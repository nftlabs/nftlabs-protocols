// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

// Test helper imports
import "../utils/BaseTest.sol";

// Test contracts and interfaces
import { RoyaltyPaymentsLogic } from "contracts/extension/plugin/RoyaltyPayments.sol";
import { MarketplaceV3, IPlatformFee } from "contracts/prebuilts/marketplace/entrypoint/MarketplaceV3.sol";
import { TWProxy } from "contracts/infra/TWProxy.sol";
import { ERC721Base } from "contracts/base/ERC721Base.sol";
import { MockRoyaltyEngineV1 } from "../mocks/MockRoyaltyEngineV1.sol";

import { IDirectListings } from "contracts/prebuilts/marketplace/IMarketplace.sol";
import { MintraDirectListings } from "contracts/prebuilts/marketplace/direct-listings/MintraDirectListings.sol";
import "@thirdweb-dev/dynamic-contracts/src/interface/IExtension.sol";
import { MockERC721Ownable } from "../mocks/MockERC721Ownable.sol";

contract MintraDirectListingsTest is BaseTest, IExtension {
    // Target contract
    address public marketplace;

    // Participants
    address public marketplaceDeployer;
    address public seller;
    address public buyer;
    address public wizard;
    address public collectionOwner;

    MintraDirectListings public mintraDirectListingsLogicStandalone;
    MockERC721Ownable public erc721Ownable;

    function setUp() public override {
        super.setUp();

        marketplaceDeployer = getActor(1);
        seller = getActor(2);
        buyer = getActor(3);
        wizard = getActor(4);
        collectionOwner = getActor(5);

        // Deploy implementation.
        mintraDirectListingsLogicStandalone = new MintraDirectListings(
            address(weth),
            address(erc20Aux),
            address(platformFeeRecipient),
            address(wizard)
        );
        marketplace = address(mintraDirectListingsLogicStandalone);

        vm.prank(collectionOwner);
        erc721Ownable = new MockERC721Ownable();

        //vm.prank(marketplaceDeployer);

        vm.label(marketplace, "Marketplace");
        vm.label(seller, "Seller");
        vm.label(buyer, "Buyer");
        vm.label(address(erc721), "ERC721_Token");
        vm.label(address(erc1155), "ERC1155_Token");
    }

    function _setupERC721BalanceForSeller(address _seller, uint256 _numOfTokens) private {
        erc721.mint(_seller, _numOfTokens);
    }

    function test_state_initial() public {
        uint256 totalListings = MintraDirectListings(marketplace).totalListings();
        assertEq(totalListings, 0);
    }

    /*///////////////////////////////////////////////////////////////
                            Miscellaneous
    //////////////////////////////////////////////////////////////*/

    function test_getValidListings_burnListedTokens() public {
        // Sample listing parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = 200;
        bool reserved = true;

        // Mint the ERC721 tokens to seller. These tokens will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        MintraDirectListings(marketplace).createListing(listingParams);

        // Total listings incremented
        assertEq(MintraDirectListings(marketplace).totalListings(), 1);

        // burn listed token
        vm.prank(seller);
        erc721.burn(0);

        vm.warp(150);
        // Fetch listing and verify state.
        uint256 totalListings = MintraDirectListings(marketplace).totalListings();
        assertEq(MintraDirectListings(marketplace).getAllValidListings(0, totalListings - 1).length, 0);
    }

    function test_state_approvedCurrencies() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParams) = _setup_updateListing(0);
        address currencyToApprove = address(erc20); // same currency as main listing
        uint256 pricePerTokenForCurrency = 2 ether;

        // Seller approves currency for listing.
        vm.prank(seller);
        vm.expectRevert("Marketplace: approving listing currency with different price.");
        MintraDirectListings(marketplace).approveCurrencyForListing(
            listingId,
            currencyToApprove,
            pricePerTokenForCurrency
        );

        // change currency
        currencyToApprove = NATIVE_TOKEN;

        vm.prank(seller);
        MintraDirectListings(marketplace).approveCurrencyForListing(
            listingId,
            currencyToApprove,
            pricePerTokenForCurrency
        );

        assertEq(
            MintraDirectListings(marketplace).isCurrencyApprovedForListing(listingId, NATIVE_TOKEN),
            true
        );
        assertEq(
            MintraDirectListings(marketplace).currencyPriceForListing(listingId, NATIVE_TOKEN),
            pricePerTokenForCurrency
        );

        // should revert when updating listing with an approved currency but different price
        listingParams.currency = NATIVE_TOKEN;
        vm.prank(seller);
        vm.expectRevert("Marketplace: price different from approved price");
        MintraDirectListings(marketplace).updateListing(listingId, listingParams);

        // change listingParams.pricePerToken to approved price
        listingParams.pricePerToken = pricePerTokenForCurrency;
        vm.prank(seller);
        MintraDirectListings(marketplace).updateListing(listingId, listingParams);
    }

    /*///////////////////////////////////////////////////////////////
                Royalty Tests (incl Royalty Engine / Registry)
    //////////////////////////////////////////////////////////////*/

    function _setupListingForRoyaltyTests(address erc721TokenAddress) private returns (uint256 listingId) {
        // Sample listing parameters.
        address assetContract = erc721TokenAddress;
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 pricePerToken = 100 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = 200;
        bool reserved = false;

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        IERC721(erc721TokenAddress).setApprovalForAll(marketplace, true);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        listingId = MintraDirectListings(marketplace).createListing(listingParams);
    }

    function _buyFromListingForRoyaltyTests(uint256 listingId) private returns (uint256 totalPrice) {
        IDirectListings.Listing memory listing = MintraDirectListings(marketplace).getListing(listingId);

        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity;
        address currency = listing.currency;
        uint256 pricePerToken = listing.pricePerToken;
        totalPrice = pricePerToken * quantityToBuy;

        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice);

        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, totalPrice);

        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.prank(buyer);

        uint256[] memory listingIdArray = new uint256[](1);
        listingIdArray[0] = listingId;

        address[] memory buyForArray = new address[](1);
        buyForArray[0] = buyFor;

        uint256[] memory quantityToBuyArray = new uint256[](1);
        quantityToBuyArray[0] = quantityToBuy;

        address[] memory currencyArray = new address[](1);
        currencyArray[0] = currency;

        uint256[] memory expectedTotalPriceArray = new uint256[](1);
        expectedTotalPriceArray[0] = totalPrice;

        MintraDirectListings(marketplace).bulkBuyFromListing(
            listingIdArray,
            buyForArray,
            quantityToBuyArray,
            currencyArray,
            expectedTotalPriceArray
        );
    }

    function test_noRoyaltyEngine_defaultERC2981Token() public {
        // create token with ERC2981
        address royaltyRecipient = address(0x12345);
        uint128 royaltyBps = 10;
        uint256 platformFeeBps = MintraDirectListings(marketplace).platformFeeBps();
        ERC721Base nft2981 = new ERC721Base(address(0x12345), "NFT 2981", "NFT2981", royaltyRecipient, royaltyBps);
        vm.prank(address(0x12345));
        nft2981.mintTo(seller, "");

        // 1. ========= Create listing =========

        uint256 listingId = _setupListingForRoyaltyTests(address(nft2981));

        // 2. ========= Buy from listing =========

        uint256 totalPrice = _buyFromListingForRoyaltyTests(listingId);

        // 3. ======== Check balances after royalty payments ========

        {
            uint256 platforfee = (platformFeeBps * totalPrice) / 10_000;
            uint256 royaltyAmount = (royaltyBps * totalPrice) / 10_000;

            assertBalERC20Eq(address(erc20), platformFeeRecipient, platforfee);

            // Royalty recipient receives correct amounts
            assertBalERC20Eq(address(erc20), royaltyRecipient, royaltyAmount);

            // Seller gets total price minus royalty amount minus platform fee
            assertBalERC20Eq(address(erc20), seller, totalPrice - royaltyAmount - platforfee);
        }
    }

    function test_revert_mintra_native_royalty_feesExceedTotalPrice() public {
        // Set native royalty too high
        vm.prank(collectionOwner);
        mintraDirectListingsLogicStandalone.createOrUpdateRoyalty(address(erc721Ownable), 10000, factoryAdmin);

        // 1. ========= Create listing =========
        erc721Ownable.mint(seller, 1);
        uint256 listingId = _setupListingForRoyaltyTests(address(erc721Ownable));

        // 2. ========= Buy from listing =========
        IDirectListings.Listing memory listing = MintraDirectListings(marketplace).getListing(listingId);
        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity;
        address currency = listing.currency;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;
        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice);
        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, totalPrice);
        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.expectRevert("fees exceed the price");
        vm.prank(buyer);

        uint256[] memory listingIdArray = new uint256[](1);
        listingIdArray[0] = listingId;

        address[] memory buyForArray = new address[](1);
        buyForArray[0] = buyFor;

        uint256[] memory quantityToBuyArray = new uint256[](1);
        quantityToBuyArray[0] = quantityToBuy;

        address[] memory currencyArray = new address[](1);
        currencyArray[0] = currency;

        uint256[] memory expectedTotalPriceArray = new uint256[](1);
        expectedTotalPriceArray[0] = totalPrice;

        MintraDirectListings(marketplace).bulkBuyFromListing(
            listingIdArray,
            buyForArray,
            quantityToBuyArray,
            currencyArray,
            expectedTotalPriceArray
        );
    }

    function test_revert_erc2981_royalty_feesExceedTotalPrice() public {
        // Set erc2981 royalty too high
        ERC721Base nft2981 = new ERC721Base(address(0x12345), "NFT 2981", "NFT2981", royaltyRecipient, 10000);

        // 1. ========= Create listing =========
        vm.prank(address(0x12345));
        nft2981.mintTo(seller, "");
        uint256 listingId = _setupListingForRoyaltyTests(address(nft2981));

        // 2. ========= Buy from listing =========
        IDirectListings.Listing memory listing = MintraDirectListings(marketplace).getListing(listingId);
        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity;
        address currency = listing.currency;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;
        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice);
        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, totalPrice);
        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.expectRevert("fees exceed the price");
        vm.prank(buyer);

        uint256[] memory listingIdArray = new uint256[](1);
        listingIdArray[0] = listingId;

        address[] memory buyForArray = new address[](1);
        buyForArray[0] = buyFor;

        uint256[] memory quantityToBuyArray = new uint256[](1);
        quantityToBuyArray[0] = quantityToBuy;

        address[] memory currencyArray = new address[](1);
        currencyArray[0] = currency;

        uint256[] memory expectedTotalPriceArray = new uint256[](1);
        expectedTotalPriceArray[0] = totalPrice;

        MintraDirectListings(marketplace).bulkBuyFromListing(
            listingIdArray,
            buyForArray,
            quantityToBuyArray,
            currencyArray,
            expectedTotalPriceArray
        );
    }

    /*///////////////////////////////////////////////////////////////
                            Create listing
    //////////////////////////////////////////////////////////////*/

    function createListing_1155(uint256 tokenId, uint256 totalListings) private returns (uint256 listingId) {
        // Sample listing parameters.
        address assetContract = address(erc1155);
        uint256 quantity = 2;
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = 200;
        bool reserved = false;

        // Mint the ERC721 tokens to seller. These tokens will be listed.
        _setupERC721BalanceForSeller(seller, 1);
        erc1155.mint(seller, tokenId, quantity, "");

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = quantity;

        assertBalERC1155Eq(address(erc1155), seller, tokenIds, amounts);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc1155.setApprovalForAll(marketplace, true);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        listingId = MintraDirectListings(marketplace).createListing(listingParams);

        // Test consequent state of the contract.

        // Seller is still owner of token.
        assertBalERC1155Eq(address(erc1155), seller, tokenIds, amounts);

        // Total listings incremented
        assertEq(MintraDirectListings(marketplace).totalListings(), totalListings);

        // Fetch listing and verify state.
        IDirectListings.Listing memory listing = MintraDirectListings(marketplace).getListing(listingId);

        assertEq(listing.listingId, listingId);
        assertEq(listing.listingCreator, seller);
        assertEq(listing.assetContract, assetContract);
        assertEq(listing.tokenId, tokenId);
        assertEq(listing.quantity, quantity);
        assertEq(listing.currency, currency);
        assertEq(listing.pricePerToken, pricePerToken);
        assertEq(listing.startTimestamp, startTimestamp);
        assertEq(listing.endTimestamp, endTimestamp);
        assertEq(listing.reserved, reserved);
        assertEq(uint256(listing.tokenType), uint256(IDirectListings.TokenType.ERC1155));

        return listingId;
    }

    function test_state_createListing() public {
        // Sample listing parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = 200;
        bool reserved = true;

        // Mint the ERC721 tokens to seller. These tokens will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        uint256 listingId = MintraDirectListings(marketplace).createListing(listingParams);

        // Test consequent state of the contract.

        // Seller is still owner of token.
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Total listings incremented
        assertEq(MintraDirectListings(marketplace).totalListings(), 1);

        // Fetch listing and verify state.
        IDirectListings.Listing memory listing = MintraDirectListings(marketplace).getListing(listingId);

        assertEq(listing.listingId, listingId);
        assertEq(listing.listingCreator, seller);
        assertEq(listing.assetContract, assetContract);
        assertEq(listing.tokenId, tokenId);
        assertEq(listing.quantity, quantity);
        assertEq(listing.currency, currency);
        assertEq(listing.pricePerToken, pricePerToken);
        assertEq(listing.startTimestamp, startTimestamp);
        assertEq(listing.endTimestamp, endTimestamp);
        assertEq(listing.reserved, reserved);
        assertEq(uint256(listing.tokenType), uint256(IDirectListings.TokenType.ERC721));
    }

    function test_state_createListing_start_time_in_past() public {
        // Sample listing parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;

        vm.warp(10000); // Set the timestop for block 1 to 10000

        uint256 expectedStartTimestamp = 10000;
        uint256 expectedEndTimestamp = type(uint128).max;
        // Set the start time to be at a timestamp in the past
        uint128 startTimestamp = uint128(block.timestamp) - 1000;

        uint128 endTimestamp = type(uint128).max;
        bool reserved = true;

        // Mint the ERC721 tokens to seller. These tokens will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        uint256 listingId = MintraDirectListings(marketplace).createListing(listingParams);

        // Test consequent state of the contract.

        // Seller is still owner of token.
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Total listings incremented
        assertEq(MintraDirectListings(marketplace).totalListings(), 1);

        // Fetch listing and verify state.
        IDirectListings.Listing memory listing = MintraDirectListings(marketplace).getListing(listingId);

        assertEq(listing.listingId, listingId);
        assertEq(listing.listingCreator, seller);
        assertEq(listing.assetContract, assetContract);
        assertEq(listing.tokenId, tokenId);
        assertEq(listing.quantity, quantity);
        assertEq(listing.currency, currency);
        assertEq(listing.pricePerToken, pricePerToken);
        assertEq(listing.startTimestamp, expectedStartTimestamp);
        assertEq(listing.endTimestamp, expectedEndTimestamp);
        assertEq(listing.reserved, reserved);
        assertEq(uint256(listing.tokenType), uint256(IDirectListings.TokenType.ERC721));
    }

    function test_revert_createListing_notOwnerOfListedToken() public {
        // Sample listing parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = 200;
        bool reserved = true;

        // Don't mint to 'token to be listed' to the seller.
        address someWallet = getActor(1000);
        _setupERC721BalanceForSeller(someWallet, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), someWallet, tokenIds);
        assertIsNotOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(someWallet);
        erc721.setApprovalForAll(marketplace, true);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: not owner or approved tokens.");
        MintraDirectListings(marketplace).createListing(listingParams);
    }

    function test_revert_createListing_notApprovedMarketplaceToTransferToken() public {
        // Sample listing parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = 200;
        bool reserved = true;

        // Mint the ERC721 tokens to seller. These tokens will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Don't approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, false);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: not owner or approved tokens.");
        MintraDirectListings(marketplace).createListing(listingParams);
    }

    function test_revert_createListing_listingZeroQuantity() public {
        // Sample listing parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 0; // Listing ZERO quantity
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = 200;
        bool reserved = true;

        // Mint the ERC721 tokens to seller. These tokens will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: listing zero quantity.");
        MintraDirectListings(marketplace).createListing(listingParams);
    }

    function test_revert_createListing_listingInvalidQuantity() public {
        // Sample listing parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 2; // Listing more than `1` quantity
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = 200;
        bool reserved = true;

        // Mint the ERC721 tokens to seller. These tokens will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: listing invalid quantity.");
        MintraDirectListings(marketplace).createListing(listingParams);
    }

    function test_revert_createListing_invalidStartTimestamp() public {
        uint256 blockTimestamp = 100 minutes;
        // Set block.timestamp
        vm.warp(blockTimestamp);

        // Sample listing parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = uint128(blockTimestamp - 61 minutes); // start time is less than block timestamp.
        uint128 endTimestamp = uint128(startTimestamp + 1);
        bool reserved = true;

        // Mint the ERC721 tokens to seller. These tokens will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: invalid startTimestamp.");
        MintraDirectListings(marketplace).createListing(listingParams);
    }

    function test_revert_createListing_invalidEndTimestamp() public {
        // Sample listing parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = uint128(startTimestamp - 1); // End timestamp is less than start timestamp.
        bool reserved = true;

        // Mint the ERC721 tokens to seller. These tokens will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: endTimestamp not greater than startTimestamp.");
        MintraDirectListings(marketplace).createListing(listingParams);
    }

    function test_revert_createListing_listingNonERC721OrERC1155Token() public {
        // Sample listing parameters.
        address assetContract = address(erc20);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = 200;
        bool reserved = true;

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.expectRevert("Marketplace: listed token must be ERC1155 or ERC721.");
        MintraDirectListings(marketplace).createListing(listingParams);
    }

    /*///////////////////////////////////////////////////////////////
                            Update listing
    //////////////////////////////////////////////////////////////*/

    function _setup_updateListing(
        uint256 tokenId
    ) private returns (uint256 listingId, IDirectListings.ListingParameters memory listingParams) {
        // listing parameters.
        address assetContract = address(erc721);
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = 200;
        bool reserved = true;

        // Mint the ERC721 tokens to seller. These tokens will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // List tokens.
        listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(seller);
        listingId = MintraDirectListings(marketplace).createListing(listingParams);
    }

    function test_state_updateListing() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParamsToUpdate) = _setup_updateListing(0);

        // Mint MORE ERC721 tokens to seller. A new tokenId will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        listingParamsToUpdate.pricePerToken = 2 ether;

        vm.prank(seller);
        MintraDirectListings(marketplace).updateListing(listingId, listingParamsToUpdate);

        // Test consequent state of the contract.

        // Seller is still owner of token.
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Total listings not incremented on update.
        assertEq(MintraDirectListings(marketplace).totalListings(), 1);

        // Fetch listing and verify state.
        IDirectListings.Listing memory listing = MintraDirectListings(marketplace).getListing(listingId);

        assertEq(listing.listingId, listingId);
        assertEq(listing.listingCreator, seller);
        assertEq(listing.assetContract, listingParamsToUpdate.assetContract);
        assertEq(listing.tokenId, 0);
        assertEq(listing.quantity, listingParamsToUpdate.quantity);
        assertEq(listing.currency, listingParamsToUpdate.currency);
        assertEq(listing.pricePerToken, listingParamsToUpdate.pricePerToken);
        assertEq(listing.startTimestamp, listingParamsToUpdate.startTimestamp);
        assertEq(listing.endTimestamp, listingParamsToUpdate.endTimestamp);
        assertEq(listing.reserved, listingParamsToUpdate.reserved);
        assertEq(uint256(listing.tokenType), uint256(IDirectListings.TokenType.ERC721));
    }

    function test_state_updateListing_start_time_in_past() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParamsToUpdate) = _setup_updateListing(0);

        // Mint MORE ERC721 tokens to seller. A new tokenId will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        listingParamsToUpdate.pricePerToken = 2 ether;

        // Update the start time of the listing
        uint256 expectedStartTimestamp = block.timestamp + 10;
        uint256 expectedEndTimestamp = type(uint128).max;

        listingParamsToUpdate.startTimestamp = uint128(block.timestamp);
        listingParamsToUpdate.endTimestamp = type(uint128).max;
        vm.warp(block.timestamp + 10); // Set the timestamp 10 seconds in the future

        vm.prank(seller);
        MintraDirectListings(marketplace).updateListing(listingId, listingParamsToUpdate);

        // Test consequent state of the contract.

        // Seller is still owner of token.
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Total listings not incremented on update.
        assertEq(MintraDirectListings(marketplace).totalListings(), 1);

        // Fetch listing and verify state.
        IDirectListings.Listing memory listing = MintraDirectListings(marketplace).getListing(listingId);

        assertEq(listing.listingId, listingId);
        assertEq(listing.listingCreator, seller);
        assertEq(listing.assetContract, listingParamsToUpdate.assetContract);
        assertEq(listing.tokenId, 0);
        assertEq(listing.quantity, listingParamsToUpdate.quantity);
        assertEq(listing.currency, listingParamsToUpdate.currency);
        assertEq(listing.pricePerToken, listingParamsToUpdate.pricePerToken);
        assertEq(listing.startTimestamp, expectedStartTimestamp);
        assertEq(listing.endTimestamp, expectedEndTimestamp);
        assertEq(listing.reserved, listingParamsToUpdate.reserved);
        assertEq(uint256(listing.tokenType), uint256(IDirectListings.TokenType.ERC721));
    }

    function test_revert_updateListing_notListingCreator() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParamsToUpdate) = _setup_updateListing(0);

        // Mint MORE ERC721 tokens to seller. A new tokenId will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        address notSeller = getActor(1000); // Someone other than the seller calls update.
        vm.prank(notSeller);
        vm.expectRevert("Marketplace: not listing creator.");
        MintraDirectListings(marketplace).updateListing(listingId, listingParamsToUpdate);
    }

    function test_revert_updateListing_notOwnerOfListedToken() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParamsToUpdate) = _setup_updateListing(0);

        // Mint MORE ERC721 tokens but NOT to seller. A new tokenId will be listed.
        address notSeller = getActor(1000);
        _setupERC721BalanceForSeller(notSeller, 1);

        // Approve Marketplace to transfer token.
        vm.prank(notSeller);
        erc721.setApprovalForAll(marketplace, true);

        // Transfer away owned token.
        vm.prank(seller);
        erc721.transferFrom(seller, address(0x1234), 0);

        vm.prank(seller);
        vm.expectRevert("Marketplace: not owner or approved tokens.");
        MintraDirectListings(marketplace).updateListing(listingId, listingParamsToUpdate);
    }

    function test_revert_updateListing_notApprovedMarketplaceToTransferToken() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParamsToUpdate) = _setup_updateListing(0);

        // Mint MORE ERC721 tokens to seller. A new tokenId will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Don't approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, false);

        vm.prank(seller);
        vm.expectRevert("Marketplace: not owner or approved tokens.");
        MintraDirectListings(marketplace).updateListing(listingId, listingParamsToUpdate);
    }

    function test_revert_updateListing_listingZeroQuantity() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParamsToUpdate) = _setup_updateListing(0);

        // Mint MORE ERC721 tokens to seller. A new tokenId will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        listingParamsToUpdate.quantity = 0; // Listing zero quantity

        vm.prank(seller);
        vm.expectRevert("Marketplace: listing zero quantity.");
        MintraDirectListings(marketplace).updateListing(listingId, listingParamsToUpdate);
    }

    function test_revert_updateListing_listingInvalidQuantity() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParamsToUpdate) = _setup_updateListing(0);

        // Mint MORE ERC721 tokens to seller. A new tokenId will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        listingParamsToUpdate.quantity = 2; // Listing more than `1` of the ERC721 token

        vm.prank(seller);
        vm.expectRevert("Marketplace: listing invalid quantity.");
        MintraDirectListings(marketplace).updateListing(listingId, listingParamsToUpdate);
    }

    function test_revert_updateListing_listingNonERC721OrERC1155Token() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParamsToUpdate) = _setup_updateListing(0);

        // Mint MORE ERC721 tokens to seller. A new tokenId will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        listingParamsToUpdate.assetContract = address(erc20); // Listing non ERC721 / ERC1155 token.

        vm.prank(seller);
        vm.expectRevert("Marketplace: listed token must be ERC1155 or ERC721.");
        MintraDirectListings(marketplace).updateListing(listingId, listingParamsToUpdate);
    }

    function test_revert_updateListing_invalidStartTimestamp() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParamsToUpdate) = _setup_updateListing(0);

        // Mint MORE ERC721 tokens to seller. A new tokenId will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        uint128 currentStartTimestamp = listingParamsToUpdate.startTimestamp;
        listingParamsToUpdate.startTimestamp = currentStartTimestamp - 1; // Retroactively decreasing startTimestamp.

        vm.warp(currentStartTimestamp + 50);
        vm.prank(seller);
        vm.expectRevert("Marketplace: listing already active.");
        MintraDirectListings(marketplace).updateListing(listingId, listingParamsToUpdate);
    }

    function test_revert_updateListing_invalidEndTimestamp() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParamsToUpdate) = _setup_updateListing(0);

        // Mint MORE ERC721 tokens to seller. A new tokenId will be listed.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        uint128 currentStartTimestamp = listingParamsToUpdate.startTimestamp;
        listingParamsToUpdate.endTimestamp = currentStartTimestamp - 1; // End timestamp less than startTimestamp

        vm.prank(seller);
        vm.expectRevert("Marketplace: endTimestamp not greater than startTimestamp.");
        MintraDirectListings(marketplace).updateListing(listingId, listingParamsToUpdate);
    }

    /*///////////////////////////////////////////////////////////////
                            Cancel listing
    //////////////////////////////////////////////////////////////*/

    function _setup_cancelListing(
        uint256 tokenId
    ) private returns (uint256 listingId, IDirectListings.Listing memory listing) {
        (listingId, ) = _setup_updateListing(tokenId);
        listing = MintraDirectListings(marketplace).getListing(listingId);
    }

    function test_state_cancelListing() public {
        (uint256 listingId, IDirectListings.Listing memory existingListingAtId) = _setup_cancelListing(0);

        // Verify existing listing at `listingId`
        assertEq(existingListingAtId.assetContract, address(erc721));

        vm.prank(seller);
        MintraDirectListings(marketplace).cancelListing(listingId);

        // status should be `CANCELLED`
        IDirectListings.Listing memory cancelledListing = MintraDirectListings(marketplace).getListing(
            listingId
        );
        assertTrue(cancelledListing.status == IDirectListings.Status.CANCELLED);
    }

    function test_revert_cancelListing_notListingCreator() public {
        (uint256 listingId, IDirectListings.Listing memory existingListingAtId) = _setup_cancelListing(0);

        // Verify existing listing at `listingId`
        assertEq(existingListingAtId.assetContract, address(erc721));

        address notSeller = getActor(1000);
        vm.prank(notSeller);
        vm.expectRevert("Marketplace: not listing creator.");
        MintraDirectListings(marketplace).cancelListing(listingId);
    }

    function test_revert_cancelListing_nonExistentListing() public {
        _setup_cancelListing(0);

        // Verify no listing exists at `nexListingId`
        uint256 nextListingId = MintraDirectListings(marketplace).totalListings();

        vm.prank(seller);
        vm.expectRevert("Marketplace: invalid listing.");
        MintraDirectListings(marketplace).cancelListing(nextListingId);
    }

    /*///////////////////////////////////////////////////////////////
                        Approve buyer for listing
    //////////////////////////////////////////////////////////////*/

    function _setup_approveBuyerForListing(uint256 tokenId) private returns (uint256 listingId) {
        (listingId, ) = _setup_updateListing(tokenId);
    }

    function test_state_approveBuyerForListing() public {
        uint256 listingId = _setup_approveBuyerForListing(0);
        bool toApprove = true;

        assertEq(MintraDirectListings(marketplace).getListing(listingId).reserved, true);

        // Seller approves buyer for reserved listing.
        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, toApprove);

        assertEq(MintraDirectListings(marketplace).isBuyerApprovedForListing(listingId, buyer), true);
    }

    function test_revert_approveBuyerForListing_notListingCreator() public {
        uint256 listingId = _setup_approveBuyerForListing(0);
        bool toApprove = true;

        assertEq(MintraDirectListings(marketplace).getListing(listingId).reserved, true);

        // Someone other than the seller approves buyer for reserved listing.
        address notSeller = getActor(1000);
        vm.prank(notSeller);
        vm.expectRevert("Marketplace: not listing creator.");
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, toApprove);
    }

    function test_revert_approveBuyerForListing_listingNotReserved() public {
        (uint256 listingId, IDirectListings.ListingParameters memory listingParamsToUpdate) = _setup_updateListing(0);
        bool toApprove = true;

        assertEq(MintraDirectListings(marketplace).getListing(listingId).reserved, true);

        listingParamsToUpdate.reserved = false;

        vm.prank(seller);
        MintraDirectListings(marketplace).updateListing(listingId, listingParamsToUpdate);

        assertEq(MintraDirectListings(marketplace).getListing(listingId).reserved, false);

        // Seller approves buyer for reserved listing.
        vm.prank(seller);
        vm.expectRevert("Marketplace: listing not reserved.");
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, toApprove);
    }

    /*///////////////////////////////////////////////////////////////
                        Approve currency for listing
    //////////////////////////////////////////////////////////////*/

    function _setup_approveCurrencyForListing(uint256 tokenId) private returns (uint256 listingId) {
        (listingId, ) = _setup_updateListing(tokenId);
    }

    function test_state_approveCurrencyForListing() public {
        uint256 listingId = _setup_approveCurrencyForListing(0);
        address currencyToApprove = NATIVE_TOKEN;
        uint256 pricePerTokenForCurrency = 2 ether;

        // Seller approves buyer for reserved listing.
        vm.prank(seller);
        MintraDirectListings(marketplace).approveCurrencyForListing(
            listingId,
            currencyToApprove,
            pricePerTokenForCurrency
        );

        assertEq(
            MintraDirectListings(marketplace).isCurrencyApprovedForListing(listingId, NATIVE_TOKEN),
            true
        );
        assertEq(
            MintraDirectListings(marketplace).currencyPriceForListing(listingId, NATIVE_TOKEN),
            pricePerTokenForCurrency
        );
    }

    function test_revert_approveCurrencyForListing_notListingCreator() public {
        uint256 listingId = _setup_approveCurrencyForListing(0);
        address currencyToApprove = NATIVE_TOKEN;
        uint256 pricePerTokenForCurrency = 2 ether;

        // Someone other than seller approves buyer for reserved listing.
        address notSeller = getActor(1000);
        vm.prank(notSeller);
        vm.expectRevert("Marketplace: not listing creator.");
        MintraDirectListings(marketplace).approveCurrencyForListing(
            listingId,
            currencyToApprove,
            pricePerTokenForCurrency
        );
    }

    function test_revert_approveCurrencyForListing_reApprovingMainCurrency() public {
        uint256 listingId = _setup_approveCurrencyForListing(0);
        address currencyToApprove = MintraDirectListings(marketplace).getListing(listingId).currency;
        uint256 pricePerTokenForCurrency = 2 ether;

        // Seller approves buyer for reserved listing.
        vm.prank(seller);
        vm.expectRevert("Marketplace: approving listing currency with different price.");
        MintraDirectListings(marketplace).approveCurrencyForListing(
            listingId,
            currencyToApprove,
            pricePerTokenForCurrency
        );
    }

    /*///////////////////////////////////////////////////////////////
                        Buy from listing
    //////////////////////////////////////////////////////////////*/

    function _setup_buyFromListing(
        uint256 tokenId
    ) private returns (uint256 listingId, IDirectListings.Listing memory listing) {
        (listingId, ) = _setup_updateListing(tokenId);
        listing = MintraDirectListings(marketplace).getListing(listingId);
    }

    function test_state_buyFromListing_with_mint_token() public {
        uint256 listingId = _createListing(seller, address(erc20Aux));
        IDirectListings.Listing memory listing = MintraDirectListings(marketplace).getListing(listingId);

        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity;
        address currency = listing.currency;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;
        uint256 platformFeeBpsMint = MintraDirectListings(marketplace).platformFeeBpsMint();
        uint256 platformFee = (totalPrice * platformFeeBpsMint) / 10000;

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);
        assertIsNotOwnerERC721(address(erc721), buyer, tokenIds);

        // Mint requisite total price to buyer.
        erc20Aux.mint(buyer, totalPrice);
        assertBalERC20Eq(address(erc20Aux), buyer, totalPrice);
        assertBalERC20Eq(address(erc20Aux), seller, 0);

        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20Aux.increaseAllowance(marketplace, totalPrice);

        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.prank(buyer);

        {
            uint256[] memory listingIdArray = new uint256[](1);
            listingIdArray[0] = listingId;

            address[] memory buyForArray = new address[](1);
            buyForArray[0] = buyFor;

            uint256[] memory quantityToBuyArray = new uint256[](1);
            quantityToBuyArray[0] = quantityToBuy;

            address[] memory currencyArray = new address[](1);
            currencyArray[0] = currency;

            uint256[] memory expectedTotalPriceArray = new uint256[](1);
            expectedTotalPriceArray[0] = totalPrice;

            MintraDirectListings(marketplace).bulkBuyFromListing(
                listingIdArray,
                buyForArray,
                quantityToBuyArray,
                currencyArray,
                expectedTotalPriceArray
            );
        }

        // Verify that buyer is owner of listed tokens, post-sale.
        assertIsOwnerERC721(address(erc721), buyer, tokenIds);
        assertIsNotOwnerERC721(address(erc721), seller, tokenIds);

        // Verify seller is paid total price.
        assertBalERC20Eq(address(erc20Aux), buyer, 0);
        assertBalERC20Eq(address(erc20Aux), seller, totalPrice - platformFee);

        if (quantityToBuy == listing.quantity) {
            // Verify listing status is `COMPLETED` if listing tokens are all bought.
            IDirectListings.Listing memory completedListing = MintraDirectListings(marketplace)
                .getListing(listingId);
            assertTrue(completedListing.status == IDirectListings.Status.COMPLETED);
        }
    }

    function test_state_buyFromListing_721() public {
        (uint256 listingId, IDirectListings.Listing memory listing) = _setup_buyFromListing(0);

        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity;
        address currency = listing.currency;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;
        uint256 platformFeeBps = MintraDirectListings(marketplace).platformFeeBps();
        uint256 platformFee = (totalPrice * platformFeeBps) / 10000;

        // Seller approves buyer for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, true);

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);
        assertIsNotOwnerERC721(address(erc721), buyer, tokenIds);

        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice);
        assertBalERC20Eq(address(erc20), buyer, totalPrice);
        assertBalERC20Eq(address(erc20), seller, 0);

        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, totalPrice);

        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.prank(buyer);

        {
            uint256[] memory listingIdArray = new uint256[](1);
            listingIdArray[0] = listingId;

            address[] memory buyForArray = new address[](1);
            buyForArray[0] = buyFor;

            uint256[] memory quantityToBuyArray = new uint256[](1);
            quantityToBuyArray[0] = quantityToBuy;

            address[] memory currencyArray = new address[](1);
            currencyArray[0] = currency;

            uint256[] memory expectedTotalPriceArray = new uint256[](1);
            expectedTotalPriceArray[0] = totalPrice;

            MintraDirectListings(marketplace).bulkBuyFromListing(
                listingIdArray,
                buyForArray,
                quantityToBuyArray,
                currencyArray,
                expectedTotalPriceArray
            );
        }
        // Verify that buyer is owner of listed tokens, post-sale.
        assertIsOwnerERC721(address(erc721), buyer, tokenIds);
        assertIsNotOwnerERC721(address(erc721), seller, tokenIds);

        // Verify seller is paid total price.
        assertBalERC20Eq(address(erc20), buyer, 0);
        assertBalERC20Eq(address(erc20), seller, totalPrice - platformFee);

        if (quantityToBuy == listing.quantity) {
            // Verify listing status is `COMPLETED` if listing tokens are all bought.
            IDirectListings.Listing memory completedListing = MintraDirectListings(marketplace)
                .getListing(listingId);
            assertTrue(completedListing.status == IDirectListings.Status.COMPLETED);
        }
    }

    function test_state_buyFromListing_multi_721() public {
        vm.prank(seller);
        (uint256 listingIdOne, IDirectListings.Listing memory listingOne) = _setup_buyFromListing(0);
        vm.prank(seller);
        (uint256 listingIdTwo, IDirectListings.Listing memory listingTwo) = _setup_buyFromListing(1);

        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingIdOne, buyer, true);
        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingIdTwo, buyer, true);

        address buyFor = buyer;
        uint256 quantityToBuy = listingOne.quantity;
        address currency = listingOne.currency;
        uint256 pricePerToken = listingOne.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;
        uint256 platformFeeBps = MintraDirectListings(marketplace).platformFeeBps();
        uint256 platformFee = (totalPrice * platformFeeBps) / 10000;

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);
        assertIsNotOwnerERC721(address(erc721), buyer, tokenIds);

        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice + totalPrice);
        assertBalERC20Eq(address(erc20), buyer, totalPrice + totalPrice);
        assertBalERC20Eq(address(erc20), seller, 0);

        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, totalPrice + totalPrice);

        // Buy tokens from listing.
        vm.warp(listingTwo.startTimestamp);
        {
            uint256[] memory listingIdArray = new uint256[](2);
            listingIdArray[0] = listingIdOne;
            listingIdArray[1] = listingIdTwo;

            address[] memory buyForArray = new address[](2);
            buyForArray[0] = buyFor;
            buyForArray[1] = buyFor;

            uint256[] memory quantityToBuyArray = new uint256[](2);
            quantityToBuyArray[0] = quantityToBuy;
            quantityToBuyArray[1] = quantityToBuy;

            address[] memory currencyArray = new address[](2);
            currencyArray[0] = currency;
            currencyArray[1] = currency;

            uint256[] memory expectedTotalPriceArray = new uint256[](2);
            expectedTotalPriceArray[0] = totalPrice;
            expectedTotalPriceArray[1] = totalPrice;

            vm.prank(buyer);
            MintraDirectListings(marketplace).bulkBuyFromListing(
                listingIdArray,
                buyForArray,
                quantityToBuyArray,
                currencyArray,
                expectedTotalPriceArray
            );
        }

        // Verify that buyer is owner of listed tokens, post-sale.
        assertIsOwnerERC721(address(erc721), buyer, tokenIds);
        assertIsNotOwnerERC721(address(erc721), seller, tokenIds);

        // Verify seller is paid total price.
        assertBalERC20Eq(address(erc20), buyer, 0);
        uint256 sellerPayout = totalPrice + totalPrice - platformFee - platformFee;
        assertBalERC20Eq(address(erc20), seller, sellerPayout);
    }

    function test_state_buyFromListing_1155() public {
        // Create the listing
        uint256 listingId = createListing_1155(0, 1);

        IDirectListings.Listing memory listing = MintraDirectListings(marketplace).getListing(listingId);

        address buyFor = buyer;
        uint256 tokenId = listing.tokenId;
        uint256 quantity = listing.quantity;
        uint256 quantityToBuy = listing.quantity;
        address currency = listing.currency;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;
        uint256 platformFeeBps = MintraDirectListings(marketplace).platformFeeBps();
        uint256 platformFee = (totalPrice * platformFeeBps) / 10000;

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        uint256[] memory amounts = new uint256[](1);
        amounts[0] = quantity;

        assertBalERC1155Eq(address(erc1155), seller, tokenIds, amounts);

        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice);
        assertBalERC20Eq(address(erc20), buyer, totalPrice);
        assertBalERC20Eq(address(erc20), seller, 0);

        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, totalPrice);

        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.prank(buyer);
        {
            uint256[] memory listingIdArray = new uint256[](1);
            listingIdArray[0] = listingId;

            address[] memory buyForArray = new address[](1);
            buyForArray[0] = buyFor;

            uint256[] memory quantityToBuyArray = new uint256[](1);
            quantityToBuyArray[0] = quantityToBuy;

            address[] memory currencyArray = new address[](1);
            currencyArray[0] = currency;

            uint256[] memory expectedTotalPriceArray = new uint256[](1);
            expectedTotalPriceArray[0] = totalPrice;

            MintraDirectListings(marketplace).bulkBuyFromListing(
                listingIdArray,
                buyForArray,
                quantityToBuyArray,
                currencyArray,
                expectedTotalPriceArray
            );
        }

        // Verify that buyer is owner of listed tokens, post-sale.
        assertBalERC1155Eq(address(erc1155), buyer, tokenIds, amounts);

        // Verify seller is paid total price.
        assertBalERC20Eq(address(erc20), buyer, 0);
        assertBalERC20Eq(address(erc20), seller, totalPrice - platformFee);

        if (quantityToBuy == listing.quantity) {
            // Verify listing status is `COMPLETED` if listing tokens are all bought.
            IDirectListings.Listing memory completedListing = MintraDirectListings(marketplace)
                .getListing(listingId);
            assertTrue(completedListing.status == IDirectListings.Status.COMPLETED);
        }
    }

    function test_state_buyFromListing_multi_1155() public {
        vm.prank(seller);
        uint256 listingIdOne = createListing_1155(0, 1);
        IDirectListings.Listing memory listingOne = MintraDirectListings(marketplace).getListing(
            listingIdOne
        );

        vm.prank(seller);
        uint256 listingIdTwo = createListing_1155(1, 2);
        IDirectListings.Listing memory listingTwo = MintraDirectListings(marketplace).getListing(
            listingIdTwo
        );

        address buyFor = buyer;
        uint256 quantityToBuy = listingOne.quantity;
        address currency = listingOne.currency;
        uint256 pricePerToken = listingOne.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;
        uint256 platformFeeBps = MintraDirectListings(marketplace).platformFeeBps();
        uint256 platformFee = (totalPrice * platformFeeBps) / 10000;

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = 0;
        tokenIds[1] = 1;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 2;
        amounts[1] = 2;

        assertBalERC1155Eq(address(erc1155), seller, tokenIds, amounts);

        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice + totalPrice);
        assertBalERC20Eq(address(erc20), buyer, totalPrice + totalPrice);
        assertBalERC20Eq(address(erc20), seller, 0);

        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, totalPrice + totalPrice);

        // Buy tokens from listing.
        vm.warp(listingTwo.startTimestamp);
        {
            uint256[] memory listingIdArray = new uint256[](2);
            listingIdArray[0] = listingIdOne;
            listingIdArray[1] = listingIdTwo;

            address[] memory buyForArray = new address[](2);
            buyForArray[0] = buyFor;
            buyForArray[1] = buyFor;

            uint256[] memory quantityToBuyArray = new uint256[](2);
            quantityToBuyArray[0] = quantityToBuy;
            quantityToBuyArray[1] = quantityToBuy;

            address[] memory currencyArray = new address[](2);
            currencyArray[0] = currency;
            currencyArray[1] = currency;

            uint256[] memory expectedTotalPriceArray = new uint256[](2);
            expectedTotalPriceArray[0] = totalPrice;
            expectedTotalPriceArray[1] = totalPrice;

            vm.prank(buyer);
            MintraDirectListings(marketplace).bulkBuyFromListing(
                listingIdArray,
                buyForArray,
                quantityToBuyArray,
                currencyArray,
                expectedTotalPriceArray
            );
        }

        // Verify that buyer is owner of listed tokens, post-sale.
        assertBalERC1155Eq(address(erc1155), buyer, tokenIds, amounts);

        // Verify seller is paid total price.
        assertBalERC20Eq(address(erc20), buyer, 0);
        uint256 sellerPayout = totalPrice + totalPrice - platformFee - platformFee;
        assertBalERC20Eq(address(erc20), seller, sellerPayout);
    }

    function test_state_bulkBuyFromListing_nativeToken() public {
        (uint256 listingId, IDirectListings.Listing memory listing) = _setup_buyFromListing(0);

        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity;
        address currency = NATIVE_TOKEN;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;
        uint256 platformFeeBps = MintraDirectListings(marketplace).platformFeeBps();
        uint256 platformFee = (totalPrice * platformFeeBps) / 10000;

        // Approve NATIVE_TOKEN for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveCurrencyForListing(listingId, currency, pricePerToken);

        // Seller approves buyer for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, true);

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);
        assertIsNotOwnerERC721(address(erc721), buyer, tokenIds);

        // Deal requisite total price to buyer.
        vm.deal(buyer, totalPrice);
        uint256 buyerBalBefore = buyer.balance;
        uint256 sellerBalBefore = seller.balance;

        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.prank(buyer);
        {
            uint256[] memory listingIdArray = new uint256[](1);
            listingIdArray[0] = listingId;

            address[] memory buyForArray = new address[](1);
            buyForArray[0] = buyFor;

            uint256[] memory quantityToBuyArray = new uint256[](1);
            quantityToBuyArray[0] = quantityToBuy;

            address[] memory currencyArray = new address[](1);
            currencyArray[0] = currency;

            uint256[] memory expectedTotalPriceArray = new uint256[](1);
            expectedTotalPriceArray[0] = totalPrice;

            MintraDirectListings(marketplace).bulkBuyFromListing{ value: totalPrice }(
                listingIdArray,
                buyForArray,
                quantityToBuyArray,
                currencyArray,
                expectedTotalPriceArray
            );
        }

        // Verify that buyer is owner of listed tokens, post-sale.
        assertIsOwnerERC721(address(erc721), buyer, tokenIds);
        assertIsNotOwnerERC721(address(erc721), seller, tokenIds);

        // Verify seller is paid total price.
        assertEq(buyer.balance, buyerBalBefore - totalPrice);
        assertEq(seller.balance, sellerBalBefore + (totalPrice - platformFee));

        if (quantityToBuy == listing.quantity) {
            // Verify listing status is `COMPLETED` if listing tokens are all bought.
            IDirectListings.Listing memory completedListing = MintraDirectListings(marketplace)
                .getListing(listingId);
            assertTrue(completedListing.status == IDirectListings.Status.COMPLETED);
        }
    }

    function test_revert_bulkBuyFromListing_nativeToken_incorrectValueSent() public {
        (uint256 listingId, IDirectListings.Listing memory listing) = _setup_buyFromListing(0);

        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity;
        address currency = NATIVE_TOKEN;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;

        // Approve NATIVE_TOKEN for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveCurrencyForListing(listingId, currency, pricePerToken);

        // Seller approves buyer for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, true);

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);
        assertIsNotOwnerERC721(address(erc721), buyer, tokenIds);

        // Deal requisite total price to buyer.
        vm.deal(buyer, totalPrice);

        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.prank(buyer);
        vm.expectRevert("native token transfer failed");
        {
            uint256[] memory listingIdArray = new uint256[](1);
            listingIdArray[0] = listingId;

            address[] memory buyForArray = new address[](1);
            buyForArray[0] = buyFor;

            uint256[] memory quantityToBuyArray = new uint256[](1);
            quantityToBuyArray[0] = quantityToBuy;

            address[] memory currencyArray = new address[](1);
            currencyArray[0] = currency;

            uint256[] memory expectedTotalPriceArray = new uint256[](1);
            expectedTotalPriceArray[0] = totalPrice;

            MintraDirectListings(marketplace).bulkBuyFromListing{ value: totalPrice - 1 }(
                listingIdArray,
                buyForArray,
                quantityToBuyArray,
                currencyArray,
                expectedTotalPriceArray
            );
        }
    }

    function test_revert_buyFromListing_unexpectedTotalPrice() public {
        (uint256 listingId, IDirectListings.Listing memory listing) = _setup_buyFromListing(0);

        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity;
        address currency = NATIVE_TOKEN;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;

        // Approve NATIVE_TOKEN for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveCurrencyForListing(listingId, currency, pricePerToken);

        // Seller approves buyer for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, true);

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);
        assertIsNotOwnerERC721(address(erc721), buyer, tokenIds);

        // Deal requisite total price to buyer.
        vm.deal(buyer, totalPrice);

        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.prank(buyer);
        vm.expectRevert("Unexpected total price");

        {
            uint256[] memory listingIdArray = new uint256[](1);
            listingIdArray[0] = listingId;

            address[] memory buyForArray = new address[](1);
            buyForArray[0] = buyFor;

            uint256[] memory quantityToBuyArray = new uint256[](1);
            quantityToBuyArray[0] = quantityToBuy;

            address[] memory currencyArray = new address[](1);
            currencyArray[0] = currency;

            uint256[] memory expectedTotalPriceArray = new uint256[](1);
            expectedTotalPriceArray[0] = totalPrice + 1;

            MintraDirectListings(marketplace).bulkBuyFromListing{ value: totalPrice - 1 }(
                listingIdArray,
                buyForArray,
                quantityToBuyArray,
                currencyArray,
                expectedTotalPriceArray
            );
        }
    }

    function test_revert_buyFromListing_invalidCurrency() public {
        (uint256 listingId, IDirectListings.Listing memory listing) = _setup_buyFromListing(0);

        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;

        // Seller approves buyer for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, true);

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);
        assertIsNotOwnerERC721(address(erc721), buyer, tokenIds);

        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice);
        assertBalERC20Eq(address(erc20), buyer, totalPrice);
        assertBalERC20Eq(address(erc20), seller, 0);

        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, totalPrice);

        // Buy tokens from listing.

        assertEq(listing.currency, address(erc20));
        assertEq(
            MintraDirectListings(marketplace).isCurrencyApprovedForListing(listingId, NATIVE_TOKEN),
            false
        );

        vm.warp(listing.startTimestamp);
        vm.prank(buyer);
        vm.expectRevert("Paying in invalid currency.");

        uint256[] memory listingIdArray = new uint256[](1);
        listingIdArray[0] = listingId;

        address[] memory buyForArray = new address[](1);
        buyForArray[0] = buyFor;

        uint256[] memory quantityToBuyArray = new uint256[](1);
        quantityToBuyArray[0] = quantityToBuy;

        address[] memory currencyArray = new address[](1);
        currencyArray[0] = NATIVE_TOKEN;

        uint256[] memory expectedTotalPriceArray = new uint256[](1);
        expectedTotalPriceArray[0] = totalPrice;

        MintraDirectListings(marketplace).bulkBuyFromListing(
            listingIdArray,
            buyForArray,
            quantityToBuyArray,
            currencyArray,
            expectedTotalPriceArray
        );
    }

    function test_revert_buyFromListing_buyerBalanceLessThanPrice() public {
        (uint256 listingId, IDirectListings.Listing memory listing) = _setup_buyFromListing(0);

        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity;
        address currency = listing.currency;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;

        // Seller approves buyer for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, true);

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);
        assertIsNotOwnerERC721(address(erc721), buyer, tokenIds);

        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice - 1); // Buyer balance less than total price
        assertBalERC20Eq(address(erc20), buyer, totalPrice - 1);
        assertBalERC20Eq(address(erc20), seller, 0);

        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, totalPrice);

        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.prank(buyer);
        vm.expectRevert("!BAL20");

        uint256[] memory listingIdArray = new uint256[](1);
        listingIdArray[0] = listingId;

        address[] memory buyForArray = new address[](1);
        buyForArray[0] = buyFor;

        uint256[] memory quantityToBuyArray = new uint256[](1);
        quantityToBuyArray[0] = quantityToBuy;

        address[] memory currencyArray = new address[](1);
        currencyArray[0] = currency;

        uint256[] memory expectedTotalPriceArray = new uint256[](1);
        expectedTotalPriceArray[0] = totalPrice;

        MintraDirectListings(marketplace).bulkBuyFromListing(
            listingIdArray,
            buyForArray,
            quantityToBuyArray,
            currencyArray,
            expectedTotalPriceArray
        );
    }

    function test_revert_buyFromListing_notApprovedMarketplaceToTransferPrice() public {
        (uint256 listingId, IDirectListings.Listing memory listing) = _setup_buyFromListing(0);

        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity;
        address currency = listing.currency;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;

        // Seller approves buyer for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, true);

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);
        assertIsNotOwnerERC721(address(erc721), buyer, tokenIds);

        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice);
        assertBalERC20Eq(address(erc20), buyer, totalPrice);
        assertBalERC20Eq(address(erc20), seller, 0);

        // Don't approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.approve(marketplace, 0);

        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.prank(buyer);
        vm.expectRevert("!BAL20");

        uint256[] memory listingIdArray = new uint256[](1);
        listingIdArray[0] = listingId;

        address[] memory buyForArray = new address[](1);
        buyForArray[0] = buyFor;

        uint256[] memory quantityToBuyArray = new uint256[](1);
        quantityToBuyArray[0] = quantityToBuy;

        address[] memory currencyArray = new address[](1);
        currencyArray[0] = currency;

        uint256[] memory expectedTotalPriceArray = new uint256[](1);
        expectedTotalPriceArray[0] = totalPrice;

        MintraDirectListings(marketplace).bulkBuyFromListing(
            listingIdArray,
            buyForArray,
            quantityToBuyArray,
            currencyArray,
            expectedTotalPriceArray
        );
    }

    function test_revert_buyFromListing_buyingZeroQuantity() public {
        (uint256 listingId, IDirectListings.Listing memory listing) = _setup_buyFromListing(0);

        address buyFor = buyer;
        uint256 quantityToBuy = 0; // Buying zero quantity
        address currency = listing.currency;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;

        // Seller approves buyer for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, true);

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);
        assertIsNotOwnerERC721(address(erc721), buyer, tokenIds);

        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice);
        assertBalERC20Eq(address(erc20), buyer, totalPrice);
        assertBalERC20Eq(address(erc20), seller, 0);

        // Don't approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, totalPrice);

        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.prank(buyer);
        vm.expectRevert("Buying invalid quantity");

        uint256[] memory listingIdArray = new uint256[](1);
        listingIdArray[0] = listingId;

        address[] memory buyForArray = new address[](1);
        buyForArray[0] = buyFor;

        uint256[] memory quantityToBuyArray = new uint256[](1);
        quantityToBuyArray[0] = quantityToBuy;

        address[] memory currencyArray = new address[](1);
        currencyArray[0] = currency;

        uint256[] memory expectedTotalPriceArray = new uint256[](1);
        expectedTotalPriceArray[0] = totalPrice;

        MintraDirectListings(marketplace).bulkBuyFromListing(
            listingIdArray,
            buyForArray,
            quantityToBuyArray,
            currencyArray,
            expectedTotalPriceArray
        );
    }

    function test_revert_buyFromListing_buyingMoreQuantityThanListed() public {
        (uint256 listingId, IDirectListings.Listing memory listing) = _setup_buyFromListing(0);

        address buyFor = buyer;
        uint256 quantityToBuy = listing.quantity + 1; // Buying more than listed.
        address currency = listing.currency;
        uint256 pricePerToken = listing.pricePerToken;
        uint256 totalPrice = pricePerToken * quantityToBuy;

        // Seller approves buyer for listing
        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, true);

        // Verify that seller is owner of listed tokens, pre-sale.
        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = 0;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);
        assertIsNotOwnerERC721(address(erc721), buyer, tokenIds);

        // Mint requisite total price to buyer.
        erc20.mint(buyer, totalPrice);
        assertBalERC20Eq(address(erc20), buyer, totalPrice);
        assertBalERC20Eq(address(erc20), seller, 0);

        // Don't approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, totalPrice);

        // Buy tokens from listing.
        vm.warp(listing.startTimestamp);
        vm.prank(buyer);
        vm.expectRevert("Buying invalid quantity");

        uint256[] memory listingIdArray = new uint256[](1);
        listingIdArray[0] = listingId;

        address[] memory buyForArray = new address[](1);
        buyForArray[0] = buyFor;

        uint256[] memory quantityToBuyArray = new uint256[](1);
        quantityToBuyArray[0] = quantityToBuy;

        address[] memory currencyArray = new address[](1);
        currencyArray[0] = currency;

        uint256[] memory expectedTotalPriceArray = new uint256[](1);
        expectedTotalPriceArray[0] = totalPrice;

        MintraDirectListings(marketplace).bulkBuyFromListing(
            listingIdArray,
            buyForArray,
            quantityToBuyArray,
            currencyArray,
            expectedTotalPriceArray
        );
    }

    /*///////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/
    function test_getAllListing() public {
        // Create the listing
        createListing_1155(0, 1);

        IDirectListings.Listing[] memory listings = MintraDirectListings(marketplace).getAllListings(
            0,
            0
        );

        assertEq(listings.length, 1);

        IDirectListings.Listing memory listing = listings[0];

        assertEq(listing.assetContract, address(erc1155));
        assertEq(listing.tokenId, 0);
        assertEq(listing.quantity, 2);
        assertEq(listing.currency, address(erc20));
        assertEq(listing.pricePerToken, 1 ether);
        assertEq(listing.startTimestamp, 100);
        assertEq(listing.endTimestamp, 200);
        assertEq(listing.reserved, false);
    }

    function test_getAllValidListings() public {
        // Create the listing
        createListing_1155(0, 1);

        IDirectListings.Listing[] memory listingsAll = MintraDirectListings(marketplace).getAllListings(
            0,
            0
        );

        assertEq(listingsAll.length, 1);

        vm.warp(listingsAll[0].startTimestamp);
        IDirectListings.Listing[] memory listings = MintraDirectListings(marketplace)
            .getAllValidListings(0, 0);

        assertEq(listings.length, 1);

        IDirectListings.Listing memory listing = listings[0];

        assertEq(listing.assetContract, address(erc1155));
        assertEq(listing.tokenId, 0);
        assertEq(listing.quantity, 2);
        assertEq(listing.currency, address(erc20));
        assertEq(listing.pricePerToken, 1 ether);
        assertEq(listing.startTimestamp, 100);
        assertEq(listing.endTimestamp, 200);
        assertEq(listing.reserved, false);
    }

    function test_currencyPriceForListing_fail() public {
        // Create the listing
        createListing_1155(0, 1);

        vm.expectRevert("Currency not approved for listing");
        MintraDirectListings(marketplace).currencyPriceForListing(0, address(erc20Aux));
    }

    function _createListing(address _seller, address currency) private returns (uint256 listingId) {
        // Sample listing parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        uint256 pricePerToken = 1 ether;
        uint128 startTimestamp = 100;
        uint128 endTimestamp = 200;
        bool reserved = false;

        // Mint the ERC721 tokens to seller. These tokens will be listed.
        _setupERC721BalanceForSeller(_seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), _seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(_seller);
        erc721.setApprovalForAll(marketplace, true);

        // List tokens.
        IDirectListings.ListingParameters memory listingParams = IDirectListings.ListingParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            pricePerToken,
            startTimestamp,
            endTimestamp,
            reserved
        );

        vm.prank(_seller);
        listingId = MintraDirectListings(marketplace).createListing(listingParams);
    }

    function test_audit_native_tokens_locked() public {
        (uint256 listingId, IDirectListings.Listing memory existingListing) = _setup_buyFromListing(0);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingListing.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingListing.assetContract, address(erc721));

        vm.warp(existingListing.startTimestamp);

        // No ether is locked in contract
        assertEq(marketplace.balance, 0);

        // buy from listing
        erc20.mint(buyer, 10 ether);
        vm.deal(buyer, 1 ether);

        vm.prank(seller);
        MintraDirectListings(marketplace).approveBuyerForListing(listingId, buyer, true);

        vm.startPrank(buyer);
        erc20.approve(marketplace, 10 ether);

        vm.expectRevert("Incorrect PLS amount sent");

        uint256[] memory listingIdArray = new uint256[](1);
        listingIdArray[0] = listingId;

        address[] memory buyForArray = new address[](1);
        buyForArray[0] = buyer;

        uint256[] memory quantityToBuyArray = new uint256[](1);
        quantityToBuyArray[0] = 1;

        address[] memory currencyArray = new address[](1);
        currencyArray[0] = address(erc20);

        uint256[] memory expectedTotalPriceArray = new uint256[](1);
        expectedTotalPriceArray[0] = 1 ether;

        MintraDirectListings(marketplace).bulkBuyFromListing{ value: 1 ether }(
            listingIdArray,
            buyForArray,
            quantityToBuyArray,
            currencyArray,
            expectedTotalPriceArray
        );

        vm.stopPrank();

        // 1 ether is temporary locked in contract
        assertEq(marketplace.balance, 0 ether);
    }

    function test_set_platform_fee() public {
        uint256 platformFeeBps = MintraDirectListings(marketplace).platformFeeBps();
        assertEq(platformFeeBps, 225);

        vm.prank(wizard);
        MintraDirectListings(marketplace).setPlatformFeeBps(369);

        platformFeeBps = MintraDirectListings(marketplace).platformFeeBps();

        assertEq(platformFeeBps, 369);
    }

    function test_fuzz_set_platform_fee(uint256 platformFeeBps) public {
        vm.assume(platformFeeBps <= 369);

        vm.prank(wizard);
        MintraDirectListings(marketplace).setPlatformFeeBps(platformFeeBps);

        uint256 expectedPlatformFeeBps = MintraDirectListings(marketplace).platformFeeBps();

        assertEq(expectedPlatformFeeBps, platformFeeBps);
    }

    function test_set_platform_fee_fail() public {
        vm.prank(wizard);
        vm.expectRevert("Fee not in range");
        MintraDirectListings(marketplace).setPlatformFeeBps(1000);
    }
}
