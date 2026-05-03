// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IVolatilityOracle {
    /// @notice Returns the latest accepted annualized volatility in BPS (e.g. 4500 = 45%)
    function getVolatility() external view returns (uint256 volBPS, uint256 updatedAt);

    /// @notice Returns true when the oracle data is fresh (within heartbeat)
    function isHealthy() external view returns (bool);
}
