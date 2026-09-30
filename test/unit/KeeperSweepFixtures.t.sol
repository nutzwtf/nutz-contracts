// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";
import {NutzConverter} from "../../src/NutzConverter.sol";
import {ConverterBase} from "../harness/ConverterBase.sol";

/// @dev Prints the Sweep arithmetic cases nutz-platform's testdata/abi/generate.sh pins its Route planning to
///      (engineering spec §2.2 steps 3–5): for each Converter balance and Keeper balance, what `Swept` reported.
///      The mock router pays 3,000 USDG per ETH and one stock unit per USDG unit, so `amounts[0..3]` are `perStock`
///      itself and `usdgOut` is `(ethIn − opsAmt) × 3000e6 / 1e18`, the mock's own formula.
contract KeeperSweepFixturesTest is ConverterBase {
    uint256 internal constant ETH_USDG = 3_000e6;

    function setUp() public override {
        super.setUp();
        tok[4].mint(address(router), 100_000_000e6);
        router.setRate(address(tok[4]), ETH_USDG);
        for (uint256 i = 0; i < 4; i++) {
            tok[i].mint(address(router), 1_000_000e18);
            router.setRate(address(tok[i]), 1e18);
        }
    }

    function test_printsSweepFixtures() public {
        printCase("worked example", 1 ether, 0);
        printCase("odd balance, ops capped by headroom", 0.123456789012345678 ether, 0.49 ether);
        printCase("above the cap", 25 ether, 0.2 ether);
        printCase("keeper above opsCap", 7 ether, 0.6 ether);
    }

    function printCase(string memory name, uint256 balance, uint256 keeperBalance) internal {
        vm.deal(address(c), balance);
        vm.deal(keeper, keeperBalance);

        uint256 epochId = d.currentEpoch();
        NutzConverter.Route[6] memory routes = sweepRoutes();
        vm.recordLogs();
        vm.prank(keeper);
        c.sweep(epochId, routes, block.timestamp);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(c) || logs[i].topics[0] != NutzConverter.Swept.selector) continue;
            (uint256 ethIn, uint256 opsAmt, uint256[5] memory amounts, uint256 acornUsdg) =
                abi.decode(logs[i].data, (uint256, uint256, uint256[5], uint256));
            uint256[] memory list = new uint256[](5);
            for (uint256 j = 0; j < 5; j++) {
                list[j] = amounts[j];
            }
            string memory f = string.concat("fixture-", name);
            vm.serializeString(f, "name", name);
            vm.serializeUint(f, "balance", balance);
            vm.serializeUint(f, "keeperBalance", keeperBalance);
            vm.serializeUint(f, "opsCap", OPS_CAP);
            vm.serializeUint(f, "ethUsdgRate", ETH_USDG);
            vm.serializeUint(f, "ethIn", ethIn);
            vm.serializeUint(f, "opsAmt", opsAmt);
            vm.serializeUint(f, "usdgOut", (ethIn - opsAmt) * ETH_USDG / 1e18);
            vm.serializeUint(f, "amounts", list);
            string memory json = vm.serializeUint(f, "acornUsdg", acornUsdg);
            console.log(string.concat("FIXTURE ", json));
        }
        // Leave nothing behind for the next case: the Converter keeps only the ETH above MAX_SWEEP_ETH.
        vm.deal(address(c), 0);
    }
}
