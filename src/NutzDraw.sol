// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {INutzDraw} from "./interfaces/INutzDraw.sol";
import {INutzDistributor} from "./interfaces/INutzDistributor.sol";
import {BLS2} from "./vendor/bls/BLS2.sol";

/// @title NutzDraw
/// @notice Commits an Acorn Draw and accepts its Beacon fulfilment. Once a week the Keeper commits the Ticket list
///         (its Merkle root and Ticket count) together with a drand quicknet round that does not exist yet; once
///         that round is published, anyone submits its signature, the contract verifies it against the quicknet
///         public key through the EIP-2537 precompiles and stores the Seed. The Distributor reads `seedOf` before
///         releasing the Acorn pool and before accepting a Draw Root. Holds no funds, moves no token, has no
///         governance and is never upgraded: the Distributor replaces it behind its 2-of-3, 48-hour timelock
///         (ADR-0004).
contract NutzDraw is INutzDraw {
    // ------------------------------------------------------------------ types

    /// @notice One Acorn Draw: the committed Ticket list, the quicknet round it waits for, and the Seed once that
    ///         round's signature has been verified.
    struct Draw {
        bytes32 ticketsRoot;
        uint256 ticketCount;
        uint64 round;
        bytes32 seed;
    }

    // -------------------------------------------------------------- constants

    /// @notice drand quicknet `genesis_time`: round 1 covers the three seconds from here.
    uint256 public constant GENESIS = 1_692_803_367;
    /// @notice drand quicknet `period`, seconds per round.
    uint256 public constant PERIOD = 3;
    /// @notice How far ahead of the request the committed round lies, so the Keeper never knows a Seed when it
    ///         commits a list.
    uint256 public constant LEAD = 10 minutes;
    /// @notice RFC 9380 domain separation tag of drand's `bls-unchained-g1-rfc9380` scheme.
    bytes public constant DST = "BLS_SIG_BLS12381G1_XMD:SHA-256_SSWU_RO_NUL_";
    /// @notice The recorded quicknet round the constructor verifies before accepting the deployment.
    uint64 public constant VECTOR_ROUND = 1000;
    /// @notice quicknet's signature for `VECTOR_ROUND`, compressed; `sha256` of it is that round's `randomness`.
    bytes public constant VECTOR_SIG =
        hex"b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";
    /// @dev A quicknet signature is one compressed G1 point: 48 bytes whose top three bits are the zcash flags,
    ///      compressed set and infinity clear (the third is the sign of y).
    uint256 private constant SIGNATURE_BYTES = 48;
    uint8 private constant FLAG_COMPRESSED = 0x80;
    uint8 private constant FLAG_INFINITY = 0x40;

    // ------------------------------------------------------------- immutables

    INutzDistributor public immutable DISTRIBUTOR;

    // ---------------------------------------------------------------- storage

    /// @notice Every requested draw by id: the committed root and count, the round, and the Seed once fulfilled.
    mapping(uint256 drawId => Draw) public draws;
    /// @notice The highest round any draw has committed to; every request commits strictly above it.
    uint64 public lastRound;

    // ---------------------------------------------------------------- errors

    error ZeroAddress();
    /// @dev The recorded vector did not verify at construction: the precompiles are missing on this chain, the key
    ///      limbs were transcribed wrongly, or the vendored verifier misbehaves under this compiler.
    error VerifierSelfTestFailed();
    error NotKeeper();
    /// @dev A Draw Root needs `drawId < currentDraw()`, so a draw is only requested for a week that has ended.
    error DrawNotOpen(uint256 drawId);
    /// @dev The Seed is final: no re-request and no second fulfilment.
    error AlreadyFulfilled(uint256 drawId);
    /// @dev A week without Ticket holders is not requested; the Distributor Skips it.
    error NoTickets();
    error DrawNotRequested(uint256 drawId);
    /// @dev The committed round has not been published yet.
    error RoundNotDue(uint64 round, uint64 current);
    /// @dev Not a 48-byte compressed point, or not the quicknet signature of the committed round.
    error InvalidSignature();

    // ---------------------------------------------------------------- events

    /// @notice The Keeper committed a Ticket list for `drawId` to quicknet `round`; a re-request emits it again.
    event DrawRequested(uint256 indexed drawId, bytes32 ticketsRoot, uint256 ticketCount, uint64 round);
    /// @notice `round`'s signature verified; `seed` is drand's published `randomness` for it.
    event DrawFulfilled(uint256 indexed drawId, uint64 round, bytes32 seed, address indexed fulfiller);

    // ------------------------------------------------------------ constructor

    /// @dev Runs the verifier on the recorded vector so a Draw that could never be fulfilled is never deployed
    ///      (replacing one costs 48 hours).
    constructor(address distributor) {
        if (distributor == address(0)) revert ZeroAddress();
        DISTRIBUTOR = INutzDistributor(distributor);
        (uint64 round, bytes memory signature) = _selfTestVector();
        if (!_verify(round, signature)) revert VerifierSelfTestFailed();
    }

    // ---------------------------------------------------------------- request

    /// @notice Commits the Ticket list of `drawId` (the Unix week that ended last Thursday: `currentDraw() - 1`) to
    ///         the quicknet round ten minutes ahead, or the next unused round if later. Keeper-only, read from the
    ///         Distributor at call time. An unfulfilled draw may be requested again: root, count and round are
    ///         replaced, and the new round again lies in the future.
    function requestDraw(uint256 drawId, bytes32 ticketsRoot, uint256 ticketCount) external {
        // Two views on an immutable address (STATICCALL): nothing can re-enter before the writes below.
        // aderyn-fp-next-line(reentrancy-state-change)
        if (msg.sender != DISTRIBUTOR.keeper()) revert NotKeeper();
        // aderyn-fp-next-line(reentrancy-state-change)
        if (drawId >= DISTRIBUTOR.currentDraw()) revert DrawNotOpen(drawId);
        Draw storage d = draws[drawId];
        if (d.seed != 0) revert AlreadyFulfilled(drawId);
        if (ticketsRoot == 0 || ticketCount == 0) revert NoTickets();
        // Strictly increasing across every request, so two draws never share a Seed; the `max` only matters for
        // two requests inside one 3-second round.
        uint64 round = roundAt(block.timestamp + LEAD);
        uint64 next = lastRound + 1;
        if (next > round) round = next;
        lastRound = round;
        d.ticketsRoot = ticketsRoot;
        d.ticketCount = ticketCount;
        d.round = round;
        emit DrawRequested(drawId, ticketsRoot, ticketCount, round);
    }

    // ----------------------------------------------------------------- fulfil

    /// @notice Verifies the 48-byte compressed quicknet signature of the round `drawId` committed to and stores
    ///         `sha256(signature)`, drand's published `randomness`, as the Seed. Permissionless: the Keeper fulfils
    ///         in the normal case, anyone else can, so the draw cannot be stalled.
    /// @dev A signature whose point the pairing precompile rejects burns all the gas forwarded to it; the sender
    ///      pays, so callers should set a sane gas limit rather than an estimate-less maximum.
    function fulfill(uint256 drawId, bytes calldata signature) external {
        Draw storage d = draws[drawId];
        uint64 round = d.round;
        if (round == 0) revert DrawNotRequested(drawId);
        if (d.seed != 0) revert AlreadyFulfilled(drawId);
        uint64 current = currentRound();
        if (current < round) revert RoundNotDue(round, current);
        if (signature.length != SIGNATURE_BYTES || !_wellFormed(signature) || !_verify(round, signature)) {
            revert InvalidSignature();
        }
        bytes32 seed = sha256(signature);
        d.seed = seed;
        emit DrawFulfilled(drawId, round, seed, msg.sender);
    }

    // ------------------------------------------------------------------ views

    /// @inheritdoc INutzDraw
    function seedOf(uint256 drawId) external view returns (bytes32) {
        return draws[drawId].seed;
    }

    /// @notice The quicknet round `block.timestamp` falls in.
    function currentRound() public view returns (uint64) {
        return roundAt(block.timestamp);
    }

    /// @notice The quicknet round `timestamp` falls in; the Keeper and the dashboard compute what the contract will.
    /// @dev Defined from GENESIS on; an earlier timestamp reverts on the subtraction.
    function roundAt(uint256 timestamp) public pure returns (uint64) {
        return SafeCast.toUint64((timestamp - GENESIS) / PERIOD + 1);
    }

    // -------------------------------------------------------------- internals

    /// @dev The flag bits the verifier's unmarshalling would otherwise refuse with its own message, checked here so
    ///      every malformed input is refused as `InvalidSignature`.
    function _wellFormed(bytes calldata signature) internal pure returns (bool) {
        uint8 flags = uint8(signature[0]);
        return flags & FLAG_COMPRESSED != 0 && flags & FLAG_INFINITY == 0;
    }

    /// @dev drand's recipe: the message is `sha256(round as big-endian uint64)`, hashed to G1 under `DST`; the
    ///      signature is checked against the quicknet key with one two-pair pairing. False when the pairing fails
    ///      or the precompile rejects the point (off the curve or outside the subgroup). The verifier itself reverts
    ///      on a malformed compression flag or an input that is not 48 bytes; `fulfill` screens both first.
    function _verify(uint64 round, bytes memory signature) internal view returns (bool) {
        BLS2.PointG1 memory sig = BLS2.g1UnmarshalCompressed(signature);
        BLS2.PointG1 memory message = BLS2.hashToPoint(DST, abi.encodePacked(sha256(abi.encodePacked(round))));
        (bool ok, bool callOk) = BLS2.verifySingle(sig, _publicKey(), message);
        return ok && callOk;
    }

    /// @dev drand quicknet public key, uncompressed, in `BLS2.PointG2` limb order (x1, x0, y1, y0; 16 high bytes
    ///      then 32 low bytes each). Compressed form `0x83cf0f28…ece45a`, checked against
    ///      `api.drand.sh/<chain>/info` by a human before launch (draw spec §10). Virtual only so a test harness can
    ///      prove the constructor self-test catches a wrong key.
    function _publicKey() internal pure virtual returns (BLS2.PointG2 memory) {
        return BLS2.PointG2({
            x1_hi: 0x03cf0f2896adee7eb8b5f01fcad39122,
            x1_lo: 0x12c437e0073e911fb90022d3e760183c8c4b450b6a0a6c3ac6a5776a2d106451,
            x0_hi: 0x0d1fec758c921cc22b0e17e63aaf4bcb,
            x0_lo: 0x5ed66304de9cf809bd274ca73bab4af5a6e9c76a4bc09e76eae8991ef5ece45a,
            y1_hi: 0x01a714f2edb74119a2f2b0d5a7c75ba9,
            y1_lo: 0x02d163700a61bc224ededd8e63aef7be1aaf8e93d7a9718b047ccddb3eb5d68b,
            y0_hi: 0x0e5db2b6bfbb01c867749cadffca88b3,
            y0_lo: 0x6c24f3012ba09fc4d3022c5c37dce0f977d3adb5d183c7477c442b1f04515273
        });
    }

    /// @dev The round and signature the constructor verifies. Virtual only so a test harness can prove the
    ///      self-test catches a vector that does not verify.
    function _selfTestVector() internal pure virtual returns (uint64 round, bytes memory signature) {
        return (VECTOR_ROUND, VECTOR_SIG);
    }
}
