// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";

contract OrbitalHook is BaseHook {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // NOTE: ---------------------------------------------------------
    // Orbital Hook implements a custom AMM curve for 3-asset stablecoin pools
    // Equation: (R-x)^2 + (R-y)^2 + (R-z)^2 = L^2
    // ---------------------------------------------------------------

    // The "Radius" or theoretical maximum capacity for the curve
    uint256 public constant R = 1_000_000e18;

    // The invariant constant squared
    uint256 public L_SQUARED;

    // Virtual reserves for the 3 assets managed by this hook
    mapping(Currency => uint256) public reserves;

    // The three tokens in the orbital system
    Currency public immutable token0;
    Currency public immutable token1;
    Currency public immutable token2;

    constructor(
        IPoolManager _poolManager,
        Currency _token0,
        Currency _token1,
        Currency _token2
    ) BaseHook(_poolManager) {
        token0 = _token0;
        token1 = _token1;
        token2 = _token2;
    }

    function getHookPermissions()
        public
        pure
        override
        returns (Hooks.Permissions memory)
    {
        return
            Hooks.Permissions({
                beforeInitialize: false,
                afterInitialize: false,
                beforeAddLiquidity: true, // Control liquidity additions
                afterAddLiquidity: false,
                beforeRemoveLiquidity: true,
                afterRemoveLiquidity: false,
                beforeSwap: true, // Override swap logic
                afterSwap: false,
                beforeDonate: false,
                afterDonate: false,
                beforeSwapReturnDelta: true, // Handle token transfers (Flash Accounting)
                afterSwapReturnDelta: false,
                afterAddLiquidityReturnDelta: false,
                afterRemoveLiquidityReturnDelta: false
            });
    }

    // -----------------------------------------------
    // NOTE: see IHooks.sol for function documentation
    // -----------------------------------------------

    function _beforeSwap(
        address,
        PoolKey calldata key,
        SwapParams calldata params,
        bytes calldata
    ) internal override returns (bytes4, BeforeSwapDelta, uint24) {
        // 1. Determine which tokens are involved in this swap
        Currency inputCurrency = params.zeroForOne
            ? key.currency0
            : key.currency1;
        Currency outputCurrency = params.zeroForOne
            ? key.currency1
            : key.currency0;

        // 2. Identify the third token (z) not involved in the swap
        Currency thirdToken;
        if (
            Currency.unwrap(token0) != Currency.unwrap(inputCurrency) &&
            Currency.unwrap(token0) != Currency.unwrap(outputCurrency)
        ) thirdToken = token0;
        else if (
            Currency.unwrap(token1) != Currency.unwrap(inputCurrency) &&
            Currency.unwrap(token1) != Currency.unwrap(outputCurrency)
        ) thirdToken = token1;
        else thirdToken = token2;

        // 3. Get current reserves
        uint256 x = reserves[inputCurrency];
        uint256 y = reserves[outputCurrency];
        uint256 z = reserves[thirdToken];

        // 4. Calculate Output Amount using Orbital Math
        // (R - (x + dx))^2 + (R - (y - dy))^2 + (R - z)^2 = L^2
        // We need to solve for dy (amountOut)

        uint256 amountIn = uint256(
            params.amountSpecified < 0
                ? -params.amountSpecified
                : params.amountSpecified
        );

        // Note: This is a simplified placeholder for the actual math implementation
        // In a real implementation, we would solve the quadratic equation here
        // For now, we will just simulate a 1:1 swap to show the structure
        uint256 amountOut = amountIn;

        // 5. Update Reserves
        reserves[inputCurrency] = x + amountIn;
        reserves[outputCurrency] = y - amountOut;

        // 6. Return Delta to PoolManager
        // We take amountIn from the user and give amountOut to the user
        // Positive delta means the hook takes tokens, Negative means hook gives tokens
        BeforeSwapDelta hookDelta = toBeforeSwapDelta(
            int128(int256(amountIn)),
            -int128(int256(amountOut))
        );

        return (BaseHook.beforeSwap.selector, hookDelta, 0);
    }

    function _beforeAddLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        // In Orbital, standard liquidity addition via the PoolManager is disabled/intercepted
        // because we need to update L_SQUARED and reserves for all 3 assets.
        // Users should call a custom addLiquidity function on this Hook.
        revert("Use custom addLiquidity");
    }

    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata key,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal override returns (bytes4) {
        revert("Use custom removeLiquidity");
    }
}
