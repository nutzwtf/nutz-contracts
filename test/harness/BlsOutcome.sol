// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {BlsVerifierHarness} from "./BlsVerifierHarness.sol";

/// @dev Names what the vendored verifier did with a signature, in the vocabulary the negatives fixture and the
///      generator share (`SolidityPath` in tooling/src/gen-bls-fixtures.ts), and predicts it for a one-byte tamper of
///      a real signature. No cheatcodes, so a Draw test can mix it in beside its own base.
abstract contract BlsOutcome {
    string internal constant ACCEPTED = "accepted";
    /// @dev Well-formed G1 point, pairing check returned 0.
    string internal constant PAIRING_FALSE = "pairingFalse";
    /// @dev The pairing precompile rejected its input: a field element >= p, a point off the curve or outside G1.
    string internal constant CALL_FAILS = "callFails";
    /// @dev `g1UnmarshalCompressed`, flag bit 7 clear.
    string internal constant REVERT_NOT_COMPRESSED = "revert:Invalid G1 point: not compressed";
    /// @dev `g1UnmarshalCompressed`, flag bit 6 set.
    string internal constant REVERT_INFINITY = "revert:unsupported: point at infinity";
    string internal constant REVERT_OTHER = "revert:other";

    /// @dev Three times one verify (about 135k gas): enough for any accepted input, small enough to bound an input
    ///      the pairing precompile rejects, which burns everything forwarded.
    uint256 internal constant VERIFY_GAS_CAP = 400_000;

    BlsVerifierHarness internal h = new BlsVerifierHarness();

    /// @dev Runs the verifier on `point` (48 bytes compressed, as NutzDraw does, or 96 bytes uncompressed, by
    ///      `encoding`) as the signature of `round` under `dst` and names the outcome.
    function outcome(string memory encoding, bytes memory point, uint256 round, string memory dst)
        internal
        view
        returns (string memory)
    {
        bytes memory call = same(encoding, "compressed")
            ? abi.encodeCall(h.verifyWithDst, (bytes(dst), uint64(round), point))
            : abi.encodeCall(h.verifyUncompressed, (bytes(dst), uint64(round), point));
        (bool success, bytes memory ret) = address(h).staticcall{gas: VERIFY_GAS_CAP}(call);
        if (!success) {
            if (isError(ret, "Invalid G1 point: not compressed")) return REVERT_NOT_COMPRESSED;
            if (isError(ret, "unsupported: point at infinity")) return REVERT_INFINITY;
            return REVERT_OTHER;
        }
        (bool ok, bool callOk) = abi.decode(ret, (bool, bool));
        if (!callOk) return ok ? "callFails but ok" : CALL_FAILS;
        return ok ? ACCEPTED : PAIRING_FALSE;
    }

    /// @dev What flipping `mask` into byte `index` of a real compressed signature must produce. Byte 0 carries the
    ///      three zcash flags: bit 7 (compressed) cleared reverts first, bit 6 (infinity) set reverts next, bit 5 alone
    ///      negates the point, which stays in G1 and fails the pairing check. Any change to the 381 bits of x yields
    ///      an x whose curve points (if x^3 + 4 is a square at all) lie outside G1 with probability 1 - 2^-125, so the
    ///      pairing precompile rejects the input.
    function expectedTamperOutcome(uint8 index, uint8 mask) internal pure returns (string memory) {
        if (index == 0) {
            if (mask & 0x80 != 0) return REVERT_NOT_COMPRESSED;
            if (mask & 0x40 != 0) return REVERT_INFINITY;
            if (mask == 0x20) return PAIRING_FALSE;
        }
        return CALL_FAILS;
    }

    function same(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }

    function isError(bytes memory ret, string memory reason) internal pure returns (bool) {
        return keccak256(ret) == keccak256(abi.encodeWithSignature("Error(string)", reason));
    }
}
