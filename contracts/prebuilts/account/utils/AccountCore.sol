// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

/* solhint-disable avoid-low-level-calls */
/* solhint-disable no-inline-assembly */
/* solhint-disable reason-string */

// Base
import "./BaseAccount.sol";

// Fixed Extensions
import "../../../extension/Multicall.sol";
import "../../../extension/upgradeable/Initializable.sol";
import "../../../extension/upgradeable/AccountPermissions.sol";

// Utils
import "./Helpers.sol";
import "./AccountCoreStorage.sol";
import "./BaseAccountFactory.sol";
import { AccountExtension } from "./AccountExtension.sol";
import "../../../external-deps/openzeppelin/utils/cryptography/ECDSA.sol";

import "../interfaces/IAccountCore.sol";

//   $$\     $$\       $$\                 $$\                         $$\
//   $$ |    $$ |      \__|                $$ |                        $$ |
// $$$$$$\   $$$$$$$\  $$\  $$$$$$\   $$$$$$$ |$$\  $$\  $$\  $$$$$$\  $$$$$$$\
// \_$$  _|  $$  __$$\ $$ |$$  __$$\ $$  __$$ |$$ | $$ | $$ |$$  __$$\ $$  __$$\
//   $$ |    $$ |  $$ |$$ |$$ |  \__|$$ /  $$ |$$ | $$ | $$ |$$$$$$$$ |$$ |  $$ |
//   $$ |$$\ $$ |  $$ |$$ |$$ |      $$ |  $$ |$$ | $$ | $$ |$$   ____|$$ |  $$ |
//   \$$$$  |$$ |  $$ |$$ |$$ |      \$$$$$$$ |\$$$$$\$$$$  |\$$$$$$$\ $$$$$$$  |
//    \____/ \__|  \__|\__|\__|       \_______| \_____\____/  \_______|\_______/

contract AccountCore is IAccountCore, Initializable, Multicall, BaseAccount, AccountPermissions {
    using ECDSA for bytes32;
    using EnumerableSet for EnumerableSet.AddressSet;

    /*///////////////////////////////////////////////////////////////
                                State
    //////////////////////////////////////////////////////////////*/

    /// @notice EIP 4337 factory for this contract.
    address public immutable factory;

    /// @notice EIP 4337 Entrypoint contract.
    IEntryPoint private immutable entrypointContract;

    /*///////////////////////////////////////////////////////////////
                    Constructor, Initializer, Modifiers
    //////////////////////////////////////////////////////////////*/

    constructor(IEntryPoint _entrypoint, address _factory) EIP712("Account", "1") {
        _disableInitializers();
        factory = _factory;
        entrypointContract = _entrypoint;
    }

    /// @notice Initializes the smart contract wallet.
    function initialize(address _defaultAdmin, bytes calldata _data) public virtual initializer {
        // This is passed as data in the `_registerOnFactory()` call in `AccountExtension` / `Account`.
        AccountCoreStorage.data().creationSalt = _generateSalt(_defaultAdmin, _data);
        _setAdmin(_defaultAdmin, true);
    }

    /*///////////////////////////////////////////////////////////////
                            View functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns the EIP 4337 entrypoint contract.
    function entryPoint() public view virtual override returns (IEntryPoint) {
        address entrypointOverride = AccountCoreStorage.data().entrypointOverride;
        if (address(entrypointOverride) != address(0)) {
            return IEntryPoint(entrypointOverride);
        }
        return entrypointContract;
    }

    /**
    @notice Returns whether a signer is authorized to perform transactions using the account.
            Validity of the signature is based upon signer permission start/end timestamps, txn target, and txn value.
            Account admins will always return true, and signers with address(0) as the only approved target will skip target checks.

    @param _signer The signer to check.
    @param _userOp The user operation to check.

    @return Whether the signer is authorized to perform the transaction.
    */

    /* solhint-disable*/
    function isValidSigner(address _signer, PackedUserOperation calldata _userOp) public view virtual returns (bool) {
        // First, check if the signer is an admin.
        if (_accountPermissionsStorage().isAdmin[_signer]) {
            return true;
        }

        SignerPermissionsStatic memory permissions = _accountPermissionsStorage().signerPermissions[_signer];
        EnumerableSet.AddressSet storage approvedTargets = _accountPermissionsStorage().approvedTargets[_signer];

        // If not an admin, check if the signer is active.
        if (
            permissions.startTimestamp > block.timestamp ||
            block.timestamp >= permissions.endTimestamp ||
            approvedTargets.length() == 0
        ) {
            // Account: no active permissions.
            return false;
        }

        // Extract the function signature from the userOp calldata and check whether the signer is attempting to call `execute` or `executeBatch`.
        bytes4 sig = getFunctionSignature(_userOp.callData);

        // if address(0) is the only approved target, set isWildCard to true (wildcard approved).
        bool isWildCard = approvedTargets.length() == 1 && approvedTargets.at(0) == address(0);

        // checking target and value for `execute`
        if (sig == AccountExtension.execute.selector) {
            // Extract the `target` and `value` arguments from the calldata for `execute`.
            (address target, uint256 value) = decodeExecuteCalldata(_userOp.callData);

            // if wildcard target is not approved, check that the target is in the approvedTargets set.
            if (!isWildCard) {
                // Check if the target is approved.
                if (!approvedTargets.contains(target)) {
                    // Account: target not approved.
                    return false;
                }
            }

            // Check if the value is within the allowed range.
            if (permissions.nativeTokenLimitPerTransaction < value) {
                // Account: value too high OR Account: target not approved.
                return false;
            }
        }
        // checking target and value for `executeBatch`
        else if (sig == AccountExtension.executeBatch.selector) {
            // Extract the `target` and `value` array arguments from the calldata for `executeBatch`.
            (address[] memory targets, uint256[] memory values, ) = decodeExecuteBatchCalldata(_userOp.callData);

            // if wildcard target is not approved, check that the targets are in the approvedTargets set.
            if (!isWildCard) {
                for (uint256 i = 0; i < targets.length; i++) {
                    if (!approvedTargets.contains(targets[i])) {
                        // If any target is not approved, break the loop.
                        return false;
                    }
                }
            }

            // For each target+value pair, check if the value is within the allowed range.
            for (uint256 i = 0; i < targets.length; i++) {
                if (permissions.nativeTokenLimitPerTransaction < values[i]) {
                    // Account: value too high OR Account: target not approved.
                    return false;
                }
            }
        } else {
            // Account: calling invalid fn.
            return false;
        }

        return true;
    }

    /* solhint-enable */

    /*///////////////////////////////////////////////////////////////
                            External functions
    //////////////////////////////////////////////////////////////*/

    /// @notice Overrides the Entrypoint contract being used.
    function setEntrypointOverride(IEntryPoint _entrypointOverride) public virtual {
        _onlyAdmin();
        AccountCoreStorage.data().entrypointOverride = address(_entrypointOverride);
    }

    /*///////////////////////////////////////////////////////////////
                        Internal functions
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the salt used when deploying an Account.
    function _generateSalt(address _admin, bytes memory _data) internal view virtual returns (bytes32) {
        return keccak256(abi.encode(_admin, _data));
    }

    function getFunctionSignature(bytes calldata data) internal pure returns (bytes4 functionSelector) {
        require(data.length >= 4, "!Data");
        return bytes4(data[:4]);
    }

    function decodeExecuteCalldata(bytes calldata data) internal pure returns (address _target, uint256 _value) {
        require(data.length >= 4 + 32 + 32, "!Data");

        // Decode the address, which is bytes 4 to 35
        _target = abi.decode(data[4:36], (address));

        // Decode the value, which is bytes 36 to 68
        _value = abi.decode(data[36:68], (uint256));
    }

    function decodeExecuteBatchCalldata(
        bytes calldata data
    ) internal pure returns (address[] memory _targets, uint256[] memory _values, bytes[] memory _callData) {
        require(data.length >= 4 + 32 + 32 + 32, "!Data");

        (_targets, _values, _callData) = abi.decode(data[4:], (address[], uint256[], bytes[]));
    }

    /// @notice Validates the signature of a user operation.
    function _validateSignature(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash
    ) internal virtual override returns (uint256 validationData) {
        bytes32 hash = userOpHash.toEthSignedMessageHash();
        address signer = hash.recover(userOp.signature);

        if (!isValidSigner(signer, userOp)) return SIG_VALIDATION_FAILED;

        SignerPermissionsStatic memory permissions = _accountPermissionsStorage().signerPermissions[signer];

        uint48 validAfter = uint48(permissions.startTimestamp);
        uint48 validUntil = uint48(permissions.endTimestamp);

        return _packValidationData(ValidationData(address(0), validAfter, validUntil));
    }

    /// @notice Makes the given account an admin.
    function _setAdmin(address _account, bool _isAdmin) internal virtual override {
        super._setAdmin(_account, _isAdmin);
        if (factory.code.length > 0) {
            if (_isAdmin) {
                BaseAccountFactory(factory).onSignerAdded(_account, AccountCoreStorage.data().creationSalt);
            } else {
                BaseAccountFactory(factory).onSignerRemoved(_account, AccountCoreStorage.data().creationSalt);
            }
        }
    }

    /// @notice Runs after every `changeRole` run.
    function _afterSignerPermissionsUpdate(SignerPermissionRequest calldata _req) internal virtual override {
        if (factory.code.length > 0) {
            BaseAccountFactory(factory).onSignerAdded(_req.signer, AccountCoreStorage.data().creationSalt);
        }
    }
}
