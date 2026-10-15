# AGENTS.md — instructions for the AI agent building a Hookit plugin

You are helping a developer write a **plugin for Hookit** (hookit.fun), a Uniswap v4 launchpad on **Ink (chain
57073)**. A plugin is a small, separate contract that Hookit's hook ("hook C") calls during the swaps, liquidity
changes and donations of the coins whose creators chose it. The developer writes and deploys it; the Hookit owner
reviews it and registers it in the `ModuleRegistry`; creators can then pick it in the launch form. Nothing in Hookit
is redeployed for a new plugin.

This folder is self-contained. Read, in order: this file, `src/hookit/IHookPlugin.sol` (the exact interface),
`src/examples/SwapCounterPlugin.sol` (no money), `src/examples/BuyBurnPlugin.sol` (moves money safely),
`src/MyPlugin.sol` (the starter), `MANIFEST.md` (what is submitted).

## 1. How a plugin works

- **Hook points.** 0 `onLaunch` (once per pool) · 1-2 initialize · 3-4 add liquidity · 5-6 remove liquidity ·
  7-8 swap (before / after) · 9-10 donate. The plugin subscribes to a point by setting its capability bit in `caps`
  and overriding the callback. Hook C never calls a point that is not subscribed.
- **Exact gas.** Hook C calls each callback with **exactly the gas declared for that point** in the manifest. A
  callback that reverts, runs out of gas or returns malformed data **reverts the user's swap** (fail-closed): every
  buy and sell of every coin using the plugin is frozen until the owner halts it. Removals (points 5-6) are the
  exception: a faulty remove callback is skipped.
- **Money.** A plugin never holds hook money directly. The creator can route a share of the hook-tax pot to it
  (`potBps`, bounded by your `maxPotBps`); hook C credits that share to the plugin's slot as an **allotment**, shown
  to every callback as `ctx.available`. The plugin spends it only by returning **intents** that hook C executes:
  1 PAY(to, amount), 2 BURN, 3 DEEPEN (liquidity), 4 FUND_FLOOR, 5 FUND_AIRDROP, 6 CREDIT_CREATOR — each needs its
  capability bit (kind k = bit k-1). Rebates to the swapper need the delta capabilities (bits 28-31).
- **Identity.** `msg.sender` is hook C. The trader is `ctx.hint` (first 32 bytes of hookData, set by routers) if
  non-zero, else `ctx.origin`. Both are untrusted: never let a **sell** change anyone's state (a seller can name
  anyone in hookData).
- **Halt.** The owner can halt a plugin at any time; from the next transaction hook C stops calling it and gives its
  allotment to the coin's other destinations. Anything users are owed by your plugin must stay claimable without
  any hook callback.

## 2. Hard rules (the owner's review checklist, §9.3, in plain terms)

A plugin that breaks any of these is rejected. The harness in `test/harness/` checks the ones marked (H).

1. **Never revert on valid input** (H). Clamp, saturate or return early instead. Check every arithmetic path with
   1e27-wei token supplies and 6/8/18-decimal quotes; use `FullMath.mulDiv` for products. Reverting in `onLaunch`
   on bad creator parameters is fine (it fails the launch, not trading).
2. **No calls to the PoolManager or to hook C** from any callback. No external call at all in swap callbacks unless
   to an immutable, non-reverting contract you control and document.
3. **Bounded gas** (H): no unbounded loop (no loop over users, rounds or positions); storage growth bounded per
   call; no `gasleft()`-dependent logic; no try/catch that changes behaviour on out-of-gas.
4. **Declared gas ≥ 2× the measured worst case** at every point, cold storage included (H). Declarations above
   250,000 must be justified. Declared `maxIntents` = the maximum the code can return per point.
5. **Exact return shapes** (H): points 1-2 return nothing; 3, 5, 9 `(uint8 guard, uint16 reason)`; 7 the 5-field
   `BeforeSwapResult`; 4, 6, 8, 10 `(uint256, Intent[])` with at most the declared number of intents; `to == 0` for
   intent kinds 2-6; PAY never to hook C or the PoolManager; point 10's first value is 0; point 5's guard is 0.
6. **Within the allotment** (H): `rebate (or lpRebate / lpReward) + Σ intent amounts <= ctx.available`, always.
7. **Guards only with capabilities** (H): blocking a buy, add or donate needs `CAP_GUARD`; blocking or capping a
   **sell** needs `CAP_SELL_GUARD_ANTIMEV` and is only accepted as a time-bounded or size-only anti-MEV rule; a
   surcharge needs `CAP_FEE_SURCHARGE` and stays ≤ `maxSurchargeBps`; an after-swap rebate only when
   `ctx.quoteIsUnspecified`.
8. **Authentication** (H): inherit `HookPluginBase`; call `_auth(ctx.poolId)` first in every callback; key all state
   by `(msg.sender, ctx.poolId)` (hook, pool). Never trust `msg.sender` as a user.
9. **No privileges**: no owner, admin, pause that reverts, upgrade, proxy, `DELEGATECALL`, `SELFDESTRUCT`,
   approvals, or randomness. A pause, if any, must make callbacks return "allow, 0, no intents", never revert.
10. **Halt-safe**: users can withdraw anything the plugin holds for them without a hook callback; a promise funded
    from the allotment is never presented as guaranteed.
11. **Not farmable**: a rebate or reward must cost more to farm (wash trades pay the fee on both legs, ~2 %+) than
    it pays; liquidity rewards are time-weighted (no same-block add/remove profit).
12. **Liquidity / donate callbacks** handle extreme inputs (full range, single tick, `liquidityDelta` near the int128
    limits, zero-delta pokes, dust and huge donations) (H).
13. **Compatibility declared honestly**: family groups (bit 0 F1 swap rules, 1 F2 pot share, 2 F3 supply/liquidity,
    3 F4 exclusive), forbidden built-ins (a pot-funded plugin forbids NFT_STRATEGY), known incompatible modules.
14. **Default: no surcharge** (`maxSurchargeBps = 0`): a declared surcharge is reserved in the 10 % fee cap of every
    coin that uses the plugin and lowers its creator's maximum hook tax.
15. **Builder cut ≤ 20 %**: the builder may pay themselves a share of what the plugin spends, as a `PAY` intent to a
    `constant` (or immutable) address set at deployment, at most **20 %** (`2_000` bps) of each spend, computed
    with `FullMath.mulDiv` and rounding down. It comes out of the plugin's allotment (never a surcharge on top), is
    paid as ERC-6909 quote claims on the PoolManager, and needs `CAP_PAY`, the F3 group bit and one more
    `maxIntents` at point 8. The Workshop studio generates exactly this pattern when a payout wallet is set.

## 3. Workflow

```sh
./setup.sh                                   # 1. dependencies into ./lib (v4-core v4.0.0, forge-std)
forge build && forge test                    # 2. everything green before you start
```

3. **Write.** Rename `src/MyPlugin.sol` (contract + `MyPluginDeclaration` library) and `test/MyPlugin.t.sol`, and
   add the name to `script/Manifest.s.sol` (`_deployLocal`, `_declaration`). Start from the example closest to the
   mechanic. Keep the declaration in sync with the code: `caps` bit per overridden callback and per intent kind.
4. **Test.** `forge test`. The test contract inherits `PluginHarness`: it gets the whole conformance suite. Add one
   unit test per rule of the mechanic, fuzz tests for the money paths (payouts ≤ funding), and override
   `_initData`, `_potBps`, `_afterEachCall` (ledger invariants) as needed. Never weaken the harness to get green:
   a harness failure is a real hook C failure.
5. **Measure gas.** `forge test --match-test test_conformance_gasReport -vv` prints, per point, the measured cold
   worst case and the declaration; declare at least 2×, rounded up. Then rerun everything.
6. **Live fork test.** `INK_RPC_URL=https://rpc-gel.inkonchain.com forge test --match-path 'test/fork/*' -vv`:
   the plugin is registered (admin pranked, fork only) and traded on the real hook C with the exact declared gas.
   Copy `test/fork/ExamplesLiveInk.t.sol`'s `MyPluginLiveInkTest` for the renamed plugin.
7. **Format.** `forge fmt`.
8. **Deploy on Ink — the developer does this, with their own wallet.** The agent prepares the command and the human
   runs it. Keyless rules: never ask for, paste, print, log or store a private key or seed phrase; never put a key on
   a command line or in a file; never run a broadcasting command yourself unless the human explicitly asks you to
   in this conversation. The wallet is imported once, interactively, by the human:
   ```sh
   cast wallet import plugin-dev --interactive        # human types the key; stored encrypted in ~/.foundry/keystores
   forge create src/MyPlugin.sol:MyPlugin \
     --constructor-args 0x91f1622D49a09Ce2904E8f98650393eB3dAA2470 \
     --rpc-url https://rpc-gel.inkonchain.com --account plugin-dev --broadcast
   ```
   The constructor argument must be the live ModuleRegistry (`HookitInk.MODULE_REGISTRY`): it is baked into the
   runtime code and the codehash. Then verify the source on the Ink explorer (Blockscout):
   ```sh
   forge verify-contract <address> src/MyPlugin.sol:MyPlugin --chain 57073 \
     --constructor-args $(cast abi-encode "f(address)" 0x91f1622D49a09Ce2904E8f98650393eB3dAA2470) \
     --verifier blockscout --verifier-url https://explorer.inkonchain.com/api/
   ```
9. **Manifest.** `forge script script/Manifest.s.sol --sig "run(string,address)" my-plugin <address> --rpc-url
   https://rpc-gel.inkonchain.com` — reads the deployed code, re-runs every registry check, writes
   `manifests/my-plugin.json`. It never broadcasts.
10. **Submit** at https://hookit.fun/workshop/submit, in four steps: what it runs on (the trades, the pot or both),
    the manifest file and the public repo at the exact deployed commit, a name, a one-line tagline, a description
    (the mechanic, what it costs traders, what it can never do) and an optional logo, then one message signed by the
    wallet that deployed it (nothing moves on chain). Keep the test output (`forge test` summary, gas report, fork
    run) in the repo for the reviewer. The owner reviews (§9.3), may ask for changes (a change = a new deployment and
    a new manifest), then registers it. Walkthrough and agent briefs: https://hookit.fun/workshop/build.

## 4. What not to do

- Do not edit `src/hookit/*` (vendored from the Hookit monorepo; hook C uses exactly this ABI) or weaken
  `test/harness/*`.
- Do not use `msg.sender` as the trader, `block.timestamp` randomness, or any oracle that can revert.
- Do not deploy a proxy, and do not keep an admin key "just in case".
- Do not claim the plugin is registered or live until the owner has registered it: check
  `ModuleRegistry.moduleEntry(id)` on Ink.
