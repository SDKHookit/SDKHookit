// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {HookitInk} from "../src/hookit/HookitInk.sol";
import {PluginManifest, ManifestJson} from "../src/hookit/PluginManifest.sol";
import {RegistryRules} from "../src/hookit/RegistryRules.sol";
import {SwapCounterPlugin, SwapCounterDeclaration} from "../src/examples/SwapCounterPlugin.sol";
import {BuyBurnPlugin, BuyBurnDeclaration} from "../src/examples/BuyBurnPlugin.sol";
import {MyPlugin, MyPluginDeclaration} from "../src/MyPlugin.sol";

/// @title Manifest
/// @notice Prints (and writes to manifests/<name>.json) the Hookit Workshop submission manifest of a plugin: exactly
///         the arguments of `ModuleRegistry.addModule` except `metadataHash`, plus the runtime codehash. Nothing is
///         broadcast: this script never calls `vm.startBroadcast` and needs no key.
///
///         Before deploying (codehash of your local build, deployed with the live ModuleRegistry address):
///           forge script script/Manifest.s.sol --sig "run(string)" my-plugin
///         After deploying on Ink (reads the deployed code; this is the one you submit):
///           forge script script/Manifest.s.sol --sig "run(string,address)" my-plugin 0xYourPlugin --rpc-url ink
/// @dev Add your plugin to `_deployLocal` and `_declaration` when you rename MyPlugin.
contract Manifest is Script {
    function run(string calldata name) external {
        _run(name, address(0));
    }

    function run(string calldata name, address deployed) external {
        _run(name, deployed);
    }

    function _run(string calldata name, address deployed) internal {
        // A local, simulated deployment with the live ModuleRegistry address (an immutable inside the runtime code).
        address local = _deployLocal(name, HookitInk.MODULE_REGISTRY);
        address plugin = local;
        if (deployed != address(0)) {
            require(deployed.code.length != 0, "no code at that address on this chain: pass --rpc-url ink");
            (bool ok, bytes memory ret) = deployed.staticcall(abi.encodeWithSignature("moduleRegistry()"));
            require(
                ok && ret.length == 32 && abi.decode(ret, (address)) == HookitInk.MODULE_REGISTRY,
                "plugin was not constructed with HookitInk.MODULE_REGISTRY"
            );
            if (deployed.codehash != local.codehash) {
                console2.log("WARNING: deployed codehash differs from this local build (compiler settings or source).");
                console2.log("         The manifest uses the DEPLOYED codehash; publish the exact source + settings.");
            }
            plugin = deployed;
        }

        PluginManifest memory m = _declaration(name, plugin);
        RegistryRules.checkAddModule(m, HookitInk.HOOK_API_MASK);
        RegistryRules.checkReviewRules(m);

        string memory json = ManifestJson.toJson(m, HookitInk.CHAIN_ID);
        console2.log(json);
        string memory path = string.concat("manifests/", name, ".json");
        vm.writeFile(path, json);
        console2.log(string.concat("written: ", path));
        if (deployed == address(0)) {
            console2.log(
                "NOTE: plugin address above is a local simulation. Deploy on Ink, then rerun with the address."
            );
        }
        console2.log("addModule calldata for the owner (metadataHash = keccak256 of the review record):");
        console2.log(ManifestJson.castCalldata(m));
    }

    function _deployLocal(string calldata name, address registry) internal returns (address) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("swap-counter")) return address(new SwapCounterPlugin(registry));
        if (h == keccak256("buy-burn")) return address(new BuyBurnPlugin(registry));
        if (h == keccak256("my-plugin")) return address(new MyPlugin(registry));
        revert("unknown plugin name: add it to script/Manifest.s.sol");
    }

    function _declaration(string calldata name, address plugin) internal view returns (PluginManifest memory) {
        bytes32 h = keccak256(bytes(name));
        if (h == keccak256("swap-counter")) return SwapCounterDeclaration.manifest(plugin);
        if (h == keccak256("buy-burn")) return BuyBurnDeclaration.manifest(plugin);
        if (h == keccak256("my-plugin")) return MyPluginDeclaration.manifest(plugin);
        revert("unknown plugin name: add it to script/Manifest.s.sol");
    }
}
