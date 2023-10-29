// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.12;

// Utils
import "./BaseAccountFactoryStorage.sol";
import "../../../extension/Multicall.sol";
import "../../../external-deps/openzeppelin/proxy/Clones.sol";
import "../../../external-deps/openzeppelin/utils/structs/EnumerableSet.sol";
import "../utils/BaseAccount.sol";
import "../../../extension/interface/IAccountPermissions.sol";
import "../../../lib/BytesLib.sol";

// Interface
import "../interface/IEntrypoint.sol";
import "../interface/IAccountFactory.sol";

//   $$\     $$\       $$\                 $$\                         $$\
//   $$ |    $$ |      \__|                $$ |                        $$ |
// $$$$$$\   $$$$$$$\  $$\  $$$$$$\   $$$$$$$ |$$\  $$\  $$\  $$$$$$\  $$$$$$$\
// \_$$  _|  $$  __$$\ $$ |$$  __$$\ $$  __$$ |$$ | $$ | $$ |$$  __$$\ $$  __$$\
//   $$ |    $$ |  $$ |$$ |$$ |  \__|$$ /  $$ |$$ | $$ | $$ |$$$$$$$$ |$$ |  $$ |
//   $$ |$$\ $$ |  $$ |$$ |$$ |      $$ |  $$ |$$ | $$ | $$ |$$   ____|$$ |  $$ |
//   \$$$$  |$$ |  $$ |$$ |$$ |      \$$$$$$$ |\$$$$$\$$$$  |\$$$$$$$\ $$$$$$$  |
//    \____/ \__|  \__|\__|\__|       \_______| \_____\____/  \_______|\_______/

abstract contract BaseAccountFactory is IAccountFactory, Multicall {
    using EnumerableSet for EnumerableSet.AddressSet;

    /*///////////////////////////////////////////////////////////////
                                State
    //////////////////////////////////////////////////////////////*/

    address public immutable accountImplementation;
    address public immutable entrypoint;

    /*///////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/

    constructor(address _accountImpl, address _entrypoint) {
        accountImplementation = _accountImpl;
        entrypoint = _entrypoint;
    }

    /*///////////////////////////////////////////////////////////////
                        External functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys a new Account for admin.
    function createAccount(address _admin, bytes calldata _data) external virtual override returns (address) {
        address impl = accountImplementation;
        bytes32 salt = _generateSalt(_admin, _data);
        address account = Clones.predictDeterministicAddress(impl, salt);

        if (account.code.length > 0) {
            return account;
        }

        account = Clones.cloneDeterministic(impl, salt);

        if (msg.sender != entrypoint) {
            require(
                _baseAccountFactoryStorage().allAccounts.add(account),
                "AccountFactory: account already registered"
            );
        }

        _initializeAccount(account, _admin, _data);

        emit AccountCreated(account, _admin);

        return account;
    }

    /// @notice Callback function for an Account to register itself on the factory.
    function onRegister(bytes32 _salt) external {
        address account = msg.sender;
        require(_isAccountOfFactory(account, _salt), "AccountFactory: not an account.");

        require(_baseAccountFactoryStorage().allAccounts.add(account), "AccountFactory: account already registered");
    }

    function onSignerAdded(address _signer, bytes32 _salt) external {
        address account = msg.sender;
        require(_isAccountOfFactory(account, _salt), "AccountFactory: not an account.");

        bool isNewSigner = _baseAccountFactoryStorage().accountsOfSigner[_signer].add(account);

        if (isNewSigner) {
            emit SignerAdded(account, _signer);
        }
    }

    /// @notice Callback function for an Account to un-register its signers.
    function onSignerRemoved(address _signer, bytes32 _salt) external {
        address account = msg.sender;
        require(_isAccountOfFactory(account, _salt), "AccountFactory: not an account.");

        bool isAccount = _baseAccountFactoryStorage().accountsOfSigner[_signer].remove(account);

        if (isAccount) {
            emit SignerRemoved(account, _signer);
        }
    }

    /*///////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns whether an account is registered on this factory.
    function isRegistered(address _account) external view returns (bool) {
        return _baseAccountFactoryStorage().allAccounts.contains(_account);
    }

    /// @notice Returns all accounts created on the factory.
    function getAllAccounts() external view returns (address[] memory) {
        return _baseAccountFactoryStorage().allAccounts.values();
    }

    /// @notice Returns the address of an Account that would be deployed with the given admin signer.
    function getAddress(address _adminSigner, bytes calldata _data) public view returns (address) {
        bytes32 salt = _generateSalt(_adminSigner, _data);
        return Clones.predictDeterministicAddress(accountImplementation, salt);
    }

    /// @notice Returns all accounts that the given address is a signer of.
    function getAccountsOfSigner(address signer) external view returns (address[] memory accounts) {
        return _baseAccountFactoryStorage().accountsOfSigner[signer].values();
    }

    /*///////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns whether the caller is an account deployed by this factory.
    function _isAccountOfFactory(address _account, bytes32 _salt) internal view virtual returns (bool) {
        address predicted = Clones.predictDeterministicAddress(accountImplementation, _salt);
        return _account == predicted;
    }

    function _getImplementation(address cloneAddress) internal view returns (address) {
        bytes memory code = cloneAddress.code;
        return BytesLib.toAddress(code, 10);
    }

    /// @dev Returns the salt used when deploying an Account.
    function _generateSalt(address _admin, bytes memory _data) internal view virtual returns (bytes32) {
        return keccak256(abi.encode(_admin, _data));
    }

    /// @dev Returns the BaseAccountFactory contract's storage.
    function _baseAccountFactoryStorage() internal pure returns (BaseAccountFactoryStorage.Data storage) {
        return BaseAccountFactoryStorage.data();
    }

    /// @dev Called in `createAccount`. Initializes the account contract created in `createAccount`.
    function _initializeAccount(
        address _account,
        address _admin,
        bytes calldata _data
    ) internal virtual;
}
