// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {OracleSwapFixture} from "./helpers/OracleSwapFixture.sol";
import {SettlementProbe} from "./helpers/SettlementProbe.sol";
import {Geomean} from "../src/Geomean.sol";
import {GeomeanOracleHook} from "../src/GeomeanOracleHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";

/// @dev Only this handler is targeted. No deal/mint/storage writes occur during the campaign;
/// inventory comes from the one-sided seed and actual swaps. Unexpected reverts fail the run.
contract OracleSwapHandler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager public immutable manager;
    SettlementProbe public immutable probe;
    GeomeanOracleHook public immutable oracle;
    Geomean public immutable token;
    Geomean public immutable plainToken;
    PoolKey internal hooked;
    PoolKey internal plain;
    uint256[4] public calls;

    // Independent wide-integer model of the latest committed observation.
    uint256 public modelTime;
    int256 public modelTick;
    int256 public standardCumulative;
    int256 public truncatedCumulative;
    uint16 public modelIndex;
    uint16 public modelCapacity = 1;
    uint16 public modelNext = 1;

    constructor(IPoolManager manager_, SettlementProbe probe_, PoolKey memory hooked_, PoolKey memory plain_) {
        manager = manager_;
        probe = probe_;
        hooked = hooked_;
        plain = plain_;
        oracle = GeomeanOracleHook(address(hooked_.hooks));
        token = Geomean(Currency.unwrap(hooked_.currency1));
        plainToken = Geomean(Currency.unwrap(plain_.currency1));
        token.approve(address(probe_), type(uint256).max);
        plainToken.approve(address(probe_), type(uint256).max);
        modelTime = block.timestamp;
        (, int24 tick,,) = manager_.getSlot0(hooked_.toId());
        modelTick = tick;
    }

    function advance(uint32 rawElapsed) external {
        uint256 elapsed = bound(rawElapsed, 0, 1 hours);
        vm.warp(vm.getBlockTimestamp() + elapsed);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function grow(uint16 rawCapacity) external {
        uint16 requested = uint16(bound(rawCapacity, 0, 64));
        oracle.increaseObservationCardinalityNext(requested, hooked.toId());
        if (requested > modelNext) modelNext = requested;
        assertObservationModel();
    }

    function trade(uint8 rawKind, uint96 rawAmount, bytes calldata hookData) external {
        uint256 kind = uint256(rawKind) % 4;
        if (kind >= 2 && token.balanceOf(address(this)) < 1 ether) _execute(0, 1 ether, "");
        uint256 maximum;
        if (kind == 0) {
            maximum = 50 ether;
        } else if (kind == 1) {
            maximum = token.balanceOf(address(manager)) / 1_000;
        } else if (kind == 2) {
            maximum = token.balanceOf(address(this)) / 8;
        } else {
            (uint160 price,,,) = manager.getSlot0(hooked.toId());
            // Conservatively sell <= 1/16 of available tokens at spot price, also capped by
            // 1/16 of this pool's ETH reserves. This keeps exact output fully fillable.
            uint256 spotEth = FullMath.mulDiv(token.balanceOf(address(this)), 1 << 96, price);
            spotEth = FullMath.mulDiv(spotEth, 1 << 96, price) / 16;
            maximum = spotEth < address(manager).balance / 32 ? spotEth : address(manager).balance / 32;
        }
        assertGt(maximum, 0, "handler ran out of inventory");
        _execute(kind, bound(rawAmount, 1, maximum), hookData);
    }

    function _execute(uint256 kind, uint256 amount, bytes memory hookData) private {
        bool buy = kind < 2;
        bool exactIn = kind % 2 == 0;
        SwapParams memory params = SwapParams(
            buy,
            exactIn ? -int256(amount) : int256(amount),
            buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
        );
        _recordPreSwapTick();
        uint256 value = buy ? (exactIn ? amount + 1 : address(this).balance / 2) : 0;
        BalanceDelta h = probe.swap{value: value}(hooked, params, hookData, SettlementProbe.Payment.Full);
        BalanceDelta p = probe.swap{value: value}(plain, params, hookData, SettlementProbe.Payment.Full);
        assertEq(BalanceDelta.unwrap(h), BalanceDelta.unwrap(p), "oracle changed trader delta");
        int128 specified = buy == exactIn ? h.amount0() : h.amount1();
        assertEq(specified, params.amountSpecified, "bounded trade was not fully filled");
        calls[kind]++;
        assertEquivalentPools();
        assertObservationModel();
    }

    function _recordPreSwapTick() private {
        uint256 now_ = vm.getBlockTimestamp();
        if (now_ == modelTime) return;
        (, int24 tick,,) = manager.getSlot0(hooked.toId());
        int256 difference = int256(tick) - modelTick;
        if (difference > 9_116) difference = 9_116;
        if (difference < -9_116) difference = -9_116;
        modelTick += difference;
        int256 duration = int256(now_ - modelTime);
        standardCumulative += int256(tick) * duration;
        truncatedCumulative += modelTick * duration;
        modelTime = now_;
        if (modelIndex + 1 == modelCapacity) modelCapacity = modelNext;
        modelIndex = uint16((uint256(modelIndex) + 1) % modelCapacity);
    }

    function assertObservationModel() public view {
        (uint16 index, uint16 cardinality, uint16 next) = oracle.observationState(hooked.toId());
        assertEq(index, modelIndex);
        assertEq(cardinality, modelCapacity);
        assertEq(next, modelNext);
        assertLt(index, cardinality);
        assertLe(cardinality, next);
        (uint32 time, int24 tick, int56 a, int56 b, bool initialized) = oracle.observationsById(hooked.toId(), index);
        assertTrue(initialized);
        assertEq(time, uint32(modelTime));
        assertEq(tick, modelTick);
        assertEq(a, standardCumulative);
        assertEq(b, truncatedCumulative);

        // Views after an idle period must use the current pool tick without mutating history.
        if (vm.getBlockTimestamp() > modelTime) {
            (, int24 currentTick,,) = manager.getSlot0(hooked.toId());
            int256 change = int256(currentTick) - modelTick;
            if (change > 9_116) change = 9_116;
            if (change < -9_116) change = -9_116;
            (int24 standardMean, int24 truncatedMean) =
                oracle.consult(hooked.toId(), uint32(vm.getBlockTimestamp() - modelTime));
            assertEq(standardMean, currentTick);
            assertEq(truncatedMean, modelTick + change);
        }
    }

    function assertEquivalentPools() public view {
        (uint160 hp, int24 ht, uint24 hpf, uint24 hf) = manager.getSlot0(hooked.toId());
        (uint160 pp, int24 pt, uint24 ppf, uint24 pf) = manager.getSlot0(plain.toId());
        assertEq(hp, pp);
        assertEq(ht, pt);
        assertEq(hpf, ppf);
        assertEq(hf, pf);
        assertEq(manager.getLiquidity(hooked.toId()), manager.getLiquidity(plain.toId()));
        (uint256 h0, uint256 h1) = manager.getFeeGrowthGlobals(hooked.toId());
        (uint256 p0, uint256 p1) = manager.getFeeGrowthGlobals(plain.toId());
        assertEq(h0, p0);
        assertEq(h1, p1);
        assertEq(token.balanceOf(address(this)), plainToken.balanceOf(address(this)));
        assertEq(token.balanceOf(address(manager)), plainToken.balanceOf(address(manager)));
    }

    receive() external payable {}
}

/// forge-config: default.invariant.fail-on-revert = true
/// forge-config: default.invariant.runs = 128
/// forge-config: default.invariant.depth = 128
contract OracleSwapInvariantTest is OracleSwapFixture {
    OracleSwapHandler internal handler;
    uint256 internal constant ENDOWMENT = 1_000_000 ether;

    function setUp() public override {
        super.setUp();
        handler = new OracleSwapHandler(manager, probe, key, plain);
        token.transfer(address(handler), token.balanceOf(address(this)));
        plainToken.transfer(address(handler), plainToken.balanceOf(address(this)));
        vm.deal(address(handler), ENDOWMENT);
        // Guarantee all four paths are exercised even before the random campaign starts.
        for (uint8 i; i < 4; ++i) {
            handler.trade(i, uint96(1 ether), "");
        }
        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.trade.selector;
        selectors[1] = handler.advance.selector;
        selectors[2] = handler.grow.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    function invariant_AllDeltasSettleAndAssetsAreConserved() public view {
        // The probe checks transient deltas inside every unlock. These persistent checks ensure
        // the hook/router cannot accumulate balances or ERC-6909 claims between transactions.
        assertEq(address(handler).balance + address(manager).balance, ENDOWMENT);
        assertEq(token.balanceOf(address(handler)) + token.balanceOf(address(manager)), token.totalSupply());
        assertEq(
            plainToken.balanceOf(address(handler)) + plainToken.balanceOf(address(manager)), plainToken.totalSupply()
        );
        assertEq(address(probe).balance, 0);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(probe)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(plainToken.balanceOf(address(probe)), 0);
        assertEq(manager.balanceOf(address(probe), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(probe), key.currency1.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency0.toId()), 0);
        assertEq(manager.balanceOf(address(hook), key.currency1.toId()), 0);
        for (uint256 i; i < 4; ++i) {
            assertGt(handler.calls(i), 0);
        }
    }

    function invariant_HookNeverChangesSwapOutcome() public view {
        handler.assertEquivalentPools();
    }

    function invariant_ObservationSeriesMatchIndependentModel() public view {
        handler.assertObservationModel();
    }
}
