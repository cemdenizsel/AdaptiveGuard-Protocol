// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/IAdaptiveMCR.sol";
import "./interfaces/IMezoCDP.sol";
import "./interfaces/IBorrowerOperations.sol";
import "./interfaces/ITroveManager.sol";
import "./interfaces/IStabilityPool.sol";
import "./interfaces/IHintHelpers.sol";
import "./interfaces/ISortedTroves.sol";

/**
 * @title MezoIntegrationAdapter
 * @notice Bridge between AdaptiveGuard Protocol and the Mezo CDP / MUSD system.
 *
 * Responsibilities:
 *   1. Expose position health checks using the adaptive MCR from AdaptiveMCREngine
 *   2. Provide a batch liquidation trigger that respects the current MCR
 *   3. Track system-level stats (TCR, SP depth) that feed back into MCR computation
 *   4. Serve as the entry point for the frontend and off-chain service
 *
 * Design notes:
 *   - The adapter does NOT hold funds; it is a pure coordinator.
 *   - When Mezo testnet CDP contracts are unavailable, a mock mode is used
 *     (isSimulated = true) that tracks positions in local storage for demo purposes.
 *   - In production mode, all calls are forwarded to the live Mezo CDP contract.
 */
contract MezoIntegrationAdapter is AccessControl, Pausable, ReentrancyGuard {

    // ─── Roles ────────────────────────────────────────────────────────────────
    bytes32 public constant LIQUIDATOR_ROLE = keccak256("LIQUIDATOR_ROLE");
    bytes32 public constant DAO_ROLE        = keccak256("DAO_ROLE");
    bytes32 public constant GUARDIAN_ROLE   = keccak256("GUARDIAN_ROLE");

    // ─── Precision ────────────────────────────────────────────────────────────
    uint256 public constant PRECISION = 1e18;

    // ─── External Contracts ───────────────────────────────────────────────────
    IAdaptiveMCR   public mcrEngine;
    IMezoCDP       public mezoCDP;         // address(0) when simulated
    IMezoPriceFeed public mezoPriceFeed;   // Mezo BTC/USD price feed (optional)

    bool public isSimulated;  // true = demo/testnet mode with local CDP tracking

    // ─── Live Mezo contract references (set via setMezoContracts) ─────────────
    ITroveManager  public troveManager;
    IStabilityPool public stabilityPool;
    IHintHelpers   public hintHelpers;
    ISortedTroves  public sortedTroves;

    // ─── Simulated CDP Storage (used when isSimulated = true) ─────────────────
    struct SimulatedTrove {
        uint256 collateralBTC18;  // BTC collateral in 1e18
        uint256 debtMUSD18;       // MUSD debt in 1e18
        bool    active;
    }
    mapping(address => SimulatedTrove) public simulatedTroves;
    address[] public troveOwners;
    uint256 public simulatedBTCPrice;    // USD price in 1e18
    uint256 public simulatedSPBalance;   // MUSD in Stability Pool (1e18)
    uint256 public totalSimulatedDebt;   // total MUSD borrowed (1e18)

    // ─── Events ───────────────────────────────────────────────────────────────
    event TroveOpened(address indexed owner, uint256 collateral, uint256 debt, uint256 cr);
    event TroveClosed(address indexed owner);
    event TroveLiquidated(address indexed owner, uint256 debt, uint256 collateral, bool hadBadDebt);
    event CollateralAdded(address indexed owner, uint256 added, uint256 newCR);
    event DebtRepaid(address indexed owner, uint256 repaid, uint256 remaining);
    event PriceUpdated(uint256 newPrice);
    event SPDeposit(address indexed depositor, uint256 amount);
    event SystemSnapshot(uint256 tcr, uint256 spDepth, uint256 currentMCR);

    // ─── Constructor ──────────────────────────────────────────────────────────
    constructor(
        address _mcrEngine,
        address _mezoCDP,      // pass address(0) for simulated mode
        address _dao
    ) {
        mcrEngine = IAdaptiveMCR(_mcrEngine);
        isSimulated = (_mezoCDP == address(0));
        if (!isSimulated) {
            mezoCDP = IMezoCDP(_mezoCDP);
        }

        _grantRole(DEFAULT_ADMIN_ROLE, _dao);
        _grantRole(DAO_ROLE, _dao);
        _grantRole(GUARDIAN_ROLE, _dao);
        _grantRole(LIQUIDATOR_ROLE, _dao);

        // Reasonable testnet defaults
        simulatedBTCPrice  = 30_000e18;
        simulatedSPBalance = 1_500_000e18;  // 1.5M MUSD
    }

    function isLive() public view returns (bool) {
        return address(troveManager) != address(0);
    }

    // ─── Position Health ──────────────────────────────────────────────────────

    /**
     * @notice Check whether a position is safe under the current adaptive MCR.
     * @return safe        True if CR ≥ current MCR
     * @return currentCR   The position's collateral ratio (1e18 precision)
     * @return requiredMCR The current MCR threshold (1e18 precision)
     * @return riskLevel   0=safe, 1=warning(<MCR+10%), 2=at_risk(<MCR+5%), 3=liquidatable
     */
    function checkPositionHealth(address owner)
        external
        view
        returns (bool safe, uint256 currentCR, uint256 requiredMCR, uint8 riskLevel)
    {
        (uint256 collUSD, uint256 debtUSD) = _getPosition(owner);
        (safe, currentCR, requiredMCR) = mcrEngine.isPositionSafe(collUSD, debtUSD);

        if (debtUSD == 0) return (true, type(uint256).max, requiredMCR, 0);

        if (!safe) {
            riskLevel = 3; // liquidatable
        } else if (currentCR < requiredMCR + 10e16) {
            riskLevel = 2; // at_risk (<MCR+10%)
        } else if (currentCR < requiredMCR + 20e16) {
            riskLevel = 1; // warning (<MCR+20%)
        } else {
            riskLevel = 0; // safe
        }
    }

    /**
     * @notice Batch-check multiple positions and return those eligible for liquidation.
     */
    function findLiquidatable(address[] calldata owners)
        external
        view
        returns (address[] memory liquidatable, uint256 count)
    {
        liquidatable = new address[](owners.length);
        count = 0;
        uint256 mcr = mcrEngine.currentMCR();

        for (uint256 i = 0; i < owners.length; i++) {
            (uint256 collUSD, uint256 debtUSD) = _getPosition(owners[i]);
            if (debtUSD == 0) continue;
            uint256 cr = collUSD * PRECISION / debtUSD;
            if (cr < mcr) {
                liquidatable[count++] = owners[i];
            }
        }
    }

    // ─── System Stats ─────────────────────────────────────────────────────────

    /**
     * @notice Returns system-wide stats needed by AdaptiveMCREngine for composite MCR.
     * @return tcrBPS     Total Collateral Ratio in BPS (e.g. 15000 = 150%)
     * @return spDepthBPS SP balance as fraction of total debt, in BPS
     * @return btcPriceBPS BTC price in BPS-compatible format
     */
    function getSystemStats()
        external
        view
        returns (uint256 tcrBPS, uint256 spDepthBPS, uint256 btcPriceBPS)
    {
        if (isLive()) {
            uint256 price = simulatedBTCPrice; // cached; update via updateBTCPrice() or setSimulatedBTCPrice()
            uint256 tcr  = troveManager.getTCR(price);
            uint256 debt = troveManager.getEntireSystemDebt();
            uint256 spBal = stabilityPool.getTotalMUSDDeposits();
            tcrBPS      = tcr * 10000 / PRECISION;
            spDepthBPS  = debt > 0 ? spBal * 10000 / debt : 10000;
            btcPriceBPS = price / 1e18;
            return (tcrBPS, spDepthBPS, btcPriceBPS);
        }
        return _simulatedStats();
    }

    function _simulatedStats() internal view returns (uint256 tcrBPS, uint256 spDepthBPS, uint256 btcPriceBPS) {
        uint256 totalCollUSD;
        for (uint256 i = 0; i < troveOwners.length; i++) {
            SimulatedTrove storage t = simulatedTroves[troveOwners[i]];
            if (t.active) {
                totalCollUSD += t.collateralBTC18 * simulatedBTCPrice / 1e18;
            }
        }
        uint256 debt = totalSimulatedDebt > 0 ? totalSimulatedDebt : 1;
        uint256 tcr  = totalCollUSD * PRECISION / debt;

        tcrBPS      = tcr * 10000 / PRECISION;
        spDepthBPS  = simulatedSPBalance * 10000 / debt;
        btcPriceBPS = simulatedBTCPrice / 1e18;        // 1e18 precision → raw USD integer
    }

    // ─── Simulated CDP Operations (demo / testnet) ────────────────────────────

    /**
     * @notice Open a simulated trove (testnet demo).
     * @param collateralBTC18  BTC collateral amount in 1e18
     * @param debtMUSD18       MUSD to borrow in 1e18
     */
    function openSimulatedTrove(uint256 collateralBTC18, uint256 debtMUSD18)
        external
        whenNotPaused
    {
        require(isSimulated, "Adapter: not in simulated mode");
        require(!simulatedTroves[msg.sender].active, "Adapter: trove exists");
        require(collateralBTC18 > 0 && debtMUSD18 > 0, "Adapter: invalid amounts");

        uint256 collUSD = collateralBTC18 * simulatedBTCPrice / 1e18;
        uint256 cr = collUSD * PRECISION / debtMUSD18;
        require(cr >= mcrEngine.currentMCR(), "Adapter: below MCR");

        simulatedTroves[msg.sender] = SimulatedTrove({
            collateralBTC18: collateralBTC18,
            debtMUSD18: debtMUSD18,
            active: true
        });
        troveOwners.push(msg.sender);
        totalSimulatedDebt += debtMUSD18;

        emit TroveOpened(msg.sender, collateralBTC18, debtMUSD18, cr);
    }

    /**
     * @notice Add collateral to an existing simulated trove.
     */
    function addSimulatedCollateral(uint256 extraBTC18) external whenNotPaused {
        require(isSimulated, "Adapter: not simulated");
        SimulatedTrove storage t = simulatedTroves[msg.sender];
        require(t.active, "Adapter: no active trove");

        t.collateralBTC18 += extraBTC18;
        uint256 newCR = (t.collateralBTC18 * simulatedBTCPrice / 1e18) * PRECISION / t.debtMUSD18;
        emit CollateralAdded(msg.sender, extraBTC18, newCR);
    }

    /**
     * @notice Repay MUSD debt.
     */
    function repaySimulatedDebt(uint256 repayAmount) external whenNotPaused {
        require(isSimulated, "Adapter: not simulated");
        SimulatedTrove storage t = simulatedTroves[msg.sender];
        require(t.active, "Adapter: no active trove");
        require(repayAmount <= t.debtMUSD18, "Adapter: repay > debt");

        t.debtMUSD18       -= repayAmount;
        totalSimulatedDebt -= repayAmount;
        if (t.debtMUSD18 == 0) {
            t.active = false;
        }
        emit DebtRepaid(msg.sender, repayAmount, t.debtMUSD18);
    }

    /**
     * @notice Close a simulated trove (repay all debt).
     */
    function closeSimulatedTrove() external whenNotPaused {
        require(isSimulated, "Adapter: not simulated");
        SimulatedTrove storage t = simulatedTroves[msg.sender];
        require(t.active, "Adapter: no active trove");

        totalSimulatedDebt -= t.debtMUSD18;
        t.active = false;
        emit TroveClosed(msg.sender);
    }

    /**
     * @notice Liquidate an undercollateralized simulated trove.
     */
    function liquidateSimulated(address owner) external nonReentrant whenNotPaused {
        require(isSimulated, "Adapter: not simulated");
        SimulatedTrove storage t = simulatedTroves[owner];
        require(t.active, "Adapter: trove not active");

        uint256 collUSD = t.collateralBTC18 * simulatedBTCPrice / 1e18;
        uint256 cr = collUSD * PRECISION / t.debtMUSD18;
        require(cr < mcrEngine.currentMCR(), "Adapter: trove is safe");

        uint256 debt = t.debtMUSD18;
        uint256 coll = t.collateralBTC18;

        // SP absorbs what it can
        bool hadBadDebt = false;
        if (simulatedSPBalance >= debt) {
            simulatedSPBalance -= debt;
        } else {
            hadBadDebt = true;
            simulatedSPBalance = 0;
        }

        totalSimulatedDebt -= debt;
        t.active = false;

        emit TroveLiquidated(owner, debt, coll, hadBadDebt);
    }

    /**
     * @notice Batch liquidate all eligible troves.
     */
    function batchLiquidate(address[] calldata owners)
        external
        nonReentrant
        whenNotPaused
    {
        require(isSimulated, "Adapter: not simulated");
        for (uint256 i = 0; i < owners.length; i++) {
            SimulatedTrove storage t = simulatedTroves[owners[i]];
            if (!t.active || t.debtMUSD18 == 0) continue;
            uint256 collUSD = t.collateralBTC18 * simulatedBTCPrice / 1e18;
            uint256 cr = collUSD * PRECISION / t.debtMUSD18;
            if (cr < mcrEngine.currentMCR()) {
                // inline liquidation
                if (simulatedSPBalance >= t.debtMUSD18) {
                    simulatedSPBalance -= t.debtMUSD18;
                } else {
                    simulatedSPBalance = 0;
                }
                totalSimulatedDebt -= t.debtMUSD18;
                emit TroveLiquidated(owners[i], t.debtMUSD18, t.collateralBTC18, simulatedSPBalance == 0);
                t.active = false;
            }
        }
    }

    // ─── Simulated SP Deposit ─────────────────────────────────────────────────

    function depositToSP(uint256 musdAmount) external whenNotPaused {
        require(isSimulated, "Adapter: not simulated");
        simulatedSPBalance += musdAmount;
        emit SPDeposit(msg.sender, musdAmount);
    }

    // ─── Price Feed (admin) ───────────────────────────────────────────────────

    function setSimulatedBTCPrice(uint256 price18) external onlyRole(DAO_ROLE) {
        simulatedBTCPrice = price18;
        emit PriceUpdated(price18);
    }

    function setMezoPriceFeed(address _feed) external onlyRole(DAO_ROLE) {
        mezoPriceFeed = IMezoPriceFeed(_feed);
    }

    function setMezoContracts(
        address _troveManager,
        address _stabilityPool,
        address _hintHelpers,
        address _sortedTroves,
        address _priceFeed
    ) external onlyRole(DAO_ROLE) {
        troveManager  = ITroveManager(_troveManager);
        stabilityPool = IStabilityPool(_stabilityPool);
        hintHelpers   = IHintHelpers(_hintHelpers);
        sortedTroves  = ISortedTroves(_sortedTroves);
        if (_priceFeed != address(0)) {
            mezoPriceFeed = IMezoPriceFeed(_priceFeed);
        }
    }

    function getMezoPrice() external view returns (uint256) {
        return simulatedBTCPrice;
    }

    function getRealTrove(address owner) external view returns (
        uint256 coll, uint256 debt, uint256 status, uint256 icr
    ) {
        require(isLive(), "Adapter: not in live mode");
        coll   = troveManager.getTroveColl(owner);
        debt   = troveManager.getTroveDebt(owner);
        status = troveManager.getTroveStatus(owner);
        icr    = simulatedBTCPrice > 0
            ? troveManager.getCurrentICR(owner, simulatedBTCPrice)
            : 0;
    }

    /**
     * @notice Pull the current BTC price from Mezo's PriceFeed and store it.
     * Anyone can call this to keep simulatedBTCPrice fresh on testnet.
     */
    function updateBTCPrice() external {
        require(address(mezoPriceFeed) != address(0), "Adapter: no price feed set");
        uint256 newPrice = mezoPriceFeed.fetchPrice();
        require(newPrice > 0, "Adapter: invalid price from feed");
        simulatedBTCPrice = newPrice;
        emit PriceUpdated(newPrice);
    }

    // ─── View: all active trove owners ───────────────────────────────────────

    function getActiveTroveOwners() external view returns (address[] memory active) {
        uint256 cnt;
        for (uint256 i = 0; i < troveOwners.length; i++) {
            if (simulatedTroves[troveOwners[i]].active) cnt++;
        }
        active = new address[](cnt);
        uint256 j;
        for (uint256 i = 0; i < troveOwners.length; i++) {
            if (simulatedTroves[troveOwners[i]].active) active[j++] = troveOwners[i];
        }
    }

    function getTrove(address owner) external view returns (SimulatedTrove memory) {
        return simulatedTroves[owner];
    }

    // ─── Governance ───────────────────────────────────────────────────────────

    function setMCREngine(address _engine) external onlyRole(DAO_ROLE) {
        mcrEngine = IAdaptiveMCR(_engine);
    }

    function pause()   external onlyRole(GUARDIAN_ROLE) { _pause(); }
    function unpause() external onlyRole(DAO_ROLE)      { _unpause(); }

    // ─── Internals ────────────────────────────────────────────────────────────

    function _getPosition(address owner)
        internal
        view
        returns (uint256 collUSD, uint256 debtUSD)
    {
        if (isLive()) {
            uint256 status = troveManager.getTroveStatus(owner);
            if (status != 1) return (0, 0); // not active
            uint256 coll  = troveManager.getTroveColl(owner);
            uint256 debt  = troveManager.getTroveDebt(owner);
            uint256 price = simulatedBTCPrice;
            collUSD = coll * price / 1e18;
            debtUSD = debt;
            return (collUSD, debtUSD);
        }
        // Simulated mode
        SimulatedTrove storage t = simulatedTroves[owner];
        if (!t.active) return (0, 0);
        collUSD = t.collateralBTC18 * simulatedBTCPrice / 1e18;
        debtUSD = t.debtMUSD18;
    }

    function _getPrice() internal view returns (uint256) {
        return simulatedBTCPrice;  // updated via setSimulatedBTCPrice() or updateBTCPrice()
    }
}

interface IMezoPriceFeed {
    function fetchPrice() external returns (uint256);
}
