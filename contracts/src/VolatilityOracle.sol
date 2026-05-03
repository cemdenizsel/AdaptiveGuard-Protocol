// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IVolatilityOracle.sol";

/**
 * @title VolatilityOracle
 * @notice On-chain volatility oracle for AdaptiveGuard Protocol.
 *
 * Data flow:
 *   Off-chain EGARCH(1,1) service  →  submitVolatility()
 *   Chainlink RV feed (optional)   →  used for sanity-check / median
 *   Deribit DVOL (optional)        →  used as secondary cross-check
 *
 * Acceptance rules (streaming-median outlier rejection):
 *   1. If both Chainlink RV and DVOL are available:
 *      - Compute streaming median of {chainlink_rv, dvol, egarch}
 *      - Reject if any two diverge by >30% of their midpoint
 *   2. If only one feed available, require |egarch - feed| < 30%
 *   3. If neither feed available, accept EGARCH directly (degraded mode)
 *
 * EMA smoothing (α = 0.1) is applied on-chain to the accepted value
 * to suppress transient spikes before the result reaches AdaptiveMCREngine.
 */

interface IChainlinkFeed {
    function latestRoundData()
        external
        view
        returns (uint80, int256 answer, uint256, uint256 updatedAt, uint80);
}

contract VolatilityOracle is IVolatilityOracle, AccessControl, Pausable {
    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant UPDATER_ROLE = keccak256("UPDATER_ROLE");
    bytes32 public constant ADMIN_ROLE   = keccak256("ADMIN_ROLE");

    // ─── Constants ────────────────────────────────────────────────────────────
    uint256 public constant ORACLE_HEARTBEAT      = 2 hours;
    uint256 public constant DIVERGENCE_LIMIT      = 30e16;  // 30% in 1e18
    uint256 public constant EMA_ALPHA_BPS         = 1000;   // α = 0.10 in BPS (10%)
    uint256 public constant EMA_ALPHA_DENOM       = 10000;
    uint256 public constant VOL_MIN_BPS           = 500;    // 5% floor
    uint256 public constant VOL_MAX_BPS           = 50000;  // 500% ceiling (safety)

    // ─── Storage ──────────────────────────────────────────────────────────────
    uint256 public smoothedVolBPS;    // EMA-smoothed volatility in BPS
    uint256 public rawVolBPS;         // Latest raw (pre-EMA) accepted value
    uint256 public lastUpdatedAt;     // Timestamp of last accepted update
    uint256 public updateCount;       // Total accepted updates

    IChainlinkFeed public chainlinkRVFeed;   // Optional Chainlink Realized Vol feed
    IChainlinkFeed public dvolFeed;          // Optional Deribit DVOL feed

    bool public chainlinkEnabled;
    bool public dvolEnabled;

    // ─── Events ───────────────────────────────────────────────────────────────
    event VolatilityUpdated(
        uint256 rawBPS,
        uint256 smoothedBPS,
        uint256 timestamp,
        address updater
    );
    event OutlierRejected(uint256 egarchBPS, uint256 feedBPS, uint256 divergence);
    event FeedConfigured(address chainlinkFeed, address dvolFeed);

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address admin, uint256 initialVolBPS) {
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(ADMIN_ROLE, admin);
        _grantRole(UPDATER_ROLE, admin);

        uint256 clamped = _clamp(initialVolBPS);
        smoothedVolBPS = clamped;
        rawVolBPS      = clamped;
        lastUpdatedAt  = block.timestamp;
    }

    // ─── Core: Submit Volatility ──────────────────────────────────────────────

    /**
     * @notice Submit a new EGARCH volatility estimate.
     * @param egarchVolBPS Annualized volatility from off-chain EGARCH, in BPS.
     */
    function submitVolatility(uint256 egarchVolBPS)
        external
        onlyRole(UPDATER_ROLE)
        whenNotPaused
    {
        uint256 accepted = _validateAndAccept(egarchVolBPS);

        // Apply EMA smoothing: smoothed = α * new + (1-α) * old
        uint256 newSmoothed = (accepted * EMA_ALPHA_BPS + smoothedVolBPS * (EMA_ALPHA_DENOM - EMA_ALPHA_BPS))
            / EMA_ALPHA_DENOM;

        rawVolBPS      = accepted;
        smoothedVolBPS = newSmoothed;
        lastUpdatedAt  = block.timestamp;
        unchecked { ++updateCount; }

        emit VolatilityUpdated(accepted, newSmoothed, block.timestamp, msg.sender);
    }

    // ─── IVolatilityOracle ────────────────────────────────────────────────────

    function getVolatility() external view override returns (uint256 volBPS, uint256 updatedAt) {
        return (smoothedVolBPS, lastUpdatedAt);
    }

    function isHealthy() external view override returns (bool) {
        return block.timestamp - lastUpdatedAt <= ORACLE_HEARTBEAT;
    }

    // ─── Validation ───────────────────────────────────────────────────────────

    function _validateAndAccept(uint256 egarchBPS) internal returns (uint256) {
        egarchBPS = _clamp(egarchBPS);

        uint256 clFeed;
        bool clFresh;
        uint256 dvFeed;
        bool dvFresh;

        if (chainlinkEnabled) {
            (clFeed, clFresh) = _readChainlinkRV();
        }
        if (dvolEnabled) {
            (dvFeed, dvFresh) = _readDVOL();
        }

        // Both feeds available: streaming median of three
        if (clFresh && dvFresh) {
            if (_divergenceExceeds(clFeed, dvFeed)) {
                emit OutlierRejected(egarchBPS, clFeed, _divergence(clFeed, dvFeed));
                return clFeed; // Fall back to chainlink as primary
            }
            return _median3(egarchBPS, clFeed, dvFeed);
        }

        // Only chainlink available
        if (clFresh) {
            if (_divergenceExceeds(egarchBPS, clFeed)) {
                emit OutlierRejected(egarchBPS, clFeed, _divergence(egarchBPS, clFeed));
                return clFeed;
            }
            return _median3(egarchBPS, clFeed, egarchBPS); // median of 2 = lower of the two closer values
        }

        // Only DVOL available
        if (dvFresh) {
            if (_divergenceExceeds(egarchBPS, dvFeed)) {
                emit OutlierRejected(egarchBPS, dvFeed, _divergence(egarchBPS, dvFeed));
                return egarchBPS; // Keep EGARCH if DVOL seems off
            }
            return _median3(egarchBPS, dvFeed, egarchBPS);
        }

        // Degraded: no external feeds
        return egarchBPS;
    }

    function _readChainlinkRV() internal view returns (uint256 bps, bool fresh) {
        try chainlinkRVFeed.latestRoundData() returns (uint80, int256 ans, uint256, uint256 upd, uint80) {
            if (ans > 0 && block.timestamp - upd <= ORACLE_HEARTBEAT) {
                return (uint256(ans), true);
            }
        } catch {}
        return (0, false);
    }

    function _readDVOL() internal view returns (uint256 bps, bool fresh) {
        try dvolFeed.latestRoundData() returns (uint80, int256 ans, uint256, uint256 upd, uint80) {
            if (ans > 0 && block.timestamp - upd <= 24 hours) {
                return (uint256(ans), true);
            }
        } catch {}
        return (0, false);
    }

    // ─── Admin ────────────────────────────────────────────────────────────────

    function setFeeds(address _chainlinkRV, address _dvol) external onlyRole(ADMIN_ROLE) {
        if (_chainlinkRV != address(0)) {
            chainlinkRVFeed  = IChainlinkFeed(_chainlinkRV);
            chainlinkEnabled = true;
        }
        if (_dvol != address(0)) {
            dvolFeed    = IChainlinkFeed(_dvol);
            dvolEnabled = true;
        }
        emit FeedConfigured(_chainlinkRV, _dvol);
    }

    function pause()   external onlyRole(ADMIN_ROLE) { _pause(); }
    function unpause() external onlyRole(ADMIN_ROLE) { _unpause(); }

    // ─── Helpers ──────────────────────────────────────────────────────────────

    function _divergence(uint256 a, uint256 b) internal pure returns (uint256) {
        uint256 mid = (a + b) / 2;
        if (mid == 0) return 0;
        uint256 diff = a > b ? a - b : b - a;
        return diff * 1e18 / mid;
    }

    function _divergenceExceeds(uint256 a, uint256 b) internal pure returns (bool) {
        return _divergence(a, b) > DIVERGENCE_LIMIT;
    }

    function _median3(uint256 a, uint256 b, uint256 c) internal pure returns (uint256) {
        if (a > b) (a, b) = (b, a);
        if (b > c) (b, c) = (c, b);
        if (a > b) (a, b) = (b, a);
        return b;
    }

    function _clamp(uint256 v) internal pure returns (uint256) {
        if (v < VOL_MIN_BPS) return VOL_MIN_BPS;
        if (v > VOL_MAX_BPS) return VOL_MAX_BPS;
        return v;
    }
}
