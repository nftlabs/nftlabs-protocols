// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

/// @author thirdweb.com / mintra.ai

import "./DirectListingsStorage.sol";

// ====== External imports ======
import "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC2981.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";

// ====== Internal imports ======
import "../../../eip/interface/IERC721.sol";
import "../../../extension/Multicall.sol";
import "../../../extension/upgradeable/ReentrancyGuard.sol";
import { CurrencyTransferLib } from "../../../lib/CurrencyTransferLib.sol";

/**
 * @author  thirdweb.com / mintra.ai
 */
contract MintraDirectListings is IDirectListings, Multicall, ReentrancyGuard {
    /*///////////////////////////////////////////////////////////////
                        Mintra
    //////////////////////////////////////////////////////////////*/
    struct Royalty {
        address receiver;
        uint256 basisPoints;
    }

    event MintraNewSale(
        uint256 listingId,
        address buyer,
        uint256 quantityBought,
        uint256 totalPricePaid,
        address currency
    );

    event MintraRoyaltyTransfered(
        address assetContract,
        uint256 tokenId,
        uint256 listingId,
        uint256 totalPrice,
        uint256 royaltyAmount,
        uint256 platformFee,
        address royaltyRecipient,
        address currency
    );

    event RoyaltyUpdated(address assetContract, uint256 royaltyAmount, address royaltyRecipient);
    event PlatformFeeUpdated(uint256 platformFeeBps);

    address public immutable wizard;
    address private immutable mintTokenAddress;
    address public immutable platformFeeRecipient;
    uint256 public platformFeeBps = 225;
    uint256 public platformFeeBpsMint = 150;
    mapping(address => Royalty) public royalties;

    /*///////////////////////////////////////////////////////////////
                        Constants / Immutables
    //////////////////////////////////////////////////////////////*/

    /// @dev The max bps of the contract. So, 10_000 == 100 %
    uint64 private constant MAX_BPS = 10_000;

    /// @dev The address of the native token wrapper contract.
    address private immutable nativeTokenWrapper;

    /*///////////////////////////////////////////////////////////////
                            Modifier
    //////////////////////////////////////////////////////////////*/

    modifier onlyWizard() {
        require(msg.sender == wizard, "Not Wizard");
        _;
    }

    /// @dev Checks whether caller is a listing creator.
    modifier onlyListingCreator(uint256 _listingId) {
        require(
            _directListingsStorage().listings[_listingId].listingCreator == msg.sender,
            "Marketplace: not listing creator."
        );
        _;
    }

    /// @dev Checks whether a listing exists.
    modifier onlyExistingListing(uint256 _listingId) {
        require(
            _directListingsStorage().listings[_listingId].status == IDirectListings.Status.CREATED,
            "Marketplace: invalid listing."
        );
        _;
    }

    /*///////////////////////////////////////////////////////////////
                            Constructor logic
    //////////////////////////////////////////////////////////////*/

    constructor(
        address _nativeTokenWrapper,
        address _mintTokenAddress,
        address _platformFeeRecipient,
        address _wizard
    ) {
        nativeTokenWrapper = _nativeTokenWrapper;
        mintTokenAddress = _mintTokenAddress;
        platformFeeRecipient = _platformFeeRecipient;
        wizard = _wizard;
    }

    /*///////////////////////////////////////////////////////////////
                            External functions
    //////////////////////////////////////////////////////////////*/

    /// @notice List NFTs (ERC721 or ERC1155) for sale at a fixed price.
    function createListing(ListingParameters calldata _params) external returns (uint256 listingId) {
        listingId = _getNextListingId();
        address listingCreator = msg.sender;
        TokenType tokenType = _getTokenType(_params.assetContract);

        uint128 startTime = _params.startTimestamp;
        uint128 endTime = _params.endTimestamp;
        require(startTime < endTime, "Marketplace: endTimestamp not greater than startTimestamp.");
        if (startTime < block.timestamp) {
            require(startTime + 60 minutes >= block.timestamp, "Marketplace: invalid startTimestamp.");

            startTime = uint128(block.timestamp);
            endTime = endTime == type(uint128).max
                ? endTime
                : startTime + (_params.endTimestamp - _params.startTimestamp);
        }

        _validateNewListing(_params, tokenType);

        Listing memory listing = Listing({
            listingId: listingId,
            listingCreator: listingCreator,
            assetContract: _params.assetContract,
            tokenId: _params.tokenId,
            quantity: _params.quantity,
            currency: _params.currency,
            pricePerToken: _params.pricePerToken,
            startTimestamp: startTime,
            endTimestamp: endTime,
            reserved: _params.reserved,
            tokenType: tokenType,
            status: IDirectListings.Status.CREATED
        });

        _directListingsStorage().listings[listingId] = listing;

        emit NewListing(listingCreator, listingId, _params.assetContract, listing);

        return listingId;
    }

    /// @notice Update parameters of a listing of NFTs.
    function updateListing(
        uint256 _listingId,
        ListingParameters memory _params
    ) external onlyExistingListing(_listingId) onlyListingCreator(_listingId) {
        address listingCreator = msg.sender;
        Listing memory listing = _directListingsStorage().listings[_listingId];
        TokenType tokenType = _getTokenType(_params.assetContract);

        require(listing.endTimestamp > block.timestamp, "Marketplace: listing expired.");

        require(
            listing.assetContract == _params.assetContract && listing.tokenId == _params.tokenId,
            "Marketplace: cannot update what token is listed."
        );

        uint128 startTime = _params.startTimestamp;
        uint128 endTime = _params.endTimestamp;
        require(startTime < endTime, "Marketplace: endTimestamp not greater than startTimestamp.");
        require(
            listing.startTimestamp > block.timestamp ||
                (startTime == listing.startTimestamp && endTime > block.timestamp),
            "Marketplace: listing already active."
        );
        if (startTime != listing.startTimestamp && startTime < block.timestamp) {
            require(startTime + 60 minutes >= block.timestamp, "Marketplace: invalid startTimestamp.");

            startTime = uint128(block.timestamp);

            endTime = endTime == listing.endTimestamp || endTime == type(uint128).max
                ? endTime
                : startTime + (_params.endTimestamp - _params.startTimestamp);
        }

        {
            uint256 _approvedCurrencyPrice = _directListingsStorage().currencyPriceForListing[_listingId][
                _params.currency
            ];
            require(
                _approvedCurrencyPrice == 0 || _params.pricePerToken == _approvedCurrencyPrice,
                "Marketplace: price different from approved price"
            );
        }

        _validateNewListing(_params, tokenType);

        listing = Listing({
            listingId: _listingId,
            listingCreator: listingCreator,
            assetContract: _params.assetContract,
            tokenId: _params.tokenId,
            quantity: _params.quantity,
            currency: _params.currency,
            pricePerToken: _params.pricePerToken,
            startTimestamp: startTime,
            endTimestamp: endTime,
            reserved: _params.reserved,
            tokenType: tokenType,
            status: IDirectListings.Status.CREATED
        });

        _directListingsStorage().listings[_listingId] = listing;

        emit UpdatedListing(listingCreator, _listingId, _params.assetContract, listing);
    }

    /// @notice Cancel a listing.
    function cancelListing(uint256 _listingId) external onlyExistingListing(_listingId) onlyListingCreator(_listingId) {
        _directListingsStorage().listings[_listingId].status = IDirectListings.Status.CANCELLED;
        emit CancelledListing(msg.sender, _listingId);
    }

    /// @notice Approve a buyer to buy from a reserved listing.
    function approveBuyerForListing(
        uint256 _listingId,
        address _buyer,
        bool _toApprove
    ) external onlyExistingListing(_listingId) onlyListingCreator(_listingId) {
        require(_directListingsStorage().listings[_listingId].reserved, "Marketplace: listing not reserved.");

        _directListingsStorage().isBuyerApprovedForListing[_listingId][_buyer] = _toApprove;

        emit BuyerApprovedForListing(_listingId, _buyer, _toApprove);
    }

    /// @notice Approve a currency as a form of payment for the listing.
    function approveCurrencyForListing(
        uint256 _listingId,
        address _currency,
        uint256 _pricePerTokenInCurrency
    ) external onlyExistingListing(_listingId) onlyListingCreator(_listingId) {
        Listing memory listing = _directListingsStorage().listings[_listingId];
        require(
            _currency != listing.currency || _pricePerTokenInCurrency == listing.pricePerToken,
            "Marketplace: approving listing currency with different price."
        );
        require(
            _directListingsStorage().currencyPriceForListing[_listingId][_currency] != _pricePerTokenInCurrency,
            "Marketplace: price unchanged."
        );

        _directListingsStorage().currencyPriceForListing[_listingId][_currency] = _pricePerTokenInCurrency;

        emit CurrencyApprovedForListing(_listingId, _currency, _pricePerTokenInCurrency);
    }

    function bulkBuyFromListing(
        uint256[] memory _listingId,
        address[] memory _buyFor,
        uint256[] memory _quantity,
        address[] memory _currency,
        uint256[] memory _expectedTotalPrice
    ) external payable nonReentrant {
        uint256 totalAmountPls = 0;
        // Iterate over each tokenId
        for (uint256 i = 0; i < _listingId.length; i++) {
            // Are we buying this item in PLS
            uint256 price;

            Listing memory listing = _directListingsStorage().listings[_listingId[i]];

            require(listing.status == IDirectListings.Status.CREATED, "Marketplace: invalid listing.");

            if (_currency[i] == CurrencyTransferLib.NATIVE_TOKEN) {
                //calculate total amount for items being sold for PLS
                if (_directListingsStorage().currencyPriceForListing[_listingId[i]][_currency[i]] > 0) {
                    price =
                        _quantity[i] *
                        _directListingsStorage().currencyPriceForListing[_listingId[i]][_currency[i]];
                } else {
                    require(_currency[i] == listing.currency, "Paying in invalid currency.");
                    price = _quantity[i] * listing.pricePerToken;
                }

                totalAmountPls += price;
            }

            // Call the buy function for the current tokenId
            _buyFromListing(listing, _buyFor[i], _quantity[i], _currency[i], _expectedTotalPrice[i]);
        }

        // Make sure that the total price for items bought with PLS is equal to the amount sent
        require(msg.value == totalAmountPls || (totalAmountPls == 0 && msg.value == 0), "Incorrect PLS amount sent");
    }

    /// @notice Buy NFTs from a listing.
    function _buyFromListing(
        Listing memory listing,
        address _buyFor,
        uint256 _quantity,
        address _currency,
        uint256 _expectedTotalPrice
    ) internal {
        uint256 listingId = listing.listingId;
        address buyer = msg.sender;

        require(
            !listing.reserved || _directListingsStorage().isBuyerApprovedForListing[listingId][buyer],
            "buyer not approved"
        );
        require(_quantity > 0 && _quantity <= listing.quantity, "Buying invalid quantity");
        require(
            block.timestamp < listing.endTimestamp && block.timestamp >= listing.startTimestamp,
            "not within sale window."
        );

        require(
            _validateOwnershipAndApproval(
                listing.listingCreator,
                listing.assetContract,
                listing.tokenId,
                _quantity,
                listing.tokenType
            ),
            "Marketplace: not owner or approved tokens."
        );

        uint256 targetTotalPrice;

        // Check: is the buyer paying in a currency that the listing creator approved
        if (_directListingsStorage().currencyPriceForListing[listingId][_currency] > 0) {
            targetTotalPrice = _quantity * _directListingsStorage().currencyPriceForListing[listingId][_currency];
        } else {
            require(_currency == listing.currency, "Paying in invalid currency.");
            targetTotalPrice = _quantity * listing.pricePerToken;
        }

        // Check: is the buyer paying the price that the buyer is expecting to pay.
        // This is to prevent attack where the seller could change the price
        // right before the buyers tranaction executes.
        require(targetTotalPrice == _expectedTotalPrice, "Unexpected total price");

        if (_currency != CurrencyTransferLib.NATIVE_TOKEN) {
            _validateERC20BalAndAllowance(buyer, _currency, targetTotalPrice);
        }

        if (listing.quantity == _quantity) {
            _directListingsStorage().listings[listingId].status = IDirectListings.Status.COMPLETED;
        }
        _directListingsStorage().listings[listingId].quantity -= _quantity;

        _payout(buyer, listing.listingCreator, _currency, targetTotalPrice, listing);

        _transferListingTokens(listing.listingCreator, _buyFor, _quantity, listing);

        emit MintraNewSale(listing.listingId, buyer, _quantity, targetTotalPrice, _currency);
    }

    /*///////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/

    /**
     *  @notice Returns the total number of listings created.
     *  @dev At any point, the return value is the ID of the next listing created.
     */
    function totalListings() external view returns (uint256) {
        return _directListingsStorage().totalListings;
    }

    /// @notice Returns whether a buyer is approved for a listing.
    function isBuyerApprovedForListing(uint256 _listingId, address _buyer) external view returns (bool) {
        return _directListingsStorage().isBuyerApprovedForListing[_listingId][_buyer];
    }

    /// @notice Returns whether a currency is approved for a listing.
    function isCurrencyApprovedForListing(uint256 _listingId, address _currency) external view returns (bool) {
        return _directListingsStorage().currencyPriceForListing[_listingId][_currency] > 0;
    }

    /// @notice Returns the price per token for a listing, in the given currency.
    function currencyPriceForListing(uint256 _listingId, address _currency) external view returns (uint256) {
        if (_directListingsStorage().currencyPriceForListing[_listingId][_currency] == 0) {
            revert("Currency not approved for listing");
        }

        return _directListingsStorage().currencyPriceForListing[_listingId][_currency];
    }

    /// @notice Returns all non-cancelled listings.
    function getAllListings(uint256 _startId, uint256 _endId) external view returns (Listing[] memory _allListings) {
        require(_startId <= _endId && _endId < _directListingsStorage().totalListings, "invalid range");

        _allListings = new Listing[](_endId - _startId + 1);

        for (uint256 i = _startId; i <= _endId; i += 1) {
            _allListings[i - _startId] = _directListingsStorage().listings[i];
        }
    }

    /**
     *  @notice Returns all valid listings between the start and end Id (both inclusive) provided.
     *          A valid listing is where the listing creator still owns and has approved Marketplace
     *          to transfer the listed NFTs.
     */
    function getAllValidListings(
        uint256 _startId,
        uint256 _endId
    ) external view returns (Listing[] memory _validListings) {
        require(_startId <= _endId && _endId < _directListingsStorage().totalListings, "invalid range");

        Listing[] memory _listings = new Listing[](_endId - _startId + 1);
        uint256 _listingCount;

        for (uint256 i = _startId; i <= _endId; i += 1) {
            _listings[i - _startId] = _directListingsStorage().listings[i];
            if (_validateExistingListing(_listings[i - _startId])) {
                _listingCount += 1;
            }
        }

        _validListings = new Listing[](_listingCount);
        uint256 index = 0;
        uint256 count = _listings.length;
        for (uint256 i = 0; i < count; i += 1) {
            if (_validateExistingListing(_listings[i])) {
                _validListings[index++] = _listings[i];
            }
        }
    }

    /// @notice Returns a listing at a particular listing ID.
    function getListing(uint256 _listingId) external view returns (Listing memory listing) {
        listing = _directListingsStorage().listings[_listingId];
    }

    /**
     * @notice Set or update the royalty for a collection
     * @dev Sets or updates the royalty for a collection to a new value
     * @param _collectionAddress Address of the collection to set the royalty for
     * @param _royaltyInBasisPoints New royalty value, in basis points (1 basis point = 0.01%)
     */
    function createOrUpdateRoyalty(
        address _collectionAddress,
        uint256 _royaltyInBasisPoints,
        address receiver
    ) public nonReentrant {
        require(_collectionAddress != address(0), "_collectionAddress is not set");
        require(_royaltyInBasisPoints >= 0 && _royaltyInBasisPoints <= 10000, "Royalty not in range");
        require(receiver != address(0), "receiver is not set");

        // Check that the caller is the owner/creator of the collection contract
        require(Ownable(_collectionAddress).owner() == msg.sender, "Unauthorized");

        // Create a new Royalty object with the given value and store it in the royalties mapping
        Royalty memory royalty = Royalty(receiver, _royaltyInBasisPoints);
        royalties[_collectionAddress] = royalty;

        // Emit a RoyaltyUpdated
        emit RoyaltyUpdated(_collectionAddress, _royaltyInBasisPoints, receiver);
    }

    /*///////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the next listing Id.
    function _getNextListingId() internal returns (uint256 id) {
        id = _directListingsStorage().totalListings;
        _directListingsStorage().totalListings += 1;
    }

    /// @dev Returns the interface supported by a contract.
    function _getTokenType(address _assetContract) internal view returns (TokenType tokenType) {
        if (IERC165(_assetContract).supportsInterface(type(IERC1155).interfaceId)) {
            tokenType = TokenType.ERC1155;
        } else if (IERC165(_assetContract).supportsInterface(type(IERC721).interfaceId)) {
            tokenType = TokenType.ERC721;
        } else {
            revert("Marketplace: listed token must be ERC1155 or ERC721.");
        }
    }

    /// @dev Checks whether the listing creator owns and has approved marketplace to transfer listed tokens.
    function _validateNewListing(ListingParameters memory _params, TokenType _tokenType) internal view {
        require(_params.quantity > 0, "Marketplace: listing zero quantity.");
        require(_params.quantity == 1 || _tokenType == TokenType.ERC1155, "Marketplace: listing invalid quantity.");

        require(
            _validateOwnershipAndApproval(
                msg.sender,
                _params.assetContract,
                _params.tokenId,
                _params.quantity,
                _tokenType
            ),
            "Marketplace: not owner or approved tokens."
        );
    }

    /// @dev Checks whether the listing exists, is active, and if the lister has sufficient balance.
    function _validateExistingListing(Listing memory _targetListing) internal view returns (bool isValid) {
        isValid =
            _targetListing.startTimestamp <= block.timestamp &&
            _targetListing.endTimestamp > block.timestamp &&
            _targetListing.status == IDirectListings.Status.CREATED &&
            _validateOwnershipAndApproval(
                _targetListing.listingCreator,
                _targetListing.assetContract,
                _targetListing.tokenId,
                _targetListing.quantity,
                _targetListing.tokenType
            );
    }

    /// @dev Validates that `_tokenOwner` owns and has approved Marketplace to transfer NFTs.
    function _validateOwnershipAndApproval(
        address _tokenOwner,
        address _assetContract,
        uint256 _tokenId,
        uint256 _quantity,
        TokenType _tokenType
    ) internal view returns (bool isValid) {
        address market = address(this);

        if (_tokenType == TokenType.ERC1155) {
            isValid =
                IERC1155(_assetContract).balanceOf(_tokenOwner, _tokenId) >= _quantity &&
                IERC1155(_assetContract).isApprovedForAll(_tokenOwner, market);
        } else if (_tokenType == TokenType.ERC721) {
            address owner;
            address operator;

            // failsafe for reverts in case of non-existent tokens
            try IERC721(_assetContract).ownerOf(_tokenId) returns (address _owner) {
                owner = _owner;

                // Nesting the approval check inside this try block, to run only if owner check doesn't revert.
                // If the previous check for owner fails, then the return value will always evaluate to false.
                try IERC721(_assetContract).getApproved(_tokenId) returns (address _operator) {
                    operator = _operator;
                } catch {}
            } catch {}

            isValid =
                owner == _tokenOwner &&
                (operator == market || IERC721(_assetContract).isApprovedForAll(_tokenOwner, market));
        }
    }

    /// @dev Validates that `_tokenOwner` owns and has approved Markeplace to transfer the appropriate amount of currency
    function _validateERC20BalAndAllowance(address _tokenOwner, address _currency, uint256 _amount) internal view {
        require(
            IERC20(_currency).balanceOf(_tokenOwner) >= _amount &&
                IERC20(_currency).allowance(_tokenOwner, address(this)) >= _amount,
            "!BAL20"
        );
    }

    /// @dev Transfers tokens listed for sale in a direct or auction listing.
    function _transferListingTokens(address _from, address _to, uint256 _quantity, Listing memory _listing) internal {
        if (_listing.tokenType == TokenType.ERC1155) {
            IERC1155(_listing.assetContract).safeTransferFrom(_from, _to, _listing.tokenId, _quantity, "");
        } else if (_listing.tokenType == TokenType.ERC721) {
            IERC721(_listing.assetContract).safeTransferFrom(_from, _to, _listing.tokenId, "");
        }
    }

    /// @dev Pays out stakeholders in a sale.
    function _payout(
        address _payer,
        address _payee,
        address _currencyToUse,
        uint256 _totalPayoutAmount,
        Listing memory _listing
    ) internal {
        uint256 amountRemaining;
        uint256 platformFeeCut;

        // Payout platform fee
        {
            // Descrease platform fee for mint token
            if (_currencyToUse == mintTokenAddress) {
                platformFeeCut = (_totalPayoutAmount * platformFeeBpsMint) / MAX_BPS;
            } else {
                platformFeeCut = (_totalPayoutAmount * platformFeeBps) / MAX_BPS;
            }

            // Transfer platform fee
            CurrencyTransferLib.transferCurrency(_currencyToUse, _payer, platformFeeRecipient, platformFeeCut);

            amountRemaining = _totalPayoutAmount - platformFeeCut;
        }

        // Payout royalties
        {
            // Get royalty recipients and amounts
            (address royaltyRecipient, uint256 royaltyAmount) = processRoyalty(
                _listing.assetContract,
                _listing.tokenId,
                _totalPayoutAmount
            );

            if (royaltyAmount > 0) {
                // Check payout amount remaining is enough to cover royalty payment
                require(amountRemaining >= royaltyAmount, "fees exceed the price");

                // Transfer royalty
                CurrencyTransferLib.transferCurrency(_currencyToUse, _payer, royaltyRecipient, royaltyAmount);

                amountRemaining = amountRemaining - royaltyAmount;

                emit MintraRoyaltyTransfered(
                    _listing.assetContract,
                    _listing.tokenId,
                    _listing.listingId,
                    _totalPayoutAmount,
                    royaltyAmount,
                    platformFeeCut,
                    royaltyRecipient,
                    _currencyToUse
                );
            }
        }

        // Distribute price to token owner
        CurrencyTransferLib.transferCurrency(_currencyToUse, _payer, _payee, amountRemaining);
    }

    function processRoyalty(
        address _tokenAddress,
        uint256 _tokenId,
        uint256 _price
    ) internal view returns (address royaltyReceiver, uint256 royaltyAmount) {
        // Check if collection has royalty using ERC2981
        if (isERC2981(_tokenAddress)) {
            (royaltyReceiver, royaltyAmount) = IERC2981(_tokenAddress).royaltyInfo(_tokenId, _price);
        } else {
            royaltyAmount = (_price * royalties[_tokenAddress].basisPoints) / 10000;
            royaltyReceiver = royalties[_tokenAddress].receiver;
        }

        return (royaltyReceiver, royaltyAmount);
    }

    /**
     * @notice This function checks if a given contract is ERC2981 compliant
     * @dev This function is called internally and cannot be accessed outside the contract
     * @param _contract The address of the contract to check
     * @return A boolean indicating whether the contract is ERC2981 compliant or not
     */
    function isERC2981(address _contract) internal view returns (bool) {
        try IERC2981(_contract).royaltyInfo(0, 0) returns (address, uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Returns the DirectListings storage.
    function _directListingsStorage() internal pure returns (DirectListingsStorage.Data storage data) {
        data = DirectListingsStorage.data();
    }

    /**
     * @notice Update the market fee percentage
     * @dev Updates the market fee percentage to a new value
     * @param _platformFeeBps New value for the market fee percentage
     */
    function setPlatformFeeBps(uint256 _platformFeeBps) public onlyWizard {
        require(_platformFeeBps <= 369, "Fee not in range");

        platformFeeBps = _platformFeeBps;

        emit PlatformFeeUpdated(_platformFeeBps);
    }
}
