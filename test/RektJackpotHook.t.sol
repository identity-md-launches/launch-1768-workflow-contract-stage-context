// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test, stdStorage, StdStorage} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {RektJackpotHook} from "../src/RektJackpotHook.sol";
import {RektdToken} from "../src/RektdToken.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @dev A recipient that refuses ETH, to exercise the parking path.
contract RejectEth {
    receive() external payable {
        revert("no");
    }
}

contract RektJackpotHookTest is Test {
    using stdStorage for StdStorage;

    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant POOL_FEE = 12_500;
    int24 constant TICK_SPACING = 60;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;
    uint256 constant ETH_ID = 0;

    address constant OWNER = 0x08cD4437B077928E7fA09CF7dcDf3F7624743Bd2;
    address constant FACTORY = address(0xFAC7);
    address constant DEAD = 0x000000000000000000000000000000000000dEaD;
    address alice = address(0xA11CE);
    address bob = address(0xB0B);

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
        hook = _deployHook(manager);
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
        vm.prank(FACTORY);
        manager.initialize(key, SQRT_PRICE_1_1);
        _addFullRangeLiquidity(1e21);
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _deployHook(PoolManager pm) internal returns (RektJackpotHook) {
        bytes memory creationCode = abi.encodePacked(type(RektJackpotHook).creationCode, abi.encode(pm, OWNER));
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            address predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), bytes32(i), initCodeHash))))
            );
            if (!HookFlags.matches(predicted, FLAGS)) continue;
            RektJackpotHook deployed = new RektJackpotHook{salt: bytes32(i)}(pm, OWNER);
            assertEq(address(deployed), predicted);
            return deployed;
        }
        revert("no salt");
    }

    function _addFullRangeLiquidity(int256 liquidity) internal {
        lpRouter.modifyLiquidity{value: 10_000 ether}(
            key,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING),
                tickUpper: TickMath.maxUsableTick(TICK_SPACING),
                liquidityDelta: liquidity,
                salt: 0
            }),
            ""
        );
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

    function _buyExactIn(uint256 ethIn, bytes memory hookData) internal returns (BalanceDelta) {
        return _swap(true, -int256(ethIn), hookData, ethIn);
    }

    function _buyExactIn(uint256 ethIn) internal returns (BalanceDelta) {
        return _buyExactIn(ethIn, abi.encode(alice));
    }

    function hookClaims() internal view returns (uint256) {
        return manager.balanceOf(address(hook), ETH_ID);
    }

    /// @dev Every wei the hook accounts for is backed by a claim on the manager or ETH it holds.
    function _assertBacked(address[] memory payees) internal view {
        uint256 owed = hook.pendingCreatorFees() + hook.jackpotPool();
        for (uint256 i = 0; i < payees.length; i++) {
            owed += hook.unclaimedPayout(payees[i]);
        }
        assertEq(hookClaims() + address(hook).balance, owed, "hook accounting is not backed");
    }

    function _payees() internal view returns (address[] memory p) {
        p = new address[](5);
        p[0] = alice;
        p[1] = bob;
        p[2] = DEAD;
        p[3] = OWNER;
        p[4] = hook.creatorFeeRecipient();
    }

    // ------------------------------------------------------------------
    // Deployment, permissions and access control
    // ------------------------------------------------------------------

    function test_constructorSetsOwnerAndRecipient() public view {
        assertEq(hook.owner(), OWNER);
        assertEq(hook.creatorFeeRecipient(), OWNER);
        assertEq(address(hook.poolManager()), address(manager));
        assertTrue(hook.owner() != address(this), "deployer must not own the hook");
    }

    function test_constructorRejectsZeroManager() public {
        vm.expectRevert(RektJackpotHook.ZeroAddress.selector);
        new RektJackpotHook(IPoolManager(address(0)), OWNER);
    }

    function test_permissionsMatchAddressFlags() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap);
        assertTrue(p.afterSwap);
        assertTrue(p.beforeSwapReturnDelta);
        assertTrue(p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize);
        assertFalse(p.beforeAddLiquidity);
        assertFalse(p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity);
        assertFalse(p.afterRemoveLiquidity);
        assertFalse(p.beforeDonate);
        assertFalse(p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta);
        assertFalse(p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
    }

    function test_poolRegisteredAtInitialization() public view {
        assertTrue(hook.poolInitialized());
        assertEq(Currency.unwrap(hook.launchToken()), address(token));
    }

    function test_callbacksRefuseNonManager() public {
        SwapParams memory params = SwapParams(true, -1 ether, SQRT_PRICE_1_1 / 2);
        vm.expectRevert(RektJackpotHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);
        vm.expectRevert(RektJackpotHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, params, "");
        vm.expectRevert(RektJackpotHook.NotPoolManager.selector);
        hook.afterSwap(address(this), key, params, BalanceDelta.wrap(0), "");
        vm.expectRevert(RektJackpotHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
    }

    function test_unimplementedCallbacksRevert() public {
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-60, 60, 1, 0);
        vm.expectRevert(RektJackpotHook.HookNotImplemented.selector);
        hook.afterInitialize(address(this), key, SQRT_PRICE_1_1, 0);
        vm.expectRevert(RektJackpotHook.HookNotImplemented.selector);
        hook.beforeAddLiquidity(address(this), key, lp, "");
        vm.expectRevert(RektJackpotHook.HookNotImplemented.selector);
        hook.beforeRemoveLiquidity(address(this), key, lp, "");
        vm.expectRevert(RektJackpotHook.HookNotImplemented.selector);
        hook.beforeDonate(address(this), key, 1, 1, "");
        vm.expectRevert(RektJackpotHook.HookNotImplemented.selector);
        hook.afterDonate(address(this), key, 1, 1, "");
    }

    function test_receiveRefusesEthFromOthers() public {
        (bool ok,) = address(hook).call{value: 1}("");
        assertFalse(ok);
        assertEq(address(hook).balance, 0);
    }

    function test_secondPoolIsRefused() public {
        PoolKey memory other = key;
        other.fee = 3_000;
        vm.prank(FACTORY);
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_nonEthPairIsRefused() public {
        PoolManager fresh = new PoolManager(address(this));
        RektJackpotHook freshHook = _deployHook(fresh);
        MockERC20 a = new MockERC20("A", "A", 0);
        MockERC20 b = new MockERC20("B", "B", 0);
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        PoolKey memory pair =
            PoolKey(Currency.wrap(c0), Currency.wrap(c1), POOL_FEE, TICK_SPACING, IHooks(address(freshHook)));
        vm.expectRevert();
        fresh.initialize(pair, SQRT_PRICE_1_1);
        assertFalse(freshHook.poolInitialized());
    }

    function test_initializeFromAnyFactoryAtLaunchTerms() public {
        PoolManager fresh = new PoolManager(address(this));
        RektJackpotHook freshHook = _deployHook(fresh);
        PoolKey memory launchKey = key;
        launchKey.hooks = IHooks(address(freshHook));
        vm.prank(address(0x1234));
        fresh.initialize(launchKey, SQRT_PRICE_1_1);
        assertTrue(freshHook.poolInitialized());
        assertEq(Currency.unwrap(freshHook.launchToken()), address(token));
    }

    function test_setCreatorFeeRecipient() public {
        vm.prank(alice);
        vm.expectRevert();
        hook.setCreatorFeeRecipient(alice);

        vm.prank(OWNER);
        vm.expectRevert(RektJackpotHook.ZeroAddress.selector);
        hook.setCreatorFeeRecipient(address(0));

        vm.prank(OWNER);
        vm.expectEmit(true, true, false, true);
        emit RektJackpotHook.CreatorFeeRecipientUpdated(OWNER, bob);
        hook.setCreatorFeeRecipient(bob);
        assertEq(hook.creatorFeeRecipient(), bob);
    }

    // ------------------------------------------------------------------
    // Fees on all four swap shapes
    // ------------------------------------------------------------------

    function test_buyExactInput_takesOnePercentOfEthIn() public {
        uint256 ethIn = 1 ether;
        uint256 ethBefore = address(this).balance;
        uint256 tokBefore = token.balanceOf(address(this));

        BalanceDelta delta = _buyExactIn(ethIn);

        assertEq(ethBefore - address(this).balance, ethIn, "trader pays exactly the input");
        assertEq(delta.amount0(), -int256(ethIn));
        assertGt(token.balanceOf(address(this)) - tokBefore, 0);
        assertEq(hookClaims(), ethIn / 100, "hook holds a 1% ETH claim");
        assertEq(hook.pendingCreatorFees(), ethIn / 200);
        assertEq(hook.jackpotPool(), ethIn / 200);
        assertEq(hook.totalFeesCollected(), ethIn / 100);
        assertEq(address(hook).balance, 0, "no ETH moved during the swap");
        _assertBacked(_payees());
    }

    function test_buyExactOutput_feeOnTopOfPoolInput() public {
        uint256 tokensOut = 1 ether;
        uint256 ethBefore = address(this).balance;
        uint256 tokBefore = token.balanceOf(address(this));

        BalanceDelta delta = _swap(true, int256(tokensOut), abi.encode(alice), 10 ether);

        assertEq(token.balanceOf(address(this)) - tokBefore, tokensOut, "exact tokens out");
        uint256 paid = ethBefore - address(this).balance;
        assertEq(uint256(uint128(-delta.amount0())), paid);
        uint256 fee = hookClaims();
        uint256 poolIn = paid - fee;
        assertEq(fee, poolIn / 100, "fee is 1% of the pool's ETH input");
        assertGt(fee, 0);
        _assertBacked(_payees());
    }

    function test_sellExactInput_takesOnePercentOfEthOut() public {
        uint256 tokensIn = 1 ether;
        uint256 ethBefore = address(this).balance;

        BalanceDelta delta = _swap(false, -int256(tokensIn), "", 0);

        uint256 received = address(this).balance - ethBefore;
        assertEq(uint256(uint128(delta.amount0())), received);
        uint256 fee = hookClaims();
        uint256 gross = received + fee;
        assertEq(fee, gross / 100, "fee is 1% of the gross ETH output");
        assertGt(fee, 0);
        assertEq(hook.currentLeader(), address(0), "a sell never takes the lead");
        _assertBacked(_payees());
    }

    function test_sellExactOutput_traderGetsExactEth() public {
        uint256 ethOut = 1 ether;
        uint256 ethBefore = address(this).balance;
        uint256 tokBefore = token.balanceOf(address(this));

        BalanceDelta delta = _swap(false, int256(ethOut), "", 0);

        assertEq(address(this).balance - ethBefore, ethOut, "trader receives exactly the ETH asked for");
        assertEq(delta.amount0(), int256(ethOut));
        assertGt(tokBefore - token.balanceOf(address(this)), ethOut, "trader pays tokens for output plus fee");
        assertEq(hookClaims(), ethOut / 100, "fee is 1% of the ETH asked for");
        _assertBacked(_payees());
    }

    function test_sellExactInput_hittingPriceLimitStillCharges() public {
        uint256 ethBefore = address(this).balance;
        // A limit just above the current price: only part of the input can be sold.
        uint160 limit = uint160(uint256(SQRT_PRICE_1_1) * 1001 / 1000);
        BalanceDelta delta = swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -int256(1_000 ether), sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 received = address(this).balance - ethBefore;
        assertGt(received, 0);
        assertLt(uint256(uint128(-delta.amount1())), 1_000 ether, "partial fill");
        assertEq(hookClaims(), (received + hookClaims()) / 100);
        _assertBacked(_payees());
    }

    function testFuzz_buyExactInput_traderPaysExactlyTheInput(uint256 ethIn) public {
        ethIn = bound(ethIn, 1, 100 ether);
        uint256 ethBefore = address(this).balance;
        _buyExactIn(ethIn, "");
        assertEq(ethBefore - address(this).balance, ethIn);
        assertEq(hookClaims(), ethIn / 100);
        _assertBacked(_payees());
    }

    function testFuzz_sellExactOutput_traderReceivesExactly(uint256 ethOut) public {
        ethOut = bound(ethOut, 1, 100 ether);
        uint256 ethBefore = address(this).balance;
        _swap(false, int256(ethOut), "", 0);
        assertEq(address(this).balance - ethBefore, ethOut);
        assertEq(hookClaims(), ethOut / 100);
        _assertBacked(_payees());
    }

    function test_tinySwapWithZeroFeeStillWorks() public {
        _buyExactIn(50, "");
        assertEq(hookClaims(), 0);
        assertEq(hook.currentLeader(), address(0));
    }

    // ------------------------------------------------------------------
    // Fresh manager seeded with tokens only
    // ------------------------------------------------------------------

    function test_buyOnFreshManagerSeededWithTokensOnly() public {
        PoolManager fresh = new PoolManager(address(this));
        RektJackpotHook freshHook = _deployHook(fresh);
        PoolSwapTest freshSwap = new PoolSwapTest(fresh);
        PoolModifyLiquidityTest freshLp = new PoolModifyLiquidityTest(fresh);
        token.approve(address(freshLp), type(uint256).max);
        token.approve(address(freshSwap), type(uint256).max);
        PoolKey memory k = key;
        k.hooks = IHooks(address(freshHook));
        vm.prank(FACTORY);
        fresh.initialize(k, SQRT_PRICE_1_1);
        // Tokens only: a range entirely below the current tick holds nothing but currency1.
        freshLp.modifyLiquidity(
            k,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(TICK_SPACING), tickUpper: -TICK_SPACING, liquidityDelta: 1e21, salt: 0
            }),
            ""
        );
        assertEq(address(fresh).balance, 0, "manager holds no ETH");

        uint256 ethIn = 0.01 ether;
        uint256 before = address(this).balance;
        freshSwap.swap{value: ethIn}(
            k,
            SwapParams({
                zeroForOne: true, amountSpecified: -int256(ethIn), sqrtPriceLimitX96: TickMath.MIN_SQRT_PRICE + 1
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(alice)
        );
        assertEq(before - address(this).balance, ethIn);
        assertEq(fresh.balanceOf(address(freshHook), ETH_ID), ethIn / 100, "claim minted with no ETH on the manager");
        assertEq(freshHook.currentLeader(), alice);

        // The claim is backed by the swap's settled ETH and can be redeemed right away.
        uint256 ownerBefore = OWNER.balance;
        freshHook.claimCreatorFees();
        assertEq(OWNER.balance - ownerBefore, ethIn / 200);
        assertEq(freshHook.pendingCreatorFees(), 0);
        assertEq(fresh.balanceOf(address(freshHook), ETH_ID), ethIn / 200);
    }

    // ------------------------------------------------------------------
    // Tickets and the countdown
    // ------------------------------------------------------------------

    function test_minimumTicketFloorAndShare() public {
        assertEq(hook.minimumTicket(), 0.0005 ether);
        // 10 ETH of buys put 0.05 ETH in the jackpot: 5% of that is 0.0025 ETH, above the floor.
        _buyExactIn(10 ether);
        assertEq(hook.jackpotPool(), 0.05 ether);
        assertEq(hook.minimumTicket(), 0.0025 ether);
    }

    function testFuzz_minimumTicket(uint256 pool) public {
        pool = bound(pool, 0, 1e24);
        stdstore.target(address(hook)).sig("jackpotPool()").checked_write(pool);
        assertEq(hook.jackpotPool(), pool);
        uint256 expected = (pool * 500 + 9_999) / 10_000;
        if (expected < 0.0005 ether) expected = 0.0005 ether;
        assertEq(hook.minimumTicket(), expected);
    }

    function test_qualifyingBuyStartsRoundAndSetsLeader() public {
        uint256 start = block.timestamp;
        vm.expectEmit(true, true, false, true);
        emit RektJackpotHook.RoundStarted(1, alice, start + 600);
        _buyExactIn(0.0005 ether);
        assertEq(hook.currentLeader(), alice);
        assertEq(hook.roundEndTime(), start + 600);
        assertEq(hook.roundId(), 1);
        assertEq(hook.timeRemaining(), 600);
    }

    function test_buyBelowMinimumTicketDoesNotLead() public {
        _buyExactIn(0.0005 ether - 1);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.roundEndTime(), 0);
        assertGt(hookClaims(), 0, "fee is still charged");
    }

    function test_ticketJudgedAgainstPoolBeforeTheSwap() public {
        _buyExactIn(10 ether); // jackpot 0.05, min ticket 0.0025
        _buyExactIn(0.0025 ether, abi.encode(bob));
        assertEq(hook.currentLeader(), bob);
    }

    function test_exactOutputBuyUsesGrossEthForTicket() public {
        // Gross ETH in = pool input + fee; the ticket is judged on that gross amount.
        _swap(true, int256(0.001 ether), abi.encode(bob), 1 ether);
        assertEq(hook.currentLeader(), bob);
    }

    function test_extensionAddsTwoMinutesCappedAtTen() public {
        uint256 start = block.timestamp;
        _buyExactIn(0.001 ether, abi.encode(alice));
        assertEq(hook.roundEndTime(), start + 600);

        // Immediately again: +120 would exceed now+600, so it stays capped.
        _buyExactIn(0.001 ether, abi.encode(bob));
        assertEq(hook.roundEndTime(), start + 600);
        assertEq(hook.currentLeader(), bob);

        vm.warp(start + 300);
        _buyExactIn(0.001 ether, abi.encode(alice));
        assertEq(hook.roundEndTime(), start + 720, "extended by 120 seconds");
        assertEq(hook.currentLeader(), alice);

        vm.warp(start + 700);
        _buyExactIn(0.001 ether, abi.encode(bob));
        assertEq(hook.roundEndTime(), start + 840);
        assertEq(hook.roundId(), 1, "same round");
    }

    function test_buyerFromTxOriginWhenNoHookData() public {
        vm.prank(address(this), bob);
        _buyExactIn(0.001 ether, "");
        assertEq(hook.currentLeader(), bob);
    }

    function test_zeroAndDeadBuyersAreChargedButSkipped() public {
        _buyExactIn(0.001 ether, abi.encode(address(0)));
        assertEq(hook.currentLeader(), address(0));
        _buyExactIn(0.001 ether, abi.encode(DEAD));
        assertEq(hook.currentLeader(), address(0));
        vm.prank(address(this), address(0));
        _buyExactIn(0.001 ether, "");
        assertEq(hook.currentLeader(), address(0));
        assertEq(hookClaims(), 3 * (0.001 ether / 100), "fees charged on all three");
    }

    function test_malformedHookDataIsIgnoredNotReverted() public {
        _buyExactIn(0.001 ether, hex"0102");
        // tx.origin is forge's default sender here, which is a valid buyer.
        assertTrue(hook.currentLeader() != address(0));
        bytes memory dirty = abi.encodePacked(bytes12(0xffffffffffffffffffffffff), bytes20(alice));
        _buyExactIn(0.001 ether, dirty);
        assertTrue(hook.currentLeader() != alice, "dirty high bits do not resolve to alice");
    }

    // ------------------------------------------------------------------
    // Round settlement and claims
    // ------------------------------------------------------------------

    function test_settleRoundPaysWinnerBurnsAndRollsOver() public {
        _buyExactIn(10 ether, abi.encode(alice));
        uint256 pool = hook.jackpotPool();
        assertEq(pool, 0.05 ether);
        uint256 end = hook.roundEndTime();

        vm.expectRevert(RektJackpotHook.RoundNotOver.selector);
        hook.settleRound();
        vm.warp(end);
        vm.expectRevert(RektJackpotHook.RoundNotOver.selector);
        hook.settleRound();

        vm.warp(end + 1);
        assertTrue(hook.roundExpired());
        uint256 aliceBefore = alice.balance;
        uint256 deadBefore = DEAD.balance;
        vm.expectEmit(true, true, false, true);
        emit RektJackpotHook.RoundSettled(1, alice, pool * 60 / 100, pool * 20 / 100, pool * 20 / 100);
        vm.prank(bob);
        hook.settleRound();

        assertEq(alice.balance - aliceBefore, pool * 60 / 100);
        assertEq(DEAD.balance - deadBefore, pool * 20 / 100);
        assertEq(hook.jackpotPool(), pool * 20 / 100);
        assertEq(hook.totalBurned(), pool * 20 / 100);
        assertEq(hook.totalPrizesPaid(), pool * 60 / 100);
        assertEq(hook.currentLeader(), address(0));
        assertEq(hook.roundEndTime(), 0);
        assertEq(hook.unclaimedPayout(alice), 0);
        assertEq(hook.unclaimedPayout(DEAD), 0);
        assertEq(hookClaims(), hook.pendingCreatorFees() + hook.jackpotPool());
        _assertBacked(_payees());

        // A new round starts with the rolled-over jackpot.
        _buyExactIn(0.001 ether, abi.encode(bob));
        assertEq(hook.roundId(), 2);
        assertEq(hook.currentLeader(), bob);
    }

    function test_expiredRoundSettlesInsideNextSwapWithoutTransfers() public {
        _buyExactIn(10 ether, abi.encode(alice));
        uint256 pool = hook.jackpotPool();
        vm.warp(hook.roundEndTime() + 1);

        uint256 aliceBefore = alice.balance;
        vm.expectEmit(true, true, false, true);
        emit RektJackpotHook.RoundSettled(1, alice, pool * 60 / 100, pool * 20 / 100, pool * 20 / 100);
        _buyExactIn(1 ether, abi.encode(bob));

        assertEq(alice.balance, aliceBefore, "no ETH moved during the swap");
        assertEq(hook.unclaimedPayout(alice), pool * 60 / 100);
        assertEq(hook.unclaimedPayout(DEAD), pool * 20 / 100);
        assertEq(hook.jackpotPool(), pool * 20 / 100 + 1 ether / 200);
        assertEq(hook.currentLeader(), bob, "the next buy opens round 2");
        assertEq(hook.roundId(), 2);
        _assertBacked(_payees());

        vm.expectRevert(RektJackpotHook.RoundNotOver.selector);
        hook.settleRound();

        vm.expectEmit(true, false, false, true);
        emit RektJackpotHook.PayoutSent(alice, pool * 60 / 100);
        hook.claimPayout(alice);
        assertEq(alice.balance - aliceBefore, pool * 60 / 100);
        hook.claimPayout(DEAD);
        assertEq(hook.totalBurned(), pool * 20 / 100);
        vm.expectRevert(RektJackpotHook.NothingToClaim.selector);
        hook.claimPayout(alice);
        _assertBacked(_payees());
    }

    function test_winnerThatRejectsEthIsParked() public {
        address rejecter = address(new RejectEth());
        _buyExactIn(10 ether, abi.encode(rejecter));
        uint256 pool = hook.jackpotPool();
        vm.warp(hook.roundEndTime() + 1);

        vm.expectEmit(true, false, false, true);
        emit RektJackpotHook.PayoutParked(rejecter, pool * 60 / 100);
        hook.settleRound();

        assertEq(hook.unclaimedPayout(rejecter), pool * 60 / 100);
        // The prize was redeemed from the manager and parked on the hook; the burn was then paid out
        // of that held ETH instead of redeeming another claim.
        assertEq(address(hook).balance, pool * 60 / 100 - pool * 20 / 100, "withdrawn ETH waits on the hook");
        assertEq(DEAD.balance, pool * 20 / 100, "the burn still went through");
        address[] memory payees = new address[](2);
        payees[0] = rejecter;
        payees[1] = DEAD;
        _assertBacked(payees);

        // Retrying parks again; nothing is lost and the amount stays claimable.
        uint256 backing = hookClaims() + address(hook).balance;
        hook.claimPayout(rejecter);
        assertEq(hook.unclaimedPayout(rejecter), pool * 60 / 100);
        assertEq(hookClaims() + address(hook).balance, backing);
        _assertBacked(payees);
    }

    function test_claimCreatorFees() public {
        vm.expectRevert(RektJackpotHook.NothingToClaim.selector);
        hook.claimCreatorFees();

        _buyExactIn(2 ether);
        _swap(false, -int256(1 ether), "", 0);
        uint256 pending = hook.pendingCreatorFees();
        assertGt(pending, 0);
        uint256 ownerBefore = OWNER.balance;
        vm.expectEmit(true, false, false, true);
        emit RektJackpotHook.CreatorFeesClaimed(OWNER, pending);
        vm.prank(alice);
        hook.claimCreatorFees();
        assertEq(OWNER.balance - ownerBefore, pending);
        assertEq(hook.pendingCreatorFees(), 0);
        assertEq(hookClaims(), hook.jackpotPool());
        _assertBacked(_payees());
    }

    function test_claimCreatorFeesParksWhenRecipientRejects() public {
        address rejecter = address(new RejectEth());
        vm.prank(OWNER);
        hook.setCreatorFeeRecipient(rejecter);
        _buyExactIn(2 ether);
        uint256 pending = hook.pendingCreatorFees();
        hook.claimCreatorFees();
        assertEq(hook.pendingCreatorFees(), 0);
        assertEq(hook.unclaimedPayout(rejecter), pending);
        assertEq(address(hook).balance, pending);

        // Once the recipient changes, the parked amount is still that address's, and a later claim
        // reuses ETH already on the hook before touching the manager.
        vm.prank(OWNER);
        hook.setCreatorFeeRecipient(OWNER);
        _buyExactIn(2 ether);
        uint256 ownerBefore = OWNER.balance;
        hook.claimCreatorFees();
        assertEq(OWNER.balance - ownerBefore, pending);
        assertEq(address(hook).balance, 0);
        assertEq(hook.unclaimedPayout(rejecter), pending);
        address[] memory payees = new address[](1);
        payees[0] = rejecter;
        _assertBacked(payees);
    }

    function test_fullCycleKeepsAccountingBacked() public {
        for (uint256 i = 0; i < 5; i++) {
            _buyExactIn(1 ether + i, abi.encode(i % 2 == 0 ? alice : bob));
            _swap(false, -int256(0.5 ether), "", 0);
            _swap(true, int256(0.25 ether), abi.encode(bob), 5 ether);
            _swap(false, int256(0.1 ether), "", 0);
            _assertBacked(_payees());
        }
        vm.warp(hook.roundEndTime() + 1);
        hook.settleRound();
        hook.claimCreatorFees();
        _assertBacked(_payees());
        assertEq(hookClaims(), hook.jackpotPool());
        (uint256 prize, uint256 burn, uint256 rollover) = hook.jackpotSplit();
        assertEq(prize + burn + rollover, hook.jackpotPool());
    }
}
