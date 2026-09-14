// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";
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
        (NutzDistributor d, NutzConverter c) = script.deploy(params(), address(script));
        assertEq(d.CONVERTER(), address(c), "the Distributor names the Converter that was deployed");
        assertEq(address(c.DISTRIBUTOR()), address(d), "the Converter names the Distributor");
    }

    function test_deploy_wiresTheConverterFromTheParams() public {
        Deploy.Params memory p = params();
        (, NutzConverter c) = script.deploy(p, address(script));
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
        (NutzDistributor d, NutzConverter c) = script.deploy(p, address(script));
        for (uint256 i = 0; i < 3; i++) {
            assertEq(d.signers(i), p.signers[i]);
            assertEq(c.signers(i), p.signers[i]);
        }
        assertEq(d.keeper(), p.keeper);
        assertEq(c.keeper(), p.keeper);
    }

    function test_deploy_revertsWhenTheConverterMissesThePrediction() public {
        // predicted for one deployer, created by another: the Distributor's immutable would name an address the
        // Converter never lands on, so `deploy` must refuse rather than leave that Distributor behind
        Deploy.Params memory p = params();
        address other = makeAddr("other-deployer");
        address predicted = vm.computeCreateAddress(other, vm.getNonce(other) + 1);
        address actual = vm.computeCreateAddress(address(script), vm.getNonce(address(script)) + 1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedConverterAddress.selector, predicted, actual));
        script.deploy(p, other);
    }

    function test_check_revertsOnMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedConverterAddress.selector, address(1), address(2)));
        script.check(address(1), address(2));
    }

    function test_checkRoles_revertsWhenTheKeepersDiffer() public {
        Deploy.Params memory p = params();
        (NutzDistributor d,) = script.deploy(p, address(script));
        p.keeper = makeAddr("other-keeper");
        (, NutzConverter c) = script.deploy(p, address(script));
        vm.expectRevert(abi.encodeWithSelector(Deploy.RolesDiffer.selector, address(d), address(c)));
        script.checkRoles(Signers(address(d)), Signers(address(c)));
    }

    function test_checkRoles_revertsWhenASignerDiffers() public {
        Deploy.Params memory p = params();
        (NutzDistributor d,) = script.deploy(p, address(script));
        p.signers[2] = makeAddr("other-signer");
        (, NutzConverter c) = script.deploy(p, address(script));
        vm.expectRevert(abi.encodeWithSelector(Deploy.RolesDiffer.selector, address(d), address(c)));
        script.checkRoles(Signers(address(d)), Signers(address(c)));
    }

    function test_load_readsTheRobinhoodConfig() public view {
        Deploy.Params memory p = script.load(string.concat(vm.projectRoot(), "/script/config/robinhood.json"));
        assertEq(address(p.tokens[0]), 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, "SPY");
        assertEq(address(p.tokens[2]), 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD, "MU");
        assertEq(address(p.tokens[3]), 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa, "SPCX");
        assertEq(address(p.tokens[4]), 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, "USDG");
        assertEq(p.pushGasBase, 100_000);
        assertEq(p.minUsdgPerEth, 1_000e6);
        assertEq(p.excludedBase.length, 1);
        assertEq(p.weth, 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, "WETH");
        assertEq(p.v3Router, 0xCaf681a66D020601342297493863E78C959E5cb2, "v3 router");
        assertEq(p.v4PoolManager, 0x8366a39CC670B4001A1121B8F6A443A643e40951, "v4 pool manager");
        assertEq(p.ponsFactory, 0x7eD598BcEf8bd9Edd8C97A195C6d13f40801EC7e, "Pons factory");
        assertEq(p.ponsEscrow, 0xd3AFEB2a57f70eF218Aa82451c51B2fb0416Ac9e, "Pons escrow");
        assertEq(p.ponsHook, 0xE5e702641Ea86F4ae6cC3cDaeD2B886f976Be044, "Pons hook");
        assertEq(p.opsCapWei, 0.5 ether, "ops cap");
    }
}
