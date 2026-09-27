// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {Geomean} from "../src/Geomean.sol";

/// @notice Canonical template launch harness using the production GEOM token.
abstract contract BaseHookTest is Deployers {
    /// @dev A high address, leaving the low 14 bits free to carry the permission flags.
    uint160 internal constant HOOK_BASE = uint160(0x4444 << 144);

    /// @dev 0.30%, used once the hook declares a permission. See {poolFee}.
    uint24 internal constant STATIC_FEE = 3000;

    int24 internal constant TICK_SPACING = 60;

    /// @dev Starting tick ≈ 984k token per ETH, so the full supply is worth ~1,016 ETH at launch.
    int24 internal constant START_TICK = 138_000;

    /// @dev ETH handed to the test contract, so it can buy without further setup.
    uint256 internal constant TEST_ETH = 1_000 ether;

    BaseHook internal hook;
    Geomean internal token;
    int24 internal tickLower;
    int24 internal tickUpper;

    function setUp() public virtual {
        deployFreshManagerAndRouters();

        token = new Geomean();
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        token.approve(address(swapRouter), type(uint256).max);

        hook = deployHook();

        // `key` is inherited from Deployers; tests refer to it directly.
        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: poolFee(),
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        manager.initialize(key, TickMath.getSqrtPriceAtTick(START_TICK));

        seedFullSupply();

        vm.deal(address(this), TEST_ETH);
    }

    function seedFullSupply() internal virtual {
        tickUpper = START_TICK;
        tickLower = TickMath.minUsableTick(TICK_SPACING);

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), token.totalSupply()
        );

        modifyLiquidityRouter.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: 0
            }),
            ZERO_BYTES
        );
    }

    function poolFee() internal virtual returns (uint24) {
        return _declaredFlags() == 0 ? LPFeeLibrary.DYNAMIC_FEE_FLAG : STATIC_FEE;
    }

    function hookArtifact() internal view virtual returns (string memory) {
        return "GeomeanOracleHook.sol:GeomeanOracleHook";
    }

    /// @dev Constructor arguments for {hookArtifact}. Override for a hook taking more than the manager.
    function hookConstructorArgs() internal view virtual returns (bytes memory) {
        return abi.encode(manager);
    }

    function deployHook() internal virtual returns (BaseHook) {
        address target = address(HOOK_BASE | _declaredFlags());
        deployCodeTo(hookArtifact(), hookConstructorArgs(), target);
        return BaseHook(payable(target));
    }

    /// @dev Token balance of `account`, for asserting who a hook moved value to.
    function balanceOf(Currency currency, address account) internal view returns (uint256) {
        return currency.balanceOf(account);
    }

    function _declaredFlags() internal returns (uint160) {
        address probe = address(uint160(uint256(keccak256("hook.permission.probe"))));
        vm.etch(probe, vm.getDeployedCode(hookArtifact()));
        return flagsOf(BaseHook(payable(probe)).getHookPermissions());
    }

    /// @dev The address bits a hook with these permissions must carry.
    function flagsOf(Hooks.Permissions memory p) internal pure returns (uint160 flags) {
        if (p.beforeInitialize) flags |= Hooks.BEFORE_INITIALIZE_FLAG;
        if (p.afterInitialize) flags |= Hooks.AFTER_INITIALIZE_FLAG;
        if (p.beforeAddLiquidity) flags |= Hooks.BEFORE_ADD_LIQUIDITY_FLAG;
        if (p.afterAddLiquidity) flags |= Hooks.AFTER_ADD_LIQUIDITY_FLAG;
        if (p.beforeRemoveLiquidity) flags |= Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG;
        if (p.afterRemoveLiquidity) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_FLAG;
        if (p.beforeSwap) flags |= Hooks.BEFORE_SWAP_FLAG;
        if (p.afterSwap) flags |= Hooks.AFTER_SWAP_FLAG;
        if (p.beforeDonate) flags |= Hooks.BEFORE_DONATE_FLAG;
        if (p.afterDonate) flags |= Hooks.AFTER_DONATE_FLAG;
        if (p.beforeSwapReturnDelta) flags |= Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterSwapReturnDelta) flags |= Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG;
        if (p.afterAddLiquidityReturnDelta) flags |= Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG;
        if (p.afterRemoveLiquidityReturnDelta) flags |= Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG;
    }
}
