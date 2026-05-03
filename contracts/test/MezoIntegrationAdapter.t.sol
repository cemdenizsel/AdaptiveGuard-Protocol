// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/MezoIntegrationAdapter.sol";
import "../src/AdaptiveMCREngine.sol";
import "../src/VolatilityOracle.sol";

contract MezoIntegrationAdapterTest is Test {

    MezoIntegrationAdapter adapter;
    AdaptiveMCREngine       engine;
    VolatilityOracle        oracle;

    address dao     = address(0xDA0);
    address alice   = address(0xA11CE);
    address bob     = address(0xB0B);
    address charlie = address(0xC4B1E);

    // 1 BTC = $30,000
    uint256 constant BTC_PRICE_18 = 30_000e18;
    // Open with 1 BTC ($30k) and borrow $25k MUSD → CR = 120%
    uint256 constant COLL_1BTC   = 1e18;
    uint256 constant DEBT_25K    = 25_000e18;

    function setUp() public {
        vm.warp(1_700_000_000);

        oracle  = new VolatilityOracle(dao, 2000); // low vol → MCR = 110%
        engine  = new AdaptiveMCREngine(address(oracle), dao);
        adapter = new MezoIntegrationAdapter(address(engine), address(0), dao);

        vm.startPrank(dao);
        oracle.grantRole(oracle.UPDATER_ROLE(), dao);
        engine.addProposer(dao);
        vm.stopPrank();

        // Set price
        vm.prank(dao);
        adapter.setSimulatedBTCPrice(BTC_PRICE_18);
    }

    // ─── Simulated mode ───────────────────────────────────────────────────────

    function test_IsSimulated() public view {
        assertTrue(adapter.isSimulated());
    }

    // ─── Open Trove ───────────────────────────────────────────────────────────

    function test_OpenTrove_Success() public {
        vm.prank(alice);
        adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);

        MezoIntegrationAdapter.SimulatedTrove memory t = adapter.getTrove(alice);
        assertTrue(t.active);
        assertEq(t.collateralBTC18, COLL_1BTC);
        assertEq(t.debtMUSD18, DEBT_25K);
    }

    function test_OpenTrove_FailsBelowMCR() public {
        // CR = $30k / $28k ≈ 107% — below 110% MCR
        vm.prank(alice);
        vm.expectRevert("Adapter: below MCR");
        adapter.openSimulatedTrove(COLL_1BTC, 28_000e18);
    }

    function test_OpenTrove_FailsDuplicate() public {
        vm.prank(alice);
        adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);

        vm.prank(alice);
        vm.expectRevert("Adapter: trove exists");
        adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);
    }

    // ─── Collateral Management ────────────────────────────────────────────────

    function test_AddCollateral() public {
        vm.prank(alice);
        adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);

        vm.prank(alice);
        adapter.addSimulatedCollateral(0.5e18);

        MezoIntegrationAdapter.SimulatedTrove memory t = adapter.getTrove(alice);
        assertEq(t.collateralBTC18, 1.5e18);
    }

    function test_RepayDebt() public {
        vm.prank(alice);
        adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);

        vm.prank(alice);
        adapter.repaySimulatedDebt(5_000e18);

        MezoIntegrationAdapter.SimulatedTrove memory t = adapter.getTrove(alice);
        assertEq(t.debtMUSD18, 20_000e18);
    }

    function test_CloseTrove() public {
        vm.prank(alice);
        adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);

        vm.prank(alice);
        adapter.closeSimulatedTrove();

        MezoIntegrationAdapter.SimulatedTrove memory t = adapter.getTrove(alice);
        assertFalse(t.active);
    }

    // ─── Liquidation ──────────────────────────────────────────────────────────

    function _openAndCrash(address user, uint256 debt) internal {
        vm.prank(user);
        adapter.openSimulatedTrove(COLL_1BTC, debt);

        // Crash BTC price: $30k → $21k (-30%) → CR drops below 110%
        // collateral = 1 BTC × $21k = $21k; debt = $25k → CR = 84%
        vm.prank(dao);
        adapter.setSimulatedBTCPrice(21_000e18);
    }

    function test_Liquidate_UndercollateralizedTrove() public {
        _openAndCrash(alice, DEBT_25K);

        // Deposit MUSD to SP so liquidation has coverage
        adapter.depositToSP(50_000e18);

        adapter.liquidateSimulated(alice);

        MezoIntegrationAdapter.SimulatedTrove memory t = adapter.getTrove(alice);
        assertFalse(t.active);
    }

    function test_Liquidate_FailsSafeTrove() public {
        vm.prank(alice);
        adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);
        // CR = 120%, MCR = 110% — safe

        vm.expectRevert("Adapter: trove is safe");
        adapter.liquidateSimulated(alice);
    }

    function test_BatchLiquidate() public {
        // Open three troves
        vm.prank(alice);   adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);
        vm.prank(bob);     adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);
        vm.prank(charlie); adapter.openSimulatedTrove(2e18, 20_000e18); // healthier

        adapter.depositToSP(200_000e18);

        // Crash price
        vm.prank(dao);
        adapter.setSimulatedBTCPrice(21_000e18);

        address[] memory victims = new address[](3);
        victims[0] = alice;
        victims[1] = bob;
        victims[2] = charlie;
        adapter.batchLiquidate(victims);

        assertFalse(adapter.getTrove(alice).active);
        assertFalse(adapter.getTrove(bob).active);
        // Charlie's CR = 2 BTC × $21k / $20k = 210% — still safe
        assertTrue(adapter.getTrove(charlie).active);
    }

    // ─── Position Health ──────────────────────────────────────────────────────

    function test_CheckPositionHealth_Safe() public {
        vm.prank(alice);
        adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K); // 120% CR

        // CR=120%, MCR=110%: safe but in warning band (MCR+10pp ≤ CR < MCR+20pp)
        // riskLevel 0 requires CR ≥ MCR+20pp = 130%; at 120% we get riskLevel 1
        (bool safe,,, uint8 risk) = adapter.checkPositionHealth(alice);
        assertTrue(safe);
        assertEq(risk, 1);
    }

    function test_CheckPositionHealth_AtRisk() public {
        // CR just above MCR: open at 112%
        uint256 debt = (COLL_1BTC * BTC_PRICE_18 / 1e18) * 1e18 / 112e16;
        vm.prank(alice);
        adapter.openSimulatedTrove(COLL_1BTC, debt);

        (bool safe,,, uint8 risk) = adapter.checkPositionHealth(alice);
        assertTrue(safe);
        assertGe(risk, 1); // warning or at_risk
    }

    function test_CheckPositionHealth_NoTrove() public view {
        (bool safe,,, uint8 risk) = adapter.checkPositionHealth(address(0xDEAD));
        assertTrue(safe);
        assertEq(risk, 0);
    }

    // ─── System Stats ─────────────────────────────────────────────────────────

    function test_GetSystemStats() public {
        vm.prank(alice);
        adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);
        adapter.depositToSP(10_000e18);

        (uint256 tcr, uint256 spDepth,) = adapter.getSystemStats();
        assertGt(tcr, 0);
        assertGt(spDepth, 0);
    }

    // ─── Active Troves View ───────────────────────────────────────────────────

    function test_GetActiveTroveOwners() public {
        vm.prank(alice);   adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);
        vm.prank(bob);     adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);
        // charlie never opens a trove — just verify alice and bob are counted

        address[] memory active = adapter.getActiveTroveOwners();
        assertEq(active.length, 2);
    }

    // ─── FindLiquidatable ─────────────────────────────────────────────────────

    function test_FindLiquidatable() public {
        vm.prank(alice); adapter.openSimulatedTrove(COLL_1BTC, DEBT_25K);
        vm.prank(bob);   adapter.openSimulatedTrove(2e18, 10_000e18); // safe

        // Crash price
        vm.prank(dao);
        adapter.setSimulatedBTCPrice(21_000e18);

        address[] memory candidates = new address[](2);
        candidates[0] = alice;
        candidates[1] = bob;

        (, uint256 count) = adapter.findLiquidatable(candidates);
        assertEq(count, 1); // only alice is liquidatable
    }
}
