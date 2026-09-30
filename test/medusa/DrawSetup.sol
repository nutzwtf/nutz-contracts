// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {vm} from "chimera/Hevm.sol";
import {NutzDraw} from "../../src/NutzDraw.sol";
import {MockDistributor} from "../mocks/MockDistributor.sol";
import {MedusaBase} from "./MedusaBase.sol";

/// @dev The Draw fixture of test/harness/DrawBase.sol: a mock Distributor, a deployed Draw (whose constructor runs
///      the BLS self-test, so this is where Medusa's EIP-2537 precompiles are first exercised) and the clock set
///      so that the first request commits to drand quicknet round 1000, the recorded vector, plus the ghosts of
///      test/invariant/DrawHandler.sol.
abstract contract DrawSetup is MedusaBase {
    uint256 internal constant GENESIS = 1_692_803_367;
    uint256 internal constant PERIOD = 3;
    uint256 internal constant LEAD = 10 minutes;
    uint64 internal constant VECTOR_ROUND = 1000;
    bytes internal constant VECTOR_SIG =
        hex"b44679b9a59af2ec876b1a6b1ad52ea9b1615fc3982b19576350f93447cb1125e342b73a8dd2bacbe47e4b6b63ed5e39";
    /// @dev A request here targets round 1000: roundAt(now + LEAD) == 1000 and no earlier round is committed.
    uint256 internal constant VECTOR_REQUEST_TS = GENESIS + (VECTOR_ROUND - 1) * PERIOD - LEAD;
    /// @dev A rejected point burns all the gas forwarded to the pairing precompile; bound what a bad fulfil costs.
    uint256 internal constant FULFIL_GAS_CAP = 400_000;
    uint256 internal constant ID_SPAN = 4;

    NutzDraw internal draw;
    MockDistributor internal dist;
    address internal keeper;
    address internal stranger;

    // ---- ghosts ----
    uint256[] internal ids; // every id that was ever requested
    mapping(uint256 id => bool) internal seen;
    mapping(uint256 id => uint64) internal ghostRound; // the round observed after the last successful request
    mapping(uint256 id => bytes32) internal ghostSeed; // the seed observed at the fulfilling call, zero before
    mapping(uint256 id => bytes) internal ghostSignature; // the signature that call submitted
    uint64 internal ghostMaxRound; // the highest round any successful request committed to
    bool internal ghostRoundDecreased; // a re-request committed to a lower round
    bool internal ghostFulfilledChanged; // a call touched a fulfilled draw
    bool internal ghostDueRoundReplaced; // a request replaced a round that was already public (F08)
    bool internal ghostBadSignatureAccepted; // a tampered or mis-sized signature fulfilled a draw
    bool internal ghostStrangerRequested; // a non-Keeper request succeeded
    bool internal ghostOpenWeekRequested; // a request for the running week succeeded

    function setup() internal virtual override {
        vm.warp(VECTOR_REQUEST_TS);
        keeper = _addr("keeper");
        stranger = _addr("stranger");
        dist = new MockDistributor(keeper);
        draw = new NutzDraw(address(dist));
    }
}
