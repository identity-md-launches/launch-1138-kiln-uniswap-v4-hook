// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {Kiln} from "../src/Kiln.sol";
import {KilnBase} from "./KilnBase.t.sol";

/// @notice Property and edge tests: fuzzed swap sizes for every tier and shape, one-wei swaps, whose pass counts,
///         bid/ask arithmetic at its edges, and the sell-then-buy round trip.
contract KilnPropertiesTest is KilnBase {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    uint256 internal ztoId;

    function setUp() public override {
        super.setUp();
        ztoId = uint256(uint160(address(zto)));
    }

    // ------------------------------------------------------------------ swaps

    /// @notice For any complete-fill size, tier and shape, the cut is kilnCut of the ZTO side within one wei,
    ///         the specified side is honoured exactly and the cut sits in claims as ERC-6909.
    /// forge-config: default.fuzz.runs = 400
    function testFuzz_cutIsKilnCutOfZtoSide(uint256 amountSeed, uint8 tierSeed, uint8 shapeSeed) public {
        uint256 t = bound(tierSeed, 0, 5);
        uint256 shape = bound(shapeSeed, 0, 3);
        bool zeroForOne = shape < 2;
        bool exactIn = shape % 2 == 0;
        address trader = makeTrader("fz", tierPieces[t]);

        // Sizes well inside the range: up to 4 ETH or 4,000,000 ZTO against ~20 ETH / ~240M ZTO of depth.
        int256 amountSpecified;
        if (zeroForOne && exactIn) amountSpecified = -int256(bound(amountSeed, 1e6, 4 ether));
        else if (zeroForOne) amountSpecified = int256(bound(amountSeed, 1e6, 4_000_000e18));
        else if (exactIn) amountSpecified = -int256(bound(amountSeed, 1e6, 4_000_000e18));
        else amountSpecified = int256(bound(amountSeed, 1e6, 4 ether));

        uint256 claimsBefore = kiln.claims();
        vm.recordLogs();
        BalanceDelta delta = swapAs(trader, zeroForOne, amountSpecified);
        (address pTrader, uint256 pPepes, uint24 pCut, uint256 pTaken) = findPassed(vm.getRecordedLogs());
        uint256 taken = kiln.claims() - claimsBefore;

        assertEq(pTrader, trader);
        assertEq(pPepes, tierPieces[t]);
        assertEq(pCut, tierCuts[t]);
        assertEq(pTaken, taken);
        assertEq(manager.balanceOf(address(kiln), ztoId), kiln.claims(), "6909 mirror");

        uint256 ztoSide;
        if (zeroForOne && !exactIn) {
            assertEq(int256(delta.amount1()), amountSpecified);
            ztoSide = uint256(amountSpecified);
        } else if (!zeroForOne && exactIn) {
            assertEq(int256(delta.amount1()), amountSpecified);
            ztoSide = uint256(-amountSpecified);
        } else if (zeroForOne) {
            assertEq(int256(delta.amount0()), amountSpecified);
            ztoSide = abs(delta.amount1()) + taken;
        } else {
            assertEq(int256(delta.amount0()), amountSpecified);
            ztoSide = abs(delta.amount1()) - taken;
        }
        assertEq(taken, ztoSide * tierCuts[t] / PIPS, "cut is floor(kilnCut * ztoSide)");
        if (tierCuts[t] == 0) assertEq(taken, 0);
        // A trader selling ETH never pays ZTO and one selling ZTO never pays ETH on a complete fill.
        if (zeroForOne) assertGe(int256(delta.amount1()), 0, "ETH seller paid ZTO");
        else assertGe(int256(delta.amount0()), 0, "ZTO seller paid ETH");
    }

    /// @notice One-wei swaps in every shape never revert. When the ZTO side itself is one wei the cut floors to
    ///         zero and nothing is minted, though Passed still fires; when one wei of ETH is the specified side
    ///         the ZTO side is about a million wei and the cut is still exactly floor(1.30%) of it.
    function test_oneWeiSwaps_cutFloors() public {
        address trader = makeTrader("wei", 0);
        int256[4] memory amounts = [int256(-1), int256(1), int256(-1), int256(1)];
        bool[4] memory dirs = [true, true, false, false];
        for (uint256 i; i < 4; ++i) {
            uint256 claimsBefore = kiln.claims();
            vm.recordLogs();
            BalanceDelta delta = swapAs(trader, dirs[i], amounts[i]);
            (,, uint24 cut, uint256 taken) = findPassed(vm.getRecordedLogs());
            assertEq(cut, 13_000);
            assertEq(taken, kiln.claims() - claimsBefore);
            uint256 ztoSide = dirs[i] ? abs(delta.amount1()) + taken : abs(delta.amount1()) - taken;
            assertEq(taken, ztoSide * 13_000 / PIPS, "cut floors on the ZTO side");
            if (i == 1 || i == 2) {
                // ZTO is the specified side: exactly one wei moves and the cut floors to zero.
                assertEq(ztoSide, 1, "one wei of ZTO moved");
                assertEq(taken, 0, "one wei of ZTO rounds to no cut");
            } else if (i == 0) {
                // One wei of ETH in is eaten whole by the LP fee rounding up: nothing comes out, no cut.
                assertEq(ztoSide, 0);
                assertEq(taken, 0);
            } else {
                // One wei of ETH out costs about a million wei of ZTO, and the cut is 1.30% of that.
                assertGt(ztoSide, 1e5, "one wei of ETH is many wei of ZTO");
                assertGt(taken, 0);
            }
        }
        // The smallest ZTO side that pays one wei at 1.30%: 77 wei (77 * 13000 / 1e6 = 1); 76 pays none.
        uint256 before = kiln.claims();
        swapAs(trader, false, -76);
        assertEq(kiln.claims() - before, 0);
        swapAs(trader, false, -77);
        assertEq(kiln.claims() - before, 1);
    }

    // ------------------------------------------------------------------ partial fills

    /// @dev Swap with an explicit price limit, msg.sender and tx.origin both `trader`.
    function _swapLimited(address trader, bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        returns (BalanceDelta delta)
    {
        uint256 value;
        if (zeroForOne) value = amountSpecified < 0 ? uint256(-amountSpecified) : 5000 ether;
        if (value > trader.balance) vm.deal(trader, value);
        vm.prank(trader, trader);
        delta = swapRouter.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev The PoolManager's wrapping of an afterSwap revert with PartialFill(asked, realised).
    function _wrappedPartialFill(uint256 asked, uint256 realised) internal view returns (bytes memory) {
        return abi.encodeWithSelector(
            CustomRevert.WrappedError.selector,
            address(kiln),
            IHooks.afterSwap.selector,
            abi.encodeWithSelector(Kiln.PartialFill.selector, asked, realised),
            abi.encodeWithSelector(Hooks.HookCallFailed.selector)
        );
    }

    /// @dev Current sqrtPriceX96 lowered by `bps`; the range extends 6000 ticks down, so up to 20% stays inside.
    function _limitBelow(uint256 bps) internal view returns (uint160) {
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        return uint160(uint256(sqrtP) * (10_000 - bps) / 10_000);
    }

    /// @notice For any paying tier and any binding price limit, a ZTO-specified swap that cannot fill in full
    ///         reverts PartialFill(asked, realised) with asked = specified minus the cut (exact input) or plus it
    ///         (exact output) and realised the ZTO the pool actually moved, and leaves nothing behind. The same
    ///         swap by a 21-piece wallet goes through as a partial fill and pays nothing.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_partialFill_ztoSpecified_revertsForPayingTiers(uint8 tierSeed, uint16 bpsSeed, bool exactOut)
        public
    {
        uint256 t = bound(tierSeed, 0, 4);
        uint256 bps = bound(bpsSeed, 1, 2000);
        address trader = makeTrader("pf", tierPieces[t]);
        uint24 cutPips = tierCuts[t];

        bool zeroForOne = exactOut; // ETH in for exact ZTO out; ZTO in for exact ZTO in
        int256 amountSpecified;
        uint160 limit;
        if (exactOut) {
            // Ask for twice the ZTO the pool holds, stopping at a limit inside the range.
            amountSpecified = int256(zto.balanceOf(address(manager)) * 2);
            limit = _limitBelow(bps);
        } else {
            // Push in far more ZTO than the range's ETH can absorb; the pool stops when liquidity runs out.
            (uint160 sqrtP,,,) = manager.getSlot0(poolId);
            uint256 ztoPerEthX96 = (uint256(sqrtP) * uint256(sqrtP)) >> 96;
            amountSpecified = -int256((address(manager).balance * ztoPerEthX96 >> 96) * 4);
            limit = TickMath.MAX_SQRT_PRICE - 1;
        }
        uint256 specified = abs(int128(amountSpecified));
        uint256 cut = specified * cutPips / PIPS;
        uint256 asked = exactOut ? specified + cut : specified - cut;

        // Probe what the pool can move with a wallet that pays no cut; the paying wallet asks the pool for `asked`,
        // which is also beyond what it can move, so it stops at the same place.
        uint256 snap = vm.snapshotState();
        BalanceDelta probe = _swapLimited(whale, zeroForOne, amountSpecified, limit);
        uint256 realised = abs(probe.amount1());
        assertLt(realised, asked, "fixture: the probe must be a partial fill even after the cut");
        assertEq(kiln.claims(), 0, "tier 21 pays nothing on a partial fill");
        vm.revertToState(snap);

        vm.deal(trader, 6000 ether); // enough for the exact-output router call; fixed before the snapshot below
        uint256 ethBefore = trader.balance;
        uint256 ztoBefore = zto.balanceOf(trader);
        vm.expectRevert(_wrappedPartialFill(asked, realised));
        _swapLimited(trader, zeroForOne, amountSpecified, limit);
        assertEq(kiln.claims(), 0, "claims after a reverted swap");
        assertEq(manager.balanceOf(address(kiln), ztoId), 0, "6909 after a reverted swap");
        assertEq(trader.balance, ethBefore, "ETH after a reverted swap");
        assertEq(zto.balanceOf(trader), ztoBefore, "ZTO after a reverted swap");
    }

    /// @notice The afterSwap shapes (ETH in exact input, ZTO in exact output) may fill partially; the cut is then
    ///         exactly floor(kilnCut * ZTO the pool moved) for every tier, and Passed reports it.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_partialFill_afterSwapShapes_chargeRealised(uint8 tierSeed, uint16 bpsSeed, bool exactOut) public {
        uint256 t = bound(tierSeed, 0, 5);
        uint256 bps = bound(bpsSeed, 1, 2000);
        address trader = makeTrader("pa", tierPieces[t]);

        bool zeroForOne = !exactOut; // ETH in exact input, or ZTO in exact ETH output
        int256 amountSpecified;
        uint160 limit;
        if (zeroForOne) {
            (uint160 sqrtP,,,) = manager.getSlot0(poolId);
            uint256 ztoPerEthX96 = (uint256(sqrtP) * uint256(sqrtP)) >> 96;
            amountSpecified = -int256((zto.balanceOf(address(manager)) << 96) / ztoPerEthX96 * 2);
            limit = _limitBelow(bps);
        } else {
            amountSpecified = int256(address(manager).balance * 2);
            limit = TickMath.MAX_SQRT_PRICE - 1;
        }

        vm.recordLogs();
        BalanceDelta delta = _swapLimited(trader, zeroForOne, amountSpecified, limit);
        (address pTrader, uint256 pPepes, uint24 pCut, uint256 pTaken) = findPassed(vm.getRecordedLogs());
        uint256 taken = kiln.claims();
        assertEq(pTrader, trader);
        assertEq(pPepes, tierPieces[t]);
        assertEq(pCut, tierCuts[t]);
        assertEq(pTaken, taken);

        uint256 realisedSpecified = abs(delta.amount0());
        assertLt(realisedSpecified, abs(int128(amountSpecified)), "fixture: the swap must be a partial fill");
        assertGt(realisedSpecified, 0, "fixture: something must have moved");
        uint256 poolZto = zeroForOne ? abs(delta.amount1()) + taken : abs(delta.amount1()) - taken;
        assertEq(taken, poolZto * tierCuts[t] / PIPS, "cut is floor(kilnCut * realised ZTO)");
        if (tierCuts[t] == 0) assertEq(taken, 0);
        assertEq(manager.balanceOf(address(kiln), ztoId), taken, "cut sits in claims");
    }

    // ------------------------------------------------------------------ bounded overloads

    /// @notice sell(id, min) and buy(id, max) refuse exactly when the execution price crosses the bound, report
    ///         that price, move nothing when they refuse, and otherwise behave like sell(id)/buy(id). The
    ///         execution price is quoteBid()/quoteAsk(): the pending cut counts because sell()/buy() collect first.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_boundedOverloads(uint256 amountSeed, uint256 minSeed, uint256 maxSeed) public {
        uint256 amount = bound(amountSeed, 1000, 1e27);
        address actor = makeTrader("bo", 0);
        zto.mint(actor, amount);
        vm.prank(actor);
        kiln.seed(amount);
        // Leave a cut pending so quote and bid differ.
        swapAs(actor, true, -1 ether);
        uint256 pending = manager.balanceOf(address(kiln), ztoId);
        assertGt(pending, 0);
        uint256 price = (amount + pending) / 50;
        assertEq(kiln.quoteBid(), price);
        assertGt(kiln.quoteBid(), kiln.bid(), "quote above bid while a cut is pending");
        uint256 id = mintPiece(actor);

        uint256 minPrice = bound(minSeed, 0, price * 2);
        if (minPrice > price) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(Kiln.PriceBelowMin.selector, price, minPrice));
            kiln.sell(id, minPrice);
            assertEq(pepeo.ownerOf(id), actor, "piece moved on a refused sell");
            assertEq(kiln.claims(), pending, "refused sell collected");
            assertEq(kiln.reserve(), amount, "refused sell touched the reserve");
            minPrice = price; // the bound met exactly is accepted
        }
        uint256 ztoBefore = zto.balanceOf(actor);
        vm.prank(actor);
        kiln.sell(id, minPrice);
        assertEq(zto.balanceOf(actor) - ztoBefore, price, "sell paid the quoted bid");
        assertEq(kiln.reserve(), amount + pending - price);
        assertEq(kiln.claims(), 0);

        uint256 ask = kiln.ask();
        assertEq(ask, kiln.quoteAsk(), "nothing pending: ask is the quote");
        uint256 maxPrice = bound(maxSeed, 0, ask * 2);
        if (maxPrice < ask) {
            vm.prank(actor);
            vm.expectRevert(abi.encodeWithSelector(Kiln.PriceAboveMax.selector, ask, maxPrice));
            kiln.buy(id, maxPrice);
            assertTrue(kiln.held(id), "piece left on a refused buy");
            assertEq(zto.balanceOf(actor), ztoBefore + price, "refused buy charged");
            maxPrice = ask;
        }
        vm.prank(actor);
        kiln.buy(id, maxPrice);
        assertEq(ztoBefore + price - ask, zto.balanceOf(actor), "buy charged the ask");
        assertEq(pepeo.ownerOf(id), actor);
        assertFalse(kiln.held(id));
    }

    // ------------------------------------------------------------------ pass read failure

    /// @notice When PEPEO.balanceOf reverts, every wallet is tier 0 and pays the full 1.30%; once it reads again
    ///         the wallet is back on its tier. A zero origin is tier 0 without touching PEPEO.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_pepeoReadFailure_everyTierPaysFull(uint8 tierSeed) public {
        uint256 t = bound(tierSeed, 0, 5);
        address trader = makeTrader("rf", tierPieces[t]);
        (uint256 index, uint256 pepes, uint24 cut) = kiln.tierOf(trader);
        assertEq(index, t);
        assertEq(pepes, tierPieces[t]);
        assertEq(cut, tierCuts[t]);

        pepeo.setBalanceOfReverts(true);
        (index, pepes, cut) = kiln.tierOf(trader);
        assertEq(index, 0, "unreadable pass is tier 0");
        assertEq(pepes, 0);
        assertEq(cut, 13_000);
        (index, pepes, cut) = kiln.tierOf(address(0));
        assertEq(cut, 13_000, "zero origin is tier 0");

        vm.recordLogs();
        BalanceDelta delta = swapAs(trader, true, -1 ether);
        (, uint256 pPepes, uint24 pCut, uint256 taken) = findPassed(vm.getRecordedLogs());
        assertEq(pPepes, 0);
        assertEq(pCut, 13_000);
        assertEq(taken, (abs(delta.amount1()) + taken) * 13_000 / PIPS, "full cut charged");
        assertGt(taken, 0);

        pepeo.setBalanceOfReverts(false);
        (index, pepes, cut) = kiln.tierOf(trader);
        assertEq(index, t, "tier restored once the read works");
        assertEq(cut, tierCuts[t]);
    }

    /// @notice The pass is read from tx.origin, not msg.sender: a holder trading through a non-holding router
    ///         gets the pass, a non-holder trading through a holding contract does not.
    function test_passFollowsTxOrigin_notMsgSender() public {
        address holder = makeTrader("holder", 21);
        address nobody = makeTrader("nobody", 0);
        int256 amount = -1 ether;

        uint256 before = kiln.claims();
        vm.deal(nobody, 10 ether);
        vm.prank(nobody, holder); // msg.sender holds nothing, tx.origin holds 21
        swapRouter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: amount, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        assertEq(kiln.claims(), before, "origin's pass applied");

        vm.recordLogs();
        vm.prank(holder, nobody); // msg.sender holds 21, tx.origin holds nothing
        swapRouter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: amount, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (address pTrader, uint256 pPepes, uint24 pCut, uint256 taken) = findPassed(vm.getRecordedLogs());
        assertEq(pTrader, nobody);
        assertEq(pPepes, 0);
        assertEq(pCut, 13_000);
        assertGt(taken, 0, "msg.sender's pass does not count");
    }

    /// @notice A piece only needs to be in the wallet during the swap: moving it in right before and out right
    ///         after is enough for the pass (the README's borrowed-pass caveat).
    function test_passOnlyNeedsToBeHeldDuringTheSwap() public {
        address lender = makeTrader("lender", 21);
        address borrower = makeTrader("borrower", 0);
        // Move every lender piece to the borrower.
        uint256 moved;
        for (uint256 id = 1; id < nextPieceId && moved < 21; ++id) {
            if (pepeo.ownerOf(id) == lender) {
                vm.prank(lender);
                pepeo.transferFrom(lender, borrower, id);
                ++moved;
            }
        }
        assertEq(pepeo.balanceOf(borrower), 21);
        uint256 before = kiln.claims();
        swapAs(borrower, true, -1 ether);
        assertEq(kiln.claims(), before, "borrowed pass honoured");
        // Give them back; the next swap pays full cut again.
        for (uint256 id = 1; id < nextPieceId; ++id) {
            if (pepeo.ownerOf(id) == borrower) {
                vm.prank(borrower);
                pepeo.transferFrom(borrower, lender, id);
            }
        }
        swapAs(borrower, true, -1 ether);
        assertGt(kiln.claims(), before);
    }

    /// @notice Swaps settled with claim tokens (ERC-6909 in, claims out) still pay the same cut as token swaps.
    function test_swapSettledWithClaims_paysSameCut() public {
        address trader = makeTrader("claimer", 1);
        // First take ZTO out as claims.
        vm.prank(trader, trader);
        swapRouter.swap{value: 1 ether}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -1 ether, sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        uint256 traderClaims = manager.balanceOf(trader, ztoId);
        assertGt(traderClaims, 0);
        uint256 claimsBefore = kiln.claims();
        // Then sell 500,000 ZTO back, burning claims to settle (the router burns on the trader's behalf).
        vm.prank(trader);
        manager.approve(address(swapRouter), ztoId, type(uint256).max);
        vm.prank(trader, trader);
        BalanceDelta delta = swapRouter.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: false, amountSpecified: -500_000e18, sqrtPriceLimitX96: TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: true}),
            ""
        );
        assertEq(int256(delta.amount1()), -500_000e18);
        assertEq(kiln.claims() - claimsBefore, 500_000e18 * 10_000 / PIPS, "1.00% for one piece");
        assertEq(manager.balanceOf(trader, ztoId), traderClaims - 500_000e18, "settled by burning claims");
    }

    /// @notice collect() is idempotent and permissionless: a second call right after moves nothing.
    function test_collect_isIdempotent() public {
        address trader = makeTrader("t", 0);
        swapAs(trader, true, -1 ether);
        kiln.collect();
        uint256 reserve = kiln.reserve();
        assertGt(reserve, 0);
        vm.recordLogs();
        vm.prank(makeAddr("other"));
        kiln.collect();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(kiln.reserve(), reserve);
        assertEq(zto.balanceOf(address(kiln)), reserve);
    }

    /// @notice collect() cannot run inside somebody else's PoolManager unlock, so it cannot be composed into a
    ///         swap transaction; outside one it always works.
    function test_collect_insideUnlockReverts() public {
        address trader = makeTrader("t", 0);
        swapAs(trader, true, -1 ether);
        assertGt(kiln.claims(), 0);
        Reentrant r = new Reentrant(manager, kiln);
        vm.expectRevert();
        r.go();
        assertGt(kiln.claims(), 0, "nothing collected");
        kiln.collect();
        assertEq(kiln.claims(), 0);
    }

    // ------------------------------------------------------------------ reserve arithmetic

    /// @notice bid and ask for any reserve: bid = reserve / 50, ask = bid * 11500 / 10000 (multiply first),
    ///         ask >= bid, and reserve dust under 50 wei gives a zero bid.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_bidAskArithmetic(uint256 amount) public {
        amount = bound(amount, 1, 1e27);
        address seeder = makeAddr("s");
        zto.mint(seeder, amount);
        vm.startPrank(seeder);
        zto.approve(address(kiln), amount);
        kiln.seed(amount);
        vm.stopPrank();
        uint256 bid = amount / 50;
        assertEq(kiln.reserve(), amount);
        assertEq(kiln.bid(), bid);
        assertEq(kiln.ask(), bid * 11_500 / 10_000);
        assertEq(kiln.ask(), bid * 23 / 20);
        assertGe(kiln.ask(), bid);
        assertLe(kiln.bid(), amount, "bid always payable");
        if (amount < 50) assertEq(kiln.bid(), 0);
        if (bid >= 20) assertGt(kiln.ask(), bid, "spread is positive once bid clears rounding");
    }

    /// @notice Selling a piece and buying it straight back never costs the Kiln ZTO: ask on the lower reserve
    ///         still exceeds the bid that was paid, so reserve and bid end at or above where they started.
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_sellThenBuy_neverDrainsReserve(uint256 amount) public {
        amount = bound(amount, 1000, 1e27);
        address actor = makeTrader("rt", 0);
        zto.mint(actor, amount);
        vm.startPrank(actor);
        kiln.seed(amount);
        vm.stopPrank();
        uint256 id = mintPiece(actor);
        uint256 bidBefore = kiln.bid();
        uint256 ztoBefore = zto.balanceOf(actor);

        vm.prank(actor);
        kiln.sell(id);
        assertEq(zto.balanceOf(actor), ztoBefore + bidBefore, "sell paid bid");
        uint256 ask = kiln.ask();
        vm.prank(actor);
        kiln.buy(id);

        assertEq(ztoBefore + bidBefore - ask, zto.balanceOf(actor), "buy charged ask");
        assertGe(ask, bidBefore, "round trip costs the trader at least what they received");
        assertGe(kiln.reserve(), amount, "reserve did not shrink over a round trip");
        assertGe(kiln.bid(), bidBefore, "bid did not fall over a round trip");
        assertEq(pepeo.ownerOf(id), actor);
        assertEq(kiln.inventory().length, 0);
    }

    /// @notice Repeated sales drain the reserve geometrically and never below zero; bid stays payable.
    /// forge-config: default.fuzz.runs = 200
    function testFuzz_repeatedSells_geometricAndPayable(uint256 amount, uint8 count) public {
        amount = bound(amount, 50, 1e27);
        uint256 n = bound(count, 1, 40);
        address actor = makeTrader("rs", 0);
        zto.mint(actor, amount);
        vm.prank(actor);
        kiln.seed(amount);
        uint256 reserve = amount;
        for (uint256 i; i < n; ++i) {
            uint256 id = mintPiece(actor);
            uint256 price = reserve / 50;
            if (price == 0) {
                vm.prank(actor);
                vm.expectRevert(Kiln.EmptyReserve.selector);
                kiln.sell(id);
                break;
            }
            vm.prank(actor);
            kiln.sell(id);
            reserve -= price;
            assertEq(kiln.reserve(), reserve);
            assertEq(zto.balanceOf(address(kiln)), reserve);
            assertLe(kiln.bid(), price, "bid falls or holds each sale");
        }
        assertEq(kiln.reserve(), zto.balanceOf(address(kiln)));
    }

    /// @notice The tier table is monotone: more pieces never means a higher cut, and the six brief values hold.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_tierMonotone(uint16 a, uint16 b) public {
        uint256 pa = bound(a, 0, 737);
        uint256 pb = bound(b, 0, 737);
        if (pa > pb) (pa, pb) = (pb, pa);
        address wa = makeAddr("wa");
        address wb = makeAddr("wb");
        for (uint256 i; i < pa; ++i) {
            mintPiece(wa);
        }
        for (uint256 i; i < pb; ++i) {
            mintPiece(wb);
        }
        (uint256 ia,, uint24 ca) = kiln.tierOf(wa);
        (uint256 ib,, uint24 cb) = kiln.tierOf(wb);
        assertLe(ia, ib, "tier index monotone");
        assertGe(ca, cb, "cut monotone");
        assertEq(ca, _expectedCut(pa));
        assertEq(cb, _expectedCut(pb));
    }

    function _expectedCut(uint256 pepes) internal pure returns (uint24) {
        if (pepes >= 21) return 0;
        if (pepes >= 12) return 2_500;
        if (pepes >= 7) return 5_000;
        if (pepes >= 3) return 7_500;
        if (pepes >= 1) return 10_000;
        return 13_000;
    }

    // ------------------------------------------------------------------ buy edge: dust reserve

    /// @notice With reserve dust under DEPTH, a held piece cannot be bought for zero; it waits for the reserve.
    function test_buy_revertsWhenAskIsZero() public {
        address actor = makeTrader("dust", 0);
        vm.prank(actor);
        kiln.seed(50);
        uint256 id = mintPiece(actor);
        vm.prank(actor);
        kiln.sell(id); // pays 1 wei, reserve 49
        assertEq(kiln.reserve(), 49);
        assertEq(kiln.ask(), 0);
        vm.prank(actor);
        vm.expectRevert(Kiln.EmptyReserve.selector);
        kiln.buy(id);
        assertTrue(kiln.held(id));
        // One more wei of reserve and it is purchasable again.
        vm.prank(actor);
        kiln.seed(1);
        assertEq(kiln.ask(), 1);
        vm.prank(actor);
        kiln.buy(id);
        assertEq(pepeo.ownerOf(id), actor);
    }
}

/// @dev Calls collect() from inside a PoolManager unlock to show it cannot be nested.
contract Reentrant {
    IPoolManager internal immutable manager;
    Kiln internal immutable kiln;

    constructor(IPoolManager m, Kiln k) {
        manager = m;
        kiln = k;
    }

    function go() external {
        manager.unlock("");
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        kiln.collect();
        return "";
    }
}
