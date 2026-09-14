// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NutzDistributor} from "../src/NutzDistributor.sol";
import {NutzConverter} from "../src/NutzConverter.sol";
import {Signers} from "../src/Signers.sol";

/// @notice Deploys the Nut Vault. The Distributor's CONVERTER is immutable and the Converter takes the
///         Distributor's address in its constructor, so the Converter's address is predicted from the
///         deployer's next nonce, the Converter is deployed right after the Distributor, and the prediction
///         is asserted (engineering-spec §10, ADR-0003).
///
///   forge script script/Deploy.s.sol --rpc-url robinhood --account nutz-dev --broadcast --verify \
///     --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
///
///   Launch day (engineering-spec §10): after `launchAndBuy` names the Converter as creator fee recipient, the
///   Keeper calls `converter.bindNutz(NUTZ)`; the Sweep pulls no Pons fees until then.
contract Deploy is Script {
    struct Params {
        address[3] signers;
        address keeper;
        IERC20[5] tokens; // SPY, NVDA, MU, SPCX, USDG
        uint256 pushGasBase;
        uint256 pushGasPerLeaf;
        uint256 minUsdgPerEth;
        uint256 maxUsdgPerEth;
        address[] excludedBase;
        address weth;
        address v3Router;
        address v4PoolManager;
        address ponsFactory;
        address ponsEscrow;
        address ponsHook;
        uint256 opsCapWei;
    }

    error UnexpectedConverterAddress(address predicted, address actual);
    error RolesDiffer(address distributor, address converter);

    function run() external {
        Params memory p = load(string.concat(vm.projectRoot(), "/script/config/robinhood.json"));
        address deployer = msg.sender; // the --account / --sender forge broadcasts with
        vm.startBroadcast();
        (NutzDistributor d, NutzConverter c) = deploy(p, deployer);
        vm.stopBroadcast();
        console.log("NutzDistributor", address(d));
        console.log("NutzConverter", address(c));
        console.log("After launchAndBuy, the Keeper binds NUTZ: converter.bindNutz(NUTZ)");
    }

    /// @dev Deploys the Distributor with the Converter address `deployer` will get on its next CREATE, then the
    ///      Converter itself, and checks that it landed there and that both contracts carry the same Signers and
    ///      Keeper. Two consecutive transactions from `deployer`; nothing else may slip in between.
    function deploy(Params memory p, address deployer) public returns (NutzDistributor d, NutzConverter c) {
        address predictedConverter = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
        d = new NutzDistributor(
            p.signers,
            p.keeper,
            predictedConverter,
            p.tokens,
            p.pushGasBase,
            p.pushGasPerLeaf,
            p.minUsdgPerEth,
            p.maxUsdgPerEth,
            p.excludedBase
        );
        c = new NutzConverter(
            NutzConverter.Params({
                signers: p.signers,
                keeper: p.keeper,
                distributor: address(d),
                tokens: p.tokens,
                weth: p.weth,
                v3Router: p.v3Router,
                v4PoolManager: p.v4PoolManager,
                ponsFactory: p.ponsFactory,
                ponsEscrow: p.ponsEscrow,
                ponsHook: p.ponsHook,
                opsCap: p.opsCapWei
            })
        );
        check(predictedConverter, address(c));
        checkRoles(d, c);
    }

    function check(address predicted, address actual) public pure {
        if (predicted != actual) revert UnexpectedConverterAddress(predicted, actual);
    }

    /// @dev Both contracts are governed by the same three Signers and the same Keeper; anything else is a
    ///      construction mistake, since the two are only ever rotated together.
    // Three bounded view calls on two contracts this script just deployed.
    // forge-lint: disable-next-item(calls-loop)
    function checkRoles(Signers distributor, Signers converter) public view {
        bool same = distributor.keeper() == converter.keeper();
        for (uint256 i = 0; i < 3; i++) {
            same = same && distributor.signers(i) == converter.signers(i);
        }
        if (!same) revert RolesDiffer(address(distributor), address(converter));
    }

    function load(string memory path) public view returns (Params memory p) {
        string memory json = vm.readFile(path);
        address[] memory s = vm.parseJsonAddressArray(json, ".signers");
        p.signers = [s[0], s[1], s[2]];
        p.keeper = vm.parseJsonAddress(json, ".keeper");
        p.tokens = [
            IERC20(vm.parseJsonAddress(json, ".tokens.spy")),
            IERC20(vm.parseJsonAddress(json, ".tokens.nvda")),
            IERC20(vm.parseJsonAddress(json, ".tokens.mu")),
            IERC20(vm.parseJsonAddress(json, ".tokens.spcx")),
            IERC20(vm.parseJsonAddress(json, ".tokens.usdg"))
        ];
        p.pushGasBase = vm.parseJsonUint(json, ".pushGasBase");
        p.pushGasPerLeaf = vm.parseJsonUint(json, ".pushGasPerLeaf");
        p.minUsdgPerEth = vm.parseJsonUint(json, ".minUsdgPerEth");
        p.maxUsdgPerEth = vm.parseJsonUint(json, ".maxUsdgPerEth");
        p.excludedBase = vm.parseJsonAddressArray(json, ".excludedBase");
        p.weth = vm.parseJsonAddress(json, ".weth");
        p.v3Router = vm.parseJsonAddress(json, ".v3Router");
        p.v4PoolManager = vm.parseJsonAddress(json, ".v4PoolManager");
        p.ponsFactory = vm.parseJsonAddress(json, ".ponsFactory");
        p.ponsEscrow = vm.parseJsonAddress(json, ".ponsEscrow");
        p.ponsHook = vm.parseJsonAddress(json, ".ponsHook");
        p.opsCapWei = vm.parseJsonUint(json, ".opsCapWei");
    }
}
