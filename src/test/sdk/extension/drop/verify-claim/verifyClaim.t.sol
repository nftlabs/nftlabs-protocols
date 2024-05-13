// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

import "@std/Test.sol";
import "@ds-test/test.sol";

import { Drop, IDrop, IClaimConditionMultiPhase, IClaimCondition } from "contracts/extension/Drop.sol";
import "../../ExtensionUtilTest.sol";

contract MyDrop is Drop {
    function _collectPriceOnClaim(
        address _primarySaleRecipient,
        uint256 _quantityToClaim,
        address _currency,
        uint256 _pricePerToken
    ) internal override {}

    function _transferTokensOnClaim(
        address _to,
        uint256 _quantityBeingClaimed
    ) internal override returns (uint256 startTokenId) {}

    function _canSetClaimConditions() internal view override returns (bool) {
        return true;
    }

    /**
     * note: the functions below are dummy functions for test purposes,
     * to directly access and set/reset state without going through the actual functions and checks
     */

    function setCondition(ClaimCondition calldata condition, uint256 _conditionId) public {
        claimCondition.conditions[_conditionId] = condition;
        claimCondition.conditionHash[_conditionId] = keccak256(abi.encodePacked(_conditionId, block.number));
    }

    function setSupplyClaimedByWallet(uint256 _conditionId, address _wallet, uint256 _supplyClaimed) public {
        bytes32 _conditionHash = keccak256(abi.encodePacked(_conditionId, block.number));
        claimCondition.supplyClaimedByWallet[_conditionHash][_wallet] = _supplyClaimed;
    }
}

contract Drop_VerifyClaim is ExtensionUtilTest {
    MyDrop internal ext;

    uint256 internal _conditionId;
    address internal _claimer;
    address internal _allowlistClaimer;
    uint256 internal _quantity;
    address internal _currency;
    uint256 internal _pricePerToken;
    IDrop.AllowlistProof internal _allowlistProof;
    IDrop.AllowlistProof internal _allowlistProofEmpty; // will leave uninitialized

    IClaimCondition.ClaimCondition internal claimCondition;
    IClaimCondition.ClaimCondition internal claimConditionWithAllowlist;

    function setUp() public override {
        super.setUp();

        ext = new MyDrop();

        _claimer = getActor(1);
        _allowlistClaimer = address(0xDDdDddDdDdddDDddDDddDDDDdDdDDdDDdDDDDDDd);

        // claim condition without allowlist
        claimCondition = IClaimCondition.ClaimCondition({
            startTimestamp: 1000,
            maxClaimableSupply: 100,
            supplyClaimed: 0,
            quantityLimitPerWallet: 1,
            merkleRoot: bytes32(0),
            pricePerToken: 10,
            currency: address(erc20),
            metadata: ""
        });

        // claim condition with allowlist -- set defaults for now
        claimConditionWithAllowlist = claimCondition;
        (_allowlistProof, claimConditionWithAllowlist.merkleRoot) = _setAllowlistAndProofs(
            0, // default
            type(uint256).max, // default
            address(0) // default
        );
    }

    function _setAllowlistAndProofs(
        uint256 _quantity,
        uint256 _price,
        address _currency
    ) internal returns (IDrop.AllowlistProof memory, bytes32) {
        string[] memory inputs = new string[](5);

        inputs[0] = "node";
        inputs[1] = "src/test/scripts/generateRoot.ts";
        inputs[2] = Strings.toString(_quantity);
        inputs[3] = Strings.toString(_price);
        inputs[4] = Strings.toHexString(uint160(_currency));

        bytes memory result = vm.ffi(inputs);
        // revert();
        bytes32 root = abi.decode(result, (bytes32));

        inputs[1] = "src/test/scripts/getProof.ts";
        result = vm.ffi(inputs);
        bytes32[] memory proofs = abi.decode(result, (bytes32[]));

        IDrop.AllowlistProof memory alp;
        alp.proof = proofs;
        alp.quantityLimitPerWallet = _quantity;
        alp.pricePerToken = _price;
        alp.currency = address(_currency);

        return (alp, root);
    }

    // ==================
    // ======= Test branch: when no allowlist
    // ==================

    function test_verifyClaim_noAllowlist_invalidCurrency() public {
        ext.setCondition(claimCondition, _conditionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimInvalidTokenPrice.selector,
                _currency,
                _pricePerToken,
                claimCondition.currency,
                claimCondition.pricePerToken
            )
        );
        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    modifier whenValidCurrency_open() {
        _currency = claimCondition.currency;
        _;
    }

    function test_verifyClaim_noAllowlist_invalidPrice() public whenValidCurrency_open {
        ext.setCondition(claimCondition, _conditionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimInvalidTokenPrice.selector,
                _currency,
                _pricePerToken,
                claimCondition.currency,
                claimCondition.pricePerToken
            )
        );
        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    modifier whenValidPrice_open() {
        _pricePerToken = claimCondition.pricePerToken;
        _;
    }

    function test_verifyClaim_noAllowlist_zeroQuantity() public whenValidCurrency_open whenValidPrice_open {
        ext.setCondition(claimCondition, _conditionId);

        _quantity = 0;
        vm.expectRevert(
            abi.encodeWithSelector(Drop.DropClaimExceedLimit.selector, claimCondition.quantityLimitPerWallet, 0)
        );
        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    modifier whenNonZeroQuantity() {
        _quantity = claimCondition.quantityLimitPerWallet + 1234;
        _;
    }

    function test_verifyClaim_noAllowlist_nonZeroInvalidQuantity()
        public
        whenValidCurrency_open
        whenValidPrice_open
        whenNonZeroQuantity
    {
        ext.setCondition(claimCondition, _conditionId);
        ext.setSupplyClaimedByWallet(_conditionId, _claimer, claimCondition.quantityLimitPerWallet);

        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimExceedLimit.selector,
                claimCondition.quantityLimitPerWallet,
                _quantity + claimCondition.quantityLimitPerWallet
            )
        );
        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    modifier whenValidQuantity_open() {
        _quantity = 1;
        _;
    }

    function test_verifyClaim_noAllowlist_quantityMoreThanMaxClaimableSupply()
        public
        whenValidCurrency_open
        whenValidPrice_open
        whenNonZeroQuantity
        whenValidQuantity_open
    {
        claimCondition.supplyClaimed = claimCondition.maxClaimableSupply;
        ext.setCondition(claimCondition, _conditionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimExceedMaxSupply.selector,
                claimCondition.maxClaimableSupply,
                _quantity + claimCondition.maxClaimableSupply
            )
        );
        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    modifier whenQuantityWithinMaxLimit() {
        _;
    }

    function test_verifyClaim_noAllowlist_beforeStartTimestamp()
        public
        whenValidCurrency_open
        whenValidPrice_open
        whenNonZeroQuantity
        whenValidQuantity_open
        whenQuantityWithinMaxLimit
    {
        ext.setCondition(claimCondition, _conditionId);

        vm.expectRevert(
            abi.encodeWithSelector(Drop.DropClaimNotStarted.selector, claimCondition.startTimestamp, block.timestamp)
        );
        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    modifier whenValidTimestamp() {
        vm.warp(claimCondition.startTimestamp);
        _;
    }

    function test_verifyClaim_noAllowlist()
        public
        whenValidCurrency_open
        whenValidPrice_open
        whenNonZeroQuantity
        whenValidQuantity_open
        whenQuantityWithinMaxLimit
        whenValidTimestamp
    {
        ext.setCondition(claimCondition, _conditionId);

        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    // ==================
    // ======= Test branch: allowlist but incorrect proof -- open limits should apply
    // ==================

    function test_verifyClaim_incorrectProof_invalidCurrency() public {
        ext.setCondition(claimConditionWithAllowlist, _conditionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimInvalidTokenPrice.selector,
                _currency,
                _pricePerToken,
                claimCondition.currency,
                claimCondition.pricePerToken
            )
        );
        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    function test_verifyClaim_incorrectProof_invalidPrice() public whenValidCurrency_open {
        ext.setCondition(claimConditionWithAllowlist, _conditionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimInvalidTokenPrice.selector,
                _currency,
                _pricePerToken,
                claimCondition.currency,
                claimCondition.pricePerToken
            )
        );
        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    function test_verifyClaim_incorrectProof_zeroQuantity() public whenValidCurrency_open whenValidPrice_open {
        ext.setCondition(claimConditionWithAllowlist, _conditionId);

        _quantity = 0;
        vm.expectRevert(
            abi.encodeWithSelector(Drop.DropClaimExceedLimit.selector, claimCondition.quantityLimitPerWallet, _quantity)
        );
        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    function test_verifyClaim_incorrectProof_nonZeroInvalidQuantity()
        public
        whenValidCurrency_open
        whenValidPrice_open
        whenNonZeroQuantity
    {
        ext.setCondition(claimConditionWithAllowlist, _conditionId);
        ext.setSupplyClaimedByWallet(_conditionId, _claimer, claimCondition.quantityLimitPerWallet);

        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimExceedLimit.selector,
                claimCondition.quantityLimitPerWallet,
                claimCondition.quantityLimitPerWallet + _quantity
            )
        );
        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    function test_verifyClaim_incorrectProof()
        public
        whenValidCurrency_open
        whenValidPrice_open
        whenNonZeroQuantity
        whenValidQuantity_open
        whenQuantityWithinMaxLimit
        whenValidTimestamp
    {
        ext.setCondition(claimConditionWithAllowlist, _conditionId);

        ext.verifyClaim(_conditionId, _claimer, _quantity, _currency, _pricePerToken, _allowlistProofEmpty);
    }

    // ==================
    // ======= Test branch: allowlist with correct proof
    // ==================

    function test_verifyClaim_allowlist_defaultPriceAndCurrency_invalidCurrencyParam() public {
        ext.setCondition(claimConditionWithAllowlist, _conditionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimInvalidTokenPrice.selector,
                _currency,
                _pricePerToken,
                claimCondition.currency,
                claimCondition.pricePerToken
            )
        );
        ext.verifyClaim(_conditionId, _allowlistClaimer, _quantity, _currency, _pricePerToken, _allowlistProof);
    }

    function test_verifyClaim_allowlist_defaultPriceNonDefaultCurrenct_invalidCurrencyParam() public {
        (_allowlistProof, claimConditionWithAllowlist.merkleRoot) = _setAllowlistAndProofs(
            0, // default
            type(uint256).max, // default
            address(weth)
        );
        ext.setCondition(claimConditionWithAllowlist, _conditionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimInvalidTokenPrice.selector,
                _currency,
                _pricePerToken,
                claimCondition.currency,
                claimCondition.pricePerToken
            )
        );
        ext.verifyClaim(_conditionId, _allowlistClaimer, _quantity, _currency, _pricePerToken, _allowlistProof);
    }

    function test_verifyClaim_allowlist_nonDefaultPriceAndCurrency_invalidCurrencyParam() public {
        (_allowlistProof, claimConditionWithAllowlist.merkleRoot) = _setAllowlistAndProofs(
            0, // default
            2,
            address(weth)
        );
        ext.setCondition(claimConditionWithAllowlist, _conditionId);

        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimInvalidTokenPrice.selector,
                _currency,
                _pricePerToken,
                address(weth),
                2
            )
        );
        ext.verifyClaim(_conditionId, _allowlistClaimer, _quantity, _currency, _pricePerToken, _allowlistProof);
    }

    function test_verifyClaim_allowlist_defaultQuantity_invalidQuantityParam() public {
        (_allowlistProof, claimConditionWithAllowlist.merkleRoot) = _setAllowlistAndProofs(
            0, // default
            2,
            address(weth)
        );
        ext.setCondition(claimConditionWithAllowlist, _conditionId);
        ext.setSupplyClaimedByWallet(
            _conditionId,
            _allowlistClaimer,
            claimConditionWithAllowlist.quantityLimitPerWallet
        );

        _currency = address(weth);
        _pricePerToken = 2;
        _quantity = 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimExceedLimit.selector,
                claimCondition.quantityLimitPerWallet,
                claimCondition.quantityLimitPerWallet + _quantity
            )
        );
        ext.verifyClaim(_conditionId, _allowlistClaimer, _quantity, _currency, _pricePerToken, _allowlistProof);
    }

    function test_verifyClaim_allowlist_nonDefaultQuantity_invalidQuantityParam() public {
        (_allowlistProof, claimConditionWithAllowlist.merkleRoot) = _setAllowlistAndProofs(5, 2, address(weth));
        ext.setCondition(claimConditionWithAllowlist, _conditionId);
        ext.setSupplyClaimedByWallet(_conditionId, _allowlistClaimer, 5);

        _currency = address(weth);
        _pricePerToken = 2;
        _quantity = 1;
        vm.expectRevert(abi.encodeWithSelector(Drop.DropClaimExceedLimit.selector, 5, 5 + _quantity));
        ext.verifyClaim(_conditionId, _allowlistClaimer, _quantity, _currency, _pricePerToken, _allowlistProof);
    }

    function test_verifyClaim_allowlist_defaultPrice_invalidPriceParam() public {
        (_allowlistProof, claimConditionWithAllowlist.merkleRoot) = _setAllowlistAndProofs(
            5,
            type(uint256).max, // default
            address(weth)
        );
        ext.setCondition(claimConditionWithAllowlist, _conditionId);

        _currency = address(weth);
        _quantity = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimInvalidTokenPrice.selector,
                _currency,
                _pricePerToken,
                claimCondition.currency,
                claimCondition.pricePerToken
            )
        );
        ext.verifyClaim(_conditionId, _allowlistClaimer, _quantity, _currency, _pricePerToken, _allowlistProof);
    }

    function test_verifyClaim_allowlist_nonDefaultPrice_invalidPriceParam() public {
        (_allowlistProof, claimConditionWithAllowlist.merkleRoot) = _setAllowlistAndProofs(5, 1, address(weth));
        ext.setCondition(claimConditionWithAllowlist, _conditionId);

        _currency = address(weth);
        _quantity = 1;
        _pricePerToken = 2;
        vm.expectRevert(
            abi.encodeWithSelector(
                Drop.DropClaimInvalidTokenPrice.selector,
                _currency,
                _pricePerToken,
                address(weth),
                1
            )
        );
        ext.verifyClaim(_conditionId, _allowlistClaimer, _quantity, _currency, _pricePerToken, _allowlistProof);
    }

    function test_verifyClaim_allowlist() public whenQuantityWithinMaxLimit whenValidTimestamp {
        (_allowlistProof, claimConditionWithAllowlist.merkleRoot) = _setAllowlistAndProofs(5, 1, address(weth));
        ext.setCondition(claimConditionWithAllowlist, _conditionId);

        _currency = address(weth);
        _quantity = 1;
        _pricePerToken = 1;
        ext.verifyClaim(_conditionId, _allowlistClaimer, _quantity, _currency, _pricePerToken, _allowlistProof);
    }
}
