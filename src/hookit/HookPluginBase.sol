// SPDX-License-Identifier: MIT
// Vendored from the Hookit monorepo: src/plugins/HookPluginBase.sol (only the IHookPlugin import path differs).
// Upstream: the hookit monorepo
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {IHookPlugin} from "./IHookPlugin.sol";

interface IModuleRegistryHooks {
    function hookRegistry() external view returns (IRegisteredHooks);
}

interface IRegisteredHooks {
    function isRegisteredHook(address hook) external view returns (bool);
}

/// @title HookPluginBase
/// @notice Base for hook C plugins (spec/v2/ARCHITECTURE.md §4.2), moved from test/ to src/plugins/ with the first production
///         module (FloorLoanPlugin); `test/c/plugins/HookPluginBase.sol` re-exports it.
///         S3 delivers the parts the registry and D11 depend on:
///         - `hookitPluginApi() == 3` (checked by ModuleRegistry.addModule);
///         - `predecessor()`: an immutable, `address(0)` for an original version, so any plugin built on this base
///           can later be used as a successor without an ABI change (R26, §4.2 IHookPluginSuccessor);
///         - `migrate(bytes)`: callable only by the ModuleRegistry the plugin was built for, at most once; the default
///           implementation reverts `NotSupported()` (then `migrateSuccessor` reverts too);
///         - the D11 custody accumulator: quote that a custody account receives as a holder (HolderAirdropVault
///           epochs, manual `airdrop()`, raffle prizes, ...) is credited pro rata to the users whose launch tokens it
///           holds, synced permissionlessly by `syncAirdrops`, and claimable without any hook callback (works after
///           a halt); `custodyBalanceOf` lets indexers attribute custody balances to their owners (§13 P5).
///         S5 part (§4.2 "normative for every registered plugin"): every IHookPlugin callback as a no-op returning the
///         empty result, `onLaunch` authenticated with `HookRegistry.isRegisteredHook(msg.sender)` (the registry is
///         read through the ModuleRegistry's immutable `hookRegistry()`), `address(ctx.key.hooks) == msg.sender`,
///         `poolId == keccak256(abi.encode(key))`, one-shot per (hook, poolId); every other callback authenticated
///         without an external call by `initialized[msg.sender][poolId]`; state keyed by (hook, poolId).
/// @dev The accumulator never trusts balances alone: the concrete plugin reports `_custodyAssets(account)`, the quote
///      currently held for `account` EXCLUDING amounts the plugin booked itself (PAY intents it emitted, its own
///      transfers). Cumulative inflow = assets + everything already paid out from that account, so claims do not look
///      like new airdrops. Inflow is monotone by construction; a decrease (e.g. a rebasing or fee-charging quote) is
///      never "un-credited" and never re-credited: `observed` only moves up.
///      Rounding: each sync credits `inc = floor(amount * 1e36 / shares)` per share and keeps the part not
///      represented, `amount - ceil(inc * shares / 1e36)`, as `unallocated` for the next sync, so the sum of what
///      users can claim never exceeds what the account received (solvency); the only loss is the per-user floor
///      at settlement (< 1 wei per settlement).
///      Every state-changing entry point is guarded by a transient-storage lock, so an ERC-777-style quote or an ETH
///      recipient cannot re-enter between the bookkeeping and the payment.
abstract contract HookPluginBase is IHookPlugin {
    uint16 internal constant PLUGIN_API = 3;
    uint256 internal constant ACC_PRECISION = 1e36;
    /// @dev transient-storage lock slot: keccak256("hookit.pluginbase.lock") - 1
    uint256 private constant LOCK_SLOT = 0xbc4acb7908da6e1f0ac63a4493a8b3a2d006eecff1b89a18e2db721a439e02b5;

    address private immutable PREDECESSOR;
    address public immutable moduleRegistry;

    bool public migrated;

    struct CustodyAccount {
        uint256 totalShares; // launch-token units held for users at this account
        uint256 accPerShare; // cumulative quote per share, scaled by 1e36
        uint256 observed; // cumulative inflow already accounted for
        uint256 unallocated; // inflow not yet represented in accPerShare (no shares, or rounding remainder)
        uint256 paid; // cumulative quote paid out to users from this account
    }

    struct CustodyUser {
        uint256 shares;
        uint256 accSnap;
        uint256 owed;
    }

    mapping(address account => CustodyAccount) internal _custody;
    mapping(address account => mapping(address user => CustodyUser)) internal _custodyUser;

    event CustodyDeposited(address indexed account, address indexed user, uint256 amount);
    event CustodyWithdrawn(address indexed account, address indexed user, uint256 amount);
    event CustodyAirdropSynced(address indexed account, uint256 inflow, uint256 credited);
    event CustodyAirdropClaimed(address indexed account, address indexed user, address to, uint256 amount);

    error NotModuleRegistry();
    error AlreadyMigrated();
    error NotSupported();
    error Reentrant();
    error InsufficientCustody();
    error NotRegisteredHook();
    error ForgedContext();
    error AlreadyLaunched();
    error NotInitialized();

    /// @notice (hook, poolId) pairs this plugin was launched on by a registered hook (§4.2).
    mapping(address hook => mapping(PoolId => bool)) public initialized;

    modifier nonReentrant() {
        uint256 slot = LOCK_SLOT;
        bool locked;
        assembly ("memory-safe") {
            locked := tload(slot)
        }
        if (locked) revert Reentrant();
        assembly ("memory-safe") {
            tstore(slot, 1)
        }
        _;
        assembly ("memory-safe") {
            tstore(slot, 0)
        }
    }

    constructor(address predecessor_, address moduleRegistry_) {
        PREDECESSOR = predecessor_;
        moduleRegistry = moduleRegistry_;
    }

    // ================================================================== registry-facing

    /// @notice Plugin API version (ModuleRegistry.addModule STATICCALLs it; MUST be 3).
    function hookitPluginApi() external pure override returns (uint16) {
        return PLUGIN_API;
    }

    /// @notice The plugin whose state this version continues; `address(0)` for an original version (R26).
    function predecessor() external view returns (address) {
        return PREDECESSOR;
    }

    /// @notice One-time migration, only through `ModuleRegistry.migrateSuccessor` (admin = the cold EOA).
    function migrate(bytes calldata data) external nonReentrant {
        if (msg.sender != moduleRegistry) revert NotModuleRegistry();
        if (migrated) revert AlreadyMigrated();
        migrated = true;
        _migrate(data);
    }

    /// @dev Override to migrate plugin-global state. MUST NOT call the PoolManager or hook C.
    function _migrate(bytes calldata) internal virtual {
        revert NotSupported();
    }

    // ================================================================== D11 custody accumulator: views

    /// @notice Launch tokens held for `user` at the plugin's own address (one C token per custody account, D11).
    function custodyBalanceOf(address user) external view returns (uint256) {
        return _custodyUser[address(this)][user].shares;
    }

    /// @notice Launch tokens held for `user` at custody account `account`.
    function custodyBalanceOf(address account, address user) external view returns (uint256) {
        return _custodyUser[account][user].shares;
    }

    function custodyTotal(address account) external view returns (uint256) {
        return _custody[account].totalShares;
    }

    function custodyAccountState(address account) external view returns (CustodyAccount memory) {
        return _custody[account];
    }

    /// @notice Quote `user` could claim from `account` now, including inflow not yet synced.
    function pendingCustodyAirdrop(address account, address user) external view returns (uint256) {
        CustodyAccount storage a = _custody[account];
        (uint256 acc,,) = _preview(a, _inflow(account, a));
        CustodyUser storage u = _custodyUser[account][user];
        return u.owed + FullMath.mulDiv(u.shares, acc - u.accSnap, ACC_PRECISION);
    }

    /// @notice Inflow of `account` not represented in any user's claim yet (no holders, or rounding remainder),
    ///         including inflow not yet synced.
    function unallocatedCustodyAirdrop(address account) external view returns (uint256 unallocated) {
        CustodyAccount storage a = _custody[account];
        (, unallocated,) = _preview(a, _inflow(account, a));
    }

    // ================================================================== D11 custody accumulator: entry points

    /// @notice Permissionless: credit every quote amount `account` received since the last sync to its holders.
    function syncAirdrops(address account) external nonReentrant {
        _sync(account);
    }

    /// @notice Claim the caller's custody airdrops from `account` to `to`. Needs no hook callback.
    function claimCustodyAirdrop(address account, address to) external nonReentrant returns (uint256 amount) {
        _sync(account);
        CustodyUser storage u = _settle(account, msg.sender);
        amount = u.owed;
        if (amount == 0) return 0;
        u.owed = 0;
        _custody[account].paid += amount;
        emit CustodyAirdropClaimed(account, msg.sender, to, amount);
        _payCustody(account, to, amount);
    }

    // ================================================================== D11 custody accumulator: for the plugin

    /// @dev Call when `amount` of `user`'s launch tokens start being held at `account` (stake). Syncs first, so
    ///      airdrops received before the deposit go to the previous holders only.
    function _custodyDeposit(address account, address user, uint256 amount) internal {
        _sync(account);
        CustodyUser storage u = _settle(account, user);
        u.shares += amount;
        _custody[account].totalShares += amount;
        emit CustodyDeposited(account, user, amount);
    }

    /// @dev Call when `amount` of `user`'s launch tokens leave `account` (unstake). What the user earned stays owed.
    function _custodyWithdraw(address account, address user, uint256 amount) internal {
        _sync(account);
        CustodyUser storage u = _settle(account, user);
        if (amount > u.shares) revert InsufficientCustody();
        unchecked {
            u.shares -= amount;
            _custody[account].totalShares -= amount;
        }
        emit CustodyWithdrawn(account, user, amount);
    }

    /// @dev Quote currently held for `account`, excluding amounts the plugin booked itself.
    function _custodyAssets(address account) internal view virtual returns (uint256);

    /// @dev Pay `amount` of `account`'s quote to `to` (ERC-6909 claims via `poolManager.transfer`, or raw quote after
    ///      the plugin's own out-of-swap redemption). MUST reduce `_custodyAssets(account)` by exactly `amount`.
    function _payCustody(address account, address to, uint256 amount) internal virtual;

    // ================================================================== internals

    function _inflow(address account, CustodyAccount storage a) internal view returns (uint256) {
        return _custodyAssets(account) + a.paid;
    }

    function _preview(CustodyAccount storage a, uint256 inflow)
        internal
        view
        returns (uint256 acc, uint256 unallocated, uint256 credited)
    {
        acc = a.accPerShare;
        uint256 prev = a.observed;
        unallocated = a.unallocated + (inflow > prev ? inflow - prev : 0);
        uint256 shares = a.totalShares;
        if (shares == 0 || unallocated == 0) return (acc, unallocated, 0);
        uint256 inc = FullMath.mulDiv(unallocated, ACC_PRECISION, shares);
        if (inc == 0) return (acc, unallocated, 0);
        credited = FullMath.mulDivRoundingUp(inc, shares, ACC_PRECISION);
        acc += inc;
        unallocated -= credited;
    }

    function _sync(address account) internal {
        CustodyAccount storage a = _custody[account];
        uint256 inflow = _inflow(account, a);
        (uint256 acc, uint256 unallocated, uint256 credited) = _preview(a, inflow);
        if (inflow > a.observed) a.observed = inflow;
        a.accPerShare = acc;
        a.unallocated = unallocated;
        if (credited != 0) emit CustodyAirdropSynced(account, inflow, credited);
    }

    function _settle(address account, address user) internal returns (CustodyUser storage u) {
        u = _custodyUser[account][user];
        uint256 acc = _custody[account].accPerShare;
        uint256 snap = u.accSnap;
        if (acc != snap) {
            u.owed += FullMath.mulDiv(u.shares, acc - snap, ACC_PRECISION);
            u.accSnap = acc;
        }
    }

    // ================================================================== IHookPlugin (S5 reference behaviour)

    /// @notice Point 0: authenticate a registered hook, reject a forged context, one-shot per (hook, poolId).
    function onLaunch(LaunchCtx calldata ctx, bytes calldata initData)
        external
        override
        returns (address[] memory custody)
    {
        if (!IModuleRegistryHooks(moduleRegistry).hookRegistry().isRegisteredHook(msg.sender)) {
            revert NotRegisteredHook();
        }
        if (address(ctx.key.hooks) != msg.sender || PoolId.unwrap(ctx.poolId) != keccak256(abi.encode(ctx.key))) {
            revert ForgedContext();
        }
        if (initialized[msg.sender][ctx.poolId]) revert AlreadyLaunched();
        initialized[msg.sender][ctx.poolId] = true;
        return _onLaunch(ctx, initData);
    }

    /// @dev Override for per-pool setup; returns the custody accounts (<= 3, D11).
    function _onLaunch(LaunchCtx calldata, bytes calldata) internal virtual returns (address[] memory custody) {}

    /// @dev Originals: `initialized[msg.sender][poolId]` (set by an authenticated `onLaunch`), no external call.
    ///      Successors (§4.2 "No onLaunch for existing pools"): an inherited pool never calls `onLaunch`, so a
    ///      successor also accepts a caller that the HookRegistry lists as a registered hook (one STATICCALL through
    ///      the ModuleRegistry's immutable `hookRegistry()`, counted in the declared gas; not cached here, which would
    ///      cost an SSTORE per (hook, pool) inside a callback). State stays keyed by (hook, poolId), so another
    ///      registered hook still reaches only its own entries.
    function _auth(PoolId id) internal view {
        if (initialized[msg.sender][id]) return;
        if (
            PREDECESSOR == address(0)
                || !IModuleRegistryHooks(moduleRegistry).hookRegistry().isRegisteredHook(msg.sender)
        ) revert NotInitialized();
    }

    function beforeInitializePlugin(InitCtx calldata ctx) external virtual override {
        _auth(ctx.poolId);
    }

    function afterInitializePlugin(InitCtx calldata ctx) external virtual override {
        _auth(ctx.poolId);
    }

    function beforeAddLiquidityPlugin(LiquidityCtx calldata ctx) external virtual override returns (uint8, uint16) {
        _auth(ctx.poolId);
        return (0, 0);
    }

    function afterAddLiquidityPlugin(AfterLiquidityCtx calldata ctx)
        external
        virtual
        override
        returns (uint256, Intent[] memory)
    {
        _auth(ctx.poolId);
        return (0, new Intent[](0));
    }

    function beforeRemoveLiquidityPlugin(LiquidityCtx calldata ctx) external virtual override returns (uint8, uint16) {
        _auth(ctx.poolId);
        return (0, 0);
    }

    function afterRemoveLiquidityPlugin(AfterLiquidityCtx calldata ctx)
        external
        virtual
        override
        returns (uint256, Intent[] memory)
    {
        _auth(ctx.poolId);
        return (0, new Intent[](0));
    }

    function beforeSwapPlugin(SwapCtx calldata ctx) external virtual override returns (BeforeSwapResult memory r) {
        _auth(ctx.poolId);
        return r;
    }

    function afterSwapPlugin(AfterSwapCtx calldata ctx) external virtual override returns (uint256, Intent[] memory) {
        _auth(ctx.poolId);
        return (0, new Intent[](0));
    }

    function beforeDonatePlugin(DonateCtx calldata ctx) external virtual override returns (uint8, uint16) {
        _auth(ctx.poolId);
        return (0, 0);
    }

    function afterDonatePlugin(DonateCtx calldata ctx) external virtual override returns (uint256, Intent[] memory) {
        _auth(ctx.poolId);
        return (0, new Intent[](0));
    }
}
