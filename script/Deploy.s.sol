// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {CompounderRegistry} from "../src/CompounderRegistry.sol";
import {UserCompounder} from "../src/UserCompounder.sol";
import {KeeperMulticall} from "../src/KeeperMulticall.sol";

/// @notice Deploys the registry, implementation v1 and keeper multicall on Robinhood Chain,
///         sets the default UP routes and enables the initial pools.
///
///   forge script script/Deploy.s.sol --rpc-url robinhood --broadcast --verify \
///     --verifier blockscout --verifier-url https://robinhoodchain.blockscout.com/api
///
/// Env: PRIVATE_KEY (deployer), OWNER (protocol multisig), TREASURY, OPERATOR (keeper EOA, optional)
contract Deploy is Script {
    // up33 mainnet
    address constant VOTER = 0x7F749fDD351C1Ceed82d76d7699CB631Eb8332a7;
    address constant CL_FACTORY = 0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3;
    address constant NPM = 0x07F44c47743A2f36414A82b9F558ECFCf0EEdCEf;
    address constant SWAP_ROUTER = 0xC062b870E813fcA720f1e002c234369Ab3aB9415;
    address constant UP = 0x57C0E45cB534413D1C20A4240955d6bB250BB4F1;
    address constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    address constant POOL_WETH_USDG = 0x16679e2ac1A798865eCf1c1639e67693ddB1C220;
    address constant POOL_WETH_UP = 0x23D641FeCcD207E8794c593e8240444A0674C4Ba;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("OWNER", deployer);
        address treasury = vm.envOr("TREASURY", owner);
        address operator = vm.envOr("OPERATOR", address(0));

        vm.startBroadcast(pk);

        // Deployer keeps ownership during setup, then hands over.
        CompounderRegistry registry =
            new CompounderRegistry(VOTER, CL_FACTORY, NPM, SWAP_ROUTER, UP, treasury, deployer);
        UserCompounder implementation = new UserCompounder(address(registry), 1);
        KeeperMulticall keeper = new KeeperMulticall(address(registry), deployer);

        registry.addImplementation(address(implementation));
        registry.setRoute(UP, WETH, abi.encodePacked(UP, int24(200), WETH));
        registry.setRoute(UP, USDG, abi.encodePacked(UP, int24(200), WETH, int24(10), USDG));
        registry.enablePool(POOL_WETH_USDG);
        registry.enablePool(POOL_WETH_UP);
        registry.setProtocolKeeper(address(keeper));

        if (operator != address(0)) keeper.setOperator(operator, true);

        if (owner != deployer) {
            registry.transferOwnership(owner); // owner must call acceptOwnership()
            keeper.transferOwnership(owner);
        }

        vm.stopBroadcast();

        console2.log("CompounderRegistry:", address(registry));
        console2.log("UserCompounder v1: ", address(implementation));
        console2.log("KeeperMulticall:   ", address(keeper));
    }
}
