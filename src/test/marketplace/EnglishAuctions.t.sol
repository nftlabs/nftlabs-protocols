// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

// Test helper imports
import "../utils/BaseTest.sol";

// Test contracts and interfaces
import { PluginMap, IPluginMap } from "contracts/extension/plugin/PluginMap.sol";
import { RoyaltyPaymentsLogic } from "contracts/extension/plugin/RoyaltyPayments.sol";
import { MarketplaceV3, IPlatformFee } from "contracts/prebuilts/marketplace/entrypoint/MarketplaceV3.sol";
import { EnglishAuctionsLogic } from "contracts/prebuilts/marketplace/english-auctions/EnglishAuctionsLogic.sol";
import { TWProxy } from "contracts/infra/TWProxy.sol";
import { ERC721Base } from "contracts/base/ERC721Base.sol";
import { MockRoyaltyEngineV1 } from "../mocks/MockRoyaltyEngineV1.sol";

import { IEnglishAuctions } from "contracts/prebuilts/marketplace/IMarketplace.sol";

import "@thirdweb-dev/dynamic-contracts/src/interface/IExtension.sol";

contract MarketplaceEnglishAuctionsTest is BaseTest, IExtension {
    // Target contract
    address public marketplace;

    // Participants
    address public marketplaceDeployer;
    address public seller;
    address public buyer;

    function setUp() public override {
        super.setUp();

        marketplaceDeployer = getActor(1);
        seller = getActor(2);
        buyer = getActor(3);

        // Deploy implementation.
        Extension[] memory extensions = _setupExtensions();
        address impl = address(
            new MarketplaceV3(MarketplaceV3.MarketplaceConstructorParams(extensions, address(0), address(weth)))
        );

        vm.prank(marketplaceDeployer);
        marketplace = address(
            new TWProxy(
                impl,
                abi.encodeCall(
                    MarketplaceV3.initialize,
                    (marketplaceDeployer, "", new address[](0), marketplaceDeployer, 0)
                )
            )
        );

        // Setup roles for seller and assets
        vm.startPrank(marketplaceDeployer);
        Permissions(marketplace).revokeRole(keccak256("ASSET_ROLE"), address(0));
        Permissions(marketplace).revokeRole(keccak256("LISTER_ROLE"), address(0));
        Permissions(marketplace).grantRole(keccak256("LISTER_ROLE"), seller);
        Permissions(marketplace).grantRole(keccak256("ASSET_ROLE"), address(erc721));
        Permissions(marketplace).grantRole(keccak256("ASSET_ROLE"), address(erc1155));

        vm.stopPrank();

        vm.label(impl, "MarketplaceV3_Impl");
        vm.label(marketplace, "Marketplace");
        vm.label(seller, "Seller");
        vm.label(buyer, "Buyer");
        vm.label(address(erc721), "ERC721_Token");
        vm.label(address(erc1155), "ERC1155_Token");
    }

    function _setupExtensions() internal returns (Extension[] memory extensions) {
        extensions = new Extension[](1);

        // Deploy `EnglishAuctions`
        address englishAuctions = address(new EnglishAuctionsLogic(address(weth)));
        vm.label(englishAuctions, "EnglishAuctions_Extension");

        // Extension: EnglishAuctionsLogic
        Extension memory extension_englishAuctions;
        extension_englishAuctions.metadata = ExtensionMetadata({
            name: "EnglishAuctionsLogic",
            metadataURI: "ipfs://EnglishAuctions",
            implementation: englishAuctions
        });

        extension_englishAuctions.functions = new ExtensionFunction[](12);
        extension_englishAuctions.functions[0] = ExtensionFunction(
            EnglishAuctionsLogic.totalAuctions.selector,
            "totalAuctions()"
        );
        extension_englishAuctions.functions[1] = ExtensionFunction(
            EnglishAuctionsLogic.createAuction.selector,
            "createAuction((address,uint256,uint256,address,uint256,uint256,uint64,uint64,uint64,uint64))"
        );
        extension_englishAuctions.functions[2] = ExtensionFunction(
            EnglishAuctionsLogic.cancelAuction.selector,
            "cancelAuction(uint256)"
        );
        extension_englishAuctions.functions[3] = ExtensionFunction(
            EnglishAuctionsLogic.collectAuctionPayout.selector,
            "collectAuctionPayout(uint256)"
        );
        extension_englishAuctions.functions[4] = ExtensionFunction(
            EnglishAuctionsLogic.collectAuctionTokens.selector,
            "collectAuctionTokens(uint256)"
        );
        extension_englishAuctions.functions[5] = ExtensionFunction(
            EnglishAuctionsLogic.bidInAuction.selector,
            "bidInAuction(uint256,uint256)"
        );
        extension_englishAuctions.functions[6] = ExtensionFunction(
            EnglishAuctionsLogic.isNewWinningBid.selector,
            "isNewWinningBid(uint256,uint256)"
        );
        extension_englishAuctions.functions[7] = ExtensionFunction(
            EnglishAuctionsLogic.getAuction.selector,
            "getAuction(uint256)"
        );
        extension_englishAuctions.functions[8] = ExtensionFunction(
            EnglishAuctionsLogic.getAllAuctions.selector,
            "getAllAuctions(uint256,uint256)"
        );
        extension_englishAuctions.functions[9] = ExtensionFunction(
            EnglishAuctionsLogic.getAllValidAuctions.selector,
            "getAllValidAuctions(uint256,uint256)"
        );
        extension_englishAuctions.functions[10] = ExtensionFunction(
            EnglishAuctionsLogic.getWinningBid.selector,
            "getWinningBid(uint256)"
        );
        extension_englishAuctions.functions[11] = ExtensionFunction(
            EnglishAuctionsLogic.isAuctionExpired.selector,
            "isAuctionExpired(uint256)"
        );

        extensions[0] = extension_englishAuctions;
    }

    function _setupERC721BalanceForSeller(address _seller, uint256 _numOfTokens) private {
        erc721.mint(_seller, _numOfTokens);
    }

    function test_state_initial() public {
        uint256 totoalAuctions = EnglishAuctionsLogic(marketplace).totalAuctions();
        assertEq(totoalAuctions, 0);
    }

    /*///////////////////////////////////////////////////////////////
                Royalty Tests (incl Royalty Engine / Registry)
    //////////////////////////////////////////////////////////////*/

    function _setupRoyaltyEngine()
        private
        returns (
            MockRoyaltyEngineV1 royaltyEngine,
            address payable[] memory mockRecipients,
            uint256[] memory mockAmounts
        )
    {
        mockRecipients = new address payable[](2);
        mockAmounts = new uint256[](2);

        mockRecipients[0] = payable(address(0x12345));
        mockRecipients[1] = payable(address(0x56789));

        mockAmounts[0] = 10;
        mockAmounts[1] = 15;

        royaltyEngine = new MockRoyaltyEngineV1(mockRecipients, mockAmounts);
    }

    function _setupAuctionForRoyaltyTests(address erc721TokenAddress) private returns (uint256 auctionId) {
        // Sample auction parameters.
        address assetContract = erc721TokenAddress;
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        IERC721(erc721TokenAddress).setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        auctionId = EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function _buyoutAuctionForRoyaltyTests(uint256 auctionId) private returns (uint256 buyoutAmount) {
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        buyoutAmount = existingAuction.buyoutBidAmount;

        // Mint requisite total price to buyer.
        erc20.mint(buyer, buyoutAmount);

        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.approve(marketplace, buyoutAmount);

        // Place buyout bid in auction.
        vm.warp(existingAuction.startTimestamp);
        vm.prank(buyer);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, buyoutAmount);
    }

    function test_royaltyEngine_tokenWithCustomRoyalties() public {
        (
            MockRoyaltyEngineV1 royaltyEngine,
            address payable[] memory customRoyaltyRecipients,
            uint256[] memory customRoyaltyAmounts
        ) = _setupRoyaltyEngine();

        // Add RoyaltyEngine to marketplace
        vm.prank(marketplaceDeployer);
        RoyaltyPaymentsLogic(marketplace).setRoyaltyEngine(address(royaltyEngine));

        assertEq(RoyaltyPaymentsLogic(marketplace).getRoyaltyEngineAddress(), address(royaltyEngine));

        // 1. ========= Create auction =========

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);
        uint256 auctionId = _setupAuctionForRoyaltyTests(address(erc721));

        // 2. ========= Bid in auction =========

        uint256 buyoutAmount = _buyoutAuctionForRoyaltyTests(auctionId);

        // 3. ========= Seller collects auction payout

        vm.prank(seller);
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);

        // 4. ======== Check balances after royalty payments ========

        {
            // Royalty recipients receive correct amounts
            assertBalERC20Eq(address(erc20), customRoyaltyRecipients[0], customRoyaltyAmounts[0]);
            assertBalERC20Eq(address(erc20), customRoyaltyRecipients[1], customRoyaltyAmounts[1]);

            // Seller gets total price minus royalty amounts
            assertBalERC20Eq(address(erc20), seller, buyoutAmount - customRoyaltyAmounts[0] - customRoyaltyAmounts[1]);
        }
    }

    function test_royaltyEngine_tokenWithERC2981() public {
        (MockRoyaltyEngineV1 royaltyEngine, , ) = _setupRoyaltyEngine();

        // Add RoyaltyEngine to marketplace
        vm.prank(marketplaceDeployer);
        RoyaltyPaymentsLogic(marketplace).setRoyaltyEngine(address(royaltyEngine));

        assertEq(RoyaltyPaymentsLogic(marketplace).getRoyaltyEngineAddress(), address(royaltyEngine));

        // create token with ERC2981
        address royaltyRecipient = address(0x12345);
        uint128 royaltyBps = 10;
        ERC721Base nft2981 = new ERC721Base(address(0x12345), "NFT 2981", "NFT2981", royaltyRecipient, royaltyBps);
        // Mint the ERC721 tokens to seller. These tokens will be listed.
        vm.prank(address(0x12345));
        nft2981.mintTo(seller, "");

        vm.prank(marketplaceDeployer);
        Permissions(marketplace).grantRole(keccak256("ASSET_ROLE"), address(nft2981));

        // 1. ========= Create auction =========

        uint256 auctionId = _setupAuctionForRoyaltyTests(address(nft2981));

        // 2. ========= Bid in auction =========

        uint256 buyoutAmount = _buyoutAuctionForRoyaltyTests(auctionId);

        // 3. ========= Seller collects auction payout

        vm.prank(seller);
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);

        // 4. ======== Check balances after royalty payments ========

        {
            uint256 royaltyAmount = (royaltyBps * buyoutAmount) / 10_000;
            // Royalty recipient receives correct amounts
            assertBalERC20Eq(address(erc20), royaltyRecipient, royaltyAmount);

            // Seller gets total price minus royalty amount
            assertBalERC20Eq(address(erc20), seller, buyoutAmount - royaltyAmount);
        }
    }

    function test_noRoyaltyEngine_defaultERC2981Token() public {
        // create token with ERC2981
        address royaltyRecipient = address(0x12345);
        uint128 royaltyBps = 10;
        ERC721Base nft2981 = new ERC721Base(address(0x12345), "NFT 2981", "NFT2981", royaltyRecipient, royaltyBps);
        vm.prank(address(0x12345));
        nft2981.mintTo(seller, "");

        vm.prank(marketplaceDeployer);
        Permissions(marketplace).grantRole(keccak256("ASSET_ROLE"), address(nft2981));

        // 1. ========= Create auction =========

        uint256 auctionId = _setupAuctionForRoyaltyTests(address(nft2981));

        // 2. ========= Bid in auction =========

        uint256 buyoutAmount = _buyoutAuctionForRoyaltyTests(auctionId);

        // 3. ========= Seller collects auction payout

        vm.prank(seller);
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);

        // 4. ======== Check balances after royalty payments ========

        {
            uint256 royaltyAmount = (royaltyBps * buyoutAmount) / 10_000;
            // Royalty recipient receives correct amounts
            assertBalERC20Eq(address(erc20), royaltyRecipient, royaltyAmount);

            // Seller gets total price minus royalty amount
            assertBalERC20Eq(address(erc20), seller, buyoutAmount - royaltyAmount);
        }
    }

    function test_royaltyEngine_correctlyDistributeAllFees() public {
        (
            MockRoyaltyEngineV1 royaltyEngine,
            address payable[] memory customRoyaltyRecipients,
            uint256[] memory customRoyaltyAmounts
        ) = _setupRoyaltyEngine();

        // Add RoyaltyEngine to marketplace
        vm.prank(marketplaceDeployer);
        RoyaltyPaymentsLogic(marketplace).setRoyaltyEngine(address(royaltyEngine));

        assertEq(RoyaltyPaymentsLogic(marketplace).getRoyaltyEngineAddress(), address(royaltyEngine));

        // Set platform fee on marketplace
        address platformFeeRecipient = marketplaceDeployer;
        uint128 platformFeeBps = 5;
        vm.prank(marketplaceDeployer);
        IPlatformFee(marketplace).setPlatformFeeInfo(platformFeeRecipient, platformFeeBps);

        // 1. ========= Create auction =========

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);
        uint256 auctionId = _setupAuctionForRoyaltyTests(address(erc721));

        // 2. ========= Bid in auction =========

        uint256 buyoutAmount = _buyoutAuctionForRoyaltyTests(auctionId);

        // 3. ========= Seller collects auction payout

        vm.prank(seller);
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);

        // 4. ======== Check balances after royalty payments ========

        {
            // Royalty recipients receive correct amounts
            assertBalERC20Eq(address(erc20), customRoyaltyRecipients[0], customRoyaltyAmounts[0]);
            assertBalERC20Eq(address(erc20), customRoyaltyRecipients[1], customRoyaltyAmounts[1]);

            // Platform fee recipient
            uint256 platformFeeAmount = (platformFeeBps * buyoutAmount) / 10_000;
            assertBalERC20Eq(address(erc20), platformFeeRecipient, platformFeeAmount);

            // Seller gets total price minus royalty amounts
            assertBalERC20Eq(
                address(erc20),
                seller,
                buyoutAmount - customRoyaltyAmounts[0] - customRoyaltyAmounts[1] - platformFeeAmount
            );
        }
    }

    function test_revert_feesExceedTotalPrice() public {
        (MockRoyaltyEngineV1 royaltyEngine, , ) = _setupRoyaltyEngine();

        // Add RoyaltyEngine to marketplace
        vm.prank(marketplaceDeployer);
        RoyaltyPaymentsLogic(marketplace).setRoyaltyEngine(address(royaltyEngine));

        assertEq(RoyaltyPaymentsLogic(marketplace).getRoyaltyEngineAddress(), address(royaltyEngine));

        // Set platform fee on marketplace
        address platformFeeRecipient = marketplaceDeployer;
        uint128 platformFeeBps = 10_000; // equal to max bps 10_000 or 100%
        vm.prank(marketplaceDeployer);
        IPlatformFee(marketplace).setPlatformFeeInfo(platformFeeRecipient, platformFeeBps);

        // 1. ========= Create auction =========

        _setupERC721BalanceForSeller(seller, 1);
        uint256 auctionId = _setupAuctionForRoyaltyTests(address(erc721));

        // 2. ========= Bid in auction =========

        IEnglishAuctions.Auction memory auction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256 buyoutAmount = auction.buyoutBidAmount;

        // Mint requisite total price to buyer.
        erc20.mint(buyer, buyoutAmount);

        // Approve marketplace to transfer currency
        vm.prank(buyer);
        erc20.increaseAllowance(marketplace, buyoutAmount);

        // Buy tokens from auction.
        vm.warp(auction.startTimestamp);

        vm.prank(buyer);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, buyoutAmount);

        // 3. ========= Seller collects auction payout

        vm.expectRevert("fees exceed the price");
        vm.prank(seller);
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);
    }

    /*///////////////////////////////////////////////////////////////
                            Create Auction
    //////////////////////////////////////////////////////////////*/

    function test_state_createAuction() public {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        uint256 auctionId = EnglishAuctionsLogic(marketplace).createAuction(auctionParams);

        // Test consequent state of the contract.

        // Marketplace is owner of token.
        assertIsOwnerERC721(address(erc721), marketplace, tokenIds);

        // Total listings incremented
        assertEq(EnglishAuctionsLogic(marketplace).totalAuctions(), 1);

        // Fetch listing and verify state.
        IEnglishAuctions.Auction memory auction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        assertEq(auction.auctionId, auctionId);
        assertEq(auction.auctionCreator, seller);
        assertEq(auction.assetContract, assetContract);
        assertEq(auction.tokenId, tokenId);
        assertEq(auction.quantity, quantity);
        assertEq(auction.currency, currency);
        assertEq(auction.minimumBidAmount, minimumBidAmount);
        assertEq(auction.buyoutBidAmount, buyoutBidAmount);
        assertEq(auction.timeBufferInSeconds, timeBufferInSeconds);
        assertEq(auction.bidBufferBps, bidBufferBps);
        assertEq(auction.startTimestamp, startTimestamp);
        assertEq(auction.endTimestamp, endTimestamp);
        assertEq(uint256(auction.tokenType), uint256(IEnglishAuctions.TokenType.ERC721));
    }

    function test_revert_createAuction_notOwnerOfAuctionedToken() public {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Don't mint to 'token to be auctioned' to the seller.
        address someWallet = getActor(1000);
        _setupERC721BalanceForSeller(someWallet, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), someWallet, tokenIds);
        assertIsNotOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(someWallet);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        vm.expectRevert("ERC721: transfer from incorrect owner");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_revert_createAuction_notApprovedMarketplaceToTransferToken() public {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Don't approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, false);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        vm.expectRevert("ERC721: caller is not token owner or approved");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_revert_createAuction_auctioningZeroQuantity() public {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 0;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: auctioning zero quantity.");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_revert_createAuction_invalidQuantity() public {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 2; // Listing more than `1` quantity
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: auctioning invalid quantity.");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_revert_createAuction_noBidOrTimeBuffer() public {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 0;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: no time-buffer.");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);

        timeBufferInSeconds = 10 seconds;
        bidBufferBps = 0;

        auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: no bid-buffer.");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_revert_createAuction_invalidBidAmounts() public {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 10 ether; // set minimumBidAmount greater than buyoutBidAmount
        uint256 buyoutBidAmount = 1 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: invalid bid amounts.");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_revert_createAuction_invalidStartTimestamp() public {
        uint256 blockTimestamp = 100 minutes;
        // Set block.timestamp
        vm.warp(blockTimestamp);

        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = uint64(blockTimestamp - 61 minutes); // start time is less than block timestamp.
        uint64 endTimestamp = startTimestamp + 1;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: invalid timestamps.");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_revert_createAuction_invalidEndTimestamp() public {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = startTimestamp - 1;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        vm.expectRevert("Marketplace: invalid timestamps.");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_revert_createAuction_invalidAssetContract() public {
        // Sample auction parameters.
        address assetContract = address(erc20);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = startTimestamp - 1;

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        // Grant ERC20 token asset role.
        vm.prank(marketplaceDeployer);
        Permissions(marketplace).grantRole(keccak256("ASSET_ROLE"), address(erc20));

        vm.prank(seller);
        vm.expectRevert("Marketplace: auctioned token must be ERC1155 or ERC721.");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_revert_createAuction_noListerRoleWhenRestrictionsActive() public {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        // Revoke LISTER_ROLE from seller.
        vm.startPrank(marketplaceDeployer);
        assertEq(Permissions(marketplace).hasRole(keccak256("LISTER_ROLE"), address(0)), false);
        Permissions(marketplace).revokeRole(keccak256("LISTER_ROLE"), seller);
        assertEq(Permissions(marketplace).hasRole(keccak256("LISTER_ROLE"), seller), false);

        vm.stopPrank();

        vm.prank(seller);
        vm.expectRevert("!LISTER_ROLE");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_revert_createAuction_noAssetRoleWhenRestrictionsActive() public {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        // Revoke ASSET_ROLE from token to list.
        vm.startPrank(marketplaceDeployer);
        assertEq(Permissions(marketplace).hasRole(keccak256("ASSET_ROLE"), address(0)), false);
        Permissions(marketplace).revokeRole(keccak256("ASSET_ROLE"), address(erc721));
        assertEq(Permissions(marketplace).hasRole(keccak256("ASSET_ROLE"), address(erc721)), false);

        vm.stopPrank();

        vm.prank(seller);
        vm.expectRevert("!ASSET_ROLE");
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    /*///////////////////////////////////////////////////////////////
                            Cancel Auction
    //////////////////////////////////////////////////////////////*/

    function _setup_newAuction() private returns (uint256 auctionId) {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        auctionId = EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function _setup_newAuction_nativeToken() private returns (uint256 auctionId) {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = NATIVE_TOKEN;
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        auctionId = EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_state_cancelAuction() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.prank(seller);
        EnglishAuctionsLogic(marketplace).cancelAuction(auctionId);

        // Test consequent states.

        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Total auction count should include deleted auctions too
        assertEq(EnglishAuctionsLogic(marketplace).totalAuctions(), 1);

        // status should be `CANCELLED`
        IEnglishAuctions.Auction memory cancelledAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);
        assertTrue(cancelledAuction.status == IEnglishAuctions.Status.CANCELLED);
    }

    function test_revert_cancelAuction_bidsAlreadyMade() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        erc20.mint(buyer, 1 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 1 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 1 ether);
        vm.stopPrank();

        vm.prank(seller);
        vm.expectRevert("Marketplace: bids already made.");
        EnglishAuctionsLogic(marketplace).cancelAuction(auctionId);
    }

    /*///////////////////////////////////////////////////////////////
                            Bid In Auction
    //////////////////////////////////////////////////////////////*/

    function test_state_bidInAuction_firstBid() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        erc20.mint(buyer, 1 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 1 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 1 ether);
        vm.stopPrank();

        (address bidder, address currency, uint256 bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(
            auctionId
        );

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), marketplace, tokenIds);
        assertEq(erc20.balanceOf(marketplace), 1 ether);
        assertEq(erc20.balanceOf(buyer), 0);
        assertEq(buyer, bidder);
        assertEq(currency, address(erc20));
        assertEq(bidAmount, 1 ether);
    }

    function test_state_bidInAuction_secondBid() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place first bid
        erc20.mint(buyer, 1 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 1 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 1 ether);
        vm.stopPrank();

        (address bidder, address currency, uint256 bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(
            auctionId
        );

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), marketplace, tokenIds);
        assertEq(erc20.balanceOf(marketplace), 1 ether);
        assertEq(erc20.balanceOf(buyer), 0);
        assertEq(buyer, bidder);
        assertEq(currency, address(erc20));
        assertEq(bidAmount, 1 ether);

        // place second winning bid
        erc20.mint(address(0x345), 2 ether);
        vm.startPrank(address(0x345));
        erc20.approve(marketplace, 2 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 2 ether);
        vm.stopPrank();

        (bidder, currency, bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(auctionId);

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), marketplace, tokenIds);
        assertEq(erc20.balanceOf(marketplace), 2 ether);
        assertEq(erc20.balanceOf(buyer), 1 ether);
        assertEq(erc20.balanceOf(address(0x345)), 0);
        assertEq(address(0x345), bidder);
        assertEq(currency, address(erc20));
        assertEq(bidAmount, 2 ether);
    }

    function test_state_bidInAuction_buyoutBid() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place first bid
        erc20.mint(buyer, 1 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 1 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 1 ether);
        vm.stopPrank();

        (address bidder, address currency, uint256 bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(
            auctionId
        );

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), marketplace, tokenIds);
        assertEq(erc20.balanceOf(marketplace), 1 ether);
        assertEq(erc20.balanceOf(buyer), 0);
        assertEq(buyer, bidder);
        assertEq(currency, address(erc20));
        assertEq(bidAmount, 1 ether);

        // place buyout bid
        erc20.mint(address(0x345), 10 ether);
        vm.startPrank(address(0x345));
        erc20.approve(marketplace, 10 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 10 ether);
        vm.stopPrank();

        (bidder, currency, bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(auctionId);

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), address(0x345), tokenIds);
        assertEq(erc20.balanceOf(marketplace), 10 ether);
        assertEq(erc20.balanceOf(buyer), 1 ether);
        assertEq(erc20.balanceOf(address(0x345)), 0);
        assertEq(address(0x345), bidder);
        assertEq(currency, address(erc20));
        assertEq(bidAmount, 10 ether);
    }

    function test_revert_bidInAuction_inactiveAuction() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        // place bid before start-time
        erc20.mint(buyer, 1 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 1 ether);
        vm.expectRevert("Marketplace: inactive auction.");
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 1 ether);
        vm.stopPrank();

        // place bid after end-time
        vm.warp(existingAuction.endTimestamp);

        erc20.mint(buyer, 1 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 1 ether);
        vm.expectRevert("Marketplace: inactive auction.");
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 1 ether);
        vm.stopPrank();
    }

    function test_revert_bidInAuction_notOwnerOfBidTokens() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        vm.startPrank(buyer);
        erc20.approve(marketplace, 1 ether);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 1 ether);
        vm.stopPrank();
    }

    function test_revert_bidInAuction_notApprovedMarketplaceToTransferToken() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        erc20.mint(buyer, 1 ether);
        vm.startPrank(buyer);
        vm.expectRevert("ERC20: insufficient allowance");
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 1 ether);
        vm.stopPrank();
    }

    function test_revert_bidInAuction_notNewWinningBid_firstBid() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place first bid less than minimum bid amount
        erc20.mint(buyer, 0.5 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 0.5 ether);
        vm.expectRevert("Marketplace: not winning bid.");
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 0.5 ether);
        vm.stopPrank();
    }

    function test_revert_bidInAuction_notNewWinningBid_secondBid() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place first bid
        erc20.mint(buyer, 1 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 1 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 1 ether);
        vm.stopPrank();

        (address bidder, address currency, uint256 bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(
            auctionId
        );

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), marketplace, tokenIds);
        assertEq(erc20.balanceOf(marketplace), 1 ether);
        assertEq(erc20.balanceOf(buyer), 0);
        assertEq(buyer, bidder);
        assertEq(currency, address(erc20));
        assertEq(bidAmount, 1 ether);

        // place second bid less-than/equal-to previous winning bid
        erc20.mint(address(0x345), 1 ether);
        vm.startPrank(address(0x345));
        erc20.approve(marketplace, 1 ether);
        vm.expectRevert("Marketplace: not winning bid.");
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 1 ether);
        vm.stopPrank();
    }

    function test_state_bidInAuction_nativeToken() public {
        uint256 auctionId = _setup_newAuction_nativeToken();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        vm.deal(buyer, 10 ether);
        vm.startPrank(buyer);
        EnglishAuctionsLogic(marketplace).bidInAuction{ value: 1 ether }(auctionId, 1 ether);
        vm.stopPrank();

        (address bidder, address currency, uint256 bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(
            auctionId
        );

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), marketplace, tokenIds);
        assertEq(weth.balanceOf(marketplace), 1 ether);
        assertEq(buyer.balance, 9 ether);
        assertEq(buyer, bidder);
        assertEq(currency, NATIVE_TOKEN);
        assertEq(bidAmount, 1 ether);
    }

    /*///////////////////////////////////////////////////////////////
                        Collect Auction Payout
    //////////////////////////////////////////////////////////////*/

    function test_state_collectAuctionPayout_buyoutBid() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place buyout bid
        erc20.mint(buyer, 10 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 10 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 10 ether);
        vm.stopPrank();

        (address bidder, address currency, uint256 bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(
            auctionId
        );

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), buyer, tokenIds);
        assertEq(erc20.balanceOf(marketplace), 10 ether);
        assertEq(erc20.balanceOf(buyer), 0);
        assertEq(buyer, bidder);
        assertEq(currency, address(erc20));
        assertEq(bidAmount, 10 ether);

        // collect auction payout
        vm.prank(seller);
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);

        assertEq(erc20.balanceOf(marketplace), 0);
        assertEq(erc20.balanceOf(seller), 10 ether);
    }

    function test_state_collectAuctionPayout_afterAuctionEnds() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        erc20.mint(buyer, 5 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 5 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 5 ether);
        vm.stopPrank();

        (address bidder, address currency, uint256 bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(
            auctionId
        );

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), marketplace, tokenIds);
        assertEq(erc20.balanceOf(marketplace), 5 ether);
        assertEq(erc20.balanceOf(buyer), 0);
        assertEq(buyer, bidder);
        assertEq(currency, address(erc20));
        assertEq(bidAmount, 5 ether);

        vm.warp(existingAuction.endTimestamp);

        // collect auction payout
        vm.prank(seller);
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);

        assertIsOwnerERC721(address(erc721), marketplace, tokenIds);
        assertEq(erc20.balanceOf(marketplace), 0);
        assertEq(erc20.balanceOf(seller), 5 ether);
    }

    function test_revert_collectAuctionPayout_auctionNotExpired() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        erc20.mint(buyer, 5 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 5 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 5 ether);
        vm.stopPrank();

        // collect auction payout before auction has ended
        vm.prank(seller);
        vm.expectRevert("Marketplace: auction still active.");
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);
    }

    function test_revert_collectAuctionPayout_noBidsInAuction() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.endTimestamp);

        // collect auction payout without any bids made
        vm.prank(seller);
        vm.expectRevert("Marketplace: no bids were made.");
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);
    }

    /*///////////////////////////////////////////////////////////////
                        Collect Auction Tokens
    //////////////////////////////////////////////////////////////*/

    function test_state_collectAuctionTokens() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        erc20.mint(buyer, 5 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 5 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 5 ether);
        vm.stopPrank();

        (address bidder, address currency, uint256 bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(
            auctionId
        );

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), marketplace, tokenIds);
        assertEq(erc20.balanceOf(marketplace), 5 ether);
        assertEq(erc20.balanceOf(buyer), 0);
        assertEq(buyer, bidder);
        assertEq(currency, address(erc20));
        assertEq(bidAmount, 5 ether);

        vm.warp(existingAuction.endTimestamp);

        // collect auction tokens
        vm.prank(buyer);
        EnglishAuctionsLogic(marketplace).collectAuctionTokens(auctionId);

        assertIsOwnerERC721(address(erc721), buyer, tokenIds);
        assertEq(erc20.balanceOf(marketplace), 5 ether);
    }

    function test_revert_collectAuctionTokens_auctionNotExpired() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        erc20.mint(buyer, 5 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 5 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 5 ether);
        vm.stopPrank();

        (address bidder, address currency, uint256 bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(
            auctionId
        );

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), marketplace, tokenIds);
        assertEq(erc20.balanceOf(marketplace), 5 ether);
        assertEq(erc20.balanceOf(buyer), 0);
        assertEq(buyer, bidder);
        assertEq(currency, address(erc20));
        assertEq(bidAmount, 5 ether);

        // collect auction tokens before auction has ended
        vm.prank(buyer);
        vm.expectRevert("Marketplace: auction still active.");
        EnglishAuctionsLogic(marketplace).collectAuctionTokens(auctionId);
    }

    /*///////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/

    function test_state_isNewWinningBid() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        erc20.mint(buyer, 5 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 5 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 5 ether);
        vm.stopPrank();

        // check if new winning bid
        assertTrue(EnglishAuctionsLogic(marketplace).isNewWinningBid(auctionId, 6 ether));
        assertFalse(EnglishAuctionsLogic(marketplace).isNewWinningBid(auctionId, 5 ether));
        assertFalse(EnglishAuctionsLogic(marketplace).isNewWinningBid(auctionId, 4 ether));
    }

    function test_revert_isNewWinningBid() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        erc20.mint(buyer, 5 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 5 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 5 ether);
        vm.stopPrank();

        // check winning bid for a non-existent auction
        vm.expectRevert("Marketplace: invalid auction.");
        EnglishAuctionsLogic(marketplace).isNewWinningBid(auctionId + 1, 6 ether);
    }

    function test_state_getAllAuctions() public {
        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 6);

        uint256[] memory auctionIds = new uint256[](5);
        uint256[] memory tokenIds = new uint256[](5);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = uint64(block.timestamp);
        uint64 endTimestamp = startTimestamp + 200;

        IEnglishAuctions.AuctionParameters memory auctionParams;

        for (uint256 i = 0; i < 5; i += 1) {
            tokenIds[i] = i;

            // Auction tokens.
            auctionParams = IEnglishAuctions.AuctionParameters(
                assetContract,
                tokenIds[i],
                quantity,
                currency,
                minimumBidAmount,
                buyoutBidAmount,
                timeBufferInSeconds,
                bidBufferBps,
                startTimestamp,
                endTimestamp
            );

            vm.prank(seller);
            auctionIds[i] = EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
        }

        IEnglishAuctions.Auction[] memory activeAuctions = EnglishAuctionsLogic(marketplace).getAllAuctions(0, 4);
        assertEq(activeAuctions.length, 5);

        for (uint256 i = 0; i < 5; i += 1) {
            assertEq(activeAuctions[i].auctionId, auctionIds[i]);
            assertEq(activeAuctions[i].auctionCreator, seller);
            assertEq(activeAuctions[i].assetContract, assetContract);
            assertEq(activeAuctions[i].tokenId, tokenIds[i]);
            assertEq(activeAuctions[i].quantity, quantity);
            assertEq(activeAuctions[i].currency, currency);
            assertEq(activeAuctions[i].minimumBidAmount, minimumBidAmount);
            assertEq(activeAuctions[i].buyoutBidAmount, buyoutBidAmount);
            assertEq(activeAuctions[i].timeBufferInSeconds, timeBufferInSeconds);
            assertEq(activeAuctions[i].bidBufferBps, bidBufferBps);
            assertEq(activeAuctions[i].startTimestamp, startTimestamp);
            assertEq(activeAuctions[i].endTimestamp, endTimestamp);
            assertEq(uint256(activeAuctions[i].tokenType), uint256(IEnglishAuctions.TokenType.ERC721));
        }
    }

    function test_state_getAllValidAuctions() public {
        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 6);

        uint256[] memory auctionIds = new uint256[](5);
        uint256[] memory tokenIds = new uint256[](5);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = uint64(block.timestamp);
        uint64 endTimestamp = startTimestamp + 200;

        IEnglishAuctions.AuctionParameters memory auctionParams;

        for (uint256 i = 0; i < 5; i += 1) {
            tokenIds[i] = i;

            // Auction tokens.
            auctionParams = IEnglishAuctions.AuctionParameters(
                assetContract,
                tokenIds[i],
                quantity,
                currency,
                minimumBidAmount,
                buyoutBidAmount,
                timeBufferInSeconds,
                bidBufferBps,
                startTimestamp,
                endTimestamp
            );

            vm.prank(seller);
            auctionIds[i] = EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
        }

        IEnglishAuctions.Auction[] memory activeAuctions = EnglishAuctionsLogic(marketplace).getAllValidAuctions(0, 4);
        assertEq(activeAuctions.length, 5);

        for (uint256 i = 0; i < 5; i += 1) {
            assertEq(activeAuctions[i].auctionId, auctionIds[i]);
            assertEq(activeAuctions[i].auctionCreator, seller);
            assertEq(activeAuctions[i].assetContract, assetContract);
            assertEq(activeAuctions[i].tokenId, tokenIds[i]);
            assertEq(activeAuctions[i].quantity, quantity);
            assertEq(activeAuctions[i].currency, currency);
            assertEq(activeAuctions[i].minimumBidAmount, minimumBidAmount);
            assertEq(activeAuctions[i].buyoutBidAmount, buyoutBidAmount);
            assertEq(activeAuctions[i].timeBufferInSeconds, timeBufferInSeconds);
            assertEq(activeAuctions[i].bidBufferBps, bidBufferBps);
            assertEq(activeAuctions[i].startTimestamp, startTimestamp);
            assertEq(activeAuctions[i].endTimestamp, endTimestamp);
            assertEq(uint256(activeAuctions[i].tokenType), uint256(IEnglishAuctions.TokenType.ERC721));
        }

        // create an inactive auction, and check the auctions returned
        auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            5,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp + 100,
            endTimestamp
        );

        vm.prank(seller);
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams);

        activeAuctions = EnglishAuctionsLogic(marketplace).getAllValidAuctions(0, 5);
        assertEq(activeAuctions.length, 5);
    }

    function test_state_isAuctionExpired() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        vm.warp(existingAuction.endTimestamp + 1);
        assertTrue(EnglishAuctionsLogic(marketplace).isAuctionExpired(auctionId));
    }

    function test_revert_isAuctionExpired() public {
        uint256 auctionId = _setup_newAuction();

        vm.expectRevert("Marketplace: invalid auction.");
        EnglishAuctionsLogic(marketplace).isAuctionExpired(auctionId + 1);
    }

    /*///////////////////////////////////////////////////////////////
                            Audit POCs
    //////////////////////////////////////////////////////////////*/

    function test_state_collectAuctionPayout_buyoutBid_nativeToken() public {
        uint256 auctionId = _setup_newAuction_nativeToken();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        vm.deal(buyer, 10 ether);
        vm.startPrank(buyer);
        EnglishAuctionsLogic(marketplace).bidInAuction{ value: 10 ether }(auctionId, 10 ether);
        vm.stopPrank();

        (address bidder, address currency, uint256 bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(
            auctionId
        );

        // Test consequent states.
        // Seller is owner of token.
        assertIsOwnerERC721(address(erc721), buyer, tokenIds);
        assertEq(weth.balanceOf(marketplace), 10 ether);
        assertEq(buyer.balance, 0 ether);
        assertEq(buyer, bidder);
        assertEq(currency, NATIVE_TOKEN);
        assertEq(bidAmount, 10 ether);

        vm.prank(seller);
        // calls WETH.withdraw (which calls receive function of Marketplace) and sends native tokens to seller
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);
        assertEq(weth.balanceOf(marketplace), 0 ether);
        assertEq(seller.balance, 10 ether);

        // sending eth directly should fail
        vm.deal(address(this), 1 ether);
        (bool success, ) = marketplace.call{ value: 1 ether }("");
        assertEq(success, false);
    }

    function test_audit_native_tokens_locked() public {
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        // place buyout bid
        erc20.mint(buyer, 10 ether);
        vm.deal(buyer, 1 ether);

        vm.startPrank(buyer);
        erc20.approve(marketplace, 10 ether);

        vm.expectRevert("Marketplace: invalid native tokens sent.");
        EnglishAuctionsLogic(marketplace).bidInAuction{ value: 1 ether }(auctionId, 10 ether);
        vm.stopPrank();

        // No ether is temporary locked in contract
        assertEq(marketplace.balance, 0);
    }

    function test_revert_collectAuctionPayout_buyoutBid_poc() public {
        /*///////////////////////////////////////////////////////////////
                        Initial State
        //////////////////////////////////////////////////////////////*/

        // consider that market place already has 200 ETH worth of tokens from all bids made
        erc20.mint(marketplace, 200 ether);

        /*///////////////////////////////////////////////////////////////
                       Create Auction
        //////////////////////////////////////////////////////////////*/

        // Buyout bid : 10 ETH
        uint256 auctionId = _setup_newAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        /*///////////////////////////////////////////////////////////////
                       BID
        //////////////////////////////////////////////////////////////*/

        // place bid : 200 ETH
        erc20.mint(buyer, 200 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 200 ether);

        vm.expectRevert("Marketplace: Bidding above buyout price.");
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 200 ether);
        vm.stopPrank();
    }

    function _setup_nativeTokenAuction() private returns (uint256 auctionId) {
        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = NATIVE_TOKEN;
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        auctionId = EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_revert_collectAuctionPayout_buyoutBid_nativeTokens_poc() public {
        /*///////////////////////////////////////////////////////////////
                        Initial State
        //////////////////////////////////////////////////////////////*/

        // consider that market place already has 200 ETH worth of tokens from all bids made
        vm.deal(address(marketplace), 200 ether);

        /*///////////////////////////////////////////////////////////////
                       Create Auction
        //////////////////////////////////////////////////////////////*/

        // Buyout bid : 10 ETH
        uint256 auctionId = _setup_nativeTokenAuction();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = existingAuction.tokenId;

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc721));

        vm.warp(existingAuction.startTimestamp);

        /*///////////////////////////////////////////////////////////////
                       BID
        //////////////////////////////////////////////////////////////*/

        // place bid : 200 ETH
        vm.deal(buyer, 200 ether);
        vm.prank(buyer);
        vm.expectRevert("Marketplace: Bidding above buyout price.");
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 200 ether);
    }
}

contract BreitwieserTheCreator is BaseTest, IERC721Receiver, IExtension {
    // Target contract
    address public marketplace;

    // Participants
    address public marketplaceDeployer;
    address public seller;
    address public buyer;

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    function setUp() public override {
        super.setUp();

        marketplaceDeployer = getActor(1);
        seller = getActor(2);
        buyer = getActor(3);

        // Deploy implementation.
        Extension[] memory extensions = _setupExtensions();
        address impl = address(
            new MarketplaceV3(MarketplaceV3.MarketplaceConstructorParams(extensions, address(0), address(weth)))
        );

        vm.prank(marketplaceDeployer);
        marketplace = address(
            new TWProxy(
                impl,
                abi.encodeCall(
                    MarketplaceV3.initialize,
                    (marketplaceDeployer, "", new address[](0), marketplaceDeployer, 0)
                )
            )
        );

        // Setup roles for seller and assets
        vm.startPrank(marketplaceDeployer);
        Permissions(marketplace).revokeRole(keccak256("ASSET_ROLE"), address(0));
        Permissions(marketplace).revokeRole(keccak256("LISTER_ROLE"), address(0));
        Permissions(marketplace).grantRole(keccak256("LISTER_ROLE"), seller);
        Permissions(marketplace).grantRole(keccak256("ASSET_ROLE"), address(erc721));
        Permissions(marketplace).grantRole(keccak256("ASSET_ROLE"), address(erc1155));

        vm.stopPrank();

        vm.label(impl, "MarketplaceV3_Impl");
        vm.label(marketplace, "Marketplace");
        vm.label(seller, "Seller");
        vm.label(buyer, "Buyer");
        vm.label(address(erc721), "ERC721_Token");
        vm.label(address(erc1155), "ERC1155_Token");
    }

    function _setupExtensions() internal returns (Extension[] memory extensions) {
        extensions = new Extension[](1);

        // Deploy `EnglishAuctions`
        address englishAuctions = address(new EnglishAuctionsLogic(address(weth)));
        vm.label(englishAuctions, "EnglishAuctions_Extension");

        // Extension: EnglishAuctionsLogic
        Extension memory extension_englishAuctions;
        extension_englishAuctions.metadata = ExtensionMetadata({
            name: "EnglishAuctionsLogic",
            metadataURI: "ipfs://EnglishAuctions",
            implementation: englishAuctions
        });

        extension_englishAuctions.functions = new ExtensionFunction[](12);
        extension_englishAuctions.functions[0] = ExtensionFunction(
            EnglishAuctionsLogic.totalAuctions.selector,
            "totalAuctions()"
        );
        extension_englishAuctions.functions[1] = ExtensionFunction(
            EnglishAuctionsLogic.createAuction.selector,
            "createAuction((address,uint256,uint256,address,uint256,uint256,uint64,uint64,uint64,uint64))"
        );
        extension_englishAuctions.functions[2] = ExtensionFunction(
            EnglishAuctionsLogic.cancelAuction.selector,
            "cancelAuction(uint256)"
        );
        extension_englishAuctions.functions[3] = ExtensionFunction(
            EnglishAuctionsLogic.collectAuctionPayout.selector,
            "collectAuctionPayout(uint256)"
        );
        extension_englishAuctions.functions[4] = ExtensionFunction(
            EnglishAuctionsLogic.collectAuctionTokens.selector,
            "collectAuctionTokens(uint256)"
        );
        extension_englishAuctions.functions[5] = ExtensionFunction(
            EnglishAuctionsLogic.bidInAuction.selector,
            "bidInAuction(uint256,uint256)"
        );
        extension_englishAuctions.functions[6] = ExtensionFunction(
            EnglishAuctionsLogic.isNewWinningBid.selector,
            "isNewWinningBid(uint256,uint256)"
        );
        extension_englishAuctions.functions[7] = ExtensionFunction(
            EnglishAuctionsLogic.getAuction.selector,
            "getAuction(uint256)"
        );
        extension_englishAuctions.functions[8] = ExtensionFunction(
            EnglishAuctionsLogic.getAllAuctions.selector,
            "getAllAuctions(uint256,uint256)"
        );
        extension_englishAuctions.functions[9] = ExtensionFunction(
            EnglishAuctionsLogic.getAllValidAuctions.selector,
            "getAllValidAuctions(uint256,uint256)"
        );
        extension_englishAuctions.functions[10] = ExtensionFunction(
            EnglishAuctionsLogic.getWinningBid.selector,
            "getWinningBid(uint256)"
        );
        extension_englishAuctions.functions[11] = ExtensionFunction(
            EnglishAuctionsLogic.isAuctionExpired.selector,
            "isAuctionExpired(uint256)"
        );

        extensions[0] = extension_englishAuctions;
    }

    function _setupERC721BalanceForSeller(address _seller, uint256 _numOfTokens) private {
        erc721.mint(_seller, _numOfTokens);
    }

    function test_rob_as_creator() public {
        ///////////////////////////// Setup: dummy NFT  ////////////////////////////

        // Sample auction parameters.
        address assetContract = address(erc721);
        uint256 tokenId = 0;
        uint256 quantity = 1;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 50 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 0;
        uint64 endTimestamp = 200;

        // Mint the ERC721 tokens to seller. These tokens will be auctioned.
        _setupERC721BalanceForSeller(seller, 1);

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;
        assertIsOwnerERC721(address(erc721), seller, tokenIds);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc721.setApprovalForAll(marketplace, true);

        ////////////////////////////// Setup: auction tokens //////////////////////////////////
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );
        vm.prank(seller);
        uint256 auctionId = EnglishAuctionsLogic(marketplace).createAuction(auctionParams);

        /////////////////////////// Setup: marketplace has currency /////////////
        uint256 mbalance = 100 ether;
        erc20.mint(marketplace, mbalance);

        /////////////////////////// Attack: win to drain ///////////////////////////////////////////

        // 1. Buy out the token.
        assertEq(erc20.balanceOf(seller), 0);
        erc20.mint(seller, buyoutBidAmount);
        assertEq(erc20.balanceOf(seller), buyoutBidAmount);

        vm.startPrank(seller);

        erc20.approve(marketplace, buyoutBidAmount);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, buyoutBidAmount);

        // 2. Collect their own bid.
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);
        assertEq(erc20.balanceOf(seller), buyoutBidAmount);

        // 3. Profit. (FIXED)

        vm.expectRevert("Marketplace: payout already completed.");
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);
        // EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);
        // assertEq(erc20.balanceOf(seller), buyoutBidAmount + mbalance);
    }
}

contract BreitwieserTheBidder is BaseTest, IExtension {
    // Target contract
    address public marketplace;

    // Participants
    address public marketplaceDeployer;
    address public seller;
    address public buyer;

    function setUp() public override {
        super.setUp();

        marketplaceDeployer = getActor(1);
        seller = getActor(2);
        buyer = getActor(3);

        // Deploy implementation.
        Extension[] memory extensions = _setupExtensions();
        address impl = address(
            new MarketplaceV3(MarketplaceV3.MarketplaceConstructorParams(extensions, address(0), address(weth)))
        );

        vm.prank(marketplaceDeployer);
        marketplace = address(
            new TWProxy(
                impl,
                abi.encodeCall(
                    MarketplaceV3.initialize,
                    (marketplaceDeployer, "", new address[](0), marketplaceDeployer, 0)
                )
            )
        );

        // Setup roles for seller and assets
        vm.startPrank(marketplaceDeployer);
        Permissions(marketplace).revokeRole(keccak256("ASSET_ROLE"), address(0));
        Permissions(marketplace).revokeRole(keccak256("LISTER_ROLE"), address(0));
        Permissions(marketplace).grantRole(keccak256("LISTER_ROLE"), seller);
        Permissions(marketplace).grantRole(keccak256("ASSET_ROLE"), address(erc721));
        Permissions(marketplace).grantRole(keccak256("ASSET_ROLE"), address(erc1155));

        vm.stopPrank();

        vm.label(impl, "MarketplaceV3_Impl");
        vm.label(marketplace, "Marketplace");
        vm.label(seller, "Seller");
        vm.label(buyer, "Buyer");
        vm.label(address(erc721), "ERC721_Token");
        vm.label(address(erc1155), "ERC1155_Token");
    }

    function _setupExtensions() internal returns (Extension[] memory extensions) {
        extensions = new Extension[](1);

        // Deploy `EnglishAuctions`
        address englishAuctions = address(new EnglishAuctionsLogic(address(weth)));
        vm.label(englishAuctions, "EnglishAuctions_Extension");

        // Extension: EnglishAuctionsLogic
        Extension memory extension_englishAuctions;
        extension_englishAuctions.metadata = ExtensionMetadata({
            name: "EnglishAuctionsLogic",
            metadataURI: "ipfs://EnglishAuctions",
            implementation: englishAuctions
        });

        extension_englishAuctions.functions = new ExtensionFunction[](12);
        extension_englishAuctions.functions[0] = ExtensionFunction(
            EnglishAuctionsLogic.totalAuctions.selector,
            "totalAuctions()"
        );
        extension_englishAuctions.functions[1] = ExtensionFunction(
            EnglishAuctionsLogic.createAuction.selector,
            "createAuction((address,uint256,uint256,address,uint256,uint256,uint64,uint64,uint64,uint64))"
        );
        extension_englishAuctions.functions[2] = ExtensionFunction(
            EnglishAuctionsLogic.cancelAuction.selector,
            "cancelAuction(uint256)"
        );
        extension_englishAuctions.functions[3] = ExtensionFunction(
            EnglishAuctionsLogic.collectAuctionPayout.selector,
            "collectAuctionPayout(uint256)"
        );
        extension_englishAuctions.functions[4] = ExtensionFunction(
            EnglishAuctionsLogic.collectAuctionTokens.selector,
            "collectAuctionTokens(uint256)"
        );
        extension_englishAuctions.functions[5] = ExtensionFunction(
            EnglishAuctionsLogic.bidInAuction.selector,
            "bidInAuction(uint256,uint256)"
        );
        extension_englishAuctions.functions[6] = ExtensionFunction(
            EnglishAuctionsLogic.isNewWinningBid.selector,
            "isNewWinningBid(uint256,uint256)"
        );
        extension_englishAuctions.functions[7] = ExtensionFunction(
            EnglishAuctionsLogic.getAuction.selector,
            "getAuction(uint256)"
        );
        extension_englishAuctions.functions[8] = ExtensionFunction(
            EnglishAuctionsLogic.getAllAuctions.selector,
            "getAllAuctions(uint256,uint256)"
        );
        extension_englishAuctions.functions[9] = ExtensionFunction(
            EnglishAuctionsLogic.getAllValidAuctions.selector,
            "getAllValidAuctions(uint256,uint256)"
        );
        extension_englishAuctions.functions[10] = ExtensionFunction(
            EnglishAuctionsLogic.getWinningBid.selector,
            "getWinningBid(uint256)"
        );
        extension_englishAuctions.functions[11] = ExtensionFunction(
            EnglishAuctionsLogic.isAuctionExpired.selector,
            "isAuctionExpired(uint256)"
        );

        extensions[0] = extension_englishAuctions;
    }

    function _setupERC721BalanceForSeller(address _seller, uint256 _numOfTokens) private {
        erc721.mint(_seller, _numOfTokens);
    }

    function test_rob_as_bidder() public {
        address attacker = address(0xbeef);
        vm.prank(marketplaceDeployer);
        Permissions(marketplace).grantRole(keccak256("LISTER_ROLE"), attacker);

        // Condition: multiple copies in circulation and attacker has at least 1.
        uint256 tokenId = 999;
        // Victim.
        erc1155.mint(seller, tokenId, 1);
        erc1155.mint(attacker, tokenId, 1);

        ////////////////// Setup: auction 1 //////////////////

        IEnglishAuctions.AuctionParameters memory auctionParams1;
        {
            address assetContract = address(erc1155);
            address currency = address(erc20);
            uint256 minimumBidAmount = 1 ether;
            uint256 buyoutBidAmount = 10 ether;
            uint256 qty = 1;
            uint64 timeBufferInSeconds = 10 seconds;
            uint64 bidBufferBps = 1000;
            uint64 startTimestamp = 0;
            uint64 endTimestamp = 200;
            auctionParams1 = IEnglishAuctions.AuctionParameters(
                assetContract,
                tokenId,
                qty,
                currency,
                minimumBidAmount,
                buyoutBidAmount,
                timeBufferInSeconds,
                bidBufferBps,
                startTimestamp,
                endTimestamp
            );
        }

        vm.startPrank(seller);

        erc1155.setApprovalForAll(marketplace, true);
        EnglishAuctionsLogic(marketplace).createAuction(auctionParams1);

        assertEq(erc1155.balanceOf(marketplace, tokenId), 1, "Marketplace should have the token.");

        vm.stopPrank();

        ////////////////// Attack: auction the 2nd and steal the 1st token //////////////////

        // 1. Set up auction.
        erc20.mint(attacker, 1);

        vm.startPrank(attacker);

        erc1155.setApprovalForAll(marketplace, true);

        IEnglishAuctions.AuctionParameters memory auctionParams2;
        {
            address assetContract = address(erc1155);
            address currency = address(erc20);
            uint256 minimumBidAmount = 1;
            uint256 buyoutBidAmount = 1;
            uint64 timeBufferInSeconds = 10 seconds;
            uint64 bidBufferBps = 1000;
            uint64 startTimestamp = 0;
            uint64 endTimestamp = 200;
            auctionParams2 = IEnglishAuctions.AuctionParameters(
                assetContract,
                tokenId,
                1,
                currency,
                minimumBidAmount,
                buyoutBidAmount,
                timeBufferInSeconds,
                bidBufferBps,
                startTimestamp,
                endTimestamp
            );
        }
        uint256 auctionId2 = EnglishAuctionsLogic(marketplace).createAuction(auctionParams2);

        assertEq(erc1155.balanceOf(marketplace, tokenId), 2, "Marketplace should have 2 tokens.");

        // 2. Bid and collect back token.
        erc20.increaseAllowance(marketplace, 1);
        // Bid a small amount: 1 wei.
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId2, 1);

        assertEq(erc1155.balanceOf(attacker, tokenId), 1, "Attack should have collected back their token.");

        // Note: Attacker does not collect payout, it sets auction quantity to 0 and prevent further token collections.

        // 3. Fixed: Profit.
        assertEq(erc1155.balanceOf(marketplace, tokenId), 1);

        vm.expectRevert("Marketplace: payout already completed.");
        EnglishAuctionsLogic(marketplace).collectAuctionTokens(auctionId2);

        // assertEq(erc1155.balanceOf(attacker, tokenId), 2, "Attacker should have collected the 2nd token for free.");

        vm.stopPrank();
    }
}

contract IssueC3_MarketplaceEnglishAuctionsTest is BaseTest, IExtension {
    // Target contract
    address public marketplace;

    // Participants
    address public marketplaceDeployer;
    address public seller;
    address public buyer;

    function setUp() public override {
        super.setUp();

        marketplaceDeployer = getActor(1);
        seller = getActor(2);
        buyer = getActor(3);

        // Deploy implementation.
        Extension[] memory extensions = _setupExtensions();
        address impl = address(
            new MarketplaceV3(MarketplaceV3.MarketplaceConstructorParams(extensions, address(0), address(weth)))
        );

        vm.prank(marketplaceDeployer);
        marketplace = address(
            new TWProxy(
                impl,
                abi.encodeCall(
                    MarketplaceV3.initialize,
                    (marketplaceDeployer, "", new address[](0), marketplaceDeployer, 0)
                )
            )
        );

        // Setup roles for seller and assets
        vm.startPrank(marketplaceDeployer);
        Permissions(marketplace).revokeRole(keccak256("ASSET_ROLE"), address(0));
        Permissions(marketplace).revokeRole(keccak256("LISTER_ROLE"), address(0));
        Permissions(marketplace).grantRole(keccak256("LISTER_ROLE"), seller);
        Permissions(marketplace).grantRole(keccak256("ASSET_ROLE"), address(erc721));
        Permissions(marketplace).grantRole(keccak256("ASSET_ROLE"), address(erc1155));

        vm.stopPrank();

        vm.label(impl, "MarketplaceV3_Impl");
        vm.label(marketplace, "Marketplace");
        vm.label(seller, "Seller");
        vm.label(buyer, "Buyer");
        vm.label(address(erc721), "ERC721_Token");
        vm.label(address(erc1155), "ERC1155_Token");
    }

    function _setupExtensions() internal returns (Extension[] memory extensions) {
        extensions = new Extension[](1);

        // Deploy `EnglishAuctions`
        address englishAuctions = address(new EnglishAuctionsLogic(address(weth)));
        vm.label(englishAuctions, "EnglishAuctions_Extension");

        // Extension: EnglishAuctionsLogic
        Extension memory extension_englishAuctions;
        extension_englishAuctions.metadata = ExtensionMetadata({
            name: "EnglishAuctionsLogic",
            metadataURI: "ipfs://EnglishAuctions",
            implementation: englishAuctions
        });

        extension_englishAuctions.functions = new ExtensionFunction[](12);
        extension_englishAuctions.functions[0] = ExtensionFunction(
            EnglishAuctionsLogic.totalAuctions.selector,
            "totalAuctions()"
        );
        extension_englishAuctions.functions[1] = ExtensionFunction(
            EnglishAuctionsLogic.createAuction.selector,
            "createAuction((address,uint256,uint256,address,uint256,uint256,uint64,uint64,uint64,uint64))"
        );
        extension_englishAuctions.functions[2] = ExtensionFunction(
            EnglishAuctionsLogic.cancelAuction.selector,
            "cancelAuction(uint256)"
        );
        extension_englishAuctions.functions[3] = ExtensionFunction(
            EnglishAuctionsLogic.collectAuctionPayout.selector,
            "collectAuctionPayout(uint256)"
        );
        extension_englishAuctions.functions[4] = ExtensionFunction(
            EnglishAuctionsLogic.collectAuctionTokens.selector,
            "collectAuctionTokens(uint256)"
        );
        extension_englishAuctions.functions[5] = ExtensionFunction(
            EnglishAuctionsLogic.bidInAuction.selector,
            "bidInAuction(uint256,uint256)"
        );
        extension_englishAuctions.functions[6] = ExtensionFunction(
            EnglishAuctionsLogic.isNewWinningBid.selector,
            "isNewWinningBid(uint256,uint256)"
        );
        extension_englishAuctions.functions[7] = ExtensionFunction(
            EnglishAuctionsLogic.getAuction.selector,
            "getAuction(uint256)"
        );
        extension_englishAuctions.functions[8] = ExtensionFunction(
            EnglishAuctionsLogic.getAllAuctions.selector,
            "getAllAuctions(uint256,uint256)"
        );
        extension_englishAuctions.functions[9] = ExtensionFunction(
            EnglishAuctionsLogic.getAllValidAuctions.selector,
            "getAllValidAuctions(uint256,uint256)"
        );
        extension_englishAuctions.functions[10] = ExtensionFunction(
            EnglishAuctionsLogic.getWinningBid.selector,
            "getWinningBid(uint256)"
        );
        extension_englishAuctions.functions[11] = ExtensionFunction(
            EnglishAuctionsLogic.isAuctionExpired.selector,
            "isAuctionExpired(uint256)"
        );

        extensions[0] = extension_englishAuctions;
    }

    function _setupERC1155BalanceForSeller(address _seller, uint256 _numOfTokens) private {
        erc1155.mint(_seller, 0, _numOfTokens);
    }

    function _setup_newAuction_1155() private returns (uint256 auctionId) {
        // Sample auction parameters.
        address assetContract = address(erc1155);
        uint256 tokenId = 0;
        uint256 quantity = 2;
        address currency = address(erc20);
        uint256 minimumBidAmount = 1 ether;
        uint256 buyoutBidAmount = 10 ether;
        uint64 timeBufferInSeconds = 10 seconds;
        uint64 bidBufferBps = 1000;
        uint64 startTimestamp = 100;
        uint64 endTimestamp = 200;

        // Mint the erc1155 tokens to seller. These tokens will be auctioned.
        _setupERC1155BalanceForSeller(seller, 2);

        // Approve Marketplace to transfer token.
        vm.prank(seller);
        erc1155.setApprovalForAll(marketplace, true);

        // Auction tokens.
        IEnglishAuctions.AuctionParameters memory auctionParams = IEnglishAuctions.AuctionParameters(
            assetContract,
            tokenId,
            quantity,
            currency,
            minimumBidAmount,
            buyoutBidAmount,
            timeBufferInSeconds,
            bidBufferBps,
            startTimestamp,
            endTimestamp
        );

        vm.prank(seller);
        auctionId = EnglishAuctionsLogic(marketplace).createAuction(auctionParams);
    }

    function test_state_collectAuctionTokens_afterAuctionPayout() public {
        uint256 auctionId = _setup_newAuction_1155();
        IEnglishAuctions.Auction memory existingAuction = EnglishAuctionsLogic(marketplace).getAuction(auctionId);

        // Verify existing auction at `auctionId`
        assertEq(existingAuction.assetContract, address(erc1155));

        vm.warp(existingAuction.startTimestamp);

        // place bid
        erc20.mint(buyer, 5 ether);
        vm.startPrank(buyer);
        erc20.approve(marketplace, 5 ether);
        EnglishAuctionsLogic(marketplace).bidInAuction(auctionId, 5 ether);
        vm.stopPrank();

        (address bidder, address currency, uint256 bidAmount) = EnglishAuctionsLogic(marketplace).getWinningBid(
            auctionId
        );

        // Seller is owner of token.
        assertEq(erc20.balanceOf(marketplace), 5 ether);
        assertEq(erc20.balanceOf(buyer), 0);
        assertEq(buyer, bidder);
        assertEq(currency, address(erc20));
        assertEq(bidAmount, 5 ether);

        vm.warp(existingAuction.endTimestamp);

        // collect auction payout
        vm.prank(seller);
        EnglishAuctionsLogic(marketplace).collectAuctionPayout(auctionId);

        // collect buyer token
        vm.prank(buyer);
        EnglishAuctionsLogic(marketplace).collectAuctionTokens(auctionId);

        // token is NOT stuck in the marketplace
        assertEq(erc1155.balanceOf(marketplace, 0), 0);
        assertEq(erc1155.balanceOf(buyer, 0), 2);
    }
}
