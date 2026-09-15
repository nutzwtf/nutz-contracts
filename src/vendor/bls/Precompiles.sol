// SPDX-License-Identifier: MIT
// Vendored from randa-mu/bls-solidity, src/libraries/Precompiles.sol, tag v0.3.0,
// commit 9e10df92d631fab9c46f0ce9cd5c445f857bedcb. MIT, Copyright (c) 2025 Randamu; licence text in ./LICENSE.
// Upstream `pragma solidity ^0.8` kept: the repo's exact solc pin (0.8.37) satisfies it and the build accepts it.
pragma solidity ^0.8;

// @notice address of the EIP-198 modular exponentiation precompile
uint256 constant MODEXP_ADDRESS = 5;

// @notice address of the EIP-196 BN254 G1 point addition
uint256 constant ECADD_ADDRESS = 6;

// @notice address of the EIP-196 BN254 G1 scalar multiplication
uint256 constant ECMUL_ADDRESS = 7;

// @notice address of the EIP-197 BN254 pairing check
uint256 constant BN254_ECPAIRING_ADDRESS = 8;

// @notice address of the EIP-2537 BLS12-381 point addition precompile
uint256 constant BLS12_G1ADD = 0x0b;

// @notice address of the EIP-2537 BLS12-381 pairing check precompile
uint256 constant BLS12_PAIRING_CHECK = 0x0f;

// @notice address of the EIP-2537 BLS12-381 base field element to point precompile
// @dev it uses the Simplified Shallue-van de Woestĳne-Ulas mapping (SSWU)
uint256 constant BLS12_MAP_FP_TO_G1 = 0x10;
