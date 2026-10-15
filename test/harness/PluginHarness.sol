// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console2} from "forge-std/Test.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {BalanceDelta, toBalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";

import {IHookPlugin} from "../../src/hookit/IHookPlugin.sol";
import {PluginPortConstants as PPC} from "../../src/hookit/PluginPortConstants.sol";
import {PluginManifest, ManifestJson} from "../../src/hookit/PluginManifest.sol";
import {RegistryRules} from "../../src/hookit/RegistryRules.sol";
import {MockHookC, MockHookRegistry, MockModuleRegistry} from "./MockHookC.sol";

/// @title PluginHarness
/// @notice Reusable conformance harness for a Hookit hook C plugin. Inherit it, implement `_deployPlugin` and
///         `_manifest`, and you get, for free, every review rule that can be checked mechanically (§9.3):
///         - the declaration passes every `ModuleRegistry.addModule` check (offline copy, same errors) and the
///           mechanical review rules (family group, codehash);
///         - `hookitPluginApi() == 3`; `onLaunch` authenticated, one-shot, rejects forged contexts, <= 3 custody;
///         - every subscribed callback rejects a hook / pool that did not launch it;
///         - fuzzed sequences on three pools (ETH quote, ERC-20 quote on either side) hitting every subscribed point
///           with the EXACT declared gas: no revert, exact return shapes, intents <= declared and <= ctx.available,
///           guard / surcharge / rebate only with their capabilities;
///         - extreme inputs (1e30 amounts, int128-limit liquidity, uint128 donations, min / max ticks);
///         - gas: declared >= 2x the highest measured use, cold storage included (printed with -vv).
///         Mocks: `MockHookRegistry` + `MockModuleRegistry` (what HookPluginBase reads) and `MockHookC` (calls and
///         checks like hook C). It does not replace a fork test against the live hook C (see README).
abstract contract PluginHarness is Test {
    using PoolIdLibrary for PoolKey;

    struct HPool {
        PoolKey key;
        PoolId id;
        address token;
        Currency quote;
        bool tokenIsCurrency0;
    }

    MockHookRegistry internal hookRegistry;
    MockModuleRegistry internal moduleRegistry;
    MockHookC internal hook; // the registered hook C stand-in
    MockHookC internal otherHook; // registered too, but never launches the harness pools
    MockHookC internal rogueHook; // not registered
    address internal plugin;

    uint256 internal constant MAX_AMOUNT = 1e30; // > 1e27-wei supplies, any 6/8/18-decimal quote
    uint256 private _nonce;

    // ------------------------------------------------------------------ implement these

    /// @notice Deploy the plugin under test, constructed with `moduleRegistry_` as its ModuleRegistry.
    function _deployPlugin(address moduleRegistry_) internal virtual returns (address);

    /// @notice The plugin's declaration (the same one the manifest script prints).
    function _manifest(address plugin_) internal view virtual returns (PluginManifest memory);

    // ------------------------------------------------------------------ optional overrides

    /// @notice The creator's launch data for a fuzzed launch. Default: empty.
    function _initData(
        uint256 /* seed */
    )
        internal
        view
        virtual
        returns (bytes memory)
    {
        return "";
    }

    /// @notice The creator's pot share for this plugin at launch (<= maxPotBps). Default: half of maxPotBps.
    function _potBps() internal view virtual returns (uint16) {
        return _manifest(plugin).maxPotBps / 2;
    }

    /// @notice Hook for plugin-specific invariants, run after every successful callback.
    function _afterEachCall(uint8 point, HPool memory p) internal virtual {}

    // ------------------------------------------------------------------ setup

    function setUp() public virtual {
        hookRegistry = new MockHookRegistry();
        moduleRegistry = new MockModuleRegistry(address(hookRegistry));
        hook = new MockHookC();
        otherHook = new MockHookC();
        rogueHook = new MockHookC();
        hookRegistry.setRegistered(address(hook), true);
        hookRegistry.setRegistered(address(otherHook), true);
        plugin = _deployPlugin(address(moduleRegistry));
        PluginManifest memory m = _manifest(plugin);
        hook.configure(plugin, m.caps, m.limits, m.maxSurchargeBps);
        otherHook.configure(plugin, m.caps, m.limits, m.maxSurchargeBps);
        rogueHook.configure(plugin, m.caps, m.limits, m.maxSurchargeBps);
    }

    // ================================================================== the conformance tests

    function test_conformance_declarationPassesRegistryChecks() public view {
        PluginManifest memory m = _manifest(plugin);
        RegistryRules.checkAddModule(m, hookRegistry.apiVersionMask());
        RegistryRules.checkReviewRules(m);
        assertEq(m.plugin, plugin, "manifest names the plugin under test");
        assertLe(_potBps(), m.maxPotBps, "harness potBps within maxPotBps");
    }

    function test_conformance_pluginApiIs3() public view {
        (bool ok, bytes memory ret) = plugin.staticcall{gas: 30_000}(abi.encodeWithSignature("hookitPluginApi()"));
        assertTrue(ok && ret.length == 32, "hookitPluginApi() answers 32 bytes within 30k gas");
        assertEq(abi.decode(ret, (uint256)), 3, "plugin API 3");
    }

    function test_conformance_onLaunchAuthenticatedAndOneShot() public {
        HPool memory p = _newPool(hook, 0, 0);
        IHookPlugin.LaunchCtx memory ctx = _launchCtx(p);
        bytes memory init = _initData(0);

        // a hook the HookRegistry does not list cannot launch
        HPool memory rp = _newPool(rogueHook, 0, 1);
        (bool ok,) = rogueHook.rawCall(abi.encodeCall(IHookPlugin.onLaunch, (_launchCtx(rp), init)), 1_000_000);
        assertFalse(ok, "onLaunch from an unregistered hook must revert");

        // forged context: key.hooks is not the caller / poolId is not keccak256(key)
        IHookPlugin.LaunchCtx memory forged = _launchCtx(p);
        forged.poolId = PoolId.wrap(bytes32(uint256(1)));
        (ok,) = hook.rawCall(abi.encodeCall(IHookPlugin.onLaunch, (forged, init)), 1_000_000);
        assertFalse(ok, "onLaunch with a forged poolId must revert");
        (ok,) = otherHook.rawCall(abi.encodeCall(IHookPlugin.onLaunch, (ctx, init)), 1_000_000);
        assertFalse(ok, "onLaunch where key.hooks != msg.sender must revert");

        // the real launch, at the declared launchGas, then a second launch of the same pool reverts
        _cool();
        hook.launch(ctx, init);
        (ok,) = hook.rawCall(abi.encodeCall(IHookPlugin.onLaunch, (ctx, init)), 1_000_000);
        assertFalse(ok, "onLaunch is one-shot per (hook, poolId)");
    }

    function test_conformance_callbacksRejectUnlaunchedPools() public {
        HPool memory p = _newPool(hook, 0, 0);
        // pool not launched yet: every subscribed callback from the registered hook reverts
        _assertAllRevert(hook, p, "registered hook, pool never launched");
        _launch(p, 0);
        // launched by `hook`: another registered hook and an unregistered one still cannot call for that pool
        _assertAllRevert(otherHook, p, "another registered hook, pool launched by hook C");
        _assertAllRevert(rogueHook, p, "unregistered hook");
    }

    /// @notice Fuzzed sequences over three pools at the exact declared gas, then the 2x gas rule.
    function testFuzz_conformance_randomSequence(uint256 seed) public {
        HPool[3] memory pools = [_newPool(hook, 0, seed), _newPool(hook, 1, seed), _newPool(hook, 2, seed)];
        for (uint256 i; i < 3; ++i) {
            _launch(pools[i], uint256(keccak256(abi.encode(seed, "launch", i))));
        }
        uint8[] memory pts = _points();
        if (pts.length == 0) return;
        for (uint256 s; s < 24; ++s) {
            uint256 r = uint256(keccak256(abi.encode(seed, s)));
            _callPoint(pts[r % pts.length], pools[(r >> 8) % 3], r >> 16, false);
        }
        _assertGasRule(false);
    }

    /// @notice Extreme but valid inputs at every subscribed point.
    function testFuzz_conformance_extremeInputs(uint256 seed) public {
        HPool memory p = _newPool(hook, seed % 3, seed);
        _launch(p, seed);
        uint8[] memory pts = _points();
        for (uint256 i; i < pts.length; ++i) {
            for (uint256 k; k < 3; ++k) {
                _callPoint(pts[i], p, uint256(keccak256(abi.encode(seed, i, k))), true);
            }
        }
        _assertGasRule(false);
    }

    /// @notice Deterministic worst-case pass (fresh pools, cold storage) that prints the measured table: run
    ///         `forge test --match-test test_conformance_gasReport -vv` and declare >= 2x each line.
    function test_conformance_gasReport() public {
        uint8[] memory pts = _points();
        for (uint256 n; n < 4; ++n) {
            HPool memory p = _newPool(hook, n % 3, n);
            _launch(p, n);
            for (uint256 rep; rep < 4; ++rep) {
                for (uint256 i; i < pts.length; ++i) {
                    _callPoint(pts[i], p, uint256(keccak256(abi.encode("gas", n, rep, i))), rep == 3);
                }
            }
        }
        _assertGasRule(true);
    }

    // ================================================================== building blocks (usable in your tests)

    /// @notice A fresh pool on `h`. kind 0 = ETH quote; 1 = ERC-20 quote, token is currency0; 2 = ERC-20 quote,
    ///         token is currency1.
    function _newPool(MockHookC h, uint256 kind, uint256 seed) internal returns (HPool memory p) {
        ++_nonce;
        address token = address(uint160(uint256(keccak256(abi.encode("token", seed, _nonce))) | (1 << 159)));
        if (token == address(type(uint160).max)) token = address(uint160(token) - 1);
        address q; // kind 0: ETH (address 0 < token, so the token is currency1)
        if (kind == 1) q = address(uint160(token) + 1); // quote above the token: token is currency0
        else if (kind == 2) q = address(uint160(token) >> 1); // quote below the token: token is currency1
        p.token = token;
        p.quote = Currency.wrap(q);
        p.tokenIsCurrency0 = token < q;
        (address c0, address c1) = p.tokenIsCurrency0 ? (token, q) : (q, token);
        p.key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(h))
        });
        p.id = p.key.toId();
    }

    function _launchCtx(HPool memory p) internal view returns (IHookPlugin.LaunchCtx memory c) {
        PluginManifest memory m = _manifest(plugin);
        c.poolId = p.id;
        c.key = p.key;
        c.token = p.token;
        c.quote = p.quote;
        c.creator = address(0xC2EA702);
        c.tokenIsCurrency0 = p.tokenIsCurrency0;
        c.tickLower = -887220;
        c.tickUpper = 887220;
        c.marketIndex = 0;
        c.marketCount = 1;
        c.slot = 0;
        c.slotCount = 1;
        c.potBps = _potBps();
        c.potBpsSum = _potBps();
        c.caps = m.caps;
        c.maxSurchargeBps = m.maxSurchargeBps;
        // hook C's per-slot limits word: registry part (RegistryRules.pack), potBps at bit 216, maxSurchargeBps at 232
        c.limits = RegistryRules.pack(m.limits) | (uint256(_potBps()) << 216) | (uint256(m.maxSurchargeBps) << 232);
    }

    /// @notice Launch `p` through its hook at the declared launch gas, then the initialize points if subscribed.
    function _launch(HPool memory p, uint256 seed) internal {
        MockHookC h = MockHookC(address(p.key.hooks));
        _cool();
        h.launch(_launchCtx(p), _initData(seed));
        uint64 caps = _manifest(plugin).caps;
        uint160 sp = uint160(bound(seed, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
        IHookPlugin.InitCtx memory ic =
            IHookPlugin.InitCtx({poolId: p.id, token: p.token, quote: p.quote, slot: 0, sqrtPriceX96: sp, tick: 0});
        if (RegistryRules.subscribed(caps, 1)) {
            _cool();
            h.beforeInitialize(ic);
        }
        if (RegistryRules.subscribed(caps, 2)) {
            ic.tick = TickMath.getTickAtSqrtPrice(sp);
            _cool();
            h.afterInitialize(ic);
        }
    }

    /// @notice The subscribed points 3-10 (points 1-2 run once, at `_launch`).
    function _points() internal view returns (uint8[] memory pts) {
        uint64 caps = _manifest(plugin).caps;
        pts = new uint8[](8);
        uint256 n;
        for (uint8 p = 3; p <= 10; ++p) {
            if (RegistryRules.subscribed(caps, p)) pts[n++] = p;
        }
        assembly ("memory-safe") {
            mstore(pts, n)
        }
    }

    /// @notice One call of `point` on `p` with a context derived from `r`; `extreme` pushes values to their limits.
    function _callPoint(uint8 point, HPool memory p, uint256 r, bool extreme) internal {
        MockHookC h = MockHookC(address(p.key.hooks));
        _cool();
        if (point == 7) h.beforeSwap(_swapCtx(p, r, extreme));
        else if (point == 8) h.afterSwap(_afterSwapCtx(p, r, extreme));
        else if (point == 3) h.beforeAddLiquidity(_liqCtx(p, r, extreme, true));
        else if (point == 4) h.afterAddLiquidity(_afterLiqCtx(p, r, extreme, true));
        else if (point == 5) h.beforeRemoveLiquidity(_liqCtx(p, r, extreme, false));
        else if (point == 6) h.afterRemoveLiquidity(_afterLiqCtx(p, r, extreme, false));
        else if (point == 9) h.beforeDonate(_donateCtx(p, r, extreme));
        else if (point == 10) h.afterDonate(_donateCtx(p, r, extreme));
        _afterEachCall(point, p);
    }

    // ------------------------------------------------------------------ contexts

    function _amt(uint256 r, bool extreme) internal pure returns (uint256) {
        if (extreme) return r % 2 == 0 ? MAX_AMOUNT : 1;
        return r % 7 == 0 ? 0 : r % (r % 3 == 0 ? 1e18 : MAX_AMOUNT);
    }

    function _addr(uint256 r) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encode("addr", r % 16)))));
    }

    function _sqrtP(uint256 r, bool extreme) internal pure returns (uint160) {
        if (extreme) return r % 2 == 0 ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE - 1;
        return uint160(bound(r, TickMath.MIN_SQRT_PRICE, TickMath.MAX_SQRT_PRICE - 1));
    }

    function _tickOf(uint160 sp) internal pure returns (int24) {
        return TickMath.getTickAtSqrtPrice(sp);
    }

    function _delta(HPool memory p, int256 quoteSide, int256 tokenSide) internal pure returns (BalanceDelta) {
        return p.tokenIsCurrency0
            ? toBalanceDelta(int128(tokenSide), int128(quoteSide))
            : toBalanceDelta(int128(quoteSide), int128(tokenSide));
    }

    function _swapCtx(HPool memory p, uint256 r, bool extreme) internal pure returns (IHookPlugin.SwapCtx memory c) {
        c.poolId = p.id;
        c.token = p.token;
        c.quote = p.quote;
        c.sender = _addr(r);
        c.origin = _addr(r >> 4);
        c.hint = (r >> 8) % 2 == 0 ? address(0) : _addr(r >> 12);
        c.isBuy = (r >> 16) % 2 == 0;
        c.exactInput = (r >> 17) % 2 == 0;
        c.quoteIsUnspecified = c.isBuy ? !c.exactInput : c.exactInput;
        uint256 a = _amt(r >> 20, extreme);
        c.amountSpecified = c.exactInput ? -int256(a) : int256(a);
        c.quoteNotional = _amt(r >> 40, extreme);
        c.sqrtPriceX96 = _sqrtP(r >> 60, extreme);
        c.tick = _tickOf(c.sqrtPriceX96);
        c.liquidity = uint128(extreme ? type(uint128).max : _amt(r >> 80, false));
        c.hookTaxBps = uint16(extreme ? 900 : (r >> 100) % 901);
        c.snipeBps = 0;
        c.feeHeadroomBps = uint16(1000 - 100 - c.hookTaxBps);
        c.rebateHeadroom = c.quoteNotional * (100 + c.hookTaxBps) / 10_000;
        c.available = _amt(r >> 120, extreme);
    }

    function _afterSwapCtx(HPool memory p, uint256 r, bool extreme)
        internal
        pure
        returns (IHookPlugin.AfterSwapCtx memory c)
    {
        c.poolId = p.id;
        c.token = p.token;
        c.quote = p.quote;
        c.sender = _addr(r);
        c.origin = _addr(r >> 4);
        c.hint = (r >> 8) % 2 == 0 ? address(0) : _addr(r >> 12);
        c.isBuy = (r >> 16) % 2 == 0;
        c.exactInput = (r >> 17) % 2 == 0;
        c.quoteIsUnspecified = c.isBuy ? !c.exactInput : c.exactInput;
        c.floorFill = !c.isBuy && (r >> 18) % 5 == 0;
        uint256 q = _amt(r >> 20, extreme);
        uint256 t = _amt(r >> 40, extreme);
        c.delta = c.isBuy ? _delta(p, -int256(q), int256(t)) : _delta(p, int256(q), -int256(t));
        c.quoteNotional = q;
        c.feeTotal = q / 10;
        c.rebatesBefore = 0;
        c.potCredited = c.feeTotal / 2;
        c.sqrtPriceX96After = _sqrtP(r >> 60, extreme);
        c.tickAfter = _tickOf(c.sqrtPriceX96After);
        c.available = _amt(r >> 80, extreme);
    }

    function _ticks(uint256 r, bool extreme) internal pure returns (int24 lo, int24 hi) {
        if (extreme) {
            if (r % 2 == 0) return (-887220, 887220); // full range
            return (0, 60); // single spacing
        }
        int24 a = int24(int256(r % 29_000)) * 60 - 870_000;
        int24 w = int24(int256(1 + (r >> 20) % 200)) * 60;
        lo = a;
        hi = a + w;
    }

    function _liqCtx(HPool memory p, uint256 r, bool extreme, bool add)
        internal
        pure
        returns (IHookPlugin.LiquidityCtx memory c)
    {
        c.poolId = p.id;
        c.token = p.token;
        c.quote = p.quote;
        c.sender = _addr(r);
        c.tokenIsCurrency0 = p.tokenIsCurrency0;
        (c.tickLower, c.tickUpper) = _ticks(r >> 8, extreme);
        c.liquidityDelta = _liqDelta(r >> 40, extreme, add);
        c.salt = bytes32(r % 4);
        c.tickCurrent = _tickOf(_sqrtP(r >> 60, extreme));
        c.available = _amt(r >> 120, extreme);
    }

    function _liqDelta(uint256 r, bool extreme, bool add) internal pure returns (int256) {
        if (extreme) {
            if (r % 3 == 0) return 0; // zero-delta poke
            return add ? int256(type(int128).max) : -int256(type(int128).max);
        }
        int256 v = int256(r % 1e30);
        return add ? (v == 0 ? int256(1) : v) : -v;
    }

    function _afterLiqCtx(HPool memory p, uint256 r, bool extreme, bool add)
        internal
        pure
        returns (IHookPlugin.AfterLiquidityCtx memory c)
    {
        c.poolId = p.id;
        c.token = p.token;
        c.quote = p.quote;
        c.sender = _addr(r);
        c.tokenIsCurrency0 = p.tokenIsCurrency0;
        (c.tickLower, c.tickUpper) = _ticks(r >> 8, extreme);
        c.liquidityDelta = _liqDelta(r >> 40, extreme, add);
        c.salt = bytes32(r % 4);
        int256 q = int256(_amt(r >> 60, extreme));
        int256 t = int256(_amt(r >> 80, extreme));
        c.delta = add ? _delta(p, -q, -t) : _delta(p, q, t);
        c.available = _amt(r >> 120, extreme);
    }

    function _donateCtx(HPool memory p, uint256 r, bool extreme)
        internal
        pure
        returns (IHookPlugin.DonateCtx memory c)
    {
        c.poolId = p.id;
        c.token = p.token;
        c.quote = p.quote;
        c.sender = _addr(r);
        c.amount0 = extreme ? type(uint128).max : (r >> 8) % 3 == 0 ? 1 : _amt(r >> 8, false);
        c.amount1 = extreme ? ((r >> 1) % 2 == 0 ? 0 : type(uint128).max) : _amt(r >> 40, false);
        c.tickCurrent = _tickOf(_sqrtP(r >> 60, extreme));
        c.available = _amt(r >> 120, extreme);
    }

    // ------------------------------------------------------------------ checks

    /// @dev Marks the plugin's (and the registries') storage cold, so every measurement includes cold access.
    function _cool() internal {
        vm.cool(plugin);
        vm.cool(address(moduleRegistry));
        vm.cool(address(hookRegistry));
    }

    function _assertAllRevert(MockHookC h, HPool memory p, string memory who) internal {
        uint8[] memory pts = _points();
        for (uint256 i; i < pts.length; ++i) {
            bytes memory data = _calldataFor(pts[i], p, uint256(keccak256(abi.encode(who, i))));
            (bool ok,) = h.rawCall(data, 1_000_000);
            assertFalse(ok, string.concat("callback must revert (", who, "), point ", vm.toString(pts[i])));
        }
    }

    function _calldataFor(uint8 point, HPool memory p, uint256 r) internal pure returns (bytes memory) {
        if (point == 7) return abi.encodeCall(IHookPlugin.beforeSwapPlugin, (_swapCtx(p, r, false)));
        if (point == 8) return abi.encodeCall(IHookPlugin.afterSwapPlugin, (_afterSwapCtx(p, r, false)));
        if (point == 3) return abi.encodeCall(IHookPlugin.beforeAddLiquidityPlugin, (_liqCtx(p, r, false, true)));
        if (point == 4) {
            return abi.encodeCall(IHookPlugin.afterAddLiquidityPlugin, (_afterLiqCtx(p, r, false, true)));
        }
        if (point == 5) {
            return abi.encodeCall(IHookPlugin.beforeRemoveLiquidityPlugin, (_liqCtx(p, r, false, false)));
        }
        if (point == 6) {
            return abi.encodeCall(IHookPlugin.afterRemoveLiquidityPlugin, (_afterLiqCtx(p, r, false, false)));
        }
        if (point == 9) return abi.encodeCall(IHookPlugin.beforeDonatePlugin, (_donateCtx(p, r, false)));
        return abi.encodeCall(IHookPlugin.afterDonatePlugin, (_donateCtx(p, r, false)));
    }

    /// @notice Review item 4: declared gas >= 2x the highest measured use at every point that ran.
    function _assertGasRule(bool print) internal {
        PluginManifest memory m = _manifest(plugin);
        if (print) console2.log("point | measured max gas | declared | declared/measured x100");
        for (uint8 point; point <= 10; ++point) {
            uint256 used = hook.maxGasUsed(point);
            if (used == 0) continue;
            uint256 declared = point == 0 ? m.limits.launchGas : m.limits.gas[point - 1];
            if (print) {
                console2.log(
                    string.concat(
                        vm.toString(point),
                        " | ",
                        vm.toString(used),
                        " | ",
                        vm.toString(declared),
                        " | ",
                        vm.toString(declared * 100 / used)
                    )
                );
            }
            assertGe(declared, 2 * used, string.concat("declared gas < 2x measured at point ", vm.toString(point)));
        }
    }

    /// @notice The manifest JSON of the plugin under test (same output as script/Manifest.s.sol).
    function _manifestJson() internal view returns (string memory) {
        return ManifestJson.toJson(_manifest(plugin), block.chainid);
    }
}
