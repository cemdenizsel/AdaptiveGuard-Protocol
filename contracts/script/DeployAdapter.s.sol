// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/MezoIntegrationAdapter.sol";

/**
 * @notice Deploys a fresh MezoIntegrationAdapter and wires it to the live Mezo contracts.
 *
 * Required env vars:
 *   DEPLOYER_KEY              — deployer private key
 *   DAO_ADDRESS               — governance address
 *   ENGINE_ADDRESS            — already-deployed AdaptiveMCREngine
 *
 * Mezo testnet contracts (pre-filled):
 *   MEZO_TROVE_MANAGER, MEZO_BORROWER_OPERATIONS, STABILITY_POOL_ADDRESS,
 *   MEZO_HINT_HELPERS, MEZO_SORTED_TROVES, MEZO_PRICE_FEED
 */
contract DeployAdapter is Script {
    function run() external {
        uint256 deployerKey  = vm.envUint("DEPLOYER_KEY");
        address dao          = vm.envOr("DAO_ADDRESS",    address(0));
        address engine       = vm.envOr("ENGINE_ADDRESS", address(0));

        address troveManager  = vm.envOr("MEZO_TROVE_MANAGER",    address(0));
        address stabilityPool = vm.envOr("STABILITY_POOL_ADDRESS", address(0));
        address hintHelpers   = vm.envOr("MEZO_HINT_HELPERS",      address(0));
        address sortedTroves  = vm.envOr("MEZO_SORTED_TROVES",     address(0));
        address priceFeed     = vm.envOr("MEZO_PRICE_FEED",        address(0));

        if (dao == address(0)) dao = vm.addr(deployerKey);

        vm.startBroadcast(deployerKey);

        // Deploy in simulated mode (address(0) for mezoCDP) — live contracts wired via setMezoContracts
        MezoIntegrationAdapter adapter = new MezoIntegrationAdapter(
            engine,
            address(0), // simulated = true, but live reads use troveManager when set
            dao
        );

        // Wire live Mezo contracts
        if (troveManager != address(0)) {
            adapter.setMezoContracts(
                troveManager,
                stabilityPool,
                hintHelpers,
                sortedTroves,
                priceFeed
            );
        }

        // Set current BTC price (77k, 1e18 precision) — EGARCH service updates this each cycle
        adapter.setSimulatedBTCPrice(77_000e18);

        vm.stopBroadcast();

        console.log("=== MezoIntegrationAdapter Redeployed ===");
        console.log("Adapter      :", address(adapter));
        console.log("Engine       :", engine);
        console.log("TroveManager :", troveManager);
        console.log("StabilityPool:", stabilityPool);
        console.log("isLive()     :", adapter.isLive());
    }
}
