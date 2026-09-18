// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

interface IERC20Test {
    function transferFrom(address, address, uint256) external returns (bool);
}

/// @dev Local harness only, never deployed by launch services.
contract Router is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory k, SwapParams memory p) external payable returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(msg.sender, k, true, abi.encode(p))), (BalanceDelta));
    }

    function modify(PoolKey memory k, ModifyLiquidityParams memory p) external payable returns (BalanceDelta) {
        return abi.decode(manager.unlock(abi.encode(msg.sender, k, false, abi.encode(p))), (BalanceDelta));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (address sender, PoolKey memory k, bool swapOp, bytes memory args) =
            abi.decode(data, (address, PoolKey, bool, bytes));
        BalanceDelta d;
        if (swapOp) d = manager.swap(k, abi.decode(args, (SwapParams)), "");
        else (d,) = manager.modifyLiquidity(k, abi.decode(args, (ModifyLiquidityParams)), "");
        settle(k.currency0, d.amount0(), sender);
        settle(k.currency1, d.amount1(), sender);
        return abi.encode(d);
    }

    function settle(Currency c, int128 d, address sender) private {
        if (d < 0) {
            uint256 amount = uint256(-int256(d));
            if (Currency.unwrap(c) == address(0)) {
                manager.settle{value: amount}();
            } else {
                manager.sync(c);
                require(IERC20Test(Currency.unwrap(c)).transferFrom(sender, address(manager), amount));
                manager.settle();
            }
        } else if (d > 0) {
            manager.take(c, sender, uint128(d));
        }
    }
    receive() external payable {}
}
