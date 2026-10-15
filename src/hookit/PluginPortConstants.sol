// SPDX-License-Identifier: MIT
// Vendored verbatim from the Hookit monorepo: src/c/libraries/PluginPortConstants.sol.
// The registry and hook C both alias these values. Upstream: the hookit monorepo
pragma solidity ^0.8.26;

/// @title PluginPortConstants
/// @notice The single source of truth of the plugin-port constants shared by ModuleRegistry (registration checks) and
///         Master hook C (runtime checks), spec §4.4-§4.7 (audit guidelines-10). Both alias these values, so they can
///         never drift apart; compile-time constants only (no bytecode of its own).
library PluginPortConstants {
    uint16 internal constant PLUGIN_API = 3;
    uint256 internal constant MAX_PLUGIN_CALL_GAS = 1_000_000; // D31
    uint256 internal constant MIN_PLUGIN_CALL_GAS = 10_000; // D31
    uint256 internal constant MAX_INTENTS_CEILING = 8; // D39

    // Capability bits (§4.4, uint64 caps). Intent kind k (1-6) is gated by capability bit k-1
    // (test/c/PortConstantsC.t.sol asserts the coupling PluginCallLib relies on).
    uint64 internal constant CAP_PAY = 1 << 0;
    uint64 internal constant CAP_BURN = 1 << 1;
    uint64 internal constant CAP_DEEPEN = 1 << 2;
    uint64 internal constant CAP_FUND_FLOOR = 1 << 3;
    uint64 internal constant CAP_FUND_AIRDROP = 1 << 4;
    uint64 internal constant CAP_CREDIT_CREATOR = 1 << 5;
    uint64 internal constant CAP_FLOOR_TOPUP = 1 << 6;
    uint64 internal constant CAP_FLOOR_ESCROW = 1 << 7;
    uint64 internal constant CAP_HOLDS_TOKEN = 1 << 8;
    uint64 internal constant REQ_BACKED_FLOOR = 1 << 9;
    uint64 internal constant REQ_HOLDER_AIRDROP = 1 << 10;
    uint64 internal constant REQ_SINGLE_MARKET = 1 << 11;
    uint64 internal constant REQ_HOLDER_LIST = 1 << 13;
    uint64 internal constant CAP_REVENUE_IN = 1 << 14;
    uint64 internal constant CAP_BEFORE_SWAP = 1 << 15;
    uint64 internal constant CAP_AFTER_SWAP = 1 << 16;
    uint64 internal constant CAP_GUARD = 1 << 17;
    uint64 internal constant CAP_SELL_GUARD_ANTIMEV = 1 << 18;
    uint64 internal constant CAP_FEE_SURCHARGE = 1 << 19;
    uint64 internal constant CAP_BEFORE_ADD_LIQUIDITY = 1 << 20;
    uint64 internal constant CAP_AFTER_ADD_LIQUIDITY = 1 << 21;
    uint64 internal constant CAP_BEFORE_REMOVE_LIQUIDITY = 1 << 22;
    uint64 internal constant CAP_AFTER_REMOVE_LIQUIDITY = 1 << 23;
    uint64 internal constant CAP_BEFORE_INITIALIZE = 1 << 24;
    uint64 internal constant CAP_AFTER_INITIALIZE = 1 << 25;
    uint64 internal constant CAP_BEFORE_DONATE = 1 << 26;
    uint64 internal constant CAP_AFTER_DONATE = 1 << 27;
    uint64 internal constant CAP_BEFORE_SWAP_DELTA = 1 << 28;
    uint64 internal constant CAP_AFTER_SWAP_DELTA = 1 << 29;
    uint64 internal constant CAP_AFTER_ADD_LIQUIDITY_DELTA = 1 << 30;
    uint64 internal constant CAP_AFTER_REMOVE_LIQUIDITY_DELTA = 1 << 31;
    /// @dev Bits 0-31 except the reserved bit 12 (rejected, D13 / D29 moot); 32-63 unknown.
    uint64 internal constant KNOWN_CAPS = 0xFFFFEFFF;
    uint64 internal constant INTENT_CAPS = 0x3F; // bits 0-5
    uint64 internal constant AFTER_POINT_CAPS =
        CAP_AFTER_SWAP | CAP_AFTER_ADD_LIQUIDITY | CAP_AFTER_REMOVE_LIQUIDITY | CAP_AFTER_DONATE;
    /// @dev Capability bit of hook point p (1-10), one byte per point, point p at byte p-1:
    ///      1→24, 2→25, 3→20, 4→21, 5→22, 6→23, 7→15, 8→16, 9→26, 10→27.
    uint256 internal constant POINT_CAP_BITS = 0x1b1a100f171615141918;
}
