//SPDX-License-Identifier: MIT
pragma solidity 0.8.11;

import "ds-test/test.sol";
import {FNFTStaking} from "../contracts/fNFTStaking.sol";
import {IERC20} from "../contracts/interfaces/IERC20.sol"; 
import {IRenaissanceAuthority} from "../contracts/interfaces/IRenaissanceAuthority.sol";
import {ITreasury} from "../contracts/interfaces/ITreasury.sol";
import {CheatCodes} from "./utils/CheatCodes.sol";

contract testfNFTStaking is DSTest { 
    CheatCodes public cheats = CheatCodes(HEVM_ADDRESS);       
    FNFTStaking public fnftStking;
    
    /**
    CONSTANTS
     */
    address constant TREASURY_ADDRESS = address(0);
    address constant ART_ADDRESS = address(0);
    address constant RENAI_AUTHORITY_ADDRESS = address(0);

    constructor() {
        uint256 requiredSArtPerShare = 10;
        uint256 artPerBlock = 10;
        uint256 startBlock = 0;

        fnftStking = new FNFTStaking(TREASURY_ADDRESS, ART_ADDRESS, RENAI_AUTHORITY_ADDRESS, requiredSArtPerShare, artPerBlock, startBlock);
    }

    function setUp() public {}

    function testAddStakingPool() public {}

    function testSetAllocPoint() public {}

    function testGetMultiplier() public {}

    function testPendingArt() public {}

    function testDeposit() public {}

    function testWithdraw() public {}

    function testEmergencyWithdraw() public {}

    function testHarvest() public {}

    function testSetMigrator() public {}

    function testUpdateArtPerBlock() public {}

    function testUpdateMultiplier() public {}

    function testMigrate() public {}
}