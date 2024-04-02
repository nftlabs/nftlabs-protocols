// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

/// @author thirdweb

//   $$\     $$\       $$\                 $$\                         $$\
//   $$ |    $$ |      \__|                $$ |                        $$ |
// $$$$$$\   $$$$$$$\  $$\  $$$$$$\   $$$$$$$ |$$\  $$\  $$\  $$$$$$\  $$$$$$$\
// \_$$  _|  $$  __$$\ $$ |$$  __$$\ $$  __$$ |$$ | $$ | $$ |$$  __$$\ $$  __$$\
//   $$ |    $$ |  $$ |$$ |$$ |  \__|$$ /  $$ |$$ | $$ | $$ |$$$$$$$$ |$$ |  $$ |
//   $$ |$$\ $$ |  $$ |$$ |$$ |      $$ |  $$ |$$ | $$ | $$ |$$   ____|$$ |  $$ |
//   \$$$$  |$$ |  $$ |$$ |$$ |      \$$$$$$$ |\$$$$$\$$$$  |\$$$$$$$\ $$$$$$$  |
//    \____/ \__|  \__|\__|\__|       \_______| \_____\____/  \_______|\_______/

import "@solady/src/utils/MerkleProofLib.sol";
import "@solady/src/utils/ECDSA.sol";
import "@solady/src/utils/EIP712.sol";
import "@solady/src/utils/SafeTransferLib.sol";
import "@solady/src/utils/SignatureCheckerLib.sol";

import { Initializable } from "../../../extension/Initializable.sol";
import { Ownable } from "../../../extension/Ownable.sol";

import "../../../eip/interface/IERC20.sol";
import "../../../eip/interface/IERC721.sol";
import "../../../eip/interface/IERC1155.sol";

contract Airdrop is EIP712, Initializable, Ownable {
    using ECDSA for bytes32;

    /*///////////////////////////////////////////////////////////////
                            State, constants & structs
    //////////////////////////////////////////////////////////////*/

    /// @dev token contract address => conditionId
    mapping(address => uint256) public tokenConditionId;
    /// @dev token contract address => merkle root
    mapping(address => bytes32) public tokenMerkleRoot;
    /// @dev conditionId => hash(claimer address, token address, token id [1155]) => has claimed
    mapping(uint256 => mapping(bytes32 => bool)) private claimed;
    /// @dev Mapping from request UID => whether the request is processed.
    mapping(bytes32 => bool) private processed;

    struct AirdropContentERC20 {
        address recipient;
        uint256 amount;
    }

    struct AirdropContentERC721 {
        address recipient;
        uint256 tokenId;
    }

    struct AirdropContentERC1155 {
        address recipient;
        uint256 tokenId;
        uint256 amount;
    }

    struct AirdropRequestERC20 {
        bytes32 uid;
        address tokenAddress;
        uint256 expirationTimestamp;
        AirdropContentERC20[] contents;
    }

    struct AirdropRequestERC721 {
        bytes32 uid;
        address tokenAddress;
        uint256 expirationTimestamp;
        AirdropContentERC721[] contents;
    }

    struct AirdropRequestERC1155 {
        bytes32 uid;
        address tokenAddress;
        uint256 expirationTimestamp;
        AirdropContentERC1155[] contents;
    }

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

    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /*///////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    error AirdropInvalidProof();
    error AirdropAlreadyClaimed();
    error AirdropFailed();
    error AirdropNoMerkleRoot();
    error AirdropValueMismatch();
    error AirdropRequestExpired(uint256 expirationTimestamp);
    error AirdropRequestAlreadyProcessed();
    error AirdropRequestInvalidSigner();
    error AirdropInvalidTokenAddress();

    /*///////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    event Airdrop(address token);
    event AirdropClaimed(address token, address receiver);

    /*///////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/

    constructor() {
        _disableInitializers();
    }

    function initialize(address _defaultAdmin) external initializer {
        _setupOwner(_defaultAdmin);
    }

    /*///////////////////////////////////////////////////////////////
                        Receive and withdraw logic
    //////////////////////////////////////////////////////////////*/

    receive() external payable {}

    function withdraw(address _tokenAddress, uint256 _amount) external onlyOwner {
        if (_tokenAddress == NATIVE_TOKEN_ADDRESS) {
            SafeTransferLib.safeTransferETH(msg.sender, _amount);
        } else {
            SafeTransferLib.safeTransferFrom(_tokenAddress, address(this), msg.sender, _amount);
        }
    }

    /*///////////////////////////////////////////////////////////////
                            Airdrop Push
    //////////////////////////////////////////////////////////////*/

    function airdropNativeToken(AirdropContentERC20[] calldata _contents) external payable onlyOwner {
        uint256 len = _contents.length;
        uint256 nativeTokenAmount;

        for (uint256 i = 0; i < len; i++) {
            nativeTokenAmount += _contents[i].amount;
            (bool success, ) = _contents[i].recipient.call{ value: _contents[i].amount }("");
            if (!success) {
                revert AirdropFailed();
            }
        }

        if (nativeTokenAmount != msg.value) {
            revert AirdropValueMismatch();
        }

        emit Airdrop(NATIVE_TOKEN_ADDRESS);
    }

    function airdropERC20(address _tokenAddress, AirdropContentERC20[] calldata _contents) external onlyOwner {
        uint256 len = _contents.length;

        for (uint256 i = 0; i < len; i++) {
            SafeTransferLib.safeTransferFrom(_tokenAddress, msg.sender, _contents[i].recipient, _contents[i].amount);
        }

        emit Airdrop(_tokenAddress);
    }

    function airdropERC721(address _tokenAddress, AirdropContentERC721[] calldata _contents) external onlyOwner {
        uint256 len = _contents.length;

        for (uint256 i = 0; i < len; i++) {
            IERC721(_tokenAddress).safeTransferFrom(msg.sender, _contents[i].recipient, _contents[i].tokenId);
        }

        emit Airdrop(_tokenAddress);
    }

    function airdropERC1155(address _tokenAddress, AirdropContentERC1155[] calldata _contents) external onlyOwner {
        uint256 len = _contents.length;

        for (uint256 i = 0; i < len; i++) {
            IERC1155(_tokenAddress).safeTransferFrom(
                msg.sender,
                _contents[i].recipient,
                _contents[i].tokenId,
                _contents[i].amount,
                ""
            );
        }

        emit Airdrop(_tokenAddress);
    }

    /*///////////////////////////////////////////////////////////////
                        Airdrop With Signature
    //////////////////////////////////////////////////////////////*/

    function airdropERC20WithSignature(AirdropRequestERC20 calldata req, bytes calldata signature) external {
        // verify expiration timestamp
        if (req.expirationTimestamp < block.timestamp) {
            revert AirdropRequestExpired(req.expirationTimestamp);
        }

        if (processed[req.uid]) {
            revert AirdropRequestAlreadyProcessed();
        }

        // verify data
        if (!_verifyRequestSignerERC20(req, signature)) {
            revert AirdropRequestInvalidSigner();
        }

        processed[req.uid] = true;

        uint256 len = req.contents.length;
        address _from = owner();

        for (uint256 i = 0; i < len; i++) {
            SafeTransferLib.safeTransferFrom(
                req.tokenAddress,
                _from,
                req.contents[i].recipient,
                req.contents[i].amount
            );
        }

        emit Airdrop(req.tokenAddress);
    }

    function airdropERC721WithSignature(AirdropRequestERC721 calldata req, bytes calldata signature) external {
        // verify expiration timestamp
        if (req.expirationTimestamp < block.timestamp) {
            revert AirdropRequestExpired(req.expirationTimestamp);
        }

        if (processed[req.uid]) {
            revert AirdropRequestAlreadyProcessed();
        }

        // verify data
        if (!_verifyRequestSignerERC721(req, signature)) {
            revert AirdropRequestInvalidSigner();
        }

        processed[req.uid] = true;

        address _from = owner();
        uint256 len = req.contents.length;

        for (uint256 i = 0; i < len; i++) {
            IERC721(req.tokenAddress).safeTransferFrom(_from, req.contents[i].recipient, req.contents[i].tokenId);
        }

        emit Airdrop(req.tokenAddress);
    }

    function airdropERC1155WithSignature(AirdropRequestERC1155 calldata req, bytes calldata signature) external {
        // verify expiration timestamp
        if (req.expirationTimestamp < block.timestamp) {
            revert AirdropRequestExpired(req.expirationTimestamp);
        }

        if (processed[req.uid]) {
            revert AirdropRequestAlreadyProcessed();
        }

        // verify data
        if (!_verifyRequestSignerERC1155(req, signature)) {
            revert AirdropRequestInvalidSigner();
        }

        processed[req.uid] = true;

        address _from = owner();
        uint256 len = req.contents.length;

        for (uint256 i = 0; i < len; i++) {
            IERC1155(req.tokenAddress).safeTransferFrom(
                _from,
                req.contents[i].recipient,
                req.contents[i].tokenId,
                req.contents[i].amount,
                ""
            );
        }

        emit Airdrop(req.tokenAddress);
    }

    /*///////////////////////////////////////////////////////////////
                            Airdrop Claimable
    //////////////////////////////////////////////////////////////*/

    function claimERC20(address _token, address _receiver, uint256 _quantity, bytes32[] calldata _proofs) external {
        bytes32 claimHash = _getClaimHashERC20(_receiver, _token);
        uint256 conditionId = tokenConditionId[_token];

        if (claimed[conditionId][claimHash]) {
            revert AirdropAlreadyClaimed();
        }

        bytes32 _tokenMerkleRoot = tokenMerkleRoot[_token];
        if (_tokenMerkleRoot == bytes32(0)) {
            revert AirdropNoMerkleRoot();
        }

        bool valid = MerkleProofLib.verify(
            _proofs,
            _tokenMerkleRoot,
            keccak256(abi.encodePacked(_receiver, _quantity))
        );
        if (!valid) {
            revert AirdropInvalidProof();
        }

        claimed[conditionId][claimHash] = true;

        SafeTransferLib.safeTransferFrom(_token, owner(), _receiver, _quantity);

        emit AirdropClaimed(_token, _receiver);
    }

    function claimERC721(address _token, address _receiver, uint256 _tokenId, bytes32[] calldata _proofs) external {
        bytes32 claimHash = _getClaimHashERC721(_receiver, _token, _tokenId);
        uint256 conditionId = tokenConditionId[_token];

        if (claimed[conditionId][claimHash]) {
            revert AirdropAlreadyClaimed();
        }

        bytes32 _tokenMerkleRoot = tokenMerkleRoot[_token];
        if (_tokenMerkleRoot == bytes32(0)) {
            revert AirdropNoMerkleRoot();
        }

        bool valid = MerkleProofLib.verify(_proofs, _tokenMerkleRoot, keccak256(abi.encodePacked(_receiver, _tokenId)));
        if (!valid) {
            revert AirdropInvalidProof();
        }

        claimed[conditionId][claimHash] = true;

        IERC721(_token).safeTransferFrom(owner(), _receiver, _tokenId);

        emit AirdropClaimed(_token, _receiver);
    }

    function claimERC1155(
        address _token,
        address _receiver,
        uint256 _tokenId,
        uint256 _quantity,
        bytes32[] calldata _proofs
    ) external {
        bytes32 claimHash = _getClaimHashERC1155(_receiver, _token, _tokenId);
        uint256 conditionId = tokenConditionId[_token];

        if (claimed[conditionId][claimHash]) {
            revert AirdropAlreadyClaimed();
        }

        bytes32 _tokenMerkleRoot = tokenMerkleRoot[_token];
        if (_tokenMerkleRoot == bytes32(0)) {
            revert AirdropNoMerkleRoot();
        }

        bool valid = MerkleProofLib.verify(
            _proofs,
            _tokenMerkleRoot,
            keccak256(abi.encodePacked(_receiver, _tokenId, _quantity))
        );
        if (!valid) {
            revert AirdropInvalidProof();
        }

        claimed[conditionId][claimHash] = true;

        IERC1155(_token).safeTransferFrom(owner(), _receiver, _tokenId, _quantity, "");

        emit AirdropClaimed(_token, _receiver);
    }

    /*///////////////////////////////////////////////////////////////
                            Setter functions
    //////////////////////////////////////////////////////////////*/

    function setMerkleRoot(address _token, bytes32 _tokenMerkleRoot, bool _resetClaimStatus) external onlyOwner {
        if (_resetClaimStatus || tokenConditionId[_token] == 0) {
            tokenConditionId[_token] += 1;
        }
        tokenMerkleRoot[_token] = _tokenMerkleRoot;
    }

    /*///////////////////////////////////////////////////////////////
                        Miscellaneous
    //////////////////////////////////////////////////////////////*/

    function isClaimed(address _receiver, address _token, uint256 _tokenId) external view returns (bool) {
        uint256 _conditionId = tokenConditionId[_token];

        bytes32 claimHash = keccak256(abi.encodePacked(_receiver, _token, _tokenId));
        if (claimed[_conditionId][claimHash]) {
            return true;
        }

        claimHash = keccak256(abi.encodePacked(_receiver, _token));
        if (claimed[_conditionId][claimHash]) {
            return true;
        }

        return false;
    }

    function _canSetOwner() internal view virtual override returns (bool) {
        return msg.sender == owner();
    }

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "Airdrop";
        version = "1";
    }

    function _getClaimHashERC20(address _receiver, address _token) private view returns (bytes32) {
        return keccak256(abi.encodePacked(_receiver, _token));
    }

    function _getClaimHashERC721(address _receiver, address _token, uint256 _tokenId) private view returns (bytes32) {
        return keccak256(abi.encodePacked(_receiver, _token, _tokenId));
    }

    function _getClaimHashERC1155(address _receiver, address _token, uint256 _tokenId) private view returns (bytes32) {
        return keccak256(abi.encodePacked(_receiver, _token, _tokenId));
    }

    function _hashContentInfoERC20(AirdropContentERC20[] calldata contents) private pure returns (bytes32) {
        bytes32[] memory contentHashes = new bytes32[](contents.length);
        for (uint256 i = 0; i < contents.length; i++) {
            contentHashes[i] = keccak256(abi.encode(CONTENT_TYPEHASH_ERC20, contents[i].recipient, contents[i].amount));
        }
        return keccak256(abi.encodePacked(contentHashes));
    }

    function _hashContentInfoERC721(AirdropContentERC721[] calldata contents) private pure returns (bytes32) {
        bytes32[] memory contentHashes = new bytes32[](contents.length);
        for (uint256 i = 0; i < contents.length; i++) {
            contentHashes[i] = keccak256(
                abi.encode(CONTENT_TYPEHASH_ERC721, contents[i].recipient, contents[i].tokenId)
            );
        }
        return keccak256(abi.encodePacked(contentHashes));
    }

    function _hashContentInfoERC1155(AirdropContentERC1155[] calldata contents) private pure returns (bytes32) {
        bytes32[] memory contentHashes = new bytes32[](contents.length);
        for (uint256 i = 0; i < contents.length; i++) {
            contentHashes[i] = keccak256(
                abi.encode(CONTENT_TYPEHASH_ERC1155, contents[i].recipient, contents[i].tokenId, contents[i].amount)
            );
        }
        return keccak256(abi.encodePacked(contentHashes));
    }

    function _verifyRequestSignerERC20(
        AirdropRequestERC20 calldata req,
        bytes calldata signature
    ) private view returns (bool) {
        bytes32 contentHash = _hashContentInfoERC20(req.contents);
        bytes32 structHash = keccak256(
            abi.encode(REQUEST_TYPEHASH_ERC20, req.uid, req.tokenAddress, req.expirationTimestamp, contentHash)
        );

        bytes32 digest = _hashTypedData(structHash);

        return SignatureCheckerLib.isValidSignatureNowCalldata(owner(), digest, signature);
    }

    function _verifyRequestSignerERC721(
        AirdropRequestERC721 calldata req,
        bytes calldata signature
    ) private view returns (bool) {
        bytes32 contentHash = _hashContentInfoERC721(req.contents);
        bytes32 structHash = keccak256(
            abi.encode(REQUEST_TYPEHASH_ERC721, req.uid, req.tokenAddress, req.expirationTimestamp, contentHash)
        );

        bytes32 digest = _hashTypedData(structHash);

        return SignatureCheckerLib.isValidSignatureNowCalldata(owner(), digest, signature);
    }

    function _verifyRequestSignerERC1155(
        AirdropRequestERC1155 calldata req,
        bytes calldata signature
    ) private view returns (bool) {
        bytes32 contentHash = _hashContentInfoERC1155(req.contents);
        bytes32 structHash = keccak256(
            abi.encode(REQUEST_TYPEHASH_ERC1155, req.uid, req.tokenAddress, req.expirationTimestamp, contentHash)
        );

        bytes32 digest = _hashTypedData(structHash);

        return SignatureCheckerLib.isValidSignatureNowCalldata(owner(), digest, signature);
    }
}
