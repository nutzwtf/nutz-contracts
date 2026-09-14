// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Signers} from "../../src/Signers.sol";
import {SignersHarness} from "../harness/SignersHarness.sol";

contract SignersTest is Test {
    uint256 internal constant KEY_A = 0xA11CE;
    uint256 internal constant KEY_B = 0xB0B;
    uint256 internal constant KEY_C = 0xCA11;
    uint256 internal constant KEY_X = 0x5717A; // not a signer

    address internal signerA = vm.addr(KEY_A);
    address internal signerB = vm.addr(KEY_B);
    address internal signerC = vm.addr(KEY_C);
    address internal keeper = makeAddr("keeper");

    SignersHarness internal h;

    function setUp() public {
        h = new SignersHarness([signerA, signerB, signerC], keeper);
    }

    // ---- EIP-712 helpers built independently of the contract ----

    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 internal constant PING_TYPEHASH = keccak256("Ping(uint256 value,uint256 nonce)");
    bytes32 internal constant SET_KEEPER_TYPEHASH = keccak256("SetKeeper(address keeper,uint256 nonce)");
    bytes32 internal constant ROTATE_TYPEHASH = keccak256("RotateSigner(address from,address to,uint256 nonce)");
    bytes32 internal constant CANCEL_TYPEHASH = keccak256("Cancel(bytes32 id,uint256 nonce)");

    uint256 internal constant TIMELOCK = 48 hours;
    uint256 internal constant PROPOSAL_TTL = 7 days;

    function rotateHash(address from, address to, uint256 nonce_) internal pure returns (bytes32) {
        return keccak256(abi.encode(ROTATE_TYPEHASH, from, to, nonce_));
    }

    function rotateId(address from, address to) internal pure returns (bytes32) {
        return keccak256(abi.encode(ROTATE_TYPEHASH, from, to));
    }

    function proposeRotation(address from, address to, uint256 k1, uint256 k2) internal {
        bytes32 sh = rotateHash(from, to, h.nonce());
        h.proposeSignerRotation(from, to, sign(k1, sh), sign(k2, sh));
    }

    function domainSeparator() internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(DOMAIN_TYPEHASH, keccak256("SignersHarness"), keccak256("1"), block.chainid, address(h))
            );
    }

    function digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", domainSeparator(), structHash));
    }

    function sign(uint256 key, bytes32 structHash) internal view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest(structHash));
        return abi.encodePacked(r, s, v);
    }

    function pingHash(uint256 value, uint256 nonce_) internal pure returns (bytes32) {
        return keccak256(abi.encode(PING_TYPEHASH, value, nonce_));
    }

    // ---- constructor ----

    function test_constructor_storesSignersKeeperAndZeroNonce() public view {
        assertEq(h.signers(0), signerA);
        assertEq(h.signers(1), signerB);
        assertEq(h.signers(2), signerC);
        assertEq(h.keeper(), keeper);
        assertEq(h.nonce(), 0);
    }

    function test_constructor_rejectsZeroSigner() public {
        vm.expectRevert(Signers.ZeroAddress.selector);
        new SignersHarness([signerA, address(0), signerC], keeper);
    }

    function test_constructor_rejectsDuplicateSigner() public {
        vm.expectRevert(Signers.DuplicateSigner.selector);
        new SignersHarness([signerA, signerB, signerA], keeper);
    }

    function test_constructor_rejectsZeroKeeper() public {
        vm.expectRevert(Signers.ZeroAddress.selector);
        new SignersHarness([signerA, signerB, signerC], address(0));
    }

    // ---- 2-of-3 verification ----

    function test_twoDistinctSigners_passAndConsumeNonce() public {
        bytes32 sh = pingHash(42, 0);
        h.ping(42, sign(KEY_A, sh), sign(KEY_C, sh));
        assertEq(h.lastPing(), 42);
        assertEq(h.nonce(), 1);
    }

    function test_anyPairOfSigners_isAccepted_inEitherOrder() public {
        h.ping(1, sign(KEY_B, pingHash(1, 0)), sign(KEY_A, pingHash(1, 0)));
        h.ping(2, sign(KEY_C, pingHash(2, 1)), sign(KEY_B, pingHash(2, 1)));
        assertEq(h.nonce(), 2);
    }

    function test_sameSignerTwice_reverts() public {
        bytes32 sh = pingHash(1, 0);
        vm.expectRevert(Signers.SameSigner.selector);
        h.ping(1, sign(KEY_A, sh), sign(KEY_A, sh));
    }

    function test_nonSigner_reverts() public {
        bytes32 sh = pingHash(1, 0);
        vm.expectRevert(abi.encodeWithSelector(Signers.NotSigner.selector, vm.addr(KEY_X)));
        h.ping(1, sign(KEY_A, sh), sign(KEY_X, sh));
    }

    function test_staleNonce_reverts() public {
        h.ping(1, sign(KEY_A, pingHash(1, 0)), sign(KEY_B, pingHash(1, 0)));
        bytes32 stale = pingHash(2, 0); // signed against nonce 0, but nonce is now 1
        vm.expectRevert();
        h.ping(2, sign(KEY_A, stale), sign(KEY_B, stale));
    }

    function test_replayOfConsumedSignatures_reverts() public {
        bytes32 sh = pingHash(7, 0);
        bytes memory s1 = sign(KEY_A, sh);
        bytes memory s2 = sign(KEY_B, sh);
        h.ping(7, s1, s2);
        vm.expectRevert();
        h.ping(7, s1, s2);
    }

    function test_signatureForOtherContract_reverts() public {
        SignersHarness other = new SignersHarness([signerA, signerB, signerC], keeper);
        bytes32 sh = pingHash(1, 0);
        bytes memory s1 = sign(KEY_A, sh); // domain bound to `h`
        bytes memory s2 = sign(KEY_B, sh);
        vm.expectRevert();
        other.ping(1, s1, s2);
    }

    function testFuzz_anyTwoDistinctSigners_pass(uint8 i, uint8 j, uint256 value) public {
        i = uint8(bound(i, 0, 2));
        j = uint8(bound(j, 0, 2));
        vm.assume(i != j);
        uint256[3] memory keys = [KEY_A, KEY_B, KEY_C];
        bytes32 sh = pingHash(value, 0);
        h.ping(value, sign(keys[i], sh), sign(keys[j], sh));
        assertEq(h.lastPing(), value);
    }

    // ---- keeper ----

    function test_onlyKeeper_allowsKeeper() public {
        vm.prank(keeper);
        h.keeperOnly();
        assertEq(h.keeperCalls(), 1);
    }

    function test_onlyKeeper_rejectsOthers() public {
        vm.prank(signerA);
        vm.expectRevert(Signers.NotKeeper.selector);
        h.keeperOnly();
    }

    function test_setKeeper_withTwoSigners_changesKeeperImmediately() public {
        address newKeeper = makeAddr("newKeeper");
        bytes32 sh = keccak256(abi.encode(SET_KEEPER_TYPEHASH, newKeeper, uint256(0)));
        vm.expectEmit(address(h));
        emit Signers.KeeperSet(keeper, newKeeper);
        h.setKeeper(newKeeper, sign(KEY_B, sh), sign(KEY_C, sh));
        assertEq(h.keeper(), newKeeper);
        vm.prank(newKeeper);
        h.keeperOnly();
        vm.prank(keeper);
        vm.expectRevert(Signers.NotKeeper.selector);
        h.keeperOnly();
    }

    function test_setKeeper_rejectsZero() public {
        bytes32 sh = keccak256(abi.encode(SET_KEEPER_TYPEHASH, address(0), uint256(0)));
        vm.expectRevert(Signers.ZeroAddress.selector);
        h.setKeeper(address(0), sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_setKeeper_withoutSignatures_reverts() public {
        vm.expectRevert();
        h.setKeeper(makeAddr("x"), "", "");
    }

    // ---- signer rotation (48h timelock) ----

    address internal signerX = vm.addr(KEY_X);

    function test_proposeRotation_schedulesAfter48h() public {
        vm.warp(1_000_000);
        bytes32 id = rotateId(signerC, signerX);
        vm.expectEmit(address(h));
        emit Signers.Scheduled(id, block.timestamp + TIMELOCK);
        proposeRotation(signerC, signerX, KEY_A, KEY_B);
        assertEq(h.readyAt(id), block.timestamp + TIMELOCK);
        assertEq(h.signers(2), signerC, "not rotated yet");
    }

    function test_executeRotation_beforeReady_reverts() public {
        vm.warp(1_000_000);
        proposeRotation(signerC, signerX, KEY_A, KEY_B);
        vm.warp(block.timestamp + TIMELOCK - 1);
        vm.expectRevert(Signers.NotReady.selector);
        h.executeSignerRotation(signerC, signerX);
    }

    function test_executeRotation_atReady_byAnyone_swapsSigner() public {
        vm.warp(1_000_000);
        proposeRotation(signerC, signerX, KEY_A, KEY_B);
        vm.warp(block.timestamp + TIMELOCK);
        vm.prank(makeAddr("anyone"));
        vm.expectEmit(address(h));
        emit Signers.SignerRotated(signerC, signerX);
        h.executeSignerRotation(signerC, signerX);
        assertEq(h.signers(2), signerX);
        assertEq(h.readyAt(rotateId(signerC, signerX)), 0, "proposal consumed");

        // the new signer works, the old one does not
        bytes32 sh = pingHash(9, h.nonce());
        h.ping(9, sign(KEY_A, sh), sign(KEY_X, sh));
        sh = pingHash(10, h.nonce());
        vm.expectRevert(abi.encodeWithSelector(Signers.NotSigner.selector, signerC));
        h.ping(10, sign(KEY_A, sh), sign(KEY_C, sh));
    }

    function test_executeRotation_afterExpiry_reverts() public {
        vm.warp(1_000_000);
        proposeRotation(signerC, signerX, KEY_A, KEY_B);
        vm.warp(block.timestamp + TIMELOCK + PROPOSAL_TTL + 1);
        vm.expectRevert(Signers.Expired.selector);
        h.executeSignerRotation(signerC, signerX);
    }

    function test_executeRotation_neverProposed_reverts() public {
        vm.expectRevert(Signers.NotScheduled.selector);
        h.executeSignerRotation(signerC, signerX);
    }

    function test_signerMaySignItsOwnReplacement() public {
        vm.warp(1_000_000);
        proposeRotation(signerC, signerX, KEY_C, KEY_A);
        vm.warp(block.timestamp + TIMELOCK);
        h.executeSignerRotation(signerC, signerX);
        assertEq(h.signers(2), signerX);
    }

    function test_proposeRotation_rejectsNonSignerFrom_existingSignerTo_andZeroTo() public {
        bytes32 sh = rotateHash(signerX, signerA, 0);
        vm.expectRevert(abi.encodeWithSelector(Signers.NotSigner.selector, signerX));
        h.proposeSignerRotation(signerX, signerA, sign(KEY_A, sh), sign(KEY_B, sh));

        sh = rotateHash(signerA, signerB, 0);
        vm.expectRevert(Signers.DuplicateSigner.selector);
        h.proposeSignerRotation(signerA, signerB, sign(KEY_A, sh), sign(KEY_B, sh));

        sh = rotateHash(signerA, address(0), 0);
        vm.expectRevert(Signers.ZeroAddress.selector);
        h.proposeSignerRotation(signerA, address(0), sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_proposeRotation_whilePending_reverts() public {
        vm.warp(1_000_000);
        proposeRotation(signerC, signerX, KEY_A, KEY_B);
        bytes32 sh = rotateHash(signerC, signerX, h.nonce());
        vm.expectRevert(Signers.AlreadyScheduled.selector);
        h.proposeSignerRotation(signerC, signerX, sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_executeRotation_rechecksConditions() public {
        // Two proposals replace the same signer; once the first executes, the second must fail.
        vm.warp(1_000_000);
        address signerY = makeAddr("Y");
        proposeRotation(signerC, signerX, KEY_A, KEY_B);
        proposeRotation(signerC, signerY, KEY_A, KEY_B);
        vm.warp(block.timestamp + TIMELOCK);
        h.executeSignerRotation(signerC, signerX);
        vm.expectRevert(abi.encodeWithSelector(Signers.NotSigner.selector, signerC));
        h.executeSignerRotation(signerC, signerY);
    }

    function test_cancel_removesProposal() public {
        vm.warp(1_000_000);
        proposeRotation(signerC, signerX, KEY_A, KEY_B);
        bytes32 id = rotateId(signerC, signerX);
        bytes32 sh = keccak256(abi.encode(CANCEL_TYPEHASH, id, h.nonce()));
        vm.expectEmit(address(h));
        emit Signers.Cancelled(id);
        h.cancel(id, sign(KEY_B, sh), sign(KEY_C, sh));
        assertEq(h.readyAt(id), 0);
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectRevert(Signers.NotScheduled.selector);
        h.executeSignerRotation(signerC, signerX);
    }

    function test_cancel_unknownProposal_reverts() public {
        bytes32 id = rotateId(signerC, signerX);
        bytes32 sh = keccak256(abi.encode(CANCEL_TYPEHASH, id, uint256(0)));
        vm.expectRevert(Signers.NotScheduled.selector);
        h.cancel(id, sign(KEY_A, sh), sign(KEY_B, sh));
    }
}
