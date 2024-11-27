// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

// Test utils
import "../utils/BaseTest.sol";
import "@thirdweb-dev/dynamic-contracts/src/interface/IExtension.sol";
import { IAccountPermissions } from "contracts/extension/interface/IAccountPermissions.sol";
import { AccountPermissions } from "contracts/extension/upgradeable/AccountPermissions.sol";
import { AccountExtension } from "contracts/prebuilts/account/utils/AccountExtension.sol";

// Account Abstraction setup for smart wallets.
import { EntryPoint, IEntryPoint } from "contracts/prebuilts/account/utils/Entrypoint.sol";
import { UserOperation } from "contracts/prebuilts/account/utils/UserOperation.sol";

// Target
import { Account as SimpleAccount } from "contracts/prebuilts/account/non-upgradeable/Account.sol";
import { DynamicAccountFactory, DynamicAccount } from "contracts/prebuilts/account/dynamic/DynamicAccountFactory.sol";

/// @dev This is a dummy contract to test contract interactions with Account.
contract Number {
    uint256 public num;

    function setNum(uint256 _num) public {
        num = _num;
    }

    function doubleNum() public {
        num *= 2;
    }

    function incrementNum() public {
        num += 1;
    }
}

contract NFTRejector {
    function onERC721Received(address, address, uint256, bytes memory) public virtual returns (bytes4) {
        revert("NFTs not accepted");
    }
}

contract DynamicAccountBenchmarkTest is BaseTest {
    // Target contracts
    EntryPoint private entrypoint;
    DynamicAccountFactory private accountFactory;

    // Mocks
    Number internal numberContract;

    // Test params
    uint256 private accountAdminPKey = 100;
    address private accountAdmin;

    uint256 private accountSignerPKey = 200;
    address private accountSigner;

    uint256 private nonSignerPKey = 300;
    address private nonSigner;

    bytes internal data = bytes("");

    // UserOp terminology: `sender` is the smart wallet.
    address private sender = 0xbC12AEae5E1b1a80401dd20A6728f7a01a3A6166;
    address payable private beneficiary = payable(address(0x45654));

    bytes32 private uidCache = bytes32("random uid");

    event AccountCreated(address indexed account, address indexed accountAdmin);

    function _signSignerPermissionRequest(
        IAccountPermissions.SignerPermissionRequest memory _req
    ) internal view returns (bytes memory signature) {
        bytes32 typehashSignerPermissionRequest = keccak256(
            "SignerPermissionRequest(address signer,uint8 isAdmin,address[] approvedTargets,uint256 nativeTokenLimitPerTransaction,uint128 permissionStartTimestamp,uint128 permissionEndTimestamp,uint128 reqValidityStartTimestamp,uint128 reqValidityEndTimestamp,bytes32 uid)"
        );
        bytes32 nameHash = keccak256(bytes("Account"));
        bytes32 versionHash = keccak256(bytes("1"));
        bytes32 typehashEip712 = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        bytes32 domainSeparator = keccak256(abi.encode(typehashEip712, nameHash, versionHash, block.chainid, sender));

        bytes memory encodedRequestStart = abi.encode(
            typehashSignerPermissionRequest,
            _req.signer,
            _req.isAdmin,
            keccak256(abi.encodePacked(_req.approvedTargets)),
            _req.nativeTokenLimitPerTransaction
        );

        bytes memory encodedRequestEnd = abi.encode(
            _req.permissionStartTimestamp,
            _req.permissionEndTimestamp,
            _req.reqValidityStartTimestamp,
            _req.reqValidityEndTimestamp,
            _req.uid
        );

        bytes32 structHash = keccak256(bytes.concat(encodedRequestStart, encodedRequestEnd));
        bytes32 typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(accountAdminPKey, typedDataHash);
        signature = abi.encodePacked(r, s, v);
    }

    function _setupUserOp(
        uint256 _signerPKey,
        bytes memory _initCode,
        bytes memory _callDataForEntrypoint
    ) internal returns (UserOperation[] memory ops) {
        uint256 nonce = entrypoint.getNonce(sender, 0);

        // Get user op fields
        UserOperation memory op = UserOperation({
            sender: sender,
            nonce: nonce,
            initCode: _initCode,
            callData: _callDataForEntrypoint,
            callGasLimit: 5_000_000,
            verificationGasLimit: 5_000_000,
            preVerificationGas: 5_000_000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: bytes(""),
            signature: bytes("")
        });

        // Sign UserOp
        bytes32 opHash = EntryPoint(entrypoint).getUserOpHash(op);
        bytes32 msgHash = ECDSA.toEthSignedMessageHash(opHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPKey, msgHash);
        bytes memory userOpSignature = abi.encodePacked(r, s, v);

        address recoveredSigner = ECDSA.recover(msgHash, v, r, s);
        address expectedSigner = vm.addr(_signerPKey);
        assertEq(recoveredSigner, expectedSigner);

        op.signature = userOpSignature;

        // Store UserOp
        ops = new UserOperation[](1);
        ops[0] = op;
    }

    function _setupUserOpExecute(
        uint256 _signerPKey,
        bytes memory _initCode,
        address _target,
        uint256 _value,
        bytes memory _callData
    ) internal returns (UserOperation[] memory) {
        bytes memory callDataForEntrypoint = abi.encodeWithSignature(
            "execute(address,uint256,bytes)",
            _target,
            _value,
            _callData
        );

        return _setupUserOp(_signerPKey, _initCode, callDataForEntrypoint);
    }

    function _setupUserOpExecuteBatch(
        uint256 _signerPKey,
        bytes memory _initCode,
        address[] memory _target,
        uint256[] memory _value,
        bytes[] memory _callData
    ) internal returns (UserOperation[] memory) {
        bytes memory callDataForEntrypoint = abi.encodeWithSignature(
            "executeBatch(address[],uint256[],bytes[])",
            _target,
            _value,
            _callData
        );

        return _setupUserOp(_signerPKey, _initCode, callDataForEntrypoint);
    }

    function setUp() public override {
        super.setUp();

        // Setup signers.
        accountAdmin = vm.addr(accountAdminPKey);
        vm.deal(accountAdmin, 100 ether);

        accountSigner = vm.addr(accountSignerPKey);
        nonSigner = vm.addr(nonSignerPKey);

        // Setup contracts
        entrypoint = new EntryPoint();

        // Setting up default extension.
        IExtension.Extension memory defaultExtension;

        defaultExtension.metadata = IExtension.ExtensionMetadata({
            name: "AccountExtension",
            metadataURI: "ipfs://AccountExtension",
            implementation: address(new AccountExtension())
        });

        defaultExtension.functions = new IExtension.ExtensionFunction[](7);

        defaultExtension.functions[0] = IExtension.ExtensionFunction(
            AccountExtension.supportsInterface.selector,
            "supportsInterface(bytes4)"
        );
        defaultExtension.functions[1] = IExtension.ExtensionFunction(
            AccountExtension.execute.selector,
            "execute(address,uint256,bytes)"
        );
        defaultExtension.functions[2] = IExtension.ExtensionFunction(
            AccountExtension.executeBatch.selector,
            "executeBatch(address[],uint256[],bytes[])"
        );
        defaultExtension.functions[3] = IExtension.ExtensionFunction(
            ERC721Holder.onERC721Received.selector,
            "onERC721Received(address,address,uint256,bytes)"
        );
        defaultExtension.functions[4] = IExtension.ExtensionFunction(
            ERC1155Holder.onERC1155Received.selector,
            "onERC1155Received(address,address,uint256,uint256,bytes)"
        );
        defaultExtension.functions[5] = IExtension.ExtensionFunction(
            bytes4(0), // Selector for `receive()` function.
            "receive()"
        );
        defaultExtension.functions[6] = IExtension.ExtensionFunction(
            AccountExtension.isValidSignature.selector,
            "isValidSignature(bytes32,bytes)"
        );

        IExtension.Extension[] memory extensions = new IExtension.Extension[](1);
        extensions[0] = defaultExtension;

        // deploy account factory
        accountFactory = new DynamicAccountFactory(deployer, extensions);
        // deploy dummy contract
        numberContract = new Number();
    }

    /*///////////////////////////////////////////////////////////////
                        Test: creating an account
    //////////////////////////////////////////////////////////////*/

    /// @dev benchmark test for deployment gas cost
    function test_deploy_dynamicAccount() public {
        vm.pauseGasMetering();
        // Setting up default extension.
        IExtension.Extension memory defaultExtension;

        defaultExtension.metadata = IExtension.ExtensionMetadata({
            name: "AccountExtension",
            metadataURI: "ipfs://AccountExtension",
            implementation: address(new AccountExtension())
        });

        defaultExtension.functions = new IExtension.ExtensionFunction[](7);

        defaultExtension.functions[0] = IExtension.ExtensionFunction(
            AccountExtension.supportsInterface.selector,
            "supportsInterface(bytes4)"
        );
        defaultExtension.functions[1] = IExtension.ExtensionFunction(
            AccountExtension.execute.selector,
            "execute(address,uint256,bytes)"
        );
        defaultExtension.functions[2] = IExtension.ExtensionFunction(
            AccountExtension.executeBatch.selector,
            "executeBatch(address[],uint256[],bytes[])"
        );
        defaultExtension.functions[3] = IExtension.ExtensionFunction(
            ERC721Holder.onERC721Received.selector,
            "onERC721Received(address,address,uint256,bytes)"
        );
        defaultExtension.functions[4] = IExtension.ExtensionFunction(
            ERC1155Holder.onERC1155Received.selector,
            "onERC1155Received(address,address,uint256,uint256,bytes)"
        );
        defaultExtension.functions[5] = IExtension.ExtensionFunction(
            bytes4(0), // Selector for `receive()` function.
            "receive()"
        );
        defaultExtension.functions[6] = IExtension.ExtensionFunction(
            AccountExtension.isValidSignature.selector,
            "isValidSignature(bytes32,bytes)"
        );

        IExtension.Extension[] memory extensions = new IExtension.Extension[](1);
        extensions[0] = defaultExtension;

        vm.resumeGasMetering();
        // deploy account factory
        DynamicAccountFactory factory = new DynamicAccountFactory(deployer, extensions);
    }

    /// @dev Create an account by directly calling the factory.
    function test_state_createAccount_viaFactory() public {
        accountFactory.createAccount(accountAdmin, data);
    }

    /// @dev Create an account via Entrypoint.
    function test_state_createAccount_viaEntrypoint() public {
        vm.pauseGasMetering();
        bytes memory initCallData = abi.encodeWithSignature("createAccount(address,bytes)", accountAdmin, data);
        bytes memory initCode = abi.encodePacked(abi.encodePacked(address(accountFactory)), initCallData);

        vm.resumeGasMetering();
        UserOperation[] memory userOpCreateAccount = _setupUserOpExecute(
            accountAdminPKey,
            initCode,
            address(0),
            0,
            bytes("")
        );

        EntryPoint(entrypoint).handleOps(userOpCreateAccount, beneficiary);
    }

    /*///////////////////////////////////////////////////////////////
                    Test: performing a contract call
    //////////////////////////////////////////////////////////////*/

    function _setup_executeTransaction() internal {
        vm.pauseGasMetering();
        bytes memory initCallData = abi.encodeWithSignature("createAccount(address,bytes)", accountAdmin, data);
        bytes memory initCode = abi.encodePacked(abi.encodePacked(address(accountFactory)), initCallData);

        vm.resumeGasMetering();
        UserOperation[] memory userOpCreateAccount = _setupUserOpExecute(
            accountAdminPKey,
            initCode,
            address(0),
            0,
            bytes("")
        );

        EntryPoint(entrypoint).handleOps(userOpCreateAccount, beneficiary);
    }

    /// @dev Perform a state changing transaction directly via account.
    function test_state_executeTransaction() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        vm.resumeGasMetering();
        vm.prank(accountAdmin);
        SimpleAccount(payable(account)).execute(
            address(numberContract),
            0,
            abi.encodeWithSignature("setNum(uint256)", 42)
        );
    }

    /// @dev Perform many state changing transactions in a batch directly via account.
    function test_state_executeBatchTransaction() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        uint256 count = 3;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        for (uint256 i = 0; i < count; i += 1) {
            targets[i] = address(numberContract);
            values[i] = 0;
            callData[i] = abi.encodeWithSignature("incrementNum()", i);
        }

        vm.resumeGasMetering();
        vm.prank(accountAdmin);
        SimpleAccount(payable(account)).executeBatch(targets, values, callData);
    }

    /// @dev Perform a state changing transaction via Entrypoint.
    function test_state_executeTransaction_viaEntrypoint() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();

        vm.resumeGasMetering();
        UserOperation[] memory userOp = _setupUserOpExecute(
            accountAdminPKey,
            bytes(""),
            address(numberContract),
            0,
            abi.encodeWithSignature("setNum(uint256)", 42)
        );

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);
    }

    /// @dev Perform many state changing transactions in a batch via Entrypoint.
    function test_state_executeBatchTransaction_viaEntrypoint() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();

        uint256 count = 3;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        for (uint256 i = 0; i < count; i += 1) {
            targets[i] = address(numberContract);
            values[i] = 0;
            callData[i] = abi.encodeWithSignature("incrementNum()", i);
        }

        vm.resumeGasMetering();
        UserOperation[] memory userOp = _setupUserOpExecuteBatch(
            accountAdminPKey,
            bytes(""),
            targets,
            values,
            callData
        );

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);
    }

    /// @dev Perform many state changing transactions in a batch via Entrypoint.
    function test_state_executeBatchTransaction_viaAccountSigner() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();

        uint256 count = 3;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        for (uint256 i = 0; i < count; i += 1) {
            targets[i] = address(numberContract);
            values[i] = 0;
            callData[i] = abi.encodeWithSignature("incrementNum()", i);
        }

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        address[] memory approvedTargets = new address[](1);
        approvedTargets[0] = address(numberContract);

        IAccountPermissions.SignerPermissionRequest memory permissionsReq = IAccountPermissions.SignerPermissionRequest(
            accountSigner,
            0,
            approvedTargets,
            1 ether,
            0,
            type(uint128).max,
            0,
            type(uint128).max,
            uidCache
        );

        vm.resumeGasMetering();
        vm.prank(accountAdmin);
        bytes memory sig = _signSignerPermissionRequest(permissionsReq);
        SimpleAccount(payable(account)).setPermissionsForSigner(permissionsReq, sig);

        UserOperation[] memory userOp = _setupUserOpExecuteBatch(
            accountSignerPKey,
            bytes(""),
            targets,
            values,
            callData
        );

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);
    }

    /// @dev Perform a state changing transaction via Entrypoint and a SIGNER_ROLE holder.
    function test_state_executeTransaction_viaAccountSigner() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        address[] memory approvedTargets = new address[](1);
        approvedTargets[0] = address(numberContract);

        IAccountPermissions.SignerPermissionRequest memory permissionsReq = IAccountPermissions.SignerPermissionRequest(
            accountSigner,
            0,
            approvedTargets,
            1 ether,
            0,
            type(uint128).max,
            0,
            type(uint128).max,
            uidCache
        );

        vm.resumeGasMetering();
        vm.prank(accountAdmin);
        bytes memory sig = _signSignerPermissionRequest(permissionsReq);
        SimpleAccount(payable(account)).setPermissionsForSigner(permissionsReq, sig);

        UserOperation[] memory userOp = _setupUserOpExecute(
            accountSignerPKey,
            bytes(""),
            address(numberContract),
            0,
            abi.encodeWithSignature("setNum(uint256)", 42)
        );

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);
    }

    /*///////////////////////////////////////////////////////////////
                Test: receiving and sending native tokens
    //////////////////////////////////////////////////////////////*/

    /// @dev Send native tokens to an account.
    function test_state_accountReceivesNativeTokens() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        vm.resumeGasMetering();
        vm.prank(accountAdmin);
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory ret) = payable(account).call{ value: 1000 }("");
    }

    /// @dev Transfer native tokens out of an account.
    function test_state_transferOutsNativeTokens() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();

        uint256 value = 1000;

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        vm.prank(accountAdmin);
        // solhint-disable-next-line avoid-low-level-calls
        (bool success, bytes memory ret) = payable(account).call{ value: value }("");

        address recipient = address(0x3456);

        vm.resumeGasMetering();
        UserOperation[] memory userOp = _setupUserOpExecute(accountAdminPKey, bytes(""), recipient, value, bytes(""));

        EntryPoint(entrypoint).handleOps(userOp, beneficiary);
    }

    /// @dev Add and remove a deposit for the account from the Entrypoint.

    function test_state_addAndWithdrawDeposit() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();

        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        vm.resumeGasMetering();
        vm.startPrank(accountAdmin);
        SimpleAccount(payable(account)).addDeposit{ value: 1000 }();
        SimpleAccount(payable(account)).withdrawDepositTo(payable(accountSigner), 500);
        vm.stopPrank();
    }

    /*///////////////////////////////////////////////////////////////
                Test: receiving ERC-721 and ERC-1155 NFTs
    //////////////////////////////////////////////////////////////*/

    /// @dev Send an ERC-721 NFT to an account.
    function test_state_receiveERC721NFT() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();
        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        vm.resumeGasMetering();
        erc721.mint(account, 1);
    }

    /// @dev Send an ERC-1155 NFT to an account.
    function test_state_receiveERC1155NFT() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();
        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        vm.resumeGasMetering();
        erc1155.mint(account, 0, 1);
    }

    /*///////////////////////////////////////////////////////////////
                Test: change an extension on the account
    //////////////////////////////////////////////////////////////*/

    /// @dev Make the account reject ERC-721 NFTs instead of accepting them.
    function test_scenario_changeExtensionForFunction() public {
        vm.pauseGasMetering();
        _setup_executeTransaction();
        address account = accountFactory.getAddress(accountAdmin, bytes(""));

        // The account can initially receive NFTs.
        erc721.mint(account, 1);

        // Make the account reject ERC-721 NFTs going forward.
        IExtension.Extension memory extension;

        extension.metadata = IExtension.ExtensionMetadata({
            name: "NFTRejector",
            metadataURI: "ipfs://NFTRejector",
            implementation: address(new NFTRejector())
        });

        extension.functions = new IExtension.ExtensionFunction[](1);

        extension.functions[0] = IExtension.ExtensionFunction(
            NFTRejector.onERC721Received.selector,
            "onERC721Received(address,address,uint256,bytes)"
        );

        vm.resumeGasMetering();
        vm.startPrank(accountAdmin);
        DynamicAccount(payable(account)).disableFunctionInExtension(
            "AccountExtension",
            NFTRejector.onERC721Received.selector
        );

        DynamicAccount(payable(account)).addExtension(extension);
        vm.stopPrank();
    }
}
