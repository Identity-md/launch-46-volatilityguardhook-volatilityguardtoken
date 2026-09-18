// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {GuardFixture} from "./Guard.t.sol";
import {BootstrapMath} from "../src/BootstrapMath.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract BootstrapTest is GuardFixture {
    function test_tokenOnlyBootstrap() public {
        PoolKey memory nativeKey = key;
        nativeKey.currency0 = Currency.wrap(address(0));
        nativeKey.currency1 = Currency.wrap(address(a));
        uint160 opening = 792281625142643375935439503360000;
        manager.initialize(nativeKey, opening);
        (int24 lower, int24 upper, uint128 liq, uint256 tokens) =
            BootstrapMath.derive(8e26, Pool.tickSpacingToMaxLiquidityPerTick(60));
        emit log_named_int("lower", lower);
        emit log_named_int("upper", upper);
        emit log_named_uint("liquidity", liq);
        emit log_named_uint("tokens", tokens);
        assertLe(TickMath.getSqrtPriceAtTick(upper), opening);
        assertGt(TickMath.getSqrtPriceAtTick(upper + 60), opening);
        assertLe(tokens, 8e26);
        BalanceDelta seed = router.modify(nativeKey, ModifyLiquidityParams(lower, upper, int256(uint256(liq)), 0));
        assertEq(seed.amount0(), 0);
        assertEq(uint256(-int256(seed.amount1())), tokens);
        vm.expectRevert();
        router.swap(nativeKey, SwapParams(false, -int256(1e18), TickMath.MAX_SQRT_PRICE - 1));
        vm.deal(address(this), 1 ether);
        BalanceDelta buy = router.swap{value: 0.001 ether}(
            nativeKey, SwapParams(true, -int256(0.001 ether), TickMath.MIN_SQRT_PRICE + 1)
        );
        assertLt(buy.amount0(), 0);
        assertGt(buy.amount1(), 0);
        BalanceDelta sell =
            router.swap(nativeKey, SwapParams(false, -int256(buy.amount1() / 2), TickMath.MAX_SQRT_PRICE - 1));
        assertGt(sell.amount0(), 0);
        assertLt(sell.amount1(), 0);
        router.modify(nativeKey, ModifyLiquidityParams(lower, upper, -int256(uint256(liq)), 0));
    }
}
