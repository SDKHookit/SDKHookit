// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PluginLimitsDecl, CompatDecl} from "./ModuleRegistryTypes.sol";

/// @notice Everything the Hookit Workshop form needs for one plugin: exactly the arguments of
///         `ModuleRegistry.addModule(plugin, caps, hookApiMask, limits, maxPotBps, maxSurchargeBps, compat,
///         metadataHash)` except `metadataHash` (the owner computes it from the review record), plus display fields
///         and the runtime codehash the owner will pin. Schema: MANIFEST.md.
struct PluginManifest {
    address plugin;
    string name;
    string description;
    string repo;
    uint64 caps;
    uint64 hookApiMask;
    PluginLimitsDecl limits;
    uint16 maxPotBps;
    uint16 maxSurchargeBps;
    CompatDecl compat;
    bytes32 codehash;
}

/// @title ManifestJson
/// @notice Serialises a PluginManifest to the Workshop JSON (MANIFEST.md, schema `hookit.plugin-manifest/v1`).
///         uint64 fields are decimal strings (they can exceed 2^53); every other number is a JSON number. Hex is
///         lowercase with a 0x prefix. Pure Solidity, no cheatcodes, so it can run anywhere.
library ManifestJson {
    string internal constant SCHEMA = "hookit.plugin-manifest/v1";

    error UnsafeString(string field);

    function toJson(PluginManifest memory m, uint256 chainId) internal pure returns (string memory) {
        _safe(m.name, "name");
        _safe(m.description, "description");
        _safe(m.repo, "repo");
        string memory head = string.concat(
            "{\n",
            '  "schema": "',
            SCHEMA,
            '",\n',
            '  "chainId": ',
            u(chainId),
            ",\n",
            '  "pluginApi": 3,\n',
            '  "plugin": "',
            addr(m.plugin),
            '",\n',
            '  "name": "',
            m.name,
            '",\n',
            '  "description": "',
            m.description,
            '",\n'
        );
        string memory caps = string.concat(
            '  "caps": "',
            u(m.caps),
            '",\n',
            '  "capsHex": "',
            hex64(m.caps),
            '",\n',
            '  "capNames": ',
            capNamesJson(m.caps),
            ",\n",
            '  "hookApiMask": "',
            u(m.hookApiMask),
            '",\n'
        );
        string memory limits = string.concat(
            '  "limits": {\n',
            '    "launchGas": ',
            u(m.limits.launchGas),
            ",\n",
            '    "gas": ',
            _gasArray(m.limits.gas),
            ",\n",
            '    "maxIntents": ',
            _intentArray(m.limits.maxIntents),
            "\n  },\n",
            '  "maxPotBps": ',
            u(m.maxPotBps),
            ",\n",
            '  "maxSurchargeBps": ',
            u(m.maxSurchargeBps),
            ",\n"
        );
        string memory compat = string.concat(
            '  "compat": {\n',
            '    "incompatibleWith": ',
            _idArray(m.compat.incompatibleWith),
            ",\n",
            '    "forbiddenBuiltins": ',
            u(m.compat.forbiddenBuiltins),
            ",\n",
            '    "groups": "',
            u(m.compat.groups),
            '",\n',
            '    "exclusiveGroups": "',
            u(m.compat.exclusiveGroups),
            '",\n',
            '    "conflictGroups": "',
            u(m.compat.conflictGroups),
            '"\n  },\n'
        );
        string memory tail =
            string.concat('  "codehash": "', b32(m.codehash), '",\n', '  "repo": "', m.repo, '"\n', "}\n");
        return string.concat(head, caps, limits, compat, tail);
    }

    /// @notice One `cast calldata` line encoding addModule with these values; the owner fills METADATA_HASH.
    function castCalldata(PluginManifest memory m) internal pure returns (string memory) {
        string memory gas = "[";
        for (uint256 p; p < 10; ++p) {
            gas = string.concat(gas, p == 0 ? "" : ",", u(m.limits.gas[p]));
        }
        string memory mi = "[";
        for (uint256 k; k < 4; ++k) {
            mi = string.concat(mi, k == 0 ? "" : ",", u(m.limits.maxIntents[k]));
        }
        string memory inc = "[";
        for (uint256 i; i < m.compat.incompatibleWith.length; ++i) {
            inc = string.concat(inc, i == 0 ? "" : ",", u(m.compat.incompatibleWith[i]));
        }
        return string.concat(
            'cast calldata "addModule(address,uint64,uint64,(uint32,uint32[10],uint8[4]),uint16,uint16,',
            '(uint32[],uint16,uint64,uint64,uint64),bytes32)" ',
            addr(m.plugin),
            " ",
            u(m.caps),
            " ",
            u(m.hookApiMask),
            ' "(',
            u(m.limits.launchGas),
            ",",
            gas,
            "],",
            mi,
            '])" ',
            u(m.maxPotBps),
            " ",
            u(m.maxSurchargeBps),
            ' "(',
            inc,
            "],",
            u(m.compat.forbiddenBuiltins),
            ",",
            u(m.compat.groups),
            ",",
            u(m.compat.exclusiveGroups),
            ",",
            u(m.compat.conflictGroups),
            ')" $METADATA_HASH'
        );
    }

    /// @notice Name of capability bit `bit` (0-63), "" for an unknown / reserved bit.
    function capName(uint256 bit) internal pure returns (string memory) {
        string[32] memory n = [
            "CAP_PAY",
            "CAP_BURN",
            "CAP_DEEPEN",
            "CAP_FUND_FLOOR",
            "CAP_FUND_AIRDROP",
            "CAP_CREDIT_CREATOR",
            "CAP_FLOOR_TOPUP",
            "CAP_FLOOR_ESCROW",
            "CAP_HOLDS_TOKEN",
            "REQ_BACKED_FLOOR",
            "REQ_HOLDER_AIRDROP",
            "REQ_SINGLE_MARKET",
            "",
            "REQ_HOLDER_LIST",
            "CAP_REVENUE_IN",
            "CAP_BEFORE_SWAP",
            "CAP_AFTER_SWAP",
            "CAP_GUARD",
            "CAP_SELL_GUARD_ANTIMEV",
            "CAP_FEE_SURCHARGE",
            "CAP_BEFORE_ADD_LIQUIDITY",
            "CAP_AFTER_ADD_LIQUIDITY",
            "CAP_BEFORE_REMOVE_LIQUIDITY",
            "CAP_AFTER_REMOVE_LIQUIDITY",
            "CAP_BEFORE_INITIALIZE",
            "CAP_AFTER_INITIALIZE",
            "CAP_BEFORE_DONATE",
            "CAP_AFTER_DONATE",
            "CAP_BEFORE_SWAP_DELTA",
            "CAP_AFTER_SWAP_DELTA",
            "CAP_AFTER_ADD_LIQUIDITY_DELTA",
            "CAP_AFTER_REMOVE_LIQUIDITY_DELTA"
        ];
        return bit < 32 ? n[bit] : "";
    }

    function capNamesJson(uint64 caps) internal pure returns (string memory s) {
        s = "[";
        bool first = true;
        for (uint256 b; b < 64; ++b) {
            if ((caps >> b) & 1 == 0) continue;
            string memory nm = capName(b);
            if (bytes(nm).length == 0) nm = string.concat("UNKNOWN_BIT_", u(b));
            s = string.concat(s, first ? '"' : ', "', nm, '"');
            first = false;
        }
        s = string.concat(s, "]");
    }

    // ------------------------------------------------------------------ formatting helpers

    function u(uint256 v) internal pure returns (string memory) {
        if (v == 0) return "0";
        uint256 len = 0;
        for (uint256 t = v; t != 0; t /= 10) {
            ++len;
        }
        bytes memory b = new bytes(len);
        for (; v != 0; v /= 10) {
            b[--len] = bytes1(uint8(48 + v % 10));
        }
        return string(b);
    }

    function _hex(uint256 v, uint256 nibbles) private pure returns (string memory) {
        bytes memory b = new bytes(2 + nibbles);
        b[0] = "0";
        b[1] = "x";
        for (uint256 i; i < nibbles; ++i) {
            uint256 d = (v >> (4 * (nibbles - 1 - i))) & 0xF;
            b[2 + i] = bytes1(uint8(d < 10 ? 48 + d : 87 + d));
        }
        return string(b);
    }

    function addr(address a) internal pure returns (string memory) {
        return _hex(uint160(a), 40);
    }

    function b32(bytes32 x) internal pure returns (string memory) {
        return _hex(uint256(x), 64);
    }

    function hex64(uint64 x) internal pure returns (string memory) {
        return _hex(x, 16);
    }

    function _gasArray(uint32[10] memory g) private pure returns (string memory s) {
        s = "[";
        for (uint256 i; i < 10; ++i) {
            s = string.concat(s, i == 0 ? "" : ", ", u(g[i]));
        }
        s = string.concat(s, "]");
    }

    function _intentArray(uint8[4] memory g) private pure returns (string memory s) {
        s = "[";
        for (uint256 i; i < 4; ++i) {
            s = string.concat(s, i == 0 ? "" : ", ", u(g[i]));
        }
        s = string.concat(s, "]");
    }

    function _idArray(uint32[] memory g) private pure returns (string memory s) {
        s = "[";
        for (uint256 i; i < g.length; ++i) {
            s = string.concat(s, i == 0 ? "" : ", ", u(g[i]));
        }
        s = string.concat(s, "]");
    }

    /// @dev No JSON escaping is done: refuse quotes, backslashes and control characters.
    function _safe(string memory s, string memory field) private pure {
        bytes memory b = bytes(s);
        for (uint256 i; i < b.length; ++i) {
            if (b[i] == '"' || b[i] == "\\" || uint8(b[i]) < 0x20) revert UnsafeString(field);
        }
    }
}
