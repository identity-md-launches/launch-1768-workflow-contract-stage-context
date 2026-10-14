// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
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

/// @dev A payee that refuses ETH, so prizes and creator fees for it must be parked, never lost.
contract RejectingPayee {
    receive() external payable {
        revert("no");
    }
}

/// @notice Drives the hook through every public entry point in random order with bounded inputs and
/// several actors, checking per-call postconditions and keeping ghost totals for the invariants.
/// @dev Expected failures (a settle before expiry, a claim of nothing, an attack that must be refused)
/// are caught here and turned into violation flags when they do NOT fail, so the suite can run with
/// `fail-on-revert = true` and still surface any unexpected revert as a failure.
contract RektJackpotHandler is Test {
    using PoolIdLibrary for PoolKey;

    uint256 constant BPS = 10_000;
    address constant OWNER = 0x08cD4437B077928E7fA09CF7dcDf3F7624743Bd2;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant ETH_ID = 0;

    PoolManager public manager;
    RektJackpotHook public hook;
    RektdToken public token;
    PoolSwapTest public swapRouter;
    PoolKey public key;

    address[] public actors; // alice, bob, carol, rejecter
    address public rejecter;
    address public attacker = address(0xBAD);

    // Ghost accounting
    uint256 public ghostCreatorPaid; // ETH delivered by claimCreatorFees to an accepting recipient
    uint256 public ghostSwaps;
    uint256 public ghostSettlementsInSwap;
    uint256 public ghostSettleRoundCalls;
    uint256 public ghostParkedEvents;
    uint256 public ghostRoundsStarted;
    uint256 public ghostRecycled; // ETH returned to the jackpot by recycleParkedPayout
    mapping(address => uint256) public firstParkedAt; // when a payee's current parked amount first failed

    // Violation reporting: the first broken postcondition and where it happened.
    bool public violated;
    string public violation;

    // Monotonic snapshots
    uint256 lastFees;
    uint256 lastBurned;
    uint256 lastPrizes;
    uint256 lastRoundId;

    constructor(
        PoolManager manager_,
        RektJackpotHook hook_,
        RektdToken token_,
        PoolSwapTest swapRouter_,
        PoolKey memory key_,
        address[] memory actors_,
        address rejecter_
    ) {
        manager = manager_;
        hook = hook_;
        token = token_;
        swapRouter = swapRouter_;
        key = key_;
        actors = actors_;
        rejecter = rejecter_;
        token.approve(address(swapRouter), type(uint256).max);
    }

    receive() external payable {}

    function payees() external view returns (address[] memory p) {
        p = new address[](actors.length + 2);
        for (uint256 i = 0; i < actors.length; i++) {
            p[i] = actors[i];
        }
        p[actors.length] = DEAD;
        p[actors.length + 1] = OWNER;
    }

    // ------------------------------------------------------------------
    // Internal helpers
    // ------------------------------------------------------------------

    function _flag(bool ok, string memory what) internal {
        if (!ok && !violated) {
            violated = true;
            violation = what;
        }
    }

    function _claims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), ETH_ID);
    }

    function _split(uint256 pool) internal pure returns (uint256 prize, uint256 burn, uint256 rollover) {
        prize = pool * 6_000 / BPS;
        burn = pool * 2_000 / BPS;
        rollover = pool - prize - burn;
    }

    function _minTicketFor(uint256 pool) internal pure returns (uint256) {
        uint256 share = (pool * 500 + BPS - 1) / BPS;
        return share > 0.0005 ether ? share : 0.0005 ether;
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _snapshotMonotonic() internal {
        _flag(hook.totalFeesCollected() >= lastFees, "totalFeesCollected decreased");
        _flag(hook.totalBurned() >= lastBurned, "totalBurned decreased");
        _flag(hook.totalPrizesPaid() >= lastPrizes, "totalPrizesPaid decreased");
        _flag(hook.roundId() >= lastRoundId, "roundId decreased");
        lastFees = hook.totalFeesCollected();
        lastBurned = hook.totalBurned();
        lastPrizes = hook.totalPrizesPaid();
        lastRoundId = hook.roundId();
    }

    struct Snap {
        address leader;
        uint256 endTime;
        uint256 roundId;
        uint256 pool;
        uint256 pending;
        uint256 fees;
        uint256 claims;
        bool expired;
        uint256 unclaimedLeader;
        uint256 unclaimedDead;
    }

    function _snap() internal view returns (Snap memory s) {
        s.leader = hook.currentLeader();
        s.endTime = hook.roundEndTime();
        s.roundId = hook.roundId();
        s.pool = hook.jackpotPool();
        s.pending = hook.pendingCreatorFees();
        s.fees = hook.totalFeesCollected();
        s.claims = _claims();
        s.expired = hook.roundExpired();
        s.unclaimedLeader = hook.unclaimedPayout(s.leader);
        s.unclaimedDead = hook.unclaimedPayout(DEAD);
    }

    /// @dev Checks what every swap must do to the fee accounting and (via beforeSwap) to an expired round.
    function _checkSwapAccounting(Snap memory s, uint256 expectedFee) internal {
        uint256 feeDelta = hook.totalFeesCollected() - s.fees;
        _flag(feeDelta == expectedFee, "fee charged differs from 1% of the ETH side");
        _flag(_claims() - s.claims == feeDelta, "claims minted differ from the fee");
        uint256 creatorShare = feeDelta * 5_000 / BPS;
        _flag(hook.pendingCreatorFees() - s.pending == creatorShare, "creator share is not half the fee");

        uint256 poolBase = s.pool;
        if (s.expired) {
            (uint256 prize, uint256 burn, uint256 rollover) = _split(s.pool);
            poolBase = rollover;
            _flag(
                hook.unclaimedPayout(s.leader) == s.unclaimedLeader + prize,
                "in-swap settlement did not record the winner prize"
            );
            _flag(hook.unclaimedPayout(DEAD) == s.unclaimedDead + burn, "in-swap settlement did not record the burn");
            ghostSettlementsInSwap++;
        }
        _flag(hook.jackpotPool() == poolBase + (feeDelta - creatorShare), "jackpot share is not the fee remainder");
    }

    /// @dev Checks leader and countdown after a buy whose gross ETH input is `gross` and buyer is `buyer`
    /// (zero when the buyer must be skipped).
    function _checkTicket(Snap memory s, uint256 gross, address buyer) internal {
        address leaderAfterSettle = s.expired ? address(0) : s.leader;
        uint256 endAfterSettle = s.expired ? 0 : s.endTime;
        uint256 poolAfterSettle = s.pool;
        if (s.expired) (,, poolAfterSettle) = _split(s.pool);
        bool qualifies = buyer != address(0) && buyer != DEAD && gross >= _minTicketFor(poolAfterSettle);

        if (!qualifies) {
            _flag(hook.currentLeader() == leaderAfterSettle, "non-qualifying buy changed the leader");
            _flag(hook.roundEndTime() == endAfterSettle, "non-qualifying buy changed the countdown");
            return;
        }
        _flag(hook.currentLeader() == buyer, "qualifying buy did not take the lead");
        uint256 cap = block.timestamp + 600;
        if (leaderAfterSettle == address(0)) {
            _flag(hook.roundEndTime() == cap, "new round does not end in 600 seconds");
            _flag(hook.roundId() == s.roundId + 1, "new round did not increment roundId");
            ghostRoundsStarted++;
        } else {
            uint256 extended = endAfterSettle + 120;
            _flag(hook.roundEndTime() == (extended > cap ? cap : extended), "extension is not +120 capped at +600");
            _flag(hook.roundId() == s.roundId, "extension changed roundId");
        }
    }

    function _checkNoTicket(Snap memory s) internal {
        _flag(hook.currentLeader() == (s.expired ? address(0) : s.leader), "sell changed the leader");
        _flag(hook.roundEndTime() == (s.expired ? 0 : s.endTime), "sell changed the countdown");
        _flag(hook.roundId() == s.roundId, "sell changed roundId");
    }

    function _swap(bool zeroForOne, int256 amountSpecified, bytes memory hookData, uint256 value)
        internal
        returns (BalanceDelta)
    {
        return swapRouter.swap{value: value}(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: amountSpecified,
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            hookData
        );
    }

    // ------------------------------------------------------------------
    // Actions: swaps
    // ------------------------------------------------------------------

    /// @dev Exact-input buy. `mode` picks how the buyer is identified: 0-5 hookData with an actor,
    /// 6 empty hookData with the actor as tx.origin, 7 zero buyer, 8 dEaD buyer, 9 malformed hookData.
    function buyExactIn(uint256 ethIn, uint256 actorSeed, uint8 mode) external {
        ethIn = bound(ethIn, 1, 10 ether);
        mode = uint8(bound(mode, 0, 9));
        address buyer = _actor(actorSeed);
        bytes memory hookData = abi.encode(buyer);
        if (mode == 7) {
            buyer = address(0);
            hookData = abi.encode(address(0));
        } else if (mode == 8) {
            buyer = DEAD;
            hookData = abi.encode(DEAD);
        } else if (mode == 9) {
            // 33 bytes: not a buyer, falls back to tx.origin, which the prank below sets to the actor.
            hookData = abi.encodePacked(bytes1(0x01), abi.encode(buyer));
        }
        Snap memory s = _snap();
        uint256 ethBefore = address(this).balance;

        if (mode >= 6) vm.prank(address(this), buyer == address(0) ? address(0) : buyer);
        if (mode == 6) hookData = "";
        _swap(true, -int256(ethIn), hookData, ethIn);
        ghostSwaps++;

        _flag(ethBefore - address(this).balance == ethIn, "exact-input buyer paid something other than the input");
        _checkSwapAccounting(s, ethIn / 100);
        _checkTicket(s, ethIn, buyer);
        _snapshotMonotonic();
    }

    function buyExactOut(uint256 tokensOut, uint256 actorSeed) external {
        tokensOut = bound(tokensOut, 1, 10 ether);
        address buyer = _actor(actorSeed);
        Snap memory s = _snap();
        uint256 ethBefore = address(this).balance;
        uint256 tokBefore = token.balanceOf(address(this));

        _swap(true, int256(tokensOut), abi.encode(buyer), 100 ether);
        ghostSwaps++;

        uint256 paid = ethBefore - address(this).balance;
        uint256 fee = _claims() - s.claims;
        _flag(token.balanceOf(address(this)) - tokBefore == tokensOut, "exact-output buyer got a different amount");
        _flag(fee == (paid - fee) / 100, "exact-output buy fee is not 1% of the pool input");
        _checkSwapAccounting(s, fee);
        _checkTicket(s, paid, buyer);
        _snapshotMonotonic();
    }

    function sellExactIn(uint256 tokensIn, uint256 actorSeed) external {
        tokensIn = bound(tokensIn, 1, 10 ether);
        Snap memory s = _snap();
        uint256 ethBefore = address(this).balance;

        // hookData with a buyer on a sell must never make that address the leader.
        _swap(false, -int256(tokensIn), abi.encode(_actor(actorSeed)), 0);
        ghostSwaps++;

        uint256 received = address(this).balance - ethBefore;
        uint256 fee = _claims() - s.claims;
        _flag(fee == (received + fee) / 100, "exact-input sell fee is not 1% of the gross ETH output");
        _checkSwapAccounting(s, fee);
        _checkNoTicket(s);
        _snapshotMonotonic();
    }

    function sellExactOut(uint256 ethOut, uint256 actorSeed) external {
        ethOut = bound(ethOut, 1, 10 ether);
        Snap memory s = _snap();
        uint256 ethBefore = address(this).balance;

        _swap(false, int256(ethOut), abi.encode(_actor(actorSeed)), 0);
        ghostSwaps++;

        _flag(address(this).balance - ethBefore == ethOut, "exact-output seller received a different amount");
        _checkSwapAccounting(s, ethOut / 100);
        _checkNoTicket(s);
        _snapshotMonotonic();
    }

    // ------------------------------------------------------------------
    // Actions: time and settlement
    // ------------------------------------------------------------------

    function warp(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1, 900);
        vm.warp(block.timestamp + seconds_);
        _checkClock();
    }

    /// @dev Long jumps so parked payouts can pass the one-day grace period within a sequence.
    function warpLong(uint256 seconds_) external {
        seconds_ = bound(seconds_, 1 days, 3 days);
        vm.warp(block.timestamp + seconds_);
        _checkClock();
    }

    function _checkClock() internal {
        bool running = hook.currentLeader() != address(0);
        uint256 end = hook.roundEndTime();
        bool expired = running && block.timestamp > end;
        _flag(hook.roundExpired() == expired, "roundExpired disagrees with the countdown");
        uint256 remaining = hook.timeRemaining();
        _flag((remaining == 0) == (!running || expired), "timeRemaining is zero exactly when the round is not live");
        if (running && !expired) {
            uint256 left = end - block.timestamp;
            _flag(remaining == (left == 0 ? 1 : left), "timeRemaining is not the seconds left (1 in the end second)");
            _flag(remaining <= 600, "timeRemaining above the round cap");
        }
    }

    /// @dev An exact-input buy stopped by a price limit one unit under the current price: the pool
    /// takes a few wei, the hook still charges 1% of the specified amount, and the ticket is judged on
    /// the ETH really paid (pool input plus fee), never on the amount specified.
    function buyExactInLimited(uint256 ethIn, uint256 actorSeed) external {
        ethIn = bound(ethIn, 1, 10 ether);
        address buyer = _actor(actorSeed);
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(manager, key.toId());
        if (sqrtPrice <= TickMath.MIN_SQRT_PRICE + 1) return;
        Snap memory s = _snap();
        uint256 ethBefore = address(this).balance;

        swapRouter.swap{value: ethIn}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: sqrtPrice - 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(buyer)
        );
        ghostSwaps++;

        uint256 paid = ethBefore - address(this).balance;
        uint256 fee = ethIn / 100;
        _flag(paid >= fee && paid <= ethIn, "limited buy paid outside [fee, specified]");
        _flag(paid - fee < 10, "a buy limited one unit under the price should trade only a few wei");
        _checkSwapAccounting(s, fee);
        _checkTicket(s, paid, buyer);
        _snapshotMonotonic();
    }

    /// @dev An exact-output sell stopped by a price limit one unit above the current price cannot
    /// output the ETH asked plus the fee: it must be refused outright and leave no trace, including
    /// the settlement beforeSwap would have recorded for an expired round.
    function sellExactOutLimited(uint256 ethOut, uint256 actorSeed) external {
        ethOut = bound(ethOut, 1, 10 ether);
        (uint160 sqrtPrice,,,) = StateLibrary.getSlot0(manager, key.toId());
        if (sqrtPrice >= TickMath.MAX_SQRT_PRICE - 1) return;
        Snap memory s = _snap();
        uint256 ethBefore = address(this).balance;
        uint256 tokBefore = token.balanceOf(address(this));

        bool reverted;
        try swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: int256(ethOut), sqrtPriceLimitX96: sqrtPrice + 1}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(_actor(actorSeed))
        ) {}
        catch (bytes memory reason) {
            reverted = true;
            _flag(_contains(reason, RektJackpotHook.EthOutputNotFilled.selector), "unfillable sell: wrong reason");
        }
        _flag(reverted, "an unfillable exact-output sell was not refused");
        _flag(
            address(this).balance == ethBefore && token.balanceOf(address(this)) == tokBefore,
            "refused sell moved funds"
        );
        _flag(hook.totalFeesCollected() == s.fees && _claims() == s.claims, "refused sell charged a fee");
        _flag(hook.jackpotPool() == s.pool && hook.pendingCreatorFees() == s.pending, "refused sell changed accounting");
        _flag(hook.currentLeader() == s.leader && hook.roundEndTime() == s.endTime, "refused sell changed the round");
        _flag(hook.unclaimedPayout(s.leader) == s.unclaimedLeader, "refused sell left an in-swap settlement behind");
    }

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

    function settleRound(uint256 callerSeed) external {
        address caller = _actor(callerSeed);
        if (!hook.roundExpired()) {
            vm.prank(caller);
            try hook.settleRound() {
                _flag(false, "settleRound succeeded before expiry");
            } catch (bytes memory reason) {
                _flag(bytes4(reason) == RektJackpotHook.RoundNotOver.selector, "settleRound wrong revert");
            }
            return;
        }
        Snap memory s = _snap();
        (uint256 prize, uint256 burn, uint256 rollover) = _split(s.pool);
        uint256 winnerBefore = s.leader.balance;
        uint256 deadBefore = DEAD.balance;
        uint256 burnedBefore = hook.totalBurned();
        uint256 prizesBefore = hook.totalPrizesPaid();

        vm.prank(caller);
        hook.settleRound();
        ghostSettleRoundCalls++;

        _flag(hook.currentLeader() == address(0) && hook.roundEndTime() == 0, "settleRound left a round running");
        _flag(hook.jackpotPool() == rollover, "settleRound rollover is not 20%");
        _flag(DEAD.balance - deadBefore == s.unclaimedDead + burn, "burn not delivered");
        _flag(hook.unclaimedPayout(DEAD) == 0, "burn still recorded");
        _flag(hook.totalBurned() - burnedBefore == s.unclaimedDead + burn, "totalBurned not updated");
        uint256 owedWinner = s.unclaimedLeader + prize;
        if (s.leader == rejecter) {
            _flag(hook.unclaimedPayout(s.leader) == owedWinner, "rejecting winner prize not parked");
            _flag(hook.totalPrizesPaid() == prizesBefore, "parked prize counted as paid");
            if (owedWinner > 0) {
                ghostParkedEvents++;
                _checkParkedClock(s.leader);
            }
        } else {
            _flag(s.leader.balance - winnerBefore == owedWinner, "winner did not receive the prize");
            _flag(hook.unclaimedPayout(s.leader) == 0, "paid prize still recorded");
            _flag(hook.totalPrizesPaid() - prizesBefore == owedWinner, "totalPrizesPaid not updated");
        }
        _flag(hook.pendingCreatorFees() == s.pending, "settleRound touched creator fees");
        _snapshotMonotonic();
    }

    function claimPayout(uint256 payeeSeed, uint256 callerSeed) external {
        address[] memory p = this.payees();
        address payee = p[payeeSeed % p.length];
        uint256 owed = hook.unclaimedPayout(payee);
        address caller = _actor(callerSeed);
        if (owed == 0) {
            vm.prank(caller);
            try hook.claimPayout(payee) {
                _flag(false, "claimPayout succeeded with nothing owed");
            } catch (bytes memory reason) {
                _flag(bytes4(reason) == RektJackpotHook.NothingToClaim.selector, "claimPayout wrong revert");
            }
            return;
        }
        uint256 before = payee.balance;
        uint256 callerBefore = caller.balance;
        uint256 burnedBefore = hook.totalBurned();
        uint256 prizesBefore = hook.totalPrizesPaid();
        vm.prank(caller);
        hook.claimPayout(payee);
        _flag(caller.balance == callerBefore || caller == payee, "claimPayout paid the caller instead of the payee");
        if (payee == rejecter) {
            _flag(hook.unclaimedPayout(payee) == owed, "rejected payout was not re-parked in full");
            _flag(payee.balance == before, "rejecter received ETH");
            ghostParkedEvents++;
            _checkParkedClock(payee);
        } else {
            _flag(payee.balance - before == owed, "payee did not receive the owed amount");
            _flag(hook.unclaimedPayout(payee) == 0, "paid amount still recorded");
            if (payee == DEAD) _flag(hook.totalBurned() - burnedBefore == owed, "burn not counted");
            else _flag(hook.totalPrizesPaid() - prizesBefore == owed, "prize not counted");
        }
        _snapshotMonotonic();
    }

    function claimCreatorFees(uint256 callerSeed) external {
        uint256 pending = hook.pendingCreatorFees();
        address caller = _actor(callerSeed);
        if (pending == 0) {
            vm.prank(caller);
            try hook.claimCreatorFees() {
                _flag(false, "claimCreatorFees succeeded with nothing pending");
            } catch (bytes memory reason) {
                _flag(bytes4(reason) == RektJackpotHook.NothingToClaim.selector, "claimCreatorFees wrong revert");
            }
            return;
        }
        address recipient = hook.creatorFeeRecipient();
        uint256 before = recipient.balance;
        uint256 parkedBefore = hook.unclaimedPayout(recipient);
        uint256 jackpotBefore = hook.jackpotPool();
        uint256 claimsBefore = _claims();
        uint256 hookEthBefore = address(hook).balance;
        if (recipient == rejecter) {
            // The claim must fail as a whole: nothing parked, nothing redeemed, pending untouched.
            vm.prank(caller);
            try hook.claimCreatorFees() {
                _flag(false, "claimCreatorFees succeeded for a rejecting recipient");
            } catch (bytes memory reason) {
                _flag(
                    bytes4(reason) == RektJackpotHook.CreatorFeeTransferFailed.selector,
                    "claimCreatorFees wrong revert for a rejecting recipient"
                );
            }
            _flag(hook.pendingCreatorFees() == pending, "failed creator claim changed pending fees");
            _flag(hook.unclaimedPayout(recipient) == parkedBefore, "failed creator claim parked something");
            _flag(_claims() == claimsBefore && address(hook).balance == hookEthBefore, "failed creator claim moved ETH");
            _flag(hook.parkedSince(recipient) == parkedSinceExpected(recipient), "failed creator claim set parkedSince");
            return;
        }
        vm.prank(caller);
        hook.claimCreatorFees();
        _flag(hook.pendingCreatorFees() == 0, "pending creator fees not cleared");
        _flag(hook.jackpotPool() == jackpotBefore, "creator claim touched the jackpot");
        _flag(recipient.balance - before == pending, "creator recipient did not receive the fees");
        _flag(hook.unclaimedPayout(recipient) == parkedBefore, "creator claim changed parked amounts");
        ghostCreatorPaid += pending;
        _snapshotMonotonic();
    }

    /// @dev Returns a payout parked for at least the grace period to the jackpot, after one more
    /// delivery attempt. Anything not parked, or parked too recently, must be refused unchanged.
    function recycleParkedPayout(uint256 payeeSeed, uint256 callerSeed) external {
        address[] memory p = this.payees();
        // Half the calls name the only payee that can ever be parked, so the success path is reached.
        address payee = payeeSeed % 2 == 0 ? rejecter : p[payeeSeed % p.length];
        address caller = _actor(callerSeed);
        uint256 since = hook.parkedSince(payee);
        uint256 owed = hook.unclaimedPayout(payee);
        uint256 poolBefore = hook.jackpotPool();
        uint256 prizesBefore = hook.totalPrizesPaid();
        uint256 hookEthBefore = address(hook).balance;
        uint256 claimsBefore = _claims();
        bool recyclable = since != 0 && block.timestamp >= since + 1 days;

        if (!recyclable) {
            vm.prank(caller);
            try hook.recycleParkedPayout(payee) {
                _flag(false, "recycle succeeded for a payout that is not recyclable");
            } catch (bytes memory reason) {
                _flag(bytes4(reason) == RektJackpotHook.PayoutNotRecyclable.selector, "recycle wrong revert");
            }
            _flag(
                hook.unclaimedPayout(payee) == owed && hook.jackpotPool() == poolBefore, "refused recycle changed state"
            );
            return;
        }
        // Only the rejecter can ever have a parked clock: everyone else accepts ETH on first delivery.
        _flag(payee == rejecter, "an accepting payee had a parked payout");
        _flag(owed > 0, "parked clock running with nothing owed");

        vm.prank(caller);
        hook.recycleParkedPayout(payee);
        ghostRecycled += owed;

        _flag(hook.unclaimedPayout(payee) == 0, "recycled payout still recorded");
        _flag(hook.parkedSince(payee) == 0, "recycled payout still has a parked clock");
        _flag(hook.jackpotPool() == poolBefore + owed, "recycled amount did not go to the jackpot");
        _flag(hook.totalPrizesPaid() == prizesBefore, "recycled amount counted as paid");
        _flag(payee.balance == 0, "rejecter received ETH on recycle");
        _flag(_claims() + address(hook).balance == claimsBefore + hookEthBefore, "recycle moved ETH out of the hook");
        firstParkedAt[payee] = 0;
        _snapshotMonotonic();
    }

    /// @dev The parked clock starts at the first failed delivery and is never restarted by a re-park.
    function _checkParkedClock(address payee) internal {
        if (firstParkedAt[payee] == 0) firstParkedAt[payee] = block.timestamp;
        _flag(hook.parkedSince(payee) == firstParkedAt[payee], "parkedSince is not the first failed delivery");
    }

    function parkedSinceExpected(address payee) public view returns (uint256) {
        return firstParkedAt[payee];
    }

    function setCreatorFeeRecipient(uint256 seed) external {
        address next = seed % 5 == 4 ? OWNER : _actor(seed);
        // A non-owner must be refused first.
        vm.prank(attacker);
        try hook.setCreatorFeeRecipient(attacker) {
            _flag(false, "non-owner changed the creator recipient");
        } catch {}
        _flag(hook.creatorFeeRecipient() != attacker, "attacker became creator recipient");
        vm.prank(OWNER);
        hook.setCreatorFeeRecipient(next);
        _flag(hook.creatorFeeRecipient() == next, "recipient not updated");
    }

    // ------------------------------------------------------------------
    // Actions: things that must always be refused
    // ------------------------------------------------------------------

    /// @dev Nobody but the hook may move its ERC-6909 ETH claims; nobody but the manager may drive a
    /// callback; nobody may push ETH into the hook. Each attempt must fail and change nothing.
    function attack(uint256 which, uint256 amount) external {
        which = bound(which, 0, 4);
        uint256 claimsBefore = _claims();
        uint256 hookEthBefore = address(hook).balance;
        Snap memory s = _snap();
        amount = bound(amount, 1, claimsBefore == 0 ? 1 : claimsBefore);

        bool ok;
        if (which == 0) {
            vm.prank(attacker);
            try manager.transferFrom(address(hook), attacker, ETH_ID, amount) returns (bool r) {
                ok = r;
            } catch {}
        } else if (which == 1) {
            vm.prank(attacker);
            try manager.burn(address(hook), ETH_ID, amount) {
                ok = true;
            } catch {}
        } else if (which == 2) {
            vm.prank(attacker);
            try hook.unlockCallback(abi.encode(amount)) {
                ok = true;
            } catch {}
        } else if (which == 3) {
            SwapParams memory params = SwapParams(true, -int256(amount), TickMath.MIN_SQRT_PRICE + 1);
            vm.prank(attacker);
            try hook.afterSwap(attacker, key, params, BalanceDelta.wrap(0), abi.encode(attacker)) {
                ok = true;
            } catch {}
            vm.prank(attacker);
            try hook.beforeSwap(attacker, key, params, "") {
                ok = true;
            } catch {}
        } else {
            vm.deal(attacker, 1 ether);
            vm.prank(attacker);
            (ok,) = address(hook).call{value: 1}("");
        }
        _flag(!ok, "an attack call succeeded");
        _flag(_claims() == claimsBefore, "attack moved the hook's claims");
        _flag(address(hook).balance == hookEthBefore, "attack changed the hook's ETH");
        _flag(hook.jackpotPool() == s.pool && hook.pendingCreatorFees() == s.pending, "attack changed accounting");
        _flag(hook.currentLeader() == s.leader && hook.roundEndTime() == s.endTime, "attack changed the round");
    }
}

/// @notice Stateful fuzzing of RektJackpotHook: random sequences of swaps of all four shapes, time
/// warps, settlements, claims, recipient changes and refused attacks, with the properties below checked
/// after every call.
contract RektJackpotHookInvariantTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    address constant OWNER = 0x08cD4437B077928E7fA09CF7dcDf3F7624743Bd2;
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 constant ETH_ID = 0;

    PoolManager manager;
    RektdToken token;
    RektJackpotHook hook;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;
    PoolKey key;
    RektJackpotHandler handler;

    receive() external payable {}

    function setUp() public {
        manager = new PoolManager(address(this));
        token = new RektdToken();
        hook = _deployHook();
        swapRouter = new PoolSwapTest(manager);
        lpRouter = new PoolModifyLiquidityTest(manager);
        token.approve(address(lpRouter), type(uint256).max);
        vm.deal(address(this), 100_000_000 ether);

        key = PoolKey({
            currency0: CurrencyLibrary.ADDRESS_ZERO,
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
        vm.prank(address(0xFAC7));
        manager.initialize(key, SQRT_PRICE_1_1);
        // Deep liquidity (about one million ETH and tokens) so bounded swaps never exhaust the pool.
        lpRouter.modifyLiquidity{value: 2_000_000 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: 1e24,
                salt: 0
            }),
            ""
        );

        address rejecter = address(new RejectingPayee());
        address[] memory actors = new address[](4);
        actors[0] = address(0xA11CE);
        actors[1] = address(0xB0B);
        actors[2] = address(0xCA201);
        actors[3] = rejecter;
        handler = new RektJackpotHandler(manager, hook, token, swapRouter, key, actors, rejecter);
        vm.deal(address(handler), 10_000_000 ether);
        token.transfer(address(handler), 1e26);

        targetContract(address(handler));
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

    function _claims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), ETH_ID);
    }

    function _sumUnclaimed() internal view returns (uint256 sum) {
        address[] memory p = handler.payees();
        for (uint256 i = 0; i < p.length; i++) {
            sum += hook.unclaimedPayout(p[i]);
        }
    }

    // ------------------------------------------------------------------
    // Invariants
    // ------------------------------------------------------------------

    /// @dev Every wei the hook owes (creator fees, jackpot, recorded payouts) is backed by an ERC-6909
    /// ETH claim on the manager or ETH already redeemed onto the hook, exactly.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_everyWeiOwedIsBacked() public view {
        uint256 owed = hook.pendingCreatorFees() + hook.jackpotPool() + _sumUnclaimed();
        assertEq(_claims() + address(hook).balance, owed, "hook accounting is not backed by claims plus ETH");
    }

    /// @dev Fees are conserved: everything ever collected is either still owed or has been delivered.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_feesAreConserved() public view {
        uint256 stillOwed = hook.pendingCreatorFees() + hook.jackpotPool() + _sumUnclaimed();
        uint256 delivered = handler.ghostCreatorPaid() + hook.totalPrizesPaid() + hook.totalBurned();
        assertEq(hook.totalFeesCollected(), stillOwed + delivered, "fees collected != owed + delivered");
    }

    /// @dev The manager always holds the ETH behind the hook's claims, and ETH sits on the hook only
    /// while it waits for a recipient that rejected it, or because such a wait ended in a recycle.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ethCustody() public view {
        assertGe(address(manager).balance, _claims(), "manager holds less ETH than the hook's claims");
        assertLe(
            address(hook).balance,
            _sumUnclaimed() + handler.ghostRecycled(),
            "hook holds ETH that is neither a parked payout nor recycled"
        );
        assertEq(token.balanceOf(address(hook)), 0, "hook must never hold REKTD");
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(token)))), 0, "hook holds REKTD claims");
    }

    /// @dev A parked clock runs only while something undeliverable is owed, never in the future, and
    /// only for the payee that rejects ETH; the creator's fees are never parked.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_parkedClockConsistent() public view {
        address[] memory p = handler.payees();
        address rejecter = handler.rejecter();
        for (uint256 i = 0; i < p.length; i++) {
            uint256 since = hook.parkedSince(p[i]);
            if (since == 0) continue;
            assertGt(hook.unclaimedPayout(p[i]), 0, "parked clock running with nothing owed");
            assertLe(since, block.timestamp, "parked clock in the future");
            assertEq(p[i], rejecter, "an accepting payee has a parked clock");
            assertEq(since, handler.firstParkedAt(p[i]), "parked clock restarted");
        }
    }

    /// @dev Round state is consistent: a leader and a countdown exist together; the leader is a real
    /// buyer; the countdown never reaches more than 600 seconds ahead.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_roundStateIsConsistent() public view {
        address leader = hook.currentLeader();
        uint256 end = hook.roundEndTime();
        assertEq(leader == address(0), end == 0, "leader and countdown out of sync");
        assertTrue(leader != DEAD, "burn address is the leader");
        if (leader != address(0)) {
            assertLe(end, block.timestamp + 600, "countdown further than 600 seconds ahead");
            bool known;
            address[] memory p = handler.payees();
            for (uint256 i = 0; i < p.length; i++) {
                if (p[i] == leader) known = true;
            }
            assertTrue(known, "leader is not one of the buyers");
            assertEq(hook.roundExpired(), block.timestamp > end, "roundExpired disagrees with the countdown");
        } else {
            assertFalse(hook.roundExpired(), "no round but expired");
            assertEq(hook.timeRemaining(), 0, "no round but time remaining");
        }
        assertGe(hook.roundId(), handler.ghostRoundsStarted(), "fewer rounds than observed starts");
    }

    /// @dev Jackpot arithmetic: the split always sums to the pool and the ticket floor holds.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_jackpotArithmetic() public view {
        (uint256 prize, uint256 burn, uint256 rollover) = hook.jackpotSplit();
        uint256 pool = hook.jackpotPool();
        assertEq(prize + burn + rollover, pool, "split does not sum to the pool");
        assertEq(prize, pool * 6_000 / 10_000, "prize is not 60%");
        assertEq(burn, pool * 2_000 / 10_000, "burn is not 20%");
        uint256 ticket = hook.minimumTicket();
        assertGe(ticket, 0.0005 ether, "ticket below the floor");
        assertGe(ticket * 20, pool, "ticket below 5% of the jackpot");
        assertTrue(ticket == 0.0005 ether || (ticket - 1) * 20 < pool, "ticket above max(floor, ceil(5%))");
    }

    /// @dev Every per-call postcondition the handler checked held: exact amounts paid and received, 1%
    /// fee on the right side, ticket and extension rules, settlement splits, parking, monotonic totals,
    /// and every refused attack.
    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 60
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_handlerPostconditionsHeld() public view {
        assertFalse(handler.violated(), handler.violation());
    }
}
