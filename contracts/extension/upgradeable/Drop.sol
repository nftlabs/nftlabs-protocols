// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/// @author thirdweb

import "../interface/IDrop.sol";
import "../../lib/MerkleProof.sol";

library DropStorage {
    /// @custom:storage-location erc7201:extension.manager.storage
    bytes32 public constant DROP_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("drop.storage")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        /// @dev The active conditions for claiming tokens.
        IDrop.ClaimConditionList claimCondition;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = DROP_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

abstract contract Drop is IDrop {
    function claimCondition() public view returns (uint256, uint256) {
        return (_dropStorage().claimCondition.currentStartId, _dropStorage().claimCondition.count);
    }

    /*///////////////////////////////////////////////////////////////
                            Drop logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Lets an account claim tokens.
    function claim(
        address _receiver,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        AllowlistProof calldata _allowlistProof,
        bytes memory _data
    ) public payable virtual override {
        _beforeClaim(_receiver, _quantity, _currency, _pricePerToken, _allowlistProof, _data);

        uint256 activeConditionId = getActiveClaimConditionId();

        verifyClaim(activeConditionId, _dropMsgSender(), _quantity, _currency, _pricePerToken, _allowlistProof);

        // Update contract state.
        bytes32 activeConditionHash = _dropStorage().claimCondition.conditionHash[activeConditionId];
        _dropStorage().claimCondition.conditions[activeConditionId].supplyClaimed += _quantity;
        _dropStorage().claimCondition.supplyClaimedByWallet[activeConditionHash][_dropMsgSender()] += _quantity;

        // If there's a price, collect price.
        _collectPriceOnClaim(address(0), _quantity, _currency, _pricePerToken);

        // Mint the relevant tokens to claimer.
        uint256 startTokenId = _transferTokensOnClaim(_receiver, _quantity);

        emit TokensClaimed(activeConditionId, _dropMsgSender(), _receiver, startTokenId, _quantity);

        _afterClaim(_receiver, _quantity, _currency, _pricePerToken, _allowlistProof, _data);
    }

    /// @dev Lets a contract admin set claim conditions.
    function setClaimConditions(
        ClaimCondition[] calldata _conditions,
        bool _resetClaimEligibility
    ) external virtual override {
        if (!_canSetClaimConditions()) {
            revert("Not authorized");
        }

        uint256 existingStartIndex = _dropStorage().claimCondition.currentStartId;
        uint256 existingPhaseCount = _dropStorage().claimCondition.count;

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

        _dropStorage().claimCondition.count = _conditions.length;
        _dropStorage().claimCondition.currentStartId = newStartIndex;

        uint256 lastConditionStartTimestamp;
        for (uint256 i = 0; i < _conditions.length; i++) {
            require(i == 0 || lastConditionStartTimestamp < _conditions[i].startTimestamp, "ST");

            uint256 supplyClaimedAlready = _dropStorage().claimCondition.conditions[newStartIndex + i].supplyClaimed;
            if (supplyClaimedAlready > _conditions[i].maxClaimableSupply) {
                revert("max supply claimed");
            }

            _dropStorage().claimCondition.conditions[newStartIndex + i] = _conditions[i];
            _dropStorage().claimCondition.conditions[newStartIndex + i].supplyClaimed = supplyClaimedAlready;

            bytes32 _conditionHash = _dropStorage().claimCondition.conditionHash[newStartIndex + i];
            if (_resetClaimEligibility || _conditionHash == bytes32(0)) {
                _dropStorage().claimCondition.conditionHash[newStartIndex + i] = keccak256(
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
                delete _dropStorage().claimCondition.conditions[i];
                delete _dropStorage().claimCondition.conditionHash[i];
            }
        } else {
            if (existingPhaseCount > _conditions.length) {
                for (uint256 i = _conditions.length; i < existingPhaseCount; i++) {
                    delete _dropStorage().claimCondition.conditions[newStartIndex + i];
                    delete _dropStorage().claimCondition.conditionHash[newStartIndex + i];
                }
            }
        }

        emit ClaimConditionsUpdated(_conditions, _resetClaimEligibility);
    }

    /// @dev Checks a request to claim NFTs against the active claim condition's criteria.
    function verifyClaim(
        uint256 _conditionId,
        address _claimer,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        AllowlistProof calldata _allowlistProof
    ) public view virtual returns (bool isOverride) {
        ClaimCondition memory currentClaimPhase = _dropStorage().claimCondition.conditions[_conditionId];
        bytes32 activeConditionHash = _dropStorage().claimCondition.conditionHash[_conditionId];
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

        uint256 supplyClaimedByWallet = _dropStorage().claimCondition.supplyClaimedByWallet[activeConditionHash][
            _claimer
        ];

        if (_currency != claimCurrency || _pricePerToken != claimPrice) {
            revert("!PriceOrCurrency");
        }

        if (_quantity == 0 || (_quantity + supplyClaimedByWallet > claimLimit)) {
            revert("!Qty");
        }
        if (currentClaimPhase.supplyClaimed + _quantity > currentClaimPhase.maxClaimableSupply) {
            revert("!MaxSupply");
        }

        if (currentClaimPhase.startTimestamp > block.timestamp) {
            revert("cant claim yet");
        }
    }

    /// @dev At any given moment, returns the uid for the active claim condition.
    function getActiveClaimConditionId() public view returns (uint256) {
        for (
            uint256 i = _dropStorage().claimCondition.currentStartId + _dropStorage().claimCondition.count;
            i > _dropStorage().claimCondition.currentStartId;
            i--
        ) {
            if (block.timestamp >= _dropStorage().claimCondition.conditions[i - 1].startTimestamp) {
                return i - 1;
            }
        }

        revert("!CONDITION.");
    }

    /// @dev Returns the claim condition at the given uid.
    function getClaimConditionById(uint256 _conditionId) external view returns (ClaimCondition memory condition) {
        condition = _dropStorage().claimCondition.conditions[_conditionId];
    }

    /// @dev Returns the supply claimed by claimer for a given conditionId.
    function getSupplyClaimedByWallet(
        uint256 _conditionId,
        address _claimer
    ) public view returns (uint256 supplyClaimedByWallet) {
        bytes32 _conditionHash = _dropStorage().claimCondition.conditionHash[_conditionId];
        supplyClaimedByWallet = _dropStorage().claimCondition.supplyClaimedByWallet[_conditionHash][_claimer];
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
        address _receiver,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        AllowlistProof calldata _allowlistProof,
        bytes memory _data
    ) internal virtual {}

    /// @dev Runs after every `claim` function call.
    function _afterClaim(
        address _receiver,
        uint256 _quantity,
        address _currency,
        uint256 _pricePerToken,
        AllowlistProof calldata _allowlistProof,
        bytes memory _data
    ) internal virtual {}

    /// @dev Returns the DropStorage storage.
    function _dropStorage() internal pure returns (DropStorage.Data storage data) {
        data = DropStorage.data();
    }

    /*///////////////////////////////////////////////////////////////
        Virtual functions: to be implemented in derived contract
    //////////////////////////////////////////////////////////////*/

    /// @dev Collects and distributes the primary sale value of NFTs being claimed.
    function _collectPriceOnClaim(
        address _primarySaleRecipient,
        uint256 _quantityToClaim,
        address _currency,
        uint256 _pricePerToken
    ) internal virtual;

    /// @dev Transfers the NFTs being claimed.
    function _transferTokensOnClaim(
        address _to,
        uint256 _quantityBeingClaimed
    ) internal virtual returns (uint256 startTokenId);

    /// @dev Determine what wallet can update claim conditions
    function _canSetClaimConditions() internal view virtual returns (bool);
}
