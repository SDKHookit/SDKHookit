// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {HookitInk} from "../src/hookit/HookitInk.sol";
import {PluginManifest, ManifestJson} from "../src/hookit/PluginManifest.sol";
import {PluginLimitsDecl, CompatDecl, IHookitModuleRegistry} from "../src/hookit/ModuleRegistryTypes.sol";
import {SwapCounterPlugin, SwapCounterDeclaration} from "../src/examples/SwapCounterPlugin.sol";
import {BuyBurnPlugin, BuyBurnDeclaration} from "../src/examples/BuyBurnPlugin.sol";

/// @notice The committed sample manifests (examples/*.json) are exactly what script/Manifest.s.sol prints, and the
///         JSON decodes back to the very `addModule` calldata the declaration encodes (manifest -> addModule).
contract ManifestTest is Test {
    bytes32 internal constant META = keccak256("review record");

    function test_swapCounterSample() public {
        address local = address(new SwapCounterPlugin(HookitInk.MODULE_REGISTRY));
        _check("examples/manifest.swap-counter.json", local, true);
    }

    function test_buyBurnSample() public {
        address local = address(new BuyBurnPlugin(HookitInk.MODULE_REGISTRY));
        _check("examples/manifest.buy-burn.json", local, false);
    }

    function _check(string memory path, address local, bool swapCounter) internal {
        string memory json = vm.readFile(path);
        address plugin = vm.parseJsonAddress(json, ".plugin");
        vm.etch(plugin, local.code); // the sample's address with this build's runtime code
        PluginManifest memory d =
            swapCounter ? SwapCounterDeclaration.manifest(plugin) : BuyBurnDeclaration.manifest(plugin);

        assertEq(vm.parseJsonBytes32(json, ".codehash"), local.codehash, "sample codehash = this build (regenerate?)");
        assertEq(ManifestJson.toJson(d, HookitInk.CHAIN_ID), json, "sample = script output, byte for byte");

        PluginManifest memory p = _parse(json);
        assertEq(
            abi.encodeCall(
                IHookitModuleRegistry.addModule,
                (p.plugin, p.caps, p.hookApiMask, p.limits, p.maxPotBps, p.maxSurchargeBps, p.compat, META)
            ),
            abi.encodeCall(
                IHookitModuleRegistry.addModule,
                (d.plugin, d.caps, d.hookApiMask, d.limits, d.maxPotBps, d.maxSurchargeBps, d.compat, META)
            ),
            "JSON -> addModule calldata = declaration -> addModule calldata"
        );
        assertEq(vm.parseJsonUint(json, ".chainId"), 57073);
        assertEq(vm.parseJsonUint(json, ".pluginApi"), 3);
    }

    /// @notice Reference decoder of the manifest JSON (MANIFEST.md) into the addModule arguments.
    function _parse(string memory json) internal pure returns (PluginManifest memory p) {
        p.plugin = vm.parseJsonAddress(json, ".plugin");
        p.caps = uint64(vm.parseUint(vm.parseJsonString(json, ".caps")));
        p.hookApiMask = uint64(vm.parseUint(vm.parseJsonString(json, ".hookApiMask")));
        p.limits.launchGas = uint32(vm.parseJsonUint(json, ".limits.launchGas"));
        uint256[] memory g = vm.parseJsonUintArray(json, ".limits.gas");
        require(g.length == 10, "gas[10]");
        for (uint256 i; i < 10; ++i) {
            p.limits.gas[i] = uint32(g[i]);
        }
        uint256[] memory mi = vm.parseJsonUintArray(json, ".limits.maxIntents");
        require(mi.length == 4, "maxIntents[4]");
        for (uint256 i; i < 4; ++i) {
            p.limits.maxIntents[i] = uint8(mi[i]);
        }
        p.maxPotBps = uint16(vm.parseJsonUint(json, ".maxPotBps"));
        p.maxSurchargeBps = uint16(vm.parseJsonUint(json, ".maxSurchargeBps"));
        uint256[] memory inc = vm.parseJsonUintArray(json, ".compat.incompatibleWith");
        p.compat.incompatibleWith = new uint32[](inc.length);
        for (uint256 i; i < inc.length; ++i) {
            p.compat.incompatibleWith[i] = uint32(inc[i]);
        }
        p.compat.forbiddenBuiltins = uint16(vm.parseJsonUint(json, ".compat.forbiddenBuiltins"));
        p.compat.groups = uint64(vm.parseUint(vm.parseJsonString(json, ".compat.groups")));
        p.compat.exclusiveGroups = uint64(vm.parseUint(vm.parseJsonString(json, ".compat.exclusiveGroups")));
        p.compat.conflictGroups = uint64(vm.parseUint(vm.parseJsonString(json, ".compat.conflictGroups")));
    }
}
