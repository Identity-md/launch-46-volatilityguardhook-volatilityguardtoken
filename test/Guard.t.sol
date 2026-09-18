// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {VolatilityGuardHook as Hook} from "../src/VolatilityGuardHook.sol";
import {VolatilityGuardToken as Token} from "../src/VolatilityGuardToken.sol";
import {Router} from "./Router.sol";

abstract contract GuardFixture is Test {
    using StateLibrary for IPoolManager;
    PoolManager manager;
    Hook hook;
    Token a;
    Token b;
    Router router;
    PoolKey key;
    uint160 constant Q96 = 1 << 96;

    function setUp() public virtual {
        vm.warp(1000);
        manager = new PoolManager(address(this));
        bytes memory code = abi.encodePacked(type(Hook).creationCode, abi.encode(address(manager)));
        bytes32 hash = keccak256(code);
        for (uint256 i;; ++i) {
            address predicted =
                address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), hash)))));
            if (uint160(predicted) & 0x3fff != 0x10c0) continue;
            hook = new Hook{salt: bytes32(i)}(IPoolManager(address(manager)));
            break;
        }
        a = new Token();
        b = new Token();
        if (address(a) > address(b)) (a, b) = (b, a);
        router = new Router(IPoolManager(address(manager)));
        a.approve(address(router), type(uint256).max);
        b.approve(address(router), type(uint256).max);
        key = PoolKey(Currency.wrap(address(a)), Currency.wrap(address(b)), 3000, 60, IHooks(address(hook)));
        manager.initialize(key, Q96);
        router.modify(key, ModifyLiquidityParams(-600, 600, 1e22, 0));
    }

    function swap(bool direction, int256 amount) internal returns (BalanceDelta) {
        return router.swap(
            key, SwapParams(direction, amount, direction ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
    }

    function normal() internal {
        vm.warp(block.timestamp + 120);
        hook.checkpoint(key);
    }
    receive() external payable {}
}

contract GuardTest is GuardFixture {
    using StateLibrary for IPoolManager;

    function test_permissions() public view {
        assertEq(uint160(address(hook)) & 0x3fff, 0x10c0);
        assertFalse(hook.getHookPermissions().beforeRemoveLiquidity);
        assertFalse(hook.getHookPermissions().beforeSwapReturnDelta);
    }

    function test_bothDirectionsAndModes() public {
        for (uint256 i; i < 4; ++i) {
            bool direction = i % 2 == 0;
            int256 amount = i < 2 ? -int256(1e17) : int256(1e17);
            uint256 pre0 = a.balanceOf(address(this));
            uint256 pre1 = b.balanceOf(address(this));
            BalanceDelta d = swap(direction, amount);
            assertEq(int256(a.balanceOf(address(this))) - int256(pre0), int256(d.amount0()));
            assertEq(int256(b.balanceOf(address(this))) - int256(pre1), int256(d.amount1()));
            assertEq(a.balanceOf(address(hook)), 0);
            assertEq(b.balanceOf(address(hook)), 0);
        }
    }

    function test_unauthorizedAllEnabledCallbacks() public {
        vm.expectRevert(Hook.Unauthorized.selector);
        hook.afterInitialize(address(this), key, Q96, 0);
        vm.expectRevert(Hook.Unauthorized.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1, Q96 - 1), "");
        vm.expectRevert(Hook.Unauthorized.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1, Q96 - 1), toBalanceDelta(-1, 1), "");
    }

    function test_largeSwapRevertsAtomically() public {
        (,, uint32 beforeUsed,,) = hook.status(key.toId());
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        vm.expectRevert();
        swap(true, -int256(1e21));
        (,, uint32 afterUsed,,) = hook.status(key.toId());
        assertEq(beforeUsed, afterUsed);
        (uint160 afterPrice,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, afterPrice);
    }

    function test_splitVolumeCannotEvade() public {
        normal();
        uint256 successes;
        for (uint256 i; i < 100; ++i) {
            try router.swap(
                key,
                SwapParams(
                    i % 2 == 0, -int256(1e19), i % 2 == 0 ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
                )
            ) {
                ++successes;
            } catch {
                break;
            }
        }
        assertGt(successes, 1);
        assertLt(successes, 30);
        (,, uint32 used,,) = hook.status(key.toId());
        assertGt(used, 18000);
    }

    function test_budgetRefillsWithoutIdentity() public {
        normal();
        swap(true, -int256(1e19));
        (,, uint32 used,,) = hook.status(key.toId());
        assertGt(used, 0);
        vm.warp(block.timestamp + 300);
        hook.checkpoint(key);
        (,, used,,) = hook.status(key.toId());
        assertEq(used, 0);
    }

    function test_isolation() public {
        PoolKey memory other = key;
        other.fee = 500;
        manager.initialize(other, Q96);
        swap(true, -int256(1e18));
        (,, uint32 used,,) = hook.status(other.toId());
        assertEq(used, 0);
        (Hook.Mode mode,,,,) = hook.status(other.toId());
        assertEq(uint256(mode), uint256(Hook.Mode.WARMUP));
    }

    function test_staleRecoveryAndExit() public {
        normal();
        vm.warp(block.timestamp + 901);
        hook.checkpoint(key);
        (Hook.Mode mode,,,,) = hook.status(key.toId());
        assertEq(uint256(mode), uint256(Hook.Mode.GUARDED));
        swap(true, -int256(1e17));
        vm.warp(block.timestamp + 120);
        hook.checkpoint(key);
        (mode,,,,) = hook.status(key.toId());
        assertEq(uint256(mode), uint256(Hook.Mode.RECOVERY));
        vm.warp(block.timestamp + 120);
        hook.checkpoint(key);
        (mode,,,,) = hook.status(key.toId());
        assertEq(uint256(mode), uint256(Hook.Mode.NORMAL));
        router.modify(key, ModifyLiquidityParams(-600, 600, -int256(1e22), 0));
        hook.checkpoint(key);
        (mode,,,,) = hook.status(key.toId());
        assertEq(uint256(mode), uint256(Hook.Mode.GUARDED));
    }

    function test_lowLiquidityExit() public {
        router.modify(key, ModifyLiquidityParams(-600, 600, -int256(1e22 - 999), 0));
        vm.expectRevert();
        swap(true, -1);
        router.modify(key, ModifyLiquidityParams(-600, 600, -999, 0));
    }

    function test_callbackOrderAndCheckpointReentrancy() public {
        vm.prank(address(manager));
        vm.expectRevert(Hook.CallbackOrder.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1, Q96 - 1), toBalanceDelta(-1, 1), "");
        vm.prank(address(manager));
        hook.beforeSwap(address(this), key, SwapParams(true, -1, Q96 - 1), "");
        vm.expectRevert(Hook.CallbackOrder.selector);
        hook.checkpoint(key);
        vm.prank(address(manager));
        vm.expectRevert(Hook.CallbackOrder.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1, Q96 - 1), "");
    }

    function test_edgeAmount() public {
        vm.expectRevert();
        swap(true, type(int256).min);
        vm.expectRevert();
        swap(false, type(int256).max);
    }

    function test_stressBoundedRing() public {
        for (uint256 i; i < 160; ++i) {
            vm.warp(block.timestamp + 31);
            swap(i % 2 == 0, -int256(1e16));
        }
        (,,,, uint8 count) = hook.status(key.toId());
        assertEq(count, 16);
    }

    function test_twapUsesTimeBeforeSwapAndEwmaUpdates() public {
        normal();
        swap(true, -int256(1e19));
        (,,, int24 beforeMean,) = hook.status(key.toId());
        assertEq(beforeMean, 0);
        vm.warp(block.timestamp + 30);
        hook.checkpoint(key);
        (, uint24 ewma,, int24 mean,) = hook.status(key.toId());
        assertGt(ewma, 0);
        assertLt(mean, 0);
    }

    function test_ringBoundaryDoesNotForgetReference() public {
        normal();
        swap(true, -int256(1e19));
        vm.warp(block.timestamp + 301);
        hook.checkpoint(key);
        (,,, int24 mean,) = hook.status(key.toId());
        assertLt(mean, 0);
        assertGt(mean, -21);
    }

    function test_initializeAtPriceEdges() public {
        PoolKey memory other = key;
        other.fee = 100;
        manager.initialize(other, TickMath.MIN_SQRT_PRICE);
        (Hook.Mode mode,,,,) = hook.status(other.toId());
        assertEq(uint256(mode), uint256(Hook.Mode.WARMUP));
        other.fee = 200;
        manager.initialize(other, TickMath.MAX_SQRT_PRICE - 1);
        (mode,,,,) = hook.status(other.toId());
        assertEq(uint256(mode), uint256(Hook.Mode.WARMUP));
    }

    function test_wrongPoolAndUninitialized() public {
        PoolKey memory other = key;
        other.hooks = IHooks(address(0));
        vm.expectRevert(Hook.InvalidPool.selector);
        hook.checkpoint(other);
        other = key;
        other.fee = 100;
        vm.expectRevert(Hook.Uninitialized.selector);
        hook.checkpoint(other);
    }

    function test_callbackPoolMismatch() public {
        vm.prank(address(manager));
        hook.beforeSwap(address(123), key, SwapParams(true, -1, Q96 - 1), hex"deadbeef");
        PoolKey memory other = key;
        other.fee = 500;
        vm.prank(address(manager));
        vm.expectRevert(Hook.CallbackOrder.selector);
        hook.afterSwap(address(456), other, SwapParams(true, -1, Q96 - 1), toBalanceDelta(-1, 1), hex"aa");
    }

    function testFuzz_accounting(bool direction, bool exactOut, uint96 raw) public {
        uint256 amount = bound(raw, 1e10, 1e18);
        BalanceDelta d = swap(direction, exactOut ? int256(amount) : -int256(amount));
        assertTrue(direction ? d.amount0() < 0 : d.amount1() < 0);
        assertTrue(direction ? d.amount1() > 0 : d.amount0() > 0);
        assertEq(a.totalSupply(), 1e27);
        assertEq(b.totalSupply(), 1e27);
    }

    function testFuzz_poolIsolation(uint24 fee) public {
        fee = uint24(bound(fee, 1, 999999));
        vm.assume(fee != 3000);
        PoolKey memory other = key;
        other.fee = fee;
        manager.initialize(other, Q96);
        swap(true, -int256(1e17));
        (,, uint32 used,,) = hook.status(other.toId());
        assertEq(used, 0);
    }
}
