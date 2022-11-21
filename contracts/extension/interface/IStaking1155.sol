// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

interface IStaking1155 {
    /// @dev Emitted when tokens are staked.
    event TokensStaked(address indexed staker, uint256 indexed tokenId, uint256 amount);

    /// @dev Emitted when a set of staked token-ids are withdrawn.
    event TokensWithdrawn(address indexed staker, uint256 indexed tokenId, uint256 amount);

    /// @dev Emitted when a staker claims staking rewards.
    event RewardsClaimed(address indexed staker, uint256 rewardAmount);

    /// @dev Emitted when contract admin updates timeUnit.
    event UpdatedTimeUnit(uint256 _tokenId, uint256 oldTimeUnit, uint256 newTimeUnit);

    /// @dev Emitted when contract admin updates rewardsPerUnitTime.
    event UpdatedRewardsPerUnitTime(uint256 _tokenId, uint256 oldRewardsPerUnitTime, uint256 newRewardsPerUnitTime);

    /// @dev Emitted when contract admin updates timeUnit.
    event UpdatedDefaultTimeUnit(uint256 oldTimeUnit, uint256 newTimeUnit);

    /// @dev Emitted when contract admin updates rewardsPerUnitTime.
    event UpdatedDefaultRewardsPerUnitTime(uint256 oldRewardsPerUnitTime, uint256 newRewardsPerUnitTime);

    /**
     *  @notice Staker Info.
     *
     *  @param amountStaked         Total number of tokens staked by the staker.
     *
     *  @param timeOfLastUpdate     Last reward-update timestamp.
     *
     *  @param unclaimedRewards     Rewards accumulated but not claimed by user yet.
     */
    struct Staker {
        uint256 amountStaked;
        uint256 timeOfLastUpdate;
        uint256 unclaimedRewards;
    }

    /**
     *  @notice Stake ERC721 Tokens.
     *
     *  @param tokenId   ERC1155 token-id to stake.
     *  @param amount    Amount to stake.
     */
    function stake(uint256 tokenId, uint256 amount) external;

    /**
     *  @notice Withdraw staked tokens.
     *
     *  @param tokenId   ERC1155 token-id to withdraw.
     *  @param amount    Amount to withdraw.
     */
    function withdraw(uint256 tokenId, uint256 amount) external;

    /**
     *  @notice Claim accumulated rewards.
     *
     *  @param tokenId   Staked token Id.
     */
    function claimRewards(uint256 tokenId) external;

    /**
     *  @notice View amount staked and total rewards for a user.
     *
     *  @param staker    Address for which to calculated rewards.
     *  @param tokenId   Staked token Id.
     */
    function getStakeInfo(uint256 tokenId, address staker)
        external
        view
        returns (uint256 _tokensStaked, uint256 _rewards);
}
