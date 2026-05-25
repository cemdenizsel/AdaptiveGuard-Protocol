// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;
interface IHintHelpers {
    function getApproxHint(uint256 _CR, uint256 _numTrials, uint256 _inputRandomSeed) external view returns (address hintAddress, uint256 diff, uint256 latestRandomSeed);
    function computeNominalCR(uint256 _coll, uint256 _debt) external pure returns (uint256);
}
