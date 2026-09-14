// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {NutzDistributor} from "../../src/NutzDistributor.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @dev Stands in for the Converter: the next contract the deployer creates must land on the predicted address.
contract Probe {}

contract DeployTest is Test {
    Deploy internal script;

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
    }

    function test_deploy_predictsTheConverterAddress() public {
        (NutzDistributor d, address predicted) = script.deploy(params(), address(script));
        assertEq(d.CONVERTER(), predicted);
        // the deployer's very next CREATE is where the Converter will live
        vm.prank(address(script));
        Probe probe = new Probe();
        assertEq(address(probe), predicted);
    }

    function test_check_revertsOnMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnexpectedConverterAddress.selector, address(1), address(2)));
        script.check(address(1), address(2));
    }

    function test_load_readsTheRobinhoodConfig() public view {
        Deploy.Params memory p = script.load(string.concat(vm.projectRoot(), "/script/config/robinhood.json"));
        assertEq(address(p.tokens[0]), 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C, "SPY");
        assertEq(address(p.tokens[4]), 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, "USDG");
        assertEq(p.pushGasBase, 100_000);
        assertEq(p.minUsdgPerEth, 1_000e6);
        assertEq(p.excludedBase.length, 1);
    }
}
