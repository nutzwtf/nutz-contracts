// Generates test/fixtures/bls/*.json for the vendored BLS12-381 verifier (security-review ticket 03, ADR-0001
// pattern: generated offline, committed, never produced by `forge test`):
//
//   rfc9380-expand-message-xmd.json  RFC 9380 K.1 expand_message_xmd(SHA-256) vectors, short and oversize DST
//   rfc9380-hash-to-curve-g1.json    RFC 9380 J.9.1 BLS12381G1_XMD:SHA-256_SSWU_RO_ vectors
//   eip2537.json                     EIP-2537 precompile vectors, positives and every fail-* file
//   quicknet-rounds.json             500+ real drand quicknet rounds, each re-verified with @noble/curves
//   quicknet-negatives.json          malformed and wrong signatures built with @noble/curves, each carrying noble's
//                                    accept/reject decision and the rejection path the Solidity verifier must take
//
// Upstream data is fetched at pinned commits (RFC and EIP vectors) and from api.drand.sh (round signatures are
// immutable once published), so re-running with the same constants below rewrites identical files. Every file
// carries the generator name, the upstream sources with their sha256, and a checksum of its own payload.
//
// Run: pnpm -C tooling gen:bls-fixtures     (network access needed; commit the output)
import { bls12_381 as bls } from "@noble/curves/bls12-381.js";
import { createHash } from "node:crypto";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

// ------------------------------------------------------------------------------------------------ constants

const GENERATOR = "tooling/src/gen-bls-fixtures.ts (pnpm -C tooling gen:bls-fixtures)";
const NOBLE = "@noble/curves 2.4.0";

/** cfrg/draft-irtf-cfrg-hash-to-curve, last commit touching poc/vectors (2021-12-28). */
const CFRG_COMMIT = "6ce20a1ff9397b9e1d4361a9a1bb79d6e63c9e98";
const CFRG_RAW = `https://raw.githubusercontent.com/cfrg/draft-irtf-cfrg-hash-to-curve/${CFRG_COMMIT}/poc/vectors/`;
/** ethereum/EIPs, last commit touching assets/eip-2537 (2025-04-10). */
const EIPS_COMMIT = "faaa35fff856a109c40d291e612447fadc2095fe";
const EIPS_RAW = `https://raw.githubusercontent.com/ethereum/EIPs/${EIPS_COMMIT}/assets/eip-2537/`;

/** EIP-2537 vector files kept, with the precompile each one targets. msm_G1_bls.json (3.6 MB) and msm_G2_bls.json
 *  (6.5 MB) are left out for size: the MSM precompiles are still exercised by mul_* (one-pair MSM) and fail-msm_*. */
const EIP_FILES: Record<string, number> = {
  "add_G1_bls.json": 0x0b,
  "fail-add_G1_bls.json": 0x0b,
  "mul_G1_bls.json": 0x0c,
  "fail-mul_G1_bls.json": 0x0c,
  "fail-msm_G1_bls.json": 0x0c,
  "add_G2_bls.json": 0x0d,
  "fail-add_G2_bls.json": 0x0d,
  "mul_G2_bls.json": 0x0e,
  "fail-mul_G2_bls.json": 0x0e,
  "fail-msm_G2_bls.json": 0x0e,
  "pairing_check_bls.json": 0x0f,
  "fail-pairing_check_bls.json": 0x0f,
  "map_fp_to_G1_bls.json": 0x10,
  "fail-map_fp_to_G1_bls.json": 0x10,
  "map_fp2_to_G2_bls.json": 0x11,
  "fail-map_fp2_to_G2_bls.json": 0x11,
};

/** drand quicknet (League of Entropy), scheme bls-unchained-g1-rfc9380. */
const QUICKNET_CHAIN = "52db9ba70e0cc0f6eaf7803dd07447a1f5477735fd3f661792ba94600c84e971";
const DRAND_API = `https://api.drand.sh/${QUICKNET_CHAIN}`;
const DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_";
const GENESIS = 1_692_803_367;
const PERIOD = 3;
/** The public key NutzDraw carries (compressed). The /info document must agree; the generator checks it. */
const QUICKNET_PK =
  "83cf0f2896adee7eb8b5f01fcad3912212c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451" +
  "0d1fec758c921cc22b0e17e63aaf4bcb5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a";
/** Rounds are spread evenly over [1, ROUND_CEILING]; the ceiling is fixed so a re-run picks the same rounds.
 *  Round 32,200,000 was published 2026-09-14 16:29 UTC. */
const ROUND_CEILING = 32_200_000;
const SPREAD_COUNT = 500;
/** Rounds the repo already cites: the self-test vector (1000), the fork test's round, the first three rounds. */
const NOTABLE_ROUNDS = [1, 2, 3, 1000, 32_181_360];
const FETCH_CONCURRENCY = 4;

// ------------------------------------------------------------------------------------------------- helpers

type Hex = `0x${string}`;
const hex = (b: Uint8Array | Buffer): Hex => `0x${Buffer.from(b).toString("hex")}`;
const unhex = (h: string): Buffer => Buffer.from(h.replace(/^0x/, ""), "hex");
const sha256 = (b: Uint8Array | Buffer | string): Buffer => createHash("sha256").update(b).digest();
const utf8 = (s: string): Buffer => Buffer.from(s, "utf8");
const bigToHex48 = (x: bigint): string => x.toString(16).padStart(96, "0");

const G1 = bls.G1.Point;
const Fp = G1.Fp;
const P = Fp.ORDER;
const sigs = bls.shortSignatures;

/** drand's message for a round: sha256 of the round as a big-endian uint64. */
function roundMessage(round: number): Buffer {
  const be = Buffer.alloc(8);
  be.writeBigUInt64BE(BigInt(round));
  return sha256(be);
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** api.drand.sh answers 429 under a burst; retry with backoff (the data itself never changes). */
async function fetchText(url: string): Promise<{ text: string; sha256: Hex }> {
  for (let attempt = 0; ; attempt++) {
    const res = await fetch(url);
    if (res.ok) {
      const text = await res.text();
      return { text, sha256: hex(sha256(text)) };
    }
    if ((res.status === 429 || res.status >= 500) && attempt < 8) {
      await sleep(500 * 2 ** attempt);
      continue;
    }
    throw new Error(`${url}: HTTP ${res.status}`);
  }
}

async function fetchJson<T>(url: string): Promise<{ data: T; sha256: Hex }> {
  const { text, sha256: digest } = await fetchText(url);
  return { data: JSON.parse(text) as T, sha256: digest };
}

async function mapLimited<T, R>(items: T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let next = 0;
  async function worker() {
    while (next < items.length) {
      const i = next++;
      out[i] = await fn(items[i]);
    }
  }
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, worker));
  return out;
}

type Source = { url: string; commit?: string; sha256: Hex; kept?: number; dropped?: number };

/** Writes `{ generator, ..., checksum, <payloadKey>: payload }` with the checksum over the payload alone. */
function writeFixture(name: string, header: Record<string, unknown>, payloadKey: string, payload: unknown) {
  const body = JSON.stringify(payload);
  const doc = { generator: GENERATOR, ...header, checksum: hex(sha256(body)), [payloadKey]: payload };
  const here = dirname(fileURLToPath(import.meta.url));
  const target = join(here, "..", "..", "test", "fixtures", "bls", name);
  mkdirSync(dirname(target), { recursive: true });
  writeFileSync(target, JSON.stringify(doc, null, 2) + "\n");
  const count = Array.isArray(payload) ? payload.length : Object.values(payload as object).flat().length;
  console.log(`wrote ${target} (${count} entries, checksum ${doc.checksum.slice(0, 18)}…)`);
}

// ------------------------------------------------------------------- 1. RFC 9380 expand_message_xmd (K.1)

type XmdFile = {
  DST: string;
  tests: { DST_prime: string; len_in_bytes: string; msg: string; uniform_bytes: string }[];
};

async function genExpandMessageXmd() {
  const files = ["expand_message_xmd_SHA256_38.json", "expand_message_xmd_SHA256_256.json"];
  const sources: Source[] = [];
  const vectors: { dst: Hex; dstReduced: Hex; lenInBytes: number; msg: Hex; uniformBytes: Hex }[] = [];
  for (const f of files) {
    const { data, sha256: digest } = await fetchJson<XmdFile>(CFRG_RAW + f);
    sources.push({ url: CFRG_RAW + f, commit: CFRG_COMMIT, sha256: digest, kept: data.tests.length });
    for (const t of data.tests) {
      // DST_prime is DST || I2OSP(len(DST), 1) after the RFC's oversize-DST reduction (§5.3.3); stripping the
      // length byte gives the DST the library must be handed when the raw one exceeds 255 bytes.
      const dstPrime = unhex(t.DST_prime);
      const dstReduced = dstPrime.subarray(0, dstPrime.length - 1);
      const dst = utf8(data.DST);
      if (dst.length <= 255 && !dst.equals(dstReduced)) throw new Error(`${f}: DST_prime disagrees with DST`);
      vectors.push({
        dst: hex(dst),
        dstReduced: hex(dstReduced),
        lenInBytes: Number(t.len_in_bytes),
        msg: hex(utf8(t.msg)),
        uniformBytes: hex(unhex(t.uniform_bytes)),
      });
    }
  }
  writeFixture(
    "rfc9380-expand-message-xmd.json",
    {
      description:
        "RFC 9380 K.1 expand_message_xmd(SHA-256) vectors. `dst` is the DST as the RFC states it (the second file's is " +
        "256 bytes, over the 255-byte limit); `dstReduced` is the DST after the RFC §5.3.3 oversize reduction, i.e. " +
        "DST_prime without its length byte, equal to `dst` when no reduction applies. `msg` and `uniformBytes` are hex.",
      sources,
    },
    "vectors",
    vectors,
  );
}

// ---------------------------------------------------------- 2. RFC 9380 BLS12381G1_XMD:SHA-256_SSWU_RO_ (J.9.1)

type H2cFile = {
  dst: string;
  vectors: { P: { x: string; y: string }; msg: string; u: string[] }[];
};

async function genHashToCurveG1() {
  const f = "BLS12381G1_XMD:SHA-256_SSWU_RO_.json";
  const { data, sha256: digest } = await fetchJson<H2cFile>(CFRG_RAW + f);
  const vectors = data.vectors.map((v) => {
    // Cross-check the vector with noble before writing it: a broken upstream fetch fails here, not in forge.
    const p = bls.G1.hashToCurve(utf8(v.msg), { DST: data.dst }).toAffine();
    if (p.x !== BigInt(v.P.x) || p.y !== BigInt(v.P.y)) throw new Error(`${f}: noble disagrees on msg ${v.msg}`);
    return { dst: hex(utf8(data.dst)), msg: hex(utf8(v.msg)), px: hex(unhex(v.P.x)), py: hex(unhex(v.P.y)) };
  });
  writeFixture(
    "rfc9380-hash-to-curve-g1.json",
    {
      description:
        "RFC 9380 J.9.1 BLS12381G1_XMD:SHA-256_SSWU_RO_ vectors: hash_to_curve(msg) under the RFC's test DST is the " +
        "affine G1 point (px, py), 48-byte big-endian field elements. Re-derived with noble before writing.",
      sources: [{ url: CFRG_RAW + f, commit: CFRG_COMMIT, sha256: digest, kept: vectors.length }],
    },
    "vectors",
    vectors,
  );
}

// ---------------------------------------------------------------------------------- 3. EIP-2537 vectors

type EipVector = { Input: string; Expected?: string; ExpectedError?: string; Name: string; Gas?: number };

async function genEip2537() {
  const sources: Source[] = [];
  const positive: { name: string; precompile: number; input: Hex; expected: Hex }[] = [];
  const fail: { name: string; precompile: number; input: Hex; expectedError: string }[] = [];
  for (const [f, precompile] of Object.entries(EIP_FILES)) {
    const { data, sha256: digest } = await fetchJson<EipVector[]>(EIPS_RAW + f);
    sources.push({ url: EIPS_RAW + f, commit: EIPS_COMMIT, sha256: digest, kept: data.length });
    for (const v of data) {
      if (v.ExpectedError !== undefined) {
        fail.push({ name: v.Name, precompile, input: hex(unhex(v.Input)), expectedError: v.ExpectedError });
      } else {
        positive.push({ name: v.Name, precompile, input: hex(unhex(v.Input)), expected: hex(unhex(v.Expected!)) });
      }
    }
  }
  writeFixture(
    "eip2537.json",
    {
      description:
        "EIP-2537 test vectors from ethereum/EIPs assets/eip-2537, every file except msm_G1_bls.json and " +
        "msm_G2_bls.json (multi-megabyte; the MSM precompiles are still covered by mul_* and fail-msm_*). `precompile` " +
        "is the address (0x0b G1ADD, 0x0c G1MSM, 0x0d G2ADD, 0x0e G2MSM, 0x0f PAIRING_CHECK, 0x10 MAP_FP_TO_G1, " +
        "0x11 MAP_FP2_TO_G2). Positives must return `expected` exactly; `fail` entries must make the precompile error.",
      sources,
    },
    "vectors",
    { positive, fail },
  );
}

// ---------------------------------------------------------------------------- 4. quicknet rounds (positives)

type DrandInfo = { public_key: string; period: number; genesis_time: number; hash: string; schemeID: string };
type DrandRound = { round: number; randomness: string; signature: string };

function chooseRounds(): number[] {
  const set = new Set<number>(NOTABLE_ROUNDS);
  for (let i = 0; i < SPREAD_COUNT; i++) {
    set.add(1 + Math.floor((i * (ROUND_CEILING - 1)) / (SPREAD_COUNT - 1)));
  }
  return [...set].sort((a, b) => a - b);
}

async function genQuicknetRounds(): Promise<{ pk: Buffer; sample: DrandRound }> {
  const info = await fetchJson<DrandInfo>(`${DRAND_API}/info`);
  const i = info.data;
  if (i.public_key !== QUICKNET_PK) throw new Error(`quicknet /info public_key ${i.public_key} != NutzDraw's`);
  if (i.genesis_time !== GENESIS || i.period !== PERIOD) throw new Error("quicknet /info genesis/period changed");
  if (i.hash !== QUICKNET_CHAIN || i.schemeID !== "bls-unchained-g1-rfc9380") throw new Error("not quicknet");
  const pk = unhex(QUICKNET_PK);

  const rounds = chooseRounds();
  console.log(`fetching ${rounds.length} quicknet rounds…`);
  const fetched = await mapLimited(rounds, FETCH_CONCURRENCY, async (r) => {
    const { data } = await fetchJson<DrandRound>(`${DRAND_API}/public/${r}`);
    if (data.round !== r) throw new Error(`round ${r}: API returned ${data.round}`);
    return data;
  });

  const out = fetched.map((d) => {
    const signature = unhex(d.signature);
    if (signature.length !== 48) throw new Error(`round ${d.round}: signature is ${signature.length} bytes`);
    if (!sha256(signature).equals(unhex(d.randomness))) throw new Error(`round ${d.round}: randomness != sha256(sig)`);
    const nobleAccepts = sigs.verify(signature, sigs.hash(roundMessage(d.round), DST), pk);
    if (!nobleAccepts) throw new Error(`round ${d.round}: noble rejects the published signature`);
    return { nobleAccepts, randomness: hex(unhex(d.randomness)), round: d.round, signature: hex(signature) };
  });

  writeFixture(
    "quicknet-rounds.json",
    {
      description:
        `${out.length} distinct drand quicknet rounds (${NOTABLE_ROUNDS.length} the repo cites plus ${SPREAD_COUNT} spread ` +
        `evenly over rounds 1..${ROUND_CEILING}), fetched from api.drand.sh. Each carries the published 48-byte ` +
        "compressed G1 signature and `randomness` (== sha256(signature), checked here), and `nobleAccepts`: " +
        `${NOBLE} verified the signature against the quicknet key under DST ${DST} (message sha256(be64(round))). ` +
        "The Solidity verifier must accept every one.",
      sources: [{ url: `${DRAND_API}/info`, sha256: info.sha256 }, { url: `${DRAND_API}/public/<round>` }],
      chainHash: QUICKNET_CHAIN,
      publicKey: `0x${QUICKNET_PK}`,
      genesisTime: GENESIS,
      period: PERIOD,
      dst: DST,
    },
    "rounds",
    out,
  );
  return { pk, sample: fetched.find((d) => d.round === 1000)! };
}

// ------------------------------------------------------------------------------- 5. negatives (noble-built)

/** The path the Solidity verifier (BLS2 through BlsVerifierHarness / NutzDraw._verify) must take. */
type SolidityPath =
  | "revert:Invalid G1 point: not compressed" // g1UnmarshalCompressed, flag bit 7 clear
  | "revert:unsupported: point at infinity" // g1UnmarshalCompressed, flag bit 6 set
  | "callFails" // the pairing precompile errors: field element >= p, point off the curve or outside G1
  | "pairingFalse"; // well-formed G1 point, pairing check returns 0

type Negative = {
  name: string;
  category: string;
  encoding: "compressed" | "uncompressed";
  point: Hex;
  round: number;
  dst: string;
  nobleAccepts: boolean;
  nobleReason: string;
  solidity: SolidityPath;
  /** Whether G1ADD(point, infinity) succeeds: it has no subgroup check, so it separates "off the curve" from
   *  "on the curve but outside G1". "n/a" when unmarshalling already reverts. */
  g1add: "ok" | "fails" | "n/a";
};

/** What noble says about `point` as the signature of `round` under `dst`. */
function nobleDecision(point: Buffer, round: number, dst: string, pk: Buffer): { accepts: boolean; reason: string } {
  try {
    const sig = G1.fromBytes(point);
    const ok = sigs.verify(sig, sigs.hash(roundMessage(round), dst), pk);
    return { accepts: ok, reason: ok ? "verifies" : "pairing check false" };
  } catch (e) {
    return { accepts: false, reason: `decode/verify threw: ${(e as Error).message}` };
  }
}

/** Compressed zcash encoding of an x coordinate with explicit flags (no validation, on purpose). */
function compressedWithFlags(x: bigint, flags: number): Buffer {
  const b = unhex(bigToHex48(x));
  b[0] = (b[0] & 0x1f) | flags;
  return b;
}

/** Uncompressed 96-byte x || y with no flag bits (the EIP's field layout minus the 16-byte padding). */
function uncompressed(x: bigint, y: bigint): Buffer {
  return Buffer.concat([unhex(bigToHex48(x)), unhex(bigToHex48(y))]);
}

/** Deterministic x candidates: sha256 chain from a fixed seed, reduced mod p. */
function* xCandidates(seed: string): Generator<bigint> {
  let h = sha256(utf8(seed));
  for (;;) {
    const x = BigInt(hex(Buffer.concat([h, sha256(h)]).subarray(0, 48))) % P;
    yield x;
    h = sha256(h);
  }
}

const isSquare = (v: bigint): boolean => Fp.pow(v, (P - 1n) / 2n) === 1n;
const rhs = (x: bigint): bigint => Fp.add(Fp.mul(Fp.mul(x, x), x), 4n); // y^2 = x^3 + 4

function genNegatives(pk: Buffer, sample: DrandRound) {
  const round = sample.round;
  const sig = unhex(sample.signature);
  const sigPoint = G1.fromBytes(sig).toAffine();
  const cases: Negative[] = [];
  const push = (
    name: string,
    category: string,
    encoding: Negative["encoding"],
    point: Buffer,
    solidity: SolidityPath,
    g1add: Negative["g1add"],
    opts: { round?: number; dst?: string } = {},
  ) => {
    const r = opts.round ?? round;
    const d = opts.dst ?? DST;
    const decision = nobleDecision(point, r, d, pk);
    if (decision.accepts) throw new Error(`negative ${name} verifies with noble`);
    cases.push({
      name,
      category,
      encoding,
      point: hex(point),
      round: r,
      dst: d,
      nobleAccepts: false,
      nobleReason: decision.reason,
      solidity,
      g1add,
    });
  };

  // (a) compressed x whose x^3 + 4 is a non-residue: no y exists, the library's sqrt is garbage, off the curve.
  // (b) compressed x with a square x^3 + 4 whose points lie outside G1 (a random curve point is in G1 with
  //     probability 1/h ≈ 2^-125): both decompressions are on the curve, neither passes the subgroup check.
  let offCurve = 0;
  let offSubgroup = 0;
  for (const x of xCandidates("nutz bls negatives")) {
    if (offCurve >= 6 && offSubgroup >= 6) break;
    if (!isSquare(rhs(x))) {
      if (offCurve++ < 6) {
        push(`off-curve x #${offCurve}`, "offCurve", "compressed", compressedWithFlags(x, 0x80), "callFails", "fails");
      }
    } else {
      const y = Fp.sqrt(rhs(x));
      const pt = G1.fromAffine({ x, y });
      if (pt.isTorsionFree()) throw new Error("a random curve point landed in G1; seed needs changing");
      if (offSubgroup++ < 6) {
        // both sign choices, the library picks by the 0x20 flag
        const flags = offSubgroup % 2 === 0 ? 0xa0 : 0x80;
        push(
          `on-curve, outside G1 #${offSubgroup}`,
          "offSubgroup",
          "compressed",
          compressedWithFlags(x, flags),
          "callFails",
          "ok",
        );
        push(
          `on-curve, outside G1 #${offSubgroup} (uncompressed)`,
          "offSubgroup",
          "uncompressed",
          uncompressed(x, y),
          "callFails",
          "ok",
        );
      }
    }
  }

  // (c) field element >= p: x = p, x = p + 1, x = p + x_sig when it still fits in 381 bits, x = 2^381 - 1
  push("x == p", "fieldOverflow", "compressed", compressedWithFlags(P, 0x80), "callFails", "fails");
  push("x == p + 1", "fieldOverflow", "compressed", compressedWithFlags(P + 1n, 0x80), "callFails", "fails");
  if (P + sigPoint.x < 1n << 381n) {
    push(
      "x == p + x_sig (same point mod p, non-canonical)",
      "fieldOverflow",
      "compressed",
      compressedWithFlags(P + sigPoint.x, 0x80 | (sig[0] & 0x20)),
      "callFails",
      "fails",
    );
  }
  push("x == 2^381 - 1", "fieldOverflow", "compressed", compressedWithFlags((1n << 381n) - 1n, 0x80), "callFails", "fails");

  // (d) top bits set above the value: only reachable through the uncompressed unmarshal, whose 48-byte limbs are
  //     copied without masking; the compressed path masks everything above bit 380.
  push("x with bit 383 set (uncompressed)", "topBits", "uncompressed", uncompressed(sigPoint.x | (1n << 383n), sigPoint.y), "callFails", "fails");
  push("y with bit 383 set (uncompressed)", "topBits", "uncompressed", uncompressed(sigPoint.x, sigPoint.y | (1n << 383n)), "callFails", "fails");
  push("x with bit 381 set (uncompressed)", "topBits", "uncompressed", uncompressed(sigPoint.x | (1n << 381n), sigPoint.y), "callFails", "fails");

  // (e) infinity: the canonical compressed encoding reverts in the library; the EIP's all-zero encoding is a valid
  //     input to the pairing precompile and the check returns false.
  push("infinity, compressed 0xc0 || 0^47", "infinity", "compressed", compressedWithFlags(0n, 0xc0), "revert:unsupported: point at infinity", "n/a");
  push("infinity, uncompressed 0^96 (EIP-2537 encoding)", "infinity", "uncompressed", uncompressed(0n, 0n), "pairingFalse", "ok");
  push("infinity flag on a real x", "infinity", "compressed", compressedWithFlags(sigPoint.x, 0xc0 | (sig[0] & 0x20)), "revert:unsupported: point at infinity", "n/a");

  // (f) flag bit 7 clear
  push("compressed flag clear", "flags", "compressed", compressedWithFlags(sigPoint.x, sig[0] & 0x20), "revert:Invalid G1 point: not compressed", "n/a");
  push("compressed flag clear, infinity set", "flags", "compressed", compressedWithFlags(sigPoint.x, 0x40), "revert:Invalid G1 point: not compressed", "n/a");

  // (g) the negated signature: a valid G1 point, wrong sign
  push("sign flag flipped (-sig)", "negated", "compressed", compressedWithFlags(sigPoint.x, (sig[0] & 0xe0) ^ 0x20), "pairingFalse", "ok");
  push("-sig (uncompressed)", "negated", "uncompressed", uncompressed(sigPoint.x, Fp.neg(sigPoint.y)), "pairingFalse", "ok");

  // (h) the real signature over another round's message
  for (const other of [round + 1, round - 1, 1, ROUND_CEILING]) {
    push(`round ${round} signature checked as round ${other}`, "wrongRound", "compressed", sig, "pairingFalse", "ok", { round: other });
  }

  // (i) the real signature under another DST
  const otherDsts: [string, string][] = [
    ["POP scheme DST", "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_POP_"],
    ["DST missing the trailing underscore", "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL"],
    ["G2 scheme DST", "BLS_SIG_BLS12381G2_XMD:SHA-256_SSWU_RO_NUL_"],
    ["empty DST", ""],
    ["RFC test DST", "QUUX-V01-CS02-with-BLS12381G1_XMD:SHA-256_SSWU_RO_"],
  ];
  for (const [label, dst] of otherDsts) {
    push(`round ${round} signature under ${label}`, "wrongDst", "compressed", sig, "pairingFalse", "ok", { dst });
  }

  // (j) a valid BLS signature over the right message under another key
  const sk = sha256(utf8("nutz bls negatives: not the quicknet key"));
  const foreign = sigs.sign(sigs.hash(roundMessage(round), DST), sk);
  push("valid signature of the round under another key", "wrongKey", "compressed", Buffer.from(foreign.toBytes(true)), "pairingFalse", "ok");

  // The signature as the uncompressed path sees it: the same point the compressed positives prove, so a topBits
  // case differs from an accepted input by one bit.
  const control = { encoding: "uncompressed" as const, point: hex(uncompressed(sigPoint.x, sigPoint.y)), round, dst: DST, nobleAccepts: true };
  if (!nobleDecision(unhex(control.point), round, DST, pk).accepts) throw new Error("control does not verify");

  writeFixture(
    "quicknet-negatives.json",
    {
      description:
        `Signatures the verifier must reject, built with ${NOBLE} around quicknet round ${round}. \`encoding\` says ` +
        "which unmarshal the harness uses (48-byte compressed: BLS2.g1UnmarshalCompressed, as NutzDraw does; 96-byte " +
        "uncompressed: BLS2.g1Unmarshal). `nobleAccepts`/`nobleReason` are noble's decision on the same bytes, round " +
        "and DST; `solidity` is the rejection path BLS2 must take; `g1add` is whether the EIP-2537 G1ADD precompile " +
        "accepts the decoded point (it does not subgroup-check, so on-curve-outside-G1 points pass it and must fail " +
        "at the pairing). `control` is the round's real signature in uncompressed form, which must verify.",
      sources: [{ url: `${DRAND_API}/public/${round}` }],
      dst: DST,
      control,
    },
    "cases",
    cases,
  );
}

// ---------------------------------------------------------------------------------------------------- main

await genExpandMessageXmd();
await genHashToCurveG1();
await genEip2537();
const { pk, sample } = await genQuicknetRounds();
genNegatives(pk, sample);
