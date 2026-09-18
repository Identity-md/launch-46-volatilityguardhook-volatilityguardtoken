// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GuardFixture} from "./Guard.t.sol";
import {Test} from "forge-std/Test.sol";
import {VolatilityGuardHook as Hook} from "../src/VolatilityGuardHook.sol";
import {VolatilityGuardToken as Token} from "../src/VolatilityGuardToken.sol";
import {Router} from "./Router.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract Handler is Test {
    Router router;
    Hook hook;
    PoolKey key;
    uint256 public success;
    uint256 public failures;

    constructor(Router r, Hook h, PoolKey memory k, Token a, Token b) {
        router = r;
        hook = h;
        key = k;
        a.approve(address(r), type(uint256).max);
        b.approve(address(r), type(uint256).max);
    }

    function trade(bool direction, bool exactOut, uint96 raw) external {
        int256 amount = int256(bound(raw, 1e9, 1e20));
        try router.swap(
            key,
            SwapParams(
                direction,
                exactOut ? amount : -amount,
                direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            )
        ) {
            ++success;
        } catch {
            ++failures;
        }
    }

    function advance(uint16 raw) external {
        vm.warp(block.timestamp + bound(raw, 1, 1000));
        hook.checkpoint(key);
    }
}

contract GuardInvariantTest is GuardFixture {
    Handler handler;

    function setUp() public override {
        super.setUp();
        handler = new Handler(router, hook, key, a, b);
        a.transfer(address(handler), 1e25);
        b.transfer(address(handler), 1e25);
        targetContract(address(handler));
    }

    function invariant_supplyAndManagerAccounting() public view {
        assertEq(a.balanceOf(address(this)) + a.balanceOf(address(handler)) + a.balanceOf(address(manager)), 1e27);
        assertEq(b.balanceOf(address(this)) + b.balanceOf(address(handler)) + b.balanceOf(address(manager)), 1e27);
        assertEq(a.balanceOf(address(hook)), 0);
        assertEq(b.balanceOf(address(hook)), 0);
    }

    function invariant_boundedState() public view {
        (, uint24 ewma, uint32 used,, uint8 count) = hook.status(key.toId());
        assertLe(used, 20000);
        assertLe(count, 16);
        assertGt(count, 0);
        assertLe(ewma, 2000);
    }
}
