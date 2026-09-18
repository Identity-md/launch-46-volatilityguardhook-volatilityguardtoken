// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GuardFixture} from "./Guard.t.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract HostileToken {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address hook;
    address manager;
    bytes payload;
    bool public armed;
    bool public attempted;
    bool public callbackAccepted;
    bool public unlockAccepted;

    constructor() {
        balanceOf[msg.sender] = 1e27;
    }

    function arm(address h, address m, bytes memory p) external {
        hook = h;
        manager = m;
        payload = p;
        armed = true;
    }

    function approve(address spender, uint256 n) external returns (bool) {
        allowance[msg.sender][spender] = n;
        return true;
    }

    function transfer(address to, uint256 n) external returns (bool) {
        balanceOf[msg.sender] -= n;
        balanceOf[to] += n;
        return true;
    }

    function transferFrom(address from, address to, uint256 n) external returns (bool) {
        allowance[from][msg.sender] -= n;
        balanceOf[from] -= n;
        balanceOf[to] += n;
        if (armed) {
            attempted = true;
            (callbackAccepted,) = hook.call(payload);
            (unlockAccepted,) = manager.call(abi.encodeWithSignature("unlock(bytes)", bytes("")));
        }
        return true;
    }
}

contract ReentrancyTest is GuardFixture {
    function test_hostileTokenSettlementCannotForgeCallbackOrUnlock() public {
        HostileToken hostile = new HostileToken();
        hostile.approve(address(router), type(uint256).max);
        PoolKey memory k = key;
        bool direction = address(hostile) < address(a);
        k.currency0 = Currency.wrap(direction ? address(hostile) : address(a));
        k.currency1 = Currency.wrap(direction ? address(a) : address(hostile));
        manager.initialize(k, Q96);
        router.modify(k, ModifyLiquidityParams(-600, 600, 1e22, 0));
        SwapParams memory params =
            SwapParams(direction, -int256(1e17), direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
        hostile.arm(
            address(hook), address(manager), abi.encodeCall(IHooks.beforeSwap, (address(this), k, params, bytes("")))
        );
        router.swap(k, params);
        assertTrue(hostile.attempted());
        assertFalse(hostile.callbackAccepted());
        assertFalse(hostile.unlockAccepted());
        assertEq(hostile.balanceOf(address(hook)), 0);
    }
}
