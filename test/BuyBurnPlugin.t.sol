// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PluginHarness} from "./harness/PluginHarness.sol";
import {MockHookC} from "./harness/MockHookC.sol";
import {IHookPlugin} from "../src/hookit/IHookPlugin.sol";
import {PluginManifest} from "../src/hookit/PluginManifest.sol";
import {BuyBurnPlugin, BuyBurnDeclaration} from "../src/examples/BuyBurnPlugin.sol";

/// @notice Conformance harness (inherited tests) + unit and fuzz tests for example 2.
contract BuyBurnPluginTest is PluginHarness {
    function _deployPlugin(address registry) internal override returns (address) {
        return address(new BuyBurnPlugin(registry));
    }

    function _manifest(address p) internal view override returns (PluginManifest memory) {
        return BuyBurnDeclaration.manifest(p);
    }

    /// @dev Fuzzed launches use every valid burnBps, and the empty default.
    function _initData(uint256 seed) internal pure override returns (bytes memory) {
        if (seed % 4 == 0) return "";
        return abi.encode(1 + seed % 1_000);
    }

    function _burnOf(IHookPlugin.AfterSwapCtx memory c, MockHookC h) internal returns (uint256) {
        return h.afterSwap(c);
    }

    function test_buyQueuesBurnBoundedByAvailable() public {
        HPool memory p = _newPool(hook, 0, 1);
        _launch(p, 2); // burnBps = 3
        IHookPlugin.AfterSwapCtx memory c = _afterSwapCtx(p, 0, false);
        c.isBuy = true;
        c.quoteNotional = 1 ether;
        c.available = 1 ether;
        assertEq(hook.afterSwap(c), 1 ether * 3 / 10_000, "burnBps x notional");
        c.available = 1e11; // less than the wanted 3e14
        assertEq(hook.afterSwap(c), 1e11, "clamped to available");
        c.available = 0;
        assertEq(hook.afterSwap(c), 0, "nothing without allotment");
        (uint16 bps, uint64 buys, uint176 queued) = BuyBurnPlugin(plugin).pools(address(hook), p.id);
        assertEq(bps, 3);
        assertEq(buys, 2);
        assertEq(queued, 3e14 + 1e11);
    }

    function test_sellsDoNothing() public {
        HPool memory p = _newPool(hook, 0, 2);
        _launch(p, 0);
        IHookPlugin.AfterSwapCtx memory c = _afterSwapCtx(p, 0, false);
        c.isBuy = false;
        c.quoteNotional = 5 ether;
        c.available = 5 ether;
        assertEq(hook.afterSwap(c), 0, "sell");
    }

    function test_defaultBurnBpsWhenInitDataEmpty() public {
        HPool memory p = _newPool(hook, 0, 3);
        _launch(p, 0); // seed % 4 == 0 -> ""
        (uint16 bps,,) = BuyBurnPlugin(plugin).pools(address(hook), p.id);
        assertEq(bps, 100);
    }

    function test_badBurnBpsFailsTheLaunchNotASwap() public {
        HPool memory p = _newPool(hook, 0, 4);
        IHookPlugin.LaunchCtx memory ctx = _launchCtx(p);
        (bool ok,) = hook.rawCall(abi.encodeCall(IHookPlugin.onLaunch, (ctx, abi.encode(uint256(0)))), 1_000_000);
        assertFalse(ok, "0 bps");
        (ok,) = hook.rawCall(abi.encodeCall(IHookPlugin.onLaunch, (ctx, abi.encode(uint256(1_001)))), 1_000_000);
        assertFalse(ok, "above 10%");
    }

    function testFuzz_burnNeverExceedsAvailableNorShare(uint256 notional, uint256 available, uint256 seed) public {
        HPool memory p = _newPool(hook, seed % 3, seed);
        _launch(p, seed);
        (uint16 bps,,) = BuyBurnPlugin(plugin).pools(address(hook), p.id);
        IHookPlugin.AfterSwapCtx memory c = _afterSwapCtx(p, seed, false);
        c.isBuy = true;
        c.quoteNotional = notional;
        c.available = bound(available, 0, type(uint128).max);
        uint256 total = hook.afterSwap(c); // MockHookC already reverts if total > available
        assertLe(total, c.available, "<= available");
        assertLe(total, notional / 10_000 * bps + bps, "<= burnBps x notional");
    }
}
