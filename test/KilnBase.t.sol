// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {FixedPoint128} from "v4-core/src/libraries/FixedPoint128.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {HookMiner} from "v4-periphery/test/shared/HookMiner.sol";

import {Launcher} from "../src/Launcher.sol";
import {Kiln} from "../src/Kiln.sol";
import {MockZTO} from "./mocks/MockZTO.sol";
import {MockPepeo} from "./mocks/MockPepeo.sol";

/// @notice Shared fixture: real v4 PoolManager, mock ZTO and PEPEO, Launcher opened at a mined salt, a ZTO-only
///         range position added through the v4-core liquidity test router, and a priming ETH-in swap by a
///         21-piece wallet (no cut) so the range holds ETH for the ZTO-in cases.
abstract contract KilnBase is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using BalanceDeltaLibrary for BalanceDelta;

    uint160 internal constant FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
    uint24 internal constant LP_FEE = 2000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant PIPS = 1_000_000;
    // Opening tick: ~1,000,000 ZTO per ETH. The position sits entirely below it, so it is ZTO-only.
    int24 internal constant OPEN_TICK = 138_180;
    int24 internal constant RANGE_LOWER = OPEN_TICK - 6000;
    int128 internal constant RANGE_LIQUIDITY = 1e24;
    uint256 internal constant PRIME_ETH = 20 ether;

    bytes32 internal constant PASSED_SIG = keccak256("Passed(address,uint256,uint24,uint256)");

    IPoolManager internal manager;
    MockZTO internal zto;
    MockPepeo internal pepeo;
    Launcher internal launcher;
    Kiln internal kiln;
    PoolKey internal key;
    PoolId internal poolId;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal lpRouter;
    bytes32 internal salt;
    uint160 internal openPrice;

    address internal lp = makeAddr("lp");
    address internal whale;
    uint256 internal nextPieceId = 1;

    uint256[6] internal tierPieces = [uint256(0), 1, 3, 7, 12, 21];
    uint24[6] internal tierCuts = [uint24(13_000), 10_000, 7_500, 5_000, 2_500, 0];

    function setUp() public virtual {
        manager = new PoolManager(address(this));
        zto = new MockZTO();
        pepeo = new MockPepeo();
        launcher = new Launcher(address(zto), address(pepeo), address(manager));
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);

        openPrice = TickMath.getSqrtPriceAtTick(OPEN_TICK);
        address predicted;
        (predicted, salt) = HookMiner.find(
            address(launcher),
            FLAGS,
            type(Kiln).creationCode,
            abi.encode(address(zto), address(pepeo), address(manager))
        );
        launcher.open(salt, openPrice);
        kiln = launcher.kiln();
        assertEq(address(kiln), predicted, "kiln address");
        key = kiln.poolKey();
        poolId = key.toId();

        // ZTO-only range position below the opening tick (ZTO priced above the opening price).
        zto.mint(lp, 1e27);
        vm.startPrank(lp);
        zto.approve(address(lpRouter), type(uint256).max);
        BalanceDelta lpDelta = lpRouter.modifyLiquidity(
            key,
            IPoolManager.ModifyLiquidityParams({
                tickLower: RANGE_LOWER, tickUpper: OPEN_TICK, liquidityDelta: RANGE_LIQUIDITY, salt: bytes32(0)
            }),
            ""
        );
        vm.stopPrank();
        assertEq(lpDelta.amount0(), 0, "position must be ZTO-only");
        assertLt(lpDelta.amount1(), 0, "position must take ZTO");

        // Prime the range with ETH using a wallet that pays no cut.
        whale = makeTrader("whale", 21);
        swapAs(whale, true, -int256(PRIME_ETH));
        assertEq(kiln.claims(), 0, "priming must leave no claims");
    }

    // ------------------------------------------------------------------ helpers

    function makeTrader(string memory label, uint256 pieces) internal returns (address trader) {
        trader = makeAddr(label);
        vm.deal(trader, 1000 ether);
        zto.mint(trader, 1e26);
        vm.startPrank(trader);
        zto.approve(address(swapRouter), type(uint256).max);
        zto.approve(address(kiln), type(uint256).max);
        pepeo.setApprovalForAll(address(kiln), true);
        vm.stopPrank();
        for (uint256 i; i < pieces; ++i) {
            pepeo.mint(trader, nextPieceId++);
        }
    }

    function mintPiece(address to) internal returns (uint256 id) {
        id = nextPieceId++;
        pepeo.mint(to, id);
    }

    /// @dev Swaps with msg.sender and tx.origin both set to `trader`, as a router-fronted trade would look.
    function swapAs(address trader, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta delta) {
        uint256 value;
        if (zeroForOne) value = amountSpecified < 0 ? uint256(-amountSpecified) : 200 ether;
        vm.prank(trader, trader);
        delta = swapRouter.swap{value: value}(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    /// @dev Finds the single Passed log in `logs` and decodes it.
    function findPassed(Vm.Log[] memory logs)
        internal
        view
        returns (address trader, uint256 pepes, uint24 kilnCut, uint256 ztoTaken)
    {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(kiln) && logs[i].topics[0] == PASSED_SIG) {
                ++found;
                trader = address(uint160(uint256(logs[i].topics[1])));
                (pepes, kilnCut, ztoTaken) = abi.decode(logs[i].data, (uint256, uint24, uint256));
            }
        }
        assertEq(found, 1, "exactly one Passed per swap");
    }

    /// @dev Fees accrued to LPs in `currency` since `before`, from the pool's fee growth and active liquidity.
    function lpFeeAccrued(uint256 before0, uint256 before1, bool inputIsEth) internal view returns (uint256) {
        (uint256 after0, uint256 after1) = manager.getFeeGrowthGlobals(poolId);
        uint256 growth = inputIsEth ? after0 - before0 : after1 - before1;
        uint128 liquidity = manager.getLiquidity(poolId);
        return FullMath.mulDiv(growth, liquidity, FixedPoint128.Q128);
    }

    function abs(int128 x) internal pure returns (uint256) {
        return x < 0 ? uint256(uint128(-x)) : uint256(uint128(x));
    }
}
