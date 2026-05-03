// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IAdaptiveMCR {
    /// @notice Returns the current active MCR in 1e18 precision (e.g. 110e16 = 110%)
    function currentMCR() external view returns (uint256);

    /// @notice Returns MCR that would apply at a given volatility (no rate-limiting)
    function computeMCRFromVol(uint256 volBPS) external view returns (uint256);

    /// @notice Returns whether a position is safe at the current MCR
    function isPositionSafe(uint256 collateralUSD, uint256 debtUSD)
        external
        view
        returns (bool safe, uint256 currentCR, uint256 requiredMCR);
}
