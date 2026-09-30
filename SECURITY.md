# Security policy and bug bounty

The NUTZ Nut Vault contracts have no owner, no upgrade path and no pause. If you find a way to take or lock funds, the only people who can act are the three Signers (off-chain: stop signing, void a Root) and whitehats under the Safe Harbor below. Tell us fast and we will act fast.

**Status:** not externally audited. The internal review is in progress; its summary (`docs/security/internal-review-2026-09.md`) and the frozen commit it covers will be linked here when it lands.

## Contact

- Preferred: GitHub private vulnerability reporting on this repository — **Security → Report a vulnerability** ([new advisory](https://github.com/nutzwtf/nutz-contracts/security/advisories/new)).
- A `security@` mailbox will be added here at launch. Until then, GitHub is the only channel; please do not report through public issues, X or Telegram.
- Active exploit in progress and you cannot reach us: contact SEAL 911, the free 24/7 whitehat hotline of the Security Alliance — Telegram [@seal_911_bot](https://t.me/seal_911_bot) ([about](https://securityalliance.org/our-work/seal-911)). They can reach us and coordinate a response.

## Scope

Robinhood Chain (chain id 4663). Addresses are filled in at deploy, with the frozen commit; until then nothing is deployed and this table is the list of what will be in scope.

| Contract | Source | Address | Deployed commit |
|---|---|---|---|
| `NutzDistributor` (with `Signers`) | `src/NutzDistributor.sol`, `src/Signers.sol` | TBD at deploy | TBD at deploy |
| `NutzConverter` | `src/NutzConverter.sol` | TBD at deploy | TBD at deploy |
| `NutzDraw` (with the vendored BLS12-381 verifier `src/vendor/bls/`) | `src/NutzDraw.sol` | TBD at deploy (deployed after launch, see the engineering spec §6 scope rule) | TBD at deploy |

Verify an address before you spend time on it: the only authoritative sources are this file, nutz.wtf and @stacknutz. The deployed bytecode is verified on Blockscout and Sourcify and checked with `forge verify-bytecode` against the commit in the table.

**Out of scope:** `nutz-platform` (keeper, indexer, API, dashboard), the nutz.wtf website, the Pons launchpad contracts, the Uniswap v3 and v4 contracts, the Stock Token and USDG issuer contracts, third-party RPC providers, the drand network, and anything that needs a compromised Signer or Keeper key as its starting point (key compromise is a threat we model, not a finding). Findings in those systems are welcome as information but are not eligible for a reward here; report platform issues to their owners.

## Rules

- **No exploitation on mainnet beyond what proves the finding.** Reproduce on a fork or a local Anvil chain. A Foundry test in this repo's layout is the best possible report. If a mainnet transaction is unavoidable to prove it, keep it to the minimum value and tell us before you send it.
- **No denial of service** against the contracts, the Keeper, the RPC providers or the website; no spam transactions, no gas griefing "to demonstrate".
- **No social engineering** of the Signers, the Keeper operator or Robinhood, Pons or Uniswap staff. No physical or account attacks.
- **Do not touch other people's funds.** If a bug lets you move a Holder's Allocation, prove it against your own address on a fork.
- **Coordinated disclosure.** Do not publish before we have fixed or mitigated and agreed on a date. We publish every valid finding with credit once it is resolved, within 90 days of the report at the latest.
- First complete report of a root cause is the one rewarded; duplicates are credited. One reward per root cause, however many entry points reach it.
- Publicly known issues, findings already listed in the internal review summary once it is published, and anything the engineering spec §6 documents as accepted residual risk are not eligible.

## Reward

Paid for findings that put funds at risk in an in-scope contract:

- **10% of the funds at risk** demonstrated by the finding, **capped at 10,000 USDG per finding**.
- "Funds at risk" is the amount your proof shows could be taken or permanently locked, measured against the in-scope balances at the time of the report, not a hypothetical future balance.
- Paid in USDG on Robinhood Chain to an address you name. The bounty is funded from the Ops Slice (the 2% of inflows that pays the system's own gas); if the Ops balance is short, the payment is scheduled as the Slice accrues and the date is agreed with you in writing before disclosure. There is no external bounty pool yet: the programme is self-hosted at launch and will be listed on a bounty platform once fees have funded a pool.
- Findings with no funds at risk (an availability bug in the Sweep, a wrong event, a documentation mismatch) are acknowledged and credited; a reward for them is at our discretion.
- Rescues performed under the Safe Harbor below are rewarded on the same terms, on the value returned.

Report the finding with the impact, the preconditions, a reproduction (test or transaction sequence), and the address to pay.

## Safe Harbor

We adopt the [SEAL Whitehat Safe Harbor](https://frameworks.securityalliance.org/safe-harbor/overview/) agreement of the Security Alliance ([agreement text and registry contracts](https://github.com/security-alliance/safe-harbor)). In plain words: if an exploit is active or imminent against an in-scope contract, a whitehat who follows the agreement may intervene to rescue funds, return them to the asset recovery address below, and claim the bounty above, and we will not pursue them for it.

- Asset recovery address: TBD at deploy (published here and registered on-chain in the Safe Harbor registry at deploy; until then this file is the adoption statement).
- Scope of the Safe Harbor is the table above. Returned funds are reconciled and paid out to Holders through a corrected Root; a rescue is not a licence to keep anything beyond the bounty.
- The agreement's own terms control where this summary is looser.

## Response times

| Step | Target |
|---|---|
| Acknowledge the report | 48 hours |
| Triage and first assessment (in scope, severity, funds at risk) | 7 days |
| Mitigation | as fast as the Signers can act: stop signing, `voidRoot` inside the Dispute window, disable a Leg; a fix is a redeploy, since nothing is upgradable |
| Reward payment | within 30 days of confirming the finding, or on the schedule agreed under "Reward" |
| Public disclosure with credit | after the fix, within 90 days of the report |

One person answers reports today. Targets are targets, not guarantees; if we are late you will hear why.

## What we will never claim

These contracts are not described as audited anywhere until an external audit is published. Read the engineering spec §6 for the threat model, what the per-Root cap bounds (a bad Root misdirects at most one Epoch) and what it does not (the Distributor holds every unclaimed Allocation, every stuck amount and the Acorn pool until claimed or pushed).
