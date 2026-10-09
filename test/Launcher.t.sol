// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {Launcher} from "../src/Launcher.sol";
import {Kiln} from "../src/Kiln.sol";
import {MockZTO} from "./mocks/MockZTO.sol";
import {MockPepeo} from "./mocks/MockPepeo.sol";

/// @notice Launcher: CREATE2 deployment of the Kiln at the mined salt, the hook-bit check, one-shot open() and
///         pool initialization on the real PoolManager.
contract LauncherTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    uint160 internal constant FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    IPoolManager internal manager;
    MockZTO internal zto;
    MockPepeo internal pepeo;
    Launcher internal launcher;
    uint160 internal openPrice = TickMath.getSqrtPriceAtTick(138_180);

    function setUp() public {
        manager = new PoolManager(address(this));
        zto = new MockZTO();
        pepeo = new MockPepeo();
        launcher = new Launcher(address(zto), address(pepeo), address(manager));
    }

    function args() internal view returns (bytes memory) {
        return abi.encode(address(zto), address(pepeo), address(manager));
    }

    function goodSalt() internal view returns (address predicted, bytes32 salt) {
        (predicted, salt) = HookMiner.find(address(launcher), FLAGS, type(Kiln).creationCode, args());
    }

    function badSalt() internal view returns (address predicted, bytes32 salt) {
        for (uint256 s;; ++s) {
            predicted = launcher.kilnAddress(bytes32(s));
            if (uint160(predicted) & Hooks.ALL_HOOK_MASK != FLAGS) return (predicted, bytes32(s));
        }
    }

    function test_constructor_storesAddressesAndRejectsZero() public {
        assertEq(launcher.ZTO(), address(zto));
        assertEq(launcher.PEPEO(), address(pepeo));
        assertEq(launcher.POOL_MANAGER(), address(manager));
        assertEq(address(launcher.kiln()), address(0));
        vm.expectRevert(Launcher.ZeroAddress.selector);
        new Launcher(address(0), address(pepeo), address(manager));
        vm.expectRevert(Launcher.ZeroAddress.selector);
        new Launcher(address(zto), address(0), address(manager));
        vm.expectRevert(Launcher.ZeroAddress.selector);
        new Launcher(address(zto), address(pepeo), address(0));
    }

    function test_initCodeHash_matchesCreationCodeWithArgs() public view {
        bytes32 expected = keccak256(abi.encodePacked(type(Kiln).creationCode, args()));
        assertEq(launcher.initCodeHash(), expected);
        (address predicted, bytes32 salt) = goodSalt();
        assertEq(launcher.kilnAddress(salt), predicted);
        assertEq(
            predicted,
            address(
                uint160(
                    uint256(keccak256(abi.encodePacked(bytes1(0xff), address(launcher), salt, launcher.initCodeHash())))
                )
            )
        );
    }

    function test_open_deploysKilnAtMinedAddressAndInitializesPool() public {
        (address predicted, bytes32 salt) = goodSalt();
        PoolKey memory expectedKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(zto)),
            fee: 2000,
            tickSpacing: 60,
            hooks: IHooks(predicted)
        });
        PoolId expectedId = expectedKey.toId();

        vm.expectEmit(address(launcher));
        emit Launcher.Opened(predicted, expectedId);
        vm.prank(makeAddr("anyone"));
        (address kilnAddr, PoolId id) = launcher.open(salt, openPrice);

        assertEq(kilnAddr, predicted);
        assertEq(PoolId.unwrap(id), PoolId.unwrap(expectedId));
        assertEq(address(launcher.kiln()), predicted);
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, FLAGS, "exactly the four swap bits");
        assertEq(uint160(predicted) & Hooks.ALL_HOOK_MASK, 0xCC);

        Kiln kiln = Kiln(predicted);
        assertEq(address(kiln.ZTO()), address(zto));
        assertEq(address(kiln.PEPEO()), address(pepeo));
        assertEq(address(kiln.POOL_MANAGER()), address(manager));
        assertEq(kiln.HOOK_FLAGS(), FLAGS);
        PoolKey memory key = kiln.poolKey();
        assertEq(PoolId.unwrap(key.toId()), PoolId.unwrap(expectedId));

        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        assertEq(sqrtPriceX96, openPrice);
        assertEq(tick, 138_180);
        assertEq(protocolFee, 0);
        assertEq(lpFee, 2000);
        assertEq(manager.getLiquidity(id), 0, "launcher adds no liquidity");
    }

    function test_open_revertsWhenAddressBitsAreWrong_thenSucceedsWithGoodSalt() public {
        (address wrong, bytes32 bad) = badSalt();
        vm.expectRevert(abi.encodeWithSelector(Launcher.WrongHookAddress.selector, wrong));
        launcher.open(bad, openPrice);
        assertEq(address(launcher.kiln()), address(0), "still closed");

        (address predicted, bytes32 salt) = goodSalt();
        launcher.open(salt, openPrice);
        assertEq(address(launcher.kiln()), predicted);
    }

    function test_open_revertsWhenPoolInitFails_thenSucceeds() public {
        (address predicted, bytes32 salt) = goodSalt();
        vm.expectRevert();
        launcher.open(salt, 0);
        assertEq(address(launcher.kiln()), address(0), "deployment rolled back");
        launcher.open(salt, openPrice);
        assertEq(address(launcher.kiln()), predicted);
    }

    function test_open_onlyOnce() public {
        (, bytes32 salt) = goodSalt();
        launcher.open(salt, openPrice);
        vm.expectRevert(Launcher.AlreadyOpened.selector);
        launcher.open(salt, openPrice);
        // Nor with a different salt or price.
        vm.expectRevert(Launcher.AlreadyOpened.selector);
        launcher.open(bytes32(uint256(salt) + 1), openPrice + 1);
    }

    function test_kilnConstructor_doesNotValidateItsAddress() public {
        // Plain `new` gives an address with arbitrary low bits; the Kiln still constructs.
        Kiln loose = new Kiln(address(zto), address(pepeo), address(manager));
        assertEq(address(loose.POOL_MANAGER()), address(manager));
        PoolKey memory key = loose.poolKey();
        assertEq(address(key.hooks), address(loose));
        assertEq(Currency.unwrap(key.currency1), address(zto));
        assertEq(loose.DEPTH(), 50);
        assertEq(loose.SPREAD_BPS(), 1500);
        assertEq(loose.LP_FEE(), 2000);
        assertEq(loose.TICK_SPACING(), 60);
        assertEq(loose.ZTO_DECIMALS(), 18);
        assertEq(loose.TIER_COUNT(), 6);
    }

    function test_kiln_runtimeIsSmallAndHasNoEscapeOpcodes() public {
        (address predicted, bytes32 salt) = goodSalt();
        launcher.open(salt, openPrice);
        bytes memory kilnCode = predicted.code;
        assertGt(kilnCode.length, 0);
        assertLt(kilnCode.length, 12_000, "Kiln runtime under 12,000 bytes");
        _assertNoEscapeOpcodes(kilnCode);
        bytes memory launcherCode = address(launcher).code;
        assertLe(launcherCode.length, 24_576);
        _assertNoEscapeOpcodes(launcherCode);
    }

    /// @dev Same scan as the deployment probe: no DELEGATECALL, CALLCODE or SELFDESTRUCT outside push data.
    function _assertNoEscapeOpcodes(bytes memory code) internal pure {
        for (uint256 j; j < code.length; ++j) {
            uint8 op = uint8(code[j]);
            if (op >= 0x60 && op <= 0x7f) {
                j += op - 0x5f;
                continue;
            }
            assertTrue(op != 0xf4 && op != 0xf2 && op != 0xff, "forbidden opcode");
        }
    }
}
