/** @type import('hardhat/config').HardhatUserConfig */
// import "@nomicfoundation/hardhat-toolbox";
import "@nomicfoundation/hardhat-foundry";
import "@matterlabs/hardhat-zksync-deploy";
import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-verify";
import { HardhatUserConfig } from "hardhat/config";
import dotenv from "dotenv";

dotenv.config();

const config: HardhatUserConfig = {
  zksolc: {
    version: "1.4.1", // Uses latest available in https://github.com/matter-labs/zksolc-bin/
    settings: {
      optimizer: {
        enabled: true,
        runs: 20,
      },
    },
  },
  // defaultNetwork: "zkSyncSepoliaTestnet",
  networks: {
    hardhat: {
      zksync: false,
    },
    zkCandySepolia: {
      url: "https://sepolia.rpc.zkcandy.io",
      ethNetwork: "sepolia",
      zksync: true,
      verifyURL: "https://sepolia.contract-verifier.zkcandy.io/contract_verification",
    },
    zkSyncSepoliaTestnet: {
      url: "https://sepolia.era.zksync.dev",
      ethNetwork: "sepolia", // or a Sepolia RPC endpoint from Infura/Alchemy/Chainstack etc.
      zksync: true,
      verifyURL: "https://explorer.sepolia.era.zksync.dev/contract_verification",
    },
    zkSyncMainnet: {
      url: "https://mainnet.era.zksync.io",
      ethNetwork: "mainnet",
      zksync: true,
      verifyURL: "https://zksync2-mainnet-explorer.zksync.io/contract_verification",
    },
  },
  paths: {
    artifacts: "./artifacts-zk",
    cache: "./cache-zk",
    sources: "./contracts",
    tests: "./test",
  },
  solidity: {
    version: "0.8.23",
    settings: {
      // You should disable the optimizer when debugging
      // https://hardhat.org/hardhat-network/#solidity-optimizer-support
      optimizer: {
        enabled: true,
        runs: 20,
      },
      metadata: {
        bytecodeHash: "ipfs",
      },
      outputSelection: {
        "*": {
          "*": [
            "metadata",
            "abi",
            "evm.bytecode.object",
            "evm.bytecode.sourceMap",
            "evm.deployedBytecode.object",
            "evm.deployedBytecode.sourceMap",
          ],
        },
      },
    },
  },
};

export default config;
