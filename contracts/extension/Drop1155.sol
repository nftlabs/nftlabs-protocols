// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/// @author thirdweb

import "./interface/IDrop1155.sol";
import "../lib/MerkleProof.sol";

abstract contract Drop1155 is IDrop1155 {
    /// @dev The sender is not authorized to perform the action
    error DropUnauthorized();

    /// @dev Exceeded the max token total supply
    error DropExceedMaxSupply();

    /// @dev No active claim condition
    error DropNoActiveCondition();

    /// @dev Claim condition invalid currency or price
    error DropClaimInvalidTokenPrice(
        address expectedCurrency,
        uint256 expectedPricePerToken,
        address actualCurrency,
        uint256 actualExpectedPricePerToken
    );

    /// @dev Claim condition exceeded limit
    error DropClaimExceedLimit(uint256 expected, uint256 actual);

    /// @dev Claim condition exceeded max supply
    error DropClaimExceedMaxSupply(uint256 expected, uint256 actual);

    /// @dev Claim condition not started yet
    error DropClaimNotStarted(uint256 expected, uint256 actual);

    /*///////////////////////////////////////////////////////////////
                            State variables
    //////////////////////////////////////////////////////////////*/

    /// @dev Mapping from token ID => the set of all claim conditions, at any given moment, for tokens of the token ID.
    mapping(uint256 => ClaimConditionList) public claimCondition;

    /*///////////////////////////////////////////////////////////////
                            Drop logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Lets an account claim tokens.
    function claim(
        address _receiver,
        uint256 _tokenId,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        AllowlistProof calldata _allowlistProof,
        bytes memory _data
    ) public payable virtual override {
        _beforeClaim(_tokenId, _receiver, _quantity, _currency, _pricePerToken, _allowlistProof, _data);

        uint256 activeConditionId = getActiveClaimConditionId(_tokenId);

        verifyClaim(
            activeConditionId,
            _dropMsgSender(),
            _tokenId,
            _quantity,
            _currency,
            _pricePerToken,
            _allowlistProof
        );

        // Update contract state.
        bytes32 activeConditionHash = claimCondition[_tokenId].conditionHash[activeConditionId];
        claimCondition[_tokenId].conditions[activeConditionId].supplyClaimed += _quantity;
        claimCondition[_tokenId].supplyClaimedByWallet[activeConditionHash][_dropMsgSender()] += _quantity;

        // If there's a price, collect price.
        collectPriceOnClaim(_tokenId, address(0), _quantity, _currency, _pricePerToken);

        // Mint the relevant NFTs to claimer.
        transferTokensOnClaim(_receiver, _tokenId, _quantity);

        emit TokensClaimed(activeConditionId, _dropMsgSender(), _receiver, _tokenId, _quantity);

        _afterClaim(_tokenId, _receiver, _quantity, _currency, _pricePerToken, _allowlistProof, _data);
    }

    /// @dev Lets a contract admin set claim conditions.
    function setClaimConditions(
        uint256 _tokenId,
        ClaimCondition[] calldata _conditions,
        bool _resetClaimEligibility
    ) external virtual override {
        if (!_canSetClaimConditions()) {
            revert DropUnauthorized();
        }
        ClaimConditionList storage conditionList = claimCondition[_tokenId];
        uint256 existingStartIndex = conditionList.currentStartId;
        uint256 existingPhaseCount = conditionList.count;

        /**
         *  The mapping `supplyClaimedByWallet` uses a claim condition's UID as a key.
         *
         *  If `_resetClaimEligibility == true`, we assign completely new UIDs to the claim
         *  conditions in `_conditions`, effectively resetting the restrictions on claims expressed
         *  by `supplyClaimedByWallet`.
         */
        uint256 newStartIndex = existingStartIndex;
        if (_resetClaimEligibility) {
            newStartIndex = existingStartIndex + existingPhaseCount;
        }

        conditionList.count = _conditions.length;
        conditionList.currentStartId = newStartIndex;

        uint256 lastConditionStartTimestamp;
        for (uint256 i = 0; i < _conditions.length; i++) {
            require(i == 0 || lastConditionStartTimestamp < _conditions[i].startTimestamp, "ST");

            uint256 supplyClaimedAlready = conditionList.conditions[newStartIndex + i].supplyClaimed;
            if (supplyClaimedAlready > _conditions[i].maxClaimableSupply) {
                revert DropExceedMaxSupply();
            }

            conditionList.conditions[newStartIndex + i] = _conditions[i];
            conditionList.conditions[newStartIndex + i].supplyClaimed = supplyClaimedAlready;

            bytes32 _conditionHash = conditionList.conditionHash[newStartIndex + i];
            if (_resetClaimEligibility || _conditionHash == bytes32(0)) {
                conditionList.conditionHash[newStartIndex + i] = keccak256(
                    abi.encodePacked((newStartIndex + i), block.number)
                );
            }

            lastConditionStartTimestamp = _conditions[i].startTimestamp;
        }

        /**
         *  Gas refunds (as much as possible)
         *
         *  If `_resetClaimEligibility == true`, we assign completely new UIDs to the claim
         *  conditions in `_conditions`. So, we delete claim conditions with UID < `newStartIndex`.
         *
         *  If `_resetClaimEligibility == false`, and there are more existing claim conditions
         *  than in `_conditions`, we delete the existing claim conditions that don't get replaced
         *  by the conditions in `_conditions`.
         */
        if (_resetClaimEligibility) {
            for (uint256 i = existingStartIndex; i < newStartIndex; i++) {
                delete conditionList.conditions[i];
                delete conditionList.conditionHash[i];
            }
        } else {
            if (existingPhaseCount > _conditions.length) {
                for (uint256 i = _conditions.length; i < existingPhaseCount; i++) {
                    delete conditionList.conditions[newStartIndex + i];
                    delete conditionList.conditionHash[newStartIndex + i];
                }
            }
        }

        emit ClaimConditionsUpdated(_tokenId, _conditions, _resetClaimEligibility);
    }

    /// @dev Checks a request to claim NFTs against the active claim condition's criteria.
    function verifyClaim(
        uint256 _conditionId,
        address _claimer,
        uint256 _tokenId,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        AllowlistProof calldata _allowlistProof
    ) public view virtual returns (bool isOverride) {
        ClaimCondition memory currentClaimPhase = claimCondition[_tokenId].conditions[_conditionId];
        bytes32 activeConditionHash = claimCondition[_tokenId].conditionHash[_conditionId];
        uint256 claimLimit = currentClaimPhase.quantityLimitPerWallet;
        uint256 claimPrice = currentClaimPhase.pricePerToken;
        address claimCurrency = currentClaimPhase.currency;

        /*
         * Here `isOverride` implies that if the merkle proof verification fails,
         * the claimer would claim through open claim limit instead of allowlisted limit.
         */
        if (currentClaimPhase.merkleRoot != bytes32(0)) {
            (isOverride, ) = MerkleProof.verify(
                _allowlistProof.proof,
                currentClaimPhase.merkleRoot,
                keccak256(
                    abi.encodePacked(
                        _claimer,
                        _allowlistProof.quantityLimitPerWallet,
                        _allowlistProof.pricePerToken,
                        _allowlistProof.currency
                    )
                )
            );
        }

        if (isOverride) {
            claimLimit = _allowlistProof.quantityLimitPerWallet != 0
                ? _allowlistProof.quantityLimitPerWallet
                : claimLimit;
            claimPrice = _allowlistProof.pricePerToken != type(uint256).max
                ? _allowlistProof.pricePerToken
                : claimPrice;
            claimCurrency = _allowlistProof.pricePerToken != type(uint256).max && _allowlistProof.currency != address(0)
                ? _allowlistProof.currency
                : claimCurrency;
        }

        uint256 supplyClaimedByWallet = claimCondition[_tokenId].supplyClaimedByWallet[activeConditionHash][_claimer];

        if (_currency != claimCurrency || _pricePerToken != claimPrice) {
            revert DropClaimInvalidTokenPrice(_currency, _pricePerToken, claimCurrency, claimPrice);
        }

        if (_quantity == 0 || (_quantity + supplyClaimedByWallet > claimLimit)) {
            revert DropClaimExceedLimit(claimLimit, _quantity + supplyClaimedByWallet);
        }

        if (currentClaimPhase.supplyClaimed + _quantity > currentClaimPhase.maxClaimableSupply) {
            revert DropClaimExceedMaxSupply(
                currentClaimPhase.maxClaimableSupply,
                currentClaimPhase.supplyClaimed + _quantity
            );
        }

        if (currentClaimPhase.startTimestamp > block.timestamp) {
            revert DropClaimNotStarted(currentClaimPhase.startTimestamp, block.timestamp);
        }
    }

    /// @dev At any given moment, returns the uid for the active claim condition.
    function getActiveClaimConditionId(uint256 _tokenId) public view returns (uint256) {
        ClaimConditionList storage conditionList = claimCondition[_tokenId];
        for (uint256 i = conditionList.currentStartId + conditionList.count; i > conditionList.currentStartId; i--) {
            if (block.timestamp >= conditionList.conditions[i - 1].startTimestamp) {
                return i - 1;
            }
        }

        revert DropNoActiveCondition();
    }

    /// @dev Returns the claim condition at the given uid.
    function getClaimConditionById(
        uint256 _tokenId,
        uint256 _conditionId
    ) external view returns (ClaimCondition memory condition) {
        condition = claimCondition[_tokenId].conditions[_conditionId];
    }

    /// @dev Returns the supply claimed by claimer for a given conditionId.
    function getSupplyClaimedByWallet(
        uint256 _tokenId,
        uint256 _conditionId,
        address _claimer
    ) public view returns (uint256 supplyClaimedByWallet) {
        bytes32 _conditionHash = claimCondition[_tokenId].conditionHash[_conditionId];
        supplyClaimedByWallet = claimCondition[_tokenId].supplyClaimedByWallet[_conditionHash][_claimer];
    }

    /*////////////////////////////////////////////////////////////////////
        Optional hooks that can be implemented in the derived contract
    ///////////////////////////////////////////////////////////////////*/

    /// @dev Exposes the ability to override the msg sender.
    function _dropMsgSender() internal virtual returns (address) {
        return msg.sender;
    }

    /// @dev Runs before every `claim` function call.
    function _beforeClaim(
        uint256 _tokenId,
        address _receiver,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        AllowlistProof calldata _allowlistProof,
        bytes memory _data
    ) internal virtual {}

    /// @dev Runs after every `claim` function call.
    function _afterClaim(
        uint256 _tokenId,
        address _receiver,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        AllowlistProof calldata _allowlistProof,
        bytes memory _data
    ) internal virtual {}

    /*///////////////////////////////////////////////////////////////
        Virtual functions: to be implemented in derived contract
    //////////////////////////////////////////////////////////////*/

    /// @dev Collects and distributes the primary sale value of NFTs being claimed.
    function collectPriceOnClaim(
        uint256 _tokenId,
        address _primarySaleRecipient,
        uint256 _quantityToClaim,
        address _currency,
        uint256 _pricePerToken
    ) internal virtual;

    /// @dev Transfers the NFTs being claimed.
    function transferTokensOnClaim(address _to, uint256 _tokenId, uint256 _quantityBeingClaimed) internal virtual;

    /// @dev Determine what wallet can update claim conditions
    function _canSetClaimConditions() internal view virtual returns (bool);
}
