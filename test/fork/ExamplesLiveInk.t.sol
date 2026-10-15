// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {LiveInkForkHarness} from "./LiveInkFork.sol";
import {PluginManifest} from "../../src/hookit/PluginManifest.sol";
import {SwapCounterPlugin, SwapCounterDeclaration} from "../../src/examples/SwapCounterPlugin.sol";
import {BuyBurnPlugin, BuyBurnDeclaration} from "../../src/examples/BuyBurnPlugin.sol";
import {MyPlugin, MyPluginDeclaration} from "../../src/MyPlugin.sol";

/// @notice The live-Ink fork harness on both examples and on the starter (skipped without INK_RPC_URL).
contract SwapCounterLiveInkTest is LiveInkForkHarness {
    function _deployPlugin(address registry) internal override returns (address) {
        return address(new SwapCounterPlugin(registry));
    }

    function _manifest(address p) internal view override returns (PluginManifest memory) {
        return SwapCounterDeclaration.manifest(p);
    }
}

contract BuyBurnLiveInkTest is LiveInkForkHarness {
    function _deployPlugin(address registry) internal override returns (address) {
        return address(new BuyBurnPlugin(registry));
    }

    function _manifest(address p) internal view override returns (PluginManifest memory) {
        return BuyBurnDeclaration.manifest(p);
    }

    function _initData() internal pure override returns (bytes memory) {
        return abi.encode(uint256(500));
    }
}

contract MyPluginLiveInkTest is LiveInkForkHarness {
    function _deployPlugin(address registry) internal override returns (address) {
        return address(new MyPlugin(registry));
    }

    function _manifest(address p) internal view override returns (PluginManifest memory) {
        return MyPluginDeclaration.manifest(p);
    }
}
