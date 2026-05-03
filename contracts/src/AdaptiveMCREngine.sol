// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./interfaces/IVolatilityOracle.sol";
import "./interfaces/IAdaptiveMCR.sol";

/**
 * @title AdaptiveMCREngine
 * @notice Computes and manages the minimum collateral ratio for the AdaptiveGuard Protocol.
 *
 * Four-regime volatility → MCR mapping (linear interpolation between breakpoints):
 *
 *   Vol (annualized)  |  Base MCR
 *   ──────────────────|──────────
 *   < 30%             |  110%
 *   30–60%            |  125%   (interpolated)
 *   60–90%            |  140%   (interpolated)
 *   ≥ 90%             |  160%   (interpolated)
 *
 * Multi-signal composite floor also incorporates:
 *   - Stability Pool depth: shallower SP → higher MCR floor (+2-5pp)
 *   - System TCR proximity to CCR: near CCR → higher MCR floor (+0-10pp)
 *
 * Rate limiting:
 *   - Max ±5pp change per epoch
 *   - 4-hour cooldown between successive MCR decreases
 *   - Circuit breaker: if BTC price drops >10% in 12h, MCR is frozen for 48h
 *
 * Governance:
 *   - MCR bounds [110%, 160%] enforced as hard guardrails
 *   - Regime breakpoints and MCR targets are DAO-adjustable
 */
contract AdaptiveMCREngine is IAdaptiveMCR, AccessControl, Pausable {

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 public constant DAO_ROLE      = keccak256("DAO_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");

    // ─── Precision / Hard Bounds ──────────────────────────────────────────────
    uint256 public constant PRECISION  = 1e18;
    uint256 public constant MCR_MIN    = 110e16;  // 110%
    uint256 public constant MCR_MAX    = 160e16;  // 160%
    uint256 public constant CCR        = 150e16;  // Critical Collateral Ratio
    uint256 public constant MAX_DELTA  = 5e16;    // ±5pp per epoch
    uint256 public constant DECREASE_COOLDOWN  = 4 hours;
    uint256 public constant CIRCUIT_BREAKER_WINDOW    = 12 hours;
    uint256 public constant CIRCUIT_BREAKER_THRESHOLD = 10e16; // 10% drop
    uint256 public constant CIRCUIT_BREAKER_HOLD      = 48 hours;

    // ─── Regime Config (DAO-adjustable) ──────────────────────────────────────
    // Stored as BPS values, converted to 1e18 at compute time
    struct RegimeConfig {
        uint32 bp0;   // Vol breakpoint 0 (BPS, e.g. 3000 = 30%)
        uint32 bp1;   // Vol breakpoint 1
        uint32 bp2;   // Vol breakpoint 2
        uint32 mcr0;  // MCR at regime 0 (BPS, e.g. 11000 = 110%)
        uint32 mcr1;
        uint32 mcr2;
        uint32 mcr3;
    }
    RegimeConfig public regime;

    // ─── State ────────────────────────────────────────────────────────────────
    uint256 public override currentMCR;
    uint256 public lastDecreaseAt;

    // Circuit breaker
    uint256 public circuitBreakerUntil;  // timestamp until which MCR is frozen
    uint256 public lastRecordedPrice;    // for 12h window check
    uint256 public lastPriceCheckAt;

    // Pending proposal (optimistic challenge pattern)
    struct Proposal {
        uint256 proposedMCR;
        uint256 proposedAt;
        uint256 volBPS;
        address proposer;
    }
    Proposal public pendingProposal;
    bool public hasPending;
    uint256 public constant CHALLENGE_WINDOW = 1 hours;

    IVolatilityOracle public oracle;

    // ─── Events ───────────────────────────────────────────────────────────────
    event MCRProposed(uint256 proposedMCR, uint256 volBPS, uint256 deadline, address proposer);
    event MCRApplied(uint256 oldMCR, uint256 newMCR, uint256 volBPS);
    event MCRChallenged(address challenger, uint256 proposedMCR, string reason);
    event CircuitBreakerEngaged(uint256 frozenUntil, uint256 priceDrop);
    event RegimeUpdated(RegimeConfig newRegime);

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(address _oracle, address _dao) {
        oracle = IVolatilityOracle(_oracle);

        _grantRole(DEFAULT_ADMIN_ROLE, _dao);
        _grantRole(DAO_ROLE, _dao);
        _grantRole(GUARDIAN_ROLE, _dao);

        currentMCR = MCR_MIN;

        // Default regime: breakpoints 30/60/90%, MCR targets 110/125/140/160%
        regime = RegimeConfig({
            bp0: 3000, bp1: 6000, bp2: 9000,
            mcr0: 11000, mcr1: 12500, mcr2: 14000, mcr3: 16000
        });
    }

    // ─── Core: Propose + Apply MCR ────────────────────────────────────────────

    /**
     * @notice Propose a new MCR from the current oracle volatility reading.
     *         Enforces guardrails and rate limits immediately.
     *         The proposal enters a 1-hour challenge window before activation.
     * @param spDepthBPS  Stability Pool depth as fraction of total debt, in BPS.
     *                    E.g. 3000 = SP holds 30% of outstanding debt.
     * @param tcrBPS      System Total Collateral Ratio in BPS (e.g. 15000 = 150%).
     * @param btcPriceBPS Current BTC/USD price in BPS-equivalent (for circuit breaker).
     *                    Use raw Chainlink price * 100 / 1e8 to convert to BPS.
     */
    function proposeMCRUpdate(
        uint256 spDepthBPS,
        uint256 tcrBPS,
        uint256 btcPriceBPS
    ) external onlyRole(PROPOSER_ROLE) whenNotPaused {
        require(!hasPending, "Engine: proposal already pending");

        // 1. Check circuit breaker
        _updateCircuitBreaker(btcPriceBPS);
        require(block.timestamp > circuitBreakerUntil, "Engine: circuit breaker active");

        // 2. Read oracle
        (uint256 volBPS, uint256 oracleUpdated) = oracle.getVolatility();
        require(block.timestamp - oracleUpdated <= 2 hours, "Engine: oracle stale");

        // 3. Compute target MCR (composite)
        uint256 target = _computeCompositeMCR(volBPS, spDepthBPS, tcrBPS);

        // 4. Apply rate limiter
        uint256 limited = _applyRateLimiter(target);

        // 5. Store pending
        pendingProposal = Proposal({
            proposedMCR: limited,
            proposedAt:  block.timestamp,
            volBPS:      volBPS,
            proposer:    msg.sender
        });
        hasPending = true;

        emit MCRProposed(limited, volBPS, block.timestamp + CHALLENGE_WINDOW, msg.sender);
    }

    /**
     * @notice Apply a pending proposal after the challenge window expires.
     *         Anyone can call this.
     */
    function applyPendingProposal() external whenNotPaused {
        require(hasPending, "Engine: no pending proposal");
        require(
            block.timestamp >= pendingProposal.proposedAt + CHALLENGE_WINDOW,
            "Engine: challenge window open"
        );

        uint256 old = currentMCR;
        uint256 next = pendingProposal.proposedMCR;

        if (next < old) {
            lastDecreaseAt = block.timestamp;
        }
        currentMCR = next;
        hasPending = false;

        emit MCRApplied(old, next, pendingProposal.volBPS);
    }

    /**
     * @notice Challenge and cancel a pending proposal (Guardian/DAO only).
     */
    function challengeProposal(string calldata reason) external onlyRole(GUARDIAN_ROLE) {
        require(hasPending, "Engine: no pending proposal");
        require(
            block.timestamp < pendingProposal.proposedAt + CHALLENGE_WINDOW,
            "Engine: window expired"
        );
        emit MCRChallenged(msg.sender, pendingProposal.proposedMCR, reason);
        hasPending = false;
        delete pendingProposal;
    }

    // ─── IAdaptiveMCR ─────────────────────────────────────────────────────────

    function computeMCRFromVol(uint256 volBPS) public view override returns (uint256) {
        return _volToMCR(volBPS);
    }

    function isPositionSafe(uint256 collateralUSD, uint256 debtUSD)
        external
        view
        override
        returns (bool safe, uint256 currentCR, uint256 requiredMCR)
    {
        requiredMCR = currentMCR;
        if (debtUSD == 0) return (true, type(uint256).max, requiredMCR);
        currentCR   = collateralUSD * PRECISION / debtUSD;
        safe        = currentCR >= requiredMCR;
    }

    // ─── MCR Computation ──────────────────────────────────────────────────────

    function _volToMCR(uint256 volBPS) internal view returns (uint256) {
        RegimeConfig memory r = regime;

        // Convert BPS to 1e18 for calculation
        uint256 bp0 = uint256(r.bp0) * 1e14;
        uint256 bp1 = uint256(r.bp1) * 1e14;
        uint256 bp2 = uint256(r.bp2) * 1e14;
        uint256 m0  = uint256(r.mcr0) * 1e14;
        uint256 m1  = uint256(r.mcr1) * 1e14;
        uint256 m2  = uint256(r.mcr2) * 1e14;
        uint256 m3  = uint256(r.mcr3) * 1e14;

        uint256 v = volBPS * 1e14; // convert BPS to 1e18

        if (v <= bp0) return m0;

        if (v <= bp1) {
            uint256 t01 = (v - bp0) * PRECISION / (bp1 - bp0);
            return m0 + (m1 - m0) * t01 / PRECISION;
        }

        if (v <= bp2) {
            uint256 t12 = (v - bp1) * PRECISION / (bp2 - bp1);
            return m1 + (m2 - m1) * t12 / PRECISION;
        }

        // Above bp2: interpolate toward m3
        uint256 span = bp2; // use bp2 as scaling reference
        uint256 excess = v - bp2;
        uint256 t = excess >= span ? PRECISION : excess * PRECISION / span;
        uint256 computed = m2 + (m3 - m2) * t / PRECISION;
        return computed > MCR_MAX ? MCR_MAX : computed;
    }

    function _computeCompositeMCR(
        uint256 volBPS,
        uint256 spDepthBPS,
        uint256 tcrBPS
    ) internal view returns (uint256) {
        uint256 base = _volToMCR(volBPS);

        // Stability Pool depth adjustment
        uint256 spAdj;
        if (spDepthBPS < 1000) {      // SP < 10% of debt
            spAdj = 5e16;             // +5pp
        } else if (spDepthBPS < 2000) { // SP < 20%
            spAdj = 2e16;             // +2pp
        }

        // TCR proximity to CCR adjustment
        uint256 tcrAdj;
        uint256 tcr18 = tcrBPS * 1e14; // convert BPS to 1e18
        if (tcr18 > CCR * 13 / 10) {
            tcrAdj = 0;               // Healthy (TCR > 195%)
        } else if (tcr18 > CCR * 11 / 10) {
            // Linear from 0 → 5pp as TCR approaches 1.1×CCR
            uint256 upperBound = CCR * 13 / 10;
            uint256 lowerBound = CCR * 11 / 10;
            uint256 t = (upperBound - tcr18) * PRECISION / (upperBound - lowerBound);
            tcrAdj = 5e16 * t / PRECISION;
        } else if (tcr18 > CCR) {
            // Linear from 5pp → 10pp as TCR approaches CCR
            uint256 upperBound = CCR * 11 / 10;
            uint256 t = (upperBound - tcr18) * PRECISION / (CCR / 10);
            tcrAdj = 5e16 + 5e16 * t / PRECISION;
        } else {
            tcrAdj = 10e16;           // In or near Recovery Mode: +10pp
        }

        uint256 composite = base + spAdj + tcrAdj;
        if (composite > MCR_MAX) return MCR_MAX;
        if (composite < MCR_MIN) return MCR_MIN;
        return composite;
    }

    function _applyRateLimiter(uint256 target) internal view returns (uint256) {
        uint256 cur = currentMCR;
        int256 delta = int256(target) - int256(cur);

        // Cap magnitude
        if (delta > int256(MAX_DELTA))  delta = int256(MAX_DELTA);
        if (delta < -int256(MAX_DELTA)) delta = -int256(MAX_DELTA);

        // Cooldown on decreases
        if (delta < 0) {
            if (block.timestamp < lastDecreaseAt + DECREASE_COOLDOWN) {
                delta = 0; // Block decrease during cooldown
            }
        }

        uint256 result = uint256(int256(cur) + delta);
        if (result > MCR_MAX) return MCR_MAX;
        if (result < MCR_MIN) return MCR_MIN;
        return result;
    }

    // ─── Circuit Breaker ──────────────────────────────────────────────────────

    function _updateCircuitBreaker(uint256 currentPriceBPS) internal {
        if (lastPriceCheckAt == 0) {
            lastRecordedPrice = currentPriceBPS;
            lastPriceCheckAt  = block.timestamp;
            return;
        }

        // Refresh the 12-hour window reference
        if (block.timestamp - lastPriceCheckAt >= CIRCUIT_BREAKER_WINDOW) {
            lastRecordedPrice = currentPriceBPS;
            lastPriceCheckAt  = block.timestamp;
            return;
        }

        if (lastRecordedPrice > 0) {
            // Check drop within window
            if (currentPriceBPS < lastRecordedPrice) {
                uint256 drop = (lastRecordedPrice - currentPriceBPS) * PRECISION / lastRecordedPrice;
                if (drop > CIRCUIT_BREAKER_THRESHOLD) {
                    circuitBreakerUntil = block.timestamp + CIRCUIT_BREAKER_HOLD;
                    emit CircuitBreakerEngaged(circuitBreakerUntil, drop);
                }
            }
        }
    }

    // ─── Governance ───────────────────────────────────────────────────────────

    function updateRegime(RegimeConfig calldata newRegime) external onlyRole(DAO_ROLE) {
        require(newRegime.bp0 < newRegime.bp1 && newRegime.bp1 < newRegime.bp2, "Engine: invalid breakpoints");
        require(newRegime.mcr0 >= 11000 && newRegime.mcr3 <= 16000, "Engine: MCR out of range");
        require(newRegime.mcr0 <= newRegime.mcr1 && newRegime.mcr1 <= newRegime.mcr2 && newRegime.mcr2 <= newRegime.mcr3, "Engine: non-monotonic");
        regime = newRegime;
        emit RegimeUpdated(newRegime);
    }

    function setOracle(address _oracle) external onlyRole(DAO_ROLE) {
        oracle = IVolatilityOracle(_oracle);
    }

    function addProposer(address proposer) external onlyRole(DAO_ROLE) {
        _grantRole(PROPOSER_ROLE, proposer);
    }

    function emergencySetMCR(uint256 newMCR) external onlyRole(DAO_ROLE) {
        require(newMCR >= MCR_MIN && newMCR <= MCR_MAX, "Engine: out of bounds");
        uint256 old = currentMCR;
        currentMCR  = newMCR;
        hasPending  = false;
        emit MCRApplied(old, newMCR, 0);
    }

    function pause()   external onlyRole(GUARDIAN_ROLE) { _pause(); }
    function unpause() external onlyRole(DAO_ROLE)      { _unpause(); }

    // ─── View Helpers ─────────────────────────────────────────────────────────

    function getSystemStatus() external view returns (
        uint256 mcr,
        bool circuitBreakerActive,
        bool oracleHealthy,
        uint256 volBPS,
        uint256 proposalDeadline
    ) {
        (uint256 v,) = oracle.getVolatility();
        return (
            currentMCR,
            block.timestamp <= circuitBreakerUntil,
            oracle.isHealthy(),
            v,
            hasPending ? pendingProposal.proposedAt + CHALLENGE_WINDOW : 0
        );
    }
}
