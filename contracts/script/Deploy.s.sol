// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import "../src/VolatilityOracle.sol";
import "../src/AdaptiveMCREngine.sol";
import "../src/MezoIntegrationAdapter.sol";

/**
 * @title Deploy
 * @notice Deploys the full AdaptiveGuard Protocol stack.
 *
 * Usage:
 *   # Anvil local:
 *   forge script script/Deploy.s.sol --rpc-url anvil --broadcast
 *
 *   # Mezo testnet:
 *   forge script script/Deploy.s.sol --rpc-url mezo_testnet \
 *       --broadcast --verify --private-key $DEPLOYER_KEY
 *
 * Required env vars:
 *   DEPLOYER_KEY   — deployer private key (0x-prefixed)
 *   DAO_ADDRESS    — multi-sig or EOA that holds governance roles
 *   INIT_VOL_BPS   — initial volatility estimate in BPS (e.g. 4500 = 45%)
 *
 * Optional (set address(0) to deploy in simulated mode):
 *   MEZO_CDP_ADDRESS — live Mezo CDP contract on testnet
 */
contract Deploy is Script {

    function run() external {
        uint256 deployerKey = vm.envUint("DEPLOYER_KEY");
        address dao         = vm.envOr("DAO_ADDRESS",  address(0));
        uint256 initVolBPS  = vm.envOr("INIT_VOL_BPS", uint256(4500));
        address mezoCDP     = vm.envOr("MEZO_CDP_ADDRESS", address(0));

        // If no DAO address configured, use deployer
        if (dao == address(0)) {
            dao = vm.addr(deployerKey);
        }

        vm.startBroadcast(deployerKey);

        // ── 1. VolatilityOracle ───────────────────────────────────────────────
        VolatilityOracle oracle = new VolatilityOracle(dao, initVolBPS);

        // ── 2. AdaptiveMCREngine ──────────────────────────────────────────────
        AdaptiveMCREngine engine = new AdaptiveMCREngine(address(oracle), dao);

        // ── 3. MezoIntegrationAdapter (simulated if no CDP address) ──────────
        MezoIntegrationAdapter adapter = new MezoIntegrationAdapter(
            address(engine),
            mezoCDP,   // address(0) → simulated mode for hackathon demo
            dao
        );

        // ── 4. Grant oracle UPDATER_ROLE to deployer (off-chain service) ─────
        //       In production, rotate to a dedicated service key.
        oracle.grantRole(oracle.UPDATER_ROLE(), vm.addr(deployerKey));

        // ── 5. Grant engine PROPOSER_ROLE to deployer (off-chain service) ────
        engine.addProposer(vm.addr(deployerKey));

        vm.stopBroadcast();

        // ── Print deployment summary ──────────────────────────────────────────
        console.log("=== AdaptiveGuard Protocol Deployed ===");
        console.log("DAO              :", dao);
        console.log("VolatilityOracle :", address(oracle));
        console.log("AdaptiveMCREngine:", address(engine));
        console.log("MezoAdapter      :", address(adapter));
        console.log("Simulated mode   :", adapter.isSimulated());
        console.log("Initial vol (BPS):", initVolBPS);
    }
}
