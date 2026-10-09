// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

import {Kiln} from "../src/Kiln.sol";
import {MockZTO} from "./mocks/MockZTO.sol";
import {MockPepeo} from "./mocks/MockPepeo.sol";
import {KilnBase} from "./KilnBase.t.sol";

/// @notice Drives the Kiln with random, bounded calls from several actors and keeps ghost totals of every ZTO
///         and piece movement. Swaps are sized inside the range's live liquidity so every fill is complete
///         (partial fills in the beforeSwap cases are a reported finding, not something to bless here).
contract KilnHandler is Test {
    using BalanceDeltaLibrary for BalanceDelta;
    using StateLibrary for IPoolManager;

    uint256 internal constant PIPS = 1_000_000;
    uint256 internal constant DEPTH = 50;

    IPoolManager public immutable manager;
    Kiln public immutable kiln;
    MockZTO public immutable zto;
    MockPepeo public immutable pepeo;
    PoolSwapTest public immutable swapRouter;
    PoolKey internal key;
    PoolId internal poolId;
    int24 internal immutable rangeLower;
    int24 internal immutable rangeUpper;

    address[6] public traders;
    uint256[6] public traderPieces;
    uint24[6] public traderCuts;
    address public seeder = makeAddr("h.seeder");
    address public seller = makeAddr("h.seller");
    address public buyer = makeAddr("h.buyer");
    address public stranger = makeAddr("h.stranger");
    uint256 public nextId = 10_000;

    // ------------------------------------------------------------------ ghosts

    uint256 public ghostSeeded; // ZTO put in through seed()
    uint256 public ghostCuts; // ZTO cut minted as claims by swaps
    uint256 public ghostCollected; // ZTO cut moved from claims to reserve
    uint256 public ghostDonatedPending; // ERC-6909 ZTO sent to the Kiln by others, not yet collected
    uint256 public ghostDonatedCollected; // donated ERC-6909 ZTO swept into reserve by collect()
    uint256 public ghostSoldOut; // ZTO paid to sellers
    uint256 public ghostBoughtIn; // ZTO paid by buyers
    uint256 public ghostPiecesIn; // pieces taken through sell()
    uint256 public ghostPiecesOut; // pieces released through buy()
    uint256 public ghostStuck; // pieces sent by plain transfer, never inventory
    uint256 public ghostSwaps;
    uint256 public ghostZeroCutSwaps; // swaps by a 21-piece wallet
    uint256 public ghostSells;
    uint256 public ghostBuys;
    uint256 public ghostEmptyReserveSells;
    uint256 public ghostCollectNoops;
    uint256 public ghostMaxCutGap; // largest |cut - kilnCut * ztoSide / PIPS| seen (rounding only)
    uint256 public ghostPriceBoundReverts; // sell(id, min) / buy(id, max) refused by their bound
    uint256 public ghostPartialFillReverts; // ZTO-specified partial fills refused for a paying tier
    uint256 public ghostPartialFillsAllowed; // partial fills that went through (tier 21, or afterSwap shapes)
    uint256 public ghostDonations;

    constructor(
        IPoolManager manager_,
        Kiln kiln_,
        MockZTO zto_,
        MockPepeo pepeo_,
        PoolSwapTest swapRouter_,
        PoolKey memory key_,
        PoolId poolId_,
        int24 rangeLower_,
        int24 rangeUpper_,
        uint256[6] memory pieces,
        uint24[6] memory cuts
    ) {
        manager = manager_;
        kiln = kiln_;
        zto = zto_;
        pepeo = pepeo_;
        swapRouter = swapRouter_;
        key = key_;
        poolId = poolId_;
        rangeLower = rangeLower_;
        rangeUpper = rangeUpper_;
        for (uint256 t; t < 6; ++t) {
            traders[t] = makeAddr(string.concat("h.trader", vm.toString(t)));
            traderPieces[t] = pieces[t];
            traderCuts[t] = cuts[t];
            _fund(traders[t]);
            for (uint256 i; i < pieces[t]; ++i) {
                pepeo.mint(traders[t], nextId++);
            }
        }
        _fund(seeder);
        _fund(seller);
        _fund(buyer);
        _fund(stranger);
    }

    function _fund(address who) internal {
        vm.deal(who, 1_000_000 ether);
        zto.mint(who, 1e30);
        vm.startPrank(who);
        zto.approve(address(swapRouter), type(uint256).max);
        zto.approve(address(kiln), type(uint256).max);
        pepeo.setApprovalForAll(address(kiln), true);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ bounds from live liquidity

    /// @dev ZTO the range can still give (price falling to the lower bound) and ETH it can still give (price
    ///      rising to the upper bound). A quarter of either is a safe complete-fill size including the cut.
    function _available() internal view returns (uint256 ztoOut, uint256 ethOut) {
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        uint128 liquidity = manager.getLiquidity(poolId);
        uint160 lower = TickMath.getSqrtPriceAtTick(rangeLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(rangeUpper);
        if (liquidity == 0) return (0, 0);
        if (sqrtP > lower) ztoOut = SqrtPriceMath.getAmount1Delta(lower, sqrtP, liquidity, false);
        if (sqrtP < upper) ethOut = SqrtPriceMath.getAmount0Delta(sqrtP, upper, liquidity, false);
    }

    function _price() internal view returns (uint256 ztoPerEthX96) {
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        ztoPerEthX96 = (uint256(sqrtP) * uint256(sqrtP)) >> 96;
    }

    /// @dev The Kiln's live ERC-6909 ZTO balance: its own cuts plus anything others transferred to it.
    function _pending() internal view returns (uint256) {
        return manager.balanceOf(address(kiln), uint256(uint160(address(zto))));
    }

    /// @dev What sell() pays / buy() charges right now, computed independently of quoteBid()/quoteAsk():
    ///      both run collect() first, so the pending ERC-6909 balance counts.
    function _executionPrices() internal view returns (uint256 sellPrice, uint256 buyPrice) {
        sellPrice = (kiln.reserve() + _pending()) / DEPTH;
        buyPrice = sellPrice * 11_500 / 10_000;
        assertEq(kiln.quoteBid(), sellPrice, "handler: quoteBid");
        assertEq(kiln.quoteAsk(), buyPrice, "handler: quoteAsk");
    }

    /// @dev Books a collect() that ran inside sell()/buy(): the Kiln's own claims and any donated claims both land
    ///      in the reserve.
    function _bookCollected(uint256 claimsBefore) internal {
        ghostCollected += claimsBefore;
        ghostDonatedCollected += ghostDonatedPending;
        ghostDonatedPending = 0;
    }

    /// @dev A price limit `bps` away from the current price in the swap's direction, kept well inside the range
    ///      so the pool stops at the limit with liquidity still live. Returns zero when there is no headroom.
    function _limitInRange(bool zeroForOne, uint256 bps) internal view returns (uint160 limit) {
        (uint160 sqrtP,,,) = manager.getSlot0(poolId);
        uint160 lower = TickMath.getSqrtPriceAtTick(rangeLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(rangeUpper);
        if (zeroForOne) {
            uint256 step = uint256(sqrtP) * bps / 10_000;
            if (step == 0 || sqrtP <= lower || uint256(sqrtP) - lower < 8 * step) return 0;
            limit = uint160(uint256(sqrtP) - step);
        } else {
            uint256 step = uint256(sqrtP) * bps / 10_000;
            if (step == 0 || sqrtP >= upper || uint256(upper) - sqrtP < 8 * step) return 0;
            limit = uint160(uint256(sqrtP) + step);
        }
    }

    // ------------------------------------------------------------------ actions

    /// @notice One swap in one of the four shapes by one of the six tier wallets, sized for a complete fill.
    function swap(uint256 traderSeed, uint256 shape, uint256 amountSeed) external {
        uint256 t = bound(traderSeed, 0, 5);
        shape = bound(shape, 0, 3);
        bool zeroForOne = shape < 2;
        bool exactIn = shape % 2 == 0;
        (uint256 ztoOut, uint256 ethOut) = _available();
        uint256 price = _price();

        int256 amountSpecified;
        if (zeroForOne && exactIn) {
            // ETH in: the ETH that buys a quarter of the remaining ZTO.
            uint256 maxEth = (ztoOut / 4 << 96) / price;
            if (maxEth < 1e9) return;
            amountSpecified = -int256(bound(amountSeed, 1e9, maxEth));
        } else if (zeroForOne && !exactIn) {
            if (ztoOut / 4 < 1e9) return;
            amountSpecified = int256(bound(amountSeed, 1e9, ztoOut / 4));
        } else if (!zeroForOne && exactIn) {
            uint256 maxZto = (ethOut / 4) * price >> 96;
            if (maxZto < 1e9) return;
            amountSpecified = -int256(bound(amountSeed, 1e9, maxZto));
        } else {
            if (ethOut / 4 < 1e9) return;
            amountSpecified = int256(bound(amountSeed, 1e9, ethOut / 4));
        }
        _swapChecked(t, zeroForOne, exactIn, amountSpecified);
    }

    function _swapChecked(uint256 t, bool zeroForOne, bool exactIn, int256 amountSpecified) internal {
        address trader = traders[t];
        uint256 claimsBefore = kiln.claims();
        uint256 reserveBefore = kiln.reserve();
        uint256 ethBefore = trader.balance;
        uint256 ztoBefore = zto.balanceOf(trader);
        uint256 value = zeroForOne ? (exactIn ? uint256(-amountSpecified) : 100_000 ether) : 0;

        vm.prank(trader, trader);
        BalanceDelta delta = swapRouter.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 taken = kiln.claims() - claimsBefore;
        ghostCuts += taken;
        ++ghostSwaps;
        if (traderCuts[t] == 0) ++ghostZeroCutSwaps;

        // The trader's balances moved exactly by the returned delta.
        assertEq(int256(trader.balance) - int256(ethBefore), int256(delta.amount0()), "handler: trader ETH");
        assertEq(int256(zto.balanceOf(trader)) - int256(ztoBefore), int256(delta.amount1()), "handler: trader ZTO");
        // Swaps never touch the reserve or the Kiln's real ZTO.
        assertEq(kiln.reserve(), reserveBefore, "handler: reserve moved by a swap");

        // The specified side is honoured exactly; the cut is kilnCut of the ZTO side within rounding.
        uint256 ztoSide;
        if (zeroForOne && !exactIn) {
            assertEq(int256(delta.amount1()), amountSpecified, "handler: exact ZTO out");
            ztoSide = uint256(amountSpecified);
        } else if (!zeroForOne && exactIn) {
            assertEq(int256(delta.amount1()), amountSpecified, "handler: exact ZTO in");
            ztoSide = uint256(-amountSpecified);
        } else if (zeroForOne && exactIn) {
            assertEq(int256(delta.amount0()), amountSpecified, "handler: exact ETH in");
            ztoSide = _abs(delta.amount1()) + taken;
        } else {
            assertEq(int256(delta.amount0()), amountSpecified, "handler: exact ETH out");
            ztoSide = _abs(delta.amount1()) - taken;
        }
        uint256 expected = ztoSide * traderCuts[t] / PIPS;
        uint256 gap = taken > expected ? taken - expected : expected - taken;
        if (gap > ghostMaxCutGap) ghostMaxCutGap = gap;
        assertLe(gap, 1, "handler: cut is not kilnCut of the ZTO side");
        if (traderCuts[t] == 0) assertEq(taken, 0, "handler: tier 21 charged");
    }

    /// @notice A swap in one of the four shapes driven to a price limit inside the range, so the pool stops early.
    ///         ZTO-specified shapes (ETH-in exact-out, ZTO-in exact-in) must revert PartialFill for a paying tier
    ///         and go through for tier 21; the afterSwap shapes go through and are charged on the realised ZTO.
    function partialFill(uint256 traderSeed, uint256 shape) external {
        uint256 t = bound(traderSeed, 0, 5);
        shape = bound(shape, 0, 3);
        bool zeroForOne = shape < 2;
        bool exactIn = shape % 2 == 0;
        uint160 limit = _limitInRange(zeroForOne, 1);
        if (limit == 0) return;
        (uint256 ztoOut, uint256 ethOut) = _available();
        uint256 price = _price();

        // Half of what the whole range could move: far more than a one-bip price move can, so the fill is partial.
        int256 amountSpecified;
        if (zeroForOne && exactIn) {
            uint256 eth = (ztoOut / 2 << 96) / price;
            if (eth < 1e12) return;
            amountSpecified = -int256(eth);
        } else if (zeroForOne) {
            if (ztoOut / 2 < 1e12) return;
            amountSpecified = int256(ztoOut / 2);
        } else if (exactIn) {
            uint256 ztoIn = (ethOut / 2) * price >> 96;
            if (ztoIn < 1e12) return;
            amountSpecified = -int256(ztoIn);
        } else {
            if (ethOut / 2 < 1e12) return;
            amountSpecified = int256(ethOut / 2);
        }

        bool ztoSpecified = zeroForOne != exactIn;
        if (ztoSpecified && traderCuts[t] != 0) {
            _expectPartialFillRevert(t, zeroForOne, amountSpecified, limit);
        } else {
            _swapLimited(t, zeroForOne, exactIn, amountSpecified, limit);
        }
    }

    function _swapParams(bool zeroForOne, int256 amountSpecified, uint160 limit)
        internal
        pure
        returns (IPoolManager.SwapParams memory)
    {
        return IPoolManager.SwapParams({
            zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit
        });
    }

    /// @dev A paying tier's ZTO-specified swap that cannot fill in full must revert with PartialFill(asked,
    ///      realised) wrapped by the PoolManager, where asked is the ZTO the pool was told to move, and leave
    ///      claims, the ERC-6909 balance and the trader's balances untouched.
    function _expectPartialFillRevert(uint256 t, bool zeroForOne, int256 amountSpecified, uint160 limit) internal {
        address trader = traders[t];
        uint256 claimsBefore = kiln.claims();
        uint256 pendingBefore = _pending();
        uint256 ethBefore = trader.balance;
        uint256 ztoBefore = zto.balanceOf(trader);
        uint256 specified = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        uint256 cut = specified * traderCuts[t] / PIPS;
        uint256 asked = amountSpecified < 0 ? specified - cut : specified + cut;
        uint256 value = zeroForOne ? 100_000 ether : 0;

        bytes memory call = abi.encodeCall(
            PoolSwapTest.swap,
            (
                key,
                _swapParams(zeroForOne, amountSpecified, limit),
                PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
                ""
            )
        );
        vm.prank(trader, trader);
        (bool ok, bytes memory data) = address(swapRouter).call{value: value}(call);
        assertFalse(ok, "handler: partial fill for a paying tier went through");
        assertEq(bytes4(data), CustomRevert.WrappedError.selector, "handler: not a wrapped hook revert");
        (address hook, bytes4 selector, bytes memory reason,) = _decodeWrapped(data);
        assertEq(hook, address(kiln), "handler: wrong hook in revert");
        assertEq(selector, IHooks.afterSwap.selector, "handler: PartialFill not from afterSwap");
        assertEq(bytes4(reason), Kiln.PartialFill.selector, "handler: not PartialFill");
        (uint256 rAsked, uint256 rRealised) = _decodePartialFill(reason);
        assertEq(rAsked, asked, "handler: PartialFill.asked");
        assertLt(rRealised, asked, "handler: PartialFill.realised not below asked");
        ++ghostPartialFillReverts;

        assertEq(kiln.claims(), claimsBefore, "handler: claims moved on a reverted swap");
        assertEq(_pending(), pendingBefore, "handler: 6909 moved on a reverted swap");
        assertEq(trader.balance, ethBefore, "handler: ETH moved on a reverted swap");
        assertEq(zto.balanceOf(trader), ztoBefore, "handler: ZTO moved on a reverted swap");
    }

    function _decodeWrapped(bytes memory data)
        internal
        pure
        returns (address hook, bytes4 selector, bytes memory reason, bytes memory details)
    {
        bytes memory body = new bytes(data.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = data[i + 4];
        }
        (hook, selector, reason, details) = abi.decode(body, (address, bytes4, bytes, bytes));
    }

    function _decodePartialFill(bytes memory reason) internal pure returns (uint256 asked, uint256 realised) {
        bytes memory body = new bytes(reason.length - 4);
        for (uint256 i; i < body.length; ++i) {
            body[i] = reason[i + 4];
        }
        (asked, realised) = abi.decode(body, (uint256, uint256));
    }

    /// @dev A limited swap that is allowed to fill partially: tier 21 in any shape, or the afterSwap shapes. The
    ///      cut is kilnCut of the ZTO the pool actually moved, and the trader's balances follow the delta.
    function _swapLimited(uint256 t, bool zeroForOne, bool exactIn, int256 amountSpecified, uint160 limit) internal {
        address trader = traders[t];
        uint256 claimsBefore = kiln.claims();
        uint256 reserveBefore = kiln.reserve();
        uint256 ethBefore = trader.balance;
        uint256 ztoBefore = zto.balanceOf(trader);
        uint256 value = zeroForOne ? (exactIn ? uint256(-amountSpecified) : 100_000 ether) : 0;

        vm.prank(trader, trader);
        BalanceDelta delta = swapRouter.swap{value: value}(
            key,
            _swapParams(zeroForOne, amountSpecified, limit),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 taken = kiln.claims() - claimsBefore;
        ghostCuts += taken;
        ++ghostSwaps;
        ++ghostPartialFillsAllowed;
        if (traderCuts[t] == 0) ++ghostZeroCutSwaps;

        assertEq(int256(trader.balance) - int256(ethBefore), int256(delta.amount0()), "handler: trader ETH (limited)");
        assertEq(
            int256(zto.balanceOf(trader)) - int256(ztoBefore), int256(delta.amount1()), "handler: trader ZTO (limited)"
        );
        assertEq(kiln.reserve(), reserveBefore, "handler: reserve moved by a limited swap");

        // The specified side is at most what was asked, and strictly less: the limit really did bind.
        uint256 specified = amountSpecified < 0 ? uint256(-amountSpecified) : uint256(amountSpecified);
        bool ztoSpecified = zeroForOne != exactIn;
        uint256 realisedSpecified = ztoSpecified ? _abs(delta.amount1()) : _abs(delta.amount0());
        assertLt(realisedSpecified, specified, "handler: limited swap filled in full");

        uint256 ztoSide = zeroForOne ? _abs(delta.amount1()) + taken : _abs(delta.amount1()) - taken;
        uint256 expected = ztoSide * traderCuts[t] / PIPS;
        uint256 gap = taken > expected ? taken - expected : expected - taken;
        if (gap > ghostMaxCutGap) ghostMaxCutGap = gap;
        assertLe(gap, 1, "handler: limited cut is not kilnCut of the realised ZTO side");
        if (traderCuts[t] == 0) assertEq(taken, 0, "handler: tier 21 charged on a partial fill");
    }

    /// @notice Somebody transfers ERC-6909 ZTO claims to the Kiln. They are not `claims()`, but the next collect()
    ///         sweeps them into the reserve, and quoteBid()/quoteAsk() count them at once.
    function donateClaims(uint256 ethSeed, uint256 shareSeed) external {
        address donor = traders[5]; // pays no cut, so the swap itself adds nothing to claims
        (uint256 ztoOut,) = _available();
        uint256 price = _price();
        uint256 maxEth = (ztoOut / 8 << 96) / price;
        if (maxEth < 1e12) return;
        uint256 eth = bound(ethSeed, 1e12, maxEth);
        uint256 claimsBefore = kiln.claims();
        uint256 reserveBefore = kiln.reserve();

        vm.prank(donor, donor);
        swapRouter.swap{value: eth}(
            key,
            _swapParams(true, -int256(eth), TickMath.MIN_SQRT_PRICE + 1),
            PoolSwapTest.TestSettings({takeClaims: true, settleUsingBurn: false}),
            ""
        );
        ++ghostSwaps;
        ++ghostZeroCutSwaps;
        assertEq(kiln.claims(), claimsBefore, "handler: tier 21 donor was charged");

        uint256 ztoId = uint256(uint160(address(zto)));
        uint256 have = manager.balanceOf(donor, ztoId);
        if (have == 0) return;
        uint256 amount = bound(shareSeed, 1, have);
        uint256 pendingBefore = _pending();
        vm.prank(donor);
        manager.transfer(address(kiln), ztoId, amount);
        ghostDonatedPending += amount;
        ++ghostDonations;
        assertEq(_pending(), pendingBefore + amount, "handler: donation not received");
        assertEq(kiln.claims(), claimsBefore, "handler: donation counted as claims");
        assertEq(kiln.reserve(), reserveBefore, "handler: donation counted as reserve before collect");
        assertEq(kiln.quoteBid(), (reserveBefore + pendingBefore + amount) / DEPTH, "handler: quote ignores donation");
    }

    function collect() external {
        uint256 claims = kiln.claims();
        uint256 pending = _pending();
        uint256 reserveBefore = kiln.reserve();
        uint256 balanceBefore = zto.balanceOf(address(kiln));
        vm.prank(stranger);
        kiln.collect();
        assertEq(kiln.claims(), 0, "handler: claims after collect");
        assertEq(_pending(), 0, "handler: 6909 left after collect");
        assertEq(kiln.reserve(), reserveBefore + pending, "handler: reserve after collect");
        assertEq(zto.balanceOf(address(kiln)), balanceBefore + pending, "handler: balance after collect");
        _bookCollected(claims);
        if (pending == 0) ++ghostCollectNoops;
    }

    function seed(uint256 amount) external {
        amount = bound(amount, 1, 1e24);
        uint256 reserveBefore = kiln.reserve();
        uint256 claims = kiln.claims();
        vm.prank(seeder);
        kiln.seed(amount);
        ghostSeeded += amount;
        assertEq(kiln.reserve(), reserveBefore + amount, "handler: seed");
        assertEq(kiln.claims(), claims, "handler: seed touched claims");
    }

    /// @notice Sells a fresh piece. With nothing payable the call must revert and move nothing.
    function sell() external {
        _sell(0, false);
    }

    /// @notice Sells a fresh piece with a random minimum price: refused with PriceBelowMin when the bound is above
    ///         the execution price, otherwise identical to sell(id).
    function sellBounded(uint256 minSeed) external {
        (uint256 price,) = _executionPrices();
        _sell(bound(minSeed, 0, price * 2 + 1), true);
    }

    function _sell(uint256 minPrice, bool bounded) internal {
        uint256 id = nextId++;
        pepeo.mint(seller, id);
        uint256 claims = kiln.claims();
        uint256 pending = _pending();
        uint256 reserveBefore = kiln.reserve();
        (uint256 price,) = _executionPrices(); // sell() collects first
        uint256 ztoBefore = zto.balanceOf(seller);

        if (price == 0) {
            vm.prank(seller);
            vm.expectRevert(Kiln.EmptyReserve.selector);
            if (bounded) kiln.sell(id, minPrice);
            else kiln.sell(id);
            ++ghostEmptyReserveSells;
            assertEq(pepeo.ownerOf(id), seller, "handler: piece moved on failed sell");
            assertEq(kiln.claims(), claims, "handler: failed sell collected");
            return;
        }
        if (bounded && price < minPrice) {
            vm.prank(seller);
            vm.expectRevert(abi.encodeWithSelector(Kiln.PriceBelowMin.selector, price, minPrice));
            kiln.sell(id, minPrice);
            ++ghostPriceBoundReverts;
            assertEq(pepeo.ownerOf(id), seller, "handler: piece moved on refused sell");
            assertEq(kiln.claims(), claims, "handler: refused sell collected");
            assertEq(_pending(), pending, "handler: refused sell swept 6909");
            assertEq(kiln.reserve(), reserveBefore, "handler: refused sell touched reserve");
            return;
        }
        vm.prank(seller);
        if (bounded) kiln.sell(id, minPrice);
        else kiln.sell(id);
        _bookCollected(claims);
        ghostSoldOut += price;
        ++ghostPiecesIn;
        ++ghostSells;
        assertEq(zto.balanceOf(seller) - ztoBefore, price, "handler: seller paid bid");
        assertEq(kiln.reserve(), reserveBefore + pending - price, "handler: reserve after sell");
        assertEq(kiln.claims(), 0, "handler: sell left claims");
        assertEq(kiln.bid(), (reserveBefore + pending - price) / DEPTH, "handler: bid after sell");
        assertLt(kiln.bid(), price + 1, "handler: bid did not fall");
        assertTrue(kiln.held(id), "handler: sold piece not held");
        assertEq(pepeo.ownerOf(id), address(kiln), "handler: sold piece not owned");
    }

    /// @notice Buys a random inventory piece, or checks that an unheld id reverts when inventory is empty.
    function buy(uint256 pick) external {
        _buy(pick, type(uint256).max, false);
    }

    /// @notice Buys with a random maximum price: refused with PriceAboveMax when the bound is below the execution
    ///         price, otherwise identical to buy(id).
    function buyBounded(uint256 pick, uint256 maxSeed) external {
        (, uint256 price) = _executionPrices();
        _buy(pick, bound(maxSeed, 0, price * 2 + 1), true);
    }

    function _buy(uint256 pick, uint256 maxPrice, bool bounded) internal {
        uint256[] memory inv = kiln.inventory();
        if (inv.length == 0) {
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(Kiln.NotInInventory.selector, pick));
            if (bounded) kiln.buy(pick, maxPrice);
            else kiln.buy(pick);
            return;
        }
        uint256 id = inv[bound(pick, 0, inv.length - 1)];
        uint256 claims = kiln.claims();
        uint256 pending = _pending();
        uint256 reserveBefore = kiln.reserve();
        (, uint256 price) = _executionPrices();
        uint256 ztoBefore = zto.balanceOf(buyer);
        if (price == 0) {
            // Reserve dust under DEPTH: the piece waits for the next seed or cut rather than going for free.
            vm.prank(buyer);
            vm.expectRevert(Kiln.EmptyReserve.selector);
            if (bounded) kiln.buy(id, maxPrice);
            else kiln.buy(id);
            return;
        }
        if (bounded && price > maxPrice) {
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(Kiln.PriceAboveMax.selector, price, maxPrice));
            kiln.buy(id, maxPrice);
            ++ghostPriceBoundReverts;
            assertTrue(kiln.held(id), "handler: piece left on refused buy");
            assertEq(kiln.claims(), claims, "handler: refused buy collected");
            assertEq(_pending(), pending, "handler: refused buy swept 6909");
            assertEq(zto.balanceOf(buyer), ztoBefore, "handler: refused buy charged");
            return;
        }
        vm.prank(buyer);
        if (bounded) kiln.buy(id, maxPrice);
        else kiln.buy(id);
        _bookCollected(claims);
        ghostBoughtIn += price;
        ++ghostPiecesOut;
        ++ghostBuys;
        assertEq(ztoBefore - zto.balanceOf(buyer), price, "handler: buyer paid ask");
        assertEq(kiln.reserve(), reserveBefore + pending + price, "handler: reserve after buy");
        assertEq(kiln.claims(), 0, "handler: buy left claims");
        assertFalse(kiln.held(id), "handler: bought piece still held");
        assertEq(pepeo.ownerOf(id), buyer, "handler: bought piece not delivered");
        assertEq(kiln.inventory().length, inv.length - 1, "handler: inventory length after buy");
    }

    /// @notice A piece sent by plain transfer is not inventory and cannot be bought.
    function strayTransfer() external {
        uint256 id = nextId++;
        pepeo.mint(stranger, id);
        uint256 reserveBefore = kiln.reserve();
        vm.prank(stranger);
        pepeo.transferFrom(stranger, address(kiln), id);
        ++ghostStuck;
        assertFalse(kiln.held(id), "handler: stray piece became inventory");
        assertEq(kiln.reserve(), reserveBefore, "handler: stray piece paid");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Kiln.NotInInventory.selector, id));
        kiln.buy(id);
    }

    /// @notice Nobody can pull ZTO or ETH out of the Kiln by any selector it does not expose.
    function attemptWithdraw(uint256 selectorSeed) external {
        bytes4[6] memory sels = [
            bytes4(keccak256("withdraw(uint256)")),
            bytes4(keccak256("withdraw(address,uint256)")),
            bytes4(keccak256("sweep(address)")),
            bytes4(keccak256("rescue(address,uint256)")),
            bytes4(keccak256("transferOwnership(address)")),
            bytes4(keccak256("pause()"))
        ];
        bytes4 sel = sels[bound(selectorSeed, 0, 5)];
        uint256 balance = zto.balanceOf(address(kiln));
        vm.prank(stranger);
        (bool ok,) = address(kiln).call(abi.encodeWithSelector(sel, stranger, balance));
        assertFalse(ok, "handler: unknown selector succeeded");
        vm.prank(stranger);
        (ok,) = address(kiln).call{value: 1}("");
        assertFalse(ok, "handler: Kiln accepted ETH");
        assertEq(zto.balanceOf(address(kiln)), balance, "handler: ZTO left");
    }

    function _abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }
}

/// @notice Invariants over random call sequences against the real v4 PoolManager.
/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 48
/// forge-config: default.invariant.fail-on-revert = true
contract KilnInvariantTest is KilnBase {
    using StateLibrary for IPoolManager;

    KilnHandler internal handler;
    uint256 internal ztoId;

    function setUp() public override {
        super.setUp();
        ztoId = uint256(uint160(address(zto)));
        handler = new KilnHandler(
            manager, kiln, zto, pepeo, swapRouter, key, poolId, RANGE_LOWER, OPEN_TICK, tierPieces, tierCuts
        );
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = KilnHandler.swap.selector;
        selectors[1] = KilnHandler.collect.selector;
        selectors[2] = KilnHandler.seed.selector;
        selectors[3] = KilnHandler.sell.selector;
        selectors[4] = KilnHandler.buy.selector;
        selectors[5] = KilnHandler.strayTransfer.selector;
        selectors[6] = KilnHandler.attemptWithdraw.selector;
        selectors[7] = KilnHandler.sellBounded.selector;
        selectors[8] = KilnHandler.buyBounded.selector;
        selectors[9] = KilnHandler.partialFill.selector;
        selectors[10] = KilnHandler.donateClaims.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice The reserve is always backed by real ZTO; here no ERC-20 is donated, so it is backed exactly.
    function invariant_reserveBackedByRealZto() public view {
        assertLe(kiln.reserve(), zto.balanceOf(address(kiln)), "reserve exceeds balance");
        assertEq(kiln.reserve(), zto.balanceOf(address(kiln)), "ZTO entered the Kiln outside the reserve");
    }

    /// @notice The Kiln's ERC-6909 ZTO balance is its own claims() plus whatever others transferred to it and
    ///         nobody has collected yet; it never holds ETH claims or ETH.
    function invariant_claimsMirrorErc6909() public view {
        assertEq(
            manager.balanceOf(address(kiln), ztoId),
            kiln.claims() + handler.ghostDonatedPending(),
            "6909 balance != claims + pending donations"
        );
        assertGe(manager.balanceOf(address(kiln), ztoId), kiln.claims(), "claims not backed by 6909");
        assertEq(manager.balanceOf(address(kiln), 0), 0, "ETH claims");
        assertEq(address(kiln).balance, 0, "Kiln holds ETH");
    }

    /// @notice ZTO conservation: what the Kiln owes as reserve plus claims plus pending donations equals every
    ///         ZTO that came in minus what sell() paid out. Nothing else moves ZTO.
    function invariant_ztoConservation() public view {
        uint256 donated = handler.ghostDonatedPending() + handler.ghostDonatedCollected();
        uint256 inflow = handler.ghostSeeded() + handler.ghostCuts() + handler.ghostBoughtIn() + donated;
        assertEq(
            kiln.reserve() + kiln.claims() + handler.ghostDonatedPending(),
            inflow - handler.ghostSoldOut(),
            "ZTO leaked or appeared"
        );
        assertEq(
            kiln.reserve(),
            handler.ghostSeeded() + handler.ghostCollected() + handler.ghostDonatedCollected() + handler.ghostBoughtIn()
                - handler.ghostSoldOut(),
            "reserve != seeds + collects + swept donations + buys - sells"
        );
        assertEq(kiln.claims(), handler.ghostCuts() - handler.ghostCollected(), "claims != cuts - collected");
    }

    /// @notice quoteBid()/quoteAsk() are bid()/ask() over the reserve plus the live ERC-6909 balance, which is
    ///         exactly what sell()/buy() execute at after their collect(); they are never below bid()/ask().
    function invariant_quotesIncludePending() public view {
        uint256 pending = manager.balanceOf(address(kiln), ztoId);
        uint256 quoteBid = (kiln.reserve() + pending) / 50;
        assertEq(kiln.quoteBid(), quoteBid, "quoteBid != (reserve + 6909) / depth");
        assertEq(kiln.quoteAsk(), quoteBid * 11_500 / 10_000, "quoteAsk != quoteBid * 1.15");
        assertGe(kiln.quoteBid(), kiln.bid(), "quoteBid below bid");
        assertGe(kiln.quoteAsk(), kiln.ask(), "quoteAsk below ask");
        if (pending == 0) {
            assertEq(kiln.quoteBid(), kiln.bid(), "quote differs from bid with nothing pending");
            assertEq(kiln.quoteAsk(), kiln.ask(), "quote differs from ask with nothing pending");
        }
    }

    /// @notice Pieces: inventory holds exactly what sell() brought in minus what buy() released; every listed id
    ///         is owned by the Kiln; stray transfers sit outside inventory.
    function invariant_inventoryConsistent() public view {
        uint256[] memory inv = kiln.inventory();
        assertEq(inv.length, handler.ghostPiecesIn() - handler.ghostPiecesOut(), "inventory count");
        assertEq(pepeo.balanceOf(address(kiln)), inv.length + handler.ghostStuck(), "pieces held");
        for (uint256 i; i < inv.length; ++i) {
            assertEq(pepeo.ownerOf(inv[i]), address(kiln), "listed piece not owned");
            assertTrue(kiln.held(inv[i]), "listed piece not held");
            for (uint256 j = i + 1; j < inv.length; ++j) {
                assertTrue(inv[i] != inv[j], "duplicate id in inventory");
            }
        }
    }

    /// @notice bid and ask follow the reserve alone, and the spread is never negative.
    function invariant_bidAskFromReserve() public view {
        uint256 bid = kiln.reserve() / 50;
        assertEq(kiln.bid(), bid, "bid != reserve / depth");
        assertEq(kiln.ask(), bid * 11_500 / 10_000, "ask != bid * 1.15");
        assertGe(kiln.ask(), kiln.bid(), "ask below bid");
        assertLe(kiln.bid(), kiln.reserve(), "bid exceeds reserve");
    }

    /// @notice The cut never strayed from kilnCut of the ZTO side by more than one wei of rounding, and the
    ///         21-piece wallet was never charged.
    function invariant_cutRounding() public view {
        assertLe(handler.ghostMaxCutGap(), 1, "cut rounding");
    }

    /// @notice The pool itself keeps its hook, fee and spacing, and the Launcher stays opened on this Kiln.
    function invariant_poolAndLauncherFixed() public view {
        assertEq(address(launcher.kiln()), address(kiln));
        (,,, uint24 lpFee) = manager.getSlot0(poolId);
        assertEq(lpFee, LP_FEE);
        assertEq(address(kiln.poolKey().hooks), address(kiln));
    }

    /// @dev Runs once at the end of every sequence: if the handler's bounds silently skipped every action the
    ///      invariants above would be vacuous, so require that something actually happened.
    function afterInvariant() public view {
        assertGt(handler.ghostSwaps() + handler.ghostSells() + handler.ghostBuys() + handler.ghostSeeded(), 0);
    }

    /// @dev One deterministic pass over every handler action, so a handler branch that silently stopped firing
    ///      (every partialFill bailing on headroom, say) shows up here rather than hiding behind the fuzzer.
    function test_handler_everyActionFires() public {
        handler.seed(1e24);
        handler.swap(0, 0, 1e18);
        handler.swap(2, 1, 1e22);
        handler.swap(4, 2, 1e22);
        handler.swap(1, 3, 1e18);
        handler.collect();
        handler.donateClaims(1e18, 1);
        assertGt(handler.ghostDonations(), 0, "donation did not fire");
        handler.sellBounded(type(uint256).max); // refused: min above price
        handler.sell();
        handler.buyBounded(0, 0); // refused: max below price
        handler.buy(0);
        assertEq(handler.ghostPriceBoundReverts(), 2, "bounded overloads did not refuse");
        assertEq(handler.ghostSells(), 1);
        assertEq(handler.ghostBuys(), 1);
        // Push the price down with an ETH-in swap so the ZTO-in direction has headroom for a limit.
        handler.swap(5, 0, type(uint256).max);
        for (uint256 shape; shape < 4; ++shape) {
            handler.partialFill(0, shape);
            handler.partialFill(5, shape);
        }
        assertEq(handler.ghostPartialFillReverts(), 2, "paying-tier ZTO-specified partial fills did not revert");
        assertEq(handler.ghostPartialFillsAllowed(), 6, "allowed partial fills did not run");
        handler.strayTransfer();
        handler.attemptWithdraw(0);
        invariant_reserveBackedByRealZto();
        invariant_claimsMirrorErc6909();
        invariant_ztoConservation();
        invariant_quotesIncludePending();
        invariant_inventoryConsistent();
        invariant_bidAskFromReserve();
        invariant_cutRounding();
    }
}
