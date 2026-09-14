// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/// @title Signers
/// @notice Three Signers, any two of which approve every privileged action by signing EIP-712 typed data
///         that carries one global nonce. Also holds the Keeper address and a 48-hour timelock queue.
/// @dev Abstract: the inheriting contract defines its actions and calls `_require2of3` with the struct hash.
abstract contract Signers is EIP712 {
    error ZeroAddress();
    error DuplicateSigner();
    error NotSigner(address recovered);
    error SameSigner();
    error NotKeeper();
    error AlreadyScheduled();
    error NotScheduled();
    error NotReady();
    error Expired();

    event KeeperSet(address indexed previous, address indexed current);
    event Scheduled(bytes32 indexed id, uint256 readyAt);
    event Executed(bytes32 indexed id);
    event Cancelled(bytes32 indexed id);
    event SignerRotated(address indexed from, address indexed to);

    /// @notice Delay between scheduling a timelocked action and being able to execute it.
    uint256 public constant TIMELOCK = 48 hours;
    /// @notice Window after `readyAt` in which a scheduled action may still be executed.
    uint256 public constant PROPOSAL_TTL = 7 days;

    bytes32 private constant SET_KEEPER_TYPEHASH = keccak256("SetKeeper(address keeper,uint256 nonce)");
    bytes32 private constant ROTATE_TYPEHASH = keccak256("RotateSigner(address from,address to,uint256 nonce)");
    bytes32 private constant CANCEL_TYPEHASH = keccak256("Cancel(bytes32 id,uint256 nonce)");

    address[3] public signers;
    uint256 public nonce;
    address public keeper;
    /// @notice Timestamp from which a scheduled action id may be executed; 0 when nothing is scheduled.
    mapping(bytes32 id => uint256) public readyAt;

    constructor(string memory name, address[3] memory signers_, address keeper_) EIP712(name, "1") {
        (address s0, address s1, address s2) = (signers_[0], signers_[1], signers_[2]);
        if (s0 == address(0) || s1 == address(0) || s2 == address(0) || keeper_ == address(0)) revert ZeroAddress();
        if (s0 == s1 || s0 == s2 || s1 == s2) revert DuplicateSigner();
        signers = signers_;
        keeper = keeper_;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert NotKeeper();
        _;
    }

    /// @notice Replaces the Keeper immediately. 2-of-3 over `SetKeeper(address keeper,uint256 nonce)`.
    function setKeeper(address newKeeper, bytes calldata sig1, bytes calldata sig2) external {
        if (newKeeper == address(0)) revert ZeroAddress();
        _require2of3(keccak256(abi.encode(SET_KEEPER_TYPEHASH, newKeeper, nonce)), sig1, sig2);
        emit KeeperSet(keeper, newKeeper);
        keeper = newKeeper;
    }

    /// @notice Schedules replacing Signer `from` with `to`. 2-of-3 over `RotateSigner(address from,address to,uint256 nonce)`.
    ///         Executable by anyone after `TIMELOCK` via `executeSignerRotation`.
    function proposeSignerRotation(address from, address to, bytes calldata sig1, bytes calldata sig2) external {
        _checkRotation(from, to);
        _require2of3(keccak256(abi.encode(ROTATE_TYPEHASH, from, to, nonce)), sig1, sig2);
        _schedule(keccak256(abi.encode(ROTATE_TYPEHASH, from, to)));
    }

    /// @notice Executes a scheduled Signer rotation once its timelock has elapsed. Conditions are re-checked.
    function executeSignerRotation(address from, address to) external {
        _consume(keccak256(abi.encode(ROTATE_TYPEHASH, from, to)));
        _checkRotation(from, to);
        uint256 slot = signers[0] == from ? 0 : signers[1] == from ? 1 : 2;
        signers[slot] = to;
        emit SignerRotated(from, to);
    }

    /// @notice Cancels a scheduled action. 2-of-3 over `Cancel(bytes32 id,uint256 nonce)`.
    function cancel(bytes32 id, bytes calldata sig1, bytes calldata sig2) external {
        // slither-disable-next-line incorrect-equality
        if (readyAt[id] == 0) revert NotScheduled(); // zero is the "nothing scheduled" sentinel
        _require2of3(keccak256(abi.encode(CANCEL_TYPEHASH, id, nonce)), sig1, sig2);
        delete readyAt[id];
        emit Cancelled(id);
    }

    function _checkRotation(address from, address to) private view {
        if (to == address(0)) revert ZeroAddress();
        if (!_isSigner(from)) revert NotSigner(from);
        if (_isSigner(to)) revert DuplicateSigner();
    }

    /// @dev Puts action `id` in the timelock queue.
    function _schedule(bytes32 id) internal {
        if (readyAt[id] != 0) revert AlreadyScheduled();
        uint256 ready = block.timestamp + TIMELOCK;
        readyAt[id] = ready;
        emit Scheduled(id, ready);
    }

    /// @dev Removes action `id` from the queue if it is ready and not expired; reverts otherwise.
    function _consume(bytes32 id) internal {
        uint256 ready = readyAt[id];
        // slither-disable-next-line incorrect-equality
        if (ready == 0) revert NotScheduled(); // zero is the "nothing scheduled" sentinel
        // A sequencer can skew block.timestamp by seconds; the delay here is 48 hours and the window 7 days.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp < ready) revert NotReady();
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp > ready + PROPOSAL_TTL) revert Expired();
        delete readyAt[id];
        emit Executed(id);
    }

    /// @dev Verifies two distinct Signer signatures over `structHash` (which must include the current nonce),
    ///      then consumes the nonce. Reverts otherwise.
    function _require2of3(bytes32 structHash, bytes calldata sig1, bytes calldata sig2) internal {
        bytes32 digest = _hashTypedDataV4(structHash);
        address a = ECDSA.recover(digest, sig1);
        address b = ECDSA.recover(digest, sig2);
        if (a == b) revert SameSigner();
        if (!_isSigner(a)) revert NotSigner(a);
        if (!_isSigner(b)) revert NotSigner(b);
        nonce++;
    }

    function _isSigner(address who) internal view returns (bool) {
        return who == signers[0] || who == signers[1] || who == signers[2];
    }
}
