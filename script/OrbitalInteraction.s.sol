// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseScript} from "./base/BaseScript.sol";
import {OrbitalDeploy} from "./OrbitalDeploy.s.sol";
import {OrbitalHook} from "../src/OrbitalHook.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPoolManager, SwapParams} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {console} from "forge-std/console.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PathKey} from "hookmate/interfaces/router/PathKey.sol";
import {SafeTransferLib} from "solady/src/utils/SafeTransferLib.sol";

contract OrbitalInteraction is BaseScript {
    using PoolIdLibrary for PoolKey;
    using SafeTransferLib for address;

    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    function run() public {
        // 1. Deploy Hook
        OrbitalDeploy deployer = new OrbitalDeploy();
        address hookAddress = deployer.run();
        OrbitalHook hook = OrbitalHook(hookAddress);

        address user = msg.sender;
        console.log("User:", user);

        // 2. Prefund Wallet
        vm.deal(user, 100 ether);
        
        address usdcWhale = 0x7713974908Be4BEd47172370115e8b1219F4A5f0;
        address usdtWhale = 0x47ac0Fb4F2D84898e4D9E7b4DaB3C24507a6D503;
        address daiWhale = 0x40ec5B33f54e0E8A33A975908C5BA1c14e5BbbDf;

        vm.startPrank(usdcWhale);
        address(USDC).safeTransfer(user, 1_000_000 * 1e6);
        vm.stopPrank();

        vm.startPrank(usdtWhale);
        address(USDT).safeTransfer(user, 1_000_000 * 1e6);
        vm.stopPrank();

        vm.startPrank(daiWhale);
        address(DAI).safeTransfer(user, 1_000_000 * 1e18);
        vm.stopPrank();

        vm.startBroadcast();

        // 3. Approve Hook and Router
        address(USDC).safeApprove(address(hook), type(uint256).max);
        address(USDT).safeApprove(address(hook), type(uint256).max);
        address(DAI).safeApprove(address(hook), type(uint256).max);
        
        address(USDC).safeApprove(address(swapRouter), type(uint256).max);
        address(USDT).safeApprove(address(swapRouter), type(uint256).max);
        address(DAI).safeApprove(address(swapRouter), type(uint256).max);

        // 4. Add Liquidity
        console.log("Adding Liquidity...");
        hook.addLiquidity(
            100_000 * 1e6, // USDC
            100_000 * 1e6, // USDT
            100_000 * 1e18, // DAI
            user
        );
        
        // 5. Initialize Pools
        uint160 SQRT_PRICE_1_1 = 79228162514264337593543950336;
        
        initializePool(USDC, USDT, hookAddress, SQRT_PRICE_1_1);
        initializePool(USDT, DAI, hookAddress, SQRT_PRICE_1_1);
        initializePool(USDC, DAI, hookAddress, SQRT_PRICE_1_1);

        // 6. Swap USDC -> USDT
        console.log("Swapping USDC -> USDT...");
        swap(USDC, USDT, hookAddress, 1000 * 1e6);

        vm.stopBroadcast();
    }

    function initializePool(address tokenA, address tokenB, address hook, uint160 sqrtPriceX96) internal {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(token0),
            currency1: Currency.wrap(token1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook)
        });
        
        poolManager.initialize(key, sqrtPriceX96);
    }

    function swap(address tokenIn, address tokenOut, address hook, uint256 amountIn) internal {
        bool zeroForOne = tokenIn < tokenOut;
        
        PathKey[] memory path = new PathKey[](1);
        path[0] = PathKey({
            intermediateCurrency: Currency.wrap(tokenOut),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(hook),
            hookData: ""
        });

        swapRouter.swapExactTokensForTokens(
            amountIn,
            0, // amountOutMin
            Currency.wrap(tokenIn),
            path,
            msg.sender,
            block.timestamp + 1000
        );
    }
}
