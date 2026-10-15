// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {HookPluginBase} from "../hookit/HookPluginBase.sol";
import {PluginPortConstants as PPC} from "../hookit/PluginPortConstants.sol";
import {PluginManifest} from "../hookit/PluginManifest.sol";
import {HookitInk} from "../hookit/HookitInk.sol";

/// @title BuyBurnPlugin
/// @notice Example 2 of the Hookit Plugin SDK, a plugin that moves money, safely. The creator routes a share of the
///         hook-tax pot to it (`potBps`); hook C credits that share to the plugin's slot as its allotment
///         (`ctx.available`). On every buy, the plugin asks hook C to queue a buy-and-burn of
///         `min(burnBps x quoteNotional, ctx.available)` from that allotment (one BURN intent). Hook C spends its
///         plugin BURN queue later, under its own per-swap caps. Sells do nothing.
/// @dev Why it is safe (§9.3): it never asks for more than `ctx.available` (hook C would revert the swap otherwise);
///      exactly one intent, as declared (`maxIntents[point 8] = 1`); BURN carries `to = 0`; it holds no money and no
///      custody, so a halt leaves nothing stranded; no loop, no external call; math is `FullMath.mulDiv` so no
///      overflow for any `quoteNotional`; `burnBps` is fixed at launch, bounded, and no one can change it.
///      Launch data: `abi.encode(uint256 burnBps)` with 1 <= burnBps <= 1_000 (0.01 % - 10 % of each buy),
///      empty = 100 (1 %). Out-of-range data fails the launch, never a swap.
contract BuyBurnPlugin is HookPluginBase {
    uint256 public constant DEFAULT_BURN_BPS = 100;
    uint256 public constant MAX_BURN_BPS = 1_000;
    uint8 internal constant KIND_BURN = 2;

    struct Pool {
        uint16 burnBps; // fixed at launch
        uint64 buys; // buys that queued a burn
        uint176 burnQueued; // total quote queued for buy-and-burn (saturating)
    }

    mapping(address hook => mapping(PoolId => Pool)) public pools;

    event BuyBurnQueued(address indexed hook, PoolId indexed poolId, uint256 amount, uint256 available);

    error BadBurnBps(uint256 burnBps);

    constructor(address moduleRegistry_) HookPluginBase(address(0), moduleRegistry_) {}

    /// @notice Bounds of the launch parameter, for UIs and tests.
    function checkBurnBps(uint256 burnBps) public pure {
        if (burnBps == 0 || burnBps > MAX_BURN_BPS) revert BadBurnBps(burnBps);
    }

    /// @dev Point 0 (already authenticated and one-shot in HookPluginBase.onLaunch).
    function _onLaunch(LaunchCtx calldata ctx, bytes calldata initData)
        internal
        override
        returns (address[] memory custody)
    {
        uint256 bps = initData.length == 0 ? DEFAULT_BURN_BPS : abi.decode(initData, (uint256));
        checkBurnBps(bps);
        pools[msg.sender][ctx.poolId].burnBps = uint16(bps);
        return custody; // no custody account
    }

    /// @notice Point 8: on a buy, one BURN intent of `min(burnBps x notional, available)`; otherwise nothing.
    function afterSwapPlugin(AfterSwapCtx calldata ctx)
        external
        override
        returns (uint256 rebate, Intent[] memory intents)
    {
        _auth(ctx.poolId);
        if (!ctx.isBuy || ctx.available == 0) return (0, new Intent[](0));
        Pool storage p = pools[msg.sender][ctx.poolId];
        uint256 amount = FullMath.mulDiv(ctx.quoteNotional, p.burnBps, 10_000);
        if (amount > ctx.available) amount = ctx.available;
        if (amount == 0) return (0, new Intent[](0));
        unchecked {
            p.buys += 1; // 2^64 buys: unreachable
            uint256 q = uint256(p.burnQueued) + amount; // amount <= available < 2^128: cannot wrap
            p.burnQueued = q > type(uint176).max ? type(uint176).max : uint176(q);
        }
        intents = new Intent[](1);
        intents[0] = Intent({kind: KIND_BURN, to: address(0), amount: amount});
        emit BuyBurnQueued(msg.sender, ctx.poolId, amount, ctx.available);
        return (rebate, intents);
    }

    function _custodyAssets(address) internal pure override returns (uint256) {
        return 0;
    }

    function _payCustody(address, address, uint256) internal pure override {}
}

/// @notice The registration declaration of BuyBurnPlugin.
library BuyBurnDeclaration {
    function manifest(address plugin) internal view returns (PluginManifest memory m) {
        m.plugin = plugin;
        m.name = "Buy Burn";
        m.description =
        "On every buy, queues a buy-and-burn of a fixed share of the buy, paid from the plugin pot share.";
        m.repo = "https://github.com/SDKHookit/SDKHookit";
        m.caps = PPC.CAP_AFTER_SWAP | PPC.CAP_BURN;
        m.hookApiMask = HookitInk.HOOK_API_MASK;
        m.limits.launchGas = 150_000; // onLaunch: registry reads + 2 fresh SSTOREs + abi.decode; ~57k measured cold
        m.limits.gas[7] = 40_000; // point 8: measured cold worst case ~9.3k (test_conformance_gasReport), 4x margin
        m.limits.maxIntents[2] = 1; // point 8: exactly one BURN at most
        m.maxPotBps = 10_000; // the creator may route any share of the pot to it
        m.maxSurchargeBps = 0; // never surcharges
        m.compat.groups = (1 << 1) | (1 << 2); // F2 (pot share) + F3 (supply action: BURN)
        m.compat.forbiddenBuiltins = 1 << 11; // NFT_STRATEGY pools have no pot to share
        m.codehash = plugin.codehash;
    }
}
