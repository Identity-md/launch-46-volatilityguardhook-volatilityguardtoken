// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {SqrtPriceMath} from "v4-core/src/libraries/SqrtPriceMath.sol";

/// @notice Internal launch calculations; not a separately deployed helper.
library BootstrapMath {
    uint160 internal constant OPENING = 792281625142643375935439503360000;

    /// @return lower Widest aligned lower tick.
    /// @return upper Highest aligned upper tick whose price is <= opening, so only token1 is owed.
    /// @return liquidity Affordable liquidity rounded down, capped to uint128 and per-tick cap by caller.
    /// @return tokens Exact rounded-up token1 debt at this liquidity.
    function derive(uint256 budget, uint128 maxLiquidity)
        internal
        pure
        returns (int24 lower, int24 upper, uint128 liquidity, uint256 tokens)
    {
        lower = (TickMath.MIN_TICK / 60) * 60;
        int24 tick = TickMath.getTickAtSqrtPrice(OPENING);
        upper = (tick / 60) * 60;
        uint160 lo = TickMath.getSqrtPriceAtTick(lower);
        uint160 hi = TickMath.getSqrtPriceAtTick(upper);
        uint256 amount = FullMath.mulDiv(budget, 1 << 96, hi - lo);
        if (amount > maxLiquidity) amount = maxLiquidity;
        liquidity = uint128(amount);
        tokens = SqrtPriceMath.getAmount1Delta(lo, hi, liquidity, true);
    }
}
