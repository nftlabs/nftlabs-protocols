// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

/**
 *  Thirdweb's `Airdrop` contracts provide a lightweight and easy to use mechanism
 *  to drop tokens.
 *
 *  `AirdropERC1155` contract is an airdrop contract for ERC1155 tokens. It follows a
 *  push mechanism for transfer of tokens to intended recipients.
 */

interface IAirdropERC1155 {
    /// @notice Emitted when an airdrop is made using the stateless airdrop function.
    event StatelessAirdrop(address indexed recipient, AirdropContent content, bool failed);

    /**
     *  @notice Details of amount and recipient for airdropped token.
     *
     *  @param tokenAddress The contract address of the tokens to transfer.
     *  @param tokenOwner The owner of the the tokens to transfer.
     *  @param recipient The recipient of the tokens.
     *  @param tokenId ID of the ERC1155 token being airdropped.
     *  @param amount The quantity of tokens to airdrop.
     */
    struct AirdropContent {
        address tokenAddress;
        address tokenOwner;
        address recipient;
        uint256 tokenId;
        uint256 amount;
    }

    /**
     *  @notice          Lets contract-owner send ERC1155 tokens to a list of addresses.
     *  @dev             The token-owner should approve target tokens to Airdrop contract,
     *                   which acts as operator for the tokens.
     *
     *  @param _contents        List containing recipient, tokenId to airdrop.
     */
    function airdrop(AirdropContent[] calldata _contents) external;
}
