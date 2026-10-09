// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, BalanceDeltaLibrary} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";

/// @notice The subset of ERC-721 the Kiln uses on Pepeolithic. `transferFrom` only, never `safeTransferFrom`.
interface IPepeolithic {
    function balanceOf(address owner) external view returns (uint256);
    function ownerOf(uint256 id) external view returns (address);
    function transferFrom(address from, address to, uint256 id) external;
}

/// @title Kiln
/// @notice Uniswap v4 hook for the ETH/ZTO pool. Wallets holding Pepeolithic (PEPEO) pieces pay a lower Kiln cut on
///         every swap; the cut is always taken in ZTO and parked as ERC-6909 claims until `collect()` turns it into a
///         real ZTO reserve. The reserve buys PEPEO pieces from anyone at `bid()` and sells them back at `ask()`.
/// @dev No owner, no admin, no pause, no upgrade. ZTO only ever leaves through `sell()`. Pieces only ever leave
///      through `buy()`. The hook has no liquidity callbacks, so any range position can be added or removed freely.
///      The constructor makes no external call and does not validate its own address bits: the Launcher does.
contract Kiln is IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using BalanceDeltaLibrary for BalanceDelta;
    using SafeCast for uint256;

    // ------------------------------------------------------------------ constants

    /// @notice ZTO has 18 decimals. Written as a constant as the brief requires; the Kiln never calls `decimals()`.
    uint8 public constant ZTO_DECIMALS = 18;
    /// @notice Static pool fee paid to liquidity on every swap, in hundredths of a bip (0.20%).
    uint24 public constant LP_FEE = 2000;
    /// @notice Pool tick spacing.
    int24 public constant TICK_SPACING = 60;
    /// @notice ask() = bid() * (10000 + SPREAD_BPS) / 10000.
    uint256 public constant SPREAD_BPS = 1500;
    /// @notice bid() = reserve / DEPTH.
    uint256 public constant DEPTH = 50;
    /// @notice Number of pass tiers.
    uint256 public constant TIER_COUNT = 6;
    /// @notice Hook permission bits the Kiln's address must carry: beforeSwap, afterSwap and both swap return deltas.
    uint160 public constant HOOK_FLAGS = Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;

    uint256 internal constant BPS = 10_000;
    uint256 internal constant PIPS = 1_000_000;

    // Tier table: the highest tier whose minPepes <= pepes applies. kilnCut in hundredths of a bip.
    uint256 internal constant MIN_PEPES_1 = 1;
    uint256 internal constant MIN_PEPES_2 = 3;
    uint256 internal constant MIN_PEPES_3 = 7;
    uint256 internal constant MIN_PEPES_4 = 12;
    uint256 internal constant MIN_PEPES_5 = 21;
    uint24 internal constant CUT_0 = 13_000; // 1.30%
    uint24 internal constant CUT_1 = 10_000; // 1.00%
    uint24 internal constant CUT_2 = 7_500; // 0.75%
    uint24 internal constant CUT_3 = 5_000; // 0.50%
    uint24 internal constant CUT_4 = 2_500; // 0.25%
    uint24 internal constant CUT_5 = 0; // 0%

    // ------------------------------------------------------------------ immutables

    /// @notice The ZTO token (currency1 of the pool).
    IERC20Minimal public immutable ZTO;
    /// @notice The Pepeolithic ERC-721.
    IPepeolithic public immutable PEPEO;
    /// @notice The Uniswap v4 PoolManager.
    IPoolManager public immutable POOL_MANAGER;
    /// @dev Id of the one pool this hook serves. Computed in the constructor from constants, no external call.
    bytes32 internal immutable POOL_ID;

    // ------------------------------------------------------------------ state

    /// @notice ZTO cut still held as ERC-6909 claims inside the PoolManager, pending `collect()`.
    uint256 public claims;
    /// @notice Real ZTO held for pieces. Always <= ZTO.balanceOf(this).
    uint256 public reserve;
    uint256[] internal _inventory;
    /// @dev id => index in `_inventory` plus one; zero means not held.
    mapping(uint256 => uint256) internal _slot;

    // ------------------------------------------------------------------ events

    event Passed(address indexed trader, uint256 pepes, uint24 kilnCut, uint256 ztoTaken);
    event Collected(uint256 amount);
    event Sold(uint256 indexed id, address indexed seller, uint256 price);
    event Bought(uint256 indexed id, address indexed buyer, uint256 price);
    event Seeded(address indexed from, uint256 amount);

    // ------------------------------------------------------------------ errors

    error NotPoolManager();
    error NotKilnPool();
    error EmptyReserve();
    error ZeroAmount();
    error AlreadyHeld(uint256 id);
    error NotInInventory(uint256 id);
    error NoSuchTier(uint256 index);
    error PieceNotReceived(uint256 id);
    error TransferFailed();

    // ------------------------------------------------------------------ constructor

    constructor(address zto, address pepeo, address poolManager) {
        ZTO = IERC20Minimal(zto);
        PEPEO = IPepeolithic(pepeo);
        POOL_MANAGER = IPoolManager(poolManager);
        POOL_ID = PoolId.unwrap(_poolKey(zto).toId());
    }

    // ------------------------------------------------------------------ views

    /// @notice The key of the ETH/ZTO pool this hook serves.
    function poolKey() external view returns (PoolKey memory) {
        return _poolKey(address(ZTO));
    }

    /// @notice The id of the ETH/ZTO pool this hook serves.
    function poolId() external view returns (PoolId) {
        return PoolId.wrap(POOL_ID);
    }

    /// @notice ZTO paid for a piece on `sell()`: reserve / DEPTH, so it is always payable from real ZTO.
    function bid() public view returns (uint256) {
        return reserve / DEPTH;
    }

    /// @notice ZTO charged for a piece on `buy()`: bid plus the spread.
    function ask() public view returns (uint256) {
        return bid() * (BPS + SPREAD_BPS) / BPS;
    }

    /// @notice Ids currently held and purchasable.
    function inventory() external view returns (uint256[] memory) {
        return _inventory;
    }

    /// @notice Whether `id` is in inventory.
    function held(uint256 id) external view returns (bool) {
        return _slot[id] != 0;
    }

    /// @notice Tier table entry `index` (0..TIER_COUNT-1).
    function tier(uint256 index) external pure returns (uint256 minPepes, uint24 kilnCut) {
        if (index == 0) return (0, CUT_0);
        if (index == 1) return (MIN_PEPES_1, CUT_1);
        if (index == 2) return (MIN_PEPES_2, CUT_2);
        if (index == 3) return (MIN_PEPES_3, CUT_3);
        if (index == 4) return (MIN_PEPES_4, CUT_4);
        if (index == 5) return (MIN_PEPES_5, CUT_5);
        revert NoSuchTier(index);
    }

    /// @notice The pass tier `wallet` would get right now, from its live PEPEO balance.
    function tierOf(address wallet) external view returns (uint256 index, uint256 pepes, uint24 kilnCut) {
        pepes = PEPEO.balanceOf(wallet);
        (index, kilnCut) = _tierFor(pepes);
    }

    // ------------------------------------------------------------------ hook callbacks

    /// @notice Takes the Kiln cut up front when ZTO is the specified currency: ZTO-in exact-input (from the input)
    ///         and ETH-in exact-output (from the ZTO output). Otherwise defers to `afterSwap`.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata params, bytes calldata)
        external
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _onlyKilnPool(key);
        if (!_ztoIsSpecified(params)) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);

        uint256 amount = params.amountSpecified < 0 ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        uint256 cut = _takeCut(amount);
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(cut.toInt128(), 0), 0);
    }

    /// @notice Takes the Kiln cut when ZTO is the unspecified currency: ETH-in exact-input (from the ZTO output) and
    ///         ZTO-in exact-output (from the ZTO input). Returns zero when `beforeSwap` already took it.
    function afterSwap(
        address,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external returns (bytes4, int128) {
        _onlyKilnPool(key);
        if (_ztoIsSpecified(params)) return (IHooks.afterSwap.selector, 0);

        int128 amount1 = delta.amount1();
        uint256 amount = amount1 < 0 ? uint256(uint128(-amount1)) : uint256(uint128(amount1));
        uint256 cut = _takeCut(amount);
        return (IHooks.afterSwap.selector, cut.toInt128());
    }

    /// @notice PoolManager callback used by `collect()`: burn the Kiln's ZTO claims and take real ZTO.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        POOL_MANAGER.burn(address(this), _ztoId(), amount);
        POOL_MANAGER.take(Currency.wrap(address(ZTO)), address(this), amount);
        return "";
    }

    // ------------------------------------------------------------------ reserve and pieces

    /// @notice Burns the Kiln's whole ZTO claim balance in the PoolManager and moves the real ZTO into `reserve`.
    ///         Permissionless. Harmless no-op when there is nothing to collect.
    function collect() public {
        uint256 amount = POOL_MANAGER.balanceOf(address(this), _ztoId());
        if (amount == 0) return;
        claims = 0;
        reserve += amount;
        emit Collected(amount);
        POOL_MANAGER.unlock(abi.encode(amount));
    }

    /// @notice Sells piece `id` to the Kiln for `bid()`. The caller must have approved the Kiln on PEPEO first.
    function sell(uint256 id) external {
        collect();
        uint256 price = bid();
        if (price == 0) revert EmptyReserve();
        if (_slot[id] != 0) revert AlreadyHeld(id);
        reserve -= price;
        _inventory.push(id);
        _slot[id] = _inventory.length;
        emit Sold(id, msg.sender, price);
        PEPEO.transferFrom(msg.sender, address(this), id);
        if (PEPEO.ownerOf(id) != address(this)) revert PieceNotReceived(id);
        if (!ZTO.transfer(msg.sender, price)) revert TransferFailed();
    }

    /// @notice Buys piece `id` from the Kiln for `ask()`. The caller must have approved the Kiln on ZTO first.
    function buy(uint256 id) external {
        collect();
        uint256 index = _slot[id];
        if (index == 0) revert NotInInventory(id);
        uint256 price = ask();
        if (price == 0) revert EmptyReserve();
        reserve += price;
        uint256 last = _inventory[_inventory.length - 1];
        _inventory[index - 1] = last;
        _slot[last] = index;
        _inventory.pop();
        delete _slot[id];
        emit Bought(id, msg.sender, price);
        if (!ZTO.transferFrom(msg.sender, address(this), price)) revert TransferFailed();
        PEPEO.transferFrom(address(this), msg.sender, id);
    }

    /// @notice Adds `amount` ZTO from the caller to the reserve. The caller must have approved the Kiln on ZTO first.
    function seed(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        reserve += amount;
        emit Seeded(msg.sender, amount);
        if (!ZTO.transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
    }

    // ------------------------------------------------------------------ internals

    function _poolKey(address zto) internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(zto),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(this))
        });
    }

    function _ztoId() internal view returns (uint256) {
        return uint256(uint160(address(ZTO)));
    }

    function _onlyKilnPool(PoolKey calldata key) internal view {
        if (msg.sender != address(POOL_MANAGER)) revert NotPoolManager();
        if (PoolId.unwrap(key.toId()) != POOL_ID) revert NotKilnPool();
    }

    /// @dev ZTO (currency1) is the specified currency for ZTO-in exact-input and ETH-in exact-output.
    function _ztoIsSpecified(IPoolManager.SwapParams calldata params) internal pure returns (bool) {
        return params.zeroForOne != (params.amountSpecified < 0);
    }

    function _tierFor(uint256 pepes) internal pure returns (uint256 index, uint24 kilnCut) {
        if (pepes >= MIN_PEPES_5) return (5, CUT_5);
        if (pepes >= MIN_PEPES_4) return (4, CUT_4);
        if (pepes >= MIN_PEPES_3) return (3, CUT_3);
        if (pepes >= MIN_PEPES_2) return (2, CUT_2);
        if (pepes >= MIN_PEPES_1) return (1, CUT_1);
        return (0, CUT_0);
    }

    /// @dev Reads the trader's pass, computes the cut on `ztoAmount`, mints it to the Kiln as ERC-6909 ZTO claims
    ///      and records it. Emits Passed exactly once per swap (each swap reaches this from one callback only).
    function _takeCut(uint256 ztoAmount) internal returns (uint256 cut) {
        uint256 pepes = PEPEO.balanceOf(tx.origin);
        (, uint24 kilnCut) = _tierFor(pepes);
        cut = ztoAmount * kilnCut / PIPS;
        emit Passed(tx.origin, pepes, kilnCut, cut);
        if (cut != 0) {
            claims += cut;
            POOL_MANAGER.mint(address(this), _ztoId(), cut);
        }
    }
}
