// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHookPlugin} from "../../src/hookit/IHookPlugin.sol";
import {PluginPortConstants as PPC} from "../../src/hookit/PluginPortConstants.sol";
import {PluginLimitsDecl} from "../../src/hookit/ModuleRegistryTypes.sol";
import {RegistryRules} from "../../src/hookit/RegistryRules.sol";

/// @notice Stand-in for the live HookRegistry: which hooks are registered, and the API-version mask.
contract MockHookRegistry {
    mapping(address => bool) public isRegisteredHook;
    uint64 public apiVersionMask = 1 << 1; // hook C reports apiVersion() == 1

    function setRegistered(address hook, bool on) external {
        isRegisteredHook[hook] = on;
    }
}

/// @notice Stand-in for the live ModuleRegistry, as far as HookPluginBase reads it (`hookRegistry()`).
contract MockModuleRegistry {
    address public immutable hookRegistry;

    constructor(address hookRegistry_) {
        hookRegistry = hookRegistry_;
    }
}

/// @title MockHookC
/// @notice Plays Master hook C towards one plugin: it CALLs each callback with EXACTLY the declared gas of the point
///         (like hook C), measures the gas used, and checks every return the way hook C does (exact returndata size,
///         field ranges, capability bits, intent count / kinds / `to`, `rebate + Σ intents <= available`). Any
///         breach reverts with `ConformanceViolation(point, why)`; a plugin revert or an out-of-gas at the declared
///         gas reverts with `PluginReverted(point, gasLimit, reason)`. On the real hook C both freeze trading.
/// @dev Point numbering (spec §4.2): 0 onLaunch, 1-2 initialize, 3-4 add liquidity, 5-6 remove, 7-8 swap,
///      9-10 donate.
contract MockHookC {
    error PluginReverted(uint8 point, uint256 gasLimit, bytes reason);
    error ConformanceViolation(uint8 point, string why);

    address public plugin;
    uint64 public caps;
    uint16 public maxSurchargeBps;
    PluginLimitsDecl internal _limits;

    /// @notice Highest gas measured per point (index 0 = onLaunch), call overhead included (conservative).
    uint256[11] public maxGasUsed;

    function configure(address plugin_, uint64 caps_, PluginLimitsDecl calldata limits_, uint16 maxSurchargeBps_)
        external
    {
        plugin = plugin_;
        caps = caps_;
        _limits = limits_;
        maxSurchargeBps = maxSurchargeBps_;
    }

    function limits() external view returns (PluginLimitsDecl memory) {
        return _limits;
    }

    /// @notice Declared gas of `point` (0 = launchGas).
    function declaredGas(uint8 point) public view returns (uint256) {
        return point == 0 ? _limits.launchGas : _limits.gas[point - 1];
    }

    // ================================================================== raw call (no checks), for auth tests

    function rawCall(bytes calldata data, uint256 gasLimit) external returns (bool ok, bytes memory ret) {
        (ok, ret) = plugin.call{gas: gasLimit}(data);
    }

    // ================================================================== point 0

    function launch(IHookPlugin.LaunchCtx calldata ctx, bytes calldata initData)
        external
        returns (address[] memory custody)
    {
        bytes memory ret = _call(0, abi.encodeCall(IHookPlugin.onLaunch, (ctx, initData)));
        // ABI of address[]: offset (0x20), length n, n words
        if (ret.length < 64 || _word(ret, 0) != 0x20) _bad(0, "onLaunch: malformed address[] return");
        uint256 n = _word(ret, 1);
        if (n > 3) _bad(0, "onLaunch: more than 3 custody accounts (D11)");
        if (ret.length != 64 + 32 * n) _bad(0, "onLaunch: returndata size");
        custody = new address[](n);
        for (uint256 i; i < n; ++i) {
            uint256 w = _word(ret, 2 + i);
            if (w >> 160 != 0 || w == 0) _bad(0, "onLaunch: bad custody address");
            custody[i] = address(uint160(w));
        }
    }

    // ================================================================== points 1-2

    function beforeInitialize(IHookPlugin.InitCtx calldata ctx) external {
        bytes memory ret = _call(1, abi.encodeCall(IHookPlugin.beforeInitializePlugin, (ctx)));
        if (ret.length != 0) _bad(1, "beforeInitialize: must return 0 bytes");
    }

    function afterInitialize(IHookPlugin.InitCtx calldata ctx) external {
        bytes memory ret = _call(2, abi.encodeCall(IHookPlugin.afterInitializePlugin, (ctx)));
        if (ret.length != 0) _bad(2, "afterInitialize: must return 0 bytes");
    }

    // ================================================================== points 3-6

    function beforeAddLiquidity(IHookPlugin.LiquidityCtx calldata ctx) external returns (uint8 guard) {
        guard = _guardPair(3, _call(3, abi.encodeCall(IHookPlugin.beforeAddLiquidityPlugin, (ctx))));
    }

    function afterAddLiquidity(IHookPlugin.AfterLiquidityCtx calldata ctx) external returns (uint256 total) {
        bytes memory ret = _call(4, abi.encodeCall(IHookPlugin.afterAddLiquidityPlugin, (ctx)));
        total = _afterPoint(4, ret, PPC.CAP_AFTER_ADD_LIQUIDITY_DELTA, true, ctx.available);
    }

    function beforeRemoveLiquidity(IHookPlugin.LiquidityCtx calldata ctx) external {
        uint8 g = _guardPair(5, _call(5, abi.encodeCall(IHookPlugin.beforeRemoveLiquidityPlugin, (ctx))));
        if (g != 0) _bad(5, "beforeRemoveLiquidity: guard must be 0 (removals are never blocked)");
    }

    function afterRemoveLiquidity(IHookPlugin.AfterLiquidityCtx calldata ctx) external returns (uint256 total) {
        bytes memory ret = _call(6, abi.encodeCall(IHookPlugin.afterRemoveLiquidityPlugin, (ctx)));
        total = _afterPoint(6, ret, PPC.CAP_AFTER_REMOVE_LIQUIDITY_DELTA, true, ctx.available);
    }

    // ================================================================== points 7-8

    function beforeSwap(IHookPlugin.SwapCtx calldata ctx) external returns (IHookPlugin.BeforeSwapResult memory r) {
        bytes memory ret = _call(7, abi.encodeCall(IHookPlugin.beforeSwapPlugin, (ctx)));
        if (ret.length != 160) _bad(7, "beforeSwap: returndata must be exactly 160 bytes");
        uint256 guard = _word(ret, 0);
        uint256 reason = _word(ret, 1);
        uint256 sur = _word(ret, 2);
        uint256 cap = _word(ret, 3);
        uint256 reb = _word(ret, 4);
        if (guard > 1 || reason > 0xFFFF || sur > 0xFFFF) _bad(7, "beforeSwap: field out of range");
        if ((guard | cap) != 0) {
            if (ctx.isBuy && caps & PPC.CAP_GUARD == 0) _bad(7, "beforeSwap: buy guard / size cap needs CAP_GUARD");
            if (!ctx.isBuy && caps & PPC.CAP_SELL_GUARD_ANTIMEV == 0) {
                _bad(7, "beforeSwap: sell guard / size cap needs CAP_SELL_GUARD_ANTIMEV");
            }
        }
        if (sur != 0) {
            if (caps & PPC.CAP_FEE_SURCHARGE == 0) _bad(7, "beforeSwap: surcharge needs CAP_FEE_SURCHARGE");
            if (sur > maxSurchargeBps) _bad(7, "beforeSwap: surcharge above maxSurchargeBps");
        }
        if (reb != 0) {
            if (caps & PPC.CAP_BEFORE_SWAP_DELTA == 0) _bad(7, "beforeSwap: rebate needs CAP_BEFORE_SWAP_DELTA");
            if (reb > ctx.rebateHeadroom) _bad(7, "beforeSwap: rebate above rebateHeadroom");
            if (reb > ctx.available) _bad(7, "beforeSwap: rebate above available");
        }
        r = IHookPlugin.BeforeSwapResult({
            guard: uint8(guard), reason: uint16(reason), surchargeBps: uint16(sur), maxQuoteNotional: cap, rebate: reb
        });
    }

    function afterSwap(IHookPlugin.AfterSwapCtx calldata ctx) external returns (uint256 total) {
        bytes memory ret = _call(8, abi.encodeCall(IHookPlugin.afterSwapPlugin, (ctx)));
        if (ret.length >= 32 && _word(ret, 0) != 0 && !ctx.quoteIsUnspecified) {
            _bad(8, "afterSwap: rebate only when the quote is the unspecified currency");
        }
        total = _afterPoint(8, ret, PPC.CAP_AFTER_SWAP_DELTA, true, ctx.available);
    }

    // ================================================================== points 9-10

    function beforeDonate(IHookPlugin.DonateCtx calldata ctx) external returns (uint8 guard) {
        guard = _guardPair(9, _call(9, abi.encodeCall(IHookPlugin.beforeDonatePlugin, (ctx))));
    }

    function afterDonate(IHookPlugin.DonateCtx calldata ctx) external returns (uint256 total) {
        bytes memory ret = _call(10, abi.encodeCall(IHookPlugin.afterDonatePlugin, (ctx)));
        total = _afterPoint(10, ret, 0, false, ctx.available);
    }

    // ================================================================== internals

    function _call(uint8 point, bytes memory data) internal returns (bytes memory ret) {
        if (point != 0 && !RegistryRules.subscribed(caps, point)) {
            _bad(point, "hook C never calls an unsubscribed point");
        }
        uint256 g = declaredGas(point);
        bool ok;
        uint256 g0 = gasleft();
        (ok, ret) = plugin.call{gas: g}(data);
        uint256 used = g0 - gasleft();
        if (!ok) revert PluginReverted(point, g, ret);
        if (used > maxGasUsed[point]) maxGasUsed[point] = used;
    }

    function _guardPair(uint8 point, bytes memory ret) internal view returns (uint8) {
        if (ret.length != 64) _bad(point, "returndata must be exactly 64 bytes (guard, reason)");
        uint256 guard = _word(ret, 0);
        if (guard > 1 || _word(ret, 1) > 0xFFFF) _bad(point, "guard / reason out of range");
        if (guard == 1 && caps & PPC.CAP_GUARD == 0) _bad(point, "guard = 1 needs CAP_GUARD");
        return uint8(guard);
    }

    /// @dev `(uint256 value, Intent[] intents)`: 96 + 96 n bytes, offset 0x40, n <= declared, kinds / caps / `to`,
    ///      value + Σ amounts <= available.
    function _afterPoint(uint8 point, bytes memory ret, uint64 valueCap, bool valueAllowed, uint256 available)
        internal
        view
        returns (uint256 total)
    {
        if (ret.length < 96 || (ret.length - 96) % 96 != 0) _bad(point, "returndata must be 96 + 96 n bytes");
        if (_word(ret, 1) != 0x40) _bad(point, "intent array offset must be 0x40");
        uint256 n = _word(ret, 2);
        if (ret.length != 96 + 96 * n) _bad(point, "returndata size does not match the intent count");
        if (n > RegistryRules.maxIntentsAt(_limits, point)) _bad(point, "more intents than declared (maxIntents)");
        uint256 value = _word(ret, 0);
        if (value != 0) {
            if (!valueAllowed) _bad(point, "first word must be 0");
            if (caps & valueCap == 0) {
                _bad(point, "non-zero rebate / lpRebate / lpReward without its delta capability");
            }
        }
        total = value;
        uint256 maxKind = point == 6 ? 3 : 6;
        for (uint256 k; k < n; ++k) {
            uint256 kind = _word(ret, 3 + 3 * k);
            uint256 to = _word(ret, 4 + 3 * k);
            uint256 amount = _word(ret, 5 + 3 * k);
            if (kind == 0 || kind > maxKind) _bad(point, "intent kind out of range (1-6; 1-3 at point 6)");
            if (caps & (uint64(1) << (kind - 1)) == 0) _bad(point, "intent kind without its capability bit");
            if (kind == 1) {
                if (to == 0 || to >> 160 != 0) _bad(point, "PAY needs a non-zero address");
                if (address(uint160(to)) == address(this)) _bad(point, "PAY to hook C is forbidden");
            } else if (to != 0) {
                _bad(point, "to must be 0 for intent kinds 2-6");
            }
            if (amount >> 128 != 0) _bad(point, "intent amount above any allotment");
            total += amount;
        }
        if (total > available) _bad(point, "rebate + intents exceed ctx.available");
    }

    function _word(bytes memory b, uint256 i) internal pure returns (uint256 w) {
        assembly ("memory-safe") {
            w := mload(add(add(b, 32), shl(5, i)))
        }
    }

    function _bad(uint8 point, string memory why) internal pure {
        revert ConformanceViolation(point, why);
    }
}
