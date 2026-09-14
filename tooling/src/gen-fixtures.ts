// Generates test/fixtures/claims.json: a StandardMerkleTree of (id, account, amounts[5]) leaves built by the
// same library the indexer will use, so the Solidity tests can prove byte-for-byte parity (ADR-0001).
// Run: pnpm gen:fixtures   (deterministic; commit the output)
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";
import { writeFileSync, mkdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ENCODING = ["uint256", "address", "uint256[5]"];
const ID = 500000n; // epoch id used by the fixture

// Deterministic sample: six holders with distinct amount patterns, including zeros and dust.
const claims: { account: `0x${string}`; amounts: bigint[] }[] = [
  { account: "0x1111111111111111111111111111111111111111", amounts: [1n * 10n ** 18n, 0n, 0n, 0n, 100n * 10n ** 18n] },
  { account: "0x2222222222222222222222222222222222222222", amounts: [0n, 2n * 10n ** 18n, 0n, 0n, 50n * 10n ** 18n] },
  { account: "0x3333333333333333333333333333333333333333", amounts: [1n, 2n, 3n, 4n, 5n] },
  { account: "0x4444444444444444444444444444444444444444", amounts: [0n, 0n, 0n, 0n, 7n * 10n ** 17n] },
  { account: "0x5555555555555555555555555555555555555555", amounts: [10n ** 18n, 10n ** 18n, 10n ** 18n, 10n ** 18n, 10n ** 18n] },
  { account: "0x6666666666666666666666666666666666666666", amounts: [0n, 0n, 5n * 10n ** 18n, 0n, 0n] },
];

const tree = StandardMerkleTree.of(
  claims.map((c) => [ID, c.account, c.amounts]),
  ENCODING,
);

const out = {
  encoding: ENCODING,
  id: ID.toString(),
  root: tree.root,
  claims: claims.map((c, i) => ({
    account: c.account,
    amounts: c.amounts.map((a) => a.toString()),
    proof: tree.getProof(i),
    leaf: tree.leafHash([ID, c.account, c.amounts]),
  })),
};

const here = dirname(fileURLToPath(import.meta.url));
const target = join(here, "..", "..", "test", "fixtures", "claims.json");
mkdirSync(dirname(target), { recursive: true });
writeFileSync(target, JSON.stringify(out, null, 2) + "\n");
console.log(`wrote ${target}\nroot ${tree.root}`);
