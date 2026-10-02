# Signer runbook

One page for the three Signers of the Nut Vault (engineering spec §6, monitoring requirement). The contracts have
no owner, no proxy and no pause: when an alert fires, the only levers are the ones below, every one of them a
2-of-3 signature, and comms. The watcher that raises the alerts lives in `nutz-platform`; this page says what
each alert means and what the Signers do about it.

## The levers

| Lever | Contract | Effect | Delay |
|---|---|---|---|
| stop signing | off-chain | the Keeper alone cannot post a Root: Sweeps keep funding Epochs, the funding waits in Carry, nothing is lost, claims on Final Roots continue | none |
| `voidRoot(kind, id, sig1, sig2)` | Distributor | rejects the latest Root of that kind inside its Dispute window (`CLAIM_DELAY`, 30 min from `rootPostedAt`); Carry is restored, the period keeps its funding, a corrected Root for the same id is posted next | none |
| `setRateRange(min, max)` | Distributor | the floor and ceiling of the USDG/ETH rate the Keeper may pass to `pushClaims`; the floor is also the least USDG the Converter's ETH→USDG Leg (98 % of every Sweep) accepts | none |
| `setKeeper(keeper)` | both | replaces the Keeper at once (each contract separately, same two signatures over each domain) | none |
| `disableLeg(stock)` | Converter | the circuit breaker: that Stock Token's share of the Stash is paid as USDG until `proposeLegEnable` / `executeLegEnable` | none / 48 h |
| `setOpsCap(cap)` | Converter | `0` turns the Ops Slice off | none |
| `cancel(id)` | both | removes a scheduled timelocked action (`Scheduled(id, readyAt)`) before it executes | none |
| `proposeSignerRotation(from, to)` / `executeSignerRotation` | both | replaces a Signer key | 48 h, then 7 days to execute |
| `proposeExclusion` / `executeExclusion`, `proposeDrawContract` / `executeDrawContract` | Distributor | append an Excluded address; set the Draw contract | 48 h |

Every 2-of-3 action consumes the contract's global `nonce`: a signature prepared for the old nonce is dead after any
other action lands. Sign one action at a time, in the order you mean to send them.

## The alerts

| Alert | Means | Do |
|---|---|---|
| `RootPosted` and no `nutz-verify` MATCH for it within 20 min (the watcher pages at minute 20 of the 30-minute window, so a void still fits) | the posted Root is not what the public rules recompute (MISMATCH), or it cannot be checked (INDETERMINATE: RPC, finality, the verifier's own pin) | MISMATCH: `voidRoot` before `rootPostedAt + 30 min`, then stop signing until the cause is known. INDETERMINATE still unresolved at minute 20: void anyway; a void costs nothing, a Final bad Root costs that Epoch. Only the latest Root of a kind can be voided: act before the next one |
| any governance event you did not initiate: `Scheduled`, `Executed`, `Cancelled`, `SignerRotated`, `KeeperSet`, `RateRangeSet`, `DrawContractSet`, `ExcludedAppended`, `LegDisabled`, `LegEnabled`, `OpsCapSet` | two Signer keys signed something the Signers did not decide: two keys compromised, or the warm Signer and the KMS key were made to sign | stop signing. `cancel(id)` anything `Scheduled` (the 48 h timelock is the window). If the Keeper or the KMS key is suspect, `setKeeper` on both contracts now, then `proposeSignerRotation` for the suspect key. Call SEAL 911 |
| `NutzBound` you did not expect | the Keeper re-bound the Converter to another launch; the Sweep pulls that launch's fees and sells its token | `setKeeper` if the Keeper key is suspect; otherwise the Keeper re-binds NUTZ |
| Pons `CreatorFeeRecipientChangeProposed` / `CreatorFeeRecipientUpdated` for NUTZ, or `pendingCreatorFeeRecipient(NUTZ) != 0` | the Pons owner is redirecting NUTZ's creator fees away from the Converter (3-day notice) | nothing on-chain can stop it. Fees already credited to the escrow stay claimable by the next Sweep. Announce within the 3 days; funds at rest are not exposed |
| Distributor balance of a Reward Token below `Σ (funded − claimed) + Σ stuck` for that token (plus `acornPoolUsdg` for USDG) | tokens left the Distributor that no Allocation, Stuck record or Acorn pool accounts for: the theft invariant (§7) is broken | stop signing. `voidRoot` any Root still in its window. SEAL 911, then `SECURITY.md` comms. Claims on Final Roots cannot be stopped; say so plainly |
| `Stuck(account, token, amount)` | a Reward Token transfer to a Holder failed (issuer pause or blocklist); the amount waits in `stuck` for `claimStuck` | one Holder, one token: nothing. Many Holders, one token in one hour: the issuer paused or blocked the Distributor; `disableLeg(stock)` so the Sweep pays that share as USDG; `proposeLegEnable` when the issuer resumes |
| one Leg skipped (`LegSkipped`) three Sweeps in a row | no liquidity, a wrong Route, or a paused token; that ETH stays in the Converter for the next Sweep | whoever runs the Keeper reads the Route. Paused or blocked token: `disableLeg`. Not a signing matter otherwise |
| the Keeper's ETH trending down despite the Ops Slice; a Root not posted within 20 min of the Epoch end | liveness, not safety | whoever runs the Keeper. Keep signing |

Any MISMATCH, any alert still unexplained after an hour, any doubt about the Keeper key: stop signing. The system
is built so that refusing to sign loses nothing.

## The rate range

`minUsdgPerEth` is the floor a compromised Keeper cannot push the ETH→USDG Leg under (review 2026-09, F06), and
it is only as tight as the Signers keep it. Keep it near 80 % of spot: higher and the Leg is skipped on a dip
(the ETH waits in the Converter, nothing lost); lower and the floor is loose. Review it weekly and after any 20 %
move; `setRateRange` is instant.

## Who to call, what to say

- Active exploit and the Signers cannot be reached: SEAL 911, Telegram `@seal_911_bot` (`SECURITY.md`).
- Addresses, status and incident notes go to nutz.wtf and @stacknutz only. Before anything is final: what is
  known, what the Signers did (voided Root `id`, stopped signing), what Holders should do (nothing; claims on
  Final Roots keep working; a corrected Root follows), and when the next update comes.
- Never say "audited". The contracts are internally reviewed at the commit in `SECURITY.md` and not externally
  audited.
