// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
interface IStabilityPool {
    function provideToSP(uint256 _amount, address _frontEndTag) external;
    function withdrawFromSP(uint256 _amount) external;
    function getCompoundedMUSDDeposit(address _depositor) external view returns (uint256);
    function getTotalMUSDDeposits() external view returns (uint256);
}
