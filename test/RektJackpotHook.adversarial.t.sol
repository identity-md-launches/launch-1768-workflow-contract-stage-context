// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {RektJackpotHook} from "../src/RektJackpotHook.sol";
import {RektdToken} from "../src/RektdToken.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @dev A winner whose receive re-enters every claim function of the hook while its prize is being
/// paid. The guard must refuse each attempt; the selectors it reverted with are kept for the test.
contract ReentrantClaimer {
    RektJackpotHook immutable hook;
    uint256 public attempts;
    bool public reentrySucceeded;
    bytes4[3] public reasons;

    constructor(RektJackpotHook hook_) {
        hook = hook_;
    }

    receive() external payable {
        attempts++;
        try hook.claimPayout(0x000000000000000000000000000000000000dEaD) {
            reentrySucceeded = true;
        } catch (bytes memory r) {
            reasons[0] = bytes4(r);
        }
        try hook.settleRound() {
            reentrySucceeded = true;
        } catch (bytes memory r) {
            reasons[1] = bytes4(r);
        }
        try hook.claimCreatorFees() {
            reentrySucceeded = true;
        } catch (bytes memory r) {
            reasons[2] = bytes4(r);
        }
    }
}

/// @dev A winner that spends its prize on a new buy while still inside settleRound's transfer.
contract ReentrantBuyer {
    PoolSwapTest immutable router;
    PoolKey key;
    bool armed;

    constructor(PoolSwapTest router_, PoolKey memory key_) {
        router = router_;
        key = key_;
    }

    function arm() external {
        armed = true;
    }

    receive() external payable {
        if (!armed) return;
        armed = false;
        router.swap{value: msg.value}(
            key,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(msg.value), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(address(this))
        );
    }
}

/// @dev A router that tries to drive the hook's claim functions while the manager is already unlocked.
contract NestedClaimRouter is IUnlockCallback {
    IPoolManager immutable manager;
    RektJackpotHook immutable hook;

    constructor(IPoolManager manager_, RektJackpotHook hook_) {
        manager = manager_;
        hook = hook_;
    }

    function run(uint8 which, address payee) external {
        manager.unlock(abi.encode(which, payee));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager));
        (uint8 which, address payee) = abi.decode(data, (uint8, address));
        if (which == 0) hook.claimCreatorFees();
        else if (which == 1) hook.settleRound();
        else hook.claimPayout(payee);
        return "";
    }
}

/// @dev A payee that rejects ETH until told otherwise, to model a winner contract that is fixed later.
contract TogglingPayee {
    bool public rejecting = true;

    function setRejecting(bool value) external {
        rejecting = value;
    }

    receive() external payable {
        if (rejecting) revert("not now");
    }
}

/// @dev A payee that re-enters the recycle and claim paths from inside every delivery attempt. While
/// `rejecting` it then refuses the ETH, so the prize is parked; a re-entry that got through would be
/// accepted instead and leave `reentrySucceeded` set. Once accepting, it keeps the ETH and the guard
/// reasons it saw persist, so the retry inside recycleParkedPayout can be inspected.
/// (A call that ends in a revert loses its own writes, so a rejecting receive cannot keep records.)
contract RecycleReentrant {
    RektJackpotHook immutable hook;
    bool public rejecting = true;
    uint256 public attempts;
    bool public reentrySucceeded;
    bytes4[2] public reasons;

    constructor(RektJackpotHook hook_) {
        hook = hook_;
    }

    function setRejecting(bool value) external {
        rejecting = value;
    }

    receive() external payable {
        attempts++;
        bool got;
        try hook.recycleParkedPayout(address(this)) {
            got = true;
        } catch (bytes memory r) {
            reasons[0] = bytes4(r);
        }
        try hook.claimPayout(address(this)) {
            got = true;
        } catch (bytes memory r) {
            reasons[1] = bytes4(r);
        }
        if (got) {
            reentrySucceeded = true;
            return;
        }
        if (rejecting) revert("no");
    }
}

/// @notice Adversarial and edge-case tests: re-entrancy during payouts, nested unlocks, claim theft,
/// boundary timestamps, dust jackpots, partial fills, ticket thresholds, and the recycling of
/// undeliverable prizes.
contract RektJackpotHookAdversarialTest is Test {
    using stdStorage for StdStorage;
    using PoolIdLibrary for PoolKey;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    uint256 constant ETH_ID = 0;
    address constant OWNER = 0x08cD4437B077928E7fA09CF7dcDf3F7624743Bd2;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);

    PoolManager manager;
    RektdToken token;
    RektJackpotHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey key;

    receive() external payable {}

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new RektdToken();
        hook = _deployHook();
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 1_000_000 ether);

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.prank(address(0xFAC7));
        manager.initialize(key, SQRT_PRICE_1_1);
        lpRouter.modifyLiquidity{value: 10_000 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1e21,
                salt: 0
            }),
            ""
        );
    }

    function _deployHook() internal returns (RektJackpotHook) {
        bytes memory creationCode = abi.encodePacked(type(RektJackpotHook).creationCode, abi.encode(manager, OWNER));
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))))
            );
            if (!HookFlags.matches(predicted, FLAGS)) continue;
            return new RektJackpotHook{salt: bytes32(i)}(manager, OWNER);
        }
        revert("no salt");
    }

    function _swap(bool zeroForOne, int256 amountSpecified, uint160 limit, bytes memory hookData, uint256 value)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap{value: value}(
            key,
            SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    function _buy(uint256 ethIn, address buyer) internal returns (BalanceDelta) {
        return _swap(true, -int256(ethIn), TickMath.MIN_SQRT_PRICE + 1, abi.encode(buyer), ethIn);
    }

    function _claims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), ETH_ID);
    }

    function _assertBacked(address[] memory payees) internal view {
        uint256 owed = hook.pendingCreatorFees() + hook.jackpotPool();
        for (uint256 i = 0; i < payees.length; i++) {
            owed += hook.unclaimedPayout(payees[i]);
        }
        assertEq(_claims() + address(hook).balance, owed, "hook accounting is not backed");
    }

    /// @dev True when `selector` appears anywhere in `data` (v4 wraps hook reverts in WrappedError).
    function _contains(bytes memory data, bytes4 selector) internal pure returns (bool) {
        if (data.length < 4) return false;
        for (uint256 i = 0; i + 4 <= data.length; i++) {
            if (
                data[i] == selector[0] && data[i + 1] == selector[1] && data[i + 2] == selector[2]
                    && data[i + 3] == selector[3]
            ) return true;
        }
        return false;
    }

    function _payees(address extra) internal view returns (address[] memory p) {
        p = new address[](5);
        p[0] = alice;
        p[1] = bob;
        p[2] = DEAD;
        p[3] = hook.creatorFeeRecipient();
        p[4] = extra;
    }

    // ------------------------------------------------------------------
    // Re-entrancy
    // ------------------------------------------------------------------

    function test_winnerReenteringClaimsIsRefused() public {
        ReentrantClaimer winner = new ReentrantClaimer(hook);
        _buy(10 ether, address(winner));
        uint256 pool = hook.jackpotPool();
        uint256 prize = pool * 60 / 100;
        vm.warp(hook.roundEndTime() + 1);

        hook.settleRound();

        assertEq(winner.attempts(), 1, "receive was called once");
        assertFalse(winner.reentrySucceeded(), "a claim function ran inside another one");
        bytes4 guard = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
        assertEq(winner.reasons(0), guard, "claimPayout re-entry not stopped by the guard");
        assertEq(winner.reasons(1), guard, "settleRound re-entry not stopped by the guard");
        assertEq(winner.reasons(2), guard, "claimCreatorFees re-entry not stopped by the guard");

        // Paid exactly once, and the burn that follows the winner's transfer still went through.
        assertEq(address(winner).balance, prize);
        assertEq(hook.unclaimedPayout(address(winner)), 0);
        assertEq(hook.totalPrizesPaid(), prize);
        assertEq(DEAD.balance, pool * 20 / 100);
        assertEq(hook.unclaimedPayout(DEAD), 0);
        assertEq(hook.jackpotPool(), pool * 20 / 100);
        assertEq(hook.pendingCreatorFees(), 10 ether / 200, "re-entrant claimCreatorFees took nothing");
        _assertBacked(_payees(address(winner)));

        vm.expectRevert(RektJackpotHook.NothingToClaim.selector);
        hook.claimPayout(address(winner));
    }

    function test_winnerBuyingDuringPayoutKeepsAccountingAndOpensNextRound() public {
        ReentrantBuyer winner = new ReentrantBuyer(swapRouter, key);
        _buy(10 ether, address(winner));
        uint256 pool = hook.jackpotPool();
        uint256 prize = pool * 60 / 100;
        vm.warp(hook.roundEndTime() + 1);
        winner.arm();

        hook.settleRound();

        // The prize was spent on a buy inside the payout: the manager was not locked, so the swap went
        // through, charged its fee and made the winner the leader of round 2.
        assertEq(hook.unclaimedPayout(address(winner)), 0);
        assertEq(hook.totalPrizesPaid(), prize);
        assertEq(hook.roundId(), 2);
        assertEq(hook.currentLeader(), address(winner));
        assertEq(hook.roundEndTime(), block.timestamp + 600);
        assertEq(hook.jackpotPool(), pool * 20 / 100 + prize / 200);
        assertEq(hook.totalFeesCollected(), 10 ether / 100 + prize / 100);
        assertEq(DEAD.balance, pool * 20 / 100, "the burn after the re-entrant buy still went through");
        assertEq(hook.unclaimedPayout(DEAD), 0);
        _assertBacked(_payees(address(winner)));
    }

    function test_claimFunctionsCannotRunInsideAnotherUnlock() public {
        NestedClaimRouter router = new NestedClaimRouter(manager, hook);
        _buy(10 ether, alice);
        vm.warp(hook.roundEndTime() + 1);
        uint256 pending = hook.pendingCreatorFees();
        uint256 pool = hook.jackpotPool();

        vm.expectRevert();
        router.run(0, alice); // claimCreatorFees
        vm.expectRevert();
        router.run(1, alice); // settleRound

        assertEq(hook.pendingCreatorFees(), pending, "nested claim changed creator fees");
        assertEq(hook.jackpotPool(), pool, "nested settle changed the jackpot");
        assertEq(hook.currentLeader(), alice, "nested settle ended the round");
        assertTrue(hook.roundExpired());

        // Settled normally afterwards: the nested attempts left nothing behind.
        hook.settleRound();
        assertEq(alice.balance, pool * 60 / 100);
        _assertBacked(_payees(address(router)));
    }

    // ------------------------------------------------------------------
    // Claim theft and direct access
    // ------------------------------------------------------------------

    function test_nobodyCanMoveTheHooksClaims() public {
        _buy(10 ether, alice);
        uint256 claims = _claims();
        assertGt(claims, 0);

        vm.startPrank(attacker);
        vm.expectRevert();
        manager.transferFrom(address(hook), attacker, ETH_ID, claims);
        vm.expectRevert();
        manager.burn(address(hook), ETH_ID, claims);
        vm.expectRevert();
        manager.transfer(attacker, ETH_ID, claims);
        vm.stopPrank();

        // The manager will not take ETH for the attacker against the hook's claims without an unlock.
        vm.prank(attacker);
        vm.expectRevert();
        manager.take(CurrencyLibrary.ADDRESS_ZERO, attacker, claims);

        assertEq(_claims(), claims, "claims moved");
        assertEq(manager.balanceOf(attacker, ETH_ID), 0);
        assertFalse(manager.isOperator(address(hook), attacker));
    }

    function test_directCallbackCallsCannotMintOrSettle() public {
        _buy(10 ether, alice);
        uint256 claims = _claims();
        uint256 pool = hook.jackpotPool();
        SwapParams memory params = SwapParams(true, -int256(5 ether), TickMath.MIN_SQRT_PRICE + 1);

        vm.startPrank(attacker);
        vm.expectRevert(RektJackpotHook.NotPoolManager.selector);
        hook.afterSwap(attacker, key, params, BalanceDelta.wrap(0), abi.encode(attacker));
        vm.expectRevert(RektJackpotHook.NotPoolManager.selector);
        hook.beforeSwap(attacker, key, params, abi.encode(attacker));
        vm.expectRevert(RektJackpotHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(claims));
        vm.stopPrank();

        assertEq(_claims(), claims);
        assertEq(hook.jackpotPool(), pool);
        assertEq(hook.currentLeader(), alice);
    }

    function test_ownerHasNoWayToTakeFunds() public {
        _buy(10 ether, alice);
        uint256 claims = _claims();
        string[8] memory signatures = [
            "withdraw(uint256)",
            "withdraw(address,uint256)",
            "sweep(address)",
            "rescue(address,uint256)",
            "pause()",
            "setFee(uint256)",
            "setJackpot(uint256)",
            "emergencyWithdraw()"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(OWNER);
            (bool ok,) = address(hook).call(abi.encodeWithSignature(signatures[i], OWNER, claims));
            assertFalse(ok, signatures[i]);
        }
        assertEq(_claims(), claims);
        assertEq(OWNER.balance, 0);
        _assertBacked(_payees(attacker));
    }

    function test_ownershipChangesDoNotBreakClaims() public {
        _buy(10 ether, alice);
        uint256 pending = hook.pendingCreatorFees();

        vm.prank(OWNER);
        hook.renounceOwnership();
        assertEq(hook.owner(), address(0));

        // The recipient stays what it was; nobody can change it any more; claims still flow.
        vm.prank(OWNER);
        vm.expectRevert();
        hook.setCreatorFeeRecipient(bob);
        vm.prank(bob);
        hook.claimCreatorFees();
        assertEq(OWNER.balance, pending);
        assertEq(hook.creatorFeeRecipient(), OWNER);
    }

    function test_anyoneCanClaimForAPayeeButOnlyThePayeeIsPaid() public {
        _buy(10 ether, alice);
        uint256 pool = hook.jackpotPool();
        vm.warp(hook.roundEndTime() + 1);
        _buy(0.001 ether, bob); // settles into unclaimedPayout inside the swap

        assertEq(hook.unclaimedPayout(alice), pool * 60 / 100);
        uint256 attackerBefore = attacker.balance;
        vm.prank(attacker);
        hook.claimPayout(alice);
        assertEq(attacker.balance, attackerBefore, "the caller got nothing");
        assertEq(alice.balance, pool * 60 / 100, "the payee got the prize");

        vm.prank(attacker);
        hook.claimPayout(DEAD);
        assertEq(DEAD.balance, pool * 20 / 100);
        assertEq(hook.totalBurned(), pool * 20 / 100);
        _assertBacked(_payees(attacker));
    }

    // ------------------------------------------------------------------
    // Countdown boundaries and dust
    // ------------------------------------------------------------------

    function test_buyExactlyAtRoundEndExtendsInsteadOfSettling() public {
        _buy(0.001 ether, alice);
        uint256 end = hook.roundEndTime();
        vm.warp(end);
        assertFalse(hook.roundExpired(), "not expired at the exact end");
        // The round is live for this whole second, so the clock must not read zero yet.
        assertEq(hook.timeRemaining(), 1, "the live end second reads 1, never 0");
        vm.expectRevert(RektJackpotHook.RoundNotOver.selector);
        hook.settleRound();

        _buy(0.001 ether, bob);
        assertEq(hook.roundId(), 1, "same round");
        assertEq(hook.currentLeader(), bob);
        assertEq(hook.roundEndTime(), end + 120);
        assertEq(hook.unclaimedPayout(alice), 0, "alice did not win");
    }

    function test_oneSecondLaterTheRoundIsSettledByTheNextBuy() public {
        _buy(0.001 ether, alice);
        uint256 pool = hook.jackpotPool();
        vm.warp(hook.roundEndTime() + 1);
        _buy(0.001 ether, bob);
        assertEq(hook.roundId(), 2);
        assertEq(hook.currentLeader(), bob);
        assertEq(hook.unclaimedPayout(alice), pool * 60 / 100);
    }

    function test_sellSettlesAnExpiredRoundAndLeavesNoLeader() public {
        _buy(10 ether, alice);
        uint256 pool = hook.jackpotPool();
        vm.warp(hook.roundEndTime() + 1);

        _swap(false, -int256(1 ether), TickMath.MAX_SQRT_PRICE - 1, abi.encode(bob), 0);

        assertEq(hook.currentLeader(), address(0), "a sell cannot take the lead even with hookData");
        assertEq(hook.roundEndTime(), 0);
        assertEq(hook.unclaimedPayout(alice), pool * 60 / 100);
        assertEq(hook.unclaimedPayout(DEAD), pool * 20 / 100);
        assertGt(hook.jackpotPool(), pool * 20 / 100, "rollover plus the sell's fee");
        _assertBacked(_payees(attacker));
    }

    function test_dustJackpotSettlesWithoutReverting() public {
        _buy(0.001 ether, alice);
        // Shrink the jackpot to 3 wei (the claims minted by the buy still back it) to hit the rounding floor.
        stdstore.target(address(hook)).sig("jackpotPool()").checked_write(uint256(3));
        (uint256 prize, uint256 burn, uint256 rollover) = hook.jackpotSplit();
        assertEq(prize, 1);
        assertEq(burn, 0);
        assertEq(rollover, 2);
        vm.warp(hook.roundEndTime() + 1);

        hook.settleRound();

        assertEq(alice.balance, 1);
        assertEq(hook.jackpotPool(), 2);
        assertEq(hook.totalBurned(), 0);
        assertEq(hook.currentLeader(), address(0));

        // Even a zero-wei jackpot settles cleanly.
        _buy(0.001 ether, bob);
        stdstore.target(address(hook)).sig("jackpotPool()").checked_write(uint256(0));
        vm.warp(hook.roundEndTime() + 1);
        hook.settleRound();
        assertEq(bob.balance, 0);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.roundId(), 2);
    }

    function test_hookDataOfWrongLengthFallsBackToTxOrigin() public {
        bytes memory thirtyThree = abi.encodePacked(bytes1(0), abi.encode(alice));
        vm.prank(address(this), bob);
        _swap(true, -int256(0.001 ether), TickMath.MIN_SQRT_PRICE + 1, thirtyThree, 0.001 ether);
        assertEq(hook.currentLeader(), bob, "33 bytes do not name alice; tx.origin leads");

        bytes memory thirtyOne = abi.encodePacked(bytes11(0), bytes20(alice));
        vm.prank(address(this), attacker);
        _swap(true, -int256(0.001 ether), TickMath.MIN_SQRT_PRICE + 1, thirtyOne, 0.001 ether);
        assertEq(hook.currentLeader(), attacker);
    }

    // ------------------------------------------------------------------
    // Partial fills
    // ------------------------------------------------------------------

    /// @dev An exact-input buy stopped by its price limit: the trader never pays more than the input
    /// they specified, the fee is still charged on the ETH side only, and accounting stays backed.
    function test_exactInputBuyStoppedByPriceLimitNeverOverdraws() public {
        uint256 ethIn = 100 ether;
        uint256 before = address(this).balance;
        uint160 limit = uint160(uint256(SQRT_PRICE_1_1) * 999 / 1000);

        BalanceDelta delta = _swap(true, -int256(ethIn), limit, abi.encode(alice), ethIn);

        uint256 paid = before - address(this).balance;
        assertLt(uint256(uint128(-delta.amount0())), ethIn, "partial fill");
        assertEq(paid, uint256(uint128(-delta.amount0())));
        assertLe(paid, ethIn, "trader never pays more than the specified input");
        assertGt(_claims(), 0);
        assertEq(_claims(), hook.totalFeesCollected());
        _assertBacked(_payees(attacker));
    }

    /// @dev Both exact-input shapes with a price limit: the fee on the unspecified side tracks what
    /// actually moved, so the trader's net ETH is exactly 99% of the pool's output.
    function test_exactInputSellStoppedByPriceLimitChargesOnActualOutput() public {
        uint256 before = address(this).balance;
        uint160 limit = uint160(uint256(SQRT_PRICE_1_1) * 1001 / 1000);
        BalanceDelta delta = _swap(false, -int256(1_000 ether), limit, "", 0);
        uint256 received = address(this).balance - before;
        uint256 fee = _claims();
        assertEq(uint256(uint128(delta.amount0())), received);
        assertEq(fee, (received + fee) / 100);
        assertGt(received, 0);
    }

    // ------------------------------------------------------------------
    // Property tests at the arithmetic edges
    // ------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_feeSplitSumsAndNeverFavoursEitherSideByMoreThanOneWei(uint256 ethIn) public {
        ethIn = bound(ethIn, 100, 50 ether);
        _buy(ethIn, alice);
        uint256 fee = ethIn / 100;
        assertEq(hook.totalFeesCollected(), fee);
        assertEq(hook.pendingCreatorFees() + hook.jackpotPool(), fee);
        assertEq(hook.pendingCreatorFees(), fee / 2);
        assertLe(hook.jackpotPool() - hook.pendingCreatorFees(), 1);
        assertEq(_claims(), fee);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_jackpotSplitAlwaysSumsToThePool(uint256 pool) public {
        pool = bound(pool, 0, 1e27);
        stdstore.target(address(hook)).sig("jackpotPool()").checked_write(pool);
        (uint256 prize, uint256 burn, uint256 rollover) = hook.jackpotSplit();
        assertEq(prize + burn + rollover, pool);
        assertEq(prize, pool * 60 / 100);
        assertEq(burn, pool * 20 / 100);
        assertGe(rollover, pool * 20 / 100, "rounding dust stays in the jackpot");
        assertLe(rollover - pool * 20 / 100, 2);
    }

    /// @dev After an arbitrary prior volume, a buy one wei under the ticket never leads and a buy at
    /// the ticket always does.
    /// forge-config: default.fuzz.runs = 300
    function testFuzz_ticketBoundaryAfterPriorVolume(uint256 priorVolume) public {
        priorVolume = bound(priorVolume, 0, 400 ether);
        if (priorVolume > 0) _buy(priorVolume, abi.decode(abi.encode(address(0)), (address)));
        assertEq(hook.currentLeader(), address(0), "zero buyer never leads");
        uint256 ticket = hook.minimumTicket();
        assertGe(ticket, 0.0005 ether);

        _buy(ticket - 1, alice);
        assertEq(hook.currentLeader(), address(0), "one wei under the ticket does not lead");
        // The under-ticket buy added to the jackpot, so re-read the ticket before the qualifying buy.
        ticket = hook.minimumTicket();
        _buy(ticket, bob);
        assertEq(hook.currentLeader(), bob, "the ticket amount leads");
        assertEq(hook.roundEndTime(), block.timestamp + 600);
    }

    /// @dev The exact-output shapes: the trader's ETH side is always pool amount plus or minus exactly 1%.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_exactOutputBuyFeeIsOnePercentOfPoolInput(uint256 tokensOut) public {
        tokensOut = bound(tokensOut, 1, 50 ether);
        uint256 before = address(this).balance;
        _swap(true, int256(tokensOut), TickMath.MIN_SQRT_PRICE + 1, abi.encode(alice), 200 ether);
        uint256 paid = before - address(this).balance;
        uint256 fee = _claims();
        assertEq(fee, (paid - fee) / 100);
        assertEq(hook.currentLeader(), paid >= 0.0005 ether ? alice : address(0), "ticket judged on gross ETH");
    }

    /// @dev Repeated rounds: rollover compounds and the jackpot never drops below 20% of its pre-settlement value.
    function test_threeRoundsCompoundRollover() public {
        uint256 expectedPool;
        for (uint256 r = 1; r <= 3; r++) {
            _buy(10 ether, r % 2 == 0 ? alice : bob);
            expectedPool += 10 ether / 200;
            assertEq(hook.jackpotPool(), expectedPool);
            assertEq(hook.roundId(), r);
            vm.warp(hook.roundEndTime() + 1);
            hook.settleRound();
            expectedPool = expectedPool - expectedPool * 60 / 100 - expectedPool * 20 / 100;
            assertEq(hook.jackpotPool(), expectedPool);
        }
        assertEq(hook.totalPrizesPaid() + hook.totalBurned() + hook.jackpotPool(), 3 * (10 ether / 200));
        assertEq(hook.totalFeesCollected(), 3 * (10 ether / 100));
        _assertBacked(_payees(attacker));
    }

    // ------------------------------------------------------------------
    // Reverting swaps must leave nothing behind
    // ------------------------------------------------------------------

    /// @dev An exact-output sell the pool cannot fill is refused in afterSwap. The refusal must also
    /// undo the in-swap settlement beforeSwap recorded, leaving the expired round intact and settleable.
    function test_refusedExactOutputSellUndoesInSwapSettlement() public {
        _buy(10 ether, alice);
        uint256 pool = hook.jackpotPool();
        uint256 claims = _claims();
        vm.warp(hook.roundEndTime() + 1);
        assertTrue(hook.roundExpired());

        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(manager, key.toId());
        bool reverted;
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: int256(1 ether), sqrtPriceLimitX96: sqrtPrice + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
        catch (bytes memory reason) {
            reverted = true;
            assertTrue(_contains(reason, RektJackpotHook.EthOutputNotFilled.selector), "wrong revert reason");
        }
        assertTrue(reverted, "an unfillable exact-output sell must be refused");

        assertEq(hook.currentLeader(), alice, "the refused sell must not have settled the round");
        assertEq(hook.roundEndTime(), block.timestamp - 1);
        assertEq(hook.unclaimedPayout(alice), 0);
        assertEq(hook.jackpotPool(), pool);
        assertEq(_claims(), claims, "no fee minted for a refused swap");
        hook.settleRound();
        assertEq(alice.balance, pool * 60 / 100);
        _assertBacked(_payees(attacker));
    }

    /// @dev A buy cut short by its own price limit is judged on the ETH it really paid: the few wei
    /// the pool took plus the 1% of the specified amount it was charged. The lead follows that sum,
    /// never the amount merely specified.
    /// forge-config: default.fuzz.runs = 500
    function testFuzz_limitedBuyLeadsOnlyOnWhatItReallyPaid(uint256 specified) public {
        specified = bound(specified, 1, 1 ether);
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(manager, key.toId());
        uint256 before = address(this).balance;

        BalanceDelta delta = _swap(true, -int256(specified), sqrtPrice - 1, abi.encode(alice), specified);

        uint256 paid = before - address(this).balance;
        uint256 fee = specified / 100;
        assertEq(paid, uint256(uint128(-delta.amount0())));
        assertEq(_claims(), fee, "fee is 1% of the specified amount");
        assertLt(paid - fee, 10, "the pool took almost nothing");
        assertEq(hook.currentLeader(), paid >= 0.0005 ether ? alice : address(0), "lead follows the ETH paid");
        assertEq(hook.totalFeesCollected(), fee);
        _assertBacked(_payees(attacker));
    }

    // ------------------------------------------------------------------
    // Creator fees that cannot be delivered
    // ------------------------------------------------------------------

    /// @dev A rejecting creator recipient makes claimCreatorFees revert as a whole: the claims the
    /// call redeemed stay on the manager, nothing is parked, and a new recipient can be paid in full.
    function test_rejectingCreatorRecipientRevertsAndLeavesEverythingIntact() public {
        _buy(10 ether, alice);
        RejectingCreator rejecting = new RejectingCreator();
        vm.prank(OWNER);
        hook.setCreatorFeeRecipient(address(rejecting));
        uint256 pending = hook.pendingCreatorFees();
        uint256 claims = _claims();

        vm.prank(attacker);
        vm.expectRevert(RektJackpotHook.CreatorFeeTransferFailed.selector);
        hook.claimCreatorFees();

        assertEq(hook.pendingCreatorFees(), pending, "pending fees must survive the failed claim");
        assertEq(_claims(), claims, "the redeemed claims must be restored");
        assertEq(address(hook).balance, 0, "no ETH stranded on the hook");
        assertEq(hook.unclaimedPayout(address(rejecting)), 0, "nothing parked for the creator");
        assertEq(hook.parkedSince(address(rejecting)), 0);
        _assertBacked(_payees(address(rejecting)));

        // A recipient fixed by the owner is paid everything that accrued, by anyone.
        vm.prank(OWNER);
        hook.setCreatorFeeRecipient(bob);
        vm.prank(attacker);
        hook.claimCreatorFees();
        assertEq(bob.balance, pending);
        assertEq(hook.pendingCreatorFees(), 0);
        _assertBacked(_payees(address(rejecting)));
    }

    // ------------------------------------------------------------------
    // Recycling undeliverable prizes
    // ------------------------------------------------------------------

    /// @dev The grace period is inclusive: one second short of a day the prize is still the winner's,
    /// at exactly a day anyone may return it to the jackpot. Unattempted payouts, the burn address and
    /// strangers are never recyclable.
    function test_recycleGraceBoundaryAndNonRecyclables() public {
        RejectingCreator loser = new RejectingCreator();
        _buy(10 ether, address(loser));
        uint256 pool = hook.jackpotPool();
        uint256 prize = pool * 60 / 100;
        vm.warp(hook.roundEndTime() + 1);
        hook.settleRound();
        uint256 parkedAt = block.timestamp;
        assertEq(hook.unclaimedPayout(address(loser)), prize);
        assertEq(hook.parkedSince(address(loser)), parkedAt);
        // The prize was redeemed onto the hook and the burn that followed was paid out of it.
        uint256 hookHeld = address(hook).balance;
        assertEq(hookHeld, prize - pool * 20 / 100, "parked prize minus the burn paid from it");

        // Bob wins round 2 and is settled inside a swap, so his prize was never attempted.
        _buy(10 ether, bob);
        vm.warp(hook.roundEndTime() + 1);
        _buy(0.001 ether, alice);
        assertGt(hook.unclaimedPayout(bob), 0);
        assertEq(hook.parkedSince(bob), 0);
        assertGt(hook.unclaimedPayout(DEAD), 0, "the burn of round 2 is still unclaimed");

        vm.warp(parkedAt + 1 days - 1);
        vm.expectRevert(RektJackpotHook.PayoutNotRecyclable.selector);
        hook.recycleParkedPayout(address(loser));
        vm.expectRevert(RektJackpotHook.PayoutNotRecyclable.selector);
        hook.recycleParkedPayout(bob);
        vm.expectRevert(RektJackpotHook.PayoutNotRecyclable.selector);
        hook.recycleParkedPayout(DEAD);
        vm.expectRevert(RektJackpotHook.PayoutNotRecyclable.selector);
        hook.recycleParkedPayout(attacker);

        vm.warp(parkedAt + 1 days);
        uint256 poolBefore = hook.jackpotPool();
        uint256 prizesBefore = hook.totalPrizesPaid();
        vm.prank(attacker);
        hook.recycleParkedPayout(address(loser));

        assertEq(hook.unclaimedPayout(address(loser)), 0);
        assertEq(hook.parkedSince(address(loser)), 0);
        assertEq(hook.jackpotPool(), poolBefore + prize, "the prize went back to the jackpot");
        assertEq(hook.totalPrizesPaid(), prizesBefore, "a recycled prize was never paid");
        assertEq(attacker.balance, 0, "the caller gets nothing");
        assertEq(address(loser).balance, 0);
        _assertBacked(_payees(address(loser)));

        // The retry redeemed the rest of the prize onto the hook before it failed again; that ETH now
        // backs the jackpot instead of leaving the hook. Nothing left the hook.
        assertEq(address(hook).balance, prize, "the hook holds the full recycled prize");
        assertGt(prize, hookHeld);
        vm.expectRevert(RektJackpotHook.PayoutNotRecyclable.selector);
        hook.recycleParkedPayout(address(loser));
        vm.expectRevert(RektJackpotHook.NothingToClaim.selector);
        hook.claimPayout(address(loser));

        // Bob's unattempted prize and the burn still deliver; a year later they are still not recyclable.
        vm.warp(block.timestamp + 365 days);
        vm.expectRevert(RektJackpotHook.PayoutNotRecyclable.selector);
        hook.recycleParkedPayout(bob);
        uint256 bobOwed = hook.unclaimedPayout(bob);
        hook.claimPayout(bob);
        hook.claimPayout(DEAD);
        assertEq(bob.balance, bobOwed);
        _assertBacked(_payees(address(loser)));
    }

    /// @dev A hostile recipient that re-enters the recycle and claim paths from inside every delivery
    /// attempt and then rejects: no re-entry gets through (it would have accepted the ETH and left a
    /// mark), the prize is parked, and the recycle later happens exactly once.
    function test_recycleRetryReentryIsRefusedAndRecyclesOnce() public {
        RecycleReentrant winner = new RecycleReentrant(hook);
        _buy(10 ether, address(winner));
        uint256 prize = hook.jackpotPool() * 60 / 100;
        vm.warp(hook.roundEndTime() + 1);
        hook.settleRound();
        assertFalse(winner.reentrySucceeded(), "a claim path ran inside settleRound's delivery");
        assertEq(address(winner).balance, 0);
        assertEq(hook.unclaimedPayout(address(winner)), prize, "prize parked");
        uint256 parkedAt = block.timestamp;

        // Too early: the hostile recipient's own re-entry attempts cannot shortcut the grace period.
        vm.warp(parkedAt + 1 days - 1);
        vm.expectRevert(RektJackpotHook.PayoutNotRecyclable.selector);
        hook.recycleParkedPayout(address(winner));

        vm.warp(parkedAt + 1 days);
        uint256 poolBefore = hook.jackpotPool();
        hook.recycleParkedPayout(address(winner));

        assertFalse(winner.reentrySucceeded(), "a claim path ran inside the recycle's retry");
        assertEq(address(winner).balance, 0);
        assertEq(hook.jackpotPool(), poolBefore + prize, "recycled exactly once");
        assertEq(hook.unclaimedPayout(address(winner)), 0);
        assertEq(hook.parkedSince(address(winner)), 0);
        vm.expectRevert(RektJackpotHook.PayoutNotRecyclable.selector);
        hook.recycleParkedPayout(address(winner));
        _assertBacked(_payees(address(winner)));
    }

    /// @dev The same recipient, fixed to accept before the recycle: the retry delivers the prize, the
    /// re-entries it makes from inside that delivery are refused by the guard (recorded, since this
    /// time the call does not revert), and nothing is recycled.
    function test_recycleRetryReentryIsStoppedByTheGuard() public {
        RecycleReentrant winner = new RecycleReentrant(hook);
        _buy(10 ether, address(winner));
        uint256 prize = hook.jackpotPool() * 60 / 100;
        vm.warp(hook.roundEndTime() + 1);
        hook.settleRound();
        assertEq(hook.unclaimedPayout(address(winner)), prize, "prize parked");

        vm.warp(block.timestamp + 1 days);
        winner.setRejecting(false);
        uint256 poolBefore = hook.jackpotPool();
        vm.prank(attacker);
        hook.recycleParkedPayout(address(winner));

        assertEq(winner.attempts(), 1, "one delivery attempt recorded (the accepted one)");
        assertFalse(winner.reentrySucceeded(), "a claim path ran inside the recycle's retry");
        bytes4 guard = bytes4(keccak256("ReentrancyGuardReentrantCall()"));
        assertEq(winner.reasons(0), guard, "nested recycleParkedPayout not stopped by the guard");
        assertEq(winner.reasons(1), guard, "nested claimPayout not stopped by the guard");
        assertEq(address(winner).balance, prize, "paid exactly once");
        assertEq(hook.jackpotPool(), poolBefore, "nothing recycled");
        assertEq(hook.unclaimedPayout(address(winner)), 0);
        assertEq(hook.parkedSince(address(winner)), 0);
        assertEq(hook.totalPrizesPaid(), prize);
        _assertBacked(_payees(address(winner)));
    }

    /// @dev A winner contract that rejected at settlement but accepts later is paid everything it is
    /// owed on the recycle's retry, including a second prize that was never attempted, and nothing
    /// goes back to the jackpot. The grace clock runs from the first failed delivery only.
    function test_recipientFixedBeforeRecycleIsPaidEverythingOwed() public {
        TogglingPayee winner = new TogglingPayee();
        _buy(10 ether, address(winner));
        uint256 prize1 = hook.jackpotPool() * 60 / 100;
        vm.warp(hook.roundEndTime() + 1);
        hook.settleRound();
        uint256 parkedAt = block.timestamp;
        assertEq(hook.parkedSince(address(winner)), parkedAt);

        // A retry through claimPayout while still rejecting re-parks without resetting the clock.
        vm.warp(parkedAt + 1 hours);
        hook.claimPayout(address(winner));
        assertEq(hook.unclaimedPayout(address(winner)), prize1);
        assertEq(hook.parkedSince(address(winner)), parkedAt, "re-parking must not restart the grace period");

        // The same contract wins again; this prize is settled inside a swap and never attempted.
        _buy(10 ether, address(winner));
        uint256 prize2 = hook.jackpotPool() * 60 / 100;
        vm.warp(hook.roundEndTime() + 1);
        _buy(0.001 ether, alice);
        assertEq(hook.unclaimedPayout(address(winner)), prize1 + prize2);

        vm.warp(parkedAt + 1 days);
        winner.setRejecting(false);
        uint256 poolBefore = hook.jackpotPool();
        uint256 prizesBefore = hook.totalPrizesPaid();
        vm.prank(attacker);
        hook.recycleParkedPayout(address(winner));

        assertEq(address(winner).balance, prize1 + prize2, "the retry delivered everything owed");
        assertEq(hook.jackpotPool(), poolBefore, "nothing was recycled");
        assertEq(hook.totalPrizesPaid(), prizesBefore + prize1 + prize2);
        assertEq(hook.unclaimedPayout(address(winner)), 0);
        assertEq(hook.parkedSince(address(winner)), 0);
        assertEq(address(hook).balance, 0, "no ETH left on the hook");
        _assertBacked(_payees(address(winner)));
    }

    /// @dev Anyone can crown a contract that can never receive ETH: the hook itself, the PoolManager
    /// or the token. Each prize is parked, never lost, and returns to the jackpot after the grace period.
    function test_prizesCrownedToUnpayableSystemContractsAreRecycled() public {
        address[3] memory unpayable = [address(hook), address(manager), address(token)];
        uint256 totalRecycled;
        for (uint256 i = 0; i < unpayable.length; i++) {
            _buy(10 ether, unpayable[i]);
            assertEq(hook.currentLeader(), unpayable[i]);
            uint256 parked = hook.jackpotPool() * 60 / 100;
            vm.warp(hook.roundEndTime() + 1);
            hook.settleRound();
            assertEq(hook.unclaimedPayout(unpayable[i]), parked, "prize parked");
            assertEq(hook.parkedSince(unpayable[i]), block.timestamp);
            assertEq(hook.currentLeader(), address(0));

            vm.warp(block.timestamp + 1 days);
            uint256 poolBefore = hook.jackpotPool();
            hook.recycleParkedPayout(unpayable[i]);
            assertEq(hook.jackpotPool(), poolBefore + parked);
            assertEq(hook.unclaimedPayout(unpayable[i]), 0);
            totalRecycled += parked;
            _assertBacked(_payees(unpayable[i]));
        }
        assertEq(hook.totalPrizesPaid(), 0, "nothing was ever paid to a system contract");
        uint256 hookHeld = address(hook).balance;
        assertGt(hookHeld, 0, "recycled ETH sits on the hook, backing the jackpot");
        assertLe(hookHeld, totalRecycled, "the burns were paid from the ETH the hook held");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0);

        // The ETH held on the hook is spent before any more claims are redeemed.
        _buy(10 ether, alice);
        vm.warp(hook.roundEndTime() + 1);
        uint256 claimsBefore = _claims();
        uint256 deadBefore = DEAD.balance;
        (uint256 prize, uint256 burn,) = hook.jackpotSplit();
        hook.settleRound();
        assertEq(alice.balance, prize);
        assertEq(DEAD.balance - deadBefore, burn);
        if (prize + burn <= hookHeld) {
            assertEq(_claims(), claimsBefore, "no claim redeemed while the hook held enough ETH");
            assertEq(address(hook).balance, hookHeld - prize - burn);
        } else {
            assertEq(_claims(), claimsBefore - (prize + burn - hookHeld));
            assertEq(address(hook).balance, 0);
        }
        _assertBacked(_payees(attacker));
    }
}

/// @dev A creator recipient that refuses ETH.
contract RejectingCreator {
    receive() external payable {
        revert("no");
    }
}
