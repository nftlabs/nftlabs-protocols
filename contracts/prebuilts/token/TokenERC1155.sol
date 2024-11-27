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

// Interface
import { ITokenERC1155 } from "../interface/token/ITokenERC1155.sol";

import "../../infra/interface/IThirdwebContract.sol";
import "../../extension/interface/IPlatformFee.sol";
import "../../extension/interface/IPrimarySale.sol";
import "../../extension/interface/IRoyalty.sol";
import "../../extension/interface/IOwnable.sol";

import "../../extension/NFTMetadata.sol";

// Token
import "@openzeppelin/contracts-upgradeable/token/ERC1155/ERC1155Upgradeable.sol";

// Signature utils
import "@openzeppelin/contracts-upgradeable/utils/cryptography/ECDSAUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/draft-EIP712Upgradeable.sol";

// Access Control + security
import "@openzeppelin/contracts-upgradeable/access/AccessControlEnumerableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";

// Utils
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";
import "../../extension/Multicall.sol";
import "../../lib/CurrencyTransferLib.sol";
import "../../lib/FeeType.sol";
import "../../external-deps/openzeppelin/metatx/ERC2771ContextUpgradeable.sol";

// Helper interfaces
import "@openzeppelin/contracts-upgradeable/interfaces/IERC2981Upgradeable.sol";

contract TokenERC1155 is
    Initializable,
    IThirdwebContract,
    IOwnable,
    IRoyalty,
    IPrimarySale,
    IPlatformFee,
    EIP712Upgradeable,
    ReentrancyGuardUpgradeable,
    ERC2771ContextUpgradeable,
    Multicall,
    AccessControlEnumerableUpgradeable,
    ERC1155Upgradeable,
    ITokenERC1155,
    NFTMetadata
{
    using ECDSAUpgradeable for bytes32;
    using StringsUpgradeable for uint256;

    bytes32 private constant MODULE_TYPE = bytes32("TokenERC1155");
    uint256 private constant VERSION = 1;

    // Token name
    string public name;

    // Token symbol
    string public symbol;

    bytes32 private constant TYPEHASH =
        keccak256(
            "MintRequest(address to,address royaltyRecipient,uint256 royaltyBps,address primarySaleRecipient,uint256 tokenId,string uri,uint256 quantity,uint256 pricePerToken,address currency,uint128 validityStartTimestamp,uint128 validityEndTimestamp,bytes32 uid)"
        );

    /// @dev Only TRANSFER_ROLE holders can have tokens transferred from or to them, during restricted transfers.
    bytes32 private constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");
    /// @dev Only MINTER_ROLE holders can sign off on `MintRequest`s.
    bytes32 internal constant MINTER_ROLE = keccak256("MINTER_ROLE");
    /// @dev Only METADATA_ROLE holders can update NFT metadata.
    bytes32 private constant METADATA_ROLE = keccak256("METADATA_ROLE");

    /// @dev Max bps in the thirdweb system
    uint256 private constant MAX_BPS = 10_000;

    /// @dev Owner of the contract (purpose: OpenSea compatibility, etc.)
    address private _owner;

    /// @dev The next token ID of the NFT to mint.
    uint256 public nextTokenIdToMint;

    /// @dev The adress that receives all primary sales value.
    address public primarySaleRecipient;

    /// @dev The adress that receives all primary sales value.
    address public platformFeeRecipient;

    /// @dev The recipient of who gets the royalty.
    address private royaltyRecipient;

    /// @dev The percentage of royalty how much royalty in basis points.
    uint128 private royaltyBps;

    /// @dev The % of primary sales collected by the contract as fees.
    uint128 private platformFeeBps;

    /// @dev The flat amount collected by the contract as fees on primary sales.
    uint256 private flatPlatformFee;

    /// @dev Fee type variants: percentage fee and flat fee
    PlatformFeeType private platformFeeType;

    /// @dev Contract level metadata.
    string public contractURI;

    /// @dev Mapping from mint request UID => whether the mint request is processed.
    mapping(bytes32 => bool) private minted;

    /// @dev Token ID => total circulating supply of tokens with that ID.
    mapping(uint256 => uint256) public totalSupply;

    /// @dev Token ID => the address of the recipient of primary sales.
    mapping(uint256 => address) public saleRecipientForToken;

    /// @dev Token ID => royalty recipient and bps for token
    mapping(uint256 => RoyaltyInfo) private royaltyInfoForToken;

    constructor() initializer {}

    /// @dev Initializes the contract, like a constructor.
    function initialize(
        address _defaultAdmin,
        string memory _name,
        string memory _symbol,
        string memory _contractURI,
        address[] memory _trustedForwarders,
        address _primarySaleRecipient,
        address _royaltyRecipient,
        uint128 _royaltyBps,
        uint128 _platformFeeBps,
        address _platformFeeRecipient
    ) public virtual initializer {
        // Initialize inherited contracts, most base-like -> most derived.
        __ReentrancyGuard_init();
        __EIP712_init("TokenERC1155", "1");
        __ERC2771Context_init(_trustedForwarders);
        __ERC1155_init("");

        // Initialize this contract's state.
        name = _name;
        symbol = _symbol;
        royaltyRecipient = _royaltyRecipient;
        royaltyBps = _royaltyBps;
        platformFeeRecipient = _platformFeeRecipient;
        primarySaleRecipient = _primarySaleRecipient;
        contractURI = _contractURI;

        require(_platformFeeBps <= MAX_BPS, "exceeds MAX_BPS");
        platformFeeBps = _platformFeeBps;

        // Fee type Bps by default
        platformFeeType = PlatformFeeType.Bps;

        _owner = _defaultAdmin;
        _setupRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _setupRole(MINTER_ROLE, _defaultAdmin);
        _setupRole(TRANSFER_ROLE, _defaultAdmin);
        _setupRole(TRANSFER_ROLE, address(0));

        _setupRole(METADATA_ROLE, _defaultAdmin);
        _setRoleAdmin(METADATA_ROLE, METADATA_ROLE);

        emit PrimarySaleRecipientUpdated(_primarySaleRecipient);
        emit PlatformFeeInfoUpdated(_platformFeeRecipient, _platformFeeBps);
        emit DefaultRoyalty(_royaltyRecipient, _royaltyBps);
    }

    ///     =====   Public functions  =====

    /// @dev Returns the module type of the contract.
    function contractType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    /// @dev Returns the version of the contract.
    function contractVersion() external pure returns (uint8) {
        return uint8(VERSION);
    }

    /**
     * @dev Returns the address of the current owner.
     */
    function owner() public view returns (address) {
        return hasRole(DEFAULT_ADMIN_ROLE, _owner) ? _owner : address(0);
    }

    /// @dev Verifies that a mint request is signed by an account holding MINTER_ROLE (at the time of the function call).
    function verify(MintRequest calldata _req, bytes calldata _signature) public view returns (bool, address) {
        address signer = recoverAddress(_req, _signature);
        return (!minted[_req.uid] && hasRole(MINTER_ROLE, signer), signer);
    }

    /// @dev Returns the URI for a tokenId
    function uri(uint256 _tokenId) public view override returns (string memory) {
        return _tokenURI[_tokenId];
    }

    /// @dev Lets an account with MINTER_ROLE mint an NFT.
    function mintTo(
        address _to,
        uint256 _tokenId,
        string calldata _uri,
        uint256 _amount
    ) external nonReentrant onlyRole(MINTER_ROLE) {
        uint256 tokenIdToMint;
        if (_tokenId == type(uint256).max) {
            tokenIdToMint = nextTokenIdToMint;
            nextTokenIdToMint += 1;
        } else {
            require(_tokenId < nextTokenIdToMint, "invalid id");
            tokenIdToMint = _tokenId;
        }

        // `_mintTo` is re-used. `mintTo` just adds a minter role check.
        _mintTo(_to, _uri, tokenIdToMint, _amount);
    }

    ///     =====   External functions  =====

    /// @dev See EIP-2981
    function royaltyInfo(
        uint256 tokenId,
        uint256 salePrice
    ) external view virtual returns (address receiver, uint256 royaltyAmount) {
        (address recipient, uint256 bps) = getRoyaltyInfoForToken(tokenId);
        receiver = recipient;
        royaltyAmount = (salePrice * bps) / MAX_BPS;
    }

    /// @dev Mints an NFT according to the provided mint request.
    function mintWithSignature(MintRequest calldata _req, bytes calldata _signature) external payable nonReentrant {
        address signer = verifyRequest(_req, _signature);
        address receiver = _req.to;

        uint256 tokenIdToMint;
        if (_req.tokenId == type(uint256).max) {
            tokenIdToMint = nextTokenIdToMint;
            nextTokenIdToMint += 1;
        } else {
            require(_req.tokenId < nextTokenIdToMint, "invalid id");
            tokenIdToMint = _req.tokenId;
        }

        if (_req.royaltyRecipient != address(0)) {
            royaltyInfoForToken[tokenIdToMint] = RoyaltyInfo({
                recipient: _req.royaltyRecipient,
                bps: _req.royaltyBps
            });
        }

        _mintTo(receiver, _req.uri, tokenIdToMint, _req.quantity);

        collectPrice(_req);

        emit TokensMintedWithSignature(signer, receiver, tokenIdToMint, _req);
    }

    //      =====   Setter functions  =====

    /// @dev Lets a module admin set the default recipient of all primary sales.
    function setPrimarySaleRecipient(address _saleRecipient) external onlyRole(DEFAULT_ADMIN_ROLE) {
        primarySaleRecipient = _saleRecipient;
        emit PrimarySaleRecipientUpdated(_saleRecipient);
    }

    /// @dev Lets a module admin update the royalty bps and recipient.
    function setDefaultRoyaltyInfo(
        address _royaltyRecipient,
        uint256 _royaltyBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_royaltyBps <= MAX_BPS, "exceed royalty bps");

        royaltyRecipient = _royaltyRecipient;
        royaltyBps = uint128(_royaltyBps);

        emit DefaultRoyalty(_royaltyRecipient, _royaltyBps);
    }

    /// @dev Lets a module admin set the royalty recipient for a particular token Id.
    function setRoyaltyInfoForToken(
        uint256 _tokenId,
        address _recipient,
        uint256 _bps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_bps <= MAX_BPS, "exceed royalty bps");

        royaltyInfoForToken[_tokenId] = RoyaltyInfo({ recipient: _recipient, bps: _bps });

        emit RoyaltyForToken(_tokenId, _recipient, _bps);
    }

    /// @dev Lets a module admin update the fees on primary sales.
    function setPlatformFeeInfo(
        address _platformFeeRecipient,
        uint256 _platformFeeBps
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_platformFeeBps <= MAX_BPS, "exceeds MAX_BPS");

        platformFeeBps = uint64(_platformFeeBps);
        platformFeeRecipient = _platformFeeRecipient;

        emit PlatformFeeInfoUpdated(_platformFeeRecipient, _platformFeeBps);
    }

    /// @dev Lets a module admin set a flat fee on primary sales.
    function setFlatPlatformFeeInfo(
        address _platformFeeRecipient,
        uint256 _flatFee
    ) external onlyRole(DEFAULT_ADMIN_ROLE) {
        flatPlatformFee = _flatFee;
        platformFeeRecipient = _platformFeeRecipient;

        emit FlatPlatformFeeUpdated(_platformFeeRecipient, _flatFee);
    }

    /// @dev Lets a module admin set a flat fee on primary sales.
    function setPlatformFeeType(PlatformFeeType _feeType) external onlyRole(DEFAULT_ADMIN_ROLE) {
        platformFeeType = _feeType;

        emit PlatformFeeTypeUpdated(_feeType);
    }

    /// @dev Lets a module admin set a new owner for the contract. The new owner must be a module admin.
    function setOwner(address _newOwner) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(hasRole(DEFAULT_ADMIN_ROLE, _newOwner), "new owner not module admin.");
        address _prevOwner = _owner;
        _owner = _newOwner;

        emit OwnerUpdated(_prevOwner, _newOwner);
    }

    /// @dev Lets a module admin set the URI for contract-level metadata.
    function setContractURI(string calldata _uri) external onlyRole(DEFAULT_ADMIN_ROLE) {
        contractURI = _uri;
    }

    ///     =====   Getter functions    =====

    /// @dev Returns the platform fee bps and recipient.
    function getPlatformFeeInfo() external view returns (address, uint16) {
        return (platformFeeRecipient, uint16(platformFeeBps));
    }

    /// @dev Returns the flat platform fee and recipient.
    function getFlatPlatformFeeInfo() external view returns (address, uint256) {
        return (platformFeeRecipient, flatPlatformFee);
    }

    /// @dev Returns the platform fee type.
    function getPlatformFeeType() external view returns (PlatformFeeType) {
        return platformFeeType;
    }

    /// @dev Returns default royalty info.
    function getDefaultRoyaltyInfo() external view returns (address, uint16) {
        return (royaltyRecipient, uint16(royaltyBps));
    }

    /// @dev Returns the royalty recipient for a particular token Id.
    function getRoyaltyInfoForToken(uint256 _tokenId) public view returns (address, uint16) {
        RoyaltyInfo memory royaltyForToken = royaltyInfoForToken[_tokenId];

        return
            royaltyForToken.recipient == address(0)
                ? (royaltyRecipient, uint16(royaltyBps))
                : (royaltyForToken.recipient, uint16(royaltyForToken.bps));
    }

    ///     =====   Internal functions  =====

    /// @dev Mints an NFT to `to`
    function _mintTo(address _to, string calldata _uri, uint256 _tokenId, uint256 _amount) internal {
        if (bytes(_tokenURI[_tokenId]).length == 0) {
            _setTokenURI(_tokenId, _uri);
        }

        _mint(_to, _tokenId, _amount, "");

        emit TokensMinted(_to, _tokenId, _tokenURI[_tokenId], _amount);
    }

    /// @dev Returns the address of the signer of the mint request.
    function recoverAddress(MintRequest calldata _req, bytes calldata _signature) internal view returns (address) {
        return _hashTypedDataV4(keccak256(_encodeRequest(_req))).recover(_signature);
    }

    /// @dev Resolves 'stack too deep' error in `recoverAddress`.
    function _encodeRequest(MintRequest calldata _req) internal pure returns (bytes memory) {
        return
            bytes.concat(
                abi.encode(
                    TYPEHASH,
                    _req.to,
                    _req.royaltyRecipient,
                    _req.royaltyBps,
                    _req.primarySaleRecipient,
                    _req.tokenId,
                    keccak256(bytes(_req.uri))
                ),
                abi.encode(
                    _req.quantity,
                    _req.pricePerToken,
                    _req.currency,
                    _req.validityStartTimestamp,
                    _req.validityEndTimestamp,
                    _req.uid
                )
            );
    }

    /// @dev Verifies that a mint request is valid.
    function verifyRequest(MintRequest calldata _req, bytes calldata _signature) internal returns (address) {
        (bool success, address signer) = verify(_req, _signature);
        require(success, "invalid signature");

        require(
            _req.validityStartTimestamp <= block.timestamp && _req.validityEndTimestamp >= block.timestamp,
            "request expired"
        );
        require(_req.to != address(0), "recipient undefined");
        require(_req.quantity > 0, "zero quantity");

        minted[_req.uid] = true;

        return signer;
    }

    /// @dev Collects and distributes the primary sale value of tokens being claimed.
    function collectPrice(MintRequest calldata _req) internal {
        if (_req.pricePerToken == 0) {
            require(msg.value == 0, "!Value");
            return;
        }

        uint256 totalPrice = _req.pricePerToken * _req.quantity;
        uint256 platformFees = platformFeeType == PlatformFeeType.Flat
            ? flatPlatformFee
            : ((totalPrice * platformFeeBps) / MAX_BPS);
        require(totalPrice >= platformFees, "price less than platform fee");

        if (_req.currency == CurrencyTransferLib.NATIVE_TOKEN) {
            require(msg.value == totalPrice, "must send total price.");
        } else {
            require(msg.value == 0, "msg value not zero");
        }

        address saleRecipient = _req.primarySaleRecipient == address(0)
            ? primarySaleRecipient
            : _req.primarySaleRecipient;

        CurrencyTransferLib.transferCurrency(_req.currency, _msgSender(), platformFeeRecipient, platformFees);
        CurrencyTransferLib.transferCurrency(_req.currency, _msgSender(), saleRecipient, totalPrice - platformFees);
    }

    ///     =====   Low-level overrides  =====

    /// @dev Lets a token owner burn the tokens they own (i.e. destroy for good)
    function burn(address account, uint256 id, uint256 value) public virtual {
        require(
            account == _msgSender() || isApprovedForAll(account, _msgSender()),
            "ERC1155: caller is not owner nor approved."
        );

        _burn(account, id, value);
    }

    /// @dev Lets a token owner burn multiple tokens they own at once (i.e. destroy for good)
    function burnBatch(address account, uint256[] memory ids, uint256[] memory values) public virtual {
        require(
            account == _msgSender() || isApprovedForAll(account, _msgSender()),
            "ERC1155: caller is not owner nor approved."
        );

        _burnBatch(account, ids, values);
    }

    /**
     * @dev See {ERC1155-_beforeTokenTransfer}.
     */
    function _beforeTokenTransfer(
        address operator,
        address from,
        address to,
        uint256[] memory ids,
        uint256[] memory amounts,
        bytes memory data
    ) internal virtual override {
        super._beforeTokenTransfer(operator, from, to, ids, amounts, data);

        // if transfer is restricted on the contract, we still want to allow burning and minting
        if (!hasRole(TRANSFER_ROLE, address(0)) && from != address(0) && to != address(0)) {
            require(hasRole(TRANSFER_ROLE, from) || hasRole(TRANSFER_ROLE, to), "restricted to TRANSFER_ROLE holders.");
        }

        if (from == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                totalSupply[ids[i]] += amounts[i];
            }
        }

        if (to == address(0)) {
            for (uint256 i = 0; i < ids.length; ++i) {
                totalSupply[ids[i]] -= amounts[i];
            }
        }
    }

    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        virtual
        override(AccessControlEnumerableUpgradeable, ERC1155Upgradeable, IERC165Upgradeable, IERC165)
        returns (bool)
    {
        return
            super.supportsInterface(interfaceId) ||
            interfaceId == type(IERC1155Upgradeable).interfaceId ||
            interfaceId == type(IERC2981Upgradeable).interfaceId;
    }

    /// @dev Returns whether metadata can be set in the given execution context.
    function _canSetMetadata() internal view virtual override returns (bool) {
        return hasRole(METADATA_ROLE, _msgSender());
    }

    /// @dev Returns whether metadata can be frozen in the given execution context.
    function _canFreezeMetadata() internal view virtual override returns (bool) {
        return hasRole(METADATA_ROLE, _msgSender());
    }

    function _msgSender()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable, Multicall)
        returns (address sender)
    {
        return ERC2771ContextUpgradeable._msgSender();
    }

    function _msgData()
        internal
        view
        virtual
        override(ContextUpgradeable, ERC2771ContextUpgradeable)
        returns (bytes calldata)
    {
        return ERC2771ContextUpgradeable._msgData();
    }
}
