// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager, SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency, CurrencyLibrary} from "@uniswap/v4-core/src/types/Currency.sol";
import {ERC20} from "solady/src/tokens/ERC20.sol";
import {FixedPointMathLib} from "solady/src/utils/FixedPointMathLib.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";
import {console} from "forge-std/console.sol";

contract OrbitalHook is BaseHook, ERC20, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;
    using SafeTransferLib for address;
    using FixedPointMathLib for uint256;

    // NOTE: ---------------------------------------------------------
    // Orbital Hook implements a custom AMM curve for 3-asset stablecoin pools
    // Equation: (R-x)^2 + (R-y)^2 + (R-z)^2 = L^2
    // ---------------------------------------------------------------

    // The "Radius" or theoretical maximum capacity for the curve
    uint256 public constant R = 1_000_000e18;
    
    // LP Fee: 0.01% (100 pips if denominator is 1e6, or 1000 if denominator is 1e7?)
    // User requested "1000". Let's assume denominator 1,000,000. So 1000/1,000,000 = 0.1%.
    uint256 public constant LP_FEE = 1000; 
    uint256 public constant FEE_DENOMINATOR = 1_000_000;

    // The invariant constant squared
    uint256 public L_SQUARED;

    // Virtual reserves for the 3 assets managed by this hook
    mapping(Currency => uint256) public reserves;

    // The three tokens in the orbital system
    Currency public immutable token0;
    uint8 public immutable decimals0;
    Currency public immutable token1;
    uint8 public immutable decimals1;
    Currency public immutable token2;
    uint8 public immutable decimals2;

    // Events
    event LiquidityAdded(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 amount2,
        uint256 shares
    );
    event LiquidityRemoved(
        address indexed provider,
        uint256 amount0,
        uint256 amount1,
        uint256 amount2,
        uint256 shares
    );

    uint256 private locked = 1;
    modifier nonReentrant() {
        require(locked == 1, "REENTRANCY");
        locked = 2;
        _;
        locked = 1;
    }

    constructor(
        IPoolManager _poolManager,
        Currency _token0,
        Currency _token1,
        Currency _token2
    ) BaseHook(_poolManager) {
        token0 = _token0;
        token1 = _token1;
        token2 = _token2;
        
        decimals0 = ERC20(Currency.unwrap(_token0)).decimals();
        decimals1 = ERC20(Currency.unwrap(_token1)).decimals();
        decimals2 = ERC20(Currency.unwrap(_token2)).decimals();
    }

    // Required override for Solady ERC20
    function name() public pure override returns (string memory) {
        return "Orbital LP";
    }
    function symbol() public pure override returns (string memory) {
        return "ORB";
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
        
        console.log("BeforeSwap Reserves:", x, y, z);
        console.log("L_SQUARED:", L_SQUARED);
        
        // Get decimals
        uint8 decimalsIn = _getDecimals(inputCurrency);
        uint8 decimalsOut = _getDecimals(outputCurrency);
        uint8 decimalsThird = _getDecimals(thirdToken);

        // 4. Calculate Output Amount using Orbital Math
        bool exactInput = params.amountSpecified < 0;
        uint256 amountIn;
        uint256 amountOut;

        if (exactInput) {
            amountIn = uint256(-params.amountSpecified);
            // Apply Fee to Input
            uint256 fee = amountIn * LP_FEE / FEE_DENOMINATOR;
            uint256 amountInNet = amountIn - fee;
            
            amountOut = calculateOrbitalSwapExactInput(x, y, z, amountInNet, decimalsIn, decimalsOut, decimalsThird);
        } else {
            amountOut = uint256(params.amountSpecified);
            // Calculate required input for this output
            uint256 amountInRaw = calculateOrbitalSwapExactOutput(x, y, z, amountOut, decimalsIn, decimalsOut, decimalsThird);
            
            // Add Fee to Input: amountIn = amountInRaw / (1 - feeRate)
            // amountIn * (1 - feeRate) = amountInRaw
            // amountIn * (DENOM - FEE) / DENOM = amountInRaw
            // amountIn = amountInRaw * DENOM / (DENOM - FEE)
            amountIn = amountInRaw * FEE_DENOMINATOR / (FEE_DENOMINATOR - LP_FEE) + 1;
        }

        // 5. Update Reserves
        reserves[inputCurrency] = x + amountIn;
        reserves[outputCurrency] = y - amountOut;
        
        // Update Invariant to capture fee growth
        _updateLSquared();

        // 6. Update PoolManager Accounting
        // We take input tokens from PoolManager (which received them from swapper)
        poolManager.take(inputCurrency, address(this), amountIn);
        
        // We send output tokens to PoolManager (to be sent to swapper)
        poolManager.sync(outputCurrency);
        Currency.unwrap(outputCurrency).safeTransfer(address(poolManager), amountOut);
        poolManager.settle();

        // 7. Return Delta to PoolManager
        // The delta returned must match the swap execution from the Pool's perspective.
        // toBeforeSwapDelta takes (int128 delta0, int128 delta1)
        
        BeforeSwapDelta hookDelta;
        if (params.zeroForOne) {
             // Input = Token0, Output = Token1
             hookDelta = toBeforeSwapDelta(int128(int256(amountIn)), -int128(int256(amountOut)));
        } else {
             // Input = Token1, Output = Token0
             hookDelta = toBeforeSwapDelta(-int128(int256(amountOut)), int128(int256(amountIn)));
        }

        return (BaseHook.beforeSwap.selector, hookDelta, 0);
    }
    
    function calculateOrbitalSwapExactInput(
        uint256 x,
        uint256 y,
        uint256 z,
        uint256 amountIn,
        uint8 decimalsX,
        uint8 decimalsY,
        uint8 decimalsZ
    ) internal view returns (uint256 amountOut) {
        // Normalize to 18 decimals
        uint256 x18 = _to18(x, decimalsX);
        uint256 y18 = _to18(y, decimalsY);
        uint256 z18 = _to18(z, decimalsZ);
        uint256 amountIn18 = _to18(amountIn, decimalsX);
        
        // (R - (x + dx))^2 + (R - (y - dy))^2 + (R - z)^2 = L^2
        
        require(x18 + amountIn18 < R, "Orbital: Reserves exceed Radius");
        
        uint256 termX_new = (R - (x18 + amountIn18)) ** 2;
        uint256 termZ = (R - z18) ** 2;
        
        // L^2 - termX_new - termZ = termY_new
        uint256 currentL2 = L_SQUARED; // L_SQUARED is already based on 18 decimals if updated correctly
        require(currentL2 >= termX_new + termZ, "Orbital: Invariant violation");
        
        uint256 termY_new = currentL2 - termX_new - termZ;
        
        // y_new = R - sqrt(termY_new)
        uint256 sqrtTermY = termY_new.sqrt();
        require(R >= sqrtTermY, "Orbital: Math error");
        
        uint256 y_new18 = R - sqrtTermY;
        
        require(y18 >= y_new18, "Orbital: Negative output");
        uint256 amountOut18 = y18 - y_new18;
        
        // Denormalize
        amountOut = _from18(amountOut18, decimalsY);
    }

    function calculateOrbitalSwapExactOutput(
        uint256 x,
        uint256 y,
        uint256 z,
        uint256 amountOut,
        uint8 decimalsX,
        uint8 decimalsY,
        uint8 decimalsZ
    ) internal view returns (uint256 amountIn) {
        // Normalize to 18 decimals
        uint256 x18 = _to18(x, decimalsX);
        uint256 y18 = _to18(y, decimalsY);
        uint256 z18 = _to18(z, decimalsZ);
        uint256 amountOut18 = _to18(amountOut, decimalsY);
        
        // (R - (x + dx))^2 + (R - (y - dy))^2 + (R - z)^2 = L^2
        
        require(y18 > amountOut18, "Orbital: Insufficient liquidity");
        uint256 y_new18 = y18 - amountOut18;
        
        uint256 termY_new = (R - y_new18) ** 2;
        uint256 termZ = (R - z18) ** 2;
        
        // L^2 - termY_new - termZ = termX_new
        uint256 currentL2 = L_SQUARED;
        require(currentL2 >= termY_new + termZ, "Orbital: Invariant violation");
        
        uint256 termX_new = currentL2 - termY_new - termZ;
        
        // x_new = R - sqrt(termX_new)
        uint256 sqrtTermX = termX_new.sqrt();
        require(R >= sqrtTermX, "Orbital: Math error");
        
        uint256 x_new18 = R - sqrtTermX;
        
        require(x_new18 >= x18, "Orbital: Negative input");
        uint256 amountIn18 = x_new18 - x18;
        
        // Denormalize
        amountIn = _from18(amountIn18, decimalsX) + 1; // Add 1 wei for rounding up
    }

    function _getDecimals(Currency currency) internal view returns (uint8) {
        if (Currency.unwrap(currency) == Currency.unwrap(token0)) return decimals0;
        if (Currency.unwrap(currency) == Currency.unwrap(token1)) return decimals1;
        if (Currency.unwrap(currency) == Currency.unwrap(token2)) return decimals2;
        return 18;
    }

    function _to18(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount * (10 ** (18 - decimals));
        return amount / (10 ** (decimals - 18));
    }

    function _from18(uint256 amount, uint8 decimals) internal pure returns (uint256) {
        if (decimals == 18) return amount;
        if (decimals < 18) return amount / (10 ** (18 - decimals));
        return amount * (10 ** (decimals - 18));
    }

    // Intercept liquidity additions to enforce custom logic
    function _beforeAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        // In Orbital, standard liquidity addition via the PoolManager is disabled/intercepted
        // because we need to update L_SQUARED and reserves for all 3 assets.
        // Users should call a custom addLiquidity function on this Hook.
        revert("Use custom addLiquidity");
    }

    // Intercept liquidity removals to enforce custom logic
    function _beforeRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        bytes calldata
    ) internal pure override returns (bytes4) {
        revert("Use custom removeLiquidity");
    }

    // -----------------------------------------------
    // Custom Liquidity Logic
    // -----------------------------------------------

    function addLiquidity(
        uint256 amount0Max,
        uint256 amount1Max,
        uint256 amount2Max,
        address to
    ) external nonReentrant returns (uint256 shares) {
        uint256 r0 = reserves[token0];
        uint256 r1 = reserves[token1];
        uint256 r2 = reserves[token2];

        uint256 totalShares = totalSupply();

        uint256 amount0;
        uint256 amount1;
        uint256 amount2;

        if (totalShares == 0) {
            // Initial deposit
            shares = amount0Max + amount1Max + amount2Max;
            
            // Inflation attack protection
            _mint(address(0), 1000);
            shares -= 1000;
            
            amount0 = amount0Max;
            amount1 = amount1Max;
            amount2 = amount2Max;
        } else {
            // Proportional deposit
            uint256 s0 = amount0Max.mulDiv(totalShares, r0);
            uint256 s1 = amount1Max.mulDiv(totalShares, r1);
            uint256 s2 = amount2Max.mulDiv(totalShares, r2);
            
            shares = s0 < s1 ? s0 : s1;
            shares = shares < s2 ? shares : s2;
            
            require(shares > 0, "Zero shares");
            
            amount0 = shares.mulDiv(r0, totalShares);
            amount1 = shares.mulDiv(r1, totalShares);
            amount2 = shares.mulDiv(r2, totalShares);
        }
        
        // Transfer tokens directly to the Hook
        if (amount0 > 0) {
            Currency.unwrap(token0).safeTransferFrom(msg.sender, address(this), amount0);
        }
        if (amount1 > 0) {
            Currency.unwrap(token1).safeTransferFrom(msg.sender, address(this), amount1);
        }
        if (amount2 > 0) {
            Currency.unwrap(token2).safeTransferFrom(msg.sender, address(this), amount2);
        }
        
        reserves[token0] += amount0;
        reserves[token1] += amount1;
        reserves[token2] += amount2;
        
        _mint(to, shares);
        _updateLSquared();
        
        console.log("L_SQUARED updated:", L_SQUARED);
        console.log("Reserves:", reserves[token0], reserves[token1], reserves[token2]);

        emit LiquidityAdded(to, amount0, amount1, amount2, shares);
    }

    function removeLiquidity(uint256 shares, address to) external nonReentrant returns (uint256 amount0, uint256 amount1, uint256 amount2) {
        require(shares > 0, "Zero shares");
        uint256 totalShares = totalSupply();
        
        uint256 r0 = reserves[token0];
        uint256 r1 = reserves[token1];
        uint256 r2 = reserves[token2];
        
        amount0 = shares.mulDiv(r0, totalShares);
        amount1 = shares.mulDiv(r1, totalShares);
        amount2 = shares.mulDiv(r2, totalShares);
        
        _burn(msg.sender, shares);
        
        reserves[token0] -= amount0;
        reserves[token1] -= amount1;
        reserves[token2] -= amount2;
        
        _updateLSquared();
        
        // Transfer tokens directly to user
        if (amount0 > 0) Currency.unwrap(token0).safeTransfer(to, amount0);
        if (amount1 > 0) Currency.unwrap(token1).safeTransfer(to, amount1);
        if (amount2 > 0) Currency.unwrap(token2).safeTransfer(to, amount2);
        
        emit LiquidityRemoved(msg.sender, amount0, amount1, amount2, shares);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        // Not used anymore as we handle transfers directly
        return "";
    }
    function _updateLSquared() internal {
        uint256 x = _to18(reserves[token0], decimals0);
        uint256 y = _to18(reserves[token1], decimals1);
        uint256 z = _to18(reserves[token2], decimals2);
        
        // (R-x)^2 + (R-y)^2 + (R-z)^2 = L^2
        // We assume R > x, y, z. If reserves > R, the math breaks (negative radius).
        
        uint256 term1 = (R > x) ? (R - x) : 0;
        uint256 term2 = (R > y) ? (R - y) : 0;
        uint256 term3 = (R > z) ? (R - z) : 0;
        
        L_SQUARED = term1 * term1 + term2 * term2 + term3 * term3;
    }    // Read functions
    function getOptimalAddLiquidity(
        uint256 amount0
    ) external view returns (uint256 amount1, uint256 amount2) {
        uint256 r0 = reserves[token0];
        uint256 r1 = reserves[token1];
        uint256 r2 = reserves[token2];

        if (r0 == 0) return (0, 0); // Cannot determine ratio if empty

        amount1 = amount0.mulDiv(r1, r0);
        amount2 = amount0.mulDiv(r2, r0);
    }
}
