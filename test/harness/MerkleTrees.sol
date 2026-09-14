// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {CompleteMerkle} from "murky/CompleteMerkle.sol";

/// @dev Builds trees in OpenZeppelin StandardMerkleTree format (ADR-0001): leaf = double keccak of
///      abi.encode(id, account, amounts[5]); hashed leaves sorted ascending; murky hashes sorted pairs.
abstract contract MerkleTrees {
    struct Claim {
        address account;
        uint256[5] amounts;
    }

    CompleteMerkle internal merkle;

    function leafOf(uint256 id, address account, uint256[5] memory a) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(id, account, a))));
    }

    function sortedLeaves(uint256 id, Claim[] memory claims) internal pure returns (bytes32[] memory leaves) {
        leaves = new bytes32[](claims.length);
        for (uint256 i = 0; i < claims.length; i++) {
            leaves[i] = leafOf(id, claims[i].account, claims[i].amounts);
        }
        for (uint256 i = 1; i < leaves.length; i++) {
            bytes32 key = leaves[i];
            uint256 j = i;
            while (j > 0 && leaves[j - 1] > key) {
                leaves[j] = leaves[j - 1];
                j--;
            }
            leaves[j] = key;
        }
    }

    function rootOf(uint256 id, Claim[] memory claims) internal view returns (bytes32) {
        bytes32[] memory leaves = sortedLeaves(id, claims);
        if (leaves.length == 1) return leaves[0];
        return merkle.getRoot(leaves);
    }

    function proofOf(uint256 id, Claim[] memory claims, uint256 index) internal view returns (bytes32[] memory) {
        bytes32[] memory leaves = sortedLeaves(id, claims);
        if (leaves.length == 1) return new bytes32[](0);
        bytes32 target = leafOf(id, claims[index].account, claims[index].amounts);
        for (uint256 i = 0; i < leaves.length; i++) {
            if (leaves[i] == target) return merkle.getProof(leaves, i);
        }
        revert("leaf not found");
    }

    /// @dev Sum of every claim's amounts per token: the totals a Root commits to.
    function totalsOf(Claim[] memory claims) internal pure returns (uint256[5] memory t) {
        for (uint256 i = 0; i < claims.length; i++) {
            for (uint256 k = 0; k < 5; k++) {
                t[k] += claims[i].amounts[k];
            }
        }
    }
}
