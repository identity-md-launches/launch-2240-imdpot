// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDPotToken} from "src/IMDPotToken.sol";

/// @notice Edge cases and algebraic properties complementing the original deployment tests.
/// forge-config: default.fuzz.runs = 1000
contract IMDPotTokenPropertiesTest is Test {
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    IMDPotToken internal token;
    address internal deployer;
    address internal alice;
    address internal bob;
    address internal spender;

    function setUp() public {
        deployer = makeAddr("deployer");
        alice = makeAddr("alice");
        bob = makeAddr("bob");
        spender = makeAddr("spender");
        vm.prank(deployer);
        token = new IMDPotToken();
    }

    function test_zeroTransfersEmitEventsWithoutChangingState() public {
        bytes32 beforeState = _stateDigest();
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(alice);
        assertTrue(token.transfer(bob, 0));

        // ERC-20 zero transfers must also work without a balance or an allowance.
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(alice, bob, 0);
        vm.prank(spender);
        assertTrue(token.transferFrom(alice, bob, 0));
        assertEq(_stateDigest(), beforeState);
    }

    function test_oneWeiAndEntireSupplyCanMakeARoundTrip() public {
        bytes32 initial = _stateDigest();
        vm.prank(deployer);
        assertTrue(token.transfer(alice, 1));
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
        vm.prank(alice);
        assertTrue(token.transfer(deployer, 1));
        assertEq(_stateDigest(), initial);

        vm.prank(deployer);
        assertTrue(token.transfer(alice, SUPPLY));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY);
        _rejectUnchanged(
            deployer,
            abi.encodeCall(token.transfer, (bob, 1)),
            abi.encodeWithSelector(IMDPotToken.ERC20InsufficientBalance.selector, deployer, 0, 1)
        );
        vm.prank(alice);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(_stateDigest(), initial);
    }

    function test_selfTransfersPreserveBalanceButDelegatedTransferConsumesAllowance() public {
        bytes32 initial = _stateDigest();
        vm.prank(deployer);
        assertTrue(token.transfer(deployer, SUPPLY));
        assertEq(_stateDigest(), initial);

        vm.prank(deployer);
        assertTrue(token.approve(spender, SUPPLY));
        vm.expectEmit(true, true, false, true, address(token));
        emit Transfer(deployer, deployer, SUPPLY);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, SUPPLY));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(_stateDigest(), initial);

        _rejectUnchanged(
            deployer,
            abi.encodeCall(token.transfer, (deployer, SUPPLY + 1)),
            abi.encodeWithSelector(IMDPotToken.ERC20InsufficientBalance.selector, deployer, SUPPLY, SUPPLY + 1)
        );
    }

    function test_finiteAllowanceCanBeExhaustedButNotReplayed() public {
        vm.prank(deployer);
        token.approve(spender, 3);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, spender), 2);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 2));
        assertEq(token.allowance(deployer, spender), 0);
        assertEq(token.balanceOf(alice), 3);
        assertEq(token.balanceOf(deployer), SUPPLY - 3);
        _rejectUnchanged(
            spender,
            abi.encodeCall(token.transferFrom, (deployer, alice, 1)),
            abi.encodeWithSelector(IMDPotToken.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
    }

    function test_unlimitedAllowanceCanBeReplacedAndRevoked() public {
        vm.prank(deployer);
        token.approve(spender, type(uint256).max);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, spender), type(uint256).max);

        vm.prank(deployer);
        assertTrue(token.approve(spender, 7));
        assertEq(token.allowance(deployer, spender), 7);
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(deployer, spender, 0);
        vm.prank(deployer);
        assertTrue(token.approve(spender, 0));
        assertEq(token.allowance(deployer, spender), 0);
        _rejectUnchanged(
            spender,
            abi.encodeCall(token.transferFrom, (deployer, bob, 1)),
            abi.encodeWithSelector(IMDPotToken.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
    }

    function test_allowanceBelongsToTheSpecificOwnerAndSpender() public {
        vm.prank(deployer);
        token.approve(spender, SUPPLY);
        vm.prank(deployer);
        token.transfer(alice, 10);

        _rejectUnchanged(
            bob,
            abi.encodeCall(token.transferFrom, (deployer, bob, 1)),
            abi.encodeWithSelector(IMDPotToken.ERC20InsufficientAllowance.selector, bob, 0, 1)
        );
        _rejectUnchanged(
            spender,
            abi.encodeCall(token.transferFrom, (alice, bob, 1)),
            abi.encodeWithSelector(IMDPotToken.ERC20InsufficientAllowance.selector, spender, 0, 1)
        );
    }

    function test_zeroAddressesRejectZeroOneAndFullSupplyWithoutChangingState() public {
        vm.prank(deployer);
        token.approve(spender, SUPPLY);
        uint256[3] memory amounts = [uint256(0), 1, SUPPLY];
        for (uint256 i; i < amounts.length; ++i) {
            bytes memory receiverError = abi.encodeWithSelector(IMDPotToken.ERC20InvalidReceiver.selector, address(0));
            _rejectUnchanged(deployer, abi.encodeCall(token.transfer, (address(0), amounts[i])), receiverError);
            // transferFrom debits the finite allowance before validating the receiver;
            // a revert must roll that debit back as well as preserve every balance.
            _rejectUnchanged(
                spender, abi.encodeCall(token.transferFrom, (deployer, address(0), amounts[i])), receiverError
            );
            _rejectUnchanged(
                deployer,
                abi.encodeCall(token.approve, (address(0), amounts[i])),
                abi.encodeWithSelector(IMDPotToken.ERC20InvalidSpender.selector, address(0))
            );
        }
    }

    function test_maximumTransferFailsEvenWithUnlimitedApproval() public {
        uint256 maximum = type(uint256).max;
        vm.prank(deployer);
        token.approve(spender, maximum);
        bytes memory expected =
            abi.encodeWithSelector(IMDPotToken.ERC20InsufficientBalance.selector, deployer, SUPPLY, maximum);
        _rejectUnchanged(deployer, abi.encodeCall(token.transfer, (alice, maximum)), expected);
        _rejectUnchanged(spender, abi.encodeCall(token.transferFrom, (deployer, alice, maximum)), expected);
    }

    function test_maximumMinusOneIsAFiniteAllowance() public {
        uint256 allowed = type(uint256).max - 1;
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, 1));
        assertEq(token.allowance(deployer, spender), allowed - 1);
        assertEq(token.balanceOf(alice), 1);
        assertEq(token.balanceOf(deployer), SUPPLY - 1);
    }

    function test_spenderCanBeTheRecipientOrTheOwner() public {
        vm.prank(deployer);
        token.approve(spender, 1);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, spender, 1));
        assertEq(token.balanceOf(spender), 1);
        assertEq(token.allowance(deployer, spender), 0);

        vm.prank(deployer);
        token.approve(deployer, SUPPLY - 1);
        vm.prank(deployer);
        assertTrue(token.transferFrom(deployer, alice, SUPPLY - 1));
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.balanceOf(alice), SUPPLY - 1);
        assertEq(token.allowance(deployer, deployer), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function test_contractRecipientsNeedNoReceiverCallback() public {
        // This test contract and the token itself have no token receiver hook.
        vm.prank(deployer);
        assertTrue(token.transfer(address(this), SUPPLY));
        assertEq(token.balanceOf(address(this)), SUPPLY);
        assertTrue(token.transfer(address(token), SUPPLY));
        assertEq(token.balanceOf(address(this)), 0);
        assertEq(token.balanceOf(address(token)), SUPPLY);
        assertEq(token.balanceOf(deployer), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_splitTransfersAndRoundTripPreserveAllState(uint256 total, uint256 first) public {
        total = bound(total, 0, SUPPLY);
        first = bound(first, 0, total);
        bytes32 initial = _stateDigest();
        vm.prank(deployer);
        assertTrue(token.transfer(alice, first));
        vm.prank(deployer);
        assertTrue(token.transfer(alice, total - first));
        assertEq(token.balanceOf(alice), total);
        assertEq(token.balanceOf(deployer), SUPPLY - total);
        vm.prank(alice);
        assertTrue(token.transfer(deployer, total));
        assertEq(_stateDigest(), initial);
    }

    function testFuzz_approvalOverwritesAndIsIdempotent(uint256 first, uint256 replacement) public {
        vm.prank(deployer);
        token.approve(bob, 19);
        vm.prank(alice);
        token.approve(spender, 23);
        vm.prank(deployer);
        assertTrue(token.approve(spender, first));
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(deployer, spender, replacement);
        vm.prank(deployer);
        assertTrue(token.approve(spender, replacement));
        assertEq(token.allowance(deployer, spender), replacement);
        assertEq(token.allowance(deployer, bob), 19);
        assertEq(token.allowance(alice, spender), 23);
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), SUPPLY);

        bytes32 afterReplacement = _stateDigest();
        vm.expectEmit(true, true, false, true, address(token));
        emit Approval(deployer, spender, replacement);
        vm.prank(deployer);
        assertTrue(token.approve(spender, replacement));
        assertEq(_stateDigest(), afterReplacement);
    }

    function testFuzz_excessTransferLeavesStateUnchanged(uint256 balance, uint256 amount) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, balance);
        _rejectUnchanged(
            alice,
            abi.encodeCall(token.transfer, (bob, amount)),
            abi.encodeWithSelector(IMDPotToken.ERC20InsufficientBalance.selector, alice, balance, amount)
        );
    }

    function testFuzz_insufficientAllowanceLeavesStateUnchanged(uint256 amount, uint256 allowed) public {
        amount = bound(amount, 1, SUPPLY);
        allowed = bound(allowed, 0, amount - 1);
        vm.prank(deployer);
        token.approve(spender, allowed);
        _rejectUnchanged(
            spender,
            abi.encodeCall(token.transferFrom, (deployer, alice, amount)),
            abi.encodeWithSelector(IMDPotToken.ERC20InsufficientAllowance.selector, spender, allowed, amount)
        );
    }

    function testFuzz_insufficientBalanceRollsBackAllowance(uint256 balance, uint256 amount, uint256 allowed) public {
        balance = bound(balance, 0, SUPPLY);
        amount = bound(amount, balance + 1, type(uint256).max);
        allowed = bound(allowed, amount, type(uint256).max);
        vm.prank(deployer);
        token.transfer(alice, balance);
        vm.prank(alice);
        token.approve(spender, allowed);
        _rejectUnchanged(
            spender,
            abi.encodeCall(token.transferFrom, (alice, bob, amount)),
            abi.encodeWithSelector(IMDPotToken.ERC20InsufficientBalance.selector, alice, balance, amount)
        );
    }

    function testFuzz_partialSpendsUseOnlyTheApprovedBudget(uint256 allowed, uint256 first, uint256 second) public {
        // Include allowances greater than the entire supply and the infinite sentinel.
        uint256 spendable = allowed < SUPPLY ? allowed : SUPPLY;
        first = bound(first, 0, spendable);
        second = bound(second, 0, spendable - first);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, alice, first));
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, bob, second));
        assertEq(token.balanceOf(alice), first);
        assertEq(token.balanceOf(bob), second);
        assertEq(token.balanceOf(deployer), SUPPLY - first - second);
        assertEq(token.allowance(deployer, spender), allowed == type(uint256).max ? allowed : allowed - first - second);
        assertEq(token.allowance(deployer, alice), 0);
        assertEq(token.allowance(deployer, bob), 0);
        assertEq(token.totalSupply(), SUPPLY);
    }

    function testFuzz_selfTransferFromConsumesBudgetWithoutMovingTokens(uint256 amount, uint256 allowed) public {
        amount = bound(amount, 0, SUPPLY);
        allowed = bound(allowed, amount, type(uint256).max);
        vm.prank(deployer);
        token.approve(spender, allowed);
        vm.prank(spender);
        assertTrue(token.transferFrom(deployer, deployer, amount));
        assertEq(token.balanceOf(deployer), SUPPLY);
        assertEq(token.balanceOf(spender), 0);
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.allowance(deployer, spender), allowed == type(uint256).max ? allowed : allowed - amount);
    }

    function _rejectUnchanged(address caller, bytes memory data, bytes memory expectedError) internal {
        bytes32 beforeState = _stateDigest();
        vm.prank(caller);
        (bool success, bytes memory result) = address(token).call(data);
        assertFalse(success, "invalid operation succeeded");
        assertEq(result, expectedError, "wrong revert reason");
        assertEq(_stateDigest(), beforeState, "rejected operation changed token state");
    }

    function _stateDigest() internal view returns (bytes32) {
        address[5] memory accounts = [deployer, alice, bob, spender, address(0)];
        uint256[5] memory balances;
        uint256[25] memory allowances;
        for (uint256 i; i < accounts.length; ++i) {
            balances[i] = token.balanceOf(accounts[i]);
            for (uint256 j; j < accounts.length; ++j) {
                allowances[i * accounts.length + j] = token.allowance(accounts[i], accounts[j]);
            }
        }
        return keccak256(abi.encode(token.totalSupply(), balances, allowances, token.balanceOf(address(token))));
    }
}
