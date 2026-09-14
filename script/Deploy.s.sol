// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {NutzDistributor} from "../src/NutzDistributor.sol";

/// @notice Deploys the Nut Vault. The Distributor's CONVERTER is immutable and the Converter takes the
///         Distributor's address in its constructor, so the Converter's address is predicted from the
///         deployer's next nonce and asserted once it is deployed (engineering-spec §10, grilling Q20).
///
///   forge script script/Deploy.s.sol --rpc-url robinhood --account nutz-dev --broadcast --verify \
///     --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api/
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
    }

    error UnexpectedConverterAddress(address predicted, address actual);

    function run() external {
        Params memory p = load(string.concat(vm.projectRoot(), "/script/config/robinhood.json"));
        address deployer = msg.sender; // the --account / --sender forge broadcasts with
        vm.startBroadcast();
        (NutzDistributor d, address predictedConverter) = deploy(p, deployer);
        vm.stopBroadcast();
        console.log("NutzDistributor", address(d));
        console.log("Converter must deploy at", predictedConverter);
    }

    /// @dev Deploys the Distributor with the Converter address the same deployer will get on its next
    ///      CREATE. Deploying the Converter right after is the next step (its own ticket); until then the
    ///      caller must not send any other transaction from `deployer`.
    function deploy(Params memory p, address deployer) public returns (NutzDistributor d, address predictedConverter) {
        predictedConverter = vm.computeCreateAddress(deployer, vm.getNonce(deployer) + 1);
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
        // TODO(converter): NutzConverter c = new NutzConverter(address(d), ...); check(predictedConverter, address(c));
    }

    function check(address predicted, address actual) public pure {
        if (predicted != actual) revert UnexpectedConverterAddress(predicted, actual);
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
    }
}
