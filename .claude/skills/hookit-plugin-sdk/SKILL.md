---
name: hookit-plugin-sdk
description: Build, test and package a Hookit (hookit.fun, Ink chain 57073) hook C plugin with the Hookit Plugin SDK — Solidity contract on HookPluginBase, conformance harness, gas measurement, live Ink fork test, keyless deployment by the developer, and the Workshop manifest JSON. Use when the user wants to create, test, deploy or submit a Hookit plugin / module / game mechanic from this SDK folder.
---

# Hookit plugin, from idea to Workshop submission (outside developer)

You work inside the Hookit Plugin SDK folder (the one containing `AGENTS.md`). Read `AGENTS.md` first: its §2 rules
are the owner's review checklist. You produce: a plugin contract, its tests, a measured gas declaration, a deployed
and verified contract (deployed by the human), and `manifests/<name>.json`. The Hookit owner reviews and registers it
after submission; you never register anything and there is no owner-side step for you.

## Hard rules

- Never ask for, read, print, store or pass a private key or seed phrase. Deployments use an encrypted keystore the
  human created with `cast wallet import <name> --interactive`, referenced with `--account <name>`.
- Never run a broadcasting command (`--broadcast`, `cast send`, `forge create --broadcast`) unless the human asked for
  it explicitly in this conversation; prefer giving them the command.
- Never edit `src/hookit/*` (vendored ABI) or weaken `test/harness/*` to make a test pass.
- A harness or fork failure is a real hook C failure: fix the plugin, not the test.

## Phase 0 — design (ask before coding)

In one message, ask only what you cannot default, recommending an answer for each:

1. The mechanic in 3-5 sentences: what a buy / sell does, what ends a round, who gets what.
2. Money: none (like `SwapCounterPlugin`, `maxPotBps = 0`) or a pot share spent through intents (like
   `BuyBurnPlugin`). Default: **no surcharge** (`maxSurchargeBps = 0`).
3. Identity: `ctx.hint != 0 ? ctx.hint : ctx.origin`; sells never change a player's state.
4. Launch parameters (decoded from `initData` in `_onLaunch`), their bounds and defaults.
5. Anti-abuse: show that buy → win → sell farming loses money (fees on both legs).
6. Randomness: not available; out of scope.

## Phase 1 — contract

- Copy `src/MyPlugin.sol` (or the closer example) to `src/<Name>Plugin.sol`, rename the contract and the
  `<Name>Declaration` library, register the name in `script/Manifest.s.sol` (`_deployLocal`, `_declaration`).
- Inherit `HookPluginBase`; constructor takes only the ModuleRegistry address. `_auth(ctx.poolId)` first in every
  callback; state keyed by `(msg.sender, ctx.poolId)`.
- Swap callbacks O(1): no loops over users / rounds, no external calls, no PoolManager or hook C calls; clamp and
  saturate instead of reverting; `FullMath.mulDiv` for products.
- Spend only through intents (and rebates if declared), total ≤ `ctx.available`, count ≤ declared `maxIntents`.
  To keep money for later claims, return one `PAY` to `address(this)` and keep your own ledger with a conservation
  invariant; pay out pull-based (`claim`) so it works after a halt.
- Declaration: one cap bit per overridden callback and per intent kind; `hookApiMask = HookitInk.HOOK_API_MASK`;
  family groups (bit 0 F1 swap rules, 1 F2 pot share, 2 F3 supply/liquidity); forbid NFT_STRATEGY (bit 11) when
  pot-funded.

## Phase 2 — tests

- `test/<Name>Plugin.t.sol` inherits `PluginHarness` (`_deployPlugin`, `_manifest`; override `_initData`, `_potBps`,
  `_afterEachCall` for invariants). Add a unit test per rule and bound, fuzz tests for money paths (payouts ≤
  funding), and a test that bad launch parameters fail the launch.
- `forge test`, then `forge test --match-test test_conformance_gasReport -vv`; declare ≥ 2× each measured value.
- Live fork: add a `LiveInkForkHarness` subclass in `test/fork/` and run
  `INK_RPC_URL=https://rpc-gel.inkonchain.com forge test --match-path 'test/fork/*' -vv`.
- `forge fmt`.

## Phase 3 — deploy (human), manifest, submit

1. Give the human the `forge create ... --constructor-args 0x91f1622D49a09Ce2904E8f98650393eB3dAA2470 --rpc-url
   https://rpc-gel.inkonchain.com --account <name> --broadcast` command and the `forge verify-contract ...
   --verifier blockscout --verifier-url https://explorer.inkonchain.com/api/` command (`AGENTS.md` §3).
2. After deployment: `forge script script/Manifest.s.sol --sig "run(string,address)" <name> <address> --rpc-url
   https://rpc-gel.inkonchain.com` → `manifests/<name>.json`. It must print no codehash warning.
3. Tell the human to submit at https://hookit.fun/workshop/submit (four steps: what it runs on, the manifest file and
   the public repo at the deployed commit, name, tagline, description and logo, then one signature from the deploying
   wallet), with the `forge test` summary, the gas report and the fork run output kept in the repo for the reviewer.

## Hand-off report

List: files, parameters and defaults, measured gas vs declared, test results (state plainly which failures were test
bugs vs plugin bugs), the deployed address and codehash if deployed, and what is not done (no audit, owner review
pending). Do not say the plugin is live until `ModuleRegistry.moduleEntry(id)` on Ink shows it.
