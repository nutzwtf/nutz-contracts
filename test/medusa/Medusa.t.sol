// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {FoundryAsserts} from "chimera/FoundryAsserts.sol";
import {DistributorTargets} from "./DistributorTargets.sol";
import {DrawTargets} from "./DrawTargets.sol";
import {ConverterTargets} from "./ConverterTargets.sol";

/// @dev The Medusa harness under forge's invariant runner, Chimera's "CryticToFoundry": the same fixture, the same
///      target functions (listed by selector so forge does not call the ghost getters or the properties) and the
///      same properties, each wrapped as an `invariant_`. Keeps the harness compiling and its model honest on
///      every `forge test`; the long campaign is Medusa's (docs/setup/tools.md).
contract DistributorMedusaInvariantTest is DistributorTargets, FoundryAsserts {
    function setUp() public {
        setup();
        targetContract(address(this));
        bytes4[] memory s = new bytes4[](17);
        s[0] = this.warp.selector;
        s[1] = this.fundEpoch.selector;
        s[2] = this.postRoot.selector;
        s[3] = this.voidLatest.selector;
        s[4] = this.claim.selector;
        s[5] = this.claimMany.selector;
        s[6] = this.push.selector;
        s[7] = this.togglePause.selector;
        s[8] = this.claimStuck.selector;
        s[9] = this.fulfillAndPull.selector;
        s[10] = this.attackWrongProof.selector;
        s[11] = this.attackForeignAccount.selector;
        s[12] = this.attackInflatedAmounts.selector;
        s[13] = this.attackReplay.selector;
        s[14] = this.attackNotFinal.selector;
        s[15] = this.attackPushNotKeeper.selector;
        s[16] = this.attackPushForeignAccount.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: s}));
    }

    function invariant_claimedNeverExceedsFunded() public {
        property_claimedNeverExceedsFunded();
    }

    function invariant_balanceBacksObligations() public {
        property_balanceBacksObligations();
    }

    function invariant_carryConservation() public {
        property_carryConservation();
    }

    function invariant_tokensLeaveOnlyToLeafAccounts() public {
        property_tokensLeaveOnlyToLeafAccounts();
    }

    function invariant_claimsNeverExceedPeriodTotals() public {
        property_claimsNeverExceedPeriodTotals();
    }

    function invariant_claimedIsMonotone() public {
        property_claimedIsMonotone();
    }

    function invariant_everythingBelowTheMarkIsSettled() public {
        property_everythingBelowTheMarkIsSettled();
    }
}

contract DrawMedusaInvariantTest is DrawTargets, FoundryAsserts {
    function setUp() public {
        setup();
        targetContract(address(this));
        bytes4[] memory s = new bytes4[](8);
        s[0] = this.warp.selector;
        s[1] = this.requestAsKeeper.selector;
        s[2] = this.requestAsStranger.selector;
        s[3] = this.requestNotOpenWeek.selector;
        s[4] = this.fulfilVector.selector;
        s[5] = this.fulfilTampered.selector;
        s[6] = this.fulfilWrongLength.selector;
        s[7] = this.sendEth.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: s}));
    }

    function invariant_seedSetOnceBySubmittedSignature() public {
        property_seedSetOnceBySubmittedSignature();
    }

    function invariant_roundsMonotone() public {
        property_roundsMonotone();
    }

    function invariant_fulfilledDrawHasTickets() public {
        property_fulfilledDrawHasTickets();
    }

    function invariant_onlyKeeperRequestsEndedWeeks() public {
        property_onlyKeeperRequestsEndedWeeks();
    }

    function invariant_holdsNoEth() public {
        property_holdsNoEth();
    }
}

contract ConverterMedusaInvariantTest is ConverterTargets, FoundryAsserts {
    function setUp() public {
        setup();
        targetContract(address(this));
        bytes4[] memory s = new bytes4[](18);
        s[0] = this.warp.selector;
        s[1] = this.receiveEth.selector;
        s[2] = this.keeperWalletMoves.selector;
        s[3] = this.setRate.selector;
        s[4] = this.setFailure.selector;
        s[5] = this.disable.selector;
        s[6] = this.proposeEnable.selector;
        s[7] = this.executeEnable.selector;
        s[8] = this.setOpsCap.selector;
        s[9] = this.bindNutz.selector;
        s[10] = this.receiveNutz.selector;
        s[11] = this.setPhase.selector;
        s[12] = this.accrueCurveFees.selector;
        s[13] = this.accrueHookFees.selector;
        s[14] = this.creditEscrow.selector;
        s[15] = this.sweep.selector;
        s[16] = this.convertAcorn.selector;
        s[17] = this.strangerPokes.selector;
        targetSelector(FuzzSelector({addr: address(this), selectors: s}));
    }

    function invariant_neverHoldsRewardTokens() public {
        property_neverHoldsRewardTokens();
    }

    function invariant_sweepConvertsExactlyB() public {
        property_sweepConvertsExactlyB();
    }

    function invariant_opsSliceIsBounded() public {
        property_opsSliceIsBounded();
    }

    function invariant_distributorUsdgMatchesLedgers() public {
        property_distributorUsdgMatchesLedgers();
    }

    function invariant_ethLeavesOnlyToKeeperOrVenue() public {
        property_ethLeavesOnlyToKeeperOrVenue();
    }

    function invariant_nonKeeperMovesNothing() public {
        property_nonKeeperMovesNothing();
    }

    function invariant_rewardTokensGoNowhereButTheDistributor() public {
        property_rewardTokensGoNowhereButTheDistributor();
    }

    function invariant_disabledLegNeverSwaps() public {
        property_disabledLegNeverSwaps();
    }

    function invariant_circuitBreakerFlipsOnlyThroughGovernance() public {
        property_circuitBreakerFlipsOnlyThroughGovernance();
    }

    function invariant_opsCapWithinCeiling() public {
        property_opsCapWithinCeiling();
    }
}
