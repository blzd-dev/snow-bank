// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IStakingRewards {
    // Views
    function lastTimeRewardApplicable(uint256 rewardId) external view returns (uint256);

    function rewardPerToken(uint256 rewardId) external view returns (uint256);

    function earned(address account,uint256 rewardId) external view returns (uint256);

    function getRewardForDuration(uint256 rewardId) external view returns (uint256);

    function totalSupply() external view returns (uint256);

    function balanceOf(address account) external view returns (uint256);

    // Mutative

    function stake(uint256 amount) external ;

    function withdraw(uint256 amount) external ;

    function getReward(uint256 rewardId) external;

    function exit(uint256 amount) external;

    function getAllReward() external;

}
