// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.11;

interface IMap {
    /**
     *  @notice An interface to describe a plug-in.
     *
     *  @param functionSelector     4-byte function selector.
     *  @param pluginAddress        Address of the contract containing the function.
     *  @param functionSignature    Function representation as a string. E.g. "transfer(address,address,uint256)"
     */
    struct Plugin {
        bytes4 functionSelector;
        address pluginAddress;
        string functionSignature;
    }

    /// @dev Emitted when a function selector is mapped to a particular plug-in smart contract, during construction of Map.
    event PluginSet(bytes4 indexed functionSelector, string indexed functionSignature, address indexed pluginAddress);

    /// @dev Returns the plug-in contract for a given function.
    function getPluginForFunction(bytes4 selector) external view returns (address);

    /// @dev Returns all functions that are mapped to the given plug-in contract.
    function getAllFunctionsOfPlugin(address pluginAddress) external view returns (bytes4[] memory);

    /// @dev Returns all plug-ins known by Map.
    function getAllPlugins() external view returns (Plugin[] memory);
}
