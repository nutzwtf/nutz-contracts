// Prints the StandardMerkleTree leaf hash for one claim. Handy when a proof fails.
// Usage: pnpm verify-leaf <id> <account> <a0> <a1> <a2> <a3> <a4>
import { StandardMerkleTree } from "@openzeppelin/merkle-tree";

const [id, account, ...amounts] = process.argv.slice(2);
if (!id || !account || amounts.length !== 5) {
  console.error("usage: verify-leaf <id> <account> <a0> <a1> <a2> <a3> <a4>");
  process.exit(1);
}
const tree = StandardMerkleTree.of([[BigInt(id), account, amounts.map(BigInt)]], ["uint256", "address", "uint256[5]"]);
console.log(tree.leafHash([BigInt(id), account, amounts.map(BigInt)]));
