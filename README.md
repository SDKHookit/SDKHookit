# Hookit Plugin SDK

Write, test and submit a **plugin for Hookit** (hookit.fun) — a Uniswap v4 launchpad on Ink (chain 57073). A
plugin is a small contract that Hookit's hook ("hook C") calls on the swaps, liquidity changes and donations of the
coins that chose it. You build and deploy it; the Hookit owner reviews it and registers it; creators pick it in the
launch form. Submit at **https://hookit.fun/workshop/submit**; the walkthrough and the briefs for coding agents
are at https://hookit.fun/workshop/build.

Public home: https://github.com/SDKHookit/SDKHookit (published from the Hookit monorepo's `sdk/plugin-sdk`).
The folder is self-contained: clone it anywhere.
If you work with an AI agent, point it at [`AGENTS.md`](AGENTS.md) (also `CLAUDE.md`, and the skill in
`.claude/skills/hookit-plugin-sdk/`).

## Quickstart

Requires [Foundry](https://getfoundry.sh) and git.

```sh
git clone https://github.com/SDKHookit/SDKHookit hookit-plugin-sdk && cd hookit-plugin-sdk
./setup.sh                                                   # deps into ./lib (see below)
forge build
forge test                                                   # examples + starter + harness self-test
forge test --match-test test_conformance_gasReport -vv       # measured gas per hook point
INK_RPC_URL=https://rpc-gel.inkonchain.com forge test --match-path 'test/fork/*' -vv   # live hook C on an Ink fork
forge script script/Manifest.s.sol --sig "run(string)" swap-counter                     # print a manifest
```

Then edit `src/MyPlugin.sol` (follow the `TODO`s), run `forge test` until green, deploy with your own wallet, and
generate the manifest of the deployed address ([`AGENTS.md`](AGENTS.md) §3 has the exact keyless commands).

## What is inside

| Path | What |
|---|---|
| `src/hookit/IHookPlugin.sol` | The plugin interface (API v3), vendored verbatim from the monorepo |
| `src/hookit/HookPluginBase.sol` | Base contract: authenticated one-shot `onLaunch`, `_auth`, no-op callbacks, custody accumulator (vendored) |
| `src/hookit/PluginPortConstants.sol` | Capability bits and limits (vendored) |
| `src/hookit/ModuleRegistryTypes.sol` | `PluginLimitsDecl`, `CompatDecl`, `ModuleEntry`, registry interface subset |
| `src/hookit/RegistryRules.sol` | Offline copy of every `ModuleRegistry.addModule` check + mechanical review rules |
| `src/hookit/PluginManifest.sol` | The manifest struct and its JSON serialiser |
| `src/hookit/HookitInk.sol` | Live Ink addresses and the `hookApiMask` to use (2) |
| `src/examples/SwapCounterPlugin.sol` | Example 1: counts swaps, moves no money |
| `src/examples/BuyBurnPlugin.sol` | Example 2: queues a buy-and-burn on each buy, bounded by `ctx.available` |
| `src/MyPlugin.sol` | Starter with TODOs |
| `test/harness/PluginHarness.sol` | Reusable conformance harness: inherit it, implement two functions |
| `test/harness/MockHookC.sol` | Mock hook C (exact declared gas, return checks) + mock registries |
| `test/fork/LiveInkFork.sol` | Live-Ink fork harness: register (admin pranked), launch, trade, halt on the real stack |
| `test/HarnessSelfTest.t.sol` | Broken plugins the harness must catch |
| `script/Manifest.s.sol` | Prints + writes the Workshop manifest JSON; never broadcasts |
| `MANIFEST.md` | The manifest JSON schema and its mapping to `addModule` |
| `examples/manifest.*.json` | Sample manifests |

## Dependencies (`./setup.sh`)

The SDK needs Uniswap v4-core (types and `FullMath`) and forge-std, both under `./lib` (git-ignored):

- **Inside the Hookit monorepo**, `setup.sh` symlinks `lib/v4-core` and `lib/forge-std` to the monorepo's `../../lib`
  copies (if `../../lib/forge-std` is empty, run `git submodule update --init lib/forge-std` at the monorepo root).
- **Copied out on its own**, it clones the pinned versions: `Uniswap/v4-core@v4.0.0` and `foundry-rs/forge-std@v1.16.2`.
  Equivalent with forge: `git init && forge install uniswap/v4-core@v4.0.0 foundry-rs/forge-std@v1.16.2`.

Compiler settings match the monorepo: solc 0.8.26, EVM cancun, via-IR, `bytecode_hash = "none"`.

## The conformance harness

```solidity
contract MyPluginTest is PluginHarness {
    function _deployPlugin(address registry) internal override returns (address) {
        return address(new MyPlugin(registry));
    }
    function _manifest(address p) internal view override returns (PluginManifest memory) {
        return MyPluginDeclaration.manifest(p);
    }
}
```

Inherited tests: declaration passes every registry check; `hookitPluginApi() == 3`; `onLaunch` authenticated,
one-shot, rejects forged contexts; every subscribed callback rejects hooks / pools that did not launch it; fuzzed
sequences on three pools (ETH and ERC-20 quotes, both token orders) and extreme inputs at the exact declared gas:
no revert, exact return sizes, intents ≤ declared and ≤ `ctx.available`, guards / surcharges / rebates only with
their capabilities; declared gas ≥ 2× measured (cold storage). Mocks cannot replace the real hook C: run the fork
tests too.

## Rules in one paragraph

Never revert in a callback on valid input; never call the PoolManager or hook C; no unbounded loops; declare ≥ 2×
the measured gas; return exactly the declared shapes; spend at most `ctx.available`; `_auth` first and state keyed
by (hook, pool); no owner, proxy, upgrade or randomness; users' funds withdrawable after a halt. The full list, in
plain terms, is in [`AGENTS.md`](AGENTS.md) §2.

## Safety

Nothing in this SDK broadcasts or needs a private key. Deploy with your own wallet through an encrypted keystore
(`cast wallet import <name> --interactive`, then `--account <name>`), never with a key on the command line.
