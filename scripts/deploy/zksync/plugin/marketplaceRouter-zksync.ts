import { Wallet, Provider, ContractFactory } from "zksync-ethers";
import * as hre from "hardhat";
import dotenv from "dotenv";
import { ZkSyncArtifact } from "@matterlabs/hardhat-zksync-solc/dist/src/types";

import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";

dotenv.config();

async function main() {
  const provider = new Provider(hre.network.config.url);
  const wallet = new Wallet(`${process.env.TEST_PRIVATE_KEY}`, provider);
  const artifact: ZkSyncArtifact = (await hre.artifacts.readArtifact("MarketplaceV3")) as ZkSyncArtifact;
  const marketplaceV3 = new ContractFactory(artifact.abi, artifact.bytecode, wallet, "create");

  // WETH address as constructor param
  // Zksync Mainnet: 0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91
  // Zksync Sepolia: 0x0462C05457Fed440740Ff3696bDd2D0577411e34
  const contract = await marketplaceV3.deploy(
    "0xC2f4B1B6B3d6813aBc8e55B3BAd0796526A5d633", // pluginMap address
    "0x0000000000000000000000000000000000000000", // royalty engine address - set to address(0)
    "0x0462C05457Fed440740Ff3696bDd2D0577411e34", // WETH address
  );
  await contract.deployed();

  console.log("Deployed MarketplaceV3 \n: ", contract.address);

  console.log("\n");

  console.log("Verifying contract.");

  // deployed address zksync mainnet: 0xBc02441a36Bb4029Cd191b20243c2e41B862F118
  // deployed address zksync sepolia: 0x58e0F289C7dD2025eBd0696d913ECC0fdc1CC8bc
  await verify(contract.address, "contracts/prebuilts/marketplace/entrypoint/MarketplaceV3.sol:MarketplaceV3", [
    "0xC2f4B1B6B3d6813aBc8e55B3BAd0796526A5d633",
    "0x0000000000000000000000000000000000000000",
    "0x0462C05457Fed440740Ff3696bDd2D0577411e34",
  ]);
}

async function verify(address: string, contract: string, args: any[]) {
  try {
    return await hre.run("verify:verify", {
      address: address,
      contract: contract,
      constructorArguments: args,
    });
  } catch (e) {
    console.log(address, args, e);
  }
}

main()
  .then(() => process.exit(0))
  .catch(e => {
    console.error(e);
    process.exit(1);
  });
