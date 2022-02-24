// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

interface IfNFTStakingDistributor {
    function rebase() external;
    function contractBalance() external view returns (uint256);
}
