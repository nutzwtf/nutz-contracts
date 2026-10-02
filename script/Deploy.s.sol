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
///   forge script script/Deploy.s.sol --rpc-url robinhood --account nutz-dev --broadcast
///
///   Without `--verify`: Blockscout's API answers forge with a Cloudflare challenge on chain 4663 (2026-10-02).
///   Verification is `scripts/verify-deploy.sh` afterwards (bytecode, Sourcify) and the Blockscout UI.
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

    string internal constant CONFIG = "/script/config/robinhood.json";

    error UnexpectedAddress(address predicted, address actual);
    /// @dev The config repeats an address the script appends itself, or names the zero address; the constructor
    ///      would store and emit it as given (`executeExclusion` refuses both), so the script refuses it first.
    error BadExcludedBase(address account);
    error RolesDiffer(address distributor, address converter);

    /// @notice The launch deploy: the Distributor and the Converter. The Draw is a later stage (`runDraw`), under
    ///         the scope rule of engineering-spec §6 (review 2026-09, F09).
    function run() external {
        Params memory p = load(string.concat(vm.projectRoot(), CONFIG));
        address deployer = msg.sender; // the --account / --sender forge broadcasts with
        vm.startBroadcast();
        (NutzDistributor d, NutzConverter c) = deployCore(p, deployer);
        vm.stopBroadcast();
        console.log("NutzDistributor", address(d));
        console.log("NutzConverter", address(c));
        console.log("After launchAndBuy, the Keeper binds NUTZ: converter.bindNutz(NUTZ)");
        console.log("Once gate item 10 is green: forge script ... --sig 'runDraw(address)' <distributor>");
    }

    /// @notice The Draw stage, run once its gate items are green: `--sig "runDraw(address)" <distributor>`.
    function runDraw(address distributor) external {
        vm.startBroadcast();
        NutzDraw draw = deployDraw(distributor);
        vm.stopBroadcast();
        console.log("NutzDraw", address(draw));
        console.log("The Signers wire it: proposeDrawContract(draw, sig1, sig2), 48h, executeDrawContract(draw)");
    }

    /// @notice Prints the ABI-encoded constructor arguments of the three contracts as deployed from the config,
    ///         for `scripts/verify-deploy.sh` (engineering-spec §10 step 2, launch gate item 9):
    ///         `--sig "args(address,address)" <distributor> <converter>`. Nothing is sent.
    function args(address distributor, address converter) external view {
        Params memory p = load(string.concat(vm.projectRoot(), CONFIG));
        console.log("distributor-args", vm.toString(distributorArgs(p, distributor, converter)));
        console.log("converter-args", vm.toString(converterArgs(p, distributor)));
        console.log("draw-args", vm.toString(drawArgs(distributor)));
    }

    /// @dev The Distributor's constructor arguments exactly as `deployCore` passes them: the Converter the
    ///      Distributor names is the one that was deployed, and the Excluded list carries the script's three
    ///      appended entries.
    function distributorArgs(Params memory p, address distributor, address converter)
        public
        pure
        returns (bytes memory)
    {
        return abi.encode(
            p.signers,
            p.keeper,
            converter,
            p.tokens,
            p.pushGasBase,
            p.pushGasPerLeaf,
            p.minUsdgPerEth,
            p.maxUsdgPerEth,
            excludedBase(p, distributor, converter)
        );
    }

    /// @dev The Converter's constructor arguments: the one struct `deployCore` passes.
    function converterArgs(Params memory p, address distributor) public pure returns (bytes memory) {
        return abi.encode(converterParams(p, distributor));
    }

    /// @dev The Converter's constructor struct from the config and the Distributor it serves.
    function converterParams(Params memory p, address distributor) public pure returns (NutzConverter.Params memory) {
        return NutzConverter.Params({
            signers: p.signers,
            keeper: p.keeper,
            distributor: distributor,
            tokens: p.tokens,
            weth: p.weth,
            v3Router: p.v3Router,
            v4PoolManager: p.v4PoolManager,
            ponsFactory: p.ponsFactory,
            ponsEscrow: p.ponsEscrow,
            ponsHook: p.ponsHook,
            opsCap: p.opsCapWei
        });
    }

    /// @dev The Draw's single constructor argument.
    function drawArgs(address distributor) public pure returns (bytes memory) {
        return abi.encode(distributor);
    }

    /// @dev All three in one go, for the tests and the fork suite; the two stages live in `deployCore` and
    ///      `deployDraw`.
    function deploy(Params memory p, address deployer)
        public
        returns (NutzDistributor d, NutzConverter c, NutzDraw draw)
    {
        (d, c) = deployCore(p, deployer);
        draw = deployDraw(address(d));
    }

    /// @dev Deploys the Distributor with the Converter address `deployer` will get on its next CREATE, then the
    ///      Converter itself, and checks that both landed where predicted and that both contracts carry the same
    ///      Signers and Keeper. Two consecutive transactions from `deployer`; nothing else may slip in between.
    function deployCore(Params memory p, address deployer) public returns (NutzDistributor d, NutzConverter c) {
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
        c = new NutzConverter(converterParams(p, address(d)));
        check(predictedDistributor, address(d));
        check(predictedConverter, address(c));
        checkRoles(d, c);
    }

    /// @dev The Draw's constructor verifies quicknet round 1000 through the chain's own EIP-2537 precompiles and
    ///      reverts `VerifierSelfTestFailed` if they are missing or the key is wrong.
    function deployDraw(address distributor) public returns (NutzDraw draw) {
        draw = new NutzDraw(distributor);
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
