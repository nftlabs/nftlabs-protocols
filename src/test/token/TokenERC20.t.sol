// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

import { TokenERC20 } from "contracts/prebuilts/token/TokenERC20.sol";

// Test imports

import "../utils/BaseTest.sol";
import "@openzeppelin/contracts-upgradeable/utils/StringsUpgradeable.sol";

contract TokenERC20Test is BaseTest {
    using Strings for uint256;

    event TokensMinted(address indexed mintedTo, uint256 quantityMinted);
    event TokensMintedWithSignature(
        address indexed signer,
        address indexed mintedTo,
        TokenERC20.MintRequest mintRequest
    );

    event PrimarySaleRecipientUpdated(address indexed recipient);
    event PlatformFeeInfoUpdated(address indexed platformFeeRecipient, uint256 platformFeeBps);

    TokenERC20 public tokenContract;
    bytes32 internal typehashMintRequest;
    bytes32 internal nameHash;
    bytes32 internal versionHash;
    bytes32 internal typehashEip712;
    bytes32 internal domainSeparator;
    bytes32 internal permitTypehash;

    bytes private emptyEncodedBytes = abi.encode("", "");

    TokenERC20.MintRequest _mintrequest;
    bytes _signature;

    address internal deployerSigner;
    address internal recipient;

    using stdStorage for StdStorage;

    function setUp() public override {
        super.setUp();
        deployerSigner = signer;
        recipient = address(0x123);
        tokenContract = TokenERC20(getContract("TokenERC20"));

        erc20.mint(deployerSigner, 1_000);
        vm.deal(deployerSigner, 1_000);

        erc20.mint(recipient, 1_000);
        vm.deal(recipient, 1_000);

        typehashMintRequest = keccak256(
            "MintRequest(address to,address primarySaleRecipient,uint256 quantity,uint256 price,address currency,uint128 validityStartTimestamp,uint128 validityEndTimestamp,bytes32 uid)"
        );
        nameHash = keccak256(bytes(NAME));
        versionHash = keccak256(bytes("1"));
        typehashEip712 = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        domainSeparator = keccak256(
            abi.encode(typehashEip712, nameHash, versionHash, block.chainid, address(tokenContract))
        );
        permitTypehash = keccak256(
            "Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)"
        );

        // construct default mintrequest
        _mintrequest.to = recipient;
        _mintrequest.primarySaleRecipient = saleRecipient;
        _mintrequest.quantity = 100;
        _mintrequest.price = 0;
        _mintrequest.currency = address(0);
        _mintrequest.validityStartTimestamp = 1000;
        _mintrequest.validityEndTimestamp = 2000;
        _mintrequest.uid = bytes32(0);

        _signature = signMintRequest(_mintrequest, privateKey);
    }

	// Edge case: Test minting with invalid signature (added to prevent minting exploit)
    function testFailMintWithInvalidSignature() public {
        // Trying to mint with an invalid signature should fail
        TokenERC20.MintRequest memory mintRequest = TokenERC20.MintRequest({
            to: address(this),
            primarySaleRecipient: recipient,  // Use the recipient from your setup
            quantity: 100,
            price: 0.01 ether,
            currency: address(0),
            validityStartTimestamp: block.timestamp,
            validityEndTimestamp: block.timestamp + 1 hours, // Set a valid timeframe
            uid: bytes32(0)
        });
        emptySignature = ""; // No signature provided

        // Expect this mint to fail due to invalid signature
        vm.expectRevert("Invalid signature");
        tokenContract.mintWithSignature(mintRequest, emptySignature);
    }

    // Gas efficiency check: Track gas usage for minting tokens
    function testGasMinting() public {
        // Measure gas consumption for minting
        uint256 gasBefore = gasleft();
        tokenContract.mintTo(address(this), 100);
        uint256 gasAfter = gasleft();

        uint256 gasUsed = gasBefore - gasAfter;
        emit log_uint(gasUsed); // Log gas usage for debugging (check logs for gas consumption)
    }

    function signMintRequest(
        TokenERC20.MintRequest memory _request,
        uint256 _privateKey
    ) internal view returns (bytes memory) {
        bytes memory encodedRequest = abi.encode(
            typehashMintRequest,
            _request.to,
            _request.primarySaleRecipient,
            _request.quantity,
            _request.price,
            _request.currency,
            _request.validityStartTimestamp,
            _request.validityEndTimestamp,
            _request.uid
        );
        bytes32 structHash = keccak256(encodedRequest);
        bytes32 typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_privateKey, typedDataHash);
        bytes memory sig = abi.encodePacked(r, s, v);

        return sig;
    }

    /*///////////////////////////////////////////////////////////////
                        Unit tests: `mintWithSignature`
    //////////////////////////////////////////////////////////////*/

    function test_state_mintWithSignature_ZeroPrice() public {
        vm.warp(1000);

        // initial balances and state
        uint256 currentTotalSupply = tokenContract.totalSupply();
        uint256 currentBalanceOfRecipient = tokenContract.balanceOf(recipient);

        // mint with signature
        vm.prank(recipient);
        tokenContract.mintWithSignature(_mintrequest, _signature);

        // check state after minting
        assertEq(tokenContract.totalSupply(), currentTotalSupply + _mintrequest.quantity);
        assertEq(tokenContract.balanceOf(recipient), currentBalanceOfRecipient + _mintrequest.quantity);
    }

    function test_state_mintWithSignature_NonZeroPrice_ERC20() public {
        vm.warp(1000);

        // update mintrequest data
        _mintrequest.price = 1;
        _mintrequest.currency = address(erc20);
        _signature = signMintRequest(_mintrequest, privateKey);

        // approve erc20 tokens to tokenContract
        vm.prank(recipient);
        erc20.approve(address(tokenContract), _mintrequest.price);

        // initial balances and state
        uint256 currentTotalSupply = tokenContract.totalSupply();
        uint256 currentBalanceOfRecipient = tokenContract.balanceOf(recipient);

        uint256 erc20BalanceOfSeller = erc20.balanceOf(address(saleRecipient));
        uint256 erc20BalanceOfRecipient = erc20.balanceOf(address(recipient));

        // mint with signature
        vm.prank(recipient);
        tokenContract.mintWithSignature(_mintrequest, _signature);

        // check state after minting
        assertEq(tokenContract.totalSupply(), currentTotalSupply + _mintrequest.quantity);
        assertEq(tokenContract.balanceOf(recipient), currentBalanceOfRecipient + _mintrequest.quantity);

        // check erc20 balances after minting
        uint256 _platformFees = (_mintrequest.price * platformFeeBps) / MAX_BPS;
        assertEq(erc20.balanceOf(recipient), erc20BalanceOfRecipient - _mintrequest.price);
        assertEq(erc20.balanceOf(address(saleRecipient)), erc20BalanceOfSeller + _mintrequest.price - _platformFees);
    }

    function test_state_mintWithSignature_NonZeroPrice_NativeToken() public {
        vm.warp(1000);

        // update mintrequest data
        _mintrequest.price = 1;
        _mintrequest.currency = address(NATIVE_TOKEN);
        _signature = signMintRequest(_mintrequest, privateKey);

        // initial balances and state
        uint256 currentTotalSupply = tokenContract.totalSupply();
        uint256 currentBalanceOfRecipient = tokenContract.balanceOf(recipient);

        uint256 etherBalanceOfSeller = address(saleRecipient).balance;
        uint256 etherBalanceOfRecipient = address(recipient).balance;

        // mint with signature
        vm.prank(recipient);
        tokenContract.mintWithSignature{ value: _mintrequest.price }(_mintrequest, _signature);

        // check state after minting
        assertEq(tokenContract.totalSupply(), currentTotalSupply + _mintrequest.quantity);
        assertEq(tokenContract.balanceOf(recipient), currentBalanceOfRecipient + _mintrequest.quantity);

        // check balances after minting
        uint256 _platformFees = (_mintrequest.price * platformFeeBps) / MAX_BPS;
        assertEq(address(recipient).balance, etherBalanceOfRecipient - _mintrequest.price);
        assertEq(address(saleRecipient).balance, etherBalanceOfSeller + _mintrequest.price - _platformFees);
    }

    function test_revert_mintWithSignature_MustSendTotalPrice() public {
        vm.warp(1000);

        _mintrequest.price = 1;
        _mintrequest.currency = address(NATIVE_TOKEN);
        _signature = signMintRequest(_mintrequest, privateKey);

        vm.prank(recipient);
        vm.expectRevert("must send total price.");
        tokenContract.mintWithSignature{ value: 0 }(_mintrequest, _signature);
    }

    function test_revert_mintWithSignature_MsgValueNotZero() public {
        vm.warp(1000);

        _mintrequest.price = 1;
        _mintrequest.currency = address(erc20);
        _signature = signMintRequest(_mintrequest, privateKey);

        // shouldn't send native-token when it is not the currency
        vm.prank(recipient);
        vm.expectRevert("msg value not zero");
        tokenContract.mintWithSignature{ value: 1 }(_mintrequest, _signature);
    }

    function test_revert_mintWithSignature_InvalidSignature() public {
        vm.warp(1000);

        uint256 incorrectKey = 3456;
        _signature = signMintRequest(_mintrequest, incorrectKey);

        vm.prank(recipient);
        vm.expectRevert("invalid signature");
        tokenContract.mintWithSignature(_mintrequest, _signature);
    }

    function test_revert_mintWithSignature_RequestExpired() public {
        _signature = signMintRequest(_mintrequest, privateKey);

        // warp time more out of range
        vm.warp(3000);

        vm.prank(recipient);
        vm.expectRevert("request expired");
        tokenContract.mintWithSignature(_mintrequest, _signature);
    }

    function test_revert_mintWithSignature_RecipientUndefined() public {
        vm.warp(1000);

        _mintrequest.to = address(0);
        _signature = signMintRequest(_mintrequest, privateKey);

        vm.prank(recipient);
        vm.expectRevert("recipient undefined");
        tokenContract.mintWithSignature(_mintrequest, _signature);
    }

    function test_revert_mintWithSignature_ZeroQuantity() public {
        vm.warp(1000);

        _mintrequest.quantity = 0;
        _signature = signMintRequest(_mintrequest, privateKey);

        vm.prank(recipient);
        vm.expectRevert("zero quantity");
        tokenContract.mintWithSignature(_mintrequest, _signature);
    }

    function test_event_mintWithSignature() public {
        vm.warp(1000);

        vm.expectEmit(true, true, true, true);
        emit TokensMintedWithSignature(deployerSigner, recipient, _mintrequest);

        // mint with signature
        vm.prank(recipient);
        tokenContract.mintWithSignature(_mintrequest, _signature);
    }

    /*///////////////////////////////////////////////////////////////
                        Unit tests: `mintTo`
    //////////////////////////////////////////////////////////////*/

    function test_state_mintTo() public {
        uint256 _amount = 100;

        uint256 currentTotalSupply = tokenContract.totalSupply();
        uint256 currentBalanceOfRecipient = tokenContract.balanceOf(recipient);

        vm.prank(deployerSigner);
        tokenContract.mintTo(recipient, _amount);

        assertEq(tokenContract.totalSupply(), currentTotalSupply + _amount);
        assertEq(tokenContract.balanceOf(recipient), currentBalanceOfRecipient + _amount);
    }

    function test_revert_mintTo_NotAuthorized() public {
        uint256 _amount = 100;

        vm.expectRevert("not minter.");
        vm.prank(address(0x1));
        tokenContract.mintTo(recipient, _amount);
    }

    function test_event_mintTo() public {
        uint256 _amount = 100;

        vm.expectEmit(true, true, true, true);
        emit TokensMinted(recipient, _amount);

        // mint
        vm.prank(deployerSigner);
        tokenContract.mintTo(recipient, _amount);
    }

    /*///////////////////////////////////////////////////////////////
                        Unit tests: primary sale
    //////////////////////////////////////////////////////////////*/

    function test_state_setPrimarySaleRecipient() public {
        address _primarySaleRecipient = address(0x123);

        vm.prank(deployerSigner);
        tokenContract.setPrimarySaleRecipient(_primarySaleRecipient);

        address recipient_ = tokenContract.primarySaleRecipient();
        assertEq(recipient_, _primarySaleRecipient);
    }

    function test_revert_setPrimarySaleRecipient_NotAuthorized() public {
        address _primarySaleRecipient = address(0x123);
        bytes32 role = tokenContract.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodePacked(
                "AccessControl: account ",
                Strings.toHexString(uint160(address(0x1)), 20),
                " is missing role ",
                Strings.toHexString(uint256(role), 32)
            )
        );
        vm.prank(address(0x1));
        tokenContract.setPrimarySaleRecipient(_primarySaleRecipient);
    }

    function test_event_setPrimarySaleRecipient() public {
        address _primarySaleRecipient = address(0x123);

        vm.expectEmit(true, true, true, true);
        emit PrimarySaleRecipientUpdated(_primarySaleRecipient);

        vm.prank(deployerSigner);
        tokenContract.setPrimarySaleRecipient(_primarySaleRecipient);
    }

    /*///////////////////////////////////////////////////////////////
                        Unit tests: platform fee
    //////////////////////////////////////////////////////////////*/

    function test_state_setPlatformFeeInfo() public {
        address _platformFeeRecipient = address(0x123);
        uint256 _platformFeeBps = 1000;

        vm.prank(deployerSigner);
        tokenContract.setPlatformFeeInfo(_platformFeeRecipient, _platformFeeBps);

        (address recipient_, uint16 bps) = tokenContract.getPlatformFeeInfo();
        assertEq(_platformFeeRecipient, recipient_);
        assertEq(_platformFeeBps, bps);
    }

    function test_revert_setPlatformFeeInfo_ExceedsMaxBps() public {
        address _platformFeeRecipient = address(0x123);
        uint256 _platformFeeBps = 10001;

        vm.expectRevert("exceeds MAX_BPS");
        vm.prank(deployerSigner);
        tokenContract.setPlatformFeeInfo(_platformFeeRecipient, _platformFeeBps);
    }

    function test_revert_setPlatformFeeInfo_NotAuthorized() public {
        bytes32 role = tokenContract.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodePacked(
                "AccessControl: account ",
                Strings.toHexString(uint160(address(0x1)), 20),
                " is missing role ",
                Strings.toHexString(uint256(role), 32)
            )
        );
        vm.prank(address(0x1));
        tokenContract.setPlatformFeeInfo(address(1), 1000);
    }

    function test_event_platformFeeInfo() public {
        address _platformFeeRecipient = address(0x123);
        uint256 _platformFeeBps = 1000;

        vm.expectEmit(true, true, true, true);
        emit PlatformFeeInfoUpdated(_platformFeeRecipient, _platformFeeBps);

        vm.prank(deployerSigner);
        tokenContract.setPlatformFeeInfo(_platformFeeRecipient, _platformFeeBps);
    }

    /*///////////////////////////////////////////////////////////////
                        Unit tests: contract metadata
    //////////////////////////////////////////////////////////////*/

    function test_state_setContractURI() public {
        string memory uri = "uri_string";

        vm.prank(deployerSigner);
        tokenContract.setContractURI(uri);

        string memory _contractURI = tokenContract.contractURI();

        assertEq(_contractURI, uri);
    }

    function test_revert_setContractURI_NotAuthorized() public {
        bytes32 role = tokenContract.DEFAULT_ADMIN_ROLE();

        vm.expectRevert(
            abi.encodePacked(
                "AccessControl: account ",
                Strings.toHexString(uint160(address(0x1)), 20),
                " is missing role ",
                Strings.toHexString(uint256(role), 32)
            )
        );
        vm.prank(address(0x1));
        tokenContract.setContractURI("");
    }
}
