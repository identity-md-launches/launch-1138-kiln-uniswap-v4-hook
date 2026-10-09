// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
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
    uint256 public ghostCollected; // ZTO moved from claims to reserve
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

    function collect() external {
        uint256 claims = kiln.claims();
        uint256 reserveBefore = kiln.reserve();
        uint256 balanceBefore = zto.balanceOf(address(kiln));
        vm.prank(stranger);
        kiln.collect();
        assertEq(kiln.claims(), 0, "handler: claims after collect");
        assertEq(kiln.reserve(), reserveBefore + claims, "handler: reserve after collect");
        assertEq(zto.balanceOf(address(kiln)), balanceBefore + claims, "handler: balance after collect");
        ghostCollected += claims;
        if (claims == 0) ++ghostCollectNoops;
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
        uint256 id = nextId++;
        pepeo.mint(seller, id);
        uint256 claims = kiln.claims();
        uint256 reserveBefore = kiln.reserve();
        uint256 price = (reserveBefore + claims) / DEPTH; // sell() collects first
        uint256 ztoBefore = zto.balanceOf(seller);

        if (price == 0) {
            vm.prank(seller);
            vm.expectRevert(Kiln.EmptyReserve.selector);
            kiln.sell(id);
            ++ghostEmptyReserveSells;
            assertEq(pepeo.ownerOf(id), seller, "handler: piece moved on failed sell");
            return;
        }
        vm.prank(seller);
        kiln.sell(id);
        ghostCollected += claims;
        ghostSoldOut += price;
        ++ghostPiecesIn;
        ++ghostSells;
        assertEq(zto.balanceOf(seller) - ztoBefore, price, "handler: seller paid bid");
        assertEq(kiln.reserve(), reserveBefore + claims - price, "handler: reserve after sell");
        assertEq(kiln.bid(), (reserveBefore + claims - price) / DEPTH, "handler: bid after sell");
        assertLt(kiln.bid(), price + 1, "handler: bid did not fall");
        assertTrue(kiln.held(id), "handler: sold piece not held");
        assertEq(pepeo.ownerOf(id), address(kiln), "handler: sold piece not owned");
    }

    /// @notice Buys a random inventory piece, or checks that an unheld id reverts when inventory is empty.
    function buy(uint256 pick) external {
        uint256[] memory inv = kiln.inventory();
        if (inv.length == 0) {
            vm.prank(buyer);
            vm.expectRevert(abi.encodeWithSelector(Kiln.NotInInventory.selector, pick));
            kiln.buy(pick);
            return;
        }
        uint256 id = inv[bound(pick, 0, inv.length - 1)];
        uint256 claims = kiln.claims();
        uint256 reserveBefore = kiln.reserve();
        uint256 price = (reserveBefore + claims) / DEPTH * 11_500 / 10_000;
        uint256 ztoBefore = zto.balanceOf(buyer);
        if (price == 0) {
            // Reserve dust under DEPTH: the piece waits for the next seed or cut rather than going for free.
            vm.prank(buyer);
            vm.expectRevert(Kiln.EmptyReserve.selector);
            kiln.buy(id);
            return;
        }
        vm.prank(buyer);
        kiln.buy(id);
        ghostCollected += claims;
        ghostBoughtIn += price;
        ++ghostPiecesOut;
        ++ghostBuys;
        assertEq(ztoBefore - zto.balanceOf(buyer), price, "handler: buyer paid ask");
        assertEq(kiln.reserve(), reserveBefore + claims + price, "handler: reserve after buy");
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
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = KilnHandler.swap.selector;
        selectors[1] = KilnHandler.collect.selector;
        selectors[2] = KilnHandler.seed.selector;
        selectors[3] = KilnHandler.sell.selector;
        selectors[4] = KilnHandler.buy.selector;
        selectors[5] = KilnHandler.strayTransfer.selector;
        selectors[6] = KilnHandler.attemptWithdraw.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @notice The reserve is always backed by real ZTO; here nothing is donated, so it is backed exactly.
    function invariant_reserveBackedByRealZto() public view {
        assertLe(kiln.reserve(), zto.balanceOf(address(kiln)), "reserve exceeds balance");
        assertEq(kiln.reserve(), zto.balanceOf(address(kiln)), "ZTO entered the Kiln outside the reserve");
    }

    /// @notice claims() mirrors the Kiln's ERC-6909 ZTO balance in the PoolManager; it never holds ETH claims.
    function invariant_claimsMirrorErc6909() public view {
        assertEq(manager.balanceOf(address(kiln), ztoId), kiln.claims(), "claims != 6909 balance");
        assertEq(manager.balanceOf(address(kiln), 0), 0, "ETH claims");
        assertEq(address(kiln).balance, 0, "Kiln holds ETH");
    }

    /// @notice ZTO conservation: what the Kiln owes as reserve plus claims equals every ZTO that came in minus
    ///         what sell() paid out. Nothing else moves ZTO.
    function invariant_ztoConservation() public view {
        uint256 inflow = handler.ghostSeeded() + handler.ghostCuts() + handler.ghostBoughtIn();
        assertEq(kiln.reserve() + kiln.claims(), inflow - handler.ghostSoldOut(), "ZTO leaked or appeared");
        assertEq(
            kiln.reserve(),
            handler.ghostSeeded() + handler.ghostCollected() + handler.ghostBoughtIn() - handler.ghostSoldOut(),
            "reserve != seeds + collects + buys - sells"
        );
        assertEq(kiln.claims(), handler.ghostCuts() - handler.ghostCollected(), "claims != cuts - collected");
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
}
