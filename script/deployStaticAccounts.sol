// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {IEntryPoint} from "lib/account-abstraction/contracts/interfaces/IEntryPoint.sol";
import {StaticOpenfortAccount} from "../contracts/core/static/StaticOpenfortAccount.sol";
import {StaticOpenfortFactory} from "../contracts/core/static/StaticOpenfortFactory.sol";

contract StaticOpenfortDeploy is Script {
    uint256 internal deployPrivKey = vm.deriveKey(vm.envString("MNEMONIC"), 0);
    address internal deployAddress = vm.addr(deployPrivKey);
    IEntryPoint internal entryPoint = IEntryPoint((payable(vm.envAddress("ENTRY_POINT_ADDRESS"))));

    function run() public {
        bytes32 versionSalt = vm.envBytes32("VERSION_SALT");
        vm.startBroadcast(deployPrivKey);

        // Create an acccount to server as implementation
        StaticOpenfortAccount staticOpenfortAccount = new StaticOpenfortAccount{salt: versionSalt}();

        // Create a factory to deploy cloned accounts
        StaticOpenfortFactory staticOpenfortFactory =
            new StaticOpenfortFactory{salt: versionSalt}(address(entryPoint), address(staticOpenfortAccount));
        // address account1 = staticOpenfortFactory.accountImplementation();

        // The first call should create a new account, while the second will just return the corresponding account address
        address account2 = staticOpenfortFactory.createAccountWithNonce(deployAddress, "1");
        console.log(
            "Factory at address %s has created an account at address %s", address(staticOpenfortFactory), account2
        );
        // assert(account1 != account2);
        // address account3 = staticOpenfortFactory.createAccountWithNonce(deployAddress, 3);
        // console.log(
        //     "Factory at address %s has created an account at address %s", address(staticOpenfortFactory), account3
        // );
        // assert(account2 != account3);
        // address account4 = staticOpenfortFactory.createAccountWithNonce(deployAddress, 4);
        // console.log(
        //     "Factory at address %s has created an account at address %s", address(staticOpenfortFactory), account4
        // );
        // assert(account3 != account4);

        vm.stopBroadcast();
    }
}
