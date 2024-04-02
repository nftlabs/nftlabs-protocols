// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { Airdrop, ECDSA } from "contracts/prebuilts/unaudited/airdrop/Airdrop.sol";

// Test imports
import { TWProxy } from "contracts/infra/TWProxy.sol";
import "../utils/BaseTest.sol";

contract MockSmartWallet {
    using ECDSA for bytes32;

    bytes4 private constant EIP1271_MAGIC_VALUE = 0x1626ba7e;
    address private admin;

    constructor(address _admin) {
        admin = _admin;
    }

    function isValidSignature(bytes32 _hash, bytes memory _signature) public view returns (bytes4) {
        if (_hash.recover(_signature) == admin) {
            return EIP1271_MAGIC_VALUE;
        }
    }

    function onERC721Received(address, address, uint256, bytes memory) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }

    function onERC1155Received(address, address, uint256, uint256, bytes memory) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address,
        address,
        uint256[] memory,
        uint256[] memory,
        bytes memory
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}

contract AirdropTest is BaseTest {
    Airdrop internal airdrop;
    MockSmartWallet internal mockSmartWallet;

    bytes32 private constant CONTENT_TYPEHASH_ERC20 =
        keccak256("AirdropContentERC20(address recipient,uint256 amount)");
    bytes32 private constant REQUEST_TYPEHASH_ERC20 =
        keccak256(
            "AirdropRequestERC20(bytes32 uid,address tokenAddress,uint256 expirationTimestamp,AirdropContentERC20[] contents)AirdropContentERC20(address recipient,uint256 amount)"
        );

    bytes32 private constant CONTENT_TYPEHASH_ERC721 =
        keccak256("AirdropContentERC721(address recipient,uint256 tokenId)");
    bytes32 private constant REQUEST_TYPEHASH_ERC721 =
        keccak256(
            "AirdropRequestERC721(bytes32 uid,address tokenAddress,uint256 expirationTimestamp,AirdropContentERC721[] contents)AirdropContentERC721(address recipient,uint256 tokenId)"
        );

    bytes32 private constant CONTENT_TYPEHASH_ERC1155 =
        keccak256("AirdropContentERC1155(address recipient,uint256 tokenId,uint256 amount)");
    bytes32 private constant REQUEST_TYPEHASH_ERC1155 =
        keccak256(
            "AirdropRequestERC1155(bytes32 uid,address tokenAddress,uint256 expirationTimestamp,AirdropContentERC1155[] contents)AirdropContentERC1155(address recipient,uint256 tokenId,uint256 amount)"
        );

    bytes32 private constant NAME_HASH = keccak256(bytes("Airdrop"));
    bytes32 private constant VERSION_HASH = keccak256(bytes("1"));
    bytes32 private constant TYPE_HASH_EIP712 =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    bytes32 internal domainSeparator;

    function setUp() public override {
        super.setUp();

        address impl = address(new Airdrop());

        airdrop = Airdrop(payable(address(new TWProxy(impl, abi.encodeCall(Airdrop.initialize, (signer))))));

        domainSeparator = keccak256(
            abi.encode(TYPE_HASH_EIP712, NAME_HASH, VERSION_HASH, block.chainid, address(airdrop))
        );

        mockSmartWallet = new MockSmartWallet(signer);
    }

    function _getContentsERC20(uint256 length) internal pure returns (Airdrop.AirdropContentERC20[] memory contents) {
        contents = new Airdrop.AirdropContentERC20[](length);
        for (uint256 i = 0; i < length; i++) {
            contents[i].recipient = address(uint160(i + 10));
            contents[i].amount = i + 10;
        }
    }

    function _getContentsERC721(uint256 length) internal pure returns (Airdrop.AirdropContentERC721[] memory contents) {
        contents = new Airdrop.AirdropContentERC721[](length);
        for (uint256 i = 0; i < length; i++) {
            contents[i].recipient = address(uint160(i + 10));
            contents[i].tokenId = i;
        }
    }

    function _getContentsERC1155(
        uint256 length
    ) internal pure returns (Airdrop.AirdropContentERC1155[] memory contents) {
        contents = new Airdrop.AirdropContentERC1155[](length);
        for (uint256 i = 0; i < length; i++) {
            contents[i].recipient = address(uint160(i + 10));
            contents[i].tokenId = 0;
            contents[i].amount = i + 10;
        }
    }

    function _signReqERC20(
        Airdrop.AirdropRequestERC20 memory req,
        uint256 privateKey
    ) internal view returns (bytes memory signature) {
        bytes32[] memory contentHashes = new bytes32[](req.contents.length);
        for (uint i = 0; i < req.contents.length; i++) {
            contentHashes[i] = keccak256(
                abi.encode(CONTENT_TYPEHASH_ERC20, req.contents[i].recipient, req.contents[i].amount)
            );
        }
        bytes32 contentHash = keccak256(abi.encodePacked(contentHashes));

        bytes memory dataToHash;
        {
            dataToHash = abi.encode(
                REQUEST_TYPEHASH_ERC20,
                req.uid,
                req.tokenAddress,
                req.expirationTimestamp,
                contentHash
            );
        }

        {
            bytes32 _structHash = keccak256(dataToHash);
            bytes32 typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, _structHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, typedDataHash);

            signature = abi.encodePacked(r, s, v);
        }
    }

    function _signReqERC721(
        Airdrop.AirdropRequestERC721 memory req,
        uint256 privateKey
    ) internal view returns (bytes memory signature) {
        bytes32[] memory contentHashes = new bytes32[](req.contents.length);
        for (uint i = 0; i < req.contents.length; i++) {
            contentHashes[i] = keccak256(
                abi.encode(CONTENT_TYPEHASH_ERC721, req.contents[i].recipient, req.contents[i].tokenId)
            );
        }
        bytes32 contentHash = keccak256(abi.encodePacked(contentHashes));

        bytes memory dataToHash;
        {
            dataToHash = abi.encode(
                REQUEST_TYPEHASH_ERC721,
                req.uid,
                req.tokenAddress,
                req.expirationTimestamp,
                contentHash
            );
        }

        {
            bytes32 _structHash = keccak256(dataToHash);
            bytes32 typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, _structHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, typedDataHash);

            signature = abi.encodePacked(r, s, v);
        }
    }

    function _signReqERC1155(
        Airdrop.AirdropRequestERC1155 memory req,
        uint256 privateKey
    ) internal view returns (bytes memory signature) {
        bytes32[] memory contentHashes = new bytes32[](req.contents.length);
        for (uint i = 0; i < req.contents.length; i++) {
            contentHashes[i] = keccak256(
                abi.encode(
                    CONTENT_TYPEHASH_ERC1155,
                    req.contents[i].recipient,
                    req.contents[i].tokenId,
                    req.contents[i].amount
                )
            );
        }
        bytes32 contentHash = keccak256(abi.encodePacked(contentHashes));

        bytes memory dataToHash;
        {
            dataToHash = abi.encode(
                REQUEST_TYPEHASH_ERC1155,
                req.uid,
                req.tokenAddress,
                req.expirationTimestamp,
                contentHash
            );
        }

        {
            bytes32 _structHash = keccak256(dataToHash);
            bytes32 typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, _structHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, typedDataHash);

            signature = abi.encodePacked(r, s, v);
        }
    }

    /*///////////////////////////////////////////////////////////////
                       Benchmark: Airdrop Push ERC20 
    //////////////////////////////////////////////////////////////*/

    function test_state_airdropPush_erc20() public {
        erc20.mint(signer, 100 ether);
        vm.prank(signer);
        erc20.approve(address(airdrop), 100 ether);

        Airdrop.AirdropContentERC20[] memory contents = _getContentsERC20(10);

        vm.prank(signer);

        airdrop.airdropERC20(address(erc20), contents);

        uint256 totalAmount;
        for (uint256 i = 0; i < contents.length; i++) {
            totalAmount += contents[i].amount;
            assertEq(erc20.balanceOf(contents[i].recipient), contents[i].amount);
        }
        assertEq(erc20.balanceOf(signer), 100 ether - totalAmount);
    }

    function test_state_airdropPush_nativeToken() public {
        vm.deal(signer, 100 ether);

        Airdrop.AirdropContentERC20[] memory contents = _getContentsERC20(10);

        uint256 totalAmount;
        for (uint256 i = 0; i < contents.length; i++) {
            totalAmount += contents[i].amount;
            assertEq(contents[i].recipient.balance, 0);
        }

        vm.prank(signer);
        airdrop.airdropNativeToken{ value: totalAmount }(contents);

        for (uint256 i = 0; i < contents.length; i++) {
            assertEq(contents[i].recipient.balance, contents[i].amount);
        }

        assertEq(signer.balance, 100 ether - totalAmount);
    }

    function test_revert_airdropPush_nativeToken() public {
        vm.deal(signer, 100 ether);

        Airdrop.AirdropContentERC20[] memory contents = _getContentsERC20(10);

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropFailed.selector));
        airdrop.airdropNativeToken{ value: 0 }(contents);

        // add some balance to airdrop contract, which it will try sending to recipeints when msg.value zero
        vm.deal(address(airdrop), 50 ether);
        // should revert
        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropValueMismatch.selector));
        airdrop.airdropNativeToken{ value: 0 }(contents);

        // contract balance should remain untouched
        assertEq(address(airdrop).balance, 50 ether);
    }

    /*///////////////////////////////////////////////////////////////
                    Benchmark: Airdrop Signature ERC20 
    //////////////////////////////////////////////////////////////*/

    function test_state_airdropSignature_erc20() public {
        erc20.mint(signer, 100 ether);
        vm.prank(signer);
        erc20.approve(address(airdrop), 100 ether);

        Airdrop.AirdropContentERC20[] memory contents = _getContentsERC20(10);
        Airdrop.AirdropRequestERC20 memory req = Airdrop.AirdropRequestERC20({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc20),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC20(req, privateKey);

        vm.prank(signer);

        airdrop.airdropERC20WithSignature(req, signature);

        uint256 totalAmount;
        for (uint256 i = 0; i < contents.length; i++) {
            totalAmount += contents[i].amount;
            assertEq(erc20.balanceOf(contents[i].recipient), contents[i].amount);
        }
        assertEq(erc20.balanceOf(signer), 100 ether - totalAmount);
    }

    function test_state_airdropSignature_erc20_eip1271() public {
        // set mockSmartWallet as contract owner
        vm.prank(signer);
        airdrop.setOwner(address(mockSmartWallet));

        // mint tokens to mockSmartWallet
        erc20.mint(address(mockSmartWallet), 100 ether);
        vm.prank(address(mockSmartWallet));
        erc20.approve(address(airdrop), 100 ether);

        Airdrop.AirdropContentERC20[] memory contents = _getContentsERC20(10);
        Airdrop.AirdropRequestERC20 memory req = Airdrop.AirdropRequestERC20({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc20),
            expirationTimestamp: 1000,
            contents: contents
        });

        // sign with original EOA signer private key
        bytes memory signature = _signReqERC20(req, privateKey);

        airdrop.airdropERC20WithSignature(req, signature);

        uint256 totalAmount;
        for (uint256 i = 0; i < contents.length; i++) {
            totalAmount += contents[i].amount;
            assertEq(erc20.balanceOf(contents[i].recipient), contents[i].amount);
        }
        assertEq(erc20.balanceOf(address(mockSmartWallet)), 100 ether - totalAmount);
    }

    function test_revert_airdropSignature_erc20_eip1271_invalidSignature() public {
        // set mockSmartWallet as contract owner
        vm.prank(signer);
        airdrop.setOwner(address(mockSmartWallet));

        // mint tokens to mockSmartWallet
        erc20.mint(address(mockSmartWallet), 100 ether);
        vm.prank(address(mockSmartWallet));
        erc20.approve(address(airdrop), 100 ether);

        Airdrop.AirdropContentERC20[] memory contents = _getContentsERC20(10);
        Airdrop.AirdropRequestERC20 memory req = Airdrop.AirdropRequestERC20({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc20),
            expirationTimestamp: 1000,
            contents: contents
        });

        // sign with random private key
        bytes memory signature = _signReqERC20(req, 123);

        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestInvalidSigner.selector));
        airdrop.airdropERC20WithSignature(req, signature);
    }

    function test_revert_airdropSignature_erc20_expired() public {
        erc20.mint(signer, 100 ether);
        vm.prank(signer);
        erc20.approve(address(airdrop), 100 ether);

        Airdrop.AirdropContentERC20[] memory contents = _getContentsERC20(10);
        Airdrop.AirdropRequestERC20 memory req = Airdrop.AirdropRequestERC20({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc20),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC20(req, privateKey);

        vm.warp(1001);

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestExpired.selector, req.expirationTimestamp));
        airdrop.airdropERC20WithSignature(req, signature);
    }

    function test_revert_airdropSignature_erc20_alreadyProcessed() public {
        erc20.mint(signer, 100 ether);
        vm.prank(signer);
        erc20.approve(address(airdrop), 100 ether);

        Airdrop.AirdropContentERC20[] memory contents = _getContentsERC20(10);
        Airdrop.AirdropRequestERC20 memory req = Airdrop.AirdropRequestERC20({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc20),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC20(req, privateKey);

        vm.prank(signer);

        airdrop.airdropERC20WithSignature(req, signature);

        // try re-sending same request/signature
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestAlreadyProcessed.selector));
        airdrop.airdropERC20WithSignature(req, signature);
    }

    function test_revert_airdropSignature_erc20_invalidSigner() public {
        erc20.mint(signer, 100 ether);
        vm.prank(signer);
        erc20.approve(address(airdrop), 100 ether);

        Airdrop.AirdropContentERC20[] memory contents = _getContentsERC20(10);
        Airdrop.AirdropRequestERC20 memory req = Airdrop.AirdropRequestERC20({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc20),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC20(req, 123);

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestInvalidSigner.selector));
        airdrop.airdropERC20WithSignature(req, signature);
    }

    /*///////////////////////////////////////////////////////////////
                       Benchmark: Airdrop Claim ERC20 
    //////////////////////////////////////////////////////////////*/

    function test_state_airdropClaim_erc20() public {
        erc20.mint(signer, 100 ether);
        vm.prank(signer);
        erc20.approve(address(airdrop), 100 ether);

        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "src/test/scripts/generateRootAirdrop.ts";
        inputs[2] = Strings.toString(uint256(5));
        bytes memory result = vm.ffi(inputs);
        bytes32 root = abi.decode(result, (bytes32));

        // set merkle root
        vm.prank(signer);
        airdrop.setMerkleRoot(address(erc20), root, true);

        // generate proof
        inputs[1] = "src/test/scripts/getProofAirdrop.ts";
        result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));

        address receiver = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);
        uint256 quantity = 5;

        airdrop.claimERC20(address(erc20), receiver, quantity, proofs);

        assertEq(erc20.balanceOf(receiver), quantity);
        assertEq(erc20.balanceOf(signer), 100 ether - quantity);
    }

    function test_revert_airdropClaim_erc20_alreadyClaimed() public {
        erc20.mint(signer, 100 ether);
        vm.prank(signer);
        erc20.approve(address(airdrop), 100 ether);

        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "src/test/scripts/generateRootAirdrop.ts";
        inputs[2] = Strings.toString(uint256(5));
        bytes memory result = vm.ffi(inputs);
        bytes32 root = abi.decode(result, (bytes32));

        // set merkle root
        vm.prank(signer);
        airdrop.setMerkleRoot(address(erc20), root, true);

        // generate proof
        inputs[1] = "src/test/scripts/getProofAirdrop.ts";
        result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));

        address receiver = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);
        uint256 quantity = 5;

        airdrop.claimERC20(address(erc20), receiver, quantity, proofs);

        // revert when claiming again
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropAlreadyClaimed.selector));
        airdrop.claimERC20(address(erc20), receiver, quantity, proofs);
    }

    function test_revert_airdropClaim_erc20_noMerkleRoot() public {
        erc20.mint(signer, 100 ether);
        vm.prank(signer);
        erc20.approve(address(airdrop), 100 ether);

        bytes32[] memory proofs;

        address receiver = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);
        uint256 quantity = 5;

        // revert when claiming again
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropNoMerkleRoot.selector));
        airdrop.claimERC20(address(erc20), receiver, quantity, proofs);
    }

    function test_revert_airdropClaim_erc20_invalidProof() public {
        erc20.mint(signer, 100 ether);
        vm.prank(signer);
        erc20.approve(address(airdrop), 100 ether);

        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "src/test/scripts/generateRootAirdrop.ts";
        inputs[2] = Strings.toString(uint256(5));
        bytes memory result = vm.ffi(inputs);
        bytes32 root = abi.decode(result, (bytes32));

        // set merkle root
        vm.prank(signer);
        airdrop.setMerkleRoot(address(erc20), root, true);

        // generate proof
        inputs[1] = "src/test/scripts/getProofAirdrop.ts";
        result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));

        address receiver = address(0x12345);
        uint256 quantity = 5;

        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropInvalidProof.selector));
        airdrop.claimERC20(address(erc20), receiver, quantity, proofs);
    }

    /*///////////////////////////////////////////////////////////////
                       Benchmark: Airdrop Push ERC721 
    //////////////////////////////////////////////////////////////*/

    function test_state_airdropPush_erc721() public {
        erc721.mint(signer, 100);
        vm.prank(signer);
        erc721.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC721[] memory contents = _getContentsERC721(10);

        vm.prank(signer);

        airdrop.airdropERC721(address(erc721), contents);

        for (uint256 i = 0; i < contents.length; i++) {
            assertEq(erc721.ownerOf(contents[i].tokenId), contents[i].recipient);
        }
    }

    /*///////////////////////////////////////////////////////////////
                    Benchmark: Airdrop Signature ERC721 
    //////////////////////////////////////////////////////////////*/

    function test_state_airdropSignature_erc721() public {
        erc721.mint(signer, 1000);
        vm.prank(signer);
        erc721.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC721[] memory contents = _getContentsERC721(10);
        Airdrop.AirdropRequestERC721 memory req = Airdrop.AirdropRequestERC721({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc721),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC721(req, privateKey);

        vm.prank(signer);

        airdrop.airdropERC721WithSignature(req, signature);

        for (uint256 i = 0; i < contents.length; i++) {
            assertEq(erc721.ownerOf(contents[i].tokenId), contents[i].recipient);
        }
    }

    function test_state_airdropSignature_erc721_eip1271() public {
        // set mockSmartWallet as contract owner
        vm.prank(signer);
        airdrop.setOwner(address(mockSmartWallet));

        // mint tokens to mockSmartWallet
        erc721.mint(address(mockSmartWallet), 1000);
        vm.prank(address(mockSmartWallet));
        erc721.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC721[] memory contents = _getContentsERC721(10);
        Airdrop.AirdropRequestERC721 memory req = Airdrop.AirdropRequestERC721({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc721),
            expirationTimestamp: 1000,
            contents: contents
        });

        // sign with original EOA signer private key
        bytes memory signature = _signReqERC721(req, privateKey);

        airdrop.airdropERC721WithSignature(req, signature);

        for (uint256 i = 0; i < contents.length; i++) {
            assertEq(erc721.ownerOf(contents[i].tokenId), contents[i].recipient);
        }
    }

    function test_revert_airdropSignature_erc721_eip1271_invalidSignature() public {
        // set mockSmartWallet as contract owner
        vm.prank(signer);
        airdrop.setOwner(address(mockSmartWallet));

        // mint tokens to mockSmartWallet
        erc721.mint(address(mockSmartWallet), 1000);
        vm.prank(address(mockSmartWallet));
        erc721.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC721[] memory contents = _getContentsERC721(10);
        Airdrop.AirdropRequestERC721 memory req = Airdrop.AirdropRequestERC721({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc721),
            expirationTimestamp: 1000,
            contents: contents
        });

        // sign with random private key
        bytes memory signature = _signReqERC721(req, 123);

        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestInvalidSigner.selector));
        airdrop.airdropERC721WithSignature(req, signature);
    }

    function test_revert_airdropSignature_erc721_expired() public {
        erc721.mint(signer, 1000);
        vm.prank(signer);
        erc721.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC721[] memory contents = _getContentsERC721(10);
        Airdrop.AirdropRequestERC721 memory req = Airdrop.AirdropRequestERC721({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc721),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC721(req, privateKey);

        vm.warp(1001);

        vm.prank(signer);
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestExpired.selector, req.expirationTimestamp));
        airdrop.airdropERC721WithSignature(req, signature);
    }

    function test_revert_airdropSignature_erc721_alreadyProcessed() public {
        erc721.mint(signer, 1000);
        vm.prank(signer);
        erc721.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC721[] memory contents = _getContentsERC721(10);
        Airdrop.AirdropRequestERC721 memory req = Airdrop.AirdropRequestERC721({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc721),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC721(req, privateKey);

        vm.prank(signer);
        airdrop.airdropERC721WithSignature(req, signature);

        // send it again
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestAlreadyProcessed.selector));
        airdrop.airdropERC721WithSignature(req, signature);
    }

    function test_revert_airdropSignature_erc721_invalidSigner() public {
        erc721.mint(signer, 1000);
        vm.prank(signer);
        erc721.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC721[] memory contents = _getContentsERC721(10);
        Airdrop.AirdropRequestERC721 memory req = Airdrop.AirdropRequestERC721({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc721),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC721(req, 123);

        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestInvalidSigner.selector));
        airdrop.airdropERC721WithSignature(req, signature);
    }

    /*///////////////////////////////////////////////////////////////
                       Benchmark: Airdrop Claim ERC721 
    //////////////////////////////////////////////////////////////*/

    function test_state_airdropClaim_erc721() public {
        erc721.mint(signer, 100);
        vm.prank(signer);
        erc721.setApprovalForAll(address(airdrop), true);

        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "src/test/scripts/generateRootAirdrop.ts";
        inputs[2] = Strings.toString(uint256(5));
        bytes memory result = vm.ffi(inputs);
        bytes32 root = abi.decode(result, (bytes32));

        // set merkle root
        vm.prank(signer);
        airdrop.setMerkleRoot(address(erc721), root, true);

        // generate proof
        inputs[1] = "src/test/scripts/getProofAirdrop.ts";
        result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));

        address receiver = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);
        uint256 tokenId = 5;

        airdrop.claimERC721(address(erc721), receiver, tokenId, proofs);

        assertEq(erc721.ownerOf(tokenId), receiver);
    }

    function test_revert_airdropClaim_erc721_alreadyClaimed() public {
        erc721.mint(signer, 100);
        vm.prank(signer);
        erc721.setApprovalForAll(address(airdrop), true);

        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "src/test/scripts/generateRootAirdrop.ts";
        inputs[2] = Strings.toString(uint256(5));
        bytes memory result = vm.ffi(inputs);
        bytes32 root = abi.decode(result, (bytes32));

        // set merkle root
        vm.prank(signer);
        airdrop.setMerkleRoot(address(erc721), root, true);

        // generate proof
        inputs[1] = "src/test/scripts/getProofAirdrop.ts";
        result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));

        address receiver = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);
        uint256 tokenId = 5;

        airdrop.claimERC721(address(erc721), receiver, tokenId, proofs);

        // revert when claiming again
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropAlreadyClaimed.selector));
        airdrop.claimERC721(address(erc721), receiver, tokenId, proofs);
    }

    function test_revert_airdropClaim_erc721_noMerkleRoot() public {
        erc721.mint(signer, 100);
        vm.prank(signer);
        erc721.setApprovalForAll(address(airdrop), true);

        bytes32[] memory proofs;

        address receiver = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);
        uint256 tokenId = 5;

        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropNoMerkleRoot.selector));
        airdrop.claimERC721(address(erc721), receiver, tokenId, proofs);
    }

    function test_revert_airdropClaim_erc721_invalidProof() public {
        erc721.mint(signer, 100);
        vm.prank(signer);
        erc721.setApprovalForAll(address(airdrop), true);

        string[] memory inputs = new string[](3);
        inputs[0] = "node";
        inputs[1] = "src/test/scripts/generateRootAirdrop.ts";
        inputs[2] = Strings.toString(uint256(5));
        bytes memory result = vm.ffi(inputs);
        bytes32 root = abi.decode(result, (bytes32));

        // set merkle root
        vm.prank(signer);
        airdrop.setMerkleRoot(address(erc721), root, true);

        // generate proof
        inputs[1] = "src/test/scripts/getProofAirdrop.ts";
        result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));

        address receiver = address(0x12345);
        uint256 tokenId = 5;

        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropInvalidProof.selector));
        airdrop.claimERC721(address(erc721), receiver, tokenId, proofs);
    }

    /*///////////////////////////////////////////////////////////////
                       Benchmark: Airdrop Push ERC1155 
    //////////////////////////////////////////////////////////////*/

    function test_state_airdropPush_erc1155() public {
        erc1155.mint(signer, 0, 100 ether);
        vm.prank(signer);
        erc1155.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC1155[] memory contents = _getContentsERC1155(10);

        vm.prank(signer);

        airdrop.airdropERC1155(address(erc1155), contents);

        for (uint256 i = 0; i < contents.length; i++) {
            assertEq(erc1155.balanceOf(contents[i].recipient, contents[i].tokenId), contents[i].amount);
        }
    }

    /*///////////////////////////////////////////////////////////////
                    Benchmark: Airdrop Signature ERC1155 
    //////////////////////////////////////////////////////////////*/

    function test_state_airdropSignature_erc115() public {
        erc1155.mint(signer, 0, 100 ether);
        vm.prank(signer);
        erc1155.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC1155[] memory contents = _getContentsERC1155(10);
        Airdrop.AirdropRequestERC1155 memory req = Airdrop.AirdropRequestERC1155({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc1155),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC1155(req, privateKey);

        vm.prank(signer);

        airdrop.airdropERC1155WithSignature(req, signature);

        for (uint256 i = 0; i < contents.length; i++) {
            assertEq(erc1155.balanceOf(contents[i].recipient, contents[i].tokenId), contents[i].amount);
        }
    }

    function test_state_airdropSignature_erc1155_eip1271() public {
        // set mockSmartWallet as contract owner
        vm.prank(signer);
        airdrop.setOwner(address(mockSmartWallet));

        // mint tokens to mockSmartWallet
        erc1155.mint(address(mockSmartWallet), 0, 100 ether);
        vm.prank(address(mockSmartWallet));
        erc1155.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC1155[] memory contents = _getContentsERC1155(10);
        Airdrop.AirdropRequestERC1155 memory req = Airdrop.AirdropRequestERC1155({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc1155),
            expirationTimestamp: 1000,
            contents: contents
        });

        // sign with original EOA signer private key
        bytes memory signature = _signReqERC1155(req, privateKey);

        airdrop.airdropERC1155WithSignature(req, signature);

        for (uint256 i = 0; i < contents.length; i++) {
            assertEq(erc1155.balanceOf(contents[i].recipient, contents[i].tokenId), contents[i].amount);
        }
    }

    function test_revert_airdropSignature_erc1155_eip1271_invalidSignature() public {
        // set mockSmartWallet as contract owner
        vm.prank(signer);
        airdrop.setOwner(address(mockSmartWallet));

        // mint tokens to mockSmartWallet
        erc1155.mint(address(mockSmartWallet), 0, 100 ether);
        vm.prank(address(mockSmartWallet));
        erc1155.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC1155[] memory contents = _getContentsERC1155(10);
        Airdrop.AirdropRequestERC1155 memory req = Airdrop.AirdropRequestERC1155({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc1155),
            expirationTimestamp: 1000,
            contents: contents
        });

        // sign with random private key
        bytes memory signature = _signReqERC1155(req, 123);

        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestInvalidSigner.selector));
        airdrop.airdropERC1155WithSignature(req, signature);
    }

    function test_revert_airdropSignature_erc115_expired() public {
        erc1155.mint(signer, 0, 100 ether);
        vm.prank(signer);
        erc1155.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC1155[] memory contents = _getContentsERC1155(10);
        Airdrop.AirdropRequestERC1155 memory req = Airdrop.AirdropRequestERC1155({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc1155),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC1155(req, privateKey);

        vm.warp(1001);

        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestExpired.selector, req.expirationTimestamp));
        airdrop.airdropERC1155WithSignature(req, signature);
    }

    function test_revert_airdropSignature_erc115_alreadyProcessed() public {
        erc1155.mint(signer, 0, 100 ether);
        vm.prank(signer);
        erc1155.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC1155[] memory contents = _getContentsERC1155(10);
        Airdrop.AirdropRequestERC1155 memory req = Airdrop.AirdropRequestERC1155({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc1155),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC1155(req, privateKey);

        airdrop.airdropERC1155WithSignature(req, signature);

        // send it again
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestAlreadyProcessed.selector));
        airdrop.airdropERC1155WithSignature(req, signature);
    }

    function test_revert_airdropSignature_erc115_invalidSigner() public {
        erc1155.mint(signer, 0, 100 ether);
        vm.prank(signer);
        erc1155.setApprovalForAll(address(airdrop), true);

        Airdrop.AirdropContentERC1155[] memory contents = _getContentsERC1155(10);
        Airdrop.AirdropRequestERC1155 memory req = Airdrop.AirdropRequestERC1155({
            uid: bytes32(uint256(1)),
            tokenAddress: address(erc1155),
            expirationTimestamp: 1000,
            contents: contents
        });
        bytes memory signature = _signReqERC1155(req, 123);

        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropRequestInvalidSigner.selector));
        airdrop.airdropERC1155WithSignature(req, signature);
    }
    /*///////////////////////////////////////////////////////////////
                       Benchmark: Airdrop Claim ERC1155 
    //////////////////////////////////////////////////////////////*/

    function test_state_airdropClaim_erc1155() public {
        erc1155.mint(signer, 0, 100 ether);
        vm.prank(signer);
        erc1155.setApprovalForAll(address(airdrop), true);

        string[] memory inputs = new string[](4);
        inputs[0] = "node";
        inputs[1] = "src/test/scripts/generateRootAirdrop1155.ts";
        inputs[2] = Strings.toString(uint256(0));
        inputs[3] = Strings.toString(uint256(5));
        bytes memory result = vm.ffi(inputs);
        bytes32 root = abi.decode(result, (bytes32));

        // set merkle root
        vm.prank(signer);
        airdrop.setMerkleRoot(address(erc1155), root, true);

        // generate proof
        inputs[1] = "src/test/scripts/getProofAirdrop1155.ts";
        result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));

        address receiver = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);
        uint256 quantity = 5;

        airdrop.claimERC1155(address(erc1155), receiver, 0, quantity, proofs);

        assertEq(erc1155.balanceOf(receiver, 0), quantity);
        assertEq(erc1155.balanceOf(signer, 0), 100 ether - quantity);
    }

    function test_revert_airdropClaim_erc1155_alreadyClaimed() public {
        erc1155.mint(signer, 0, 100 ether);
        vm.prank(signer);
        erc1155.setApprovalForAll(address(airdrop), true);

        string[] memory inputs = new string[](4);
        inputs[0] = "node";
        inputs[1] = "src/test/scripts/generateRootAirdrop1155.ts";
        inputs[2] = Strings.toString(uint256(0));
        inputs[3] = Strings.toString(uint256(5));
        bytes memory result = vm.ffi(inputs);
        bytes32 root = abi.decode(result, (bytes32));

        // set merkle root
        vm.prank(signer);
        airdrop.setMerkleRoot(address(erc1155), root, true);

        // generate proof
        inputs[1] = "src/test/scripts/getProofAirdrop1155.ts";
        result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));

        address receiver = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);
        uint256 quantity = 5;

        airdrop.claimERC1155(address(erc1155), receiver, 0, quantity, proofs);

        // revert when claiming again
        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropAlreadyClaimed.selector));
        airdrop.claimERC1155(address(erc1155), receiver, 0, quantity, proofs);
    }

    function test_revert_airdropClaim_erc1155_noMerkleRoot() public {
        erc1155.mint(signer, 0, 100 ether);
        vm.prank(signer);
        erc1155.setApprovalForAll(address(airdrop), true);

        // generate proof
        bytes32[] memory proofs;

        address receiver = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);
        uint256 quantity = 5;

        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropNoMerkleRoot.selector));
        airdrop.claimERC1155(address(erc1155), receiver, 0, quantity, proofs);
    }

    function test_revert_airdropClaim_erc1155_invalidProof() public {
        erc1155.mint(signer, 0, 100 ether);
        vm.prank(signer);
        erc1155.setApprovalForAll(address(airdrop), true);

        string[] memory inputs = new string[](4);
        inputs[0] = "node";
        inputs[1] = "src/test/scripts/generateRootAirdrop1155.ts";
        inputs[2] = Strings.toString(uint256(0));
        inputs[3] = Strings.toString(uint256(5));
        bytes memory result = vm.ffi(inputs);
        bytes32 root = abi.decode(result, (bytes32));

        // set merkle root
        vm.prank(signer);
        airdrop.setMerkleRoot(address(erc1155), root, true);

        // generate proof
        inputs[1] = "src/test/scripts/getProofAirdrop1155.ts";
        result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));

        address receiver = address(0x12345);
        uint256 quantity = 5;

        vm.expectRevert(abi.encodeWithSelector(Airdrop.AirdropInvalidProof.selector));
        airdrop.claimERC1155(address(erc1155), receiver, 0, quantity, proofs);
    }
}
