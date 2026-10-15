// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookPluginBase} from "./hookit/HookPluginBase.sol";
import {PluginPortConstants as PPC} from "./hookit/PluginPortConstants.sol";
import {PluginManifest} from "./hookit/PluginManifest.sol";
import {HookitInk} from "./hookit/HookitInk.sol";

/// @title MyPlugin
/// @notice Starter for your hook C plugin. It compiles and passes the conformance harness as is (it observes buys and
///         does nothing else). Rename it, then work through the TODOs. Read AGENTS.md first: the rules there are what
///         the Hookit owner checks before registering your plugin.
/// @dev TODO(name): rename the contract, the file, the declaration library and test/MyPlugin.t.sol together.
contract MyPlugin is HookPluginBase {
    /// @dev TODO(state): per-pool state, ALWAYS keyed by (hook, poolId) = (msg.sender, ctx.poolId).
    struct PoolState {
        uint64 buys;
    }

    mapping(address hook => mapping(PoolId => PoolState)) public poolState;

    /// @param moduleRegistry_ The live ModuleRegistry (HookitInk.MODULE_REGISTRY on Ink). Nothing else: no owner.
    constructor(address moduleRegistry_) HookPluginBase(address(0), moduleRegistry_) {}

    /// @dev Point 0, once per pool, already authenticated (registered hook, untampered context, one-shot).
    ///      TODO(launch): decode and bound the creator's `initData` here; reverting here fails the LAUNCH (fine),
    ///      reverting in a swap callback freezes TRADING (never acceptable).
    function _onLaunch(LaunchCtx calldata, bytes calldata) internal override returns (address[] memory custody) {
        return custody; // TODO(custody): list (<= 3) accounts that hold users' launch tokens, if any
    }

    /// @notice Point 8 (after every swap). TODO(logic): your mechanic.
    /// @dev Rules: `_auth` first; O(1) (no loop over users); no external call (never the PoolManager or hook C);
    ///      never revert (saturate, clamp, early-return instead); `rebate + Σ intent amounts <= ctx.available`;
    ///      at most the declared number of intents; identity = `ctx.hint != 0 ? ctx.hint : ctx.origin`, never
    ///      `msg.sender` (that is hook C).
    function afterSwapPlugin(AfterSwapCtx calldata ctx) external override returns (uint256, Intent[] memory) {
        _auth(ctx.poolId);
        if (ctx.isBuy) {
            unchecked {
                poolState[msg.sender][ctx.poolId].buys += 1;
            }
        }
        return (0, new Intent[](0));
    }

    // TODO(points): override other callbacks only if you subscribe to them in `caps` below, e.g.
    //   beforeSwapPlugin  (point 7, CAP_BEFORE_SWAP)  -> BeforeSwapResult (guard / surcharge / size cap / rebate)
    //   afterAddLiquidityPlugin / afterRemoveLiquidityPlugin (points 4 / 6) -> (uint256, Intent[])
    //   beforeDonatePlugin / afterDonatePlugin (points 9 / 10)

    /// @dev TODO(custody): if your plugin holds users' launch tokens (staking...), report the quote held for
    ///      `account` here (see HookPluginBase's D11 notes); otherwise keep 0.
    function _custodyAssets(address) internal pure override returns (uint256) {
        return 0;
    }

    function _payCustody(address, address, uint256) internal pure override {}
}

/// @notice The declaration you submit. Keep it in sync with the code; the harness checks it.
library MyPluginDeclaration {
    function manifest(address plugin) internal view returns (PluginManifest memory m) {
        m.plugin = plugin;
        m.name = "My Plugin"; // TODO(name)
        m.description = "TODO: one sentence that says what the plugin does and whether it moves money.";
        m.repo = "https://github.com/<you>/<repo>"; // TODO(repo): public source for the review
        // TODO(caps): one bit per hook point you override, plus each intent kind you emit (CAP_PAY, CAP_BURN, ...)
        m.caps = PPC.CAP_AFTER_SWAP;
        m.hookApiMask = HookitInk.HOOK_API_MASK;
        // TODO(gas): run `forge test --match-contract MyPluginTest -vv`, read the measured table, declare >= 2x.
        m.limits.launchGas = 100_000;
        m.limits.gas[7] = 60_000; // index = point - 1
        // m.limits.maxIntents[2] = 1; // points 4, 6, 8, 10 -> indexes 0, 1, 2, 3
        m.maxPotBps = 0; // TODO(pot): 10_000 if creators may route a pot share to the plugin (needed to move money)
        m.maxSurchargeBps = 0; // keep 0 unless you surcharge (it lowers every coin's max hook tax)
        m.compat.groups = 1 << 0; // TODO(family): F1 swap rules=bit0, F2 fee redirection=bit1, F3 supply/liquidity=bit2
        m.codehash = plugin.codehash;
    }
}
