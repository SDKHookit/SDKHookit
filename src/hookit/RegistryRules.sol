// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PluginPortConstants as PPC} from "./PluginPortConstants.sol";
import {PluginLimitsDecl, CompatDecl} from "./ModuleRegistryTypes.sol";
import {PluginManifest} from "./PluginManifest.sol";

/// @title RegistryRules
/// @notice Offline copy of every check `ModuleRegistry.addModule` runs on a declaration (monorepo
///         src/c/registry/ModuleRegistry.sol: `addModule`, `_checkCaps`, `_pack`, `_checkLimits`), with the same error
///         names, so a manifest that passes here is accepted by the live registry (apart from `incompatibleWith` ids,
///         which must exist on chain, and `metadataHash`, which the owner computes from the review record).
///         Plus `checkReviewRules`: the parts of the §9.3 review checklist that are mechanical.
library RegistryRules {
    uint16 internal constant MAX_HOOK_TAX_BPS = 900;
    uint16 internal constant RESERVED_BUILTINS = 0xF000;
    uint256 internal constant STATICCALL_GAS = 30_000;

    error NoCode();
    error BadPluginApi();
    error UnknownCapBits();
    error CapDependency();
    error BadLimits();
    error SurchargeTooHigh();
    error PotBpsTooHigh();
    error HookApiNotRegistered();
    error ReservedBuiltinBit();
    error ExclusiveNotMember();
    error UnknownModule(uint32 id);
    // review rules (SDK only, not on chain)
    error NoFamilyGroup();
    error CodehashMismatch(bytes32 declared, bytes32 actual);
    error DuplicateIncompatibility(uint32 id);
    error EmptyName();

    /// @notice Every `addModule` check, in the registry's order. `registeredApiMask` = HookRegistry.apiVersionMask()
    ///         (`1 << 1` on Ink today).
    function checkAddModule(PluginManifest memory m, uint64 registeredApiMask) internal view {
        if (m.plugin.code.length == 0) revert NoCode();
        (bool ok, bytes memory ret) =
            m.plugin.staticcall{gas: STATICCALL_GAS}(abi.encodeWithSignature("hookitPluginApi()"));
        if (!ok || ret.length != 32 || abi.decode(ret, (uint256)) != PPC.PLUGIN_API) revert BadPluginApi();
        checkCaps(m.caps);
        uint256 word = pack(m.limits);
        checkLimits(m.caps, m.limits.launchGas, word);
        if (m.maxSurchargeBps > MAX_HOOK_TAX_BPS) revert SurchargeTooHigh();
        if (m.maxSurchargeBps != 0 && m.caps & PPC.CAP_FEE_SURCHARGE == 0) revert SurchargeTooHigh();
        if (m.maxPotBps > 10_000) revert PotBpsTooHigh();
        if (m.hookApiMask == 0 || m.hookApiMask & ~registeredApiMask != 0) revert HookApiNotRegistered();
        if (m.compat.forbiddenBuiltins & RESERVED_BUILTINS != 0) revert ReservedBuiltinBit();
        if (m.compat.exclusiveGroups & ~m.compat.groups != 0) revert ExclusiveNotMember();
        for (uint256 i; i < m.compat.incompatibleWith.length; ++i) {
            if (m.compat.incompatibleWith[i] == 0) revert UnknownModule(0);
        }
    }

    /// @notice Mechanical review rules: a family group (bits 0-3, D50), the pinned codehash is the deployed one,
    ///         no duplicate incompatibility, a display name.
    function checkReviewRules(PluginManifest memory m) internal view {
        if (bytes(m.name).length == 0) revert EmptyName();
        if (m.compat.groups & 0xF == 0) revert NoFamilyGroup();
        if (m.codehash != m.plugin.codehash) revert CodehashMismatch(m.codehash, m.plugin.codehash);
        uint32[] memory l = m.compat.incompatibleWith;
        for (uint256 i; i < l.length; ++i) {
            for (uint256 j; j < i; ++j) {
                if (l[i] == l[j]) revert DuplicateIncompatibility(l[i]);
            }
        }
    }

    /// @dev §4.4 capability table: unknown / reserved bits and dependencies (ModuleRegistry._checkCaps).
    function checkCaps(uint64 caps) internal pure {
        if (caps & ~PPC.KNOWN_CAPS != 0) revert UnknownCapBits();
        if (caps & PPC.INTENT_CAPS != 0 && caps & PPC.AFTER_POINT_CAPS == 0) revert CapDependency();
        if (
            caps & PPC.CAP_GUARD != 0
                && caps & (PPC.CAP_BEFORE_SWAP | PPC.CAP_BEFORE_ADD_LIQUIDITY | PPC.CAP_BEFORE_DONATE) == 0
        ) {
            revert CapDependency();
        }
        if (caps & PPC.CAP_SELL_GUARD_ANTIMEV != 0 && (caps & PPC.CAP_BEFORE_SWAP == 0 || caps & PPC.CAP_GUARD == 0)) {
            revert CapDependency();
        }
        if (caps & (PPC.CAP_FEE_SURCHARGE | PPC.CAP_BEFORE_SWAP_DELTA) != 0 && caps & PPC.CAP_BEFORE_SWAP == 0) {
            revert CapDependency();
        }
        if (caps & PPC.CAP_AFTER_SWAP_DELTA != 0 && caps & PPC.CAP_AFTER_SWAP == 0) revert CapDependency();
        if (caps & PPC.CAP_AFTER_ADD_LIQUIDITY_DELTA != 0 && caps & PPC.CAP_AFTER_ADD_LIQUIDITY == 0) {
            revert CapDependency();
        }
        if (caps & PPC.CAP_AFTER_REMOVE_LIQUIDITY_DELTA != 0 && caps & PPC.CAP_AFTER_REMOVE_LIQUIDITY == 0) {
            revert CapDependency();
        }
    }

    /// @dev ModuleRegistry._pack: gas[p] u20 at bits 20p, maxIntents[k] u4 at bits 200 + 4k.
    function pack(PluginLimitsDecl memory l) internal pure returns (uint256 word) {
        for (uint256 p; p < 10; ++p) {
            uint256 g = l.gas[p];
            if (g >> 20 != 0) revert BadLimits();
            word |= g << (20 * p);
        }
        for (uint256 k; k < 4; ++k) {
            uint256 m = l.maxIntents[k];
            if (m >> 4 != 0) revert BadLimits();
            word |= m << (200 + 4 * k);
        }
    }

    /// @dev ModuleRegistry._checkLimits (D31 / D39).
    function checkLimits(uint64 caps, uint32 launchGas, uint256 word) internal pure {
        if (launchGas < PPC.MIN_PLUGIN_CALL_GAS || launchGas > PPC.MAX_PLUGIN_CALL_GAS) revert BadLimits();
        for (uint256 p; p < 10; ++p) {
            uint256 g = (word >> (20 * p)) & 0xFFFFF;
            bool sub = subscribed(caps, p + 1);
            if (sub ? (g < PPC.MIN_PLUGIN_CALL_GAS || g > PPC.MAX_PLUGIN_CALL_GAS) : g != 0) revert BadLimits();
        }
        bool intents = caps & PPC.INTENT_CAPS != 0;
        for (uint256 k; k < 4; ++k) {
            uint256 m = (word >> (200 + 4 * k)) & 0xF;
            bool sub = subscribed(caps, 4 + 2 * k);
            if (m > PPC.MAX_INTENTS_CEILING || (m != 0 && (!intents || !sub))) revert BadLimits();
        }
        if (word >> 216 != 0) revert BadLimits();
    }

    /// @notice True iff `caps` subscribes hook point `point` (1-10).
    function subscribed(uint64 caps, uint256 point) internal pure returns (bool) {
        return (caps >> ((PPC.POINT_CAP_BITS >> (8 * (point - 1))) & 0xFF)) & 1 != 0;
    }

    /// @notice Declared max intents at after-point `point` (4, 6, 8 or 10), else 0.
    function maxIntentsAt(PluginLimitsDecl memory l, uint256 point) internal pure returns (uint256) {
        if (point == 4) return l.maxIntents[0];
        if (point == 6) return l.maxIntents[1];
        if (point == 8) return l.maxIntents[2];
        if (point == 10) return l.maxIntents[3];
        return 0;
    }
}
