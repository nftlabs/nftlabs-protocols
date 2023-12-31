// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.12;

// Utils
import "../../../extension/Multicall.sol";
import "../../../external-deps/openzeppelin/proxy/Clones.sol";
import "../../../external-deps/openzeppelin/utils/structs/EnumerableSet.sol";
import "../utils/BaseAccount.sol";
import "../../../extension/interface/IAccountPermissions.sol";
import "../../../lib/BytesLib.sol";
import "forge-std/console.sol";

// Interface
import "../interface/IEntrypoint.sol";
import "../interface/IAccountFactory.sol";

import { AccountLock } from "../utils/AccountLock.sol";
import { Guardian } from "../utils/Guardian.sol";
import { AccountGuardian } from "../utils/AccountGuardian.sol";
import { AccountRecovery } from "../utils/AccountRecovery.sol";

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

    // Events //

    event GuardianContractDeployed(address indexed);
    event AccountLockContractDeployed(address indexed);
    event AccountGuardianContractDeployed(address indexed);
    event SmartAccountContractDeployed(address indexed);
    event AccountRecoveryContractDeployed(address indexed);
    /*///////////////////////////////////////////////////////////////
                                State
    //////////////////////////////////////////////////////////////*/

    address public immutable accountImplementation;
    address public immutable entrypoint;
    address private constant emailService = address(0xa0Ee7A142d267C1f36714E4a8F75612F20a79720); // TODO: To be updated with the wallet address of the actual email service
    Guardian public guardian;
    AccountLock public accountLock;
    AccountGuardian public accountGuardian;
    AccountRecovery public accountRecovery;
    EnumerableSet.AddressSet private allAccounts;
    mapping(address => EnumerableSet.AddressSet) internal accountsOfSigner;

    /*///////////////////////////////////////////////////////////////
                            Constructor
    //////////////////////////////////////////////////////////////*/

    constructor(address _accountImpl, address _entrypoint) {
        accountImplementation = _accountImpl;
        entrypoint = _entrypoint;
        guardian = new Guardian();
        accountLock = new AccountLock(guardian);

        // emit the contract addresses
        emit SmartAccountContractDeployed(_accountImpl);
        emit GuardianContractDeployed(address(guardian));
        emit AccountLockContractDeployed(address(accountLock));
    }

    /*///////////////////////////////////////////////////////////////
                        External functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Deploys a new Account for admin.
    function createAccount(address _admin, bytes calldata _data) external virtual override returns (address) {
        address impl = accountImplementation;
        string memory recoveryEmail = abi.decode(_data, (string));
        console.log("Decoded Email when creating account:", recoveryEmail);

        bytes32 salt = _generateSalt(_admin, _data);

        address account = Clones.predictDeterministicAddress(impl, salt);

        if (account.code.length > 0) {
            return account;
        }

        account = Clones.cloneDeterministic(impl, salt);

        if (msg.sender != entrypoint) {
            require(allAccounts.add(account), "AccountFactory: account already registered");
        }

        _initializeAccount(account, _admin, address(guardian), _data);
        emit AccountCreated(account, _admin);

        accountGuardian = new AccountGuardian(guardian, accountLock, account, emailService, recoveryEmail);

        guardian.linkAccountToAccountGuardian(account, address(accountGuardian));

        emit AccountGuardianContractDeployed(address(accountGuardian));

        return account;
    }

    /// @notice Callback function for an Account to register itself on the factory.
    function onRegister(address _defaultAdmin, bytes memory _data) external {
        address account = msg.sender;
        require(_isAccountOfFactory(account, _defaultAdmin, _data), "AccountFactory: not an account.");

        require(allAccounts.add(account), "AccountFactory: account already registered");
    }

    function onSignerAdded(address _signer, address _defaultAdmin, bytes memory _data) external {
        address account = msg.sender;
        require(_isAccountOfFactory(account, _defaultAdmin, _data), "AccountFactory: not an account.");

        bool isNewSigner = accountsOfSigner[_signer].add(account);

        if (isNewSigner) {
            emit SignerAdded(account, _signer);
        }
    }

    /// @notice Callback function for an Account to un-register its signers.
    function onSignerRemoved(address _signer, address _defaultAdmin, bytes memory _data) external {
        address account = msg.sender;
        require(_isAccountOfFactory(account, _defaultAdmin, _data), "AccountFactory: not an account.");

        bool isAccount = accountsOfSigner[_signer].remove(account);

        if (isAccount) {
            emit SignerRemoved(account, _signer);
        }
    }

    /*///////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns whether an account is registered on this factory.
    function isRegistered(address _account) external view returns (bool) {
        return allAccounts.contains(_account);
    }

    /// @notice Returns all accounts created on the factory.
    function getAllAccounts() external view returns (address[] memory) {
        return allAccounts.values();
    }

    /// @notice Returns the address of an Account that would be deployed with the given admin signer.
    function getAddress(address _adminSigner, bytes calldata _data) public view returns (address) {
        bytes32 salt = _generateSalt(_adminSigner, _data);
        return Clones.predictDeterministicAddress(accountImplementation, salt);
    }

    /// @notice Returns all accounts that the given address is a signer of.
    function getAccountsOfSigner(address signer) external view returns (address[] memory accounts) {
        return accountsOfSigner[signer].values();
    }

    /*///////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns whether the caller is an account deployed by this factory.
    function _isAccountOfFactory(
        address _account,
        address _admin,
        bytes memory _data
    ) internal view virtual returns (bool) {
        bytes32 salt = _generateSalt(_admin, _data);
        address predicted = Clones.predictDeterministicAddress(accountImplementation, salt);
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

    /// @dev Called in `createAccount`. Initializes the account contract created in `createAccount`.
    function _initializeAccount(
        address _account,
        address _admin,
        address guardian,
        bytes calldata _data
    ) internal virtual;
}
