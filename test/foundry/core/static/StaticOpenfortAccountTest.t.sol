// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.19;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {SigUtils} from "../../utils/SigUtils.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {EntryPoint, UserOperation} from "account-abstraction/core/EntryPoint.sol";
import {TestCounter} from "account-abstraction/test/TestCounter.sol";
import {TestToken} from "account-abstraction/test/TestToken.sol";
import {StaticOpenfortAccount} from "contracts/core/static/StaticOpenfortAccount.sol";
import {StaticOpenfortFactory} from "contracts/core/static/StaticOpenfortFactory.sol";

contract StaticOpenfortAccountTest is Test {
    using ECDSA for bytes32;

    EntryPoint public entryPoint;
    StaticOpenfortAccount public staticOpenfortAccount;
    StaticOpenfortFactory public staticOpenfortFactory;
    address public account;
    TestCounter public testCounter;
    TestToken public testToken;

    // Testing addresses
    address private factoryAdmin;
    uint256 private factoryAdminPKey;

    address private accountAdmin;
    uint256 private accountAdminPKey;

    address payable private beneficiary = payable(makeAddr("beneficiary"));

    event AccountCreated(address indexed account, address indexed accountAdmin);

    /*
     * Auxiliary function to generate a userOP
     */
    function _setupUserOp(
        address sender,
        uint256 _signerPKey,
        bytes memory _initCode,
        bytes memory _callDataForEntrypoint
    ) internal returns (UserOperation[] memory ops) {
        uint256 nonce = entryPoint.getNonce(sender, 0);

        // Get user op fields
        UserOperation memory op = UserOperation({
            sender: sender,
            nonce: nonce,
            initCode: _initCode,
            callData: _callDataForEntrypoint,
            callGasLimit: 500_000,
            verificationGasLimit: 500_000,
            preVerificationGas: 500_000,
            maxFeePerGas: 0,
            maxPriorityFeePerGas: 0,
            paymasterAndData: bytes(""),
            signature: bytes("")
        });

        // Sign UserOp
        bytes32 opHash = EntryPoint(entryPoint).getUserOpHash(op);
        bytes32 msgHash = ECDSA.toEthSignedMessageHash(opHash);

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(_signerPKey, msgHash);
        bytes memory userOpSignature = abi.encodePacked(r, s, v);

        address recoveredSigner = ECDSA.recover(msgHash, v, r, s);
        address expectedSigner = vm.addr(_signerPKey);
        assertEq(recoveredSigner, expectedSigner);

        op.signature = userOpSignature;

        // Store UserOp
        ops = new UserOperation[](1);
        ops[0] = op;
    }

    /* 
     * Auxiliary function to generate a userOP using the execute()
     * from the account
     */
    function _setupUserOpExecute(
        address sender,
        uint256 _signerPKey,
        bytes memory _initCode,
        address _target,
        uint256 _value,
        bytes memory _callData
    ) internal returns (UserOperation[] memory) {
        bytes memory callDataForEntrypoint =
            abi.encodeWithSignature("execute(address,uint256,bytes)", _target, _value, _callData);

        return _setupUserOp(sender, _signerPKey, _initCode, callDataForEntrypoint);
    }

    /* 
     * Auxiliary function to generate a userOP using the executeBatch()
     * from the account
     */
    function _setupUserOpExecuteBatch(
        address sender,
        uint256 _signerPKey,
        bytes memory _initCode,
        address[] memory _target,
        uint256[] memory _value,
        bytes[] memory _callData
    ) internal returns (UserOperation[] memory) {
        bytes memory callDataForEntrypoint =
            abi.encodeWithSignature("executeBatch(address[],uint256[],bytes[])", _target, _value, _callData);

        return _setupUserOp(sender, _signerPKey, _initCode, callDataForEntrypoint);
    }

    /**
     * @notice Initialize the StaticOpenfortAccount testing contract.
     * Scenario:
     * - factoryAdmin is the deployer (and owner) of the StaticOpenfortFactory
     * - accountAdmin is the account used to deploy new static accounts
     * - entryPoint is the singleton EntryPoint
     * - testCounter is the counter used to test userOps
     */
    function setUp() public {
        // Setup and fund signers
        (factoryAdmin, factoryAdminPKey) = makeAddrAndKey("factoryAdmin");
        vm.deal(factoryAdmin, 100 ether);
        (accountAdmin, accountAdminPKey) = makeAddrAndKey("accountAdmin");
        vm.deal(accountAdmin, 100 ether);

        vm.startPrank(factoryAdmin);
        // If we are in a fork
        if (vm.envAddress("ENTRY_POINT_ADDRESS").code.length > 0) {
            entryPoint = EntryPoint(payable(vm.envAddress("ENTRY_POINT_ADDRESS")));
        }
        // If not a fork, deploy entryPoint (at correct address)
        else {
            EntryPoint entryPoint_aux = new EntryPoint();
            bytes memory code = address(entryPoint_aux).code;
            address targetAddr = address(vm.envAddress("ENTRY_POINT_ADDRESS"));
            vm.etch(targetAddr, code);
            entryPoint = EntryPoint(payable(targetAddr));
        }
        // deploy static account implementation
        staticOpenfortAccount = new StaticOpenfortAccount();
        // deploy static account factory
        staticOpenfortFactory = new StaticOpenfortFactory(payable(address(entryPoint)), address(staticOpenfortAccount));
        // Create an static account wallet and get its address
        account = staticOpenfortFactory.createAccountWithNonce(accountAdmin, "1");
        // deploy a new TestCounter
        testCounter = new TestCounter();
        // deploy a new TestToken (ERC20)
        testToken = new TestToken();
        vm.stopPrank();
    }

    /*
     * Create an account by directly calling the factory.
     */
    function testCreateAccountWithNonceViaFactory() public {
        // Get the counterfactual address
        vm.prank(factoryAdmin);
        address accountAddress2 = staticOpenfortFactory.getAddressWithNonce(accountAdmin, "2");

        // Expect that we will see an event containing the account and admin
        vm.expectEmit(true, true, false, true);
        emit AccountCreated(accountAddress2, accountAdmin);

        // Deploy a static account to the counterfactual address
        vm.prank(factoryAdmin);
        staticOpenfortFactory.createAccountWithNonce(accountAdmin, "2");

        // Calling it again should just return the address and not create another account
        vm.prank(factoryAdmin);
        staticOpenfortFactory.createAccountWithNonce(accountAdmin, "2");

        // Make sure the counterfactual address has not been altered
        vm.prank(factoryAdmin);
        assertEq(accountAddress2, staticOpenfortFactory.getAddressWithNonce(accountAdmin, "2"));
    }

    /*
     * Create an account calling the factory via EntryPoint.
     * Use initCode
     */
    function testCreateAccountViaEntryPoint() public {
        // It is not correct to use the Factory using the EntryPoint anymore
        // Accounts created using factories are depend on msg.sender now
        // revert();

        // Make sure the smart account does not have any code yet
        address account2 = staticOpenfortFactory.getAddressWithNonce(accountAdmin, bytes32("2"));
        assertEq(account2.code.length, 0);

        bytes memory initCallData =
            abi.encodeWithSignature("createAccountWithNonce(address,bytes32)", accountAdmin, bytes32("2"));
        bytes memory initCode = abi.encodePacked(abi.encodePacked(address(staticOpenfortFactory)), initCallData);

        UserOperation[] memory userOpCreateAccount =
            _setupUserOpExecute(account2, accountAdminPKey, initCode, address(0), 0, bytes(""));

        // Expect that we will see an event containing the account and admin
        vm.expectEmit(true, true, false, true);
        emit AccountCreated(account2, accountAdmin);

        entryPoint.handleOps(userOpCreateAccount, beneficiary);

        // Make sure the smart account does have some code now
        assert(account2.code.length > 0);

        // Make sure the counterfactual address has not been altered
        assertEq(account2, staticOpenfortFactory.getAddressWithNonce(accountAdmin, bytes32("2")));
    }

    /*
     * Create an account using the factory and make it call count() directly.
     */
    function testIncrementCounterDirect() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        // Make the admin of the static account wallet (deployer) call "count"
        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).execute(address(testCounter), 0, abi.encodeWithSignature("count()"));

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);
    }

    /*
     * Create an account by directly calling the factory and make it call count()
     * using the execute() function using the EntryPoint (userOp). Leaveraging ERC-4337.
     */
    function testIncrementCounterViaEntrypoint() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, accountAdminPKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);
    }

    /*
     * Create an account by directly calling the factory and make it call count()
     * using the executeBatching() function using the EntryPoint (userOp). Leaveraging ERC-4337.
     */
    function testIncrementCounterViaEntrypointBatching() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        uint256 count = 3;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        for (uint256 i = 0; i < count; i += 1) {
            targets[i] = address(testCounter);
            values[i] = 0;
            callData[i] = abi.encodeWithSignature("count()");
        }

        UserOperation[] memory userOp =
            _setupUserOpExecuteBatch(account, accountAdminPKey, bytes(""), targets, values, callData);

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 3);
    }

    /*
     *  Should fail, try to use a sessionKey that is not registered.
     */
    function testFailIncrementCounterViaSessionKeyNotregistered() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has not increased
        assertEq(testCounter.counters(account), 0);
    }

    /*
     * Use a sessionKey that is registered.
     */
    function testIncrementCounterViaSessionKey() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 2 ** 48 - 1);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);
    }

    /*
     * Register a sessionKey via userOp calling the execute() function
     * using the EntryPoint (userOp). Then use the sessionKey to count
     */
    function testRegisterSessionKeyViaEntrypoint() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        UserOperation[] memory userOp = _setupUserOpExecute(
            account,
            accountAdminPKey,
            bytes(""),
            account,
            0,
            abi.encodeWithSignature("registerSessionKey(address,uint48,uint48)", sessionKey, 0, 2 ** 48 - 1)
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has not increased
        assertEq(testCounter.counters(account), 0);

        userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);
    }

    /*
     * Register a master sessionKey via userOp calling the execute() function
     * using the EntryPoint (userOp). Then use that sessionKey to register a second one
     */
    function testRegisterSessionKeyViaEntrypoint2ndKey() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        UserOperation[] memory userOp = _setupUserOpExecute(
            account,
            accountAdminPKey,
            bytes(""),
            account,
            0,
            abi.encodeWithSignature("registerSessionKey(address,uint48,uint48)", sessionKey, 0, 2 ** 48 - 1)
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has not increased
        assertEq(testCounter.counters(account), 0);

        userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);

        address sessionKeyAttack;
        uint256 sessionKeyPrivKeyAttack;
        (sessionKeyAttack, sessionKeyPrivKeyAttack) = makeAddrAndKey("sessionKeyAttack");

        userOp = _setupUserOpExecute(
            account,
            sessionKeyPrivKey,
            bytes(""),
            account,
            0,
            abi.encodeWithSignature("registerSessionKey(address,uint48,uint48)", sessionKeyAttack, 0, 2 ** 48 - 1)
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);
    }

    /*
     * Register a limited sessionKey via userOp calling the execute() function
     * using the EntryPoint (userOp). Then use that sessionKey to register a second one
     */
    function testFailAttackRegisterSessionKeyViaEntrypoint2ndKey() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        UserOperation[] memory userOp = _setupUserOpExecute(
            account,
            accountAdminPKey,
            bytes(""),
            account,
            0,
            abi.encodeWithSignature("registerSessionKey(address,uint48,uint48,uint48)", sessionKey, 0, 2 ** 48 - 1, 10)
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has not increased
        assertEq(testCounter.counters(account), 0);

        userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);

        // Verify that the registered key is not a MasterKey nor has whitelisting
        bool isMasterKey;
        bool isWhitelisted;
        (,,, isMasterKey, isWhitelisted) = StaticOpenfortAccount(payable(account)).sessionKeys(sessionKey);
        assert(!isMasterKey);
        assert(!isWhitelisted);

        address sessionKeyAttack;
        uint256 sessionKeyPrivKeyAttack;
        (sessionKeyAttack, sessionKeyPrivKeyAttack) = makeAddrAndKey("sessionKeyAttack");

        userOp = _setupUserOpExecute(
            account,
            sessionKeyPrivKey,
            bytes(""),
            account,
            0,
            abi.encodeWithSignature("registerSessionKey(address,uint48,uint48)", sessionKeyAttack, 0, 2 ** 48 - 1)
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);
    }

    /*
     *  Should fail, try to use a sessionKey that is expired.
     */
    function testIncrementCounterViaSessionKeyExpired() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        vm.warp(100);
        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 99);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        vm.expectRevert();
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has not increased
        assertEq(testCounter.counters(account), 0);
    }

    /*
     *  Should fail, try to use a sessionKey that is revoked.
     */
    function testFailIncrementCounterViaSessionKeyRevoked() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 0);
        StaticOpenfortAccount(payable(account)).revokeSessionKey(sessionKey);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);
    }

    /*
     *  Should fail, try to use a sessionKey that reached its limit.
     */
    function testFailIncrementCounterViaSessionKeyReachLimit() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        // We are now in block 100, but our session key is valid until block 150
        vm.warp(100);
        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 150, 1);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has only increased by one
        assertEq(testCounter.counters(account), 1);
    }

    /*
     *  Should fail, try to use a sessionKey that reached its limit.
     */
    function testFailIncrementCounterViaSessionKeyReachLimitBatching() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        // We are now in block 100, but our session key is valid until block 150
        vm.warp(100);
        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 150, 2);

        uint256 count = 3;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        for (uint256 i = 0; i < count; i += 1) {
            targets[i] = address(testCounter);
            values[i] = 0;
            callData[i] = abi.encodeWithSignature("count()");
        }

        UserOperation[] memory userOp =
            _setupUserOpExecuteBatch(account, sessionKeyPrivKey, bytes(""), targets, values, callData);

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has not increased
        assertEq(testCounter.counters(account), 0);
    }

    /*
     *  Should fail, try to revoke a sessionKey using a non-privileged user
     */
    function testFailRevokeSessionKeyInvalidUser() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 0);
        vm.prank(beneficiary);
        StaticOpenfortAccount(payable(account)).revokeSessionKey(sessionKey);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);
    }

    /*
     * Use a sessionKey with whitelisting to call Execute().
     */
    function testIncrementCounterViaSessionKeyWhitelisting() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        address[] memory whitelist = new address[](1);
        whitelist[0] = address(testCounter);
        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 2 ** 48 - 1, 1, whitelist);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);
    }

    /*
     * Should fail, try to register a sessionKey with a large whitelist.
     */
    function testFailIncrementCounterViaSessionKeyWhitelistingTooBig() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        address[] memory whitelist = new address[](11);
        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 2 ** 48 - 1, 1, whitelist);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has not increased
        assertEq(testCounter.counters(account), 0);
    }

    /*
     * Use a sessionKey with whitelisting to call ExecuteBatch().
     */
    function testIncrementCounterViaSessionKeyWhitelistingBatch() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        address[] memory whitelist = new address[](1);
        whitelist[0] = address(testCounter);
        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 2 ** 48 - 1, 3, whitelist);

        // Verify that the registered key is not a MasterKey but has whitelisting
        bool isMasterKey;
        bool isWhitelisted;
        (,,, isMasterKey, isWhitelisted) = StaticOpenfortAccount(payable(account)).sessionKeys(sessionKey);
        assert(!isMasterKey);
        assert(isWhitelisted);

        uint256 count = 3;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        for (uint256 i = 0; i < count; i += 1) {
            targets[i] = address(testCounter);
            values[i] = 0;
            callData[i] = abi.encodeWithSignature("count()");
        }

        UserOperation[] memory userOp =
            _setupUserOpExecuteBatch(account, sessionKeyPrivKey, bytes(""), targets, values, callData);

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 3);
    }

    /*
     * Use a sessionKey with whitelisting to call ExecuteBatch().
     */
    function testFailIncrementCounterViaSessionKeyWhitelistingBatch() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        address[] memory whitelist = new address[](1);
        whitelist[0] = address(testCounter);
        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 2 ** 48 - 1, 3, whitelist);

        // Verify that the registered key is not a MasterKey but has whitelisting
        bool isMasterKey;
        bool isWhitelisted;
        (,,, isMasterKey, isWhitelisted) = StaticOpenfortAccount(payable(account)).sessionKeys(sessionKey);
        assert(!isMasterKey);
        assert(isWhitelisted);

        uint256 count = 11;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        for (uint256 i = 0; i < count; i += 1) {
            targets[i] = address(testCounter);
            values[i] = 0;
            callData[i] = abi.encodeWithSignature("count()");
        }

        UserOperation[] memory userOp =
            _setupUserOpExecuteBatch(account, sessionKeyPrivKey, bytes(""), targets, values, callData);

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has not increased
        assertEq(testCounter.counters(account), 0);
    }

    /*
     * Should fail, try to use a sessionKey with invalid whitelisting to call Execute().
     */
    function testFailIncrementCounterViaSessionKeyWhitelistingWrongAddress() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        address[] memory whitelist = new address[](1);
        whitelist[0] = address(account);
        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 2 ** 48 - 1, 1, whitelist);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, sessionKeyPrivKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);
    }

    /*
     * Should fail, try to use a sessionKey with invalid whitelisting to call ExecuteBatch().
     */
    function testFailIncrementCounterViaSessionKeyWhitelistingBatchWrongAddress() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        address[] memory whitelist = new address[](1);
        whitelist[0] = address(account);
        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).registerSessionKey(sessionKey, 0, 2 ** 48 - 1, 1, whitelist);

        uint256 count = 3;
        address[] memory targets = new address[](count);
        uint256[] memory values = new uint256[](count);
        bytes[] memory callData = new bytes[](count);

        for (uint256 i = 0; i < count; i += 1) {
            targets[i] = address(testCounter);
            values[i] = 0;
            callData[i] = abi.encodeWithSignature("count()");
        }

        UserOperation[] memory userOp = _setupUserOpExecuteBatch(
            account,
            sessionKeyPrivKey, //Sign the userOp using the sessionKey's private key
            bytes(""),
            targets,
            values,
            callData
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has not increased
        assertEq(testCounter.counters(account), 0);
    }

    /*
     * Change the owner of an account and call TestCounter directly.
     * Important use-case:
     * 1- accountAdmin is Openfort's master wallet and is managing the account of the user.
     * 2- The user claims the ownership of the account to Openfort so Openfort calls
     * transferOwnership() to the account.
     * 3- The user has to "officially" claim the ownership of the account by directly
     * interacting with the smart contract using the acceptOwnership() function.
     * 4- From now on, the user is the owner of the account and can register and revoke session keys themselves.
     * 5- Test that the new owner can directly interact with the account and make it call the testCounter contract.
     */
    function testChangeOwnershipAndCountDirect() public {
        address accountAdmin2;
        uint256 accountAdmin2PKey;
        (accountAdmin2, accountAdmin2PKey) = makeAddrAndKey("accountAdmin2");

        vm.expectRevert("Ownable: caller is not the owner");
        StaticOpenfortAccount(payable(account)).transferOwnership(accountAdmin2);

        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).transferOwnership(accountAdmin2);
        vm.prank(accountAdmin2);
        StaticOpenfortAccount(payable(account)).acceptOwnership();

        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        // Make the admin of the static account wallet (deployer) call "count"
        vm.prank(accountAdmin2);
        StaticOpenfortAccount(payable(account)).execute(address(testCounter), 0, abi.encodeWithSignature("count()"));

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);
    }

    /*
     * Change the owner of an account and call TestCounter though the Entrypoint
     */
    function testChangeOwnershipAndCountEntryPoint() public {
        address accountAdmin2;
        uint256 accountAdmin2PKey;
        (accountAdmin2, accountAdmin2PKey) = makeAddrAndKey("accountAdmin2");

        vm.prank(accountAdmin);
        StaticOpenfortAccount(payable(account)).transferOwnership(accountAdmin2);
        vm.prank(accountAdmin2);
        StaticOpenfortAccount(payable(account)).acceptOwnership();

        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, accountAdmin2PKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the counter has increased
        assertEq(testCounter.counters(account), 1);
    }

    /*
     * Test an account with testToken instead of TestCount.
     */
    function testMintTokenAccount() public {
        // Verifiy that the totalSupply is stil 0
        assertEq(testToken.totalSupply(), 0);

        // Mint 1 to beneficiary
        testToken.mint(beneficiary, 1);
        assertEq(testToken.totalSupply(), 1);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account,
            accountAdminPKey,
            bytes(""),
            address(testToken),
            0,
            abi.encodeWithSignature("mint(address,uint256)", beneficiary, 1)
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);
        entryPoint.handleOps(userOp, beneficiary);

        // Verifiy that the totalSupply has increased
        assertEq(testToken.totalSupply(), 2);
    }

    /*
     * Test receive native tokens.
     */
    function testReceiveNativeToken() public {
        assertEq(address(account).balance, 0);

        vm.prank(accountAdmin);
        (bool success,) = payable(account).call{value: 1000}("");
        assert(success);
        assertEq(address(account).balance, 1000);
    }

    /*
     * Transfer native tokens out of an account.
     */
    function testTransferOutNativeToken() public {
        uint256 value = 1000;

        assertEq(address(account).balance, 0);
        vm.prank(accountAdmin);
        (bool success,) = payable(account).call{value: value}("");
        assertEq(address(account).balance, value);
        assert(success);
        assertEq(beneficiary.balance, 0);

        UserOperation[] memory userOp =
            _setupUserOpExecute(account, accountAdminPKey, bytes(""), address(beneficiary), value, bytes(""));

        EntryPoint(entryPoint).handleOps(userOp, beneficiary);
        assertEq(beneficiary.balance, value);
    }

    /*
     * Basic test of simulateValidation() to check that it always reverts.
     */
    function testSimulateValidation() public {
        // Verifiy that the counter is stil set to 0
        assertEq(testCounter.counters(account), 0);

        UserOperation[] memory userOp = _setupUserOpExecute(
            account, accountAdminPKey, bytes(""), address(testCounter), 0, abi.encodeWithSignature("count()")
        );

        entryPoint.depositTo{value: 1000000000000000000}(account);
        // Expect the simulateValidation() to always revert
        vm.expectRevert();
        entryPoint.simulateValidation(userOp[0]);

        // Verifiy that the counter has not increased
        assertEq(testCounter.counters(account), 0);
    }

    /*
     * 1- Deploy a factory using the old EntryPoint to create an account.
     * 2- Inform the account of the new EntryPoint by calling updateEntryPoint()
     */
    function testUpdateEntryPoint() public {
        address oldEntryPoint = address(0x0576a174D229E3cFA37253523E645A78A0C91B57);
        address newEntryPoint = vm.envAddress("ENTRY_POINT_ADDRESS");
        StaticOpenfortFactory staticOpenfortFactoryOld =
            new StaticOpenfortFactory(payable(oldEntryPoint), address(staticOpenfortAccount));

        // Create an static account wallet using the old EntryPoint and get its address
        address payable accountOld = payable(staticOpenfortFactoryOld.createAccountWithNonce(accountAdmin, "99"));
        StaticOpenfortAccount staticAccount = StaticOpenfortAccount(accountOld);
        assertEq(address(staticAccount.entryPoint()), oldEntryPoint);

        vm.expectRevert("Ownable: caller is not the owner");
        staticAccount.updateEntryPoint(newEntryPoint);

        vm.prank(accountAdmin);
        staticAccount.updateEntryPoint(newEntryPoint);

        assertEq(address(staticAccount.entryPoint()), newEntryPoint);
    }

    /*
     * 
     * 
     */
    function testRegularSignature() public {
        StaticOpenfortAccount openfortAccount = StaticOpenfortAccount(payable(account));

        // First regular hashing and signing using the EOA
        bytes memory text = "Signed by Openfort";
        bytes32 hash = keccak256(text);
        console.logBytes32(hash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(accountAdminPKey, hash);
        bytes memory signature = abi.encodePacked(r, s, v);
        console.logBytes(signature);
        bytes4 validSig = openfortAccount.isValidSignature(hash, signature);
        console.logBytes4(validSig);
        assert(validSig == 0x1626ba7e); // Should [PASS]. Regular signatures should work

        address signer = ecrecover(hash, v, r, s);
        assertEq(openfortAccount.owner(), signer); // Should [PASS]
        assertEq(accountAdmin, signer); // Should [PASS]
    }

    /*
     * 
     * 
     */
    function testEIP191Signature() public {
        StaticOpenfortAccount openfortAccount = StaticOpenfortAccount(payable(account));

        // Now using EIP-191. isValidSignature() should return the MAGIC VALUE too
        bytes memory text = "Signed by Openfort";
        bytes32 hash = keccak256(text);
        bytes32 hash191 = hash.toEthSignedMessageHash();
        console.logBytes32(hash191);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(accountAdminPKey, hash191);
        bytes memory signature191 = abi.encodePacked(r, s, v);
        console.logBytes(signature191);
        bytes4 validSig = openfortAccount.isValidSignature(hash, signature191);
        console.logBytes4(validSig);
        assert(validSig == 0x1626ba7e); // Should [PASS]. EIP-191 signatures should work too

        address signer = ecrecover(hash191, v, r, s);
        assertEq(openfortAccount.owner(), signer); // Should [PASS]
        assertEq(accountAdmin, signer); // Should [PASS]
    }

    /*
     * Test EIP712 Typed Signatures using isValidSignature's (EIP-1271)
     */
    function testEIP712Signature() public {
        StaticOpenfortAccount openfortAccount = StaticOpenfortAccount(payable(account));

        // Now using EIP-712. isValidSignature() should return the MAGIC VALUE too
        bytes32 hash = keccak256("Signed by Openfort");
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            openfortAccount.eip712Domain();
        console.log(name);
        bytes32 _TYPE_HASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 domainSeparator = keccak256(
            abi.encode(_TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
        );
        bytes32 hash712 = domainSeparator.toTypedDataHash(hash);

        console.logBytes32(hash712);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(accountAdminPKey, hash712);
        bytes memory signature721 = abi.encodePacked(r, s, v);

        console.logBytes(signature721);
        {
            bytes4 validSig = openfortAccount.isValidSignature(hash, signature721);
            console.logBytes4(validSig);
            assert(validSig == 0x1626ba7e); // Should [PASS]. EIP-712 typed signatures should work too
        }
        address signer = ecrecover(hash712, v, r, s);
        assertEq(openfortAccount.owner(), signer); // Should [PASS]
        assertEq(accountAdmin, signer); // Should [PASS]
    }

    /*
     * Test FAIL EIP712 Typed Signatures using isValidSignature's (EIP-1271)
     * Altered the ChainID
     */
    function testFailEIP712Signature() public {
        StaticOpenfortAccount openfortAccount = StaticOpenfortAccount(payable(account));

        // Now using EIP-712. isValidSignature() should return the MAGIC VALUE too
        bytes32 hash = keccak256("Signed by Openfort");
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            openfortAccount.eip712Domain();
        console.log(name);
        chainId = 9999;
        bytes32 _TYPE_HASH =
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
        bytes32 domainSeparator = keccak256(
            abi.encode(_TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
        );
        bytes32 hash712 = domainSeparator.toTypedDataHash(hash);

        console.logBytes32(hash712);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(accountAdminPKey, hash712);
        bytes memory signature721 = abi.encodePacked(r, s, v);

        console.logBytes(signature721);
        {
            bytes4 validSig = openfortAccount.isValidSignature(hash, signature721);
            console.logBytes4(validSig);
            assert(validSig == 0x1626ba7e); // Should [PASS]. EIP-712 typed signatures should work too
        }
        address signer = ecrecover(hash712, v, r, s);
        assertEq(openfortAccount.owner(), signer); // Should [PASS]
        assertEq(accountAdmin, signer); // Should [PASS]
    }

    /*
     * Test Session key Signatures using isValidSignature's (EIP-1271)
     */
    function testSessionKeySignature() public {
        StaticOpenfortAccount openfortAccount = StaticOpenfortAccount(payable(account));

        // Now using Session keys. isValidSignature() should return the MAGIC VALUE too
        bytes32 hash = keccak256("Signed by Openfort");

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        vm.warp(100);
        vm.prank(accountAdmin);
        openfortAccount.registerSessionKey(sessionKey, 0, 150);
        bytes32 domainSeparator;
        {
            (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
                openfortAccount.eip712Domain();
            console.log(name);
            bytes32 _TYPE_HASH =
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
            domainSeparator = keccak256(
                abi.encode(_TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
            );
        }
        bytes32 hash712 = domainSeparator.toTypedDataHash(hash);
        console.logBytes32(hash712);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionKeyPrivKey, hash712);
        bytes memory signature721 = abi.encodePacked(r, s, v);
        console.logBytes(signature721);
        bytes4 validSig = openfortAccount.isValidSignature(hash, signature721);
        console.logBytes4(validSig);
        assert(validSig == 0x1626ba7e); // Should [PASS]. EIP-712 typed signatures should work too
        address signer = ecrecover(hash712, v, r, s);
        assertEq(sessionKey, signer); // Should [PASS]
        assertNotEq(accountAdmin, signer); // Should [PASS]
    }

    /*
     * Test FAIL Session key Signatures using isValidSignature's (EIP-1271)
     * Session key has expired
     */
    function testFailSessionKeySignatureExpired() public {
        StaticOpenfortAccount openfortAccount = StaticOpenfortAccount(payable(account));

        // Now using Session keys. isValidSignature() should return the MAGIC VALUE too
        bytes32 hash = keccak256("Signed by Openfort");

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        // We are now at timestamp 100
        vm.warp(100);
        vm.prank(accountAdmin);
        openfortAccount.registerSessionKey(sessionKey, 0, 99); // register an expired session key
        bytes32 domainSeparator;
        {
            (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
                openfortAccount.eip712Domain();
            console.log(name);
            bytes32 _TYPE_HASH =
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
            domainSeparator = keccak256(
                abi.encode(_TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
            );
        }
        bytes32 hash712 = domainSeparator.toTypedDataHash(hash);
        console.logBytes32(hash712);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionKeyPrivKey, hash712);
        bytes memory signature721 = abi.encodePacked(r, s, v);
        console.logBytes(signature721);
        bytes4 validSig = openfortAccount.isValidSignature(hash, signature721);
        console.logBytes4(validSig);
        assert(validSig == 0x1626ba7e); // Should fail because the session key is expired
        address signer = ecrecover(hash712, v, r, s);
        assertEq(sessionKey, signer); // Should [PASS]
        assertNotEq(accountAdmin, signer); // Should [PASS]
    }

    /*
     * Test FAIL Session key Signatures using isValidSignature's (EIP-1271)
     * Session key is not valid yet
     */
    function testFailSessionKeySignatureNotYet() public {
        StaticOpenfortAccount openfortAccount = StaticOpenfortAccount(payable(account));

        // Now using Session keys. isValidSignature() should return the MAGIC VALUE too
        bytes32 hash = keccak256("Signed by Openfort");

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");

        // We are now at timestamp 100
        vm.warp(100);
        vm.prank(accountAdmin);
        openfortAccount.registerSessionKey(sessionKey, 150, 250); // register a session key that is not valid yet
        bytes32 domainSeparator;
        {
            (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
                openfortAccount.eip712Domain();
            console.log(name);
            bytes32 _TYPE_HASH =
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
            domainSeparator = keccak256(
                abi.encode(_TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
            );
        }
        bytes32 hash712 = domainSeparator.toTypedDataHash(hash);
        console.logBytes32(hash712);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionKeyPrivKey, hash712);
        bytes memory signature721 = abi.encodePacked(r, s, v);
        console.logBytes(signature721);
        bytes4 validSig = openfortAccount.isValidSignature(hash, signature721);
        console.logBytes4(validSig);
        assert(validSig == 0x1626ba7e); // Should fail because the session key is expired
        address signer = ecrecover(hash712, v, r, s);
        assertEq(sessionKey, signer); // Should [PASS]
        assertNotEq(accountAdmin, signer); // Should [PASS]
    }

    /*
     * Test FAIL Session key Signatures using isValidSignature's (EIP-1271)
     * Session key is not a valid one. Using a wrong session key
     */
    function testFailSessionKeySignatureInvalid() public {
        StaticOpenfortAccount openfortAccount = StaticOpenfortAccount(payable(account));

        // Now using Session keys. isValidSignature() should return the MAGIC VALUE too
        bytes32 hash = keccak256("Signed by Openfort");

        address sessionKey;
        uint256 sessionKeyPrivKey;
        (sessionKey, sessionKeyPrivKey) = makeAddrAndKey("sessionKey");
        address sessionKey2;
        uint256 sessionKeyPrivKey2;
        (sessionKey2, sessionKeyPrivKey2) = makeAddrAndKey("sessionKey2");

        // We are now at timestamp 100
        vm.warp(100);
        vm.prank(accountAdmin);
        openfortAccount.registerSessionKey(sessionKey, 150, 250); // register a session key that is not valid yet
        bytes32 domainSeparator;
        {
            (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
                openfortAccount.eip712Domain();
            console.log(name);
            bytes32 _TYPE_HASH =
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
            domainSeparator = keccak256(
                abi.encode(_TYPE_HASH, keccak256(bytes(name)), keccak256(bytes(version)), chainId, verifyingContract)
            );
        }
        bytes32 hash712 = domainSeparator.toTypedDataHash(hash);
        console.logBytes32(hash712);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(sessionKeyPrivKey2, hash712);
        bytes memory signature721 = abi.encodePacked(r, s, v);
        console.logBytes(signature721);
        bytes4 validSig = openfortAccount.isValidSignature(hash, signature721);
        console.logBytes4(validSig);
        assert(validSig == 0x1626ba7e); // Should fail because the session key is expired
        address signer = ecrecover(hash712, v, r, s);
        assertEq(sessionKey, signer); // Should [PASS]
        assertNotEq(accountAdmin, signer); // Should [PASS]
    }

    /*
     * Test a complex type using EIP712 Typed Signatures using isValidSignature's (EIP-1271)
     */
    function testComplextypeEIP712Signature() public {
        assertEq(true, true); // ToDo
    }
}
