/*
 * Copyright 2024 Circle Internet Group, Inc. All rights reserved.

 * SPDX-License-Identifier: GPL-3.0-or-later

 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.

 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.

 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */
pragma solidity 0.8.24;

/* solhint-disable max-states-count */
import {BaseMSCA} from "../../../../../src/msca/6900/v0.8/account/BaseMSCA.sol";

import {
    ExecutionDataView, ValidationDataView
} from "@erc6900/reference-implementation/interfaces/IModularAccountView.sol";

import {IModularAccount} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {
    ModuleEntity,
    ValidationConfig,
    ValidationFlags
} from "@erc6900/reference-implementation/interfaces/IModularAccount.sol";
import {ModuleEntityLib} from "@erc6900/reference-implementation/libraries/ModuleEntityLib.sol";

import {ValidationConfigLib} from "@erc6900/reference-implementation/libraries/ValidationConfigLib.sol";

import {SingleSignerValidationModule} from
    "../../../../../src/msca/6900/v0.8/modules/validation/SingleSignerValidationModule.sol";
import {TestLiquidityPool} from "../../../../util/TestLiquidityPool.sol";
import {AccountTestUtils} from "../utils/AccountTestUtils.sol";
import {EntryPoint} from "@account-abstraction/contracts/core/EntryPoint.sol";
import {IEntryPoint} from "@account-abstraction/contracts/interfaces/IEntryPoint.sol";

import {UpgradableMSCA} from "../../../../../src/msca/6900/v0.8/account/UpgradableMSCA.sol";
import {UpgradableMSCAFactory} from "../../../../../src/msca/6900/v0.8/factories/UpgradableMSCAFactory.sol";

import {EIP1271_INVALID_SIGNATURE, EIP1271_VALID_SIGNATURE} from "../../../../../src/common/Constants.sol";
import {PackedUserOperation} from "@account-abstraction/contracts/interfaces/PackedUserOperation.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IAccount} from "@account-abstraction/contracts/interfaces/IAccount.sol";
import {IAccountExecute} from "@account-abstraction/contracts/interfaces/IAccountExecute.sol";
import {IModularAccountView} from "@erc6900/reference-implementation/interfaces/IModularAccountView.sol";
import {IERC1271} from "@openzeppelin/contracts/interfaces/IERC1271.sol";
import {IERC777Recipient} from "@openzeppelin/contracts/interfaces/IERC777Recipient.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import {console} from "forge-std/src/console.sol";

contract SingleSignerValidationModuleTest is AccountTestUtils {
    using ModuleEntityLib for bytes21;
    using ModuleEntityLib for ModuleEntity;
    using ValidationConfigLib for ValidationFlags;

    // upgrade
    event Upgraded(address indexed newImplementation);
    // 4337
    event UserOperationEvent(
        bytes32 indexed userOpHash,
        address indexed sender,
        address indexed paymaster,
        uint256 nonce,
        bool success,
        uint256 actualGasCost,
        uint256 actualGasUsed
    );

    event SignerTransferred(
        address indexed account, uint32 indexed entityId, address indexed newSigner, address previousSigner
    );

    error FailedOpWithRevert(uint256 opIndex, string reason, bytes inner);

    IEntryPoint private entryPoint = new EntryPoint();
    uint256 internal eoaPrivateKey1;
    uint256 internal eoaPrivateKey2;
    address private signerAddr1;
    address private signerAddr2;
    address payable private beneficiary; // e.g. bundler
    UpgradableMSCAFactory private factory;
    SingleSignerValidationModule private singleSignerValidationModule;
    UpgradableMSCA private msca1;
    UpgradableMSCA private msca2;
    TestLiquidityPool private testLiquidityPool;
    address private singleSignerValidationModuleAddr;
    address private mscaAddr1;
    address private mscaAddr2;
    address private factorySigner;
    ModuleEntity private signerValidation;

    function setUp() public {
        factorySigner = makeAddr("factorySigner");
        beneficiary = payable(address(makeAddr("bundler")));
        factory = new UpgradableMSCAFactory(factorySigner, address(entryPoint));
        singleSignerValidationModule = new SingleSignerValidationModule();

        address[] memory _modules = new address[](1);
        _modules[0] = address(singleSignerValidationModule);
        bool[] memory _permissions = new bool[](1);
        _permissions[0] = true;
        vm.startPrank(factorySigner);
        factory.setModules(_modules, _permissions);
        vm.stopPrank();

        signerValidation = ModuleEntityLib.pack(address(singleSignerValidationModule), uint32(0));
        (signerAddr1, eoaPrivateKey1) = makeAddrAndKey("Circle_Single_Signer_Validation_Module_V1_Test1");
        (signerAddr2, eoaPrivateKey2) = makeAddrAndKey("Circle_Single_Signer_Validation_Module_V1_Test2");
        bytes32 salt = 0x0000000000000000000000000000000000000000000000000000000000000000;
        ValidationConfig validationConfig = ValidationConfigLib.pack(signerValidation, true, true, true);
        bytes memory initializingData =
            abi.encode(validationConfig, new bytes4[](0), abi.encode(uint32(0), signerAddr1), bytes(""));
        vm.startPrank(signerAddr1);
        msca1 = factory.createAccountWithValidation(addressToBytes32(signerAddr1), salt, initializingData);
        vm.stopPrank();
        vm.startPrank(signerAddr2);
        initializingData = abi.encode(validationConfig, new bytes4[](0), abi.encode(uint32(0), signerAddr2), bytes(""));
        msca2 = factory.createAccountWithValidation(addressToBytes32(signerAddr2), salt, initializingData);
        vm.stopPrank();
        console.logString("Circle_Single_Signer_Validation_Module_V1 address:");
        console.logAddress(address(singleSignerValidationModule));
        singleSignerValidationModuleAddr = address(singleSignerValidationModule);
        mscaAddr1 = address(msca1);
        mscaAddr2 = address(msca2);
        testLiquidityPool = new TestLiquidityPool("getrich", "$$$");
    }

    /// SingleSignerValidationModule is installed in setUp function, this test is just verifying details
    function testSingleSignerValidationModuleDetailsInstalledDuringAccountDeployment() public view {
        address sender = address(msca1);
        // deployment was done in setUp
        assertTrue(sender.code.length != 0);
        // verify the module has been installed
        ValidationDataView memory validationData = msca1.getValidationData(signerValidation);
        assertEq(validationData.selectors.length, 0);
        assertEq(validationData.validationHooks.length, 0);
        assertEq(validationData.executionHooks.length, 0);
        assertEq(validationData.validationFlags.isGlobal(), true);
        assertEq(validationData.validationFlags.isSignatureValidation(), true);
        // verify executionDetail
        ExecutionDataView memory executionData =
            msca1.getExecutionData(singleSignerValidationModule.transferSigner.selector);
        assertEq(executionData.module, address(0));
        assertEq(executionData.skipRuntimeValidation, false);
        assertEq(executionData.allowGlobalValidation, false);
        assertEq(executionData.executionHooks.length, 0);

        // native execute functions
        _verifyNativeExecutionFunction(IModularAccount.execute.selector);
        _verifyNativeExecutionFunction(IModularAccount.executeBatch.selector);
        _verifyNativeExecutionFunction(IModularAccount.installExecution.selector);
        _verifyNativeExecutionFunction(IModularAccount.uninstallExecution.selector);
        _verifyNativeExecutionFunction(UUPSUpgradeable.upgradeToAndCall.selector);
        _verifyNativeExecutionFunction(IModularAccount.installValidation.selector);
        _verifyNativeExecutionFunction(IModularAccount.uninstallValidation.selector);
        _verifyNativeExecutionFunction(IAccountExecute.executeUserOp.selector);
        _verifyNativeExecutionFunction(IModularAccount.executeWithRuntimeValidation.selector);

        // native view functions
        _verifyNativeViewFunction(BaseMSCA.entryPoint.selector);
        _verifyNativeViewFunction(IModularAccount.accountId.selector);
        _verifyNativeViewFunction(UUPSUpgradeable.proxiableUUID.selector);
        _verifyNativeViewFunction(IModularAccountView.getExecutionData.selector);
        _verifyNativeViewFunction(IModularAccountView.getValidationData.selector);
        _verifyNativeViewFunction(IAccount.validateUserOp.selector);
        _verifyNativeViewFunction(IERC165.supportsInterface.selector);
        _verifyNativeViewFunction(IERC1271.isValidSignature.selector);
        _verifyNativeViewFunction(IERC1155Receiver.onERC1155BatchReceived.selector);
        _verifyNativeViewFunction(IERC1155Receiver.onERC1155Received.selector);
        _verifyNativeViewFunction(IERC721Receiver.onERC721Received.selector);
        _verifyNativeViewFunction(IERC777Recipient.tokensReceived.selector);

        assertEq(singleSignerValidationModule.moduleId(), "circle.single-signer-validation-module.1.0.0");
    }

    function _verifyNativeViewFunction(bytes4 selector) internal view {
        ExecutionDataView memory executionData = msca1.getExecutionData(selector);
        assertEq(executionData.module, address(msca1));
        assertEq(executionData.skipRuntimeValidation, true);
        assertEq(executionData.allowGlobalValidation, false);
    }

    function _verifyNativeExecutionFunction(bytes4 selector) internal view {
        ExecutionDataView memory executionData = msca1.getExecutionData(selector);
        assertEq(executionData.module, address(msca1));
        assertEq(executionData.skipRuntimeValidation, false);
        assertEq(executionData.allowGlobalValidation, true);
        assertEq(executionData.executionHooks.length, 0);
    }

    /// fail because transferSigner was not installed in validation module
    function testTransferSignerWhenFunctionUninstalled() public {
        address sender = address(msca1);
        // it should start with the deployed signerAddr
        assertEq(singleSignerValidationModule.signers(uint32(0), mscaAddr1), signerAddr1);
        // could be any address, I'm using UpgradableMSCA for simplicity
        UpgradableMSCA newSigner = new UpgradableMSCA(entryPoint);
        // deployment was done in setUp
        assertTrue(sender.code.length != 0);
        // nonce key is 0
        uint256 acctNonce = entryPoint.getNonce(sender, 0);
        // start with balance
        vm.deal(sender, 10 ether);
        bytes memory transferSignerCallData =
            abi.encodeCall(singleSignerValidationModule.transferSigner, (uint32(0), address(newSigner)));
        bytes memory initCode = "";
        PackedUserOperation memory userOp = buildPartialUserOp(
            sender,
            acctNonce,
            vm.toString(initCode),
            vm.toString(transferSignerCallData),
            10053353,
            103353,
            45484,
            516219199704,
            1130000000,
            "0x"
        ); // no paymaster

        // eoaPrivateKey from singleSignerValidationModule
        bytes memory signature = signUserOpHash(entryPoint, vm, eoaPrivateKey1, userOp);
        userOp.signature = encodeSignature(new PreValidationHookData[](0), signerValidation, signature, true);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.startPrank(address(entryPoint));
        vm.expectRevert(
            abi.encodeWithSelector(
                FailedOpWithRevert.selector,
                0,
                "AA23 reverted",
                abi.encodeWithSelector(
                    BaseMSCA.InvalidValidationFunction.selector,
                    singleSignerValidationModule.transferSigner.selector,
                    signerValidation
                )
            )
        );
        entryPoint.handleOps(ops, beneficiary);
        // won't change
        assertEq(singleSignerValidationModule.signers(uint32(0), mscaAddr1), address(signerAddr1));
        vm.stopPrank();
    }

    /// we need to handle guarded functions like transferSigner through the execute/executeBatch workflows
    function testTransferSignerViaExecuteFunction() public {
        address sender = address(msca2);
        // it should start with the deployed signerAddr
        assertEq(singleSignerValidationModule.signers(uint32(0), mscaAddr2), signerAddr2);
        // could be any address, I'm using UpgradableMSCA for simplicity
        UpgradableMSCA newSigner = new UpgradableMSCA(entryPoint);
        // deployment was done in setUp
        assertTrue(sender.code.length != 0);
        // nonce key is 0
        uint256 acctNonce = entryPoint.getNonce(sender, 0);
        // start with balance
        vm.deal(sender, 10 ether);
        bytes memory transferSignerCallData =
            abi.encodeCall(singleSignerValidationModule.transferSigner, (uint32(0), address(newSigner)));
        bytes memory executeCallData =
            abi.encodeCall(IModularAccount.execute, (address(singleSignerValidationModule), 0, transferSignerCallData));
        bytes memory initCode = "";
        PackedUserOperation memory userOp = buildPartialUserOp(
            sender,
            acctNonce,
            vm.toString(initCode),
            vm.toString(executeCallData),
            10053353,
            103353,
            45484,
            516219199704,
            1130000000,
            "0x"
        ); // no paymaster

        bytes32 userOpHash = entryPoint.getUserOpHash(userOp);
        // eoaPrivateKey from singleSignerValidationModule
        bytes memory signature = signUserOpHash(entryPoint, vm, eoaPrivateKey2, userOp);
        // global validation enabled
        userOp.signature = encodeSignature(new PreValidationHookData[](0), signerValidation, signature, true);
        PackedUserOperation[] memory ops = new PackedUserOperation[](1);
        ops[0] = userOp;
        vm.expectEmit(true, true, true, true);
        emit SignerTransferred(mscaAddr2, uint32(0), address(newSigner), signerAddr2);
        vm.expectEmit(true, true, true, false);
        emit UserOperationEvent(userOpHash, sender, address(0), acctNonce, true, 179020250000000, 158425);
        vm.startPrank(address(entryPoint));
        entryPoint.handleOps(ops, beneficiary);
        // now it's the new signer
        assertEq(singleSignerValidationModule.signers(uint32(0), mscaAddr2), address(newSigner));
        vm.stopPrank();
    }

    function testTransferSignerViaRuntime() public {
        // it should start with the deployed signerAddr
        assertEq(singleSignerValidationModule.signers(uint32(0), mscaAddr2), signerAddr2);
        // could be any address, I'm using UpgradableMSCA for simplicity
        UpgradableMSCA newSigner = new UpgradableMSCA(entryPoint);
        // deployment was done in setUp
        assertTrue(mscaAddr2.code.length != 0);
        // start with balance
        vm.deal(mscaAddr2, 10 ether);
        bytes memory transferSignerCallData =
            abi.encodeCall(singleSignerValidationModule.transferSigner, (uint32(0), address(newSigner)));
        bytes memory executeCallData =
            abi.encodeCall(IModularAccount.execute, (address(singleSignerValidationModule), 0, transferSignerCallData));

        vm.startPrank(mscaAddr2);
        vm.expectEmit(true, true, true, true);
        emit SignerTransferred(mscaAddr2, uint32(0), address(newSigner), signerAddr2);
        msca2.executeWithRuntimeValidation(
            executeCallData, encodeSignature(new PreValidationHookData[](0), signerValidation, bytes(""), true)
        );
        // now it's the new signer
        assertEq(singleSignerValidationModule.signers(uint32(0), mscaAddr2), address(newSigner));
        vm.stopPrank();
    }

    /// you can find more negative test cases in UpgradableMSCATest
    function testValidateSignature() public view {
        // it should start with the deployed signerAddr
        assertEq(singleSignerValidationModule.signers(uint32(0), mscaAddr2), signerAddr2);
        // deployment was done in setUp
        assertTrue(mscaAddr2.code.length != 0);
        // raw message hash
        bytes memory rawMessage = abi.encodePacked("circle internet");
        bytes32 messageHash = keccak256(rawMessage);
        bytes32 replaySafeMessageHash = singleSignerValidationModule.getReplaySafeMessageHash(mscaAddr2, messageHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(eoaPrivateKey2, replaySafeMessageHash);
        bytes memory signature =
            encode1271Signature(new PreValidationHookData[](0), signerValidation, abi.encodePacked(r, s, v));
        assertEq(msca2.isValidSignature(messageHash, signature), bytes4(EIP1271_VALID_SIGNATURE));

        // invalid signature
        signature =
            encode1271Signature(new PreValidationHookData[](0), signerValidation, abi.encodePacked(r, s, uint32(0)));
        assertEq(msca2.isValidSignature(messageHash, signature), bytes4(EIP1271_INVALID_SIGNATURE));
    }

    // they are also tested during signature signing
    function testFuzz_relaySafeMessageHash(bytes32 hash) public view {
        address account = address(msca1);
        bytes32 replaySafeHash = singleSignerValidationModule.getReplaySafeMessageHash(account, hash);
        bytes32 expected = MessageHashUtils.toTypedDataHash({
            domainSeparator: keccak256(
                abi.encode(
                    keccak256(
                        "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract,bytes32 salt)"
                    ),
                    keccak256(abi.encodePacked("circle.single-signer-validation-module.1.0.0")),
                    keccak256(abi.encodePacked("1.0.0")),
                    block.chainid,
                    address(singleSignerValidationModule),
                    bytes32(bytes20(account))
                )
            ),
            structHash: keccak256(abi.encode(keccak256("SingleSignerValidationMessage(bytes message)"), hash))
        });
        assertEq(replaySafeHash, expected);
    }
}
