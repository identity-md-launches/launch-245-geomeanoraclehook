// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Oracle} from "@openzeppelin/uniswap-hooks/oracles/panoptic/libraries/Oracle.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {GeomeanOracleHook} from "../src/GeomeanOracleHook.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

/// @dev Only a test fixture can inject cumulatives near int56 limits; production has no such setter.
contract CumulativeWrapFixture is GeomeanOracleHook {
    constructor(IPoolManager manager) GeomeanOracleHook(manager) {}

    function setCumulative(PoolId id, int56 start) external {
        observationsById[id][0].tickCumulative = start;
        observationsById[id][0].tickCumulativeTruncated = start;
    }
}

contract OracleArithmeticTest is Test {
    function testFuzz_TruncationMatchesWideArithmetic(
        int24 previous,
        int24 tick,
        uint32 start,
        uint32 elapsed,
        int56 cumulative
    ) public pure {
        previous = int24(bound(int256(previous), TickMath.MIN_TICK, TickMath.MAX_TICK));
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK));
        Oracle.Observation memory old = Oracle.Observation(start, previous, cumulative, cumulative, true);
        uint32 end;
        unchecked {
            end = start + elapsed;
        }
        Oracle.Observation memory observed = Oracle.transform(old, end, tick, 9_116);
        // Compute independently in int256, then deliberately narrow modulo 2**56.
        int256 change = int256(tick) - int256(previous);
        if (change > 9_116) change = 9_116;
        if (change < -9_116) change = -9_116;
        int256 clipped = int256(previous) + change;
        assertEq(observed.prevTruncatedTick, clipped);
        assertEq(observed.tickCumulative, int56(int256(cumulative) + int256(tick) * int256(uint256(elapsed))));
        assertEq(observed.tickCumulativeTruncated, int56(int256(cumulative) + clipped * int256(uint256(elapsed))));
        assertEq(observed.blockTimestamp, end);
        assertTrue(observed.initialized);
        assertLe(observed.prevTruncatedTick, TickMath.MAX_TICK);
        assertGe(observed.prevTruncatedTick, TickMath.MIN_TICK);
    }

    function testFuzz_ConsultHandlesCumulativeOverflowAndNegativeRounding(int24 tick, uint32 window) public {
        tick = int24(bound(int256(tick), TickMath.MIN_TICK, TickMath.MAX_TICK - 1));
        window = uint32(bound(window, 1, type(uint32).max));
        vm.warp(10);
        PoolManager manager = new PoolManager(address(this));
        address target = address(uint160((0x5555 << 144) | 0x1080));
        deployCodeTo("OracleArithmetic.t.sol:CumulativeWrapFixture", abi.encode(manager), target);
        CumulativeWrapFixture oracle = CumulativeWrapFixture(target);
        PoolKey memory pool = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(1)), 3000, 60, IHooks(target));
        manager.initialize(pool, TickMath.getSqrtPriceAtTick(tick));
        oracle.setCumulative(pool.toId(), tick < 0 ? type(int56).min + 1 : type(int56).max - 1);
        vm.warp(uint256(window) + 10);
        (int24 mean, int24 truncated) = oracle.consult(pool.toId(), window);
        assertEq(mean, tick);
        assertEq(truncated, tick);
    }
}
