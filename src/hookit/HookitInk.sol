// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title HookitInk
/// @notice Live Hookit v2 (option C) addresses on Ink mainnet (chain 57073), for plugin authors.
/// @dev Your plugin's constructor takes `MODULE_REGISTRY`: HookPluginBase stores it as an immutable, so it is part of
///      the runtime bytecode and therefore of the codehash the owner pins at registration. Deploy with exactly this
///      address, or the plugin cannot authenticate hook C on Ink.
library HookitInk {
    uint256 internal constant CHAIN_ID = 57073;
    address internal constant MODULE_REGISTRY = 0x91f1622D49a09Ce2904E8f98650393eB3dAA2470;
    address internal constant HOOK_C = 0x4b533C432516FC1Be4b0bAEFe6BFF0942AD87FfF;
    address internal constant FACTORY_C = 0x145c3F3560c23fDA93eA79f2EfeB7f33D8A9Ff3e;
    address internal constant POOL_MANAGER = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;

    /// @notice `hookApiMask` for `addModule`: bit v set for every hook API version the plugin supports. Hook C reports
    ///         `apiVersion() == 1`, the only version registered in the HookRegistry today, so the value is `1 << 1`
    ///         (= 2). The registry rejects 0 and any bit the HookRegistry's `apiVersionMask()` does not have.
    uint64 internal constant HOOK_API_MASK = 1 << 1;

    string internal constant WORKSHOP_URL = "https://hookit.fun/workshop";
}
