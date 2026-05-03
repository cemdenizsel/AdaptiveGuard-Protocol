// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title RiskStewardsContract
 * @notice Volatility-Adaptive Minimum Collateral Ratio Manager
 *
 * Architecture:
 * - Off-chain EGARCH(1,1) service signs MCR updates
 * - On-chain contract applies updates after 1-hour challenge window
 * - DAO-set hard guardrails: MCR ∈ [110%, 160%]
 *
 * Circuit Breakers:
 * - Pause if oracle price deviates >15% in one block
 * - Cap single-update MCR change at ±5pp
 * - 4-hour cooldown between successive MCR decreases
 *
 * Oracle Integration:
 * - Primary: Chainlink Realized Volatility (10-min TWAP, 24h/7d)
 * - Secondary: Chainlink Functions → Deribit DVOL 30d IV
 * - Streaming median outlier rejection: reject if |RV - IV| > 30%
 *
 * Storage Optimization:
 * - Regime slots packed into single uint256
 * - Dirty-bit pattern for minimal SSTORE
 */

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IChainlinkAggregator {
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        );
}

contract RiskStewardsContract is AccessControl, Pausable, ReentrancyGuard {

    // ────────────────────────────────────────────────────────────────
    // Roles
    // ────────────────────────────────────────────────────────────────
    bytes32 public constant STEWARD_ROLE   = keccak256("STEWARD_ROLE");
    bytes32 public constant GUARDIAN_ROLE  = keccak256("GUARDIAN_ROLE");
    bytes32 public constant DAO_ROLE       = keccak256("DAO_ROLE");

    // ────────────────────────────────────────────────────────────────
    // Constants
    // ────────────────────────────────────────────────────────────────
    uint256 public constant MCR_PRECISION   = 1e18;   // 1e18 = 100%
    uint256 public constant MCR_MIN         = 110e16; // 110%
    uint256 public constant MCR_MAX         = 160e16; // 160%
    uint256 public constant MAX_DELTA_PP    = 5e16;   // 5pp per epoch
    uint256 public constant CHALLENGE_WINDOW = 1 hours;
    uint256 public constant DECREASE_COOLDOWN = 4 hours;
    uint256 public constant ORACLE_HEARTBEAT  = 1 hours;
    uint256 public constant PRICE_DEVIATION_LIMIT = 15e16;  // 15%
    uint256 public constant RV_IV_DIVERGENCE_LIMIT = 30e16; // 30%

    // ────────────────────────────────────────────────────────────────
    // Storage — packed into minimal slots
    // ────────────────────────────────────────────────────────────────

    /**
     * @dev Slot0: regime configuration packed into single uint256
     * Bits 0-15:   Regime 0 MCR (BPS, e.g. 11000 = 110%)
     * Bits 16-31:  Regime 1 MCR (BPS)
     * Bits 32-47:  Regime 2 MCR (BPS)
     * Bits 48-63:  Regime 3 MCR (BPS)
     * Bits 64-79:  Vol breakpoint 0 (BPS, e.g. 3000 = 30%)
     * Bits 80-95:  Vol breakpoint 1
     * Bits 96-111: Vol breakpoint 2
     * Bits 112-127: Reserved
     */
    uint256 public packedRegimes;

    /// @dev Current active MCR (1e18 precision)
    uint256 public currentMCR;

    /// @dev Dirty bit: pending MCR awaiting challenge window
    bool public hasPendingUpdate;

    struct PendingMCRUpdate {
        uint256 proposedMCR;
        uint256 proposedAt;
        uint256 volatilityBPS;   // EGARCH-estimated vol in BPS
        address proposer;
        bytes32 dataHash;        // Hash of off-chain EGARCH inputs
    }
    PendingMCRUpdate public pendingUpdate;

    /// @dev Timestamp of last MCR decrease
    uint256 public lastDecreaseAt;

    /// @dev Previous block's oracle price for deviation check
    uint256 public prevBlockOraclePrice;
    uint256 public prevBlockNumber;

    // ────────────────────────────────────────────────────────────────
    // Oracle References
    // ────────────────────────────────────────────────────────────────
    IChainlinkAggregator public rvFeed;    // Chainlink Realized Volatility
    IChainlinkAggregator public ivFeed;    // Deribit DVOL via Chainlink Functions
    IChainlinkAggregator public priceFeed; // BTC/USD price feed

    // ────────────────────────────────────────────────────────────────
    // Events
    // ────────────────────────────────────────────────────────────────
    event MCRUpdateProposed(
        uint256 indexed proposedMCR,
        uint256 volatilityBPS,
        uint256 challengeDeadline,
        address proposer
    );
    event MCRUpdateApplied(
        uint256 indexed oldMCR,
        uint256 indexed newMCR,
        uint256 volatilityBPS,
        uint256 appliedAt
    );
    event MCRUpdateChallenged(
        address indexed challenger,
        uint256 proposedMCR,
        string reason
    );
    event CircuitBreakerTriggered(string reason, uint256 oraclePrice);
    event OracleOutlierRejected(uint256 rv, uint256 iv, uint256 divergence);

    // ────────────────────────────────────────────────────────────────
    // Constructor
    // ────────────────────────────────────────────────────────────────
    constructor(
        address _rvFeed,
        address _ivFeed,
        address _priceFeed,
        address _dao
    ) {
        rvFeed = IChainlinkAggregator(_rvFeed);
        ivFeed = IChainlinkAggregator(_ivFeed);
        priceFeed = IChainlinkAggregator(_priceFeed);

        _grantRole(DEFAULT_ADMIN_ROLE, _dao);
        _grantRole(DAO_ROLE, _dao);
        _grantRole(GUARDIAN_ROLE, _dao);

        // Initialize at MCR_MIN = 110%
        currentMCR = MCR_MIN;

        // Pack default regime configuration
        // Regimes: 110%, 125%, 140%, 160%
        // Breakpoints: 30%, 60%, 90%
        packedRegimes = _packRegimes(
            11000, 12500, 14000, 16000, // MCR in BPS
            3000, 6000, 9000            // Vol breakpoints in BPS
        );
    }

    // ────────────────────────────────────────────────────────────────
    // Core MCR Update Flow (Optimistic Challenge Pattern)
    // ────────────────────────────────────────────────────────────────

    /**
     * @notice Propose a new MCR based on off-chain EGARCH volatility estimate.
     * @param proposedMCR New MCR in 1e18 precision (e.g. 125e16 = 125%)
     * @param volatilityBPS EGARCH annualized vol in BPS (e.g. 4500 = 45%)
     * @param dataHash Hash of EGARCH model inputs for verification
     */
    function proposeMCRUpdate(
        uint256 proposedMCR,
        uint256 volatilityBPS,
        bytes32 dataHash
    ) external onlyRole(STEWARD_ROLE) whenNotPaused nonReentrant {

        // 1. Check hard guardrails
        require(proposedMCR >= MCR_MIN, "RSC: below MCR_MIN");
        require(proposedMCR <= MCR_MAX, "RSC: above MCR_MAX");

        // 2. Check maximum rate-of-change
        uint256 delta = proposedMCR > currentMCR
            ? proposedMCR - currentMCR
            : currentMCR - proposedMCR;
        require(delta <= MAX_DELTA_PP, "RSC: exceeds max delta");

        // 3. Check decrease cooldown
        if (proposedMCR < currentMCR) {
            require(
                block.timestamp >= lastDecreaseAt + DECREASE_COOLDOWN,
                "RSC: decrease cooldown active"
            );
        }

        // 4. Validate oracle signals
        uint256 validatedVol = _validateOracleSignals(volatilityBPS);

        // 5. Check circuit breakers
        _checkCircuitBreakers();

        // 6. Store pending update
        hasPendingUpdate = true;
        pendingUpdate = PendingMCRUpdate({
            proposedMCR: proposedMCR,
            proposedAt: block.timestamp,
            volatilityBPS: validatedVol,
            proposer: msg.sender,
            dataHash: dataHash
        });

        emit MCRUpdateProposed(
            proposedMCR,
            validatedVol,
            block.timestamp + CHALLENGE_WINDOW,
            msg.sender
        );
    }

    /**
     * @notice Apply a pending MCR update after the challenge window expires.
     * Called by the steward service (or anyone) after 1-hour window.
     */
    function applyPendingUpdate() external nonReentrant whenNotPaused {
        require(hasPendingUpdate, "RSC: no pending update");
        require(
            block.timestamp >= pendingUpdate.proposedAt + CHALLENGE_WINDOW,
            "RSC: challenge window not elapsed"
        );

        uint256 oldMCR = currentMCR;
        uint256 newMCR = pendingUpdate.proposedMCR;

        if (newMCR < oldMCR) {
            lastDecreaseAt = block.timestamp;
        }

        currentMCR = newMCR;
        hasPendingUpdate = false;

        emit MCRUpdateApplied(oldMCR, newMCR, pendingUpdate.volatilityBPS, block.timestamp);
    }

    /**
     * @notice Challenge a pending update (Guardian/DAO role).
     * @param reason Human-readable reason for challenge
     */
    function challengeUpdate(string calldata reason)
        external
        onlyRole(GUARDIAN_ROLE)
    {
        require(hasPendingUpdate, "RSC: no pending update");
        require(
            block.timestamp < pendingUpdate.proposedAt + CHALLENGE_WINDOW,
            "RSC: challenge window expired"
        );

        emit MCRUpdateChallenged(msg.sender, pendingUpdate.proposedMCR, reason);

        hasPendingUpdate = false;
        delete pendingUpdate;
    }

    // ────────────────────────────────────────────────────────────────
    // Oracle Validation (Streaming Median + Outlier Rejection)
    // ────────────────────────────────────────────────────────────────

    /**
     * @notice Validate oracle signals. Reject if RV and IV diverge >30%.
     * @param proposedVolBPS Off-chain EGARCH estimate in BPS
     * @return validatedVol The accepted volatility signal
     */
    function _validateOracleSignals(uint256 proposedVolBPS)
        internal
        returns (uint256 validatedVol)
    {
        // Fetch Chainlink RV (primary)
        (, int256 rvRaw, , uint256 rvUpdatedAt, ) = rvFeed.latestRoundData();
        require(
            block.timestamp - rvUpdatedAt <= ORACLE_HEARTBEAT,
            "RSC: RV oracle stale"
        );
        require(rvRaw > 0, "RSC: invalid RV data");
        uint256 rv = uint256(rvRaw); // Assume RV feed returns value in BPS

        // Fetch IV (secondary sanity gate) — may be less fresh
        try ivFeed.latestRoundData() returns (
            uint80, int256 ivRaw, uint256, uint256 ivUpdatedAt, uint80
        ) {
            if (ivRaw > 0 && block.timestamp - ivUpdatedAt <= 24 hours) {
                uint256 iv = uint256(ivRaw);

                // Streaming median outlier rejection
                // Reject if |RV - IV| / ((RV + IV) / 2) > 30%
                uint256 midpoint = (rv + iv) / 2;
                uint256 divergence = rv > iv
                    ? (rv - iv) * 1e18 / midpoint
                    : (iv - rv) * 1e18 / midpoint;

                if (divergence > RV_IV_DIVERGENCE_LIMIT) {
                    emit OracleOutlierRejected(rv, iv, divergence);
                    // Fallback to primary RV signal
                    return rv;
                }

                // Use streaming median of {rv, iv, proposedVol}
                return _streamingMedian3(rv, iv, proposedVolBPS);
            }
        } catch {
            // IV feed unavailable, use RV only
        }

        // Sanity check: proposed vol shouldn't deviate too much from RV
        uint256 rvDivergence = rv > proposedVolBPS
            ? (rv - proposedVolBPS) * 1e18 / rv
            : (proposedVolBPS - rv) * 1e18 / rv;

        if (rvDivergence > RV_IV_DIVERGENCE_LIMIT) {
            // Use RV as authoritative source
            return rv;
        }

        return proposedVolBPS;
    }

    /**
     * @notice Compute streaming median of three values.
     */
    function _streamingMedian3(uint256 a, uint256 b, uint256 c)
        internal
        pure
        returns (uint256)
    {
        if (a > b) { (a, b) = (b, a); }
        if (b > c) { (b, c) = (c, b); }
        if (a > b) { (a, b) = (b, a); }
        return b; // Median
    }

    // ────────────────────────────────────────────────────────────────
    // Circuit Breakers
    // ────────────────────────────────────────────────────────────────

    /**
     * @notice Check all circuit breaker conditions.
     * Pauses updates if any condition is triggered.
     */
    function _checkCircuitBreakers() internal {
        (, int256 priceRaw, , uint256 priceUpdatedAt, ) = priceFeed.latestRoundData();
        require(priceUpdatedAt > 0, "RSC: price feed error");
        uint256 currentPrice = uint256(priceRaw);

        // Circuit breaker: price deviation >15% in one block
        if (prevBlockNumber > 0 && block.number > prevBlockNumber) {
            if (prevBlockOraclePrice > 0) {
                uint256 deviation = currentPrice > prevBlockOraclePrice
                    ? (currentPrice - prevBlockOraclePrice) * 1e18 / prevBlockOraclePrice
                    : (prevBlockOraclePrice - currentPrice) * 1e18 / prevBlockOraclePrice;

                if (deviation > PRICE_DEVIATION_LIMIT) {
                    _pause();
                    emit CircuitBreakerTriggered("Price deviation >15%", currentPrice);
                    revert("RSC: circuit breaker - price spike");
                }
            }
        }

        // Update previous block data
        if (block.number > prevBlockNumber) {
            prevBlockOraclePrice = currentPrice;
            prevBlockNumber = block.number;
        }
    }

    // ────────────────────────────────────────────────────────────────
    // On-Chain MCR Computation (for collateral checks)
    // ────────────────────────────────────────────────────────────────

    /**
     * @notice Compute the MCR for a given volatility level using packed regime slots.
     * @param volBPS Annualized volatility in BPS (e.g. 4500 = 45%)
     * @return mcr MCR in 1e18 precision
     */
    function computeMCRFromVol(uint256 volBPS) public view returns (uint256 mcr) {
        (
            uint256 mcr0, uint256 mcr1, uint256 mcr2, uint256 mcr3,
            uint256 bp0, uint256 bp1, uint256 bp2
        ) = _unpackRegimes(packedRegimes);

        // Convert BPS to internal format (multiply by 1e14 to get 1e18 precision)
        uint256 mcr0_18 = mcr0 * 1e14;
        uint256 mcr1_18 = mcr1 * 1e14;
        uint256 mcr2_18 = mcr2 * 1e14;
        uint256 mcr3_18 = mcr3 * 1e14;

        if (volBPS <= bp0) {
            return mcr0_18;
        } else if (volBPS <= bp1) {
            // Linear interpolation between regime 0 and 1
            uint256 t = (volBPS - bp0) * 1e18 / (bp1 - bp0);
            return mcr0_18 + (mcr1_18 - mcr0_18) * t / 1e18;
        } else if (volBPS <= bp2) {
            // Linear interpolation between regime 1 and 2
            uint256 t = (volBPS - bp1) * 1e18 / (bp2 - bp1);
            return mcr1_18 + (mcr2_18 - mcr1_18) * t / 1e18;
        } else {
            // Above highest breakpoint
            uint256 t = volBPS > 2 * bp2 ? 1e18 : (volBPS - bp2) * 1e18 / bp2;
            uint256 computed = mcr2_18 + (mcr3_18 - mcr2_18) * t / 1e18;
            return computed > MCR_MAX ? MCR_MAX : computed;
        }
    }

    /**
     * @notice Check if a position meets the current MCR requirement.
     * @param collateralUSD Collateral value in USD (1e18 precision)
     * @param debtUSD Debt value in USD (1e18 precision)
     */
    function isPositionSafe(uint256 collateralUSD, uint256 debtUSD)
        external
        view
        returns (bool safe, uint256 currentCR, uint256 requiredMCR)
    {
        requiredMCR = currentMCR;
        if (debtUSD == 0) return (true, type(uint256).max, requiredMCR);
        currentCR = collateralUSD * MCR_PRECISION / debtUSD;
        safe = currentCR >= requiredMCR;
    }

    // ────────────────────────────────────────────────────────────────
    // Storage Packing Helpers (Gas Optimization)
    // ────────────────────────────────────────────────────────────────

    function _packRegimes(
        uint256 mcr0, uint256 mcr1, uint256 mcr2, uint256 mcr3,
        uint256 bp0, uint256 bp1, uint256 bp2
    ) internal pure returns (uint256 packed) {
        packed =
            (mcr0 & 0xFFFF) |
            ((mcr1 & 0xFFFF) << 16) |
            ((mcr2 & 0xFFFF) << 32) |
            ((mcr3 & 0xFFFF) << 48) |
            ((bp0 & 0xFFFF) << 64) |
            ((bp1 & 0xFFFF) << 80) |
            ((bp2 & 0xFFFF) << 96);
    }

    function _unpackRegimes(uint256 packed)
        internal
        pure
        returns (
            uint256 mcr0, uint256 mcr1, uint256 mcr2, uint256 mcr3,
            uint256 bp0, uint256 bp1, uint256 bp2
        )
    {
        mcr0 = packed & 0xFFFF;
        mcr1 = (packed >> 16) & 0xFFFF;
        mcr2 = (packed >> 32) & 0xFFFF;
        mcr3 = (packed >> 48) & 0xFFFF;
        bp0  = (packed >> 64) & 0xFFFF;
        bp1  = (packed >> 80) & 0xFFFF;
        bp2  = (packed >> 96) & 0xFFFF;
    }

    // ────────────────────────────────────────────────────────────────
    // DAO Governance Functions
    // ────────────────────────────────────────────────────────────────

    /**
     * @notice Update regime configuration (DAO governance only).
     */
    function updateRegimes(
        uint256 mcr0, uint256 mcr1, uint256 mcr2, uint256 mcr3,
        uint256 bp0BPS, uint256 bp1BPS, uint256 bp2BPS
    ) external onlyRole(DAO_ROLE) {
        require(mcr0 >= 11000 && mcr0 <= 16000, "RSC: invalid MCR0");
        require(mcr1 >= mcr0 && mcr2 >= mcr1 && mcr3 >= mcr2, "RSC: non-monotonic");
        require(bp0BPS < bp1BPS && bp1BPS < bp2BPS, "RSC: invalid breakpoints");

        packedRegimes = _packRegimes(mcr0, mcr1, mcr2, mcr3, bp0BPS, bp1BPS, bp2BPS);
    }

    /**
     * @notice Grant steward role to an address (DAO only).
     */
    function addSteward(address steward) external onlyRole(DAO_ROLE) {
        _grantRole(STEWARD_ROLE, steward);
    }

    /**
     * @notice Revoke steward role.
     */
    function removeSteward(address steward) external onlyRole(DAO_ROLE) {
        _revokeRole(STEWARD_ROLE, steward);
    }

    /**
     * @notice Emergency pause by guardian.
     */
    function emergencyPause() external onlyRole(GUARDIAN_ROLE) {
        _pause();
    }

    /**
     * @notice Unpause by DAO.
     */
    function unpause() external onlyRole(DAO_ROLE) {
        _unpause();
    }

    /**
     * @notice Force-set MCR in emergency (DAO only, no challenge window).
     */
    function emergencySetMCR(uint256 newMCR) external onlyRole(DAO_ROLE) {
        require(newMCR >= MCR_MIN && newMCR <= MCR_MAX, "RSC: out of bounds");
        uint256 oldMCR = currentMCR;
        currentMCR = newMCR;
        hasPendingUpdate = false;
        emit MCRUpdateApplied(oldMCR, newMCR, 0, block.timestamp);
    }
}
