<p align="center">
<br />
<a href="https://thirdweb.com"><img src="https://github.com/thirdweb-dev/typescript-sdk/blob/main/logo.svg?raw=true" width="200" alt=""/></a>
<br />
</p>
<h1 align="center">thirdweb Contracts</h1>
<p align="center">
<a href="https://www.npmjs.com/package/@thirdweb-dev/contracts"><img src="https://img.shields.io/npm/v/@thirdweb-dev/contracts?color=red&logo=npm" alt="npm version"/></a>
<a href="https://github.com/thirdweb-dev/contracts/actions"><img alt="Build Status" src="https://github.com/thirdweb-dev/contracts/actions/workflows/tests.yml/badge.svg"/></a>
<a href="https://discord.gg/thirdweb"><img alt="Join our Discord!" src="https://img.shields.io/discord/834227967404146718.svg?color=7289da&label=discord&logo=discord&style=flat"/></a>

</p>
<p align="center"><strong>Collection of smart contracts deployable via the thirdweb SDK, dashboard and CLI</strong></p>
<br />

## Installation

```shell
# Forge projects
forge install https://github.com/thirdweb-dev/contracts

# Hardhat / npm-based projects
npm i @thirdweb-dev/contracts
```

```bash
contracts
|
|-- extension: "extensions that can be inherited by NON-upgradeable contracts"
|   |-- interface: "interfaces of all extension contracts"
|   |-- upgradeable: "extensions that can be inherited by upgradeable contracts"
|   |-- [$prebuilt-category]: "legacy extensions written specifically for a prebuilt contract"
|
|-- base: "NON-upgradeable base contracts to build on top of"
|   |-- interface: "interfaces for all base contracts"
|   |--  upgradeable: "upgradeable base contracts to build on top of"
|
|-- prebuilt: "audited, ready-to-deploy thirdweb smart contracts"
|   |-- interface: "interfaces for all prebuilt contracts"
|   |--[$prebuilt-category]: "feature-based group of prebuilt contracts"
|   |-- unaudited: "yet-to-audit thirdweb smart contracts"
|       |-- [$prebuilt-category]: "feature-based group of prebuilt contracts"
|
|-- infra: "onchain infrastructure contracts"
|   |-- interface: "interfaces for all infrastructure contracts"
|
|-- eip: "implementations of relevant EIP standards"
|   |-- interface "all interfaces of relevant EIP standards"
|
|-- lib: "Solidity libraries"
|
|-- external-deps: "modified / copied over external dependencies"
|   |-- openzeppelin: "modified / copied over openzeppelin dependencies"
|   |-- chainlink: "modified / copied over chainlink dependencies"
|
|-- legacy-contracts: "maintained legacy thirdweb contracts"
```

## Running Tests

1. `yarn`: install contracts dependencies
2. `forge install`: install tests dependencies
3. `forge test`: run the tests

This repository is a [forge](https://github.com/foundry-rs/foundry/tree/master/forge) project.

First install the relevant dependencies of the project:

```bash
yarn

forge install
```

To compile contracts, run:

```bash
forge build
```

To run tests:

```bash
forge test
```

## Pre-built Contracts

Pre-built contracts are written by the thirdweb team, and cover the most common use cases for smart contracts.

- [DropERC20](https://thirdweb.com/deployer.thirdweb.eth/DropERC20)
- [DropERC721](https://thirdweb.com/deployer.thirdweb.eth/DropERC721)
- [DropERC1155](https://thirdweb.com/deployer.thirdweb.eth/DropERC1155)
- [SignatureDrop](https://thirdweb.com/deployer.thirdweb.eth/SignatureDrop)
- [Marketplace](https://thirdweb.com/deployer.thirdweb.eth/Marketplace)
- [Multiwrap](https://thirdweb.com/deployer.thirdweb.eth/Multiwrap)
- [TokenERC20](https://thirdweb.com/deployer.thirdweb.eth/TokenERC20)
- [TokenERC721](https://thirdweb.com/deployer.thirdweb.eth/TokenERC721)
- [TokenERC1155](https://thirdweb.com/deployer.thirdweb.eth/TokenERC1155)
- [VoteERC20](https://thirdweb.com/deployer.thirdweb.eth/VoteERC20)
- [Split](https://thirdweb.com/deployer.thirdweb.eth/Split)

[Learn more about pre-built contracts](https://portal.thirdweb.com/pre-built-contracts)

## Extensions

Extensions are building blocks that help enrich smart contracts with features.

Some blocks come packaged together as Base Contracts, which come with a full set of features out of the box that you can modify and extend. These contracts are available at `contracts/base/`.

Other (smaller) blocks are Features, which provide a way for you to pick and choose which individual pieces you want to put into your contract; with full customization of how those features work. These are available at `contracts/extension/`.

[Learn more about extensions](https://portal.thirdweb.com/extensions)

## Contract Audits

- [Audit 1](audit-reports/audit-1.pdf)
- [Audit 2](audit-reports/audit-2.pdf)
- [Audit 3](audit-reports/audit-3.pdf)
- [Audit 4](audit-reports/audit-4.pdf)
- [Audit 5](audit-reports/audit-5.pdf)
- [Audit 6](audit-reports/audit-6.pdf)
- [Audit 7](audit-reports/audit-7.pdf)
- [Audit 8](audit-reports/audit-8.pdf)
- [Audit 9](audit-reports/audit-9.pdf)
- [Audit 10](audit-reports/audit-10.pdf)
- [Audit 11](audit-reports/audit-11.pdf)
- [Audit 12](audit-reports/audit-12.pdf)

## Bug reports

Found a security issue with our smart contracts? Send bug reports to security@thirdweb.com and we'll continue communicating with you from there. We're actively developing a bug bounty program; bug report payouts happen on a case by case basis, for now.

## Feedback

If you have any feedback, please reach out to us at support@thirdweb.com.

## Authors

- [thirdweb](https://thirdweb.com)

## License

[Apache 2.0](https://www.apache.org/licenses/LICENSE-2.0.txt)
