# Marketplace V3 design document.

This is a live document that explains what the [thirdweb](https://thirdweb.com/) `Marketplace V3` smart contract is, how it works and can be used, and why it is written the way it is.

The document is written for technical and non-technical readers. To ask further questions about `Marketplace V3`, please join the [thirdweb discord](https://discord.gg/thirdweb) or create a [github issue](https://github.com/thirdweb-dev/contracts/issues).

---

## Background

The [thirdweb](https://thirdweb.com/) `Marketplace V3` is a marketplace where where people can sell NFTs — [ERC 721](https://eips.ethereum.org/EIPS/eip-721) or [ERC 1155](https://eips.ethereum.org/EIPS/eip-1155) tokens — at a fixed price ( what we'll refer to as a "Direct listing"), or auction them (what we'll refer to as an "Auction listing"). It also allows users to make "Offers" on unlisted NFTs.

`Marketplace V3` offers improvements over previous version in terms of design and features, which are discussed in this document. You can refer to previous (v2) `Marketplace` design document [here](https://github.com/thirdweb-dev/contracts/blob/main/contracts/prebuilts/marketplace-legacy/marketplace.md).

## Context behind this update

We have given `Marketplace` an update that was long overdue. The marketplace product is still made up of three core ways of exchanging NFTs for money:

1. Selling NFTs via a ‘direct listing’.
2. Auctioning off NFTs.
3. Making offers for NFTs not on sale at all, or at favorable prices.

The core improvement about the `Marketplace V3` smart contract is better developer experience of working with the contract.

Previous version had some limitations, arising due to (1) the smart contract size limit of `~24.576 kb` on Ethereum mainnet (and other thirdweb supported chains), and (2) the way the smart contract code is organized (single, large smart contract that inherits other contracts). The previous `Marketplace` smart contract has functions that have multiple jobs, behave in many different ways under different circumstances, and a lack of convenient view functions to read data easily.

Moreover, over time, we received feature requests for `Marketplace`, some of which have been incorporated in `Marketplace V3`, for e.g.:

- Ability to accept multiple currencies for direct listings
- Ability to explicitly cancel listings
- Explicit getter functions for fetching high level states e.g. “has an auction ended”, “who is the winning bidder”, etc.
- Simplify start time and expiration time for listings

For all these reasons and feature additions, the `Marketplace` contract is getting an update, and being rolled out as `Marketplace V3`. In this update:

- the contract has been broken down into independent extensions (later offered in ContractKit).
- the contract provides explicit functions for each important action (something that is missing from the contract, today).
- the contract provides convenient view functions for all relevant state of the contract, without expecting users to rely on events to read critical information.

Finally, to accomplish all these things without the constraint of the smart contract size limit, the `Marketplace V3` contract is written in the following new code pattern, which we call `Plugin Pattern`. It was influenced by [EIP-2535](https://eips.ethereum.org/EIPS/eip-2535). You can read more about Plugin Pattern [here](https://blog.thirdweb.com/).

## Extensions that make up `Marketplace V3`

The `Marketplace V3` smart contract is now written as the sum of three main extension smart contracts:

1. `DirectListings`: List NFTs for sale at a fixed price. Buy NFTs from listings.
2. `EnglishAuctions`: Put NFTs up for auction. Bid for NFTs up on auction. The highest bid within an auction’s duration wins.
3. `Offers`: Make offers of ERC20 or native token currency for NFTs. Accept a favorable offer if you own the NFTs wanted.

Each of these extension smart contracts is independent, and does not care about the state of the other extension contracts.

### What the Marketplace will look like to users

There are two groups of users — (1) thirdweb's customers who'll set up the marketplace, and (2) the end users of thirdweb customers' marketplaces.

To thirdweb customers, the marketplace can be set up like any of the other thirdweb contract (e.g. 'NFT Collection') through the thirdweb dashboard, the thirdweb SDK, or by directly consuming the open sourced marketplace smart contract.

To the end users of thirdweb customers, the experience of using the marketplace will feel familiar to popular marketplace platforms like OpenSea, Zora, etc. The biggest difference in user experience will be that performing any action on the marketplace requires gas fees.

- Thirdweb's customers
  - Deploy the marketplace contract like any other thirdweb contract.
  - Can set a % 'platform fee'. This % is collected on every sale — when a buyer buys tokens from a direct listing, and when a seller collects the highest bid on auction closing. This platform fee is distributed to the platform fee recipient (set by a contract admin).
  - Can list NFTs for sale at a fixed price.
  - Can edit an existing listing's parameters, e.g. the currency accepted. An auction's parameters cannot be edited once it has started.
  - Can make offers to NFTs listed/unlisted for a fixed price.
  - Can auction NFTs.
  - Can make bids to auctions.
  - Must pay gas fees to perform any actions, including the actions just listed.

### EIPs implemented / supported

To be able to escrow NFTs in the case of auctions, Marketplace implements the receiver interfaces for [ERC1155](https://eips.ethereum.org/EIPS/eip-1155) and [ERC721](https://eips.ethereum.org/EIPS/eip-721) tokens.

To enable meta-transactions (gasless), Marketplace implements [ERC2771](https://eips.ethereum.org/EIPS/eip-2771).

Marketplace also honors [ERC2981](https://eips.ethereum.org/EIPS/eip-2981) for the distribution of royalties on direct and auction listings.

### Events emitted

All events emitted by the contract, as well as when they're emitted, can be found in the interface of the contract, [here](https://github.com/thirdweb-dev/contracts/blob/main/contracts/prebuilts/marketplace/IMarketplace.sol). In general, events are emitted whenever there is a state change in the contract.

### Currency transfers

The contract supports both ERC20 currencies and a chain's native token (e.g. ether for Ethereum mainnet). This means that any action that involves transferring currency (e.g. buying a token from a direct listing) can be performed with either an ERC20 token or the chain's native token.

💡 **Note**: The exception is offers — these can only be made with ERC20 tokens, since Marketplace needs to transfer the offer amount from the buyer to the seller, in case the latter accepts the offer. This cannot be done with native tokens without escrowing the requisite amount of currency.

The contract wraps all native tokens deposited into it as the canonical ERC20 wrapped version of the native token (e.g. WETH for ether). The contract unwraps the wrapped native token when transferring native tokens to a given address.

If the contract fails to transfer out native tokens, it wraps them back to wrapped native tokens, and transfers the wrapped native tokens to the concerned address. The contract may fail to transfer out native tokens to an address, if the address represents a smart contract that cannot accept native tokens transferred to it directly.

# API Reference for Extensions

## Direct listings

The `DirectListings` extension smart contract lets you buy and sell NFTs (ERC-721 or ERC-1155) for a fixed price.

### `createListing`

**What:** List NFTs (ERC721 or ERC1155) for sale at a fixed price.

- Interface

  ```solidity
  struct ListingParameters {
    address assetContract;
    uint256 tokenId;
    uint256 quantity;
    address currency;
    uint256 pricePerToken;
    uint128 startTimestamp;
    uint128 endTimestamp;
    bool reserved;
  }

  function createListing(ListingParameters memory params) external returns (uint256 listingId);

  ```

- Parameters
  | Parameter | Description |
  | ------------- | --------------------------------------------------------------------------------------------------- |
  | assetContract | The address of the smart contract of the NFTs being listed. |
  | tokenId | The tokenId of the NFTs being listed. |
  | quantity | The quantity of NFTs being listed. This must be non-zero, and is expected to be 1 for ERC-721 NFTs. |
  | currency | The currency in which the price must be paid when buying the listed NFTs. The address considered for native tokens of the chain is 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE |
  | pricePerToken | The price to pay per unit of NFTs listed. |
  | startTimestamp | The UNIX timestamp at and after which NFTs can be bought from the listing. |
  | expirationTimestamp | The UNIX timestamp at and after which NFTs cannot be bought from the listing. |
  | reserved | Whether the listing is reserved to be bought from a specific set of buyers. |
- Criteria that must be satisfied
  - The listing creator must own the NFTs being listed.
  - The listing creator must have already approved Marketplace to transfer the NFTs being listed (since the creator is not required to escrow NFTs in the Marketplace).
  - The listing creator must list a non-zero quantity of tokens. If listing ERC-721 tokens, the listing creator must list only quantity `1`.
  - The listing start time must not be less than 1+ hour before the block timestamp of the transaction. The listing end time must be after the listing start time.
  - Only ERC-721 or ERC-1155 tokens must be listed.
  - The listing creator must have `LISTER_ROLE` if role restrictions are active.
  - The asset being listed must have `ASSET_ROLE` if role restrictions are active.

### `updateListing`

**What:** Update information (e.g. price) for one of your listings on the marketplace.

- Interface

  ```solidity
  struct ListingParameters {
    address assetContract;
    uint256 tokenId;
    uint256 quantity;
    address currency;
    uint256 pricePerToken;
    uint128 startTimestamp;
    uint128 endTimestamp;
    bool reserved;
  }

  function updateListing(uint256 listingId, ListingParameters memory params) external
  ```

- Parameters
  | Parameter | Description |
  | ------------- | --------------------------------------------------------------------------------------------------- |
  | listingId | The unique ID of the listing being updated. |
  | assetContract | The address of the smart contract of the NFTs being listed. |
  | tokenId | The tokenId of the NFTs being listed. |
  | quantity | The quantity of NFTs being listed. This must be non-zero, and is expected to be 1 for ERC-721 NFTs. |
  | currency | The currency in which the price must be paid when buying the listed NFTs. The address considered for native tokens of the chain is 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE |
  | pricePerToken | The price to pay per unit of NFTs listed. |
  | startTimestamp | The UNIX timestamp at and after which NFTs can be bought from the listing. |
  | expirationTimestamp | The UNIX timestamp at and after which NFTs cannot be bought from the listing. |
  | reserved | Whether the listing is reserved to be bought from a specific set of buyers. |
- Criteria that must be satisfied
  - The caller of the function _must_ be the creator of the listing being updated.
  - The listing creator must own the NFTs being listed.
  - The listing creator must have already approved Marketplace to transfer the NFTs being listed (since the creator is not required to escrow NFTs in the Marketplace).
  - The listing creator must list a non-zero quantity of tokens. If listing ERC-721 tokens, the listing creator must list only quantity `1`.
  - Only ERC-721 or ERC-1155 tokens must be listed.
  - The listing start time must be greater than or equal to the incumbent start timestamp. The listing end time must be after the listing start time.
  - The asset being listed must have `ASSET_ROLE` if role restrictions are active.

### `cancelListing`

**What:** Cancel (i.e. delete) one of your listings on the marketplace.

- Interface

  ```solidity
  function cancelListing(uint256 listingId) external;

  ```

- Parameters
  | Parameter | Description |
  | --------- | --------------------------------------------------- |
  | listingId | The unique ID of the listing to cancel i.e. delete. |
- Criteria that must be satisfied
  - The caller of the function _must_ be the creator of the listing being cancelled.
  - The listing must exist.

### `approveBuyerForListing`

**What:** Approve a buyer to buy from a reserved listing.

- Interface

  ```solidity
  function approveBuyerForListing(
    uint256 listingId,
    address buyer,
    bool toApprove
  ) external;

  ```

- Parameters
  | Parameter | Description |
  | --------- | ------------------------------------------------------------ |
  | listingId | The unique ID of the listing. |
  | buyer | The address of the buyer to approve to buy from the listing. |
  | toApprove | Whether to approve the buyer to buy from the listing. |
- Criteria that must be satisfied
  - The caller of the function _must_ be the creator of the listing in question.
  - The listing must be reserved.

### `approveCurrencyForListing`

**What:** Approve a currency as a form of payment for the listing.

- Interface

  ```solidity
  function approveCurrencyForListing(
    uint256 listingId,
    address currency,
    uint256 pricePerTokenInCurrency,
  ) external;

  ```

- Parameters
  | Parameter | Description |
  | ----------------------- | ---------------------------------------------------------------------------- |
  | listingId | The unique ID of the listing. |
  | currency | The address of the currency to approve as a form of payment for the listing. |
  | pricePerTokenInCurrency | The price per token for the currency to approve. A value of 0 here disapprove a currency. |
- Criteria that must be satisfied
  - The caller of the function _must_ be the creator of the listing in question.
  - The currency being approved must not be the main currency accepted by the listing.

### `buyFromListing`

**What:** Buy NFTs from a listing.

- Interface

  ```solidity
  function buyFromListing(
    uint256 listingId,
    address buyFor,
    uint256 quantity,
    address currency,
    uint256 expectedTotalPrice
  ) external payable;

  ```

- Parameters
  | Parameter | Description |
  | ------------------ | ---------------------------------------------------------- |
  | listingId | The unique ID of the listing to buy NFTs from. |
  | buyFor | The recipient of the NFTs being bought. |
  | quantity | The quantity of NFTs to buy from the listing. |
  | currency | The currency to use to pay for NFTs. |
  | expectedTotalPrice | The expected total price to pay for the NFTs being bought. |
- Criteria that must be satisfied
  - The buyer must own the total price amount to pay for the NFTs being bought.
  - The buyer must approve the Marketplace to transfer the total price amount to pay for the NFTs being bought.
  - If paying in native tokens, the buyer must send exactly the expected total price amount of native tokens along with the transaction.
  - The buyer’s expected total price must match the actual total price for the NFTs being bought.
  - The buyer must buy a non-zero quantity of NFTs.
  - The buyer must not attempt to buy more NFTs than are listed at the time.
  - The buyer must pay in a currency approved by the listing creator.

### `totalListings`

**What:** Returns the total number of listings created so far.

- Interface

  ```solidity
  function totalListings() external view returns (uint256);

  ```

### `getAllListings`

**What:** Returns all listings between the start and end Id (both inclusive) provided.

- Interface

  ```solidity
  enum TokenType {
    ERC721,
    ERC1155
  }

  enum Status {
    UNSET,
    CREATED,
    COMPLETED,
    CANCELLED
  }

  struct Listing {
    uint256 listingId;
    address listingCreator;
    address assetContract;
    uint256 tokenId;
    uint256 quantity;
    address currency;
    uint256 pricePerToken;
    uint128 startTimestamp;
    uint128 endTimestamp;
    bool reserved;
    TokenType tokenType;
    Status status;
  }

  function getAllListings(uint256 startId, uint256 endId) external view returns (Listing[] memory listings);

  ```

- Parameters
  | Parameter | Description |
  | --------- | -------------------------- |
  | startId | Inclusive start listing Id |
  | endId | Inclusive end listing Id |

### `getAllValidListings`

**What:** Returns all valid listings between the start and end Id (both inclusive) provided. A valid listing is where the listing is active, as well as the creator still owns and has approved Marketplace to transfer the listed NFTs.

- Interface

  ```solidity
  function getAllValidListings(uint256 startId, uint256 endId) external view returns (Listing[] memory listings);

  ```

- Parameters
  | Parameter | Description |
  | --------- | -------------------------- |
  | startId | Inclusive start listing Id |
  | endId | Inclusive end listing Id |

### `getListing`

**What:** Returns a listing at the provided listing ID.

- Interface

  ```solidity
  function getListing(uint256 listingId) external view returns (Listing memory listing);

  ```

- Parameters
  | Parameter | Description |
  | --------- | ------------------------------- |
  | listingId | The ID of the listing to fetch. |

## English auctions

The `EnglishAuctions` extension smart contract lets you sell NFTs (ERC-721 or ERC-1155) in an english auction.

### `createAuction`

**What:** Put up NFTs (ERC721 or ERC1155) for an english auction.

- **What is an English auction?**
  - `Alice` deposits her NFTs in the Marketplace contract and specifies: **[1]** a minimum bid amount, and **[2]** a duration for the auction.
  - `Bob` is the first person to make a bid.
    - _Before_ the auction duration ends, `Bob` makes a bid in the auction (≥ minimum bid).
    - `Bob`'s bid is now deposited and locked in the Marketplace.
  - `Tom` also wants the auctioned NFTs. `Tom`'s bid _must_ be greater than `Bob`'s bid.
    - _Before_ the auction duration ends, `Tom` makes a bid in the auction (≥ `Bob`'s bid).
    - `Tom`'s bid is now deposited and locked in the Marketplace. `Bob`'s is _automatically_ refunded his bid.
  - _After_ the auction duration ends:
    - `Alice` collects the highest bid that has been deposited in Marketplace.
    - The “highest bidder” e.g. `Tom` collects the auctioned NFTs.
- Interface

  ```solidity
  struct AuctionParameters {
    address assetContract;
    uint256 tokenId;
    uint256 quantity;
    address currency;
    uint256 minimumBidAmount;
    uint256 buyoutBidAmount;
    uint64 timeBufferInSeconds;
    uint64 bidBufferBps;
    uint64 startTimestamp;
    uint64 endTimestamp;
  }

  function createAuction(AuctionParameters memory params) external returns (uint256 auctionId);

  ```

- Parameters
  | Parameter | Description |
  | ------------------- | ---------------------------------------------------------------------------------------------------------------------- |
  | assetContract | The address of the smart contract of the NFTs being auctioned. |
  | tokenId | The tokenId of the NFTs being auctioned. |
  | quantity | The quantity of NFTs being auctioned. This must be non-zero, and is expected to be 1 for ERC-721 NFTs. |
  | currency | The currency in which the bid must be made when bidding for the auctioned NFTs. |
  | minimumBidAmount | The minimum bid amount for the auction. |
  | buyoutBidAmount | The total bid amount for which the bidder can directly purchase the auctioned items and close the auction as a result. |
  | timeBufferInSeconds | This is a buffer e.g. x seconds. If a new winning bid is made less than x seconds before expirationTimestamp, the expirationTimestamp is increased by x seconds. |
  | bidBufferBps | This is a buffer in basis points e.g. x%. To be considered as a new winning bid, a bid must be at least x% greater than the current winning bid. |
  | startTimestamp | The timestamp at and after which bids can be made to the auction |
  | expirationTimestamp | The timestamp at and after which bids cannot be made to the auction. |
- Criteria that must be satisfied
  - The auction creator must own and approve Marketplace to transfer the auctioned tokens to itself.
  - The auction creator must auction a non-zero quantity of tokens. If the auctioned token is ERC721, the quantity must be `1`.
  - The auction creator must specify a non-zero time and bid buffers.
  - The minimum bid amount must be less than the buyout bid amount.
  - The auction start time must not be less than 1+ hour before the block timestamp of the transaction. The auction end time must be after the auction start time.
  - The auctioned token must be ERC-721 or ERC-1155.
  - The auction creator must have `LISTER_ROLE` if role restrictions are active.
  - The asset being auctioned must have `ASSET_ROLE` if role restrictions are active.

### `cancelAuction`

**What:** Cancel an auction.

- Interface

  ```solidity
  function cancelAuction(uint256 auctionId) external;

  ```

- Parameters
  | Parameter | Description |
  | --------- | --------------------------------------- |
  | auctionId | The unique ID of the auction to cancel. |
- Criteria that must be satisfied
  - The caller of the function must be the auction creator.
  - There must be no bids placed in the ongoing auction. (Default true for all auctions that haven’t started)

### `collectAuctionPayout`

**What:** Once the auction ends, collect the highest bid made for your auctioned NFTs.

- Interface

  ```solidity
  function collectAuctionPayout(uint256 auctionId) external;

  ```

- Parameters
  | Parameter | Description |
  | --------- | ------------------------------------------------------- |
  | auctionId | The unique ID of the auction to collect the payout for. |
- Criteria that must be satisfied
  - The auction must be expired.
  - The auction must have received at least one valid bid.

### `collectAuctionTokens`

**What:** Once the auction ends, collect the auctioned NFTs for which you were the highest bidder.

- Interface

  ```solidity
  function collectAuctionTokens(uint256 auctionId) external;

  ```

- Parameters
  | Parameter | Description |
  | --------- | ------------------------------------------------------- |
  | auctionId | The unique ID of the auction to collect the payout for. |
- Criteria that must be satisfied
  - The auction must be expired.
  - The caller must be the auction winner.

### `bidInAuction`

**What:** Make a bid in an auction.

- Interface

  ```solidity
  function bidInAuction(uint256 auctionId, uint256 bidAmount) external payable;

  ```

- Parameters
  | Parameter | Description |
  | --------- | --------------------------------------- |
  | auctionId | The unique ID of the auction to bid in. |
  | bidAmount | The total bid amount. |
- Criteria that must be satisfied
  - Auction must not be expired.
  - The caller must own and approve Marketplace to transfer the requisite bid amount to itself.
  - The bid amount must be a winning bid amount. (For convenience, this can be verified by calling `isNewWinningBid`)

### `isNewWinningBid`

**What:** Check whether a given bid amount would make for a new winning bid.

- Interface

  ```solidity
  function isNewWinningBid(uint256 auctionId, uint256 bidAmount) external view returns (bool);

  ```

- Parameters
  | Parameter | Description |
  | --------- | --------------------------------------- |
  | auctionId | The unique ID of the auction to bid in. |
  | bidAmount | The total bid amount. |
- Criteria that must be satisfied
  - The auction must not have been cancelled or expired.

### `totalAuctions`

**What:** Returns the total number of auctions created so far.

- Interface

  ```solidity
  function totalAuctions() external view returns (uint256);

  ```

### `getAuction`

**What:** Fetch the auction info at a particular auction ID.

- Interface

  ```solidity
  struct Auction {
    uint256 auctionId;
    address auctionCreator;
    address assetContract;
    uint256 tokenId;
    uint256 quantity;
    address currency;
    uint256 minimumBidAmount;
    uint256 buyoutBidAmount;
    uint64 timeBufferInSeconds;
    uint64 bidBufferBps;
    uint64 startTimestamp;
    uint64 endTimestamp;
    TokenType tokenType;
    Status status;
  }

  function getAuction(uint256 auctionId) external view returns (Auction memory auction);

  ```

- Parameters
  | Parameter | Description |
  | --------- | ----------------------------- |
  | auctionId | The unique ID of the auction. |

### `getAllAuctions`

**What:** Returns all auctions between the start and end Id (both inclusive) provided.

- Interface

  ```solidity
  function getAllAuctions(uint256 startId, uint256 endId) external view returns (Auction[] memory auctions);

  ```

- Parameters
  | Parameter | Description |
  | --------- | -------------------------- |
  | startId | Inclusive start auction Id |
  | endId | Inclusive end auction Id |

### `getAllValidAuctions`

**What:** Returns all valid auctions between the start and end Id (both inclusive) provided. A valid auction is where the auction is active, as well as the creator still owns and has approved Marketplace to transfer the auctioned NFTs.

- Interface

  ```solidity
  function getAllValidAuctions(uint256 startId, uint256 endId) external view returns (Auction[] memory auctions);

  ```

- Parameters
  | Parameter | Description |
  | --------- | -------------------------- |
  | startId | Inclusive start auction Id |
  | endId | Inclusive end auction Id |

### `getWinningBid`

**What:** Get the winning bid of an auction.

- Interface

  ```solidity
  function getWinningBid(uint256 auctionId)
    external
    view
    returns (
      address bidder,
      address currency,
      uint256 bidAmount
    );

  ```

- Parameters
  | Parameter | Description |
  | --------- | ---------------------------- |
  | auctionId | The unique ID of an auction. |

### `isAuctionExpired`

**What:** Returns whether an auction is expired or not.

- Interface

  ```solidity
  function isAuctionExpired(uint256 auctionId) external view returns (bool);

  ```

- Parameters
  | Parameter | Description |
  | --------- | ---------------------------- |
  | auctionId | The unique ID of an auction. |

## Offers

### `makeOffer`

**What:** Make an offer for any ERC721 or ERC1155 NFTs (unless `ASSET_ROLE` restrictions apply)

- Interface

  ```solidity
  struct OfferParams {
    address assetContract;
    uint256 tokenId;
    uint256 quantity;
    address currency;
    uint256 totalPrice;
    uint256 expirationTimestamp;
  }

  function makeOffer(OfferParams memory params) external returns (uint256 offerId);

  ```

- Parameters
  | Parameter | Description |
  | ------------------- | ----------------------------------------- |
  | assetContract | The contract address of the NFTs wanted. |
  | tokenId | The tokenId of the NFTs wanted. |
  | quantity | The quantity of NFTs wanted. |
  | currency | The currency offered for the NFT wanted. |
  | totalPrice | The price offered for the NFTs wanted. |
  | expirationTimestamp | The timestamp at which the offer expires. |
- Criteria that must be satisfied
  - The offeror must own and approve Marketplace to transfer the requisite amount currency offered for the NFTs wanted.
  - The offeror must make an offer for non-zero quantity of NFTs. If offering for ERC721 tokens, the quantity wanted must be `1`.
  - Expiration timestamp must be greater than block timestamp, or within 1 hour of block timestamp.

### `cancelOffer`

**What:** Cancel an existing offer.

- Interface

  ```solidity
  function cancelOffer(uint256 offerId) external;

  ```

- Parameters
  | Parameter | Description |
  | --------- | -------------------------- |
  | offerId | The unique ID of the offer |
- Criteria that must be satisfied
  - The caller of the function must be the offeror.

### `acceptOffer`

**What:** Accept an offer made for your NFTs.

- Interface

  ```solidity
  function acceptOffer(uint256 offerId) external;

  ```

- Parameters
  | Parameter | Description |
  | --------- | --------------------------- |
  | offerId | The unique ID of the offer. |
- Criteria that must be satisfied
  - The caller of the function must own and approve Marketplace to transfer the tokens for which the offer is made.
  - The offeror must still own and have approved Marketplace to transfer the requisite amount currency offered for the NFTs wanted.

### `totalOffers`

**What:** Returns the total number of offers created so far.

- Interface

  ```solidity
  function totalOffers() external view returns (uint256);

  ```

### `getOffer`

**What:** Returns the offer at a particular offer Id.

- Interface

  ```solidity
  struct Offer {
    uint256 offerId;
    address offeror;
    address assetContract;
    uint256 tokenId;
    uint256 quantity;
    address currency;
    uint256 totalPrice;
    uint256 expirationTimestamp;
    TokenType tokenType;
    Status status;
  }

  function getOffer(uint256 offerId) external view returns (Offer memory offer);

  ```

- Parameters
  | Parameter | Description |
  | --------- | -------------------------- |
  | offerId | The unique ID of an offer. |

### `getAllOffers`

**What:** Returns all offers between the start and end Id (both inclusive) provided.

- Interface

  ```solidity
  function getAllOffers(uint256 startId, uint256 endId) external view returns (Offer[] memory offers);

  ```

- Parameters
  | Parameter | Description |
  | --------- | -------------------------- |
  | startId | Inclusive start offer Id |
  | endId | Inclusive end offer Id |

### `getAllValidOffers`

**What:** Returns all valid offers between the start and end Id (both inclusive) provided. A valid offer is where the offer is active, as well as the offeror still owns and has approved Marketplace to transfer the currency tokens.

- Interface

  ```solidity
  function getAllValidOffer(uint256 startId, uint256 endId) external view returns (Offer[] memory offers);

  ```

- Parameters
  | Parameter | Description |
  | --------- | -------------------------- |
  | startId | Inclusive start offer Id |
  | endId | Inclusive end offer Id |
