// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHookTest} from "./BaseHookTest.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {BaseOracleHook} from "@openzeppelin/uniswap-hooks/oracles/panoptic/BaseOracleHook.sol";
import {Oracle} from "@openzeppelin/uniswap-hooks/oracles/panoptic/libraries/Oracle.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {GeomeanOracleHook} from "../src/GeomeanOracleHook.sol";
import {Geomean} from "../src/Geomean.sol";

contract GeomeanOracleHookTest is BaseHookTest {
    using StateLibrary for IPoolManager;

    GeomeanOracleHook internal oracle;
    PoolId internal id;

    function setUp() public override {
        vm.warp(1_000_000);
        vm.roll(100);
        super.setUp();
        oracle = GeomeanOracleHook(address(hook));
        id = key.toId();
    }

    function test_PermissionsAndInitialObservation() public view {
        assertEq(flagsOf(hook.getHookPermissions()), 0x1080);
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, 0x1080);
        assertEq(address(hook.poolManager()), address(manager));
        assertEq(oracle.MAX_ABS_TICK_DELTA(), 9_116);
        _assertState(id, 0, 1, 1);
        (uint32 time, int24 truncated, int56 standard, int56 clipped, bool initialized) = oracle.observationsById(id, 0);
        assertEq(time, 1_000_000);
        assertEq(truncated, START_TICK);
        assertEq(standard, 0);
        assertEq(clipped, 0);
        assertTrue(initialized);
    }

    function test_RealCreate2AndConstructorRejectsWrongFlags() public {
        bytes memory code = type(GeomeanOracleHook).creationCode;
        (address predicted, bytes32 salt) = HookMiner.find(address(this), 0x1080, code, abi.encode(manager));
        GeomeanOracleHook deployed = new GeomeanOracleHook{salt: salt}(manager);
        assertEq(address(deployed), predicted);
        assertEq(address(deployed.poolManager()), address(manager));
        (predicted, salt) = HookMiner.find(address(this), 0x0080, code, abi.encode(manager));
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new GeomeanOracleHook{salt: salt}(manager);
    }

    function test_CallbacksRefuseUntrustedCallers() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.afterInitialize(address(this), key, TickMath.getSqrtPriceAtTick(0), 0);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, MIN_PRICE_LIMIT), "");
        _assertState(id, 0, 1, 1);
    }

    function test_CallbackAlwaysReturnsZeroDeltaAndNoFeeOverride() public {
        _step(12);
        vm.prank(address(manager));
        (bytes4 selector, BeforeSwapDelta delta, uint24 fee) =
            hook.beforeSwap(address(0xBAD), key, SwapParams(true, -1 ether, MIN_PRICE_LIMIT), hex"deadbeef");
        assertEq(selector, IHooks.beforeSwap.selector);
        assertEq(BeforeSwapDelta.unwrap(delta), 0);
        assertEq(fee, 0);
    }

    function test_FirstBuyWorksFromTokenOnlyPoolAndCanSellAndWithdraw() public {
        assertEq(address(manager).balance, 0);
        assertLt(token.totalSupply() - token.balanceOf(address(manager)), 1 gwei);
        _step(12);
        BalanceDelta bought = swap(key, true, -1 ether, "");
        assertEq(bought.amount0(), -1 ether);
        assertGt(bought.amount1(), 0);
        assertEq(address(manager).balance, 1 ether);
        BalanceDelta sold = swap(key, false, -int256(bought.amount1()) / 2, hex"bad0");
        assertGt(sold.amount0(), 0);
        assertLt(sold.amount1(), 0);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), token.totalSupply()
        );
        modifyLiquidityRouter.modifyLiquidity(
            key, ModifyLiquidityParams(tickLower, tickUpper, -int256(uint256(liquidity)), 0), ""
        );
        assertEq(manager.getLiquidity(id), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(this)) + token.balanceOf(address(manager)), token.totalSupply());
    }

    function test_ConsultBothSeriesMatchesHandComputedMeansAndInterpolation() public {
        oracle.increaseObservationCardinalityNext(8, id);
        _step(10);
        _moveTo(38_000);
        // [0,10]: 138000; [10,30]: 38000, truncated to 128884.
        _step(20);
        _moveTo(37_000);
        // [30,60]: 37000, truncated to 119768. End is counterfactual (no write).
        _step(30);
        (int24 mean, int24 clipped) = oracle.consult(id, 60);
        assertEq(mean, 54_166); // floor((138000*10 + 38000*20 + 37000*30)/60)
        assertEq(clipped, 125_845); // floor((138000*10 + 128884*20 + 119768*30)/60)
        uint32[] memory ages = new uint32[](4);
        ages[0] = 60;
        ages[1] = 45; // interpolate inside the interval [10,30]
        ages[2] = 30;
        (int56[] memory standard, int56[] memory truncated) = oracle.observe(ages, id);
        assertEq(standard[0], 0);
        assertEq(standard[1], 138_000 * 10 + 38_000 * 5);
        assertEq(standard[2], 138_000 * 10 + 38_000 * 20);
        assertEq(standard[3], 138_000 * 10 + 38_000 * 20 + 37_000 * 30);
        assertEq(truncated[1], 138_000 * 10 + 128_884 * 5);
        assertEq(truncated[3], 138_000 * 10 + 128_884 * 20 + 119_768 * 30);
    }

    function test_HugeSwapMovesStandardMeanMuchMoreThanTruncatedMean() public {
        oracle.increaseObservationCardinalityNext(4, id);
        _step(12);
        _moveTo(38_000); // a 100000-tick move in one block
        (int24 sameBlock, int24 sameBlockTruncated) = oracle.consult(id, 12);
        assertEq(sameBlock, START_TICK);
        assertEq(sameBlockTruncated, START_TICK); // observation precedes the attack swap
        _step(12);
        (int24 standard, int24 truncated) = oracle.consult(id, 24);
        assertEq(standard, 88_000);
        assertEq(truncated, 133_442);
        assertGt(START_TICK - standard, (START_TICK - truncated) * 10);
    }

    function test_OnlyOneObservationPerBlockEvenWithManySwaps() public {
        oracle.increaseObservationCardinalityNext(8, id);
        _step(12);
        _moveTo(38_000);
        _assertState(id, 1, 8, 8);
        bytes32 beforeHash = _observationHash(id, 1);
        swap(key, true, -1 ether, "");
        swap(key, true, -1 ether, hex"ff");
        _assertState(id, 1, 8, 8);
        assertEq(_observationHash(id, 1), beforeHash);
        _step(12);
        swap(key, true, -1 ether, "");
        _assertState(id, 2, 8, 8);
        (, int24 truncated,,,) = oracle.observationsById(id, 2);
        assertEq(truncated, START_TICK - 9_116);
    }

    function test_CardinalityGrowthIsPermissionlessDeferredAndCannotShrink() public {
        vm.prank(address(0xBEEF));
        oracle.increaseObservationCardinalityNext(3, id);
        _assertState(id, 0, 1, 3);
        swap(key, true, -1 ether, ""); // same timestamp as initialization
        _assertState(id, 0, 1, 3);
        _step(12);
        swap(key, true, -1 ether, "");
        _assertState(id, 1, 3, 3);
        oracle.increaseObservationCardinalityNext(5, id);
        oracle.increaseObservationCardinalityNext(0, id);
        oracle.increaseObservationCardinalityNext(2, id);
        _assertState(id, 1, 3, 5);
        _step(12);
        swap(key, true, -1 ether, "");
        _assertState(id, 2, 3, 5); // full-ring growth waits until its last index
        _step(12);
        swap(key, true, -1 ether, "");
        _assertState(id, 3, 5, 5);
    }

    function test_ZeroWindowUnknownPoolAndTooOldReadsRevert() public {
        vm.expectRevert(GeomeanOracleHook.ZeroWindow.selector);
        oracle.consult(id, 0);
        PoolId unknown = PoolId.wrap(bytes32(uint256(123)));
        vm.expectRevert(BaseOracleHook.PoolNotInitialized.selector);
        oracle.consult(unknown, 1);
        vm.expectRevert(BaseOracleHook.PoolNotInitialized.selector);
        oracle.increaseObservationCardinalityNext(2, unknown);
        _step(12);
        swap(key, true, -1 ether, ""); // capacity 1 overwrites the initial observation
        vm.expectRevert(
            abi.encodeWithSelector(
                Oracle.TargetPredatesOldestObservation.selector, uint32(1_000_012), uint32(1_000_000)
            )
        );
        oracle.consult(id, 12);
        uint32[] memory ages = new uint32[](1);
        ages[0] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                Oracle.TargetPredatesOldestObservation.selector, uint32(1_000_012), uint32(1_000_011)
            )
        );
        oracle.observe(ages, id);
    }

    function test_RingOverwriteAndGrowPreservesAvailableHistory() public {
        oracle.increaseObservationCardinalityNext(3, id);
        for (uint256 i; i < 5; ++i) {
            _step(10);
            swap(key, true, -1 ether, "");
        }
        _assertState(id, 2, 3, 3);
        oracle.consult(id, 20); // exact oldest retained sample at t=30
        vm.expectRevert(
            abi.encodeWithSelector(
                Oracle.TargetPredatesOldestObservation.selector, uint32(1_000_030), uint32(1_000_029)
            )
        );
        oracle.consult(id, 21);
        oracle.increaseObservationCardinalityNext(6, id);
        _step(10);
        swap(key, true, -1 ether, "");
        _assertState(id, 3, 6, 6);
        oracle.consult(id, 30); // uninitialized new slots must not confuse the search
        oracle.consult(id, 15);
    }

    function test_NegativeMeansRoundDownIncludingTruncatedSeries() public {
        _moveTo(-100);
        // Start another pool at -100 so both series begin negative and in agreement.
        PoolKey memory negative = key;
        negative.fee = 500;
        manager.initialize(negative, TickMath.getSqrtPriceAtTick(-100));
        PoolId negativeId = negative.toId();
        oracle.increaseObservationCardinalityNext(4, negativeId);
        modifyLiquidityRouter.modifyLiquidity{value: 10 ether}(
            negative, ModifyLiquidityParams(-600, 600, 1 ether, 0), ""
        );
        _step(1);
        _swapTo(negative, -101);
        _step(2);
        (int24 mean, int24 truncated) = oracle.consult(negativeId, 3);
        assertEq(mean, -101); // -302 / 3 = -100.666..., floor is -101
        assertEq(truncated, -101);
        (mean, truncated) = oracle.consult(negativeId, 2);
        assertEq(mean, -101); // exact negative division must not subtract another 1
        assertEq(truncated, -101);
    }

    function test_Uint32TimestampWrapWithRealSwapsAndOldHistory() public {
        uint256 start = uint256(type(uint32).max) - 5;
        vm.warp(start);
        PoolKey memory wrapped = key;
        wrapped.fee = 500;
        manager.initialize(wrapped, TickMath.getSqrtPriceAtTick(START_TICK));
        PoolId wrappedId = wrapped.toId();
        // No liquidity is needed: real PM swaps may move through an empty price range.
        oracle.increaseObservationCardinalityNext(4, wrappedId);
        _step(4);
        _swapTo(wrapped, START_TICK - 100);
        _step(4); // crosses 2**32
        _swapTo(wrapped, START_TICK - 200);
        _step(4);
        (int24 standard, int24 truncated) = oracle.consult(wrappedId, 12);
        assertEq(standard, START_TICK - 100);
        assertEq(truncated, standard);
        (standard, truncated) = oracle.consult(wrappedId, 6);
        assertEq(standard, START_TICK - 167);
        assertEq(truncated, standard);
        vm.expectRevert(
            abi.encodeWithSelector(Oracle.TargetPredatesOldestObservation.selector, uint32(start), uint32(start - 1))
        );
        oracle.consult(wrappedId, 13);
    }

    function test_PoolsHaveIndependentHistoryAndGrowth() public {
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, TickMath.getSqrtPriceAtTick(-200));
        PoolId otherId = other.toId();
        oracle.increaseObservationCardinalityNext(16, otherId);
        _step(20);
        swap(key, true, -1 ether, "");
        _assertState(id, 0, 1, 1);
        _assertState(otherId, 0, 1, 16);
        (int24 standard, int24 truncated) = oracle.consult(otherId, 20);
        assertEq(standard, -200);
        assertEq(truncated, -200);
    }

    function test_FailedGrowthCannotGriefSwapsAndLargerBufferKeepsWritesBounded() public {
        // A caller pays for preallocation. Running out of gas must roll back every slot and state update.
        (bool ok,) = address(oracle).call{gas: 100_000}(
            abi.encodeCall(oracle.increaseObservationCardinalityNext, (type(uint16).max, id))
        );
        assertFalse(ok);
        _assertState(id, 0, 1, 1);
        (,,,, bool initialized) = oracle.observationsById(id, 1);
        assertFalse(initialized);
        _step(12);
        swap(key, true, -1 ether, "");
        oracle.increaseObservationCardinalityNext(1_024, id);
        _step(12);
        vm.prank(address(manager));
        uint256 gasBefore = gasleft();
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, MIN_PRICE_LIMIT), "");
        uint256 writeGas = gasBefore - gasleft();
        assertLt(writeGas, 100_000, "callback must not loop over capacity");
        _assertState(id, 1, 1_024, 1_024);
        swap(key, true, -1 ether, "");
        oracle.consult(id, 12);
    }

    function test_FailedSettlementRollsBackOracleWrite() public {
        oracle.increaseObservationCardinalityNext(4, id);
        _step(12);
        BalanceDelta bought = swap(key, true, -1 ether, "");
        bytes32 oldObservation = _observationHash(id, 1);
        token.approve(address(swapRouter), 0);
        _step(12);
        vm.expectRevert(); // token refuses router transferFrom after beforeSwap has run
        swap(key, false, -int256(bought.amount1()) / 2, "");
        _assertState(id, 1, 4, 4);
        assertEq(_observationHash(id, 1), oldObservation);
        (,,,, bool initialized) = oracle.observationsById(id, 2);
        assertFalse(initialized);
        token.approve(address(swapRouter), type(uint256).max);
        swap(key, false, -int256(bought.amount1()) / 2, "");
        _assertState(id, 2, 4, 4);
    }

    function test_FullTickRangeBothDirectionsDoesNotBrickBeforeSwap() public {
        PoolKey memory extremes = key;
        extremes.fee = 500;
        manager.initialize(extremes, TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 1));
        PoolId extremeId = extremes.toId();
        oracle.increaseObservationCardinalityNext(4, extremeId);
        _step(12);
        _swapTo(extremes, TickMath.MIN_TICK + 1);
        _step(12);
        // Empty pool: traverse the full range upwards without taking user funds.
        swapRouter.swap(
            extremes,
            SwapParams(false, -1, TickMath.getSqrtPriceAtTick(TickMath.MAX_TICK - 1)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        (, int24 truncated,,,) = oracle.observationsById(extremeId, 2);
        assertEq(truncated, TickMath.MAX_TICK - 1 - 9_116);
        _step(12);
        _swapTo(extremes, 0);
        (, truncated,,,) = oracle.observationsById(extremeId, 3);
        assertEq(truncated, TickMath.MAX_TICK - 1);
        oracle.consult(extremeId, 36);
    }

    function testFuzz_SettlementMatchesHooklessPool(uint96 rawAmount) public {
        uint256 amount = bound(rawAmount, 1 gwei, 100 ether);
        Geomean otherToken = new Geomean();
        otherToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        otherToken.approve(address(swapRouter), type(uint256).max);
        PoolKey memory plain = key;
        plain.hooks = IHooks(address(0));
        plain.currency1 = Currency.wrap(address(otherToken));
        manager.initialize(plain, TickMath.getSqrtPriceAtTick(START_TICK));
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), otherToken.totalSupply()
        );
        modifyLiquidityRouter.modifyLiquidity(
            plain, ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidity)), 0), ""
        );
        oracle.increaseObservationCardinalityNext(8, id);
        _step(12);
        BalanceDelta hooked = swap(key, true, -int256(amount), hex"abcd");
        BalanceDelta unhooked = swap(plain, true, -int256(amount), "");
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(unhooked));
        _step(12);
        int256 sellAmount = int256(hooked.amount1()) / 2;
        hooked = swap(key, false, -sellAmount, "");
        unhooked = swap(plain, false, -sellAmount, "");
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(unhooked));
        _step(12);
        hooked = swapNativeInput(key, true, 1 ether, "", 1 ether);
        unhooked = swapNativeInput(plain, true, 1 ether, "", 1 ether);
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(unhooked));
        hooked = swap(key, false, 1 gwei, "");
        unhooked = swap(plain, false, 1 gwei, "");
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(unhooked));
        (uint160 hookedPrice, int24 hookedTick,, uint24 hookedFee) = manager.getSlot0(id);
        (uint160 plainPrice, int24 plainTick,, uint24 plainFee) = manager.getSlot0(plain.toId());
        assertEq(hookedPrice, plainPrice);
        assertEq(hookedTick, plainTick);
        assertEq(hookedFee, plainFee);
        assertEq(token.balanceOf(address(this)), otherToken.balanceOf(address(this)));
        assertEq(token.balanceOf(address(manager)), otherToken.balanceOf(address(manager)));
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }

    function test_NoForbiddenRuntimeOpcodesAndUnderSizeLimit() public view {
        bytes memory code = address(hook).code;
        assertGt(code.length, 0);
        assertLe(code.length, 24_576);
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
            else assertTrue(op != 0xff && op != 0xf4 && op != 0xf2);
        }
    }

    function _step(uint256 secondsForward) internal {
        vm.warp(vm.getBlockTimestamp() + secondsForward);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _moveTo(int24 target) internal {
        _swapTo(key, target);
        (, int24 actual,,) = manager.getSlot0(id);
        assertEq(actual, target);
    }

    function _swapTo(PoolKey memory pool, int24 target) internal {
        vm.deal(address(this), 1e32);
        swapRouter.swap{value: 1e31}(
            pool,
            SwapParams(true, -int256(1e31), TickMath.getSqrtPriceAtTick(target)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
    }

    function _assertState(PoolId poolId, uint16 index, uint16 cardinality, uint16 next) internal view {
        (uint16 actualIndex, uint16 actualCardinality, uint16 actualNext) = oracle.observationState(poolId);
        assertEq(actualIndex, index);
        assertEq(actualCardinality, cardinality);
        assertEq(actualNext, next);
    }

    function _observationHash(PoolId poolId, uint16 index) internal view returns (bytes32) {
        (uint32 time, int24 tick, int56 a, int56 b, bool initialized) = oracle.observationsById(poolId, index);
        return keccak256(abi.encode(time, tick, a, b, initialized));
    }
}
