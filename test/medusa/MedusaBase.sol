// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {vm} from "chimera/Hevm.sol";
import {BaseSetup} from "chimera/BaseSetup.sol";

/// @dev `getNonce` is in Medusa's and forge's cheatcode sets but not in Chimera's `IHevm`.
interface IHevmNonce {
    function getNonce(address account) external returns (uint64);
}

IHevmNonce constant vmNonce = IHevmNonce(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D);

/// @dev What every Medusa fixture needs and forge-std would otherwise provide: named addresses, EIP-712 signing
///      and CREATE address prediction, written against the cheatcodes Medusa implements (`warp`, `prank`, `deal`,
///      `sign`, `addr`, `label`, `getNonce`); no `expectRevert`, `recordLogs` or `makeAddr` (docs/setup/tools.md).
abstract contract MedusaBase is BaseSetup {
    bytes32 internal constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    uint256 internal constant KEY_A = 0xA11CE;
    uint256 internal constant KEY_B = 0xB0B;
    uint256 internal constant KEY_C = 0xCA11;

    /// @dev forge-std's `makeAddr`: the address of the key `keccak256(name)`, labelled in traces.
    function _addr(string memory name) internal returns (address a) {
        a = vm.addr(uint256(keccak256(abi.encodePacked(name))));
        vm.label(a, name);
    }

    /// @dev A 65-byte `r || s || v` signature of `structHash` under the EIP-712 domain (`name`, "1", this chain,
    ///      `verifying`), built independently of the contract.
    function _sign712(uint256 key, string memory name, address verifying, bytes32 structHash)
        internal
        returns (bytes memory)
    {
        bytes32 ds = keccak256(
            abi.encode(DOMAIN_TYPEHASH, keccak256(bytes(name)), keccak256("1"), block.chainid, verifying)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, keccak256(abi.encodePacked("\x19\x01", ds, structHash)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev The address `deployer` creates at `nonce` (RLP of the pair, keccak, low 20 bytes); nonces below 2^16.
    function _createAddress(address deployer, uint256 nonce) internal pure returns (address) {
        bytes memory rlp;
        if (nonce == 0) rlp = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, bytes1(0x80));
        else if (nonce <= 0x7f) rlp = abi.encodePacked(bytes1(0xd6), bytes1(0x94), deployer, uint8(nonce));
        else if (nonce <= 0xff) rlp = abi.encodePacked(bytes1(0xd7), bytes1(0x94), deployer, bytes1(0x81), uint8(nonce));
        else rlp = abi.encodePacked(bytes1(0xd8), bytes1(0x94), deployer, bytes1(0x82), uint16(nonce));
        return address(uint160(uint256(keccak256(rlp))));
    }

    /// @dev Whether `err` is exactly the revert data `expected` (selector and arguments).
    function _reverted(bytes memory err, bytes memory expected) internal pure returns (bool) {
        return keccak256(err) == keccak256(expected);
    }

    /// @dev The reason a target function reports when a call the model says must succeed reverted: the call's
    ///      name and the revert selector, so the `Log` in Medusa's trace names the error without the trace.
    function _unexpectedReason(string memory what, bytes memory err) internal pure returns (string memory) {
        bytes memory hex_ = new bytes(8);
        bytes16 digits = "0123456789abcdef";
        for (uint256 i = 0; i < 4; i++) {
            uint8 b = err.length > i ? uint8(err[i]) : 0;
            hex_[2 * i] = digits[b >> 4];
            hex_[2 * i + 1] = digits[b & 0x0f];
        }
        return string.concat(what, " reverted unexpectedly: 0x", string(hex_));
    }
}
