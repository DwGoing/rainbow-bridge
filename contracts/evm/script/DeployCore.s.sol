// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {EndPoint} from "../src/EndPoint.sol";
import {Relay} from "../src/Relay.sol";

contract DeployCore is Script {
    function run() external returns (address endpointProxy, address relayProxy) {
        uint256 deployerPk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address owner = vm.envAddress("DEPLOY_OWNER");
        uint256 chainId = vm.envUint("DEPLOY_CHAIN_ID");

        vm.startBroadcast(deployerPk);

        EndPoint endpointImpl = new EndPoint();
        bytes memory endpointInitData = abi.encodeCall(
            EndPoint.initialize,
            (owner, chainId)
        );
        endpointProxy = address(
            new ERC1967Proxy(address(endpointImpl), endpointInitData)
        );

        Relay relayImpl = new Relay();
        bytes memory relayInitData = abi.encodeCall(
            Relay.initialize,
            (owner, chainId)
        );
        relayProxy = address(new ERC1967Proxy(address(relayImpl), relayInitData));

        vm.stopBroadcast();

        string memory outputKey = "deployment";
        vm.serializeUint(outputKey, "chainId", chainId);
        vm.serializeAddress(outputKey, "owner", owner);
        vm.serializeAddress(
            outputKey,
            "endpointImplementation",
            address(endpointImpl)
        );
        vm.serializeAddress(outputKey, "endpointProxy", endpointProxy);
        vm.serializeAddress(
            outputKey,
            "relayImplementation",
            address(relayImpl)
        );
        string memory output = vm.serializeAddress(
            outputKey,
            "relayProxy",
            relayProxy
        );
        vm.writeJson(output, "data/deploy/evm.latest.json");

        console2.log("=== EVM Deployment ===");
        console2.log("chainId:", chainId);
        console2.log("owner:", owner);
        console2.log("endpointImplementation:", address(endpointImpl));
        console2.log("endpointProxy:", endpointProxy);
        console2.log("relayImplementation:", address(relayImpl));
        console2.log("relayProxy:", relayProxy);
        console2.log("saved:", "data/deploy/evm.latest.json");
    }
}
