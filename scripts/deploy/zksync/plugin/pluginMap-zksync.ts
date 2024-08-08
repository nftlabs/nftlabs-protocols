import { Wallet, Provider, ContractFactory } from "zksync-ethers";
import * as hre from "hardhat";
import dotenv from "dotenv";
import { ZkSyncArtifact } from "@matterlabs/hardhat-zksync-solc/dist/src/types";

import "@matterlabs/hardhat-zksync-node/dist/type-extensions";
import "@matterlabs/hardhat-zksync-verify/dist/src/type-extensions";
import { ethers } from "ethers";

dotenv.config();

type PluginMapInput = {
  functionSelector: string;
  functionSignature: string;
  pluginAddress: string;
};

const getFunctionSignature = (fnInputs: any): string => {
  return (
    "(" +
    fnInputs
      .map((i: any) => {
        return i.type === "tuple" ? getFunctionSignature(i.components) : i.type;
      })
      .join(",") +
    ")"
  );
};

const generatePluginFunctions = (pluginAddress: string, pluginAbi: any): PluginMapInput[] => {
  const pluginInterface = new ethers.utils.Interface(pluginAbi);
  const pluginFunctions = [];
  // TODO - filter out common functions like _msgSender(), contractType(), etc.
  for (const fnFragment of Object.values(pluginInterface.functions)) {
    const fn = pluginInterface.getFunction(fnFragment.name);
    if (fn.name.startsWith("_")) {
      continue;
    }
    pluginFunctions.push({
      functionSelector: pluginInterface.getSighash(fn),
      functionSignature: fn.name + getFunctionSignature(fn.inputs),
      pluginAddress: pluginAddress,
    });
  }
  return pluginFunctions;
};

async function getPluginInput() {
  const DirectListingsLogicArtifact: ZkSyncArtifact = (await hre.artifacts.readArtifact(
    "DirectListingsLogic",
  )) as ZkSyncArtifact;
  const pluginsDirectListings = generatePluginFunctions(
    "0x8b0DBCf5b7D01eBB0F24525CE8AB72F16CE4F8C8",
    DirectListingsLogicArtifact.abi,
  );

  const EnglishAuctionsLogicArtifact: ZkSyncArtifact = (await hre.artifacts.readArtifact(
    "EnglishAuctionsLogic",
  )) as ZkSyncArtifact;
  const pluginsEnglishAuctions = generatePluginFunctions(
    "0xefE2fF8F3282Fd63898cb0A532099BA7780b459F",
    EnglishAuctionsLogicArtifact.abi,
  );

  const OffersLogicABI: ZkSyncArtifact = (await hre.artifacts.readArtifact("OffersLogic")) as ZkSyncArtifact;
  const pluginsOffers = generatePluginFunctions("0xB89DbEe6fA8664507b0f7758bCc532817CAf6Eb2", OffersLogicABI.abi);

  return [...pluginsDirectListings, ...pluginsEnglishAuctions, ...pluginsOffers];
}

async function main() {
  const pluginInput = await getPluginInput();

  const provider = new Provider(hre.network.config.url);
  const wallet = new Wallet(`${process.env.TEST_PRIVATE_KEY}`, provider);
  const artifact: ZkSyncArtifact = (await hre.artifacts.readArtifact("PluginMap")) as ZkSyncArtifact;
  const map = new ContractFactory(artifact.abi, artifact.bytecode, wallet, "create");

  const contract = await map.deploy(pluginInput);
  await contract.deployed();

  console.log("Deployed PluginMap \n: ", contract.address);
  console.log("\n");
  console.log("Verifying contract.");

  // deployed address zksync mainnet: 0x0326643B8844710065C9ce0e5326B006608E8D8d
  // deployed address zksync sepolia: 0xC2f4B1B6B3d6813aBc8e55B3BAd0796526A5d633
  await verify(contract.address, "contracts/extension/plugin/PluginMap.sol:PluginMap", [pluginInput]);
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
