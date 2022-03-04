// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./interfaces/IfNFTStakingDistributor.sol";
import "./types/RenaissanceAccessControlled.sol";

contract RenaissanceFNFTDistributorProxy is RenaissanceAccessControlled {
    /* ========== DEPENDENCIES ========== */

    event StakingDistributorSet(address distributor);

    IfNFTStakingDistributor public stakingDistributor;    

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _stakingDistributor,
        address _authority
    ) RenaissanceAccessControlled(IRenaissanceAuthority(_authority)) {
        require(_stakingDistributor != address(0), "Zero address: _stakingDistributor");        
        stakingDistributor = IfNFTStakingDistributor(_stakingDistributor);
    }

    /**
     * @notice trigger rebase if epoch over
     * @return uint256
     */
    function rebase(address _fNFT) public {
        require(stakingDistributor != address(0), "Zero address: _stakingDistributor");
        stakingDistributor.rebase(_fNFT);
    }

    /* ========== MANAGERIAL FUNCTIONS ========== */

    function setStakingDistributor(address _stakingDistributor) external onlyGovernor {
        stakingDistributor = IfNFTStakingDistributor(_stakingDistributor);
        emit StakingDistributorSet(_stakingDistributor);
    }
}
