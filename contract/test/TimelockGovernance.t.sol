// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

import "../src/AdaptiveLPVault.sol";
import "./mocks/MockERC20.sol";

contract TimelockGovernanceTest is Test {
    uint256 internal constant TIMELOCK_DELAY = 2 days;

    AdaptiveLPVault public vault;
    TimelockController public timelock;

    address public multisig = makeAddr("multisig");
    address public executor = makeAddr("executor");

    function setUp() public {
        MockERC20 token0 = new MockERC20("Token 0", "T0", 18);
        MockERC20 token1 = new MockERC20("Token 1", "T1", 6);

        vault = new AdaptiveLPVault(
            "Adaptive LP Vault",
            "ALPV",
            address(token0),
            address(token1),
            18, 6
        );

        address[] memory proposers = new address[](1);
        proposers[0] = multisig;
        address[] memory executors = new address[](1);
        // Open execution only permits execution of elapsed, pre-scheduled operations.
        executors[0] = address(0);
        timelock = new TimelockController(TIMELOCK_DELAY, proposers, executors, address(0));
    }

    function _schedule(address target, bytes memory data, bytes32 salt) internal {
        vm.prank(multisig);
        timelock.schedule(target, 0, data, bytes32(0), salt, TIMELOCK_DELAY);
    }

    function _execute(address target, bytes memory data, bytes32 salt) internal {
        vm.prank(executor);
        timelock.execute(target, 0, data, bytes32(0), salt);
    }

    function test_Timelock_DelaysVaultConfiguration() public {
        // Transfer starts the Ownable2Step handover but does not change vault.owner yet.
        vault.transferOwnership(address(timelock));
        bytes memory acceptOwnershipData = abi.encodeCall(vault.acceptOwnership, ());
        bytes32 acceptSalt = keccak256("accept-vault-ownership");

        _schedule(address(vault), acceptOwnershipData, acceptSalt);
        bytes32 acceptOperationId = timelock.hashOperation(
            address(vault), 0, acceptOwnershipData, bytes32(0), acceptSalt
        );

        // The timelock cannot accept ownership before its delay expires.
        vm.expectRevert();
        _execute(address(vault), acceptOwnershipData, acceptSalt);
        vm.warp(timelock.getTimestamp(acceptOperationId));
        _execute(address(vault), acceptOwnershipData, acceptSalt);

        assertEq(vault.owner(), address(timelock));
        assertEq(vault.pendingOwner(), address(0));

        // The old owner no longer has direct configuration power.
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        vault.setMinIdleBufferBps(2000);

        bytes memory setBufferData = abi.encodeCall(vault.setMinIdleBufferBps, (2000));
        bytes32 setBufferSalt = keccak256("set-idle-buffer");
        _schedule(address(vault), setBufferData, setBufferSalt);
        bytes32 setBufferOperationId = timelock.hashOperation(address(vault), 0, setBufferData, bytes32(0), setBufferSalt);

        // Scheduling does not make the operation executable immediately.
        vm.expectRevert();
        _execute(address(vault), setBufferData, setBufferSalt);
        vm.warp(timelock.getTimestamp(setBufferOperationId));
        _execute(address(vault), setBufferData, setBufferSalt);

        assertEq(vault.minIdleBufferBps(), 2000);
    }
}
