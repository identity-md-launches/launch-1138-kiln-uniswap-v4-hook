// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Kiln} from "./Kiln.sol";

/// @title Launcher
/// @notice Deploys the Kiln hook with CREATE2 at a salt mined off-chain and initializes the ETH/ZTO pool on the
///         Uniswap v4 PoolManager with the Kiln as its hook. `open()` succeeds exactly once. No owner, no admin.
/// @dev The constructor stores three addresses and makes no external call, so it deploys on an empty chain.
contract Launcher {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /// @notice The ZTO token, currency1 of the pool.
    address public immutable ZTO;
    /// @notice The Pepeolithic ERC-721 whose holders get a pass.
    address public immutable PEPEO;
    /// @notice The Uniswap v4 PoolManager.
    address public immutable POOL_MANAGER;

    /// @notice The Kiln once `open()` has run; zero before.
    Kiln public kiln;

    event Opened(address indexed kiln, PoolId poolId);
    /// @notice Somebody initialized the pool key for the predicted Kiln address before `open()` ran. The pool was
    ///         adopted at `liveSqrtPriceX96` and `requestedSqrtPriceX96` was ignored.
    event Preinitialized(PoolId indexed poolId, uint160 liveSqrtPriceX96, uint160 requestedSqrtPriceX96);

    error ZeroAddress();
    error AlreadyOpened();
    error WrongHookAddress(address kiln);

    constructor(address zto, address pepeo, address poolManager) {
        if (zto == address(0) || pepeo == address(0) || poolManager == address(0)) revert ZeroAddress();
        ZTO = zto;
        PEPEO = pepeo;
        POOL_MANAGER = poolManager;
    }

    /// @notice keccak256 of the Kiln init code with its constructor arguments, for mining `salt` off-chain:
    ///         kiln = address(keccak256(0xff ++ launcher ++ salt ++ initCodeHash())[12:]), and its low 14 bits
    ///         must equal `Kiln.HOOK_FLAGS` (0xCC).
    function initCodeHash() external view returns (bytes32) {
        return keccak256(bytes.concat(type(Kiln).creationCode, abi.encode(ZTO, PEPEO, POOL_MANAGER)));
    }

    /// @notice The address `open(salt, ...)` would deploy the Kiln at.
    function kilnAddress(bytes32 salt) external view returns (address) {
        bytes32 hash = keccak256(bytes.concat(type(Kiln).creationCode, abi.encode(ZTO, PEPEO, POOL_MANAGER)));
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, hash)))));
    }

    /// @notice Deploys the Kiln at `salt`, checks its address carries exactly the swap hook bits, and initializes
    ///         the ETH/ZTO pool (lpFee 2000, tickSpacing 60, Kiln as hook) at `sqrtPriceX96`. Permissionless,
    ///         succeeds once. Adds no liquidity: the deployer adds a ZTO-only range position afterwards.
    /// @dev The pool key is predictable from the salt and anyone may initialize it on the PoolManager before the
    ///      Kiln exists (the Kiln has no initialize hook bits, so no hook call stops them). Reverting there would
    ///      let a griefer block every salt the deployer mines, so an already-initialized pool is adopted at its
    ///      live price instead and `Preinitialized` reports it. Check slot0 before adding liquidity.
    function open(bytes32 salt, uint160 sqrtPriceX96) external returns (address kilnAddr, PoolId poolId) {
        if (address(kiln) != address(0)) revert AlreadyOpened();
        Kiln deployed = new Kiln{salt: salt}(ZTO, PEPEO, POOL_MANAGER);
        kilnAddr = address(deployed);
        if (uint160(kilnAddr) & Hooks.ALL_HOOK_MASK != deployed.HOOK_FLAGS()) revert WrongHookAddress(kilnAddr);
        kiln = deployed;
        PoolKey memory key = deployed.poolKey();
        poolId = key.toId();
        (uint160 livePrice,,,) = IPoolManager(POOL_MANAGER).getSlot0(poolId);
        if (livePrice == 0) {
            IPoolManager(POOL_MANAGER).initialize(key, sqrtPriceX96);
        } else {
            emit Preinitialized(poolId, livePrice, sqrtPriceX96);
        }
        emit Opened(kilnAddr, poolId);
    }
}
