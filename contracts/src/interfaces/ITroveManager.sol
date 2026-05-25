// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
interface ITroveManager {
    function getTroveDebt(address _borrower) external view returns (uint256);
    function getTroveColl(address _borrower) external view returns (uint256);
    function getTroveStatus(address _borrower) external view returns (uint256);
    function getCurrentICR(address _borrower, uint256 _price) external view returns (uint256);
    function getTCR(uint256 _price) external view returns (uint256);
    function getEntireSystemDebt() external view returns (uint256);
    function getEntireSystemColl() external view returns (uint256);
}
