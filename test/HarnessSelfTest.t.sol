// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";

import {HookPluginBase} from "../src/hookit/HookPluginBase.sol";
import {IHookPlugin} from "../src/hookit/IHookPlugin.sol";
import {PluginPortConstants as PPC} from "../src/hookit/PluginPortConstants.sol";
import {PluginLimitsDecl} from "../src/hookit/ModuleRegistryTypes.sol";
import {RegistryRules} from "../src/hookit/RegistryRules.sol";
import {MockHookC, MockHookRegistry, MockModuleRegistry} from "./harness/MockHookC.sol";

/// @dev A deliberately broken plugin; `mode` picks the bug.
contract BadPlugin is HookPluginBase {
    uint256 public immutable mode;
    uint256 public sink;

    constructor(address registry, uint256 mode_) HookPluginBase(address(0), registry) {
        mode = mode_;
    }

    function afterSwapPlugin(AfterSwapCtx calldata ctx) external override returns (uint256, Intent[] memory out) {
        if (mode != 4) _auth(ctx.poolId); // mode 4: forgets to authenticate
        if (mode == 1) revert("boom"); // reverts on valid input
        if (mode == 2) {
            out = new Intent[](1); // asks for more than available
            out[0] = Intent({kind: 1, to: address(0xBEEF), amount: ctx.available + 1});
            return (0, out);
        }
        if (mode == 3) return (0, new Intent[](2)); // more intents than declared (kind 0 too)
        if (mode == 5) {
            for (uint256 i; i < 6; ++i) {
                sink = uint256(keccak256(abi.encode(sink, i, gasleft()))); // one fresh then warm SSTOREs: ~27k
            }
        }
        if (mode == 6) {
            assembly ("memory-safe") {
                mstore(0, 0)
                return(0, 64) // wrong returndata size
            }
        }
        if (mode == 7) {
            out = new Intent[](1); // BURN with a non-zero `to`
            out[0] = Intent({kind: 2, to: address(1), amount: 0});
            return (0, out);
        }
        if (mode == 8) return (1, new Intent[](0)); // rebate without CAP_AFTER_SWAP_DELTA
        return (0, new Intent[](0));
    }

    function _custodyAssets(address) internal pure override returns (uint256) {
        return 0;
    }

    function _payCustody(address, address, uint256) internal pure override {}
}

/// @notice Proves the harness catches each class of bug (otherwise a green harness would mean nothing).
contract HarnessSelfTest is Test {
    using PoolIdLibrary for PoolKey;

    MockHookRegistry internal hooks;
    MockModuleRegistry internal registry;
    MockHookC internal hook;

    function setUp() public {
        hooks = new MockHookRegistry();
        registry = new MockModuleRegistry(address(hooks));
        hook = new MockHookC();
        hooks.setRegistered(address(hook), true);
    }

    function _setup(uint256 mode) internal returns (BadPlugin p, IHookPlugin.AfterSwapCtx memory c) {
        p = new BadPlugin(address(registry), mode);
        PluginLimitsDecl memory l;
        l.launchGas = 100_000;
        l.gas[7] = mode == 5 ? 45_000 : 60_000; // mode 5 fits in 45k but uses more than half of it
        l.maxIntents[2] = 1;
        hook.configure(address(p), PPC.CAP_AFTER_SWAP | PPC.CAP_PAY | PPC.CAP_BURN, l, 0);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(0x1234)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        IHookPlugin.LaunchCtx memory lc;
        lc.poolId = key.toId();
        lc.key = key;
        lc.token = address(0x1234);
        hook.launch(lc, "");
        c.poolId = key.toId();
        c.token = address(0x1234);
        c.isBuy = true;
        c.available = 1 ether;
    }

    function test_catchesRevert() public {
        (, IHookPlugin.AfterSwapCtx memory c) = _setup(1);
        vm.expectPartialRevert(MockHookC.PluginReverted.selector);
        hook.afterSwap(c);
    }

    function test_catchesOverAllotment() public {
        (, IHookPlugin.AfterSwapCtx memory c) = _setup(2);
        vm.expectRevert(
            abi.encodeWithSelector(MockHookC.ConformanceViolation.selector, 8, "rebate + intents exceed ctx.available")
        );
        hook.afterSwap(c);
    }

    function test_catchesTooManyIntents() public {
        (, IHookPlugin.AfterSwapCtx memory c) = _setup(3);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockHookC.ConformanceViolation.selector, 8, "more intents than declared (maxIntents)"
            )
        );
        hook.afterSwap(c);
    }

    function test_catchesMissingAuth() public {
        (BadPlugin p, IHookPlugin.AfterSwapCtx memory c) = _setup(4);
        c.poolId = PoolId.wrap(bytes32(uint256(42))); // never launched
        (bool ok,) = hook.rawCall(abi.encodeCall(IHookPlugin.afterSwapPlugin, (c)), 1_000_000);
        assertTrue(ok, "the broken plugin accepts an unlaunched pool: the harness auth test flags exactly this");
        p; // silence
    }

    function test_catchesGasAboveHalfDeclared() public {
        (, IHookPlugin.AfterSwapCtx memory c) = _setup(5);
        hook.afterSwap(c); // fits in the declared 45k...
        assertGt(2 * hook.maxGasUsed(8), hook.declaredGas(8), "...but the 2x rule fails");
    }

    function test_catchesWrongReturnSize() public {
        (, IHookPlugin.AfterSwapCtx memory c) = _setup(6);
        vm.expectRevert(
            abi.encodeWithSelector(MockHookC.ConformanceViolation.selector, 8, "returndata must be 96 + 96 n bytes")
        );
        hook.afterSwap(c);
    }

    function test_catchesNonZeroToOnBurn() public {
        (, IHookPlugin.AfterSwapCtx memory c) = _setup(7);
        vm.expectRevert(
            abi.encodeWithSelector(MockHookC.ConformanceViolation.selector, 8, "to must be 0 for intent kinds 2-6")
        );
        hook.afterSwap(c);
    }

    function test_catchesRebateWithoutCapability() public {
        (, IHookPlugin.AfterSwapCtx memory c) = _setup(8);
        c.isBuy = false;
        c.exactInput = true;
        c.quoteIsUnspecified = true;
        vm.expectRevert(
            abi.encodeWithSelector(
                MockHookC.ConformanceViolation.selector,
                8,
                "non-zero rebate / lpRebate / lpReward without its delta capability"
            )
        );
        hook.afterSwap(c);
    }

    function test_registryRulesRejectBrokenDeclarations() public {
        vm.expectRevert(RegistryRules.CapDependency.selector);
        this.checkCaps(PPC.CAP_BURN); // an intent kind with no after-point
        vm.expectRevert(RegistryRules.UnknownCapBits.selector);
        this.checkCaps(uint64(1) << 12); // reserved bit
        PluginLimitsDecl memory l;
        l.launchGas = 100_000;
        l.gas[6] = 50_000; // point 7 declared but not subscribed
        vm.expectRevert(RegistryRules.BadLimits.selector);
        this.checkLimits(PPC.CAP_AFTER_SWAP, l);
        l.gas[6] = 0;
        l.gas[7] = 9_999; // below the 10k floor
        vm.expectRevert(RegistryRules.BadLimits.selector);
        this.checkLimits(PPC.CAP_AFTER_SWAP, l);
        l.gas[7] = 50_000;
        l.maxIntents[2] = 1; // intents without an intent capability
        vm.expectRevert(RegistryRules.BadLimits.selector);
        this.checkLimits(PPC.CAP_AFTER_SWAP, l);
        this.checkLimits(PPC.CAP_AFTER_SWAP | PPC.CAP_PAY, l); // ok
    }

    function checkCaps(uint64 caps) external pure {
        RegistryRules.checkCaps(caps);
    }

    function checkLimits(uint64 caps, PluginLimitsDecl memory l) external pure {
        RegistryRules.checkLimits(caps, l.launchGas, RegistryRules.pack(l));
    }
}
