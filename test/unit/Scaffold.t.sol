// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import {CompleteMerkle} from "murky/CompleteMerkle.sol";

/// @dev Proves the pinned dependencies resolve and that murky's CompleteMerkle produces
///      proofs OpenZeppelin's MerkleProof accepts (the premise of ADR-0001).
contract ScaffoldTest is Test {
    function test_murkyProofVerifiesWithOpenZeppelin() public {
        CompleteMerkle m = new CompleteMerkle();
        bytes32[] memory leaves = new bytes32[](4);
        for (uint256 i = 0; i < leaves.length; i++) {
            leaves[i] = keccak256(bytes.concat(keccak256(abi.encode(i))));
        }
        bytes32 root = m.getRoot(leaves);
        bytes32[] memory proof = m.getProof(leaves, 2);
        assertTrue(MerkleProof.verify(proof, root, leaves[2]));
        assertFalse(MerkleProof.verify(proof, root, leaves[1]));
    }
}
