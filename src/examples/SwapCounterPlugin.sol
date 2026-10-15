// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookPluginBase} from "../hookit/HookPluginBase.sol";
import {PluginPortConstants as PPC} from "../hookit/PluginPortConstants.sol";
import {PluginManifest} from "../hookit/PluginManifest.sol";
import {HookitInk} from "../hookit/HookitInk.sol";

/// @title SwapCounterPlugin
/// @notice Example 1 of the Hookit Plugin SDK: the smallest useful hook C plugin (same logic as the monorepo's
///         test/c/plugins/SwapCounterModule.sol). It subscribes to the after-swap point (8) only and records, per
///         (hook, pool), how many swaps ran and the fee hook C took. It moves no money: no intent, no rebate, no pot
///         share, so it can never change what a trader pays or receives.
/// @dev Review rules it follows (§9.3): state keyed by (hook, poolId); `_auth` first in every callback; O(1), no
///      loop, no external call; cannot revert on valid input (uint64 counter cannot realistically wrap, the fee sum
///      saturates instead of overflowing); exact return shape `(0, new Intent[](0))`; no owner, no upgrade.
contract SwapCounterPlugin is HookPluginBase {
    struct Stats {
        uint64 swaps;
        uint192 feeTotal;
    }

    mapping(address hook => mapping(PoolId => Stats)) public stats;

    constructor(address moduleRegistry_) HookPluginBase(address(0), moduleRegistry_) {}

    /// @notice Point 8: count the swap and add hook C's fee to the pool's total. Returns no rebate and no intent.
    function afterSwapPlugin(AfterSwapCtx calldata ctx) external override returns (uint256, Intent[] memory) {
        _auth(ctx.poolId);
        Stats storage s = stats[msg.sender][ctx.poolId];
        unchecked {
            s.swaps += 1; // 2^64 swaps: unreachable
            uint256 f = uint256(s.feeTotal) + (ctx.feeTotal > type(uint192).max ? type(uint192).max : ctx.feeTotal);
            s.feeTotal = f > type(uint192).max ? type(uint192).max : uint192(f); // saturate, never revert
        }
        return (0, new Intent[](0));
    }

    /// @dev This plugin holds no custody account.
    function _custodyAssets(address) internal pure override returns (uint256) {
        return 0;
    }

    function _payCustody(address, address, uint256) internal pure override {}
}

/// @notice The registration declaration of SwapCounterPlugin: the single source for tests, the manifest script and
///         the Workshop submission.
library SwapCounterDeclaration {
    function manifest(address plugin) internal view returns (PluginManifest memory m) {
        m.plugin = plugin;
        m.name = "Swap Counter";
        m.description = "Counts swaps and the hook fee per pool. Moves no money.";
        m.repo = "https://github.com/SDKHookit/SDKHookit";
        m.caps = PPC.CAP_AFTER_SWAP;
        m.hookApiMask = HookitInk.HOOK_API_MASK;
        m.limits.launchGas = 100_000; // HookPluginBase.onLaunch: 2 registry reads + 1 fresh SSTORE; >= 2x measured
        m.limits.gas[7] = 60_000; // point 8 (afterSwap): >= 2x the measured cold worst case
        // maxIntents all 0: the plugin never returns an intent
        m.maxPotBps = 0; // takes no share of the pot: creators launch it with potBps = 0
        m.maxSurchargeBps = 0;
        m.compat.groups = 1 << 0; // family F1 (swap-point plugin); no incompatibility, no forbidden built-in
        m.codehash = plugin.codehash;
    }
}
