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
  const artifact: ZkSyncArtifact = (await hre.artifacts.readArtifact("OffersLogic")) as ZkSyncArtifact;
  const offers = new ContractFactory(artifact.abi, artifact.bytecode, wallet, "create");

  const contract = await offers.deploy();
  await contract.deployed();

  console.log("Deployed OffersLogic \n: ", contract.address);

  console.log("\n");

  console.log("Verifying contract.");
  // deployed address zksync mainnet: 0x5f4964a30b86B626BCAAaCc4622CB70d76c844f2
  // deployed address zksync sepolia: 0xB89DbEe6fA8664507b0f7758bCc532817CAf6Eb2
  await verify(contract.address, "contracts/prebuilts/marketplace/offers/OffersLogic.sol:OffersLogic", []);
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
