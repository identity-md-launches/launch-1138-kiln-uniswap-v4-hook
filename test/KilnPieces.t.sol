// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

import {Kiln} from "../src/Kiln.sol";
import {KilnBase} from "./KilnBase.t.sol";

/// @notice Reserve and piece side of the Kiln: sell(), buy(), seed(), inventory, invariants and the absence of
///         any withdrawal path.
contract KilnPiecesTest is KilnBase {
    address internal seeder = makeAddr("seeder");
    address internal seller;
    address internal buyer;

    function setUp() public override {
        super.setUp();
        zto.mint(seeder, 1e27);
        vm.prank(seeder);
        zto.approve(address(kiln), type(uint256).max);
        seller = makeTrader("seller", 0);
        buyer = makeTrader("buyer", 0);
    }

    function seed(uint256 amount) internal {
        vm.prank(seeder);
        kiln.seed(amount);
    }

    // ------------------------------------------------------------------ sell

    function test_sell_paysBidAndBidFalls() public {
        seed(5000e18);
        assertEq(kiln.bid(), 100e18);
        uint256 id = mintPiece(seller);
        uint256 before = zto.balanceOf(seller);

        vm.expectEmit(address(kiln));
        emit Kiln.Sold(id, seller, 100e18);
        vm.prank(seller);
        kiln.sell(id);

        assertEq(zto.balanceOf(seller) - before, 100e18, "seller paid bid");
        assertEq(kiln.reserve(), 4900e18);
        assertEq(kiln.bid(), 98e18, "bid fell");
        assertEq(pepeo.ownerOf(id), address(kiln));
        assertTrue(kiln.held(id));
        uint256[] memory inv = kiln.inventory();
        assertEq(inv.length, 1);
        assertEq(inv[0], id);
    }

    function test_sell_bidFallsGeometrically() public {
        seed(50_000e18);
        uint256 reserve = 50_000e18;
        for (uint256 i; i < 10; ++i) {
            uint256 id = mintPiece(seller);
            uint256 price = reserve / 50;
            vm.prank(seller);
            kiln.sell(id);
            reserve -= price;
            assertEq(kiln.reserve(), reserve);
            assertEq(kiln.bid(), reserve / 50);
        }
        assertEq(kiln.inventory().length, 10);
        assertLt(kiln.bid(), 1000e18 * 49 / 50);
        assertGt(kiln.bid(), 0);
    }

    function test_sell_revertsAtZeroReserve() public {
        uint256 id = mintPiece(seller);
        assertEq(kiln.bid(), 0);
        vm.prank(seller);
        vm.expectRevert(Kiln.EmptyReserve.selector);
        kiln.sell(id);
        // Dust below DEPTH gives a zero bid too.
        seed(49);
        vm.prank(seller);
        vm.expectRevert(Kiln.EmptyReserve.selector);
        kiln.sell(id);
    }

    function test_sell_collectsClaimsFirst() public {
        address trader = makeTrader("t0", 0);
        swapAs(trader, true, -1 ether);
        uint256 claims = kiln.claims();
        assertGt(claims, 0);
        assertEq(kiln.bid(), 0, "claims are not yet reserve");

        uint256 id = mintPiece(seller);
        uint256 price = claims / 50;
        vm.expectEmit(address(kiln));
        emit Kiln.Collected(claims);
        vm.expectEmit(address(kiln));
        emit Kiln.Sold(id, seller, price);
        vm.prank(seller);
        kiln.sell(id);

        assertEq(kiln.claims(), 0);
        assertEq(kiln.reserve(), claims - price);
        assertEq(zto.balanceOf(address(kiln)), claims - price);
    }

    function test_sell_revertsWithoutApproval() public {
        seed(5000e18);
        address stranger = makeAddr("stranger");
        uint256 id = mintPiece(stranger);
        vm.prank(stranger);
        vm.expectRevert(bytes("PEPEO: not authorized"));
        kiln.sell(id);
    }

    function test_sell_revertsIfCallerDoesNotOwnPiece() public {
        seed(5000e18);
        uint256 id = mintPiece(buyer);
        vm.prank(seller);
        vm.expectRevert(bytes("PEPEO: wrong from"));
        kiln.sell(id);
        assertEq(kiln.reserve(), 5000e18, "nothing paid");
    }

    function test_sell_revertsIfKilnAlreadyHoldsPiece() public {
        seed(5000e18);
        uint256 id = mintPiece(seller);
        vm.prank(seller);
        kiln.sell(id);
        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Kiln.AlreadyHeld.selector, id));
        kiln.sell(id);
    }

    function test_sell_revertsWhenZtoTransferReturnsFalse() public {
        seed(5000e18);
        uint256 id = mintPiece(seller);
        zto.setFailTransfers(true);
        vm.prank(seller);
        vm.expectRevert(Kiln.TransferFailed.selector);
        kiln.sell(id);
    }

    // ------------------------------------------------------------------ buy

    function test_buy_chargesAskAndPieceLeavesInventory() public {
        seed(5000e18);
        uint256 id = mintPiece(seller);
        vm.prank(seller);
        kiln.sell(id);
        uint256 reserveBefore = kiln.reserve();
        uint256 ask = kiln.ask();
        assertEq(ask, 98e18 * 11_500 / 10_000);
        uint256 before = zto.balanceOf(buyer);

        vm.expectEmit(address(kiln));
        emit Kiln.Bought(id, buyer, ask);
        vm.prank(buyer);
        kiln.buy(id);

        assertEq(before - zto.balanceOf(buyer), ask, "buyer paid ask");
        assertEq(kiln.reserve(), reserveBefore + ask);
        assertEq(pepeo.ownerOf(id), buyer);
        assertFalse(kiln.held(id));
        assertEq(kiln.inventory().length, 0);
        assertGt(kiln.bid(), 98e18, "bid rose with the sale");
    }

    function test_buy_revertsForIdNotHeld() public {
        seed(5000e18);
        uint256 id = mintPiece(seller);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Kiln.NotInInventory.selector, id));
        kiln.buy(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Kiln.NotInInventory.selector, 9999));
        kiln.buy(9999);
    }

    function test_buy_revertsSecondTime() public {
        seed(5000e18);
        uint256 id = mintPiece(seller);
        vm.prank(seller);
        kiln.sell(id);
        vm.prank(buyer);
        kiln.buy(id);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Kiln.NotInInventory.selector, id));
        kiln.buy(id);
    }

    function test_buy_revertsWithoutZtoAllowance() public {
        seed(5000e18);
        uint256 id = mintPiece(seller);
        vm.prank(seller);
        kiln.sell(id);
        address stranger = makeAddr("stranger");
        zto.mint(stranger, 1e24);
        vm.prank(stranger);
        vm.expectRevert(bytes("ZTO: allowance"));
        kiln.buy(id);
        assertTrue(kiln.held(id));
    }

    function test_buy_revertsWhenZtoTransferReturnsFalse() public {
        seed(5000e18);
        uint256 id = mintPiece(seller);
        vm.prank(seller);
        kiln.sell(id);
        zto.setFailTransfers(true);
        vm.prank(buyer);
        vm.expectRevert(Kiln.TransferFailed.selector);
        kiln.buy(id);
    }

    function test_buy_collectsClaimsFirst() public {
        seed(5000e18);
        uint256 id = mintPiece(seller);
        vm.prank(seller);
        kiln.sell(id);
        address trader = makeTrader("t0", 0);
        swapAs(trader, true, -1 ether);
        uint256 claims = kiln.claims();
        uint256 reserve = kiln.reserve();
        uint256 ask = (reserve + claims) / 50 * 11_500 / 10_000;
        vm.expectEmit(address(kiln));
        emit Kiln.Collected(claims);
        vm.expectEmit(address(kiln));
        emit Kiln.Bought(id, buyer, ask);
        vm.prank(buyer);
        kiln.buy(id);
        assertEq(kiln.reserve(), reserve + claims + ask);
    }

    // ------------------------------------------------------------------ quotes and price bounds

    /// bid()/ask() read the reserve only; sell()/buy() collect first. quoteBid()/quoteAsk() are what they execute
    /// at, and the bounded overloads let a caller refuse a price that moved between quote and execution.
    function test_quote_includesPendingClaims() public {
        seed(5000e18);
        uint256 id = mintPiece(seller);
        vm.prank(seller);
        kiln.sell(id);
        assertEq(kiln.quoteBid(), kiln.bid(), "nothing pending: quote equals bid");
        assertEq(kiln.quoteAsk(), kiln.ask());

        address trader = makeTrader("t0", 0);
        swapAs(trader, true, -1 ether);
        uint256 claims = kiln.claims();
        assertGt(claims, 0);
        assertEq(kiln.ask(), 98e18 * 11_500 / 10_000, "ask() still reads the reserve only");
        uint256 expectedBid = (4900e18 + claims) / 50;
        assertEq(kiln.quoteBid(), expectedBid);
        assertEq(kiln.quoteAsk(), expectedBid * 11_500 / 10_000);
        assertGt(kiln.quoteAsk(), kiln.ask());

        // buy(id) executes at quoteAsk(), not ask().
        uint256 quoted = kiln.quoteAsk();
        uint256 before = zto.balanceOf(buyer);
        vm.prank(buyer);
        kiln.buy(id);
        assertEq(before - zto.balanceOf(buyer), quoted, "buy charged the quote");
    }

    function test_buy_withMaxPrice() public {
        seed(5000e18);
        uint256 id = mintPiece(seller);
        vm.prank(seller);
        kiln.sell(id);
        uint256 stale = kiln.ask();
        address trader = makeTrader("t0", 0);
        swapAs(trader, true, -1 ether);
        uint256 live = kiln.quoteAsk();
        assertGt(live, stale);

        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Kiln.PriceAboveMax.selector, live, stale));
        kiln.buy(id, stale);
        assertTrue(kiln.held(id), "piece stays");
        assertGt(kiln.claims(), 0, "the revert undid the collect() as well");

        uint256 before = zto.balanceOf(buyer);
        vm.expectEmit(address(kiln));
        emit Kiln.Bought(id, buyer, live);
        vm.prank(buyer);
        kiln.buy(id, live);
        assertEq(before - zto.balanceOf(buyer), live);
        assertEq(pepeo.ownerOf(id), buyer);
    }

    function test_sell_withMinPrice() public {
        seed(5000e18);
        uint256 a = mintPiece(seller);
        uint256 b = mintPiece(seller);
        uint256 quoted = kiln.quoteBid();
        assertEq(quoted, 100e18);
        // A competing sale lands first and lowers the bid.
        vm.prank(seller);
        kiln.sell(a);
        assertEq(kiln.quoteBid(), 98e18);

        vm.prank(seller);
        vm.expectRevert(abi.encodeWithSelector(Kiln.PriceBelowMin.selector, 98e18, quoted));
        kiln.sell(b, quoted);
        assertEq(pepeo.ownerOf(b), seller, "piece stays with the seller");
        assertEq(kiln.reserve(), 4900e18, "nothing paid");

        uint256 before = zto.balanceOf(seller);
        vm.expectEmit(address(kiln));
        emit Kiln.Sold(b, seller, 98e18);
        vm.prank(seller);
        kiln.sell(b, 98e18);
        assertEq(zto.balanceOf(seller) - before, 98e18);
        assertTrue(kiln.held(b));
    }

    function test_boundedOverloads_sameChecksAsPlainOnes() public {
        uint256 id = mintPiece(seller);
        vm.prank(seller);
        vm.expectRevert(Kiln.EmptyReserve.selector);
        kiln.sell(id, 0);
        seed(5000e18);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Kiln.NotInInventory.selector, id));
        kiln.buy(id, type(uint256).max);
    }

    function test_inventory_removalKeepsOtherPieces() public {
        seed(50_000e18);
        uint256 a = mintPiece(seller);
        uint256 b = mintPiece(seller);
        uint256 c = mintPiece(seller);
        vm.startPrank(seller);
        kiln.sell(a);
        kiln.sell(b);
        kiln.sell(c);
        vm.stopPrank();
        vm.prank(buyer);
        kiln.buy(b);
        uint256[] memory inv = kiln.inventory();
        assertEq(inv.length, 2);
        assertTrue(kiln.held(a) && kiln.held(c) && !kiln.held(b));
        assertTrue((inv[0] == a && inv[1] == c) || (inv[0] == c && inv[1] == a));
        vm.prank(buyer);
        kiln.buy(a);
        vm.prank(buyer);
        kiln.buy(c);
        assertEq(kiln.inventory().length, 0);
        assertEq(pepeo.balanceOf(address(kiln)), 0);
    }

    // ------------------------------------------------------------------ seed

    function test_seed_growsBid() public {
        assertEq(kiln.bid(), 0);
        vm.expectEmit(address(kiln));
        emit Kiln.Seeded(seeder, 1000e18);
        seed(1000e18);
        assertEq(kiln.reserve(), 1000e18);
        assertEq(kiln.bid(), 20e18);
        assertEq(kiln.ask(), 23e18);
        seed(1000e18);
        assertEq(kiln.bid(), 40e18);
        assertEq(zto.balanceOf(address(kiln)), 2000e18);
    }

    function test_seed_zeroReverts() public {
        vm.prank(seeder);
        vm.expectRevert(Kiln.ZeroAmount.selector);
        kiln.seed(0);
    }

    function test_seed_revertsWhenTransferReturnsFalse() public {
        zto.setFailTransfers(true);
        vm.prank(seeder);
        vm.expectRevert(Kiln.TransferFailed.selector);
        kiln.seed(1);
    }

    // ------------------------------------------------------------------ caveats and invariants

    function test_plainTransferIsNotInventory() public {
        seed(5000e18);
        uint256 id = mintPiece(seller);
        vm.prank(seller);
        pepeo.transferFrom(seller, address(kiln), id);
        assertEq(pepeo.ownerOf(id), address(kiln));
        assertFalse(kiln.held(id));
        assertEq(kiln.inventory().length, 0);
        assertEq(kiln.reserve(), 5000e18, "nothing paid");
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(Kiln.NotInInventory.selector, id));
        kiln.buy(id);
    }

    function test_directZtoDonationIsNotReserve() public {
        zto.mint(address(kiln), 777e18);
        assertEq(kiln.reserve(), 0);
        assertEq(kiln.bid(), 0);
        uint256 id = mintPiece(seller);
        vm.prank(seller);
        vm.expectRevert(Kiln.EmptyReserve.selector);
        kiln.sell(id);
    }

    function test_nobodyCanWithdraw() public {
        seed(5000e18);
        address trader = makeTrader("t0", 0);
        swapAs(trader, true, -1 ether);
        kiln.collect();
        uint256 balance = zto.balanceOf(address(kiln));
        assertEq(balance, kiln.reserve());

        // No ETH path, no fallback, no admin selectors.
        (bool ok,) = address(kiln).call{value: 1 ether}("");
        assertFalse(ok, "no receive");
        (ok,) = address(kiln).call(abi.encodeWithSignature("withdraw(uint256)", balance));
        assertFalse(ok);
        (ok,) = address(kiln).call(abi.encodeWithSignature("withdraw(address,uint256)", address(this), balance));
        assertFalse(ok);
        (ok,) = address(kiln).call(abi.encodeWithSignature("transferOwnership(address)", address(this)));
        assertFalse(ok);
        (ok,) = address(kiln).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(kiln).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok);

        // The Kiln's claims cannot be moved by anyone else either.
        uint256 id = uint256(uint160(address(zto)));
        swapAs(trader, true, -1 ether);
        uint256 claims = kiln.claims();
        assertGt(claims, 0);
        vm.prank(trader);
        vm.expectRevert();
        manager.transferFrom(address(kiln), trader, id, claims);
        vm.prank(trader);
        vm.expectRevert();
        manager.transfer(trader, id, claims);

        assertEq(zto.balanceOf(address(kiln)), balance, "balance only moves through sell()");
        assertEq(kiln.reserve(), balance);
    }

    /// @notice Random sequences of every public action keep reserve <= ZTO balance and the inventory consistent.
    function testFuzz_reserveNeverExceedsBalance(uint256 seedValue) public {
        seed(2000e18);
        uint256[] memory owned = new uint256[](0);
        address[6] memory traders;
        for (uint256 t; t < 6; ++t) {
            traders[t] = makeTrader(string.concat("f", vm.toString(t)), tierPieces[t]);
        }
        for (uint256 step; step < 24; ++step) {
            uint256 r = uint256(keccak256(abi.encode(seedValue, step)));
            uint256 action = r % 7;
            address trader = traders[(r >> 8) % 6];
            if (action == 0) {
                swapAs(trader, true, -int256(1 ether + (r >> 16) % 1 ether));
            } else if (action == 1) {
                swapAs(trader, false, -int256(100_000e18 + (r >> 16) % 900_000e18));
            } else if (action == 2) {
                swapAs(trader, true, int256(100_000e18 + (r >> 16) % 900_000e18));
            } else if (action == 3) {
                kiln.collect();
            } else if (action == 4) {
                seed(1 + (r >> 16) % 1000e18);
            } else if (action == 5) {
                if (kiln.bid() > 0) {
                    uint256 id = mintPiece(seller);
                    vm.prank(seller);
                    kiln.sell(id);
                }
            } else {
                uint256[] memory inv = kiln.inventory();
                if (inv.length > 0) {
                    uint256 id = inv[(r >> 16) % inv.length];
                    vm.prank(buyer);
                    kiln.buy(id);
                }
            }
            assertLe(kiln.reserve(), zto.balanceOf(address(kiln)), "reserve <= balance");
            assertEq(kiln.inventory().length, pepeo.balanceOf(address(kiln)), "inventory == held pieces");
            assertEq(manager.balanceOf(address(kiln), uint256(uint160(address(zto)))), kiln.claims(), "claims");
        }
        owned;
    }
}
