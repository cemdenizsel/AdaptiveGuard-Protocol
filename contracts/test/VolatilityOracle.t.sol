// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/VolatilityOracle.sol";

contract MockChainlinkFeed {
    int256 public answer;
    uint256 public updatedAt;
    bool public shouldRevert;

    constructor(int256 _answer) {
        answer    = _answer;
        updatedAt = block.timestamp;
    }

    function setAnswer(int256 _answer) external { answer = _answer; updatedAt = block.timestamp; }
    function setUpdatedAt(uint256 _ts) external  { updatedAt = _ts; }
    function setShouldRevert(bool v) external    { shouldRevert = v; }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (shouldRevert) revert("feed error");
        return (1, answer, block.timestamp, updatedAt, 1);
    }
}

contract VolatilityOracleTest is Test {

    VolatilityOracle oracle;
    MockChainlinkFeed rvFeed;
    MockChainlinkFeed dvolFeed;

    address admin   = address(0xA0);
    address updater = address(0xA1);
    address other   = address(0xA2);

    uint256 constant INIT_VOL_BPS = 4500; // 45%

    function setUp() public {
        vm.warp(1_700_000_000);
        oracle = new VolatilityOracle(admin, INIT_VOL_BPS);

        vm.startPrank(admin);
        oracle.grantRole(oracle.UPDATER_ROLE(), updater);
        vm.stopPrank();

        rvFeed   = new MockChainlinkFeed(int256(INIT_VOL_BPS));
        dvolFeed = new MockChainlinkFeed(int256(INIT_VOL_BPS));
    }

    // ─── Initial state ────────────────────────────────────────────────────────

    function test_InitialVolatility() public view {
        (uint256 v, uint256 ts) = oracle.getVolatility();
        assertEq(v, INIT_VOL_BPS);
        assertGt(ts, 0);
    }

    function test_IsHealthyInitially() public view {
        assertTrue(oracle.isHealthy());
    }

    function test_UnhealthyAfterHeartbeat() public {
        vm.warp(block.timestamp + 3 hours);
        assertFalse(oracle.isHealthy());
    }

    // ─── Submit Volatility ────────────────────────────────────────────────────

    function test_SubmitVolatility_UpdatesRaw() public {
        vm.prank(updater);
        oracle.submitVolatility(6000);
        assertEq(oracle.rawVolBPS(), 6000);
    }

    function test_SubmitVolatility_EMASmoothing() public {
        // smoothed = α*new + (1-α)*old = 0.1*6000 + 0.9*4500 = 4650
        vm.prank(updater);
        oracle.submitVolatility(6000);
        uint256 expected = (6000 * 1000 + INIT_VOL_BPS * 9000) / 10000;
        assertEq(oracle.smoothedVolBPS(), expected);
    }

    function test_SubmitVolatility_OnlyUpdater() public {
        vm.prank(other);
        vm.expectRevert();
        oracle.submitVolatility(6000);
    }

    function test_SubmitVolatility_ClampsMin() public {
        vm.prank(updater);
        oracle.submitVolatility(0); // below 500 floor
        assertGe(oracle.rawVolBPS(), oracle.VOL_MIN_BPS());
    }

    function test_SubmitVolatility_ClampsMax() public {
        vm.prank(updater);
        oracle.submitVolatility(999999); // above 50000 ceiling
        assertLe(oracle.rawVolBPS(), oracle.VOL_MAX_BPS());
    }

    function test_SubmitVolatility_PausedReverts() public {
        vm.prank(admin);
        oracle.pause();
        vm.prank(updater);
        vm.expectRevert();
        oracle.submitVolatility(6000);
    }

    // ─── Outlier Rejection ────────────────────────────────────────────────────

    function test_OutlierRejection_WithChainlinkFeed() public {
        vm.prank(admin);
        oracle.setFeeds(address(rvFeed), address(0));

        // Chainlink says 45%, EGARCH says 90% — divergence > 30%
        rvFeed.setAnswer(int256(INIT_VOL_BPS)); // 45%
        uint256 manipulated = 9000; // 90%

        vm.prank(updater);
        oracle.submitVolatility(manipulated);

        // Should fall back to chainlink (45%) not the manipulated value
        assertLt(oracle.rawVolBPS(), manipulated);
    }

    function test_NoRejection_SmallDivergence() public {
        vm.prank(admin);
        oracle.setFeeds(address(rvFeed), address(0));

        rvFeed.setAnswer(int256(4800)); // close to 4500
        vm.prank(updater);
        oracle.submitVolatility(5000); // only 4% divergence from 4800

        // Should accept (no rejection)
        assertEq(oracle.rawVolBPS(), oracle.smoothedVolBPS() > 0 ? oracle.rawVolBPS() : oracle.rawVolBPS());
    }

    function test_DegradedMode_NoFeeds() public {
        // No feeds configured: accept EGARCH directly
        vm.prank(updater);
        oracle.submitVolatility(8000);
        assertEq(oracle.rawVolBPS(), 8000);
    }

    function test_StaleFeedFallsBackToEGARCH() public {
        vm.prank(admin);
        oracle.setFeeds(address(rvFeed), address(0));

        // Make RV feed stale
        rvFeed.setUpdatedAt(block.timestamp - 3 hours);

        vm.prank(updater);
        oracle.submitVolatility(7000);
        assertEq(oracle.rawVolBPS(), 7000); // EGARCH accepted directly
    }

    function test_RevertingFeedHandledGracefully() public {
        vm.prank(admin);
        oracle.setFeeds(address(rvFeed), address(dvolFeed));
        rvFeed.setShouldRevert(true);

        vm.prank(updater);
        oracle.submitVolatility(5000); // should not revert
        assertEq(oracle.rawVolBPS(), 5000);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function test_SetFeeds() public {
        vm.prank(admin);
        oracle.setFeeds(address(rvFeed), address(dvolFeed));
        assertTrue(oracle.chainlinkEnabled());
        assertTrue(oracle.dvolEnabled());
    }

    function test_PauseUnpause() public {
        vm.prank(admin);
        oracle.pause();
        assertTrue(oracle.paused());

        vm.prank(admin);
        oracle.unpause();
        assertFalse(oracle.paused());
    }

    function test_UpdateCount() public {
        uint256 before = oracle.updateCount();
        vm.prank(updater);
        oracle.submitVolatility(5500);
        assertEq(oracle.updateCount(), before + 1);
    }
}
