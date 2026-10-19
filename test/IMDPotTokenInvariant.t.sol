// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IMDPotToken} from "src/IMDPotToken.sol";

/// @notice A closed set of holders makes the sum of balances exhaustive. No token
/// storage is edited: funding, approvals and transfers all use the public API.
contract IMDPotTokenHandler is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    IMDPotToken public immutable token;
    address[4] public actors;

    // Independent transaction history, updated only after a successful call.
    // Recording both sides also handles self-transfers without a special case.
    mapping(address => uint256) public received;
    mapping(address => uint256) public sent;
    mapping(address => mapping(address => uint256)) public lastApproval;
    mapping(address => mapping(address => uint256)) public spentSinceApproval;

    uint256 public nonzeroTransfers;
    uint256 public nonzeroDelegatedTransfers;
    uint256 public rejectedCalls;

    constructor(IMDPotToken token_, address[4] memory actors_) {
        token = token_;
        actors = actors_;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, expectedBalance(from));
        vm.prank(from);
        assertTrue(token.transfer(to, amount), "valid transfer returned false");
        _recordTransfer(from, to, amount);
        if (amount > 0) ++nonzeroTransfers;
    }

    function approve(uint256 ownerSeed, uint256 spenderSeed, uint256 amount) public {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        vm.prank(owner);
        assertTrue(token.approve(spender, amount), "valid approval returned false");
        lastApproval[owner][spender] = amount;
        spentSinceApproval[owner][spender] = 0;
    }

    // Dedicated actions ensure random sequences regularly revoke existing grants
    // and exercise the infinite sentinel rather than depending on a rare uint256.
    function revoke(uint256 ownerSeed, uint256 spenderSeed) external {
        approve(ownerSeed, spenderSeed, 0);
    }

    function approveUnlimited(uint256 ownerSeed, uint256 spenderSeed) external {
        approve(ownerSeed, spenderSeed, type(uint256).max);
    }

    function transferFrom(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address spender = _actor(spenderSeed);
        uint256 limit = expectedBalance(from);
        uint256 available = expectedAllowance(from, spender);
        if (available < limit) limit = available;
        _transferFrom(from, _actor(toSeed), spender, bound(amount, 0, limit));
    }

    /// @dev The raw amount can exceed balance, allowance, or both. Expected reverts
    /// are checked explicitly; fail_on_revert makes unexpected handler failures fatal.
    function transferFromUnbounded(uint256 fromSeed, uint256 toSeed, uint256 spenderSeed, uint256 amount) external {
        _transferFrom(_actor(fromSeed), _actor(toSeed), _actor(spenderSeed), amount);
    }

    function transferBeyondBalance(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        uint256 balance = expectedBalance(from);
        amount = bound(amount, balance + 1, type(uint256).max);
        _reject(
            from,
            abi.encodeCall(token.transfer, (_actor(toSeed), amount)),
            abi.encodeWithSelector(IMDPotToken.ERC20InsufficientBalance.selector, from, balance, amount)
        );
    }

    function rejectZeroAddress(uint256 ownerSeed, uint256 spenderSeed, uint256 amount, uint256 operationSeed) external {
        address owner = _actor(ownerSeed);
        address spender = _actor(spenderSeed);
        uint256 operation = operationSeed % 3;
        if (operation == 0) {
            _reject(
                owner,
                abi.encodeCall(token.approve, (address(0), amount)),
                abi.encodeWithSelector(IMDPotToken.ERC20InvalidSpender.selector, address(0))
            );
        } else if (operation == 1) {
            amount = bound(amount, 0, expectedBalance(owner));
            _reject(
                owner,
                abi.encodeCall(token.transfer, (address(0), amount)),
                abi.encodeWithSelector(IMDPotToken.ERC20InvalidReceiver.selector, address(0))
            );
        } else {
            uint256 limit = expectedBalance(owner);
            uint256 available = expectedAllowance(owner, spender);
            if (available < limit) limit = available;
            amount = bound(amount, 0, limit);
            _reject(
                spender,
                abi.encodeCall(token.transferFrom, (owner, address(0), amount)),
                abi.encodeWithSelector(IMDPotToken.ERC20InvalidReceiver.selector, address(0))
            );
        }
    }

    function expectedBalance(address account) public view returns (uint256) {
        uint256 initial = account == actors[0] ? SUPPLY : 0;
        return initial + received[account] - sent[account];
    }

    function expectedAllowance(address owner, address spender) public view returns (uint256) {
        uint256 granted = lastApproval[owner][spender];
        return granted == type(uint256).max ? granted : granted - spentSinceApproval[owner][spender];
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _recordTransfer(address from, address to, uint256 amount) internal {
        sent[from] += amount;
        received[to] += amount;
    }

    function _transferFrom(address from, address to, address spender, uint256 amount) internal {
        uint256 available = expectedAllowance(from, spender);
        uint256 balance = expectedBalance(from);
        if (amount > available) {
            _reject(
                spender,
                abi.encodeCall(token.transferFrom, (from, to, amount)),
                abi.encodeWithSelector(IMDPotToken.ERC20InsufficientAllowance.selector, spender, available, amount)
            );
        } else if (amount > balance) {
            _reject(
                spender,
                abi.encodeCall(token.transferFrom, (from, to, amount)),
                abi.encodeWithSelector(IMDPotToken.ERC20InsufficientBalance.selector, from, balance, amount)
            );
        } else {
            vm.prank(spender);
            assertTrue(token.transferFrom(from, to, amount), "valid transferFrom returned false");
            _recordTransfer(from, to, amount);
            spentSinceApproval[from][spender] += amount;
            if (amount > 0) ++nonzeroDelegatedTransfers;
        }
    }

    function _reject(address caller, bytes memory data, bytes memory expectedError) internal {
        vm.prank(caller);
        (bool success, bytes memory result) = address(token).call(data);
        assertFalse(success, "invalid operation succeeded");
        assertEq(result, expectedError, "wrong rejection");
        ++rejectedCalls;
        // No history is changed. The invariants therefore check rollback of ALL
        // tracked balances and allowances, including unrelated owner/spender pairs.
    }
}

/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 128
/// forge-config: default.invariant.fail-on-revert = true
contract IMDPotTokenInvariantTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000 * 10 ** 18;
    IMDPotToken internal token;
    IMDPotTokenHandler internal handler;
    address[4] internal actors;

    function setUp() public {
        actors = [makeAddr("holder0"), makeAddr("holder1"), makeAddr("holder2"), makeAddr("holder3")];
        vm.prank(actors[0]);
        token = new IMDPotToken();
        handler = new IMDPotTokenHandler(token, actors);

        // Fund every actor through real transfers and seed both finite and
        // infinite approvals so useful delegated calls are reachable immediately.
        for (uint256 i = 1; i < actors.length; ++i) {
            handler.transfer(0, i, SUPPLY / 4);
        }
        handler.approve(0, 1, SUPPLY / 8);
        handler.approveUnlimited(1, 2);
        handler.approve(2, 3, SUPPLY / 8);
        handler.approveUnlimited(3, 0);

        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.transfer.selector;
        selectors[1] = handler.approve.selector;
        selectors[2] = handler.revoke.selector;
        selectors[3] = handler.approveUnlimited.selector;
        selectors[4] = handler.transferFrom.selector;
        selectors[5] = handler.transferFromUnbounded.selector;
        selectors[6] = handler.transferBeyondBalance.selector;
        selectors[7] = handler.rejectZeroAddress.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_supplyIsFixedAndEveryTokenIsAccountedFor() public view {
        assertEq(token.totalSupply(), SUPPLY, "supply changed after deployment");
        uint256 sum;
        for (uint256 i; i < actors.length; ++i) {
            sum += token.balanceOf(actors[i]);
        }
        assertEq(sum, SUPPLY, "tokens were created, destroyed, or sent outside the holders");
        assertEq(token.balanceOf(address(0)), 0, "tokens reached zero address");
        assertEq(token.balanceOf(address(token)), 0, "unexpected tokens credited to token contract");
        assertEq(token.balanceOf(address(handler)), 0, "unexpected tokens credited to handler");
    }

    function invariant_eachBalanceMatchesItsTransferHistory() public view {
        for (uint256 i; i < actors.length; ++i) {
            address actor = actors[i];
            uint256 initial = i == 0 ? SUPPLY : 0;
            assertEq(
                token.balanceOf(actor) + handler.sent(actor),
                initial + handler.received(actor),
                "holder balance does not match its incoming and outgoing transfers"
            );
        }
    }

    function invariant_eachAllowanceMatchesTheOwnersLatestGrant() public view {
        for (uint256 i; i < actors.length; ++i) {
            for (uint256 j; j < actors.length; ++j) {
                assertEq(
                    token.allowance(actors[i], actors[j]),
                    handler.expectedAllowance(actors[i], actors[j]),
                    "allowance was changed without the owner's grant or the spender's use"
                );
            }
            assertEq(token.allowance(actors[i], address(0)), 0);
            assertEq(token.allowance(address(0), actors[i]), 0);
        }
    }

    /// @dev A deterministic sequence checks that the handler reaches real token
    /// movement, self-transfers, finite exhaustion, infinite use, and each failure.
    function test_handlerExercisesSuccessAndFailurePaths() public {
        handler.transfer(0, 1, 1);
        handler.approve(0, 1, 2);
        handler.transferFrom(0, 0, 1, 1);
        handler.transferFrom(0, 2, 1, 1);
        handler.transferFromUnbounded(0, 2, 1, 1); // Exhausted approval.
        handler.approveUnlimited(0, 1);
        handler.transferFrom(0, 2, 1, 1);
        handler.transferFromUnbounded(0, 2, 1, type(uint256).max); // Insufficient balance.
        handler.transferBeyondBalance(0, 0, type(uint256).max);
        handler.rejectZeroAddress(0, 1, 1, 0);
        handler.rejectZeroAddress(0, 1, 1, 1);
        handler.approve(0, 1, 3);
        handler.rejectZeroAddress(0, 1, 1, 2); // Finite allowance must roll back.
        handler.revoke(0, 1);
        handler.transferFromUnbounded(0, 2, 1, 1);

        assertEq(handler.nonzeroTransfers(), 4); // Three initial funding calls and one here.
        assertEq(handler.nonzeroDelegatedTransfers(), 3);
        assertEq(handler.rejectedCalls(), 7);
        invariant_supplyIsFixedAndEveryTokenIsAccountedFor();
        invariant_eachBalanceMatchesItsTransferHistory();
        invariant_eachAllowanceMatchesTheOwnersLatestGrant();
    }
}
