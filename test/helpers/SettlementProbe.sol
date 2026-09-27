// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {CurrencySettler} from "@uniswap/v4-core/test/utils/CurrencySettler.sol";

/// @dev Test router. All accounting assertions run within the transaction, including before unlock
/// returns: checking transient storage only in an invariant's later call would be vacuous.
contract SettlementProbe is IUnlockCallback {
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;

    enum Payment {
        Full,
        SkipDebt,
        SkipCredit,
        Underpay,
        Overpay
    }

    struct Request {
        address payer;
        PoolKey key;
        SwapParams params;
        bytes hookData;
        Payment payment;
    }

    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes memory hookData, Payment payment)
        external
        payable
        returns (BalanceDelta delta)
    {
        require(key.currency0.isAddressZero(), "fixture requires native ETH");
        require(address(this).balance == msg.value, "router retained ETH");
        require(key.currency1.balanceOfSelf() == 0, "router retained tokens");
        uint256 payer0 = msg.sender.balance + msg.value;
        uint256 payer1 = key.currency1.balanceOf(msg.sender);
        uint256 manager0 = address(manager).balance;
        uint256 manager1 = key.currency1.balanceOf(address(manager));

        delta =
            abi.decode(manager.unlock(abi.encode(Request(msg.sender, key, params, hookData, payment))), (BalanceDelta));
        if (address(this).balance != 0) key.currency0.transfer(msg.sender, address(this).balance);

        require(int256(msg.sender.balance) - int256(payer0) == delta.amount0(), "payer ETH != delta0");
        require(int256(key.currency1.balanceOf(msg.sender)) - int256(payer1) == delta.amount1(), "payer GEOM != delta1");
        require(
            int256(address(manager).balance) - int256(manager0) == -int256(delta.amount0()), "manager ETH != -delta0"
        );
        require(
            int256(key.currency1.balanceOf(address(manager))) - int256(manager1) == -int256(delta.amount1()),
            "manager GEOM != -delta1"
        );
        require(!manager.isUnlocked(), "manager left unlocked");
        _assertSettled(key);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        Request memory r = abi.decode(data, (Request));
        require(manager.isUnlocked(), "manager not unlocked");
        _assertSettled(r.key);
        BalanceDelta delta = manager.swap(r.key, r.params, r.hookData);
        require(manager.currencyDelta(address(this), r.key.currency0) == delta.amount0(), "open delta0 mismatch");
        require(manager.currencyDelta(address(this), r.key.currency1) == delta.amount1(), "open delta1 mismatch");
        _assertHookSettled(r.key);

        _settle(r.key.currency0, delta.amount0(), r.payer, r.payment);
        _settle(r.key.currency1, delta.amount1(), r.payer, r.payment);
        // Fault modes intentionally leave a debt or credit for PoolManager.unlock to reject.
        if (r.payment == Payment.Full) _assertSettled(r.key);
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 delta, address payer, Payment payment) private {
        if (delta < 0 && payment != Payment.SkipDebt) {
            uint256 debt = uint256(-int256(delta));
            if (payment == Payment.Underpay) --debt;
            if (payment == Payment.Overpay) ++debt;
            currency.settle(manager, payer, debt, false);
        } else if (delta > 0 && payment != Payment.SkipCredit) {
            currency.take(manager, payer, uint256(int256(delta)), false);
        }
    }

    function _assertSettled(PoolKey memory key) private view {
        require(manager.getNonzeroDeltaCount() == 0, "nonzero delta count");
        require(manager.currencyDelta(address(this), key.currency0) == 0, "unsettled router ETH");
        require(manager.currencyDelta(address(this), key.currency1) == 0, "unsettled router GEOM");
        _assertHookSettled(key);
    }

    function _assertHookSettled(PoolKey memory key) private view {
        require(manager.currencyDelta(address(key.hooks), key.currency0) == 0, "hook ETH delta");
        require(manager.currencyDelta(address(key.hooks), key.currency1) == 0, "hook GEOM delta");
    }

    receive() external payable {}
}
