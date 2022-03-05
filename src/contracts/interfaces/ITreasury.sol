// SPDX-License-Identifier: AGPL-3.0
pragma solidity >=0.7.5;

interface ITreasury {
    function mintRewards( address _recipient, uint _amount ) external;
}