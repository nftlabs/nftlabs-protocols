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
  const artifact: ZkSyncArtifact = (await hre.artifacts.readArtifact("NFTStake")) as ZkSyncArtifact;
  const contractFactory = new ContractFactory(artifact.abi, artifact.bytecode, wallet, "create");

  // WETH address as constructor param
  // Zksync Mainnet: 0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91
  // Zksync Sepolia: 0x0462C05457Fed440740Ff3696bDd2D0577411e34
  const contract = await contractFactory.deploy("0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91");
  await contract.deployed();

  console.log("Deployed NFTStake \n: ", contract.address);

  console.log("\n");

  console.log("Verifying contract.");
  await verify(contract.address, "contracts/prebuilts/staking/NFTStake.sol:NFTStake", [
    "0x5AEa5775959fBC2557Cc8789bC1bf90A239D9a91",
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
