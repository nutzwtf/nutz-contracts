// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ConverterBase} from "../harness/ConverterBase.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";
import {Signers} from "../../src/Signers.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPonsV2LaunchFactory} from "../../src/interfaces/pons/IPonsV2LaunchFactory.sol";
import {MockPonsCurve} from "../mocks/pons/MockPonsCurve.sol";

contract ConverterGovernanceTest is ConverterBase {
    // ---- deployment ----

    function test_deploy_distributorAndConverterShareSignersAndKeeper() public view {
        for (uint256 i = 0; i < 3; i++) {
            assertEq(c.signers(i), d.signers(i));
        }
        assertEq(c.keeper(), d.keeper());
        assertEq(c.keeper(), keeper);
        assertEq(d.CONVERTER(), address(c));
        assertEq(address(c.DISTRIBUTOR()), address(d));
    }

    function test_deploy_recordsImmutablesAndOpsCap() public view {
        for (uint256 i = 0; i < 5; i++) {
            assertEq(address(c.tokens(i)), address(tok[i]));
        }
        assertEq(c.WETH(), address(weth));
        assertEq(address(c.V3_ROUTER()), address(router));
        assertEq(address(c.V4_POOL_MANAGER()), address(pm));
        assertEq(address(c.PONS_FACTORY()), address(factory));
        assertEq(address(c.PONS_ESCROW()), address(escrow));
        assertEq(address(c.PONS_HOOK()), address(hook));
        assertEq(c.opsCap(), 0.5 ether);
        assertEq(c.nutz(), address(0));
        assertEq(c.curve(), address(0));
        for (uint256 i = 0; i < 4; i++) {
            assertFalse(c.legDisabled(i));
        }
    }

    function test_receive_acceptsEthFromAnyone() public {
        address stranger = makeAddr("stranger");
        vm.deal(stranger, 1 ether);
        vm.deal(keeper, 2 ether);
        vm.prank(stranger);
        (bool ok,) = address(c).call{value: 1 ether}("");
        assertTrue(ok);
        vm.prank(keeper);
        (ok,) = address(c).call{value: 2 ether}("");
        assertTrue(ok);
        assertEq(address(c).balance, 3 ether);
    }
}

contract ConverterConstructorTest is ConverterBase {
    function expectZero(NutzConverter.Params memory p) internal {
        vm.expectRevert(Signers.ZeroAddress.selector);
        new NutzConverter(p);
    }

    function test_constructor_rejectsEveryZeroAddress() public {
        NutzConverter.Params memory p;
        p = params();
        p.distributor = address(0);
        expectZero(p);
        for (uint256 i = 0; i < 5; i++) {
            p = params();
            p.tokens[i] = IERC20(address(0));
            expectZero(p);
        }
        p = params();
        p.weth = address(0);
        expectZero(p);
        p = params();
        p.v3Router = address(0);
        expectZero(p);
        p = params();
        p.v4PoolManager = address(0);
        expectZero(p);
        p = params();
        p.ponsFactory = address(0);
        expectZero(p);
        p = params();
        p.ponsEscrow = address(0);
        expectZero(p);
        p = params();
        p.ponsHook = address(0);
        expectZero(p);
        p = params();
        p.keeper = address(0);
        expectZero(p);
        p = params();
        p.signers[1] = address(0);
        expectZero(p);
    }

    function test_constructor_rejectsOpsCapAboveMax() public {
        NutzConverter.Params memory p = params();
        p.opsCap = 5 ether + 1;
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.OpsCapTooHigh.selector, 5 ether + 1));
        new NutzConverter(p);
    }

    function test_constructor_acceptsOpsCapAtMaxAndZero() public {
        NutzConverter.Params memory p = params();
        p.opsCap = 5 ether;
        assertEq(new NutzConverter(p).opsCap(), 5 ether);
        p.opsCap = 0;
        assertEq(new NutzConverter(p).opsCap(), 0);
    }
}

contract ConverterBindTest is ConverterBase {
    address internal nutzToken = makeAddr("nutz");

    function test_bind_storesTokenAndCurve() public {
        MockPonsCurve curve = launch(nutzToken);
        vm.expectEmit(address(c));
        emit NutzConverter.NutzBound(address(0), nutzToken, address(curve));
        vm.prank(keeper);
        c.bindNutz(nutzToken);
        assertEq(c.nutz(), nutzToken);
        assertEq(c.curve(), address(curve));
    }

    function test_bind_rebindEmitsThePreviousToken() public {
        launch(nutzToken);
        vm.prank(keeper);
        c.bindNutz(nutzToken);
        address other = makeAddr("nutz2");
        MockPonsCurve curve2 = launch(other);
        vm.expectEmit(address(c));
        emit NutzConverter.NutzBound(nutzToken, other, address(curve2));
        vm.prank(keeper);
        c.bindNutz(other);
        assertEq(c.nutz(), other);
        assertEq(c.curve(), address(curve2));
    }

    function test_bind_nonKeeperReverts() public {
        launch(nutzToken);
        vm.expectRevert(Signers.NotKeeper.selector);
        vm.prank(makeAddr("stranger"));
        c.bindNutz(nutzToken);
        vm.expectRevert(Signers.NotKeeper.selector);
        vm.prank(vm.addr(KEY_A));
        c.bindNutz(nutzToken);
    }

    function test_bind_unknownTokenReverts() public {
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.NotOurLaunch.selector, nutzToken));
        vm.prank(keeper);
        c.bindNutz(nutzToken);
        vm.expectRevert(Signers.ZeroAddress.selector);
        vm.prank(keeper);
        c.bindNutz(address(0));
    }

    function test_bind_wrongRecipientReverts() public {
        // a stranger's launch naming someone else as recipient; the record exists but is not ours
        IPonsV2LaunchFactory.LaunchedToken memory L = launchRecord(nutzToken, makeAddr("curve"));
        L.creatorFeeRecipient = makeAddr("someoneElse");
        factory.setLaunchedToken(nutzToken, L);
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.NotOurLaunch.selector, nutzToken));
        vm.prank(keeper);
        c.bindNutz(nutzToken);
    }

    function test_bind_nonEthPairReverts() public {
        IPonsV2LaunchFactory.LaunchedToken memory L = launchRecord(nutzToken, makeAddr("curve"));
        L.pairToken = address(tok[4]); // a USDG-quoted launch
        factory.setLaunchedToken(nutzToken, L);
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.NotEthQuoted.selector, nutzToken));
        vm.prank(keeper);
        c.bindNutz(nutzToken);
        assertEq(c.nutz(), address(0));
    }
}

contract ConverterOpsCapTest is ConverterBase {
    function test_setOpsCap_setsAndEmitsPrevious() public {
        vm.expectEmit(address(c));
        emit NutzConverter.OpsCapSet(0.5 ether, 2 ether);
        setOpsCap(2 ether);
        assertEq(c.opsCap(), 2 ether);
    }

    function test_setOpsCap_zeroTurnsOpsOff() public {
        setOpsCap(0);
        assertEq(c.opsCap(), 0);
    }

    function test_setOpsCap_atMaxAllowed_aboveMaxReverts() public {
        setOpsCap(5 ether);
        assertEq(c.opsCap(), 5 ether);
        bytes32 sh = setOpsCapHash(5 ether + 1, c.nonce());
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.OpsCapTooHigh.selector, 5 ether + 1));
        c.setOpsCap(5 ether + 1, sign(KEY_A, sh), sign(KEY_B, sh));
        assertEq(c.opsCap(), 5 ether);
    }

    function test_setOpsCap_requiresTwoDistinctSigners() public {
        bytes32 sh = setOpsCapHash(1 ether, c.nonce());
        vm.expectRevert(Signers.SameSigner.selector);
        c.setOpsCap(1 ether, sign(KEY_A, sh), sign(KEY_A, sh));
        vm.expectRevert(abi.encodeWithSelector(Signers.NotSigner.selector, vm.addr(KEY_X)));
        c.setOpsCap(1 ether, sign(KEY_A, sh), sign(KEY_X, sh));
        // the order of the two signatures does not matter
        vm.expectRevert(abi.encodeWithSelector(Signers.NotSigner.selector, vm.addr(KEY_X)));
        c.setOpsCap(1 ether, sign(KEY_X, sh), sign(KEY_B, sh));
        assertEq(c.opsCap(), 0.5 ether);
    }

    function test_setOpsCap_consumesTheNonce() public {
        uint256 n = c.nonce();
        bytes32 sh = setOpsCapHash(1 ether, n);
        bytes memory s1 = sign(KEY_A, sh);
        bytes memory s2 = sign(KEY_B, sh);
        c.setOpsCap(1 ether, s1, s2);
        assertEq(c.nonce(), n + 1);
        // replaying the same signatures recovers strangers under the new nonce
        vm.expectPartialRevert(Signers.NotSigner.selector);
        c.setOpsCap(1 ether, s1, s2);
        assertEq(c.opsCap(), 1 ether);
    }

    function test_setOpsCap_nonceIsIndependentOfTheDistributor() public {
        setOpsCap(1 ether);
        assertEq(c.nonce(), 1);
        assertEq(d.nonce(), 0);
    }
}

contract ConverterDisableLegTest is ConverterBase {
    function test_disableLeg_isInstant() public {
        vm.expectEmit(address(c));
        emit NutzConverter.LegDisabled(2);
        disableLeg(2);
        assertTrue(c.legDisabled(2));
        assertFalse(c.legDisabled(0));
        assertFalse(c.legDisabled(1));
        assertFalse(c.legDisabled(3));
        assertEq(c.nonce(), 1);
    }

    function test_disableLeg_everyStockIndependently() public {
        for (uint8 i = 0; i < 4; i++) {
            disableLeg(i);
        }
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(c.legDisabled(i));
        }
    }

    function test_disableLeg_twiceReverts() public {
        disableLeg(1);
        bytes32 sh = disableLegHash(1, c.nonce());
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.LegAlreadyDisabled.selector, 1));
        c.disableLeg(1, sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_disableLeg_usdgIsNotALeg() public {
        bytes32 sh = disableLegHash(4, c.nonce());
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.InvalidLeg.selector, 4));
        c.disableLeg(4, sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_disableLeg_requiresTwoSigners() public {
        bytes32 sh = disableLegHash(0, c.nonce());
        vm.expectRevert(Signers.SameSigner.selector);
        c.disableLeg(0, sign(KEY_B, sh), sign(KEY_B, sh));
        vm.expectRevert(abi.encodeWithSelector(Signers.NotSigner.selector, vm.addr(KEY_X)));
        c.disableLeg(0, sign(KEY_X, sh), sign(KEY_B, sh));
        assertFalse(c.legDisabled(0));
    }
}

contract ConverterEnableLegTest is ConverterBase {
    uint256 internal constant TIMELOCK = 48 hours;
    uint256 internal constant PROPOSAL_TTL = 7 days;

    function setUp() public override {
        super.setUp();
        disableLeg(1);
    }

    function test_propose_schedulesTheEnable() public {
        uint256 n = c.nonce();
        vm.expectEmit(address(c));
        emit Signers.Scheduled(enableLegId(1), block.timestamp + TIMELOCK);
        proposeLegEnable(1);
        assertEq(c.readyAt(enableLegId(1)), block.timestamp + TIMELOCK);
        assertEq(c.nonce(), n + 1);
        assertTrue(c.legDisabled(1), "still disabled until executed");
    }

    function test_propose_onAnEnabledLegReverts() public {
        bytes32 sh = enableLegHash(0, c.nonce());
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.LegNotDisabled.selector, 0));
        c.proposeLegEnable(0, sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_propose_usdgIsNotALeg() public {
        bytes32 sh = enableLegHash(4, c.nonce());
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.InvalidLeg.selector, 4));
        c.proposeLegEnable(4, sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_propose_requiresTwoSigners() public {
        bytes32 sh = enableLegHash(1, c.nonce());
        vm.expectRevert(Signers.SameSigner.selector);
        c.proposeLegEnable(1, sign(KEY_A, sh), sign(KEY_A, sh));
        vm.expectRevert(abi.encodeWithSelector(Signers.NotSigner.selector, vm.addr(KEY_X)));
        c.proposeLegEnable(1, sign(KEY_X, sh), sign(KEY_B, sh));
        assertEq(c.readyAt(enableLegId(1)), 0);
    }

    function test_propose_twiceReverts() public {
        proposeLegEnable(1);
        bytes32 sh = enableLegHash(1, c.nonce());
        vm.expectRevert(Signers.AlreadyScheduled.selector);
        c.proposeLegEnable(1, sign(KEY_A, sh), sign(KEY_B, sh));
    }

    function test_execute_beforeReadyReverts() public {
        proposeLegEnable(1);
        vm.warp(block.timestamp + TIMELOCK - 1);
        vm.expectRevert(Signers.NotReady.selector);
        c.executeLegEnable(1);
        assertTrue(c.legDisabled(1));
    }

    function test_execute_afterTimelockEnablesByAnyone() public {
        proposeLegEnable(1);
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectEmit(address(c));
        emit Signers.Executed(enableLegId(1));
        vm.expectEmit(address(c));
        emit NutzConverter.LegEnabled(1);
        vm.prank(makeAddr("anyone"));
        c.executeLegEnable(1);
        assertFalse(c.legDisabled(1));
        assertEq(c.readyAt(enableLegId(1)), 0);
    }

    function test_execute_afterTtlReverts() public {
        proposeLegEnable(1);
        vm.warp(block.timestamp + TIMELOCK + PROPOSAL_TTL + 1);
        vm.expectRevert(Signers.Expired.selector);
        c.executeLegEnable(1);
        assertTrue(c.legDisabled(1));
    }

    function test_execute_cancelledReverts() public {
        proposeLegEnable(1);
        cancel(enableLegId(1));
        vm.warp(block.timestamp + TIMELOCK);
        vm.expectRevert(Signers.NotScheduled.selector);
        c.executeLegEnable(1);
        assertTrue(c.legDisabled(1));
    }

    function test_execute_withoutProposalReverts() public {
        vm.expectRevert(Signers.NotScheduled.selector);
        c.executeLegEnable(1);
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.InvalidLeg.selector, 7));
        c.executeLegEnable(7);
    }

    function test_execute_rechecksTheLegIsStillDisabled() public {
        // No public path enables a Leg while its enable is queued (execute consumes the queue entry), so the
        // re-check is forced from storage here.
        proposeLegEnable(1);
        vm.warp(block.timestamp + TIMELOCK);
        vm.record();
        c.legDisabled(1);
        (bytes32[] memory reads,) = vm.accesses(address(c));
        assertEq(reads.length, 1, "the four flags share one slot");
        vm.store(address(c), reads[0], bytes32(0)); // clears every flag; only Leg 1 was set
        assertFalse(c.legDisabled(1));
        vm.expectRevert(abi.encodeWithSelector(NutzConverter.LegNotDisabled.selector, 1));
        c.executeLegEnable(1);
    }

    function test_disableAgainAfterEnable_reusesTheQueueId() public {
        proposeLegEnable(1);
        vm.warp(block.timestamp + TIMELOCK);
        c.executeLegEnable(1);
        disableLeg(1);
        proposeLegEnable(1);
        assertEq(c.readyAt(enableLegId(1)), block.timestamp + TIMELOCK);
        vm.warp(block.timestamp + TIMELOCK);
        c.executeLegEnable(1);
        assertFalse(c.legDisabled(1));
    }
}
