// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PluginHarness} from "./harness/PluginHarness.sol";
import {IHookPlugin} from "../src/hookit/IHookPlugin.sol";
import {PluginManifest} from "../src/hookit/PluginManifest.sol";
import {MyPlugin, MyPluginDeclaration} from "../src/MyPlugin.sol";

/// @notice Your plugin's tests. Inheriting PluginHarness gives you the full conformance suite; add one unit test per
///         rule of your mechanic below (TODO).
contract MyPluginTest is PluginHarness {
    function _deployPlugin(address registry) internal override returns (address) {
        return address(new MyPlugin(registry));
    }

    function _manifest(address p) internal view override returns (PluginManifest memory) {
        return MyPluginDeclaration.manifest(p);
    }

    // TODO(initData): override `_initData(seed)` to return valid launch parameters for fuzzed launches.
    // TODO(potBps): override `_potBps()` if your plugin needs a specific pot share.
    // TODO(invariants): override `_afterEachCall(point, pool)` to assert your ledger invariants after every call.

    function test_countsBuysOnly() public {
        HPool memory p = _newPool(hook, 0, 1);
        _launch(p, 1);
        IHookPlugin.AfterSwapCtx memory c = _afterSwapCtx(p, 0, false);
        c.isBuy = true;
        hook.afterSwap(c);
        c.isBuy = false;
        hook.afterSwap(c);
        assertEq(MyPlugin(plugin).poolState(address(hook), p.id), 1);
    }
}
