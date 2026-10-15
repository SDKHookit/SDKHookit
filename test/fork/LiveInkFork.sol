// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {HookitInk} from "../../src/hookit/HookitInk.sol";
import {IHookitModuleRegistry, ModuleEntry} from "../../src/hookit/ModuleRegistryTypes.sol";
import {PluginManifest} from "../../src/hookit/PluginManifest.sol";
import {RegistryRules} from "../../src/hookit/RegistryRules.sol";

// Minimal ABI copies of the live Hookit v2 contracts (monorepo: src/c/HookCTypes.sol, src/c/interfaces/
// ILaunchFactoryC.sol, src/libraries/BitmaskConfig.sol, src/HookitSwapRouter.sol).

struct PluginChoice {
    uint32 moduleId;
    uint16 potBps;
    bytes initData;
}

struct MasterCConfig {
    uint16 version;
    uint256 modules; // BitmaskConfig word
    uint256 vestPacked;
    PluginChoice[] plugins;
}

struct LaunchParamsC {
    string name;
    string symbol;
    string metadataURI;
    uint256 totalSupply;
    address quote;
    int24 tickSpacing;
    uint32 hookId;
    bytes hookConfig;
    uint256 devBuyQuoteIn;
    uint256 minDevBuyTokensOut;
}

interface IFactoryC {
    function launchFee() external view returns (uint256);
    function poolKeyOf(uint256 launchId) external view returns (PoolKey memory);
    function launch(LaunchParamsC calldata p) external payable returns (uint256 launchId, address token, PoolId poolId);
}

interface IHookitSwapRouter {
    function swapExactIn(
        PoolKey calldata key,
        bool zeroForOne,
        uint256 amountIn,
        uint256 minAmountOut,
        uint160 sqrtPriceLimitX96
    ) external payable returns (uint256 amountOut);
}

interface IHookRegistryView {
    function apiVersionMask() external view returns (uint64);
}

interface IERC20Min {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

/// @title LiveInkForkHarness
/// @notice Your plugin on the REAL Hookit v2 stack, on an Ink mainnet fork: deployed with the live ModuleRegistry,
///         registered with your manifest values by the registry admin (pranked: only possible on a fork), launched
///         through the live Factory C on the live hook C, traded through the live HookitSwapRouter (buys and sells
///         of several sizes), then halted. Hook C calls your plugin with exactly your declared gas, so an
///         under-declared point or a bad return shows up here as a reverted swap. Nothing is broadcast.
///         Skipped unless INK_RPC_URL is set:
///           INK_RPC_URL=https://rpc-gel.inkonchain.com forge test --match-path 'test/fork/*' -vv
abstract contract LiveInkForkHarness is Test {
    using StateLibrary for IPoolManager;

    address internal constant SWAP_ROUTER = 0xb099176151Ecde2E194CCa23E491413f789D1Cb7;
    uint256 internal constant HOOK_TAX_SHIFT = 7;
    uint256 internal constant HOOK_TO_CREATOR_ENABLED = 1 << 4;
    uint256 internal constant HOOK_TO_CREATOR_BPS_SHIFT = 55;
    bytes32 internal constant PLUGIN_SKIPPED = keccak256("PluginCallSkipped(bytes32,uint16,uint8,uint8)");

    address internal trader = address(0x7EADE5);
    bool internal forked;
    address internal plugin;
    uint32 internal moduleId;
    uint256 private _n;

    // ------------------------------------------------------------------ implement these

    /// @notice Deploy your plugin with `registry` (HookitInk.MODULE_REGISTRY) as its constructor argument.
    function _deployPlugin(address registry) internal virtual returns (address);
    function _manifest(address plugin_) internal view virtual returns (PluginManifest memory);

    /// @notice Launch data for the test coin. Default: empty.
    function _initData() internal view virtual returns (bytes memory) {
        return "";
    }

    /// @notice Pot share routed to the plugin. Default: half of maxPotBps (0 for a plugin that moves no money).
    function _potBps() internal view virtual returns (uint16) {
        return _manifest(plugin).maxPotBps / 2;
    }

    // ------------------------------------------------------------------ setup

    function setUp() public virtual {
        string memory rpc = vm.envOr("INK_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        require(block.chainid == HookitInk.CHAIN_ID, "INK_RPC_URL is not Ink mainnet");
        forked = true;
        plugin = _deployPlugin(HookitInk.MODULE_REGISTRY);
        moduleId = _register(_manifest(plugin));
    }

    /// @dev What the Hookit owner does after review: addModule with your manifest values.
    function _register(PluginManifest memory m) internal returns (uint32 id) {
        IHookitModuleRegistry r = IHookitModuleRegistry(HookitInk.MODULE_REGISTRY);
        RegistryRules.checkAddModule(m, IHookRegistryView(r.hookRegistry()).apiVersionMask());
        vm.prank(r.admin());
        id = r.addModule(
            m.plugin,
            m.caps,
            m.hookApiMask,
            m.limits,
            m.maxPotBps,
            m.maxSurchargeBps,
            m.compat,
            keccak256("review record")
        );
        ModuleEntry memory e = r.moduleEntry(id);
        assertEq(e.codehash, plugin.codehash, "registry pinned the deployed codehash");
    }

    // ------------------------------------------------------------------ helpers

    function _word(uint256 taxBps, uint256 toCreatorBps) internal pure returns (uint256) {
        return (taxBps << HOOK_TAX_SHIFT) | HOOK_TO_CREATOR_ENABLED | (toCreatorBps << HOOK_TO_CREATOR_BPS_SHIFT);
    }

    /// @notice Launch an ETH coin, hook tax 5 %, pot split creator / plugin (`potBps`); `withPlugin` false = plain.
    function _launch(bool withPlugin) internal returns (address token, PoolKey memory key) {
        LaunchParamsC memory lp = _params(_hookConfig(withPlugin));
        uint256 fee = IFactoryC(HookitInk.FACTORY_C).launchFee();
        vm.deal(address(this), fee);
        uint256 id;
        (id, token,) = IFactoryC(HookitInk.FACTORY_C).launch{value: fee}(lp);
        key = IFactoryC(HookitInk.FACTORY_C).poolKeyOf(id);
        assertEq(address(key.hooks), HookitInk.HOOK_C, "live hook C");
    }

    function _hookConfig(bool withPlugin) internal view returns (bytes memory) {
        uint16 pot = withPlugin ? _potBps() : 0;
        PluginChoice[] memory ch = new PluginChoice[](withPlugin ? 1 : 0);
        if (withPlugin) ch[0] = PluginChoice({moduleId: moduleId, potBps: pot, initData: _initData()});
        return abi.encode(MasterCConfig({version: 1, modules: _word(500, 10_000 - pot), vestPacked: 0, plugins: ch}));
    }

    function _params(bytes memory hookConfig) internal returns (LaunchParamsC memory lp) {
        ++_n;
        lp.name = string.concat("SDK fork ", vm.toString(_n));
        lp.symbol = string.concat("SDKF", vm.toString(_n));
        lp.metadataURI = "ipfs://sdk-fork";
        lp.totalSupply = 1_000_000_000e18;
        lp.tickSpacing = 60;
        lp.hookConfig = hookConfig;
    }

    function _buy(PoolKey memory key, address token, uint256 ethIn) internal returns (uint256 out) {
        vm.roll(vm.getBlockNumber() + 1);
        vm.deal(trader, trader.balance + ethIn);
        uint256 t0 = IERC20Min(token).balanceOf(trader);
        vm.prank(trader, trader);
        IHookitSwapRouter(SWAP_ROUTER).swapExactIn{value: ethIn}(key, true, ethIn, 0, 0);
        out = IERC20Min(token).balanceOf(trader) - t0;
    }

    function _sell(PoolKey memory key, address token, uint256 amount) internal returns (uint256 out) {
        vm.roll(vm.getBlockNumber() + 1);
        uint256 e0 = trader.balance;
        vm.startPrank(trader, trader);
        IERC20Min(token).approve(SWAP_ROUTER, amount);
        IHookitSwapRouter(SWAP_ROUTER).swapExactIn(key, false, amount, 0, 0);
        vm.stopPrank();
        out = trader.balance - e0;
    }

    function _assertNoSkips() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == HookitInk.HOOK_C && logs[i].topics[0] == PLUGIN_SKIPPED) {
                revert("hook C skipped a plugin call");
            }
        }
    }

    // ------------------------------------------------------------------ the live tests

    /// @notice Buys and sells of several sizes run the plugin on the live hook C without a revert or a skip; then a
    ///         halt leaves the coin trading.
    function testFork_live_tradesThenHalt() public {
        if (!forked) return;
        (address token, PoolKey memory key) = _launch(true);
        uint256[4] memory sizes = [uint256(0.0005 ether), 0.01 ether, 0.2 ether, 1 ether];
        vm.recordLogs();
        for (uint256 i; i < sizes.length; ++i) {
            assertGt(_buy(key, token, sizes[i]), 0, "buy");
            assertGt(_sell(key, token, IERC20Min(token).balanceOf(trader) / 3), 0, "sell");
        }
        _assertNoSkips();
        vm.prank(IHookitModuleRegistry(HookitInk.MODULE_REGISTRY).admin());
        (bool ok,) = HookitInk.MODULE_REGISTRY.call(abi.encodeWithSignature("haltModule(uint32)", moduleId));
        assertTrue(ok, "halt");
        assertGt(_buy(key, token, 0.01 ether), 0, "buy after halt");
        assertGt(_sell(key, token, IERC20Min(token).balanceOf(trader) / 2), 0, "sell after halt");
    }

    /// @notice A plugin that takes no pot share (maxPotBps = 0) must leave trading identical to a plain coin.
    function testFork_live_noMoneyPluginTradesLikeAPlainCoin() public {
        if (!forked || _manifest(plugin).maxPotBps != 0) return;
        (address tp, PoolKey memory kp) = _launch(false);
        (address tc, PoolKey memory kc) = _launch(true);
        uint256[3] memory sizes = [uint256(0.001 ether), 0.05 ether, 0.7 ether];
        for (uint256 i; i < sizes.length; ++i) {
            assertEq(_buy(kc, tc, sizes[i]), _buy(kp, tp, sizes[i]), "same tokens out");
            uint256 amt = IERC20Min(tp).balanceOf(trader) / 3;
            assertEq(_sell(kc, tc, amt), _sell(kp, tp, amt), "same ETH back");
        }
        (uint160 a,,,) = IPoolManager(HookitInk.POOL_MANAGER).getSlot0(kp.toId());
        (uint160 b,,,) = IPoolManager(HookitInk.POOL_MANAGER).getSlot0(kc.toId());
        assertEq(a, b, "same price");
    }
}
