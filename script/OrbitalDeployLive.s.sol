// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {console} from "forge-std/console.sol";

import {BaseScript} from "./base/BaseScript.sol";
import {OrbitalHook} from "../src/OrbitalHook.sol";

contract OrbitalDeployLive is BaseScript {
    address constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    address constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;

    // Standard CREATE2 factory used by Foundry's vm.broadcast
    address constant CREATE2_FACTORY =
        0x4e59b44847b379578588920cA78FbF26c0B4956C;

    function run() public returns (address hookAddress) {
        uint160 flags = uint160(
            Hooks.BEFORE_SWAP_FLAG |
                Hooks.BEFORE_ADD_LIQUIDITY_FLAG |
                Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG |
                Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
        );
        bytes memory constructorArgs = abi.encode(
            poolManager,
            Currency.wrap(USDC),
            Currency.wrap(USDT),
            Currency.wrap(DAI)
        );

        bytes32 salt;
        (hookAddress, salt) = HookMiner.find(
            CREATE2_FACTORY,
            flags,
            type(OrbitalHook).creationCode,
            constructorArgs
        );

        vm.startBroadcast();
        OrbitalHook hook = new OrbitalHook{salt: salt}(
            poolManager,
            Currency.wrap(USDC),
            Currency.wrap(USDT),
            Currency.wrap(DAI)
        );
        vm.stopBroadcast();

        require(
            address(hook) == hookAddress,
            "OrbitalDeployLive: Hook Address Mismatch"
        );
        console.log("OrbitalHook deployed at:", address(hook));
    }
}
