// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BaseHookTest} from "../BaseHookTest.sol";
import {SettlementProbe} from "./SettlementProbe.sol";
import {Geomean} from "../../src/Geomean.sol";
import {GeomeanOracleHook} from "../../src/GeomeanOracleHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

abstract contract OracleSwapFixture is BaseHookTest {
    using StateLibrary for IPoolManager;

    GeomeanOracleHook internal oracle;
    Geomean internal plainToken;
    PoolKey internal plain;
    PoolId internal id;
    SettlementProbe internal probe;

    function setUp() public virtual override {
        vm.warp(1_000_000);
        vm.roll(100);
        super.setUp();
        oracle = GeomeanOracleHook(address(hook));
        id = key.toId();
        probe = new SettlementProbe(manager);
        token.approve(address(probe), type(uint256).max);

        plainToken = new Geomean();
        plainToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        plainToken.approve(address(probe), type(uint256).max);
        plain = PoolKey(key.currency0, Currency.wrap(address(plainToken)), key.fee, key.tickSpacing, IHooks(address(0)));
        manager.initialize(plain, TickMath.getSqrtPriceAtTick(START_TICK));
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), plainToken.totalSupply()
        );
        modifyLiquidityRouter.modifyLiquidity(
            plain, ModifyLiquidityParams(tickLower, tickUpper, int256(uint256(liquidity)), 0), ""
        );
    }

    function _pair(bool buy, int256 amount, bytes memory hookData) internal returns (BalanceDelta hooked) {
        SwapParams memory params = SwapParams(buy, amount, buy ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
        uint256 value = buy ? (amount < 0 ? uint256(-amount) + 1 : 200 ether) : 0;
        hooked = probe.swap{value: value}(key, params, hookData, SettlementProbe.Payment.Full);
        BalanceDelta unhooked = probe.swap{value: value}(plain, params, hookData, SettlementProbe.Payment.Full);
        assertEq(BalanceDelta.unwrap(hooked), BalanceDelta.unwrap(unhooked), "hook changed swap outcome");
        _assertEquivalentPools();
    }

    function _assertEquivalentPools() internal view {
        (uint160 hp, int24 ht, uint24 hpf, uint24 hf) = manager.getSlot0(id);
        (uint160 pp, int24 pt, uint24 ppf, uint24 pf) = manager.getSlot0(plain.toId());
        assertEq(hp, pp);
        assertEq(ht, pt);
        assertEq(hpf, ppf);
        assertEq(hf, pf);
        assertEq(manager.getLiquidity(id), manager.getLiquidity(plain.toId()));
        (uint256 h0, uint256 h1) = manager.getFeeGrowthGlobals(id);
        (uint256 p0, uint256 p1) = manager.getFeeGrowthGlobals(plain.toId());
        assertEq(h0, p0);
        assertEq(h1, p1);
        assertEq(token.balanceOf(address(this)), plainToken.balanceOf(address(this)));
        assertEq(token.balanceOf(address(manager)), plainToken.balanceOf(address(manager)));
        assertEq(token.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
    }

    function _step(uint256 elapsed) internal {
        vm.warp(vm.getBlockTimestamp() + elapsed);
        vm.roll(vm.getBlockNumber() + 1);
    }
}
