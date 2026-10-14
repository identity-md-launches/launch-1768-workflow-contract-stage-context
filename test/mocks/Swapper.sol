// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Minimal exact-input swap router for tests. It pays from its own balances (fund it first)
/// and keeps what it receives, with no slippage protection.
contract Swapper is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @dev Exact-input swap of `amountIn` in the `zeroForOne` direction, with empty hookData.
    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (BalanceDelta delta) {
        return swap(key, zeroForOne, amountIn, "");
    }

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData)
        public
        returns (BalanceDelta delta)
    {
        delta = abi.decode(manager.unlock(abi.encode(key, zeroForOne, amountIn, hookData)), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "not manager");
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, bytes memory hookData) =
            abi.decode(data, (PoolKey, bool, uint256, bytes));
        BalanceDelta delta = manager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            hookData
        );
        _settle(key.currency0, delta.amount0());
        _settle(key.currency1, delta.amount1());
        return abi.encode(delta);
    }

    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 owed = uint256(uint128(-amount));
            if (currency.isAddressZero()) {
                manager.settle{value: owed}();
            } else {
                manager.sync(currency);
                IERC20(Currency.unwrap(currency)).transfer(address(manager), owed);
                manager.settle();
            }
        } else if (amount > 0) {
            manager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    receive() external payable {}
}
