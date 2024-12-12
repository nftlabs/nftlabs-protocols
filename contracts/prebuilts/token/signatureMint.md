# Signature minting design document.

This is a live document that explains the 'signature minting' mechanism used in [thirdweb](https://thirdweb.com/) `Token` smart contracts.

The document is written for technical and non-technical readers. To ask further questions about any of thirdweb’s `Drop`, please join the [thirdweb discord](https://discord.gg/thirdweb) or create a github issue.

---

## Background

The 'signature minting' mechanism used in [thirdweb](https://thirdweb.com/) `Token` smart contracts is a way for a contract admin to
authorize an external party's request to mint tokens on the admin's contract. At a high level, this means you can authorize some external party to mint tokens on your contract, and specify what exactly will be minted by that external party.

A contract admin signs a 'payload' or 'mint request' which specifies parameters around a mint e.g. which address should tokens be minted to, what price should be collected in exchange for the minted tokens, etc.

Any external party can then present a smart contract implementing the 'signature minting' mechanism with a payload, along with the signature generated from a contract admin signing the payload. Tokens will then be minted according to the information specified in the payload.

The following diagram illustrates how the 'signature minting' flow looks like. For example, consider a webapp like [wombo.art](https://www.wombo.art/) which lets a user generate artwork on its website. Once a user has generated artwork on the wombo website, wombo can allow the user to mint their generated artwork as an NFT on wombo's own contract, where wombo can ensure that what the user will mint on wombo's contract is the intended generated artwork.

![signature-minting-diagram-1.png](/assets/signature-minting-diag-1.png)

### Why we're developing `Signature Minting`

We’ve observed that there are largely three distinct contexts under which one mints tokens:

1. Minting tokens for yourself on a contract you own. E.g. a person wants to mint their Twitter profile picture as an NFT.
2. Having an audience mint tokens on a contract you own.
    1. The nature of tokens to be minted by the audience is pre-determined by the contract admin. E.g. a 10k NFT drop where the contents of the NFTs to be minted by the audience is already known and determined by the contract admin before the audience comes in to mint NFTs.
    2. The nature of tokens to be minted by the audience is *not* pre-determined by the contract admin. E.g. a course ‘certificate’ dynamically generated with the name of the course participant, to be minted by the course participant at the time of course completion.

The thirdweb `Drop` contracts serve the cases described in 2(i).

The thirdweb `Token` contracts serve the cases described in (1) and 2(ii). And the 'signature minting' mechanism is particularly designed to serve the case described in 2(ii).

## Technical Details

We'll now go over the technical details involved in the 'signature minting' mechanism illustrated in the diagram in the preceding section.

### Payload / Mint request

We'll now cover what makes up a payload, or 'mint request':

```solidity
struct MintRequest {
    address to;
    address royaltyRecipient;
    uint256 royaltyBps;
    address primarySaleRecipient;
    uint256 tokenId;
    string uri;
    uint256 quantity;
    uint256 pricePerToken;
    address currency;
    uint128 validityStartTimestamp;
    uint128 validityEndTimestamp;
    bytes32 uid;
}
```

| Parameter | Description |
| --- | --- |
| to | The receiver of the tokens to mint. |
| royaltyRecipient | The recipient of the minted token's secondary sales royalties. (Not applicable for ERC20 tokens) |
| royaltyBps | The percentage of the minted token's secondary sales to take as royalties. (Not applicable for ERC20 tokens) |
| primarySaleRecipient | The recipient of the minted token's primary sales proceeds. |
| tokenId | The tokenId of the token to mint. (Only applicable for ERC1155 tokens)|
| uri | The metadata URI of the token to mint. (Not applicable for ERC20 tokens)|
| quantity | The quantity of tokens to mint.|
| pricePerToken | The price to pay per quantity of tokens minted. (For TokenERC20, this parameter is `price`, indicating the total price of all tokens)|
| currency | The currency in which to pay the price per token minted.|
| validityStartTimestamp | The unix timestamp after which the payload is valid.|
| validityEndTimestamp | The unix timestamp at which the payload expires.|
| uid | A unique identifier for the payload.|

The described fields in `MintRequest` are what make up a payload or 'mint request'. This is the payload that a contract admin signs off, to be used by an external party to mint tokens on the admin's contract.

When any external party presents a payload to the contract implementing the 'signature minting' mechanism, tokens are minted exactly according to the information specified in the presented `MintRequest`.

### Minting tokens with a payload / 'mint request'

Any external party can present a smart contract implementing the 'signature minting' mechanism with a payload, along with the signature generated from a contract admin signing the payload. Tokens will then be minted according to the information specified in the payload.

To mint tokens with a payload, the following function is called:

```solidity
function mintWithSignature(MintRequest calldata req, bytes calldata signature) external payable;
```

| Parameter | Description |
| --- | --- |
| req | The payload / mint request. |
| signature | The signature produced by an account signing the mint request. |

The contract implementing the 'signature minting' mechanism first recovers the address of the signer from the given payload i.e. `req` and the `signature`, and verifies that an authorized address has signed off this incoming mint request.

Once verified, tokens are minted according to the information specified in the payload.

## Authors
- [nkrishang](https://github.com/nkrishang)
- [thirdweb team](https://github.com/thirdweb-dev)
