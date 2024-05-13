// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/// @author thirdweb

import "./IClaimCondition.sol";

/**
 *  The interface `IClaimConditionMultiPhase` is written for thirdweb's 'Drop' contracts, which are distribution mechanisms for tokens.
 *
 *  An authorized wallet can set a series of claim conditions, ordered by their respective `startTimestamp`.
 *  A claim condition defines criteria under which accounts can mint tokens. Claim conditions can be overwritten
 *  or added to by the contract admin. At any moment, there is only one active claim condition.
 */

interface IClaimConditionMultiPhase is IClaimCondition {
    /**
     *  @notice The set of all claim conditions, at any given moment.
     *  Claim Phase ID = [currentStartId, currentStartId + length - 1];
     *
     *  @param currentStartId           The uid for the first claim condition amongst the current set of
     *                                  claim conditions. The uid for each next claim condition is one
     *                                  more than the previous claim condition's uid.
     *
     *  @param count                    The total number of phases / claim conditions in the list
     *                                  of claim conditions.
     *
     * @param conditionHash             Mapping from numeric claim condition ID to a unique hash.
     *                                  Used in supplyClaimedByWallet mapping below.
     *
     *  @param conditions                   The claim conditions at a given uid. Claim conditions
     *                                  are ordered in an ascending order by their `startTimestamp`.
     *
     *  @param supplyClaimedByWallet    Map from a claim condition uid/hash and account to supply claimed by account.
     */
    struct ClaimConditionList {
        uint256 currentStartId;
        uint256 count;
        mapping(uint256 => bytes32) conditionHash;
        mapping(uint256 => ClaimCondition) conditions;
        mapping(bytes32 => mapping(address => uint256)) supplyClaimedByWallet;
    }
}
