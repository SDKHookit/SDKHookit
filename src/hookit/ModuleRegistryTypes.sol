// SPDX-License-Identifier: MIT
// Vendored from the Hookit monorepo: the structs are verbatim copies of src/c/interfaces/IModuleRegistry.sol, the
// interface is the subset of IModuleRegistry / ModuleRegistry an outside developer needs to read. Upstream:
// (the hookit monorepo)
pragma solidity ^0.8.26;

/// @notice Declared per module at registration (D31, D39), reviewed by the owner, snapshotted per pool at launch
///         (spec/v2/ARCHITECTURE.md §4.7).
struct PluginLimitsDecl {
    uint32 launchGas; // point 0; 10_000 <= launchGas <= MAX_PLUGIN_CALL_GAS
    uint32[10] gas; // points 1..10 (index p-1); 10_000..1_000_000 if the point's cap bit is set, else 0
    uint8[4] maxIntents; // points 4, 6, 8, 10; each <= 8; 0 if unsubscribed or no intent capability (bits 0-5)
}

struct ModuleEntry {
    address plugin;
    bytes32 codehash;
    uint16 pluginApi;
    uint64 caps;
    uint64 hookApiMask;
    PluginLimitsDecl limits;
    uint16 maxPotBps;
    uint16 maxSurchargeBps;
    bytes32 metadataHash;
    uint64 addedAt;
    bool deprecated;
    bool halted;
    uint64 haltedAt;
    uint64 unhaltedAt;
    uint32 successor;
    uint32 replaces;
    bool migrated;
    uint64 successorSetAt;
    bytes32 recoveryReviewHash;
}

/// @notice Compatibility declaration (D3, D22; R28, §4.4).
struct CompatDecl {
    uint32[] incompatibleWith;
    uint16 forbiddenBuiltins;
    uint64 groups;
    uint64 exclusiveGroups;
    uint64 conflictGroups;
}

/// @notice The part of the live ModuleRegistry (Ink 0x91f1622D49a09Ce2904E8f98650393eB3dAA2470) a plugin author reads.
///         `addModule` is admin-only (the Hookit owner): you never call it, you submit its arguments (the manifest).
interface IHookitModuleRegistry {
    function addModule(
        address plugin,
        uint64 caps,
        uint64 hookApiMask,
        PluginLimitsDecl calldata limits,
        uint16 maxPotBps,
        uint16 maxSurchargeBps,
        CompatDecl calldata compat,
        bytes32 metadataHash
    ) external returns (uint32 id);

    function moduleEntry(uint32 id) external view returns (ModuleEntry memory);
    function moduleCount() external view returns (uint32);
    function isHalted(uint32 id) external view returns (bool);
    function hookRegistry() external view returns (address);
    function admin() external view returns (address);
}
