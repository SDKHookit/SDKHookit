// SPDX-License-Identifier: MIT
// Vendored verbatim from the Hookit monorepo: src/c/interfaces/IHookPlugin.sol (plugin API v3).
// Do not edit: hook C calls your plugin with exactly this ABI. Upstream: the hookit monorepo
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";

/// @title IHookPlugin (plugin API v3)
/// @notice Normative plugin surface of Master hook C (spec/v2/ARCHITECTURE.md §4.2). Every context struct is static
///         (no dynamic field), so its calldata layout is fixed and hook C patches the per-slot words in place.
/// @dev All callbacks are CALLed with the PoolManager unlocked (except `onLaunch`), with exactly the slot's declared
///      gas for the point, and MUST NOT call the PoolManager. Fail-closed at every point except the remove points
///      5-6, which are fail-open (R32): a failing remove callback is rolled back and skipped.
interface IHookPlugin {
    // ───────────── launch ─────────────
    struct LaunchCtx {
        PoolId poolId;
        PoolKey key;
        address token;
        Currency quote;
        address creator;
        bool tokenIsCurrency0;
        int24 tickLower;
        int24 tickUpper;
        uint8 marketIndex;
        uint8 marketCount;
        uint16 slot; // this plugin's slot index in the pool (uint16: no plugin-count limit, D3)
        uint16 slotCount; // number of plugins of the pool
        uint16 potBps; // this plugin's share of the pot, bps of pot (creator's choice)
        uint16 potBpsSum; // sum over all plugins of the pool
        uint64 caps; // capability bits snapshotted for this slot (§4.4)
        uint16 maxSurchargeBps; // this slot's surcharge ceiling
        uint256 limits; // snapshotted declared gas per point and max intents per after-point (§5.1 layout)
        uint256 modules; // v1 BitmaskConfig word (canonical)
        uint256 vestPacked; // v1 McapVest word
    }

    // ───────────── initialize (points 1-2, inside the factory's launch unlock) ─────────────
    struct InitCtx {
        PoolId poolId;
        address token;
        Currency quote;
        uint16 slot;
        uint160 sqrtPriceX96; // initial price
        int24 tick; // 0 at point 1; the initial tick at point 2
    }

    // ───────────── swap (points 7-8) ─────────────
    struct SwapCtx {
        PoolId poolId;
        address token;
        Currency quote;
        uint16 slot;
        address sender; // PoolManager's `sender` argument (router / factory for the dev buy)
        address origin; // tx.origin (untrusted identity)
        address hint; // first 32 bytes of hookData as an address, else 0 (untrusted, L17)
        bool isBuy;
        bool exactInput;
        bool quoteIsUnspecified; // true on exact-input sells and exact-output buys
        int256 amountSpecified;
        uint256 quoteNotional; // pre-fee spot notional (v1 _quoteNotional)
        uint160 sqrtPriceX96; // before the swap
        int24 tick; // before the swap
        uint128 liquidity;
        uint16 hookTaxBps; // effective hook tax for this swap (static or dynamic)
        uint16 snipeBps; // live snipe tax (outside the 10% cap, as v1)
        uint16 feeHeadroomBps; // MAX_TOTAL_FEE_BPS - BASE - hookTax - surcharges of lower slots
        uint256 rebateHeadroom; // applyBps(quoteNotional, 100 + hookTax) - before-swap rebates of lower slots
        uint256 available; // this slot's allotment before this swap's credits
    }

    /// @notice Exactly 160 bytes of returndata.
    struct BeforeSwapResult {
        uint8 guard; // 0 = allow, 1 = BLOCK; buys need CAP_GUARD, sells need CAP_SELL_GUARD_ANTIMEV (D38)
        uint16 reason; // plugin-defined code surfaced in PluginBlocked
        uint16 surchargeBps; // extra fee for this swap, into the pot (D35); CAP_FEE_SURCHARGE; <= maxSurchargeBps
        uint256 maxQuoteNotional; // 0 = no cap; else PluginSizeCap(slot) if quoteNotional > cap
        uint256 rebate; // quote wei returned to the swapper (D34); CAP_BEFORE_SWAP_DELTA; <= headroom and available
    }

    struct AfterSwapCtx {
        PoolId poolId;
        address token;
        Currency quote;
        uint16 slot;
        address sender;
        address origin;
        address hint;
        bool isBuy;
        bool exactInput;
        bool quoteIsUnspecified; // an after-swap rebate is allowed only when true
        bool floorFill; // the sell was served by the backed-floor path
        BalanceDelta delta; // swapper's BalanceDelta as passed to afterSwap
        uint256 quoteNotional;
        uint256 feeTotal; // hook fee taken this swap (base + tax + snipe + all surcharges), before rebates
        uint256 rebatesBefore; // Σ before-swap rebates granted this swap (all slots)
        uint256 potCredited; // plugin share of this swap's pot credited to the pool's accumulator, informational
        uint160 sqrtPriceX96After;
        int24 tickAfter; // after the swap and after hook C's own v1 queue spends
        uint256 available; // this slot's allotment after this swap's credits and its own before-swap rebate
    }

    // ───────────── liquidity (points 3-6) ─────────────
    struct LiquidityCtx {
        PoolId poolId;
        address token;
        Currency quote;
        uint16 slot;
        address sender; // PoolManager's `sender` (e.g. PositionManager)
        bool tokenIsCurrency0;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta; // > 0 add, <= 0 remove
        bytes32 salt;
        int24 tickCurrent;
        uint256 available;
    }

    struct AfterLiquidityCtx {
        PoolId poolId;
        address token;
        Currency quote;
        uint16 slot;
        address sender;
        bool tokenIsCurrency0;
        int24 tickLower;
        int24 tickUpper;
        int256 liquidityDelta;
        bytes32 salt;
        BalanceDelta delta; // caller's principal + fees delta
        BalanceDelta feesAccrued; // always 0 on C pools (LP fee is 0)
        uint256 available;
    }

    // ───────────── donate (points 9-10) ─────────────
    struct DonateCtx {
        PoolId poolId;
        address token;
        Currency quote;
        uint16 slot;
        address sender;
        uint256 amount0;
        uint256 amount1;
        int24 tickCurrent;
        uint256 available;
    }

    // ───────────── intents ─────────────
    /// kind: 1 PAY(to, amount), 2 BURN(amount), 3 DEEPEN(amount), 4 FUND_FLOOR(amount), 5 FUND_AIRDROP(amount),
    ///       6 CREDIT_CREATOR(amount). `to` MUST be 0 for kinds 2-6. 96 bytes per entry in ABI encoding.
    struct Intent {
        uint8 kind;
        address to;
        uint256 amount;
    }

    /// @notice Plugin API version. MUST return 3.
    /// @return The plugin API version (3).
    function hookitPluginApi() external pure returns (uint16);

    /// @notice Point 0. Called once per pool at launch by a registered hook (PoolManager locked).
    /// @return custody Accounts (<= 3) that hold users' launch tokens for this plugin in THIS token only (D11).
    /// @param ctx The launch context of the pool and of this plugin's slot.
    /// @param initData The creator's per-slot init data.
    function onLaunch(LaunchCtx calldata ctx, bytes calldata initData) external returns (address[] memory custody);

    /// @notice Points 1-2. Exactly 0 bytes of returndata.
    ///         Called by hook C only (point 1, before the pool's initialisation).
    /// @param ctx The initialize context (tick 0).
    function beforeInitializePlugin(InitCtx calldata ctx) external;
    /// @notice Point 2. Called by hook C only, after the pool's initialisation; exactly 0 bytes of returndata.
    /// @param ctx The initialize context with the initial tick.
    function afterInitializePlugin(InitCtx calldata ctx) external;

    /// @notice Point 3. Exactly 64 bytes. guard = 1 blocks the add (needs CAP_GUARD).
    /// @param ctx The liquidity context of the add.
    /// @return guard 0 = allow, 1 = block.
    /// @return reason Plugin-defined code surfaced when the add is blocked.
    function beforeAddLiquidityPlugin(LiquidityCtx calldata ctx) external returns (uint8 guard, uint16 reason);

    /// @notice Point 4. 96 + 96*n bytes, n <= declared maxIntents[4] <= 8.
    /// @param ctx The after-liquidity context of the add.
    /// @return lpRebate Quote the LP pays less, funded from the slot's allotment (<= the quote the add pays).
    /// @return intents Intents settled by hook C from the slot's allotment.
    function afterAddLiquidityPlugin(AfterLiquidityCtx calldata ctx)
        external
        returns (uint256 lpRebate, Intent[] memory intents);

    /// @notice Point 5. Exactly 64 bytes. guard MUST be 0. FAIL-OPEN (R32).
    /// @param ctx The liquidity context of the removal.
    /// @return guard Must be 0 (a non-zero guard is malformed and the slot is skipped).
    /// @return reason Ignored.
    function beforeRemoveLiquidityPlugin(LiquidityCtx calldata ctx) external returns (uint8 guard, uint16 reason);

    /// @notice Point 6. 96 + 96*n bytes; intent kinds 1-3 only (D45). FAIL-OPEN (R32).
    /// @param ctx The after-liquidity context of the removal.
    /// @return lpReward Extra quote paid to the LP at removal from the slot's allotment (best effort).
    /// @return intents PAY / BURN / DEEPEN intents settled by hook C.
    function afterRemoveLiquidityPlugin(AfterLiquidityCtx calldata ctx)
        external
        returns (uint256 lpReward, Intent[] memory intents);

    /// @notice Point 7. Exactly 160 bytes. MUST NOT call the PoolManager.
    /// @param ctx The swap context.
    /// @return result Guard, reason, surcharge, size cap and rebate for this swap.
    function beforeSwapPlugin(SwapCtx calldata ctx) external returns (BeforeSwapResult memory result);

    /// @notice Point 8. 96 + 96*n bytes, n <= declared maxIntents[8] <= 8.
    /// @param ctx The after-swap context.
    /// @return rebate Quote returned to the swapper (only when the quote is the unspecified currency).
    /// @return intents Intents settled by hook C from the slot's allotment.
    function afterSwapPlugin(AfterSwapCtx calldata ctx) external returns (uint256 rebate, Intent[] memory intents);

    /// @notice Point 9. Exactly 64 bytes. guard = 1 blocks the donation (needs CAP_GUARD).
    /// @param ctx The donate context.
    /// @return guard 0 = allow, 1 = block.
    /// @return reason Plugin-defined code surfaced when the donation is blocked.
    function beforeDonatePlugin(DonateCtx calldata ctx) external returns (uint8 guard, uint16 reason);

    /// @notice Point 10. 96 + 96*n bytes; the first word MUST be 0.
    /// @param ctx The donate context.
    /// @return zero Must be 0.
    /// @return intents Intents settled by hook C from the slot's allotment.
    function afterDonatePlugin(DonateCtx calldata ctx) external returns (uint256 zero, Intent[] memory intents);
}

/// @notice Successor extension (D32, R26; spec §4.2).
interface IHookPluginSuccessor is IHookPlugin {
    /// @notice The plugin this version succeeds (0 for an original version); STATICCALLed by
    ///         `ModuleRegistry.setSuccessor`.
    /// @return The predecessor plugin.
    function predecessor() external view returns (address);
    /// @notice One-time state migration, callable only through `ModuleRegistry.migrateSuccessor` (admin). A successor
    ///         MUST be safe to run before it is migrated.
    /// @param data Opaque migration payload.
    function migrate(bytes calldata data) external;
}
