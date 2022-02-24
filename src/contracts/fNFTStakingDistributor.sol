// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.7.5;

import "./libraries/SafeMath.sol";
import "./libraries/SafeERC20.sol";

import "./interfaces/IERC20.sol";
import "./interfaces/IDistributor.sol";
import "./interfaces/IfNFTMasterchef.sol";

import "./types/RenaissanceAccessControlled.sol";

contract RenaissanceFNFTStakingDistributor is RenaissanceAccessControlled {
    /* ========== DEPENDENCIES ========== */

    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== EVENTS ========== */

    event DistributorSet(address distributor);

    /* ========== DATA STRUCTURES ========== */

    struct Epoch {
        uint256 length; // in seconds
        uint256 number; // since inception
        uint256 end; // timestamp
        uint256 distribute; // amount
    }
    /* ========== STATE VARIABLES ========== */

    IERC20 public immutable ART;

    Epoch public epoch;

    IDistributor public distributor;
    IfNFTMasterchef public fNFTMasterchef;

    /* ========== CONSTRUCTOR ========== */

    constructor(
        address _art,
        uint256 _epochLength,
        uint256 _firstEpochNumber,
        uint256 _firstEpochTime,
        address _authority
    ) RenaissanceAccessControlled(IRenaissanceAuthority(_authority)) {
        require(_art != address(0), "Zero address: ART");
        ART = IERC20(_art);
            
        epoch = Epoch({length: _epochLength, number: _firstEpochNumber, end: _firstEpochTime, distribute: 0});
    }

    /**
     * @notice trigger rebase if epoch over
     * @return uint256
     */
    function rebase() public {
        require(fNFTMasterchef != address(0), "Zero address: fNFTMasterchef");                
        if( epoch.endBlock <= block.number ) {
            epoch.endBlock = epoch.endBlock.add( epoch.length );
            epoch.number++;

            IERC20(ART).safeTransferFrom(fNFTMasterchef, address(this), epoch.distribute);
            
            if ( distributor != address(0) ) {
                IDistributor( distributor ).distribute();
            }
            
            epoch.distribute = 0;
        }
    }

    /**
     * @notice seconds until the next epoch begins
     */
    function secondsToNextEpoch() external view returns (uint256) {
        return epoch.end.sub(block.timestamp);
    }

    /* ========== MANAGERIAL FUNCTIONS ========== */

    /**
     * @notice sets the contract address for LP staking
     * @param _distributor address
     */
    function setDistributor(address _distributor) external onlyGovernor {
        distributor = IDistributor(_distributor);
        emit DistributorSet(_distributor);
    }

    function setFNFTMasterchef(address _fNFTMasterchef) external onlyGovernor {
        fNFTMasterchef = IfNFTMasterchef(_fNFTMasterchef);
        emit MasterchefSet(_fNFTMasterchef);
    }

    function contractBalance() public view returns ( uint ) {
        return IERC20( ART ).balanceOf( address(this) );
    }
}
