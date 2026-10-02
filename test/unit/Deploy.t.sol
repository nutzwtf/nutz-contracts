// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";
import {NutzDraw} from "../../src/NutzDraw.sol";
import {Signers} from "../../src/Signers.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockSwapRouter02} from "../mocks/MockSwapRouter02.sol";

contract DeployTest is Test {
    Deploy internal script;
    address internal weth = makeAddr("weth");

    function setUp() public {
        vm.warp(1_800_000_000); // any real chain is far past epoch 0
        script = new Deploy();
    }

    function params() internal returns (Deploy.Params memory p) {
        p.signers = [makeAddr("a"), makeAddr("b"), makeAddr("c")];
        p.keeper = makeAddr("keeper");
        string[5] memory names = ["SPY", "NVDA", "MU", "SPCX", "USDG"];
        for (uint256 i = 0; i < 5; i++) {
            p.tokens[i] = IERC20(address(new MockERC20(names[i], names[i])));
        }
        p.pushGasBase = 100_000;
        p.pushGasPerLeaf = 40_000;
        p.minUsdgPerEth = 1_000e6;
        p.maxUsdgPerEth = 10_000e6;
        p.excludedBase = new address[](1);
        p.excludedBase[0] = 0x000000000000000000000000000000000000dEaD;
        p.weth = weth;
        p.v3Router = address(new MockSwapRouter02(weth));
        p.v4PoolManager = makeAddr("v4PoolManager");
        p.ponsFactory = makeAddr("ponsFactory");
        p.ponsEscrow = makeAddr("ponsEscrow");
        p.ponsHook = makeAddr("ponsHook");
        p.opsCapWei = 0.5 ether;
    }

    function test_deploy_converterLandsOnTheDistributorsImmutable() public {
        (NutzDistributor d, NutzConverter c,) = script.deploy(params(), address(script));
        assertEq(d.CONVERTER(), address(c), "the Distributor names the Converter that was deployed");
        assertEq(address(c.DISTRIBUTOR()), address(d), "the Converter names the Distributor");
    }

    function test_deploy_excludesTheContractsAndThePoolManager_afterTheConfigsEntries() public {
        // Review 2026-09, F02: the config carried the dead address alone; the script adds what only it knows.
        Deploy.Params memory p = params();
        (NutzDistributor d, NutzConverter c,) = script.deploy(p, address(script));
        address[] memory excluded = d.excluded();
        assertEq(excluded.length, 4);
        assertEq(excluded[0], 0x000000000000000000000000000000000000dEaD, "the config's entries come first");
        assertEq(excluded[1], address(d), "the Distributor excludes itself");
        assertEq(excluded[2], address(c), "and the Converter");
        assertEq(excluded[3], p.v4PoolManager, "and the v4 PoolManager, which holds the graduated pool's NUTZ");
    }

    function test_deployCore_leavesTheDrawToItsOwnStage() public {
        // Review 2026-09, F09: the launch deploys the pair; the Draw comes later, under the scope rule (§6).
        Deploy.Params memory p = params();
        uint256 nonceBefore = vm.getNonce(address(script));
        (NutzDistributor d, NutzConverter c) = script.deployCore(p, address(script));
        assertEq(vm.getNonce(address(script)), nonceBefore + 2, "exactly two creations");
        assertEq(d.CONVERTER(), address(c));
        NutzDraw draw = script.deployDraw(address(d));
        assertEq(address(draw.DISTRIBUTOR()), address(d), "the later stage names the Distributor it is given");
        assertEq(address(d.drawContract()), address(0), "and is not wired by the script");
    }

    function test_deploy_drawNamesTheDistributor() public {
        // the Draw's constructor self-test runs against the local prague precompiles here
        (NutzDistributor d,, NutzDraw draw) = script.deploy(params(), address(script));
        assertEq(address(draw.DISTRIBUTOR()), address(d), "the Draw names the Distributor");
        assertEq(address(d.drawContract()), address(0), "wiring is the Signers' timelocked step, not the script's");
    }

    function test_deploy_wiresTheConverterFromTheParams() public {
        Deploy.Params memory p = params();
        (, NutzConverter c,) = script.deploy(p, address(script));
        assertEq(c.WETH(), p.weth);
        assertEq(address(c.V3_ROUTER()), p.v3Router);
        assertEq(address(c.V4_POOL_MANAGER()), p.v4PoolManager);
        assertEq(address(c.PONS_FACTORY()), p.ponsFactory);
        assertEq(address(c.PONS_ESCROW()), p.ponsEscrow);
        assertEq(address(c.PONS_HOOK()), p.ponsHook);
        assertEq(c.opsCap(), p.opsCapWei);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(address(c.tokens(i)), address(p.tokens[i]));
        }
    }

    function test_deploy_bothContractsShareSignersAndKeeper() public {
        Deploy.Params memory p = params();
        (NutzDistributor d, NutzConverter c,) = script.deploy(p, address(script));
        for (uint256 i = 0; i < 3; i++) {
            assertEq(d.signers(i), p.signers[i]);
            assertEq(c.signers(i), p.signers[i]);
        }
        assertEq(d.keeper(), p.keeper);
        assertEq(c.keeper(), p.keeper);
    }

    function test_deploy_revertsWhenTheDeployerIsNotThePredictedOne() public {
        // predicted for one deployer, created by another: the Distributor's immutable would name an address the
        // Converter never lands on, and its Excluded list an address it does not sit at, so `deploy` must refuse
        // rather than leave that Distributor behind; the Distributor's own prediction is the first to miss
        Deploy.Params memory p = params();
        address other = makeAddr("other-deployer");
        address predicted = vm.computeCreateAddress(other, vm.getNonce(other));
        address actual = vm.computeCreateAddress(address(script), vm.getNonce(address(script)));
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedAddress.selector, predicted, actual));
        script.deploy(p, other);
    }

    function test_check_revertsOnMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedAddress.selector, address(1), address(2)));
        script.check(address(1), address(2));
    }

    function test_checkRoles_revertsWhenTheKeepersDiffer() public {
        Deploy.Params memory p = params();
        (NutzDistributor d,,) = script.deploy(p, address(script));
        p.keeper = makeAddr("other-keeper");
        (, NutzConverter c,) = script.deploy(p, address(script));
        vm.expectRevert(abi.encodeWithSelector(Deploy.RolesDiffer.selector, address(d), address(c)));
        script.checkRoles(Signers(address(d)), Signers(address(c)));
    }

    function test_checkRoles_revertsWhenASignerDiffers() public {
        Deploy.Params memory p = params();
        (NutzDistributor d,,) = script.deploy(p, address(script));
        p.signers[2] = makeAddr("other-signer");
        (, NutzConverter c,) = script.deploy(p, address(script));
        vm.expectRevert(abi.encodeWithSelector(Deploy.RolesDiffer.selector, address(d), address(c)));
        script.checkRoles(Signers(address(d)), Signers(address(c)));
    }

    function test_load_readsTheRobinhoodConfig() public view {
        Deploy.Params memory p = script.load(string.concat(vm.projectRoot(), "/script/config/robinhood.json"));
        assertEq(address(p.tokens[0]), 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, "SPY");
        assertEq(address(p.tokens[2]), 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, "MU");
        assertEq(address(p.tokens[3]), 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, "SPCX");
        assertEq(address(p.tokens[4]), 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, "USDG");
        assertEq(p.pushGasBase, 175_000, "measured, test/fork/PushGasFork.t.sol");
        assertEq(p.pushGasPerLeaf, 170_000, "the cold extra leaf");
        assertEq(p.minUsdgPerEth, 2_000e6); // ~80% of spot on the day it was set (review 2026-09, F06)
        assertEq(p.excludedBase.length, 3, "dead address, Pons locker, Pons buyback vault");
        assertEq(p.excludedBase[1], 0x267444D099b10fB5Ed7c3Cc7B7c767AdcA574952, "factory.locker()");
        assertEq(p.excludedBase[2], 0x42df2a798f82289E177311362e8f5ccC45c1219c, "factory.buybackVault()");
        assertEq(p.weth, 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, "WETH");
        assertEq(p.v3Router, 0xCaf681a66D020601342297493863E78C959E5cb2, "v3 router");
        assertEq(p.v4PoolManager, 0x8366a39CC670B4001A1121B8F6A443A643e40951, "v4 pool manager");
        assertEq(p.ponsFactory, 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e, "Pons factory");
        assertEq(p.ponsEscrow, 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e, "Pons escrow");
        assertEq(p.ponsHook, 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044, "Pons hook");
        assertEq(p.opsCapWei, 0.5 ether, "ops cap");
    }

    // ------------------------------------------------- constructor args for the post-deploy bytecode check

    /// @dev `scripts/verify-deploy.sh` rebuilds each creation code as `creationCode ++ args` and compares it with
    ///      the creation transaction, then re-runs it at the deployed address to compare runtime code. The encoders
    ///      must therefore produce exactly what `deployCore` / `deployDraw` passed: a twin deployed from them
    ///      carries every argument in the same slot. (Code hashes are compared only for the Draw: `Signers` is
    ///      EIP-712, whose cached domain separator is an immutable derived from the contract's own address, so a
    ///      twin at another address differs there by design.)
    function test_args_distributorTwinCarriesEveryArgument() public {
        Deploy.Params memory p = params();
        (NutzDistributor d, NutzConverter c,) = script.deploy(p, address(script));
        bytes memory args = script.distributorArgs(p, address(d), address(c));
        NutzDistributor twin = NutzDistributor(create(abi.encodePacked(type(NutzDistributor).creationCode, args)));
        assertEq(twin.CONVERTER(), address(c), "the Converter that was deployed, not a prediction");
        assertEq(twin.PUSH_GAS_BASE(), p.pushGasBase);
        assertEq(twin.PUSH_GAS_PER_LEAF(), p.pushGasPerLeaf);
        assertEq(twin.minUsdgPerEth(), p.minUsdgPerEth);
        assertEq(twin.maxUsdgPerEth(), p.maxUsdgPerEth);
        assertEq(twin.excluded(), d.excluded(), "the config's entries, then the script's three");
        assertEq(twin.keeper(), p.keeper);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(address(twin.tokens(i)), address(p.tokens[i]));
        }
        for (uint256 i = 0; i < 3; i++) {
            assertEq(twin.signers(i), p.signers[i]);
        }
    }

    function test_args_converterTwinCarriesEveryArgument() public {
        Deploy.Params memory p = params();
        (NutzDistributor d,,) = script.deploy(p, address(script));
        bytes memory args = script.converterArgs(p, address(d));
        NutzConverter twin = NutzConverter(payable(create(abi.encodePacked(type(NutzConverter).creationCode, args))));
        assertEq(address(twin.DISTRIBUTOR()), address(d), "the Distributor that was deployed");
        assertEq(twin.WETH(), p.weth);
        assertEq(address(twin.V3_ROUTER()), p.v3Router);
        assertEq(address(twin.V4_POOL_MANAGER()), p.v4PoolManager);
        assertEq(address(twin.PONS_FACTORY()), p.ponsFactory);
        assertEq(address(twin.PONS_ESCROW()), p.ponsEscrow);
        assertEq(address(twin.PONS_HOOK()), p.ponsHook);
        assertEq(twin.opsCap(), p.opsCapWei);
        assertEq(twin.keeper(), p.keeper);
        for (uint256 i = 0; i < 5; i++) {
            assertEq(address(twin.tokens(i)), address(p.tokens[i]));
        }
        for (uint256 i = 0; i < 3; i++) {
            assertEq(twin.signers(i), p.signers[i]);
        }
    }

    function test_args_drawTwinHasTheSameCode() public {
        (NutzDistributor d,, NutzDraw draw) = script.deploy(params(), address(script));
        bytes memory args = script.drawArgs(address(d));
        NutzDraw twin = NutzDraw(create(abi.encodePacked(type(NutzDraw).creationCode, args)));
        assertEq(
            address(twin).codehash, address(draw).codehash, "same runtime code, the Distributor immutable included"
        );
    }

    function test_args_changeWithTheConfig() public {
        Deploy.Params memory p = params();
        (NutzDistributor d, NutzConverter c,) = script.deploy(p, address(script));
        bytes memory before = script.distributorArgs(p, address(d), address(c));
        p.pushGasBase += 1;
        assertNotEq(keccak256(script.distributorArgs(p, address(d), address(c))), keccak256(before));
    }

    function create(bytes memory initCode) internal returns (address twin) {
        assembly {
            twin := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(twin != address(0), "twin creation failed");
    }
}
