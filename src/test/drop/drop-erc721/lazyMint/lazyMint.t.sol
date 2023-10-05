// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { DropERC721, IDelayedReveal, ERC721AUpgradeable, IPermissions, ILazyMint } from "contracts/prebuilts/drop/DropERC721.sol";

// Test imports
import "erc721a-upgradeable/contracts/IERC721AUpgradeable.sol";
import "contracts/lib/TWStrings.sol";
import "../../../utils/BaseTest.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "@openzeppelin/contracts/utils/Strings.sol";

contract DropERC721Test_lazyMint is BaseTest {
    using StringsUpgradeable for uint256;
    using StringsUpgradeable for address;

    event TokensLazyMinted(uint256 indexed startTokenId, uint256 endTokenId, string baseURI, bytes encryptedBaseURI);
    event TokenURIRevealed(uint256 indexed index, string revealedURI);
    event MaxTotalSupplyUpdated(uint256 maxTotalSupply);

    DropERC721 public drop;

    bytes private lazymint_data;
    string private lazyMint_baseURI;
    uint256 private lazyMint_amount;
    bytes private lazyMint_encryptedURI;
    bytes32 private lazyMint_provenanceHash;
    string private lazyMint_revealedURI = "test";

    using stdStorage for StdStorage;

    function setUp() public override {
        super.setUp();
        drop = DropERC721(getContract("DropERC721"));

        erc20.mint(deployer, 1_000 ether);
        vm.deal(deployer, 1_000 ether);
    }

    /*///////////////////////////////////////////////////////////////
                        Branch Testing
    //////////////////////////////////////////////////////////////*/

    modifier callerWithoutMinterRole() {
        vm.startPrank(address(0x123));
        _;
    }

    modifier callerWithMinterRole() {
        vm.startPrank(deployer);
        _;
    }

    modifier callerWithoutMetadataRole() {
        vm.startPrank(address(0x123));
        _;
    }

    modifier callerWithMetadataRole() {
        vm.prank(deployer);
        _;
    }

    modifier amountEqualZero() {
        lazyMint_amount = 0;
        _;
    }

    modifier amountNotEqualZero() {
        lazyMint_amount = 1;
        _;
    }

    modifier dataLengthZero() {
        lazymint_data = abi.encode("");
        _;
    }

    modifier dataInvalidFormat() {
        lazyMint_provenanceHash = bytes32("provenanceHash");
        lazymint_data = abi.encode(lazyMint_provenanceHash);
        console.log(lazymint_data.length);
        _;
    }

    modifier dataValidFormat() {
        lazyMint_provenanceHash = bytes32("provenanceHash");
        lazyMint_encryptedURI = "encryptedURI";
        lazymint_data = abi.encode(lazyMint_encryptedURI, lazyMint_provenanceHash);
        console.log(lazymint_data.length);
        _;
    }

    modifier dataValidFormatNoURI() {
        lazyMint_provenanceHash = bytes32("provenanceHash");
        lazyMint_encryptedURI = "";
        lazymint_data = abi.encode(lazyMint_encryptedURI, lazyMint_provenanceHash);
        console.log(lazymint_data.length);
        _;
    }

    modifier dataValidFormatNoHash() {
        lazyMint_provenanceHash = bytes32("");
        lazyMint_encryptedURI = "encryptedURI";
        lazymint_data = abi.encode(lazyMint_encryptedURI, lazyMint_provenanceHash);
        console.log(lazymint_data.length);
        _;
    }



    function test_revert_NoMinterRole() public callerWithoutMinterRole dataLengthZero {
        vm.expectRevert("Not authorized");
        drop.lazyMint(lazyMint_amount, lazyMint_revealedURI, lazymint_data);
    }

    function test_revert_AmountEqualZero() public callerWithMinterRole dataLengthZero amountEqualZero {
        vm.expectRevert("0 amt");
        drop.lazyMint(lazyMint_amount, lazyMint_revealedURI, lazymint_data);
    }

    function test_revert_DataInvalidFormat() public callerWithMinterRole amountNotEqualZero dataInvalidFormat  {
        vm.expectRevert();
        drop.lazyMint(lazyMint_amount, lazyMint_revealedURI, lazymint_data);
    }

    function test_state_dataLengthZero() public callerWithMinterRole amountNotEqualZero dataLengthZero {
        uint256 nextTokenIdToLazyMintBefore = drop.nextTokenIdToMint();
        uint256 expectedBatchId = nextTokenIdToLazyMintBefore + lazyMint_amount;

        uint256 batchIdReturn = drop.lazyMint(lazyMint_amount, lazyMint_revealedURI, lazymint_data);

        uint256 batchIdState = drop.getBatchIdAtIndex(0);
        string memory baseURIState = drop.tokenURI(0);

        assertEq(nextTokenIdToLazyMintBefore + lazyMint_amount, drop.nextTokenIdToMint());
        assertEq(expectedBatchId, batchIdReturn);
        assertEq(expectedBatchId, batchIdState);
        assertEq(string(abi.encodePacked(lazyMint_revealedURI, "0")), baseURIState);
    }

    function test_event_dataLengthZero() public callerWithMinterRole amountNotEqualZero dataLengthZero {
        uint256 nextTokenIdToLazyMintBefore = drop.nextTokenIdToMint();

        vm.expectEmit(true, false, false, true);
        emit TokensLazyMinted(nextTokenIdToLazyMintBefore, nextTokenIdToLazyMintBefore + lazyMint_amount - 1, lazyMint_revealedURI, lazymint_data);
        drop.lazyMint(lazyMint_amount, lazyMint_revealedURI, lazymint_data);
    }

    function test_state_noEncryptedURI() public callerWithMinterRole amountNotEqualZero dataValidFormatNoURI {
        uint256 nextTokenIdToLazyMintBefore = drop.nextTokenIdToMint();
        uint256 expectedBatchId = nextTokenIdToLazyMintBefore + lazyMint_amount;
        bytes memory expectedEncryptedData;

        uint256 batchIdReturn = drop.lazyMint(lazyMint_amount, lazyMint_revealedURI, lazymint_data);

        uint256 batchIdState = drop.getBatchIdAtIndex(0);
        string memory baseURIState = drop.tokenURI(0);
        bytes memory encryptedDataState = drop.encryptedData(0);

        assertEq(nextTokenIdToLazyMintBefore + lazyMint_amount, drop.nextTokenIdToMint());
        assertEq(expectedBatchId, batchIdReturn);
        assertEq(expectedBatchId, batchIdState);
        assertEq(string(abi.encodePacked(lazyMint_revealedURI, "0")), baseURIState);
        assertEq(expectedEncryptedData, encryptedDataState);
    }

    function test_event_noEncryptedURI() public callerWithMinterRole amountNotEqualZero dataValidFormatNoURI {
        uint256 nextTokenIdToLazyMintBefore = drop.nextTokenIdToMint();

        vm.expectEmit(true, false, false, true);
        emit TokensLazyMinted(nextTokenIdToLazyMintBefore, nextTokenIdToLazyMintBefore + lazyMint_amount - 1, lazyMint_revealedURI, lazymint_data);
        drop.lazyMint(lazyMint_amount, lazyMint_revealedURI, lazymint_data);
    }

    function test_state_noProvenanceHash() public callerWithMinterRole amountNotEqualZero dataValidFormatNoHash {
        uint256 nextTokenIdToLazyMintBefore = drop.nextTokenIdToMint();
        uint256 expectedBatchId = nextTokenIdToLazyMintBefore + lazyMint_amount;
        bytes memory expectedEncryptedData;

        uint256 batchIdReturn = drop.lazyMint(lazyMint_amount, lazyMint_revealedURI, lazymint_data);

        uint256 batchIdState = drop.getBatchIdAtIndex(0);
        string memory baseURIState = drop.tokenURI(0);
        bytes memory encryptedDataState = drop.encryptedData(0);

        assertEq(nextTokenIdToLazyMintBefore + lazyMint_amount, drop.nextTokenIdToMint());
        assertEq(expectedBatchId, batchIdReturn);
        assertEq(expectedBatchId, batchIdState);
        assertEq(string(abi.encodePacked(lazyMint_revealedURI, "0")), baseURIState);
        assertEq(expectedEncryptedData, encryptedDataState);
    }

    function test_event_noProvenanceHash() public callerWithMinterRole amountNotEqualZero dataValidFormatNoHash {
        uint256 nextTokenIdToLazyMintBefore = drop.nextTokenIdToMint();

        vm.expectEmit(true, false, false, true);
        emit TokensLazyMinted(nextTokenIdToLazyMintBefore, nextTokenIdToLazyMintBefore + lazyMint_amount - 1, lazyMint_revealedURI, lazymint_data);
        drop.lazyMint(lazyMint_amount, lazyMint_revealedURI, lazymint_data);
    }

    function test_state_encryptedURIAndHash() public callerWithMinterRole amountNotEqualZero dataValidFormat {
        uint256 nextTokenIdToLazyMintBefore = drop.nextTokenIdToMint();
        uint256 expectedBatchId = nextTokenIdToLazyMintBefore + lazyMint_amount;

        uint256 batchIdReturn = drop.lazyMint(lazyMint_amount, lazyMint_revealedURI, lazymint_data);

        uint256 batchIdState = drop.getBatchIdAtIndex(0);
        string memory baseURIState = drop.tokenURI(0);
        bytes memory encryptedDataState = drop.encryptedData(batchIdReturn);

        assertEq(nextTokenIdToLazyMintBefore + lazyMint_amount, drop.nextTokenIdToMint());
        assertEq(expectedBatchId, batchIdReturn);
        assertEq(expectedBatchId, batchIdState);
        assertEq(string(abi.encodePacked(lazyMint_revealedURI, "0")), baseURIState);
        assertEq(lazymint_data, encryptedDataState);
    }

    function test_event_encryptedURIAndHash() public callerWithMinterRole amountNotEqualZero dataValidFormat {
        uint256 nextTokenIdToLazyMintBefore = drop.nextTokenIdToMint();

        vm.expectEmit(true, false, false, true);
        emit TokensLazyMinted(nextTokenIdToLazyMintBefore, nextTokenIdToLazyMintBefore + lazyMint_amount - 1, lazyMint_revealedURI, lazymint_data);
        drop.lazyMint(lazyMint_amount, lazyMint_revealedURI, lazymint_data);
    }

}