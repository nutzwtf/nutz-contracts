// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NutzDistributor} from "../src/NutzDistributor.sol";
import {NutzConverter} from "../src/NutzConverter.sol";
import {NutzDraw} from "../src/NutzDraw.sol";
import {Signers} from "../src/Signers.sol";

/// @notice Deploys the Nut Vault. The Distributor's CONVERTER is immutable and the Converter takes the
///         Distributor's address in its constructor, so the Converter's address is predicted from the
///         deployer's next nonce, the Converter is deployed right after the Distributor, and the prediction
///         is asserted (engineering-spec §10, ADR-0003). The Draw follows: nothing on the Distributor names it at
///         construction, the Signers wire it later through `proposeDrawContract` / `executeDrawContract` (48h),
///         and its constructor self-test proves the EIP-2537 precompiles are live on the target chain (ADR-0004).
///
///   forge script script/Deploy.s.sol --rpc-url robinhood --account nutz-dev --broadcast --verify \
///     --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
///
///   Launch day (engineering-spec §10): after `launchAndBuy` names the Converter as creator fee recipient, the
///   Keeper calls `converter.bindNutz(NUTZ)`; the Sweep pulls no Pons fees until then. Before the first Sunday the
///   Signers `proposeDrawContract(draw)` and, 48 hours later, anyone `executeDrawContract(draw)`.
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

    error UnexpectedAddress(address predicted, address actual);
    /// @dev The config repeats an address the script appends itself, or names the zero address; the constructor
    ///      would store and emit it as given (`executeExclusion` refuses both), so the script refuses it first.
    error BadExcludedBase(address account);
    error RolesDiffer(address distributor, address converter);

    function run() external {
        Params memory p = load(string.concat(vm.projectRoot(), "/script/config/robinhood.json"));
        address deployer = msg.sender; // the --account / --sender forge broadcasts with
        vm.startBroadcast();
        (NutzDistributor d, NutzConverter c, NutzDraw draw) = deploy(p, deployer);
        vm.stopBroadcast();
        console.log("NutzDistributor", address(d));
        console.log("NutzConverter", address(c));
        console.log("NutzDraw", address(draw));
        console.log("After launchAndBuy, the Keeper binds NUTZ: converter.bindNutz(NUTZ)");
        console.log("Before the first Sunday, the Signers wire the Draw: proposeDrawContract, 48h, executeDrawContract");
    }

    /// @dev Deploys the Distributor with the Converter address `deployer` will get on its next CREATE, then the
    ///      Converter itself, and checks that it landed there and that both contracts carry the same Signers and
    ///      Keeper. Two consecutive transactions from `deployer`; nothing else may slip in between. The Draw comes
    ///      third and reverts `VerifierSelfTestFailed` on a chain without the EIP-2537 precompiles.
    function deploy(Params memory p, address deployer)
        public
        returns (NutzDistributor d, NutzConverter c, NutzDraw draw)
    {
        address predictedDistributor = vm.computeCreateAddress(deployer, vm.getNonce(deployer));
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
            excludedBase(p, predictedDistributor, predictedConverter)
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
        check(predictedDistributor, address(d));
        check(predictedConverter, address(c));
        checkRoles(d, c);
        draw = new NutzDraw(address(d));
    }

    /// @dev The base Excluded list (engineering-spec §3.5): the config's entries (the dead address, the Pons
    ///      contracts) plus the three addresses only the deploy knows or that the config would otherwise have to
    ///      repeat: the Distributor and the Converter themselves and the v4 PoolManager, which holds the graduated
    ///      pool's NUTZ. Review 2026-09, F02: the config alone carried the dead address.
    function excludedBase(Params memory p, address distributor, address converter)
        public
        pure
        returns (address[] memory list)
    {
        uint256 n = p.excludedBase.length;
        list = new address[](n + 3);
        for (uint256 i = 0; i < n; i++) {
            address a = p.excludedBase[i];
            if (a == address(0) || a == distributor || a == converter || a == p.v4PoolManager) {
                revert BadExcludedBase(a);
            }
            for (uint256 j = 0; j < i; j++) {
                if (list[j] == a) revert BadExcludedBase(a);
            }
            list[i] = a;
        }
        list[n] = distributor;
        list[n + 1] = converter;
        list[n + 2] = p.v4PoolManager;
    }

    /// @dev Both predictions are constructor inputs now (the Converter's in the Distributor, the Distributor's own
    ///      in its Excluded list), so both are asserted.
    function check(address predicted, address actual) public pure {
        if (predicted != actual) revert UnexpectedAddress(predicted, actual);
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
