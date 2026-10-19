// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDPotToken} from "../src/IMDPotToken.sol";
import {DeployIMDPot} from "../script/Deploy.s.sol";

contract IMDPotTokenTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 constant SUPPLY = 1_000_000_000 ether;

    IMDPotToken token;
    address deployer = address(0xFAC7);
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        vm.prank(deployer);
        token = new IMDPotToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "IMDPot");
        assertEq(token.symbol(), "IMDPOT");
        assertEq(token.decimals(), 18);
        assertEq(token.TOTAL_SUPPLY(), SUPPLY);
    }

    function test_constructorMintsWholeSupplyToDeployer() public {
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);

        vm.expectEmit(true, true, false, true);
        emit Transfer(address(0), alice, SUPPLY);
        vm.prank(alice);
        IMDPotToken fresh = new IMDPotToken();
        assertEq(fresh.balanceOf(alice), SUPPLY);
    }

    function test_deployScriptDeploysToken() public {
        DeployIMDPot script = new DeployIMDPot();
        IMDPotToken deployed = script.deploy();
        assertEq(deployed.totalSupply(), SUPPLY);
        assertEq(deployed.balanceOf(address(script)), SUPPLY);
    }

    function test_transfer() public {
        vm.expectEmit(true, true, false, true);
        emit Transfer(deployer, alice, 100);
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 100));
        assertEq(token.balanceOf(alice), 100);
        assertEq(token.balanceOf(deployer), SUPPLY - 100);
    }

    function test_transferToSelfKeepsBalance() public {
        vm.prank(deployer);
        token.transfer(deployer, 5);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function test_transferZeroAmount() public {
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));
        assertEq(token.balanceOf(bob), 0);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        vm.expectRevert(abi.encodeWithSelector(IMDPotToken.ERC20InsufficientBalance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transfer(bob, 1);
    }

    function test_RevertWhen_transferToZeroAddress() public {
        vm.expectRevert(abi.encodeWithSelector(IMDPotToken.ERC20InvalidReceiver.selector, address(0)));
        vm.prank(deployer);
        token.transfer(address(0), 1);
    }

    function test_approveAndTransferFrom() public {
        vm.expectEmit(true, true, false, true);
        emit Approval(deployer, alice, 50);
        vm.prank(deployer);
        assertTrue(token.approve(alice, 50));
        assertEq(token.allowance(deployer, alice), 50);

        vm.prank(alice);
        assertTrue(token.transferFrom(deployer, bob, 30));
        assertEq(token.balanceOf(bob), 30);
        assertEq(token.allowance(deployer, alice), 20);
    }

    function test_unlimitedAllowanceIsNotDecreased() public {
        vm.prank(deployer);
        token.approve(alice, type(uint256).max);
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1000);
        assertEq(token.allowance(deployer, alice), type(uint256).max);
        assertEq(token.balanceOf(bob), 1000);
    }

    function test_RevertWhen_transferFromExceedsAllowance() public {
        vm.prank(deployer);
        token.approve(alice, 10);
        vm.expectRevert(abi.encodeWithSelector(IMDPotToken.ERC20InsufficientAllowance.selector, alice, 10, 11));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 11);
    }

    function test_RevertWhen_transferFromWithoutApproval() public {
        vm.expectRevert(abi.encodeWithSelector(IMDPotToken.ERC20InsufficientAllowance.selector, alice, 0, 1));
        vm.prank(alice);
        token.transferFrom(deployer, bob, 1);
    }

    function test_RevertWhen_transferFromExceedsBalance() public {
        vm.prank(alice);
        token.approve(bob, 100);
        vm.expectRevert(abi.encodeWithSelector(IMDPotToken.ERC20InsufficientBalance.selector, alice, 0, 100));
        vm.prank(bob);
        token.transferFrom(alice, bob, 100);
    }

    function test_RevertWhen_approveZeroSpender() public {
        vm.expectRevert(abi.encodeWithSelector(IMDPotToken.ERC20InvalidSpender.selector, address(0)));
        vm.prank(deployer);
        token.approve(address(0), 1);
    }

    /// @dev No admin surface: common mint/owner/pause selectors do not exist and cannot grow supply.
    function test_noAdminFunctions() public {
        bytes[5] memory calls = [
            abi.encodeWithSignature("mint(address,uint256)", alice, 1),
            abi.encodeWithSignature("owner()"),
            abi.encodeWithSignature("pause()"),
            abi.encodeWithSignature("burn(uint256)", 1),
            abi.encodeWithSignature("transferOwnership(address)", alice)
        ];
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(calls[i]);
            assertFalse(ok);
        }
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(deployer), SUPPLY);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer), SUPPLY - amount);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_transferFromRespectsAllowance(uint256 allowed, uint256 amount) public {
        allowed = bound(allowed, 0, SUPPLY);
        amount = bound(amount, 0, SUPPLY);
        vm.prank(deployer);
        token.approve(alice, allowed);
        vm.prank(alice);
        if (amount > allowed) {
            vm.expectRevert(
                abi.encodeWithSelector(IMDPotToken.ERC20InsufficientAllowance.selector, alice, allowed, amount)
            );
            token.transferFrom(deployer, bob, amount);
        } else {
            token.transferFrom(deployer, bob, amount);
            assertEq(token.balanceOf(bob), amount);
            assertEq(token.allowance(deployer, alice), allowed - amount);
        }
        assertEq(token.balanceOf(deployer) + token.balanceOf(bob), SUPPLY);
    }
}
