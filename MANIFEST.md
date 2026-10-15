# Plugin manifest (Workshop submission) — schema `hookit.plugin-manifest/v1`

The manifest is what you paste or upload in the Hookit Workshop (https://hookit.fun/workshop/submit). It carries **exactly the
arguments of `ModuleRegistry.addModule`** on Ink, minus `metadataHash` (the owner computes it from the review record),
plus display fields and the runtime codehash the owner pins. The owner registers your plugin from it unchanged.

Generate it, never hand-write it:

```sh
# after deploying on Ink (this is the one you submit)
forge script script/Manifest.s.sol --sig "run(string,address)" my-plugin 0xYourPlugin --rpc-url ink
# before deploying (local build; the address is a simulation)
forge script script/Manifest.s.sol --sig "run(string)" my-plugin
```

Output: printed to the console and written to `manifests/<name>.json`. Samples: `examples/manifest.swap-counter.json`,
`examples/manifest.buy-burn.json`.

## The registry call it maps to

Source of truth: `src/c/registry/ModuleRegistry.sol` in the Hookit monorepo (selector `0x6399a102`).

```solidity
function addModule(
    address plugin,
    uint64 caps,
    uint64 hookApiMask,
    PluginLimitsDecl calldata limits,   // (uint32 launchGas, uint32[10] gas, uint8[4] maxIntents)
    uint16 maxPotBps,
    uint16 maxSurchargeBps,
    CompatDecl calldata compat,         // (uint32[] incompatibleWith, uint16 forbiddenBuiltins,
                                        //  uint64 groups, uint64 exclusiveGroups, uint64 conflictGroups)
    bytes32 metadataHash                // set by the owner, not in the manifest
) external returns (uint32 id);
```

## Fields

Encoding rules: `uint64` values are **decimal strings** (they can exceed 2^53, the JSON-number safe range); every
other number is a JSON number; hex is lowercase with `0x`; strings contain no `"`, `\` or control characters.

| Field | JSON type | addModule argument | Meaning / rule |
|---|---|---|---|
| `schema` | string | – | `"hookit.plugin-manifest/v1"` |
| `chainId` | number | – | `57073` (Ink) |
| `pluginApi` | number | – | `3`; the registry STATICCALLs `hookitPluginApi()` and requires 3 |
| `plugin` | string (address) | `plugin` | your deployed plugin; must have code |
| `name` | string | – | display name (catalogue) |
| `description` | string | – | one sentence; say whether it moves money |
| `caps` | string (uint64, decimal) | `caps` | capability bitmask (table below); unknown bits, bit 12 and broken dependencies revert |
| `capsHex` | string | – | the same value in hex (informational) |
| `capNames` | string[] | – | the names of the set bits (informational; must agree with `caps`) |
| `hookApiMask` | string (uint64, decimal) | `hookApiMask` | bit v = hook API version v supported. Use **`"2"`** (`1 << 1`): hook C is API v1, the only version registered on Ink (`HookRegistry.apiVersionMask() == 2`). 0 or an unregistered bit reverts |
| `limits.launchGas` | number | `limits.launchGas` | gas for `onLaunch` (point 0); 10,000 – 1,000,000 |
| `limits.gas` | number[10] | `limits.gas` | gas per hook point, index = point − 1; 10,000 – 1,000,000 at subscribed points, **0** elsewhere; ≥ 2× measured |
| `limits.maxIntents` | number[4] | `limits.maxIntents` | max intents returned at points **4, 6, 8, 10** (in that order); each ≤ 8; 0 at an unsubscribed point or without an intent capability (bits 0-5) |
| `maxPotBps` | number | `maxPotBps` | max share of the hook-tax pot a creator may route to the plugin; ≤ 10,000; 0 for a plugin that moves no money |
| `maxSurchargeBps` | number | `maxSurchargeBps` | max extra fee per swap (needs `CAP_FEE_SURCHARGE`); ≤ 900; **reserved in every coin's 10 % cap**, so keep 0 unless essential |
| `compat.incompatibleWith` | number[] | `compat.incompatibleWith` | registered module ids it must never share a pool with (must exist on chain, no duplicates) |
| `compat.forbiddenBuiltins` | number (uint16) | `compat.forbiddenBuiltins` | built-ins it must not run next to (table below); bits 12-15 revert |
| `compat.groups` | string (uint64) | `compat.groups` | group membership; bits 0-3 are the families and at least one is required by review: 0 F1 swap rules, 1 F2 fee redirection (pot share), 2 F3 supply / liquidity actions, 3 F4 exclusive strategies |
| `compat.exclusiveGroups` | string (uint64) | `compat.exclusiveGroups` | groups with at most one member per pool; must be ⊆ `groups` |
| `compat.conflictGroups` | string (uint64) | `compat.conflictGroups` | groups that may not appear in the same pool at all |
| `codehash` | string (bytes32) | – (pinned by the registry) | `keccak256` of the deployed runtime code; the registry stores `plugin.codehash` and re-checks it at every launch |
| `repo` | string | – | public source (exact commit + compiler settings) for the review |

### Hook points (index into `limits.gas`) and their capability bits

| Point | Callback | Cap bit | Point | Callback | Cap bit |
|---|---|---|---|---|---|
| 1 | beforeInitializePlugin | 24 | 6 | afterRemoveLiquidityPlugin | 23 |
| 2 | afterInitializePlugin | 25 | 7 | beforeSwapPlugin | 15 |
| 3 | beforeAddLiquidityPlugin | 20 | 8 | afterSwapPlugin | 16 |
| 4 | afterAddLiquidityPlugin | 21 | 9 | beforeDonatePlugin | 26 |
| 5 | beforeRemoveLiquidityPlugin | 22 | 10 | afterDonatePlugin | 27 |

### Capability bits (`caps`)

| Bit | Name | Bit | Name |
|---|---|---|---|
| 0 | CAP_PAY (intent kind 1) | 16 | CAP_AFTER_SWAP |
| 1 | CAP_BURN (kind 2) | 17 | CAP_GUARD (needs a before-point) |
| 2 | CAP_DEEPEN (kind 3) | 18 | CAP_SELL_GUARD_ANTIMEV (needs 15 + 17) |
| 3 | CAP_FUND_FLOOR (kind 4) | 19 | CAP_FEE_SURCHARGE (needs 15) |
| 4 | CAP_FUND_AIRDROP (kind 5) | 20-23 | CAP_BEFORE/AFTER_ADD/REMOVE_LIQUIDITY |
| 5 | CAP_CREDIT_CREATOR (kind 6) | 24-25 | CAP_BEFORE/AFTER_INITIALIZE |
| 6 | CAP_FLOOR_TOPUP | 26-27 | CAP_BEFORE/AFTER_DONATE |
| 7 | CAP_FLOOR_ESCROW | 28 | CAP_BEFORE_SWAP_DELTA (needs 15) |
| 8 | CAP_HOLDS_TOKEN | 29 | CAP_AFTER_SWAP_DELTA (needs 16) |
| 9 | REQ_BACKED_FLOOR | 30 | CAP_AFTER_ADD_LIQUIDITY_DELTA (needs 21) |
| 10 | REQ_HOLDER_AIRDROP | 31 | CAP_AFTER_REMOVE_LIQUIDITY_DELTA (needs 23) |
| 11 | REQ_SINGLE_MARKET | 12 | reserved (reverts) |
| 13 | REQ_HOLDER_LIST | 32-63 | unknown (revert) |
| 14 | CAP_REVENUE_IN | | |
| 15 | CAP_BEFORE_SWAP | | Intent caps (0-5) need at least one after-point (16, 21, 23, 27) |

### Built-ins (`compat.forbiddenBuiltins`)

0 ANTI_SNIPE · 1 BACKED_FLOOR · 2 ANTI_MEV · 3 MAX_TX · 4 HOOK_TO_CREATOR · 5 DYNAMIC_FEES · 6 BUYBACK_VESTING ·
7 AUTO_BURN · 8 DEEPEN_LPS · 9 HOLDER_AIRDROP · 10 CREATOR_SHARE_TO_HOOK · 11 NFT_STRATEGY · 12-15 reserved.
A plugin funded by a pot share should forbid NFT_STRATEGY (bit 11): NFT Strategy pools route no pot to plugins.

## Example (`examples/manifest.swap-counter.json`)

```json
{
  "schema": "hookit.plugin-manifest/v1",
  "chainId": 57073,
  "pluginApi": 3,
  "plugin": "0x5aadfb43ef8daf45dd80f4676345b7676f1d70e3",
  "name": "Swap Counter",
  "description": "Counts swaps and the hook fee per pool. Moves no money.",
  "caps": "65536",
  "capsHex": "0x0000000000010000",
  "capNames": ["CAP_AFTER_SWAP"],
  "hookApiMask": "2",
  "limits": {
    "launchGas": 100000,
    "gas": [0, 0, 0, 0, 0, 0, 0, 60000, 0, 0],
    "maxIntents": [0, 0, 0, 0]
  },
  "maxPotBps": 0,
  "maxSurchargeBps": 0,
  "compat": {
    "incompatibleWith": [],
    "forbiddenBuiltins": 0,
    "groups": "1",
    "exclusiveGroups": "0",
    "conflictGroups": "0"
  },
  "codehash": "0x…",
  "repo": "https://github.com/SDKHookit/SDKHookit"
}
```

(The sample's `plugin` is a local simulation address; the committed file has the exact codehash of this SDK build.)

## How the owner turns it into the transaction

The script also prints a `cast calldata` line for the owner:

```sh
cast calldata "addModule(address,uint64,uint64,(uint32,uint32[10],uint8[4]),uint16,uint16,(uint32[],uint16,uint64,uint64,uint64),bytes32)" \
  <plugin> <caps> <hookApiMask> "(<launchGas>,[<gas x10>],[<maxIntents x4>])" <maxPotBps> <maxSurchargeBps> \
  "([<incompatibleWith>],<forbiddenBuiltins>,<groups>,<exclusiveGroups>,<conflictGroups>)" $METADATA_HASH
```

Evidence that the mapping is exact: `test/Manifest.t.sol` (JSON → addModule calldata = declaration → calldata) and,
in the monorepo, `test/ForkInkWorkshopSdk.t.sol` (the JSON parsed back and accepted by the live ModuleRegistry on an
Ink fork, `moduleEntry(id)` equal to the manifest).
