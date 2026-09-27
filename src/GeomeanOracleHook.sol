// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {BaseOracleHook} from "@openzeppelin/uniswap-hooks/oracles/panoptic/BaseOracleHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

/// @notice Standard and truncated geometric price oracle, recorded before swaps by the OZ base.
/// @dev Inherits only afterInitialize and beforeSwap, both PoolManager-only. No hook deltas or fees.
contract GeomeanOracleHook is BaseOracleHook {
    error ZeroWindow();

    /// @param manager The PoolManager; on Sepolia, 0xE03A1074c86CFeDd5C142C4F04F1a1536e203543.
    constructor(IPoolManager manager) BaseHook(manager) BaseOracleHook(9_116) {}

    /// @notice Mean ticks over [now - secondsAgo, now], rounded toward negative infinity.
    /// @dev Reverts for zero windows, uninitialized pools, or insufficient retained history.
    /// The inherited observe() returns the same two cumulative series for arbitrary sample ages.
    function consult(PoolId poolId, uint32 secondsAgo) external view returns (int24 meanTick, int24 truncatedMeanTick) {
        if (secondsAgo == 0) revert ZeroWindow();
        if (stateById[poolId].cardinality == 0) revert PoolNotInitialized();

        uint32[] memory ages = new uint32[](2);
        ages[0] = secondsAgo;
        (int56[] memory standard, int56[] memory truncated) = this.observe(ages, poolId);

        // Cumulatives intentionally wrap at int56, as in the inherited oracle. Any uint32
        // window at a valid v4 tick fits in int56, so modular subtraction recovers its delta.
        unchecked {
            meanTick = _mean(standard[1] - standard[0], secondsAgo);
            truncatedMeanTick = _mean(truncated[1] - truncated[0], secondsAgo);
        }
    }

    /// @notice Current ring index, capacity, and requested capacity for this pool.
    /// @dev Capacity includes preallocated slots that have not yet received observations.
    function observationState(PoolId poolId)
        external
        view
        returns (uint16 index, uint16 cardinality, uint16 cardinalityNext)
    {
        ObservationState memory state = stateById[poolId];
        return (state.index, state.cardinality, state.cardinalityNext);
    }

    function _mean(int56 delta, uint32 window) private pure returns (int24 result) {
        int56 duration = int56(uint56(window));
        // A time-weighted mean of valid v4 ticks remains within [-887272, 887272].
        // forge-lint: disable-next-line(unsafe-typecast)
        result = int24(delta / duration);
        if (delta < 0 && delta % duration != 0) --result;
    }
}
