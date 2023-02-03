// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

//  ==========  External imports    ==========

import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/utils/MulticallUpgradeable.sol";

//  ==========  Internal imports    ==========

import "../interfaces/airdrop/IAirdropERC20.sol";
import { CurrencyTransferLib } from "../lib/CurrencyTransferLib.sol";
import "../openzeppelin-presets/token/ERC20/utils/SafeERC20.sol";

//  ==========  Features    ==========
import "../extension/Ownable.sol";
import "../extension/PermissionsEnumerable.sol";

contract AirdropERC20 is
    Initializable,
    Ownable,
    PermissionsEnumerable,
    ReentrancyGuardUpgradeable,
    MulticallUpgradeable,
    IAirdropERC20
{
    using SafeERC20 for IERC20;
    /*///////////////////////////////////////////////////////////////
                            State variables
    //////////////////////////////////////////////////////////////*/

    bytes32 private constant MODULE_TYPE = bytes32("AirdropERC20");
    uint256 private constant VERSION = 1;

    uint256 public payeeCount;
    uint256 public processedCount;

    uint256[] public indicesOfFailed;

    mapping(uint256 => AirdropContent) private airdropContent;

    mapping(uint256 => bool) private isCancelled;

    /*///////////////////////////////////////////////////////////////
                    Constructor + initializer logic
    //////////////////////////////////////////////////////////////*/

    constructor() initializer {}

    /// @dev Initiliazes the contract, like a constructor.
    function initialize(address _defaultAdmin) external initializer {
        _setupRole(DEFAULT_ADMIN_ROLE, _defaultAdmin);
        _setupOwner(_defaultAdmin);
        __ReentrancyGuard_init();
    }

    /*///////////////////////////////////////////////////////////////
                        Generic contract logic
    //////////////////////////////////////////////////////////////*/

    /// @dev Returns the type of the contract.
    function contractType() external pure returns (bytes32) {
        return MODULE_TYPE;
    }

    /// @dev Returns the version of the contract.
    function contractVersion() external pure returns (uint8) {
        return uint8(VERSION);
    }

    /*///////////////////////////////////////////////////////////////
                            Airdrop logic
    //////////////////////////////////////////////////////////////*/

    ///@notice Lets contract-owner set up an airdrop of ERC20 or native tokens to a list of addresses.
    function addRecipients(AirdropContent[] calldata _contents) external payable onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = _contents.length;
        require(len > 0, "No payees provided.");

        uint256 currentCount = payeeCount;
        payeeCount += len;

        uint256 nativeTokenAmount;

        for (uint256 i = currentCount; i < len; i += 1) {
            airdropContent[i] = _contents[i];

            if (_contents[i].tokenAddress == CurrencyTransferLib.NATIVE_TOKEN) {
                nativeTokenAmount += _contents[i].amount;
            }
        }

        require(nativeTokenAmount == msg.value, "Incorrect native token amount");

        emit RecipientsAdded(_contents);
    }

    ///@notice Lets contract-owner cancel any pending payments.
    function resetRecipients() external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 totalPayees = payeeCount;
        uint256 countOfProcessed = processedCount;

        // set processedCount to payeeCount -- ignore all pending payments.
        processedCount = payeeCount;

        for (uint256 i = countOfProcessed; i < totalPayees; i += 1) {
            isCancelled[i] = true;
        }
    }

    /// @notice Lets contract-owner send ERC20 or native tokens to a list of addresses.
    function processPayments(uint256 paymentsToProcess) external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 totalPayees = payeeCount;
        uint256 countOfProcessed = processedCount;

        require(countOfProcessed + paymentsToProcess <= totalPayees, "invalid no. of payments");

        processedCount += paymentsToProcess;

        for (uint256 i = countOfProcessed; i < (countOfProcessed + paymentsToProcess); i += 1) {
            AirdropContent memory content = airdropContent[i];

            bool success = _transferCurrencyWithReturnVal(
                content.tokenAddress,
                content.tokenOwner,
                content.recipient,
                content.amount
            );

            if (!success) {
                // Track failure
            }

            // if (content.tokenAddress == CurrencyTransferLib.NATIVE_TOKEN) {
            //     // solhint-disable avoid-low-level-calls
            //     // slither-disable-next-line low-level-calls
            //     (success, ) = content.recipient.call{ value: content.amount }("");
            // } else {
            //     try
            //         IERC20(content.tokenAddress).transferFrom(content.tokenOwner, content.recipient, content.amount)
            //     returns (bool _success) {
            //         success = _success;
            //     } catch {
            //         // revert if failure is due to insufficient allowance
            //         require(
            //             IERC20(content.tokenAddress).balanceOf(content.tokenOwner) >= content.amount &&
            //                 IERC20(content.tokenAddress).allowance(content.tokenOwner, address(this)) >= content.amount,
            //             "Not balance or allowance"
            //         );

            //         // record and continue for all other failures, likely originating from recipient accounts
            //         indicesOfFailed.push(i);
            //         success = false;
            //     }
            // }

            emit AirdropPayment(content.recipient, content, !success);
        }
    }

    /**
     *  @notice          Lets contract-owner send ERC20 tokens to a list of addresses.
     *  @dev             The token-owner should approve target tokens to Airdrop contract,
     *                   which acts as operator for the tokens.
     *
     *  @param _contents        List containing recipient, tokenId and amounts to airdrop.
     */
    function airdrop(AirdropContent[] calldata _contents) external payable nonReentrant onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 len = _contents.length;
        uint256 nativeTokenAmount;

        for (uint256 i = 0; i < len; i++) {
            CurrencyTransferLib.transferCurrency(
                _contents[i].tokenAddress,
                _contents[i].tokenOwner,
                _contents[i].recipient,
                _contents[i].amount
            );

            if (_contents[i].tokenAddress == CurrencyTransferLib.NATIVE_TOKEN) {
                nativeTokenAmount += _contents[i].amount;
            }

            emit StatelessAirdrop(_contents[i].recipient, _contents[i]);
        }

        require(nativeTokenAmount == msg.value, "Incorrect native token amount");
    }

    /*///////////////////////////////////////////////////////////////
                        Airdrop view logic
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns all airdrop payments set up -- pending, processed or failed.
    function getAllAirdropPayments(uint256 startId, uint256 endId)
        external
        view
        returns (AirdropContent[] memory contents)
    {
        require(startId <= endId && endId < payeeCount, "invalid range");

        contents = new AirdropContent[](endId - startId + 1);

        for (uint256 i = startId; i <= endId; i += 1) {
            contents[i - startId] = airdropContent[i];
        }
    }

    /// @notice Returns all pending airdrop payments.
    function getAllAirdropPaymentsPending(uint256 startId, uint256 endId)
        external
        view
        returns (AirdropContent[] memory contents)
    {
        require(startId <= endId && endId < payeeCount, "invalid range");

        uint256 processed = processedCount;
        if (startId < processed) {
            startId = processed;
        }
        contents = new AirdropContent[](endId - startId);

        uint256 idx;
        for (uint256 i = startId; i <= endId; i += 1) {
            contents[idx] = airdropContent[i];
            idx += 1;
        }
    }

    /// @notice Returns all pending airdrop processed.
    function getAllAirdropPaymentsProcessed(uint256 startId, uint256 endId)
        external
        view
        returns (AirdropContent[] memory contents)
    {
        require(startId <= endId && endId < payeeCount, "invalid range");
        uint256 processed = processedCount;
        if (startId >= processed) {
            return contents;
        }

        if (endId >= processed) {
            endId = processed - 1;
        }

        uint256 count;

        for (uint256 i = startId; i <= endId; i += 1) {
            if (isCancelled[i]) {
                continue;
            }
            count += 1;
        }

        contents = new AirdropContent[](count);
        uint256 index;

        for (uint256 i = startId; i <= endId; i += 1) {
            if (isCancelled[i]) {
                continue;
            }
            contents[index++] = airdropContent[i];
        }
    }

    /// @notice Returns all pending airdrop failed.
    function getAllAirdropPaymentsFailed() external view returns (AirdropContent[] memory contents) {
        uint256 count = indicesOfFailed.length;
        contents = new AirdropContent[](count);

        for (uint256 i = 0; i < count; i += 1) {
            contents[i] = airdropContent[indicesOfFailed[i]];
        }
    }

    /*///////////////////////////////////////////////////////////////
                        Miscellaneous
    //////////////////////////////////////////////////////////////*/

    /// @dev Transfers ERC20 tokens and returns a boolean i.e. the status of the transfer.
    function _transferCurrencyWithReturnVal(
        address _currency,
        address _from,
        address _to,
        uint256 _amount
    ) internal returns (bool success) {
        if (_amount == 0) {
            success = true;
            return success;
        }

        if (_currency == CurrencyTransferLib.NATIVE_TOKEN) {
            (success, ) = _to.call{ value: _amount }("");
        } else {
            try IERC20(_currency).transferFrom(_from, _to, _amount) returns (bool success_) {
                success = success_;
            } catch {
                require(
                    IERC20(_currency).balanceOf(_from) >= _amount &&
                        IERC20(_currency).allowance(_from, address(this)) >= _amount,
                    "CurrencyTransferBal: insufficient balance or allowance."
                );

                success = false;
            }
        }
    }

    /// @dev Returns whether owner can be set in the given execution context.
    function _canSetOwner() internal view virtual override returns (bool) {
        return hasRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }
}
