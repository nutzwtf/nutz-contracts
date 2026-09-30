// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/console.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";

/// @dev Prints the PostRoot case nutz-platform's testdata/abi/generate.sh pins its EIP-712 code to, and proves the
///      printed signatures are ones postRoot accepts. The digest is asserted so the fixture cannot drift silently.
contract KeeperFixturesTest is DistributorBase {
    bytes32 internal constant ROOT = 0xabababababababababababababababababababababababababababababababab;
    bytes32 internal constant DIGEST = 0x45cbda38e91301459276abca2b90127ce7ba998a3cb2097a8d4f860a871e376e;

    function test_printsPostRootFixture() public {
        uint256 e = DEPLOY_EPOCH;
        uint256[5] memory totals = amounts(1, 2, 3, 4, 5);
        fund(e, totals, 0);

        bytes32 structHash = postRootHash(EPOCH, e, ROOT, totals, d.nonce());
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
        bytes memory sigA = sign(KEY_A, structHash);
        bytes memory sigB = sign(KEY_B, structHash);

        uint256[] memory totalsList = new uint256[](5);
        for (uint256 i = 0; i < 5; i++) {
            totalsList[i] = totals[i];
        }
        string memory f = "fixture";
        vm.serializeUint(f, "chainId", block.chainid);
        vm.serializeAddress(f, "verifyingContract", address(d));
        vm.serializeUint(f, "kind", 0);
        vm.serializeUint(f, "id", e);
        vm.serializeBytes32(f, "root", ROOT);
        vm.serializeUint(f, "totals", totalsList);
        vm.serializeUint(f, "nonce", d.nonce());
        vm.serializeBytes32(f, "domainSeparator", domainSeparator());
        vm.serializeBytes32(f, "digest", digest);
        vm.serializeBytes32(f, "privateKeyA", bytes32(KEY_A));
        vm.serializeAddress(f, "signerA", vm.addr(KEY_A));
        vm.serializeBytes(f, "signatureA", sigA);
        vm.serializeBytes32(f, "privateKeyB", bytes32(KEY_B));
        vm.serializeAddress(f, "signerB", vm.addr(KEY_B));
        string memory json = vm.serializeBytes(f, "signatureB", sigB);
        console.log(string.concat("FIXTURE ", json));

        d.postRoot(EPOCH, e, ROOT, totals, sigA, sigB);
        assertEq(d.rootedThrough(EPOCH), e, "the printed signatures post the Root");
        assertEq(digest, DIGEST, "the fixture digest moved: regenerate nutz-platform's testdata/abi");
    }
}
