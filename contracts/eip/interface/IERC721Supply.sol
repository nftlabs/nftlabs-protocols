// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

/// @title ERC-721 Non-Fungible Token Standard, optional supply extension
/// @dev See https://eips.ethereum.org/EIPS/eip-721
///  Note: the ERC-165 identifier for this interface is 0x780e9d63.
/* is ERC721 */
interface IERC721Supply {
    /// @notice Count NFTs tracked by this contract
    /// @return A count of valid NFTs tracked by this contract, where each one of
    ///  them has an assigned and queryable owner not equal to the zero address
    function totalSupply() external view returns (uint256);
}
