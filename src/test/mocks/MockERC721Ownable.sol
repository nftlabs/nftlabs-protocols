// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC721/extensions/ERC721Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract MockERC721Ownable is ERC721Burnable, Ownable {
    uint256 public nextTokenIdToMint;

    constructor() ERC721("MockERC721Ownable", "MOCK") {}

    function mint(address _receiver, uint256 _amount) external {
        uint256 tokenId = nextTokenIdToMint;
        nextTokenIdToMint += _amount;

        for (uint256 i = 0; i < _amount; i += 1) {
            _mint(_receiver, tokenId);
            tokenId += 1;
        }
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return super.supportsInterface(interfaceId);
    }
}
