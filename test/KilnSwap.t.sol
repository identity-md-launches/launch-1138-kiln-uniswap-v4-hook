// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {Kiln} from "../src/Kiln.sol";
import {KilnBase} from "./KilnBase.t.sol";
import {MockPepeo} from "./mocks/MockPepeo.sol";

/// @notice Swap-side behaviour of the Kiln against the real v4 PoolManager: the four swap shapes for every tier,
///         claims, collect(), the LP fee and the hook's guards.
contract KilnSwapTest is KilnBase {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    uint256 internal constant ZTO_AMOUNT = 1_000_000e18; // about 1 ETH worth at the opening price
    int256 internal constant ETH_AMOUNT = 1 ether;

    // ------------------------------------------------------------------ setup checks

    function test_setup_poolOpenedWithKilnHook() public view {
        (uint160 sqrtPriceX96,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertLt(sqrtPriceX96, openPrice, "priming ETH-in swap moved the price into the ZTO-only range");
        assertEq(lpFee, LP_FEE);
        assertEq(uint160(address(kiln)) & 0x3FFF, FLAGS, "hook bits");
        assertEq(address(key.hooks), address(kiln));
        assertEq(Currency.unwrap(key.currency0), address(0));
        assertEq(Currency.unwrap(key.currency1), address(zto));
        assertEq(key.fee, LP_FEE);
        assertEq(key.tickSpacing, TICK_SPACING);
        assertEq(PoolId.unwrap(kiln.poolId()), PoolId.unwrap(poolId));
        assertGt(manager.getLiquidity(poolId), 0, "range is active after priming");
    }

    // ------------------------------------------------------------------ four cases, six tiers

    function test_swap_ztoIn_exactIn_allTiers() public {
        _runAllTiers(false, true);
    }

    function test_swap_ztoIn_exactOut_allTiers() public {
        _runAllTiers(false, false);
    }

    function test_swap_ethIn_exactIn_allTiers() public {
        _runAllTiers(true, true);
    }

    function test_swap_ethIn_exactOut_allTiers() public {
        _runAllTiers(true, false);
    }

    function _runAllTiers(bool zeroForOne, bool exactIn) internal {
        for (uint256 t; t < 6; ++t) {
            address trader = makeTrader(string.concat("tier", vm.toString(t)), tierPieces[t]);
            _checkSwap(trader, tierPieces[t], tierCuts[t], zeroForOne, exactIn);
        }
    }

    /// @dev One swap by `trader`, then every accounting claim the brief makes about it.
    function _checkSwap(address trader, uint256 pieces, uint24 cutRate, bool zeroForOne, bool exactIn) internal {
        int256 amountSpecified;
        if (zeroForOne) amountSpecified = exactIn ? -ETH_AMOUNT : int256(ZTO_AMOUNT);
        else amountSpecified = exactIn ? -int256(ZTO_AMOUNT) : ETH_AMOUNT;

        uint256 claimsBefore = kiln.claims();
        uint256 reserveBefore = kiln.reserve();
        (uint256 growth0, uint256 growth1) = manager.getFeeGrowthGlobals(poolId);
        uint256 ethBefore = trader.balance;
        uint256 ztoBefore = zto.balanceOf(trader);

        vm.recordLogs();
        BalanceDelta delta = swapAs(trader, zeroForOne, amountSpecified);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Passed(trader, pepes, kilnCut, ztoTaken) once per swap, with tx.origin as the trader.
        (address pTrader, uint256 pPepes, uint24 pCut, uint256 pTaken) = findPassed(logs);
        uint256 taken = kiln.claims() - claimsBefore;
        assertEq(pTrader, trader, "Passed.trader");
        assertEq(pPepes, pieces, "Passed.pepes");
        assertEq(pCut, cutRate, "Passed.kilnCut");
        assertEq(pTaken, taken, "Passed.ztoTaken");

        // The trader's balances moved exactly by the returned delta: the hook's delta was settled by the hook.
        assertEq(int256(trader.balance) - int256(ethBefore), int256(delta.amount0()), "trader ETH");
        assertEq(int256(zto.balanceOf(trader)) - int256(ztoBefore), int256(delta.amount1()), "trader ZTO");

        // The ZTO side the cut is measured on, per case.
        uint256 ztoSide;
        uint256 poolInput;
        if (zeroForOne && !exactIn) {
            // ETH in, exact ZTO out: trader receives exactly the specified amount; cut is on top.
            assertEq(int256(delta.amount1()), amountSpecified, "exact output honoured");
            ztoSide = uint256(amountSpecified);
            poolInput = abs(delta.amount0());
        } else if (!zeroForOne && exactIn) {
            // ZTO in, exact in: trader pays exactly the specified amount; pool receives it minus the cut.
            assertEq(int256(delta.amount1()), amountSpecified, "exact input honoured");
            ztoSide = uint256(-amountSpecified);
            poolInput = ztoSide - taken;
        } else if (zeroForOne && exactIn) {
            // ETH in, exact in: cut comes out of the pool's ZTO output.
            assertEq(int256(delta.amount0()), amountSpecified, "exact input honoured");
            ztoSide = abs(delta.amount1()) + taken;
            poolInput = uint256(-amountSpecified);
        } else {
            // ZTO in, exact ETH out: trader pays the pool's ZTO input plus the cut.
            assertEq(int256(delta.amount0()), amountSpecified, "exact output honoured");
            ztoSide = abs(delta.amount1()) - taken;
            poolInput = ztoSide;
        }
        assertGt(ztoSide, 0, "swap moved ZTO");
        assertApproxEqAbs(taken, ztoSide * cutRate / PIPS, 1, "cut is kilnCut of the ZTO side");
        if (cutRate == 0) assertEq(taken, 0, "tier 21 pays nothing");
        else assertGt(taken, 0, "cut taken");

        // The cut is held as ERC-6909 ZTO claims, not yet real ZTO; reserve untouched.
        assertEq(manager.balanceOf(address(kiln), uint256(uint160(address(zto)))), kiln.claims(), "6909 balance");
        assertEq(kiln.reserve(), reserveBefore, "reserve unchanged by swaps");
        assertEq(zto.balanceOf(address(kiln)), reserveBefore, "no real ZTO moved by swaps");

        // The pool's static lpFee was paid on the pool's input, independent of the Kiln cut.
        uint256 fee = lpFeeAccrued(growth0, growth1, zeroForOne);
        assertGt(fee, 0, "lp fee paid");
        assertApproxEqRel(fee, poolInput * LP_FEE / PIPS, 1e14, "lp fee is lpFee of the pool input");
    }

    // ------------------------------------------------------------------ tier 21 and collect

    function test_tier21_paysNothing_everyCase() public {
        uint256 before = kiln.claims();
        swapAs(whale, true, -ETH_AMOUNT);
        swapAs(whale, true, int256(ZTO_AMOUNT));
        swapAs(whale, false, -int256(ZTO_AMOUNT));
        swapAs(whale, false, ETH_AMOUNT);
        assertEq(kiln.claims(), before, "no cut for 21 pieces");
        (uint256 index,, uint24 cut) = kiln.tierOf(whale);
        assertEq(index, 5);
        assertEq(cut, 0);
    }

    function test_collect_movesClaimsIntoReserveAndRealZto() public {
        address trader = makeTrader("t0", 0);
        swapAs(trader, true, -ETH_AMOUNT);
        swapAs(trader, false, -int256(ZTO_AMOUNT));
        uint256 claims = kiln.claims();
        assertGt(claims, 0);
        assertEq(kiln.reserve(), 0);
        assertEq(zto.balanceOf(address(kiln)), 0);
        assertEq(kiln.bid(), 0, "bid counts real ZTO only");

        vm.expectEmit(address(kiln));
        emit Kiln.Collected(claims);
        vm.prank(makeAddr("anyone"));
        kiln.collect();

        assertEq(kiln.claims(), 0);
        assertEq(kiln.reserve(), claims);
        assertEq(zto.balanceOf(address(kiln)), claims);
        assertEq(manager.balanceOf(address(kiln), uint256(uint160(address(zto)))), 0, "claims burned");
        assertEq(kiln.bid(), claims / 50);
        assertEq(kiln.ask(), claims / 50 * 11_500 / 10_000);
    }

    function test_collect_nothingToCollect_isNoop() public {
        assertEq(kiln.claims(), 0);
        vm.recordLogs();
        kiln.collect();
        assertEq(vm.getRecordedLogs().length, 0, "no event");
        assertEq(kiln.reserve(), 0);
        assertEq(zto.balanceOf(address(kiln)), 0);
    }

    function test_collect_sweepsZtoClaimsSentByOthers() public {
        // ZTO claim tokens somebody transfers to the Kiln are swept into the reserve too; nothing is stranded.
        address trader = makeTrader("t0", 0);
        vm.prank(trader, trader);
        swapRouter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        uint256 id = uint256(uint160(address(zto)));
        uint256 traderClaims = manager.balanceOf(trader, id);
        assertGt(traderClaims, 0, "trader took ZTO as claims");
        uint256 cut = kiln.claims();
        assertGt(cut, 0);

        vm.prank(trader);
        manager.transfer(address(kiln), id, traderClaims);
        assertEq(kiln.claims(), cut, "claims() tracks cuts only");

        vm.expectEmit(address(kiln));
        emit Kiln.Collected(cut + traderClaims);
        kiln.collect();
        assertEq(kiln.claims(), 0);
        assertEq(kiln.reserve(), cut + traderClaims);
        assertEq(zto.balanceOf(address(kiln)), cut + traderClaims);
    }

    // ------------------------------------------------------------------ partial fills

    /// @dev The revert v4 surfaces when the hook's afterSwap reverts with PartialFill(asked, realised).
    function _partialFillRevert(uint256 asked, uint256 realised) internal view returns (bytes memory) {
        bytes memory reason = abi.encodeWithSelector(Kiln.PartialFill.selector, asked, realised);
        bytes memory details = abi.encodeWithSelector(Hooks.HookCallFailed.selector);
        address hook = address(kiln);
        bytes4 selector = IHooks.afterSwap.selector;
        return abi.encodeWithSelector(CustomRevert.WrappedError.selector, hook, selector, reason, details);
    }

    /// @dev Checks the one Passed event in the recorded logs and returns its ztoTaken.
    function _assertPassed(address trader, uint256 pepes, uint24 cut) internal returns (uint256 taken) {
        (address pTrader, uint256 pPepes, uint24 pCut, uint256 pTaken) = findPassed(vm.getRecordedLogs());
        assertEq(pTrader, trader, "Passed.trader");
        assertEq(pPepes, pepes, "Passed.pepes");
        assertEq(pCut, cut, "Passed.kilnCut");
        return pTaken;
    }

    /// @dev The current sqrtPriceX96 scaled by `bps / 10_000`, for price limits inside the range.
    function _limitAt(uint256 bps) internal view returns (uint160) {
        (uint160 price,,,) = manager.getSlot0(poolId);
        return uint160(uint256(price) * bps / 10_000);
    }

    /// @dev Swaps with an explicit price limit so the pool stops early.
    function _swapWithLimit(address trader, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (BalanceDelta delta)
    {
        return _swapFull(trader, trader, zeroForOne, amountSpecified, limit);
    }

    /// @dev Swaps with msg.sender `trader` but tx.origin `origin`, as a from-less eth_call looks to the hook.
    function _swapWithOrigin(address trader, address origin, bool zeroForOne, int256 amountSpecified)
        internal
        returns (BalanceDelta delta)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        return _swapFull(trader, origin, zeroForOne, amountSpecified, limit);
    }

    function _swapFull(address trader, address origin, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (BalanceDelta delta)
    {
        uint256 value;
        if (zeroForOne && amountSpecified < 0) value = uint256(-amountSpecified);
        if (zeroForOne && amountSpecified > 0) {
            // Exact ZTO output: send plenty of ETH, the router refunds the unused part.
            value = 5000 ether;
            vm.deal(trader, trader.balance + value);
        }
        vm.prank(trader, origin);
        delta = swapRouter.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// Case 1, ZTO in exact input, asking for more ETH than the range holds: the cut was taken on the full input
    /// in beforeSwap, so the pool stopping early must revert instead of charging the cut on ZTO never swapped.
    function test_partialFill_ztoIn_exactIn_reverts() public {
        address trader = makeTrader("t0", 0);
        uint256 input = 100_000_000e18;
        uint256 cut = input * 13_000 / PIPS;
        // What the pool would consume before running out of ETH: compute it with a no-cut wallet first.
        uint256 snap = vm.snapshotState();
        BalanceDelta probe = swapAs(whale, false, -int256(input));
        uint256 consumed = abs(probe.amount1());
        assertLt(consumed, input - cut, "fixture: the swap really is a partial fill");
        vm.revertToState(snap);

        uint256 claimsBefore = kiln.claims();
        vm.expectRevert(_partialFillRevert(input - cut, consumed));
        swapAs(trader, false, -int256(input));
        assertEq(kiln.claims(), claimsBefore, "nothing taken");
    }

    /// Case 4, ETH in exact ZTO output larger than the ZTO the range holds: reverts rather than leaving the trader
    /// paying ETH and ZTO for nothing.
    function test_partialFill_ethIn_exactOut_reverts() public {
        address trader = makeTrader("t0", 0);
        uint256 output = zto.balanceOf(address(manager)) * 200;
        uint256 cut = output * 13_000 / PIPS;
        uint256 snap = vm.snapshotState();
        BalanceDelta probe = _swapWithLimit(whale, true, int256(output), TickMath.MIN_SQRT_PRICE + 1);
        uint256 delivered = abs(probe.amount1());
        assertLt(delivered, output, "fixture: the swap really is a partial fill");
        vm.revertToState(snap);

        vm.expectRevert(_partialFillRevert(output + cut, delivered));
        _swapWithLimit(trader, true, int256(output), TickMath.MIN_SQRT_PRICE + 1);
        assertEq(kiln.claims(), 0, "nothing taken");
    }

    /// A price limit inside the range stops the pool early too, for every tier that pays a cut.
    function test_partialFill_priceLimit_revertsForEveryPayingTier() public {
        uint160 limit = _limitAt(10_002); // ZTO in pushes the price up; stop almost at once
        for (uint256 t; t < 5; ++t) {
            address trader = makeTrader(string.concat("tier", vm.toString(t)), tierPieces[t]);
            vm.prank(trader, trader);
            vm.expectRevert(); // PartialFill wrapped by the PoolManager
            swapRouter.swap(
                key,
                IPoolManager.SwapParams({
                    zeroForOne: false, amountSpecified: -int256(ZTO_AMOUNT), sqrtPriceLimitX96: limit
                }),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            );
        }
        assertEq(kiln.claims(), 0);
    }

    /// A wallet that pays no cut has nothing to reconcile: its ZTO-specified swaps may fill partially like any
    /// other v4 swap.
    function test_partialFill_tier21_isAllowed() public {
        BalanceDelta delta = _swapWithLimit(whale, false, -int256(ZTO_AMOUNT), _limitAt(10_002));
        assertLt(abs(delta.amount1()), ZTO_AMOUNT, "price-limited partial fill went through");
        assertEq(kiln.claims(), 0);
        uint256 input = 100_000_000e18;
        delta = swapAs(whale, false, -int256(input));
        assertLt(abs(delta.amount1()), input, "liquidity-exhausted partial fill went through");
        assertGt(delta.amount0(), 0, "ETH received");
        assertEq(kiln.claims(), 0);
    }

    /// Cases 2 and 3 measure the cut in afterSwap on the ZTO the pool actually moved, so a partial fill is simply
    /// charged on the realised amount. Case 3 here: ETH in exact input driven to a price limit inside the range.
    function test_partialFill_ethIn_exactIn_chargesRealisedAmount() public {
        address trader = makeTrader("t0", 0);
        BalanceDelta delta = _swapWithLimit(trader, true, -4 ether, _limitAt(9_990));
        uint256 taken = kiln.claims();
        uint256 ethIn = abs(delta.amount0());
        assertGt(ethIn, 0);
        assertLt(ethIn, 4 ether, "partial: not all ETH consumed");
        uint256 poolOut = abs(delta.amount1()) + taken;
        assertApproxEqAbs(taken, poolOut * 13_000 / PIPS, 1, "cut is 1.30% of the ZTO delivered");
    }

    /// Case 2: ZTO in, exact ETH output larger than the ETH the range holds.
    function test_partialFill_ztoIn_exactOut_chargesRealisedAmount() public {
        address trader = makeTrader("t0", 0);
        uint256 ethInPool = address(manager).balance;
        BalanceDelta delta = swapAs(trader, false, int256(ethInPool * 2));
        uint256 taken = kiln.claims();
        assertLt(abs(delta.amount0()), ethInPool * 2, "partial: less ETH than asked");
        uint256 poolIn = abs(delta.amount1()) - taken;
        assertGt(poolIn, 0);
        assertApproxEqAbs(taken, poolIn * 13_000 / PIPS, 1, "cut is 1.30% of the ZTO consumed");
    }

    /// An empty pool: ZTO exact-in reverts (the pool consumes nothing, the cut would be pure loss); ETH exact-in
    /// delivers nothing and takes nothing.
    function test_partialFill_emptyPool() public {
        vm.startPrank(lp);
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: RANGE_LOWER, tickUpper: OPEN_TICK, liquidityDelta: -RANGE_LIQUIDITY, salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();
        assertEq(manager.getLiquidity(poolId), 0);
        address trader = makeTrader("t0", 0);
        vm.expectRevert(_partialFillRevert(ZTO_AMOUNT - ZTO_AMOUNT * 13_000 / PIPS, 0));
        swapAs(trader, false, -int256(ZTO_AMOUNT));
        BalanceDelta delta = swapAs(trader, true, -ETH_AMOUNT);
        assertEq(delta.amount1(), 0);
        assertEq(kiln.claims(), 0);
    }

    // ------------------------------------------------------------------ pass reads that must not revert

    /// A from-less eth_call runs with tx.origin == 0, where Pepeolithic's OpenZeppelin balanceOf reverts. The
    /// Kiln treats that as no pieces so quoters and simulations still work.
    function test_zeroTxOrigin_isTierZero() public {
        vm.expectRevert(abi.encodeWithSelector(MockPepeo.ERC721InvalidOwner.selector, address(0)));
        pepeo.balanceOf(address(0));
        (uint256 index, uint256 pepes, uint24 cut) = kiln.tierOf(address(0));
        assertEq(index, 0);
        assertEq(pepes, 0);
        assertEq(cut, 13_000);
    }

    function test_zeroTxOrigin_swapSimulationSucceeds() public {
        address trader = makeTrader("t0", 0);
        vm.recordLogs();
        BalanceDelta delta = _swapWithOrigin(trader, address(0), true, -ETH_AMOUNT);
        uint256 taken = _assertPassed(address(0), 0, 13_000);
        assertEq(taken, kiln.claims());
        assertApproxEqAbs(taken, (abs(delta.amount1()) + taken) * 13_000 / PIPS, 1);
    }

    /// If the PEPEO read fails for any reason the swap still goes through at tier 0 rather than bricking the pool.
    function test_pepeoReadFailure_fallsBackToTierZero() public {
        pepeo.setBalanceOfReverts(true);
        vm.recordLogs();
        BalanceDelta delta = swapAs(whale, true, -ETH_AMOUNT);
        uint256 taken = _assertPassed(whale, 0, 13_000); // 21 pieces unreadable: treated as none
        assertGt(taken, 0);
        assertApproxEqAbs(taken, (abs(delta.amount1()) + taken) * 13_000 / PIPS, 1);
        pepeo.setBalanceOfReverts(false);
        uint256 before = kiln.claims();
        swapAs(whale, true, -ETH_AMOUNT);
        assertEq(kiln.claims(), before, "pass readable again: no cut");
    }

    // ------------------------------------------------------------------ guards

    function test_hookCallbacks_rejectNonPoolManager() public {
        IPoolManager.SwapParams memory params =
            IPoolManager.SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: 0});
        vm.expectRevert(Kiln.NotPoolManager.selector);
        kiln.beforeSwap(address(this), key, params, "");
        vm.expectRevert(Kiln.NotPoolManager.selector);
        kiln.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(Kiln.NotPoolManager.selector);
        kiln.unlockCallback(abi.encode(uint256(1)));
    }

    function test_hook_rejectsAnotherPoolUsingIt() public {
        PoolKey memory other = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(zto)),
            fee: LP_FEE,
            tickSpacing: 10,
            hooks: IHooks(address(kiln))
        });
        manager.initialize(other, openPrice);
        address trader = makeTrader("t0", 0);
        vm.prank(trader, trader);
        vm.expectRevert();
        swapRouter.swap{value: 1 ether}(
            other,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function test_liquidity_isUnrestricted() public {
        // Remove part of the ZTO-only range and add a two-sided range: no hook callback runs on liquidity.
        vm.startPrank(lp);
        lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: RANGE_LOWER, tickUpper: OPEN_TICK, liquidityDelta: -RANGE_LIQUIDITY / 2, salt: bytes32(0)
            }),
            ""
        );
        vm.deal(lp, 100 ether);
        BalanceDelta twoSided = lpRouter.modifyLiquidity{value: 100 ether}(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: OPEN_TICK - 12_000, tickUpper: OPEN_TICK + 12_000, liquidityDelta: 1e20, salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();
        assertLt(twoSided.amount0(), 0);
        assertLt(twoSided.amount1(), 0);
    }

    function test_tierOf_boundaries() public {
        uint256[11] memory balances = [uint256(0), 1, 2, 3, 6, 7, 11, 12, 20, 21, 100];
        uint256[11] memory expected = [uint256(0), 1, 1, 2, 2, 3, 3, 4, 4, 5, 5];
        for (uint256 i; i < balances.length; ++i) {
            address w = makeAddr(string.concat("w", vm.toString(i)));
            for (uint256 j; j < balances[i]; ++j) {
                mintPiece(w);
            }
            (uint256 index, uint256 pepes, uint24 cut) = kiln.tierOf(w);
            assertEq(pepes, balances[i]);
            assertEq(index, expected[i]);
            assertEq(cut, tierCuts[expected[i]]);
        }
        for (uint256 i; i < 6; ++i) {
            (uint256 minPepes, uint24 cut) = kiln.tier(i);
            assertEq(minPepes, tierPieces[i]);
            assertEq(cut, tierCuts[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(Kiln.NoSuchTier.selector, 6));
        kiln.tier(6);
    }
}
