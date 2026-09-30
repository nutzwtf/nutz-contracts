# Review: NutzDraw and the vendored BLS verifier

- Contract: `NutzDraw` (`src/NutzDraw.sol`, `src/interfaces/INutzDraw.sol`)
- Vendored verifier: `src/vendor/bls/BLS2.sol`, `src/vendor/bls/Precompiles.sol` (randa-mu/bls-solidity v0.3.0)
- Consumer read: `src/NutzDistributor.sol` (`pullAcorn`, `notifyDrawFunding`, `_requireFulfilled`, the `Kind.Draw` branch of `postRoot`, `currentDraw`)
- Spec: engineering-spec §3.4, §4.6, §5 weekly steps, §6, §10 step 2; ADR-0004
- Commit tag: `review-2026-09-rc1` = 74d724c
- Method: source and spec only; no tests read, none run. Field constants were re-derived offline (see "Verified numerically").

## Checklist

| # | Item | Verdict |
|---|---|---|
| 1 | §6 bad root | N/A for the Draw: it posts nothing; `postRoot(Kind.Draw)` stays 2-of-3 in the Distributor and needs `drawConverted[id]` plus a Seed (NutzDistributor.sol:274-277). |
| 1 | §6 keeper key compromise | **FINDING F-1**: the Keeper alone can re-roll the Seed by re-requesting after the committed round is public. Otherwise bounded: `requestDraw` is `DISTRIBUTOR.keeper()` read at call time (NutzDraw.sol:108), the Draw moves no funds. |
| 1 | §6 router/token behaviour, blocklist/pause | N/A: no token is touched by the Draw. |
| 1 | §6 Pons threats | N/A. |
| 1 | §6 reentrancy | OK: `fulfill` makes only precompile `staticcall`s; `requestDraw` makes two view calls to an immutable address before any write; no ETH, no tokens. |
| 1 | §6 sybil/farming | OK on-chain: the 1%-of-supply Ticket cap is an indexer rule (§4.6); nothing in the Draw depends on balances. |
| 1 | §6 no admin backdoors | OK: no owner, no setter, no pause; `_publicKey`/`_selfTestVector` are `internal pure virtual` (only a subclass at compile time can change them; a deployed `NutzDraw` cannot). |
| 2 | SOL-HMT-1..5 | N/A: no Merkle proof is verified in the Draw; `ticketsRoot` is an opaque commitment never read on-chain. |
| 2 | SOL-Signature-1..5, SOL-AM-ReplayAttack-1..2 | OK (BLS, not ECDSA): the round is bound into the message (`sha256(uint64 round)`, NutzDraw.sol:181), the DST binds the scheme; `lastRound` makes rounds strictly increasing so one signature never seeds two draws (NutzDraw.sol:116-119); a replacement Draw starts at `lastRound = 0` but can only commit rounds ≥ 10 min ahead, so it cannot reuse an old one; cross-chain replay is meaningless (drand signatures are public). No malleable second encoding verifies: the other sign bit gives −σ, and an `x + p` encoding (23% of x values fit under 2^381) is a field element ≥ p that the pairing precompile rejects. No `ecrecover`, so no `address(0)`. |
| 2 | SOL-LL-4 | OK with note (F-3, Info): the success flag is checked on all five precompile `staticcall`s (BLS2.sol:124, 157, 283, 288, 374). `returndatasize()` is never checked; harmless because every output is fixed-size and an absent precompile (success with empty return) is caught by the constructor self-test. |
| 2 | SOL-McCc-1, 3, 12 | OK: only `block.timestamp` is read (NutzDraw.sol:116, 157); no `block.number`, no `prevrandao`, no `blockhash`. `mcopy` (BLS2.sol:267) and PUSH0 need Cancun/Prague, which §9 Q4 records as live on ArbOS 61; the self-test would fail deployment otherwise. |
| 2 | SOL-Defi-AS-12 | N/A. |
| 3 | Merkle leaf domain separation | N/A (no leaves in the Draw). |
| 4 | Arbitrum semantics | OK with note (F-2, Info): `roundAt(block.timestamp + LEAD)` measures the 10-minute lead on the sequencer clock; a clock more than 10 min behind real time commits an already-published round. `currentRound()` ahead of real time only makes `fulfill` fail until drand publishes (retry). Timestamps are non-decreasing, so `lastRound + 1` covers the same-round case. |
| 5 | Stock Token pause/blocklist | N/A. |
| 6 | G1ADD subgroup | OK: the only G1ADD input is the two `MAP_FP_TO_G1` outputs (BLS2.sol:279, 286), which EIP-2537 returns cofactor-cleared, and the subgroup is closed under addition. The signature point is decompressed by `g1UnmarshalCompressed` and goes straight to `PAIRING_CHECK` (BLS2.sol:372), which must subgroup-check and errors on failure → `callSuccess = false` → `InvalidSignature`. Off-curve x (non-residue x³+4) and x ≥ p also fail there. The infinity flag is refused twice (NutzDraw.sol:172, BLS2.sol:94). |
| 7 | Constructor args in robinhood.json | OK/N-A: the Draw takes only `distributor`, produced by the deploy script; nothing Draw-specific is in the config. `GENESIS = 1_692_803_367`, `PERIOD = 3` match quicknet's published values; `DST` (43 bytes) matches `bls-unchained-g1-rfc9380`; the x-limbs of `_publicKey` match the compressed key `0x83cf0f28…ece45a` (flag byte 0x83 = compressed, sign clear, top limb 0x03cf0f28…). |
| 8 | Static analysis: BLS2.sol:370 | False positive: `uint256[1] memory out` is zero-initialised by Solidity; on a failed call `out[0]` stays 0 and `verifySingle` returns `(false, false)`. NutzConverter items: not in scope. |
| 9 | Anything else | See F-1..F-3 and "Notes". |

Count: OK 11, N/A 8 (several §6 rows collapsed), findings 3 (1 Medium, 2 Info).

## Verified numerically (offline, Python)

- `P_PLUS_ONE_SLASH_2` (BLS2.sol:46-47) equals (p+1)/4, not (p+1)/2 as its name says; p ≡ 3 mod 4, so `a^((p+1)/4)` is the correct square root. Name misleading, value right.
- `N_G2_*` (BLS2.sol:34-41) is exactly the negated BLS12-381 G2 generator (x unchanged, y = p − y_gen for both Fp2 coordinates), so the pairing tests e(σ, −G2)·e(H(m), PK) = 1 ⇔ e(σ, G2) = e(H(m), PK). Input layout: G1 (x_hi, x_lo, y_hi, y_lo), G2 (x0, x1, y0, y1) with 16 zero bytes ahead of each 48-byte limb, 24 words = 768 bytes (BLS2.sol:344-372) matches EIP-2537.
- Sign-flag handling (BLS2.sol:97-99, 169-174): variable `larger` is set when the sign bit is *clear*, but the double negation on line 170 yields the zcash rule (bit set → lexicographically larger y). Correct.
- `expandMsg` (BLS2.sol:296-331) is RFC 9380 §5.3.1 byte for byte: 64-byte Z_pad for SHA-256, `I2OSP(128, 2) = 0x00 0x80`, `I2OSP(0,1)`, DST ‖ len(DST), then b_i = H((b_0 ⊕ b_{i−1}) ‖ i ‖ DST'). `hashToPoint` reduces two 64-byte chunks mod p, maps each, adds: equal to the RFC's clear_cofactor(Q0 + Q1) because cofactor clearing is a group homomorphism.
- E(Fp) has odd order (cofactor 0x396c…aaab is odd), so `y = 0` never occurs and `alt_y = p − y` is always < p.
- `VECTOR_SIG` flag byte 0xb4: compressed set, infinity clear, sign set; passes both flag checks. That it is quicknet's round-1000 signature was not verifiable offline; the constructor proves it against the key at deploy.

## Findings

### F-1 The Keeper can re-roll the Seed: re-request is allowed after the committed round is public

- Severity: Medium (bounded loss: one week's Golden Acorn per week, with every verifier reporting MATCH)
- Location: `src/NutzDraw.sol:105-124` (`requestDraw` has no check that `d.round` is still in the future); `src/NutzDraw.sol:133-146` (`fulfill` is the only thing that closes the window and nobody but the Keeper is incentivised to call it)
- Spec line: §3.4 "Commits the Ticket list … **and** the target round … both before the beacon value exists, so nobody can choose the Ticket list with knowledge of the Seed"; §6 "keeper key cannot post a root alone" (the bias here needs no root of its own: the honest 2-of-3 signs the winners the re-rolled Seed selects). ADR-0004: "the Keeper cannot choose a Ticket list with knowledge of the outcome".
- Transaction sequence (Sunday 00:00 UTC, week d just ended; `acornPoolUsdg = 10,000 USDG`; wallet A, controlled by whoever holds the Keeper key, holds enough NUTZ to have the capped 1% of all Tickets; nobody else runs a fulfil bot):
  1. Keeper: `requestDraw(d, root, 100_000)` at t₀ → `round = R₀ = roundAt(t₀ + 600)`, `lastRound = R₀`.
  2. t₀ + 600 s: drand publishes round R₀; the Keeper reads `randomness_R₀` from the API and runs §4.6 selection locally: A is not the Golden winner.
  3. Keeper: `requestDraw(d, root, 100_000)` again at t₀ + 605 s. Checks: keeper ✓, `d < currentDraw()` ✓, `seed == 0` ✓, tickets non-zero ✓. New `round = max(roundAt(t₀ + 1205), R₀ + 1) = R₁`; root and count unchanged; `DrawRequested` emitted again.
  4. Repeat steps 2-3 every ~10 min. After k rolls the probability that some Rₖ makes A the Golden winner is 1 − 0.99ᵏ: 45% after 60 rolls (10 h), 76% after 140 rolls (24 h).
  5. On a favourable Rₖ: Keeper `fulfill(d, σ_Rₖ)` → `seed = sha256(σ_Rₖ)`, final. Then `convertAcorn(d)`, then `postRoot(Kind.Draw, d, …)` with A as Golden winner; `nutz-verify` recomputes from the on-chain Seed and the on-chain Ticket list and reports MATCH; the warm signer signs.
  - End state: A collects the Golden Acorn (50% of P = 5,000 USDG in stocks) with probability ≈ 0.76 instead of 0.01; expected misdirection ≈ 3,750 USDG per week, repeatable weekly, invisible to the verifier (each `DrawRequested` is a legitimate event; the spec allows re-requests).
- Impact: the property the whole design buys with an on-chain pairing check (the Keeper cannot influence the outcome) does not hold for the Keeper key. The Draw contract holds no funds, so nothing is frozen; the loss is the Acorn pool's fairness.
- Suggested fix: refuse a re-request once the committed round is due, i.e. in `requestDraw`: `if (d.round != 0 && currentRound() >= d.round) revert RoundAlreadyDue(drawId)` (or reuse `AlreadyFulfilled`). This keeps the two legitimate re-request cases that matter: a wrong Ticket list caught before the round (still allowed) and a retired beacon (ADR-0004 already answers that with a new Draw contract and Skipped weeks; quicknet signs every missed round on recovery, so "a round that can never be fulfilled" has no other cause). Spec §3.4 line 177 should drop "a round that can never be fulfilled" from the re-request reasons. Until fixed: a public fulfil bot that submits every due round narrows the window to a race but does not close it (the Keeper must read the beacon before deciding, so the bot can win, but not reliably on an FCFS sequencer).

### F-2 The 10-minute lead is measured on the sequencer clock

- Severity: Info (needs the single sequencer operator's clock to be more than 10 min behind real time; no deviation from the spec text, which defines `roundAt(block.timestamp + 10 min)`)
- Location: `src/NutzDraw.sol:116` (`roundAt(block.timestamp + LEAD)`), `:37` (`LEAD = 10 minutes`)
- Spec line: §3.4 "the target round R … before the beacon value exists"; checklist item 4 (timestamp may lag real time by up to 24 h).
- Sequence: sequencer clock at real − 15 min. Keeper `requestDraw(d, …)` at sequencer time t → `R = roundAt(t + 600)`, whose signature drand published 5 min ago. The Keeper knows the Seed before committing; combined with F-1 the roll costs nothing (no 10-min wait). Without F-1 the Keeper still cannot alter the deterministic Ticket list without the warm signer's MISMATCH, so the residual is the timing choice only.
- Suggested fix: none required in code; record the sequencer-clock assumption in §3.4 and have the watcher page when `DrawRequested.round <= roundAt(now_real)`.

### F-3 Return-data size not checked on the five precompile calls (SOL-LL-4)

- Severity: Info
- Location: `src/vendor/bls/BLS2.sol:120, 153, 274, 279, 286, 372`
- Spec line: none violated; checklist item SOL-LL-4.
- Sequence: on a chain where address 0x0f has no code, `staticcall` returns success with empty data; `out[0]` stays 0 → `(false, true)` → `_verify` false → constructor reverts `VerifierSelfTestFailed`. On a chain where 0x10 or 0x0b has no code, the message point becomes zeros and the pairing rejects the encoding. So a missing precompile can never yield a *valid* Seed; the failure mode is a refused deployment, which is the intended one (NutzDraw.sol:65-67, 90-91). MODEXP (0x05) is pre-Byzantium and always present.
- Suggested fix: optional `returndatasize()` equality checks in the vendored library (would be the first functional edit to the vendored code; the constructor self-test already covers the realistic case).

## Notes (no deviation)

- Gas griefing: a signature the pairing rejects burns the forwarded `gas()` (EIP-2537 error semantics); only `msg.sender` pays, state is untouched, and the cheap `length`/flag checks run first (NutzDraw.sol:140). Front-running the Keeper's `fulfill` with the correct signature yields the same Seed; with a wrong one it reverts. No stall is possible.
- `fulfill` on a re-requested draw verifies against the *current* `d.round` only; a signature for a superseded round fails.
- `requestDraw` accepts any `drawId < currentDraw()`, including ids the Distributor already rooted or ids far in the past (e.g. 0). Harmless: the Distributor's `pullAcorn` requires `drawId > drawBook.rootedThrough` and `postRoot` orders draws; a stray request only spends `lastRound` values.
- `pullAcorn` calls `drawContract.seedOf` (STATICCALL to a 2-of-3-timelocked address) before any state change and under `nonReentrant`; a replacement Draw returns 0 for the old contract's draws, so pending weeks are Skipped as ADR-0004 states. The pool released is the *whole* `acornPoolUsdg` at conversion time, including Slices funded after the Seed was known; this changes prize size, never winners.
- `roundAt` underflows (reverts) for `timestamp < GENESIS`, unreachable on a live chain; `SafeCast.toUint64` never trips for any realistic timestamp.
- `g1UnmarshalCompressed` reverts with strings on length/flag errors; `fulfill` screens both first, so `InvalidSignature` is the only revert on bad input, as §3.4 states. The constructor path would revert with the library string instead of `VerifierSelfTestFailed` for a malformed vector; still a refused deployment.
- The Draw never checks the committed `ticketsRoot` against anything; it is a public commitment for the verifier. Whether `nutz-verify` compares its recomputed Ticket root to `draws[d].ticketsRoot` is outside this scope; if it does not, the on-chain commitment is decorative but nothing is lost, since winners derive from the recomputed list.
