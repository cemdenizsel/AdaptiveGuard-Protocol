// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
interface IBorrowerOperations {
    function openTrove(uint256 _maxFeePercentage, uint256 _MUSDAmount, address _upperHint, address _lowerHint) external payable;
    function addColl(address _upperHint, address _lowerHint) external payable;
    function withdrawColl(uint256 _amount, address _upperHint, address _lowerHint) external;
    function withdrawMUSD(uint256 _maxFeePercentage, uint256 _amount, address _upperHint, address _lowerHint) external;
    function repayMUSD(uint256 _amount, address _upperHint, address _lowerHint) external;
    function closeTrove() external;
    function stabilityPoolAddress() external view returns (address);
}
