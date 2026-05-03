// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal interface for Mezo CDP / MUSD borrowing system.
/// Real addresses resolved at deployment time via MezoIntegrationAdapter.
interface IMezoCDP {
    struct TroveData {
        uint256 collateral;  // BTC collateral in 1e18
        uint256 debt;        // MUSD debt in 1e18
        uint8   status;      // 0=nonExistent, 1=active, 2=closed, 3=liquidated
    }

    function getTrove(address owner) external view returns (TroveData memory);

    function openTrove(
        uint256 collateralAmount,
        uint256 musdAmount,
        address upperHint,
        address lowerHint
    ) external payable;

    function closeTrove() external;

    function addCollateral(address upperHint, address lowerHint) external payable;

    function withdrawCollateral(
        uint256 amount,
        address upperHint,
        address lowerHint
    ) external;

    function repayMUSD(uint256 amount, address upperHint, address lowerHint) external;

    function liquidate(address borrower) external;

    function getTCR(uint256 price) external view returns (uint256);

    function getStabilityPoolBalance() external view returns (uint256);

    function getTotalDebt() external view returns (uint256);
}
