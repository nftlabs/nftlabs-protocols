// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.0;

// Access Control
import "@openzeppelin/contracts/access/AccessControl.sol";

// Tokens
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ProtocolControl is AccessControl {
    /// @dev Admin role for protocol.
    bytes32 public constant PROTOCOL_ADMIN = keccak256("PROTOCOL_ADMIN");
    /// @dev Admin role for protocol provider.
    bytes32 public constant PROTOCOL_PROVIDER = keccak256("PROTOCOL_PROVIDER");
    /// @dev Admin role that lets only accounts with the role transfer the module's tokens
    bytes32 public constant TRANSFER_ROLE = keccak256("TRANSFER_ROLE");

    /// @dev Protocol status.
    bool public systemPaused;

    /// @dev Protocol provider's treasury
    address public providerTreasury;

    /// @dev deployer's treasury
    address public ownerTreasury;

    /// @dev Pack protocol module names.
    enum ModuleType {
        Coin,
        NFTCollection,
        NFT,
        DynamicNFT,
        AccessNFT,
        Pack,
        Market,
        Other
    }

    /// @dev Module ID => Module address.
    mapping(bytes32 => address) public modules;
    /// @dev Module ID => Module type.
    mapping(bytes32 => ModuleType) public moduleType;
    ///@dev Module address => Module ID
    mapping(address => bytes32) public moduleIds;
    /// @dev Module type => Num of modules of that type.
    mapping(uint256 => uint256) public numOfModuleType;
    /// @dev Module ID => transfer restrictions
    mapping(bytes32 => bool) public transfersRestricted;

    /// @dev Protocol provider fees
    uint128 public constant MAX_BPS = 10000; // 100%
    uint128 public constant MAX_PROVIDER_FEE_BPS = 1000; // 10%
    uint128 public providerFeeBps = 1000; // 10%

    /// @dev Contract level metadata.
    string public _contractURI;

    /// @dev Events.
    event ModuleUpdated(bytes32 indexed moduleId, address indexed module, uint256 indexed moduleType);
    event FundsTransferred(address asset, address to, uint256 amount);
    event OwnerTreasuryUpdated(address _providerTreasury);
    event SystemPaused(bool isPaused);
    event ProviderFeeBpsUpdated(uint256 providerFeeBps);
    event ProviderTreasuryUpdated(address _providerTreasury);
    event TransferRestricted(bytes32 moduleId, address moduleAddress, bool restriction);

    /// @dev Check whether the caller is a protocol admin
    modifier onlyProtocolAdmin() {
        require(hasRole(PROTOCOL_ADMIN, msg.sender), "Protocol: Only protocol admins can call this function.");
        _;
    }

    /// @dev Check whether the caller is an protocol provider admin
    modifier onlyProtocolProvider() {
        require(
            hasRole(PROTOCOL_PROVIDER, msg.sender),
            "Protocol: Only protocol provider admins can call this function."
        );
        _;
    }

    constructor(
        address _admin,
        address _provider,
        string memory _uri
    ) {
        // Set contract URI
        _contractURI = _uri;

        // Set protocol provider treasury
        providerTreasury = _provider;
        ownerTreasury = _admin;

        // Set access control roles
        _setupRole(PROTOCOL_ADMIN, _admin);
        _setupRole(TRANSFER_ROLE, _admin);
        _setupRole(PROTOCOL_PROVIDER, _provider);

        _setRoleAdmin(PROTOCOL_ADMIN, PROTOCOL_ADMIN);
        _setRoleAdmin(TRANSFER_ROLE, PROTOCOL_ADMIN);
        _setRoleAdmin(PROTOCOL_PROVIDER, PROTOCOL_PROVIDER);

        emit OwnerTreasuryUpdated(_admin);
        emit ProviderTreasuryUpdated(_provider);
    }

    /// @dev Let the contract accept ether.
    receive() external payable {}

    /// @dev Lets a protocol admin add a module to the protocol.
    function addModule(address _newModuleAddress, uint8 _moduleType)
        external
        onlyProtocolAdmin
        returns (bytes32 moduleId)
    {
        // `moduleId` is collision resitant -- unique `_moduleType` and incrementing `numOfModuleType`
        moduleId = keccak256(abi.encodePacked(numOfModuleType[_moduleType], uint256(_moduleType)));
        numOfModuleType[_moduleType] += 1;

        modules[moduleId] = _newModuleAddress;
        moduleIds[_newModuleAddress] = moduleId;

        emit ModuleUpdated(moduleId, _newModuleAddress, _moduleType);
    }

    /// @dev Lets a protocol admin change the address of a module of the protocol.
    function updateModule(bytes32 _moduleId, address _newModuleAddress) external onlyProtocolAdmin {
        require(modules[_moduleId] != address(0), "ProtocolControl: a module with this ID does not exist.");

        modules[_moduleId] = _newModuleAddress;
        moduleIds[_newModuleAddress] = _moduleId;

        emit ModuleUpdated(_moduleId, _newModuleAddress, uint256(moduleType[_moduleId]));
    }

    /// @dev Lets a nftlabs admin change the market fee basis points.
    function updateProviderFeeBps(uint128 _newFeeBps) external onlyProtocolProvider {
        require(_newFeeBps <= MAX_PROVIDER_FEE_BPS, "ProtocolControl: provider fee cannot be greater than 10%");

        providerFeeBps = _newFeeBps;

        emit ProviderFeeBpsUpdated(_newFeeBps);
    }

    /// @dev Lets provider admins change the address of providers tresury.
    function updateProviderTreasury(address _newTreasury) external onlyProtocolProvider {
        providerTreasury = _newTreasury;

        emit ProviderTreasuryUpdated(_newTreasury);
    }

    ///@dev Lets a protocol admin update the owner trasury address.
    function updateOwnerTreasury(address _newTreasury) external onlyProtocolAdmin {
        ownerTreasury = _newTreasury;

        emit OwnerTreasuryUpdated(_newTreasury);
    }

    /// @dev Lets a protocol admin pause the protocol.
    function pauseProtocol(bool _toPause) external onlyProtocolAdmin {
        systemPaused = _toPause;
        emit SystemPaused(_toPause);
    }

    /// @dev Lets a protocol admin restric transfers of a module's tokens
    function restrictTransfers(bytes32 _moduleId, bool _restriction) external onlyProtocolAdmin {
        require(modules[_moduleId] != address(0), "ProtocolControl: a module with this ID does not exist.");
        transfersRestricted[_moduleId] = _restriction;

        emit TransferRestricted(_moduleId, modules[_moduleId], _restriction);
    }

    /// @dev Returns whether transfers on a module are restricted
    function isRestrictedTransfers(address _moduleAddress) external view returns (bool) {
        return transfersRestricted[moduleIds[_moduleAddress]];
    }

    /// @dev Lets a protocol admin transfer this contract's funds.
    function transferProtocolFunds(
        address _asset,
        address _to,
        uint256 _amount
    ) external onlyProtocolAdmin {
        bool success;

        if (_asset == address(0)) {
            (success, ) = (_to).call{ value: _amount }("");
        } else {
            success = IERC20(_asset).transfer(_to, _amount);
        }

        require(success, "Protocol Control: failed to transfer protocol funds.");

        emit FundsTransferred(_asset, _to, _amount);
    }

    /// @dev Sets contract URI for the contract-level metadata of the contract.
    function setContractURI(string calldata _URI) external onlyProtocolAdmin {
        _contractURI = _URI;
    }

    /// @dev Returns the URI for the contract-level metadata of the contract.
    function contractURI() public view returns (string memory) {
        return _contractURI;
    }

    /// @dev Returns all addresses for a module type
    function getAllModulesOfType(uint256 _moduleType) external view returns (address[] memory allModules) {
        uint256 numOfModules = numOfModuleType[_moduleType];
        allModules = new address[](numOfModules);

        for (uint256 i = 0; i < numOfModules; i += 1) {
            bytes32 moduleId = keccak256(abi.encodePacked(i, _moduleType));
            allModules[i] = modules[moduleId];
        }
    }
}
