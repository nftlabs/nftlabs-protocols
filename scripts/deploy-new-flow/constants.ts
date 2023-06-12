import { ChainId, CONTRACT_ADDRESSES } from "@thirdweb-dev/sdk";
import dotenv from "dotenv";

dotenv.config();

export const nativeTokenWrapper: Record<number, string> = {
  1: "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2", // mainnet
  5: "0xB4FBF271143F4FBf7B91A5ded31805e42b2208d6", // goerli
  137: "0x0d500B1d8E8eF31E21C99d1Db9A6444d3ADf1270", // polygon
  80001: "0x9c3C9283D3e44854697Cd22D3Faa240Cfb032889", // mumbai
  43114: "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7", // avalanche
  43113: "0xd00ae08403B9bbb9124bB305C09058E32C39A48c", // avalanche fuji testnet
  250: "0x21be370D5312f44cB42ce377BC9b8a0cEF1A4C83", // fantom
  4002: "0xf1277d1Ed8AD466beddF92ef448A132661956621", // fantom testnet
  10: "0x4200000000000000000000000000000000000006", // optimism
  420: "0x4200000000000000000000000000000000000006", // optimism goerli
  42161: "0x82af49447d8a07e3bd95bd0d56f35241523fbab1", // arbitrum
  421613: "0xe39Ab88f8A4777030A534146A9Ca3B52bd5D43A3", // arbitrum goerli
};

export const chainIdToName: Record<number, string> = {
  [ChainId.Mumbai]: "mumbai",
  [ChainId.Goerli]: "goerli",
  [ChainId.Polygon]: "polygon",
  [ChainId.Mainnet]: "mainnet",
  [ChainId.Optimism]: "optimism",
  [ChainId.OptimismGoerli]: "optimism-goerli",
  [ChainId.Arbitrum]: "arbitrum",
  [ChainId.ArbitrumGoerli]: "arbitrum-goerli",
  [ChainId.Fantom]: "fantom",
  [ChainId.FantomTestnet]: "fantom-testnet",
  [ChainId.Avalanche]: "avalanche",
  [ChainId.AvalancheFujiTestnet]: "avalanche-testnet",
  [ChainId.BinanceSmartChainMainnet]: "binance",
  [ChainId.BinanceSmartChainTestnet]: "binance-testnet",
};

export const chainIdApiKey: Record<number, string | undefined> = {
  [ChainId.Mumbai]: process.env.POLYGONSCAN_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.Goerli]: process.env.ETHERSCAN_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.Polygon]: process.env.POLYGONSCAN_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.Mainnet]: process.env.ETHERSCAN_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.Optimism]: process.env.OPTIMISM_SCAN_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.OptimismGoerli]: process.env.OPTIMISM_SCAN_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.Arbitrum]: process.env.ARBITRUM_SCAN_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.ArbitrumGoerli]: process.env.ARBITRUM_SCAN_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.Fantom]: process.env.FANTOMSCAN_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.FantomTestnet]: process.env.FANTOMSCAN_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.Avalanche]: process.env.SNOWTRACE_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.AvalancheFujiTestnet]: process.env.SNOWTRACE_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.BinanceSmartChainMainnet]: process.env.BINANCE_SCAN_API_KEY || process.env.SCAN_API_KEY,
  [ChainId.BinanceSmartChainTestnet]: process.env.BINANCE_SCAN_API_KEY || process.env.SCAN_API_KEY,
};

export const defaultFactories: Record<number, string> = {
  [ChainId.Mainnet]: CONTRACT_ADDRESSES[ChainId.Mainnet].twFactory,
  [ChainId.Goerli]: CONTRACT_ADDRESSES[ChainId.Goerli].twFactory,
  [ChainId.Polygon]: CONTRACT_ADDRESSES[ChainId.Polygon].twFactory,
  [ChainId.Mumbai]: CONTRACT_ADDRESSES[ChainId.Mumbai].twFactory,
  [ChainId.Fantom]: CONTRACT_ADDRESSES[ChainId.Fantom].twFactory,
  [ChainId.FantomTestnet]: CONTRACT_ADDRESSES[ChainId.FantomTestnet].twFactory,
  [ChainId.Optimism]: CONTRACT_ADDRESSES[ChainId.Optimism].twFactory,
  [ChainId.OptimismGoerli]: CONTRACT_ADDRESSES[ChainId.OptimismGoerli].twFactory,
  [ChainId.Arbitrum]: CONTRACT_ADDRESSES[ChainId.Arbitrum].twFactory,
  [ChainId.ArbitrumGoerli]: CONTRACT_ADDRESSES[ChainId.ArbitrumGoerli].twFactory,
  [ChainId.Avalanche]: CONTRACT_ADDRESSES[ChainId.Avalanche].twFactory,
  [ChainId.AvalancheFujiTestnet]: CONTRACT_ADDRESSES[ChainId.AvalancheFujiTestnet].twFactory,
  [ChainId.BinanceSmartChainMainnet]: CONTRACT_ADDRESSES[ChainId.BinanceSmartChainMainnet].twFactory,
  [ChainId.BinanceSmartChainTestnet]: CONTRACT_ADDRESSES[ChainId.BinanceSmartChainTestnet].twFactory,
};

export function getExplorerApiUrl(network: string): string {
  const alchemyKey: string = process.env.ALCHEMY_KEY || "";
  const polygonNetworkName = network === "polygon" ? "mainnet" : "mumbai";

  let nodeUrl =
    network === "polygon" || network === "mumbai"
      ? `https://polygon-${polygonNetworkName}.g.alchemy.com/v2/${alchemyKey}`
      : `https://eth-${network}.alchemyapi.io/v2/${alchemyKey}`;

  switch (network) {
    case "optimism":
      nodeUrl = `https://opt-mainnet.g.alchemy.com/v2/${alchemyKey}`;
      break;
    case "optimism-goerli":
      nodeUrl = `https://opt-goerli.g.alchemy.com/v2/${alchemyKey}`;
      break;
    case "arbitrum":
      nodeUrl = `https://arb-mainnet.g.alchemy.com/v2/${alchemyKey}`;
      break;
    case "arbitrum-goerli":
      nodeUrl = `https://arb-goerli.g.alchemy.com/v2/${alchemyKey}`;
      break;
    case "avalanche":
      nodeUrl = "https://api.avax.network/ext/bc/C/rpc";
      break;
    case "avalanche-testnet":
      nodeUrl = "https://api.avax-test.network/ext/bc/C/rpc";
      break;
    case "fantom":
      nodeUrl = "https://rpc.ftm.tools";
      break;
    case "fantom-testnet":
      nodeUrl = "https://rpc.testnet.fantom.network";
      break;
    case "binance":
      nodeUrl = "https://bsc-dataseed1.binance.org/";
      break;
    case "binance-testnet":
      nodeUrl = "https://data-seed-prebsc-1-s1.binance.org:8545/";
      break;
  }

  return nodeUrl;
}
