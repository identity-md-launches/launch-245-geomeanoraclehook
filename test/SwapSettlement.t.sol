// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {OracleSwapFixture} from "./helpers/OracleSwapFixture.sol";
import {SettlementProbe} from "./helpers/SettlementProbe.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Pool} from "@uniswap/v4-core/src/libraries/Pool.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract SwapSettlementTest is OracleSwapFixture {
    using StateLibrary for IPoolManager;

    function testFuzz_BuyExactInputSettlesFromTokenOnlyLaunch(uint96 raw, bytes calldata hookData) public {
        assertEq(address(manager).balance, 0);
        uint256 amount = bound(raw, 1 gwei, 100 ether);
        _step(12);
        BalanceDelta delta = _pair(true, -int256(amount), hookData);
        assertEq(delta.amount0(), -int256(amount));
        assertGt(delta.amount1(), 0);
    }

    function testFuzz_BuyExactOutputSettlesFromTokenOnlyLaunch(uint96 raw, bytes calldata hookData) public {
        assertEq(address(manager).balance, 0);
        uint256 amount = bound(raw, 1 ether, 100_000_000 ether);
        _step(12);
        BalanceDelta delta = _pair(true, int256(amount), hookData);
        assertEq(delta.amount1(), int256(amount));
        assertLt(delta.amount0(), 0);
    }

    function testFuzz_SellExactInputSettles(uint96 raw, bytes calldata hookData) public {
        BalanceDelta bought = _pair(true, -100 ether, "");
        uint256 amount = bound(raw, 1 ether, uint256(int256(bought.amount1())) / 2);
        _step(12);
        BalanceDelta delta = _pair(false, -int256(amount), hookData);
        assertEq(delta.amount1(), -int256(amount));
        assertGt(delta.amount0(), 0);
    }

    function testFuzz_SellExactOutputSettles(uint96 raw, bytes calldata hookData) public {
        _pair(true, -100 ether, "");
        uint256 amount = bound(raw, 1 gwei, 50 ether);
        _step(12);
        BalanceDelta delta = _pair(false, int256(amount), hookData);
        assertEq(delta.amount0(), int256(amount));
        assertLt(delta.amount1(), 0);
    }

    function test_OneWeiInputsAndOutputsSettleIdentically() public {
        BalanceDelta delta = _pair(true, -1, "");
        assertEq(delta.amount0(), -1);
        _pair(true, 1, hex"00");
        _pair(true, -1 ether, "");
        delta = _pair(false, -1, "");
        assertEq(delta.amount1(), -1);
        delta = _pair(false, 1, "");
        assertEq(delta.amount0(), 1);
    }

    function testFuzz_PriceLimitedPartialFillsSettle(uint8 rawKind) public {
        uint256 kind = uint256(rawKind) % 4;
        _pair(true, -100 ether, "");
        _step(12);
        bool buy = kind < 2;
        bool exactIn = kind % 2 == 0;
        (, int24 tick,,) = manager.getSlot0(id);
        uint160 limit = TickMath.getSqrtPriceAtTick(buy ? tick - 1 : tick + 1);
        int256 requested = kind == 0
            ? -int256(10 ether)
            : kind == 1 ? int256(10_000_000 ether) : kind == 2 ? -int256(10_000_000 ether) : int256(10 ether);
        SwapParams memory params = SwapParams(buy, requested, limit);
        BalanceDelta h = probe.swap{value: buy ? 10 ether : 0}(key, params, "", SettlementProbe.Payment.Full);
        BalanceDelta p = probe.swap{value: buy ? 10 ether : 0}(plain, params, "", SettlementProbe.Payment.Full);
        assertEq(BalanceDelta.unwrap(h), BalanceDelta.unwrap(p));
        int256 specified = buy == exactIn ? h.amount0() : h.amount1();
        if (exactIn) {
            assertGt(specified, requested, "test must hit the price limit before spending all input");
            assertLt(specified, 0);
        } else {
            assertLt(specified, requested, "test must hit the price limit before filling all output");
            assertGt(specified, 0);
        }
        (uint160 price,,,) = manager.getSlot0(id);
        assertEq(price, limit);
        _assertEquivalentPools();
    }

    function testFuzz_UnsettledDebtOrCreditRevertsAndRollsBack(uint8 kind, uint8 fault) public {
        kind = uint8(bound(kind, 0, 3));
        SettlementProbe.Payment payment = SettlementProbe.Payment(bound(fault, 1, 4));
        _pair(true, -10 ether, "");
        oracle.increaseObservationCardinalityNext(4, id);
        _step(12);
        bool buy = kind < 2;
        int256 amount =
            kind == 0 ? -int256(1 ether) : kind == 1 ? int256(1 ether) : kind == 2 ? -int256(1 ether) : int256(1 gwei);
        SwapParams memory params = SwapParams(buy, amount, buy ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        probe.swap{value: buy ? 2 ether : 0}(key, params, "", payment);
        assertEq(_snapshot(), beforeState, "failed unlock changed balances, price, or observations");
        // The rejected write must not prevent a correctly settled swap in the very same block.
        _pair(buy, amount, "");
        (uint16 index, uint16 cardinality,) = oracle.observationState(id);
        assertEq(index, 1);
        assertEq(cardinality, 4);
    }

    function test_ZeroAmountAndWrongPriceLimitRollBackBeforeSwapWrite() public {
        oracle.increaseObservationCardinalityNext(4, id);
        _step(12);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        probe.swap(key, SwapParams(true, 0, MIN_PRICE_LIMIT), "", SettlementProbe.Payment.Full);
        assertEq(_snapshot(), beforeState);

        (uint160 current,,,) = manager.getSlot0(id);
        vm.expectRevert(abi.encodeWithSelector(Pool.PriceLimitAlreadyExceeded.selector, current, current));
        probe.swap{value: 1 ether}(key, SwapParams(true, -1 ether, current), "", SettlementProbe.Payment.Full);
        assertEq(_snapshot(), beforeState);
        _pair(true, -1 ether, "");
    }

    function test_MissingAllowanceRollsBackAndRetrySucceeds() public {
        _pair(true, -10 ether, "");
        token.approve(address(probe), 0);
        oracle.increaseObservationCardinalityNext(4, id);
        _step(12);
        bytes32 beforeState = _snapshot();
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(probe), 0, 1 ether)
        );
        probe.swap(key, SwapParams(false, -1 ether, MAX_PRICE_LIMIT), "", SettlementProbe.Payment.Full);
        assertEq(_snapshot(), beforeState);
        token.approve(address(probe), type(uint256).max);
        _pair(false, -1 ether, "");
    }

    function testFuzz_ObservationGrowthAndRepeatedSwaps(uint16 requested, uint32 elapsed) public {
        requested = uint16(bound(requested, 2, 128));
        elapsed = uint32(bound(elapsed, 1, 1 days));
        oracle.increaseObservationCardinalityNext(requested, id);
        _step(elapsed);
        _pair(true, -1 ether, "");
        (uint16 index, uint16 cardinality, uint16 next) = oracle.observationState(id);
        assertEq(index, 1);
        assertEq(cardinality, requested);
        assertEq(next, requested);
        bytes32 beforeObservation = _observationsHash();
        _pair(true, 1 ether, hex"deadbeef");
        _pair(false, -1 ether, "");
        _pair(false, 1 gwei, "");
        assertEq(_observationsHash(), beforeObservation, "same-block swap wrote another observation");
        (int24 mean, int24 truncated) = oracle.consult(id, elapsed);
        assertEq(mean, START_TICK);
        assertEq(truncated, START_TICK);
    }

    function _snapshot() private view returns (bytes32) {
        (uint160 price, int24 tick, uint24 protocolFee, uint24 lpFee) = manager.getSlot0(id);
        (uint256 fee0, uint256 fee1) = manager.getFeeGrowthGlobals(id);
        bytes32 poolState = keccak256(abi.encode(price, tick, protocolFee, lpFee, fee0, fee1, manager.getLiquidity(id)));
        return keccak256(
            abi.encode(
                poolState,
                _observationsHash(),
                address(this).balance,
                address(manager).balance,
                token.balanceOf(address(this)),
                token.balanceOf(address(manager)),
                address(probe).balance,
                token.balanceOf(address(probe)),
                address(hook).balance,
                token.balanceOf(address(hook))
            )
        );
    }

    function _observationsHash() private view returns (bytes32 result) {
        (uint16 index, uint16 cardinality, uint16 next) = oracle.observationState(id);
        result = keccak256(abi.encode(index, cardinality, next));
        for (uint256 i; i < next; ++i) {
            (uint32 time, int24 tick, int56 a, int56 b, bool initialized) = oracle.observationsById(id, i);
            result = keccak256(abi.encode(result, time, tick, a, b, initialized));
        }
    }
}
