# Verifying the deployment

The Nut Vault's contracts on Robinhood Chain (chain ID 4663) are built from this repository's tag `v1.0.0`. Two
independent ways to check that the code on chain is this code:

1. **Sourcify** (no tools needed): each contract has an *exact match*, which binds the deployed bytecode, both the
   creation code and the runtime code, to these sources and the compiler's metadata.
2. **Rebuild it yourself** (Foundry): `scripts/verify-deploy.sh` compiles the tag and compares, byte for byte, what it
   builds with what the chain holds.

## The contracts

| Contract | Address | Sourcify |
| --- | --- | --- |
| NutzDistributor | _filled in at launch_ | `https://repo.sourcify.dev/4663/<address>` |
| NutzConverter | _filled in at launch_ | `https://repo.sourcify.dev/4663/<address>` |
| NutzDraw | _filled in at launch_ | `https://repo.sourcify.dev/4663/<address>` |

Compiler: solc `0.8.37+commit.f401782d`, EVM `prague`, optimizer on, 10,000 runs (`foundry.toml`). The constructor
arguments are `script/config/robinhood.json`, encoded by `Deploy.args`.

Robinhood Chain's Blockscout does not show the source: its compiler list stops at 0.8.36, and its Sourcify import
predates Sourcify's current API. That is the explorer's limitation, not the contracts'; Sourcify holds the
verification.

## Rebuild it yourself

You need [Foundry](https://getfoundry.sh) (this repo pins `1.8.3` in `.mise.toml`), git and jq.

```sh
git clone --recurse-submodules --branch v1.0.0 https://github.com/nutzwtf/nutz-contracts.git
cd nutz-contracts
RPC_4663=https://rpc.mainnet.chain.robinhood.com \
  scripts/verify-deploy.sh <distributor> <converter> <draw> --tag v1.0.0 --no-explorers
```

For each contract it checks:

- **creation**: the transaction that created the address carried exactly `creationCode ++ constructor args`, built
  from this tag and `robinhood.json`. The transaction hashes come from the deploy log committed at the tag,
  `broadcast/Deploy.s.sol/4663/`.
- **runtime**: the creation code, re-run at the same address (an `eth_call` with state overrides), returns exactly
  the code the chain stores. That covers the source, the compiler settings, the metadata hash and the immutables.

It ends with `OK: creation and runtime bytecode match the frozen commit and the config for every contract`. Any
other ending names the contract and the check that failed. `--no-explorers` skips the submissions to Sourcify and
Blockscout, which only the deployer needs.

The public endpoint is enough. The script was run this way against the dry run's deployment on 2026-10-06.
