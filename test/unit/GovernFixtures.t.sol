// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console} from "forge-std/console.sol";
import {ConverterBase} from "../harness/ConverterBase.sol";
import {DistributorBase} from "../harness/DistributorBase.sol";

/// @dev One FIXTURE line per Governance action, collected by nutz-platform's testdata/abi/generate.sh into
///      govern.json, which pins nutz-govern's EIP-712 hashing and calldata. Every printed call was made and
///      accepted here first, so a fixture is a signature the contract takes, not one built beside it.
abstract contract GovernFixturePrinter {
    Vm private constant VM = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private printed;

    function separatorOf(string memory name, address target) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256("1"),
                block.chainid,
                target
            )
        );
    }

    function digestOf(string memory name, address target, bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", separatorOf(name, target), structHash));
    }

    function signAs(uint256 key, string memory name, address target, bytes32 structHash)
        internal
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = VM.sign(key, digestOf(name, target, structHash));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Calls `target` with `data` and requires it to succeed.
    function accepted(address target, bytes memory data) internal {
        (bool ok, bytes memory ret) = target.call(data);
        if (!ok) {
            assembly {
                revert(add(ret, 32), mload(ret))
            }
        }
    }

    function printSigned(
        string memory verb,
        string memory name,
        address target,
        uint256 n,
        string[] memory args,
        bytes32 structHash,
        bytes memory sigA,
        bytes memory sigB,
        bytes memory data
    ) internal {
        string memory f = string.concat("govern", VM.toString(printed++));
        VM.serializeString(f, "verb", verb);
        VM.serializeString(f, "contract", name);
        VM.serializeUint(f, "chainId", block.chainid);
        VM.serializeAddress(f, "verifyingContract", target);
        VM.serializeUint(f, "nonce", n);
        VM.serializeString(f, "args", args);
        VM.serializeBytes32(f, "structHash", structHash);
        VM.serializeBytes32(f, "digest", digestOf(name, target, structHash));
        VM.serializeBytes(f, "signatureA", sigA);
        VM.serializeBytes(f, "signatureB", sigB);
        console.log(string.concat("FIXTURE ", VM.serializeBytes(f, "calldata", data)));
    }

    function printExecute(
        string memory verb,
        string memory name,
        address target,
        string[] memory args,
        bytes32 id,
        bytes memory data
    ) internal {
        string memory f = string.concat("govern", VM.toString(printed++));
        VM.serializeString(f, "verb", verb);
        VM.serializeString(f, "contract", name);
        VM.serializeUint(f, "chainId", block.chainid);
        VM.serializeAddress(f, "verifyingContract", target);
        VM.serializeString(f, "args", args);
        VM.serializeBytes32(f, "id", id);
        console.log(string.concat("FIXTURE ", VM.serializeBytes(f, "calldata", data)));
    }

    function one(string memory a) internal pure returns (string[] memory out) {
        out = new string[](1);
        out[0] = a;
    }

    function two(string memory a, string memory b) internal pure returns (string[] memory out) {
        out = new string[](2);
        out[0] = a;
        out[1] = b;
    }
}

/// @dev Every Governance action of both contracts but voidRoot, in one sequence so the nonce moves as it does
///      on chain; signed by Signers A and B.
contract GovernFixturesTest is ConverterBase, GovernFixturePrinter {
    string internal constant DIST = "NutzDistributor";
    string internal constant CONV = "NutzConverter";

    bytes32 internal constant SET_RATE_RANGE_TYPEHASH =
        keccak256("SetRateRange(uint256 min,uint256 max,uint256 nonce)");
    bytes32 internal constant APPEND_EXCLUDED_TYPEHASH = keccak256("AppendExcluded(address account,uint256 nonce)");
    bytes32 internal constant SET_KEEPER_TYPEHASH = keccak256("SetKeeper(address keeper,uint256 nonce)");
    bytes32 internal constant ROTATE_TYPEHASH = keccak256("RotateSigner(address from,address to,uint256 nonce)");

    address internal constant DRAW = address(0xD1A7d1a7d1a7D1A7D1A7d1a7d1A7D1A7D1A7D1a7);
    address internal constant EXCLUDE = address(0xE1E1E1e1E1E1e1e1E1E1E1e1e1e1E1E1E1E1e1e1);
    address internal constant EXCLUDE_CANCELLED = address(0xe2E2E2e2e2e2E2E2E2E2e2E2e2E2E2e2e2e2E2e2);
    address internal constant NEW_KEEPER = address(0x4bee4Bee4BEE4Bee4Bee4BeE4bEe4bee4Bee4bee);
    uint256 internal constant KEY_D = 0xD00D;

    function sigs(string memory name, address target, bytes32 structHash)
        internal
        view
        returns (bytes memory, bytes memory)
    {
        return (signAs(KEY_A, name, target, structHash), signAs(KEY_B, name, target, structHash));
    }

    function test_printsGovernFixtures() public {
        address dist = address(d);
        address conv = address(c);
        uint256 n;
        bytes32 id;
        bytes32 sh;
        bytes memory sigA;
        bytes memory sigB;
        bytes memory data;

        // The Distributor.
        n = d.nonce();
        sh = keccak256(abi.encode(SET_RATE_RANGE_TYPEHASH, uint256(2_000e6), uint256(9_000e6), n));
        (sigA, sigB) = sigs(DIST, dist, sh);
        data = abi.encodeCall(d.setRateRange, (uint256(2_000e6), uint256(9_000e6), sigA, sigB));
        accepted(dist, data);
        printSigned(
            "set-rate-range",
            DIST,
            dist,
            n,
            two(vm.toString(uint256(2_000e6)), vm.toString(uint256(9_000e6))),
            sh,
            sigA,
            sigB,
            data
        );
        assertEq(d.minUsdgPerEth(), 2_000e6, "set-rate-range took");

        n = d.nonce();
        sh = keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, DRAW, n));
        (sigA, sigB) = sigs(DIST, dist, sh);
        data = abi.encodeCall(d.proposeDrawContract, (DRAW, sigA, sigB));
        accepted(dist, data);
        printSigned("propose-draw", DIST, dist, n, one(vm.toString(DRAW)), sh, sigA, sigB, data);
        id = keccak256(abi.encode(SET_DRAW_CONTRACT_TYPEHASH, DRAW));
        assertEq(d.readyAt(id), block.timestamp + 48 hours, "propose-draw scheduled");
        vm.warp(block.timestamp + 48 hours);
        bytes memory exec = abi.encodeCall(d.executeDrawContract, (DRAW));
        accepted(dist, exec);
        printExecute("execute-draw", DIST, dist, one(vm.toString(DRAW)), id, exec);
        assertEq(address(d.drawContract()), DRAW, "execute-draw took");

        n = d.nonce();
        sh = keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, EXCLUDE, n));
        (sigA, sigB) = sigs(DIST, dist, sh);
        data = abi.encodeCall(d.proposeExclusion, (EXCLUDE, sigA, sigB));
        accepted(dist, data);
        printSigned("propose-exclusion", DIST, dist, n, one(vm.toString(EXCLUDE)), sh, sigA, sigB, data);
        id = keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, EXCLUDE));
        vm.warp(block.timestamp + 48 hours);
        exec = abi.encodeCall(d.executeExclusion, (EXCLUDE));
        accepted(dist, exec);
        printExecute("execute-exclusion", DIST, dist, one(vm.toString(EXCLUDE)), id, exec);

        n = d.nonce();
        sh = keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, EXCLUDE_CANCELLED, n));
        (sigA, sigB) = sigs(DIST, dist, sh);
        data = abi.encodeCall(d.proposeExclusion, (EXCLUDE_CANCELLED, sigA, sigB));
        accepted(dist, data);
        printSigned("propose-exclusion", DIST, dist, n, one(vm.toString(EXCLUDE_CANCELLED)), sh, sigA, sigB, data);
        id = keccak256(abi.encode(APPEND_EXCLUDED_TYPEHASH, EXCLUDE_CANCELLED));
        n = d.nonce();
        sh = keccak256(abi.encode(CANCEL_TYPEHASH, id, n));
        (sigA, sigB) = sigs(DIST, dist, sh);
        data = abi.encodeCall(d.cancel, (id, sigA, sigB));
        accepted(dist, data);
        printSigned("cancel", DIST, dist, n, one(vm.toString(id)), sh, sigA, sigB, data);
        assertEq(d.readyAt(id), 0, "cancel took");

        n = d.nonce();
        sh = keccak256(abi.encode(SET_KEEPER_TYPEHASH, NEW_KEEPER, n));
        (sigA, sigB) = sigs(DIST, dist, sh);
        data = abi.encodeCall(d.setKeeper, (NEW_KEEPER, sigA, sigB));
        accepted(dist, data);
        printSigned("set-keeper", DIST, dist, n, one(vm.toString(NEW_KEEPER)), sh, sigA, sigB, data);
        assertEq(d.keeper(), NEW_KEEPER, "set-keeper took");

        address from = vm.addr(KEY_C);
        address to = vm.addr(KEY_D);
        n = d.nonce();
        sh = keccak256(abi.encode(ROTATE_TYPEHASH, from, to, n));
        (sigA, sigB) = sigs(DIST, dist, sh);
        data = abi.encodeCall(d.proposeSignerRotation, (from, to, sigA, sigB));
        accepted(dist, data);
        printSigned("propose-rotation", DIST, dist, n, two(vm.toString(from), vm.toString(to)), sh, sigA, sigB, data);
        id = keccak256(abi.encode(ROTATE_TYPEHASH, from, to));
        vm.warp(block.timestamp + 48 hours);
        exec = abi.encodeCall(d.executeSignerRotation, (from, to));
        accepted(dist, exec);
        printExecute("execute-rotation", DIST, dist, two(vm.toString(from), vm.toString(to)), id, exec);
        assertEq(d.signers(2), to, "execute-rotation took");

        // The Converter.
        n = c.nonce();
        sh = keccak256(abi.encode(SET_OPS_CAP_TYPEHASH, uint256(0.3 ether), n));
        (sigA, sigB) = sigs(CONV, conv, sh);
        data = abi.encodeCall(c.setOpsCap, (uint256(0.3 ether), sigA, sigB));
        accepted(conv, data);
        printSigned("set-ops-cap", CONV, conv, n, one(vm.toString(uint256(0.3 ether))), sh, sigA, sigB, data);
        assertEq(c.opsCap(), 0.3 ether, "set-ops-cap took");

        n = c.nonce();
        sh = keccak256(abi.encode(DISABLE_LEG_TYPEHASH, uint8(2), n));
        (sigA, sigB) = sigs(CONV, conv, sh);
        data = abi.encodeCall(c.disableLeg, (uint8(2), sigA, sigB));
        accepted(conv, data);
        printSigned("disable-leg", CONV, conv, n, one("2"), sh, sigA, sigB, data);
        assertTrue(c.legDisabled(2), "disable-leg took");

        n = c.nonce();
        sh = keccak256(abi.encode(ENABLE_LEG_TYPEHASH, uint8(2), n));
        (sigA, sigB) = sigs(CONV, conv, sh);
        data = abi.encodeCall(c.proposeLegEnable, (uint8(2), sigA, sigB));
        accepted(conv, data);
        printSigned("propose-leg-enable", CONV, conv, n, one("2"), sh, sigA, sigB, data);
        id = keccak256(abi.encode(ENABLE_LEG_TYPEHASH, uint8(2)));
        vm.warp(block.timestamp + 48 hours);
        exec = abi.encodeCall(c.executeLegEnable, (uint8(2)));
        accepted(conv, exec);
        printExecute("execute-leg-enable", CONV, conv, one("2"), id, exec);
        assertFalse(c.legDisabled(2), "execute-leg-enable took");

        n = c.nonce();
        sh = keccak256(abi.encode(SET_KEEPER_TYPEHASH, NEW_KEEPER, n));
        (sigA, sigB) = sigs(CONV, conv, sh);
        data = abi.encodeCall(c.setKeeper, (NEW_KEEPER, sigA, sigB));
        accepted(conv, data);
        printSigned("set-keeper", CONV, conv, n, one(vm.toString(NEW_KEEPER)), sh, sigA, sigB, data);
        assertEq(c.keeper(), NEW_KEEPER, "converter set-keeper took");
    }
}

/// @dev voidRoot needs a posted Root inside its window, which the Distributor's own harness funds and posts.
contract GovernVoidFixtureTest is DistributorBase, GovernFixturePrinter {
    bytes32 internal constant ROOT = 0xabababababababababababababababababababababababababababababababab;

    function test_printsVoidRootFixture() public {
        uint256 e = DEPLOY_EPOCH;
        fund(e, amounts(1, 2, 3, 4, 5), 0);
        postRoot(EPOCH, e, ROOT, amounts(1, 2, 3, 4, 5));

        uint256 n = d.nonce();
        bytes32 sh = voidRootHash(EPOCH, e, n);
        bytes memory sigA = signAs(KEY_A, "NutzDistributor", address(d), sh);
        bytes memory sigB = signAs(KEY_B, "NutzDistributor", address(d), sh);
        bytes memory data = abi.encodeCall(d.voidRoot, (EPOCH, e, sigA, sigB));
        accepted(address(d), data);
        printSigned("void-root", "NutzDistributor", address(d), n, two("0", vm.toString(e)), sh, sigA, sigB, data);
        assertEq(d.rootedThrough(EPOCH), e - 1, "void-root took");
    }
}
