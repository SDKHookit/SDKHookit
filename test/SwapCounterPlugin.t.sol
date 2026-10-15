// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PluginHarness} from "./harness/PluginHarness.sol";
import {IHookPlugin} from "../src/hookit/IHookPlugin.sol";
import {PluginManifest} from "../src/hookit/PluginManifest.sol";
import {SwapCounterPlugin, SwapCounterDeclaration} from "../src/examples/SwapCounterPlugin.sol";

/// @notice Conformance harness (inherited tests) + unit tests for example 1.
contract SwapCounterPluginTest is PluginHarness {
    function _deployPlugin(address registry) internal override returns (address) {
        return address(new SwapCounterPlugin(registry));
    }

    function _manifest(address p) internal view override returns (PluginManifest memory) {
        return SwapCounterDeclaration.manifest(p);
    }

    function test_countsEverySwapAndTheFee() public {
        HPool memory p = _newPool(hook, 0, 1);
        _launch(p, 1);
        uint256 fees;
        for (uint256 i; i < 5; ++i) {
            IHookPlugin.AfterSwapCtx memory c = _afterSwapCtx(p, uint256(keccak256(abi.encode(i))), false);
            fees += c.feeTotal;
            hook.afterSwap(c);
        }
        (uint64 swaps, uint192 feeTotal) = SwapCounterPlugin(plugin).stats(address(hook), p.id);
        assertEq(swaps, 5, "swaps");
        assertEq(feeTotal, fees, "fees");
    }

    function test_feeTotalSaturatesInsteadOfReverting() public {
        HPool memory p = _newPool(hook, 0, 2);
        _launch(p, 2);
        IHookPlugin.AfterSwapCtx memory c = _afterSwapCtx(p, 3, false);
        c.feeTotal = type(uint256).max;
        hook.afterSwap(c);
        hook.afterSwap(c);
        (, uint192 feeTotal) = SwapCounterPlugin(plugin).stats(address(hook), p.id);
        assertEq(feeTotal, type(uint192).max, "saturated");
    }

    function test_statsAreKeyedByHook() public {
        HPool memory a = _newPool(hook, 0, 3);
        HPool memory b = _newPool(otherHook, 0, 3);
        _launch(a, 3);
        _launch(b, 3);
        hook.afterSwap(_afterSwapCtx(a, 7, false));
        (uint64 sa,) = SwapCounterPlugin(plugin).stats(address(hook), a.id);
        (uint64 sb,) = SwapCounterPlugin(plugin).stats(address(otherHook), b.id);
        assertEq(sa, 1);
        assertEq(sb, 0);
    }
}
