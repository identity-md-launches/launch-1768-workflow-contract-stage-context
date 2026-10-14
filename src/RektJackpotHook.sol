// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {SafeCast} from "v4-core/src/libraries/SafeCast.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";

/// @title RektJackpotHook
/// @notice Uniswap v4 hook for the REKTD / native ETH pool. Charges a 1% hook fee in ETH on every
/// swap, splits it between the creator and a jackpot, and runs a 10-minute "king of the hill" blitz
/// round: every qualifying buy makes the buyer the current leader and extends the countdown; when it
/// runs out the leader wins 60% of the jackpot, 20% is burned and 20% rolls over.
/// @dev Fee accounting never moves ETH inside a swap. The fee is minted to this contract as an
/// ERC-6909 claim on the PoolManager in afterSwap, and only the permissionless claim functions
/// (settleRound, claimCreatorFees, claimPayout) unlock the manager, burn claims and move real ETH.
/// The hook accepts swaps from any router and makes no assumption about who the swap sender is.
contract RektJackpotHook is IHooks, IUnlockCallback, Ownable, ReentrancyGuard {
    using SafeCast for uint256;
    using SafeCast for int256;
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ---------------------------------------------------------------------
    // Constants
    // ---------------------------------------------------------------------

    /// @notice Basis points denominator.
    uint256 public constant BPS = 10_000;
    /// @notice Hook fee on the ETH side of every swap: 1%.
    uint256 public constant FEE_BPS = 100;
    /// @notice Share of each fee that goes to the creator: 50% (0.5% of volume). The rest feeds the jackpot.
    uint256 public constant CREATOR_SHARE_BPS = 5_000;
    /// @notice Share of the jackpot paid to the leader when a round ends.
    uint256 public constant WINNER_BPS = 6_000;
    /// @notice Share of the jackpot burned when a round ends.
    uint256 public constant BURN_BPS = 2_000;
    /// @notice Share of the jackpot kept as the next round's seed (the remainder after winner and burn).
    uint256 public constant ROLLOVER_BPS = 2_000;
    /// @notice Length of a fresh round, and the cap on how far a round can be extended into the future.
    uint256 public constant ROUND_DURATION = 600;
    /// @notice Seconds added to the countdown by every qualifying buy.
    uint256 public constant EXTENSION = 120;
    /// @notice Smallest gross ETH buy that can ever take the lead.
    uint256 public constant MIN_TICKET_FLOOR = 0.0005 ether;
    /// @notice A ticket must also be at least this share of the current jackpot: 5%.
    uint256 public constant TICKET_POOL_BPS = 500;
    /// @notice Where the burned share is sent.
    address public constant BURN_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    // ---------------------------------------------------------------------
    // Immutable and storage
    // ---------------------------------------------------------------------

    /// @notice The Uniswap v4 PoolManager this hook serves.
    IPoolManager public immutable poolManager;

    /// @notice Receives the creator half of every fee.
    address public creatorFeeRecipient;

    /// @notice True once the launch pool has been initialized through this hook. Only one pool may use it.
    bool public poolInitialized;
    /// @notice Id of the launch pool.
    PoolId public poolId;
    /// @notice The launch token, read from the pool key at initialization (the currency that is not ETH).
    Currency public launchToken;

    /// @notice ETH owed to the creator, held as ERC-6909 claims (or ETH on this contract) until claimed.
    uint256 public pendingCreatorFees;
    /// @notice ETH in the jackpot for the current round (includes rollover from earlier rounds).
    uint256 public jackpotPool;
    /// @notice Payouts recorded but not yet delivered: winner prizes, burn amounts, and parked transfers.
    mapping(address => uint256) public unclaimedPayout;

    /// @notice Buyer currently holding the lead; zero when no round is running.
    address public currentLeader;
    /// @notice Timestamp at which the current round ends; zero when no round is running.
    uint256 public roundEndTime;
    /// @notice Number of rounds started so far; the id of the running (or last) round.
    uint256 public roundId;

    /// @notice Lifetime totals for dashboards.
    uint256 public totalFeesCollected;
    uint256 public totalBurned;
    uint256 public totalPrizesPaid;

    // ---------------------------------------------------------------------
    // Events and errors
    // ---------------------------------------------------------------------

    event PoolRegistered(PoolId indexed poolId, Currency launchToken, uint24 fee, int24 tickSpacing);
    event FeeCollected(uint256 fee, uint256 creatorShare, uint256 jackpotShare, bool isBuy);
    event RoundStarted(uint256 indexed roundId, address indexed leader, uint256 endsAt);
    event LeaderUpdated(uint256 indexed roundId, address indexed leader, uint256 grossEthIn, uint256 endsAt);
    event RoundSettled(
        uint256 indexed roundId, address indexed winner, uint256 prize, uint256 burned, uint256 rollover
    );
    event PayoutSent(address indexed recipient, uint256 amount);
    event PayoutParked(address indexed recipient, uint256 amount);
    event CreatorFeesClaimed(address indexed recipient, uint256 amount);
    event CreatorFeeRecipientUpdated(address indexed previous, address indexed current);

    error NotPoolManager();
    error PoolAlreadyRegistered();
    error NotNativeEthPair();
    error RoundNotOver();
    error NothingToClaim();
    error ZeroAddress();
    error EthNotAccepted();

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    /// @param poolManager_ The chain's Uniswap v4 PoolManager (manifest: "$poolManager").
    /// @param owner_ The launch owner (manifest: "$owner"). Also the initial creator fee recipient.
    constructor(IPoolManager poolManager_, address owner_) Ownable(owner_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        creatorFeeRecipient = owner_;
        emit CreatorFeeRecipientUpdated(address(0), owner_);
    }

    // ---------------------------------------------------------------------
    // Hook permissions
    // ---------------------------------------------------------------------

    /// @notice Permissions encoded in this hook's address.
    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    /// @notice Smallest gross ETH buy that takes the lead: max(0.0005 ETH, 5% of the jackpot, rounded up).
    function minimumTicket() public view returns (uint256) {
        uint256 share = (jackpotPool * TICKET_POOL_BPS + BPS - 1) / BPS;
        return share > MIN_TICKET_FLOOR ? share : MIN_TICKET_FLOOR;
    }

    /// @notice True when a round has a leader and its countdown has run out.
    function roundExpired() public view returns (bool) {
        return currentLeader != address(0) && block.timestamp > roundEndTime;
    }

    /// @notice Seconds left in the current round, zero when none is running or it has expired.
    function timeRemaining() external view returns (uint256) {
        if (currentLeader == address(0) || block.timestamp >= roundEndTime) return 0;
        return roundEndTime - block.timestamp;
    }

    /// @notice How the current jackpot would split if the round ended now.
    function jackpotSplit() external view returns (uint256 prize, uint256 burn, uint256 rollover) {
        return _split(jackpotPool);
    }

    // ---------------------------------------------------------------------
    // Owner
    // ---------------------------------------------------------------------

    /// @notice Changes where future creator fee claims are sent. Fees already parked under the old
    /// recipient in `unclaimedPayout` stay claimable for that address.
    function setCreatorFeeRecipient(address recipient) external onlyOwner {
        if (recipient == address(0)) revert ZeroAddress();
        emit CreatorFeeRecipientUpdated(creatorFeeRecipient, recipient);
        creatorFeeRecipient = recipient;
    }

    // ---------------------------------------------------------------------
    // Hook callbacks
    // ---------------------------------------------------------------------

    /// @inheritdoc IHooks
    function beforeInitialize(address, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (poolInitialized) revert PoolAlreadyRegistered();
        if (!key.currency0.isAddressZero()) revert NotNativeEthPair();
        poolInitialized = true;
        poolId = key.toId();
        launchToken = key.currency1;
        emit PoolRegistered(poolId, key.currency1, key.fee, key.tickSpacing);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    /// @dev Settles an expired round into `unclaimedPayout` (no external calls), then charges the fee
    /// on the specified side when the specified currency is ETH. Any router is accepted.
    function beforeSwap(address, PoolKey calldata, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _settleExpiredRound();
        if (_ethIsSpecified(params)) {
            uint256 fee = _feeOn(_abs(params.amountSpecified));
            return (IHooks.beforeSwap.selector, toBeforeSwapDelta(fee.toInt128(), 0), 0);
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    /// @inheritdoc IHooks
    /// @dev Mints the fee (from either side) to this contract as an ERC-6909 ETH claim, splits it,
    /// and processes the buy as a jackpot ticket. Never calls take or transfers ETH.
    function afterSwap(
        address,
        PoolKey calldata,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata hookData
    ) external onlyPoolManager returns (bytes4, int128) {
        uint256 minTicket = minimumTicket();
        uint256 fee;
        uint256 grossEthIn;
        int128 unspecifiedDelta;

        if (_ethIsSpecified(params)) {
            // Exact-input buy or exact-output sell: the fee was already taken through beforeSwap.
            uint256 specified = _abs(params.amountSpecified);
            fee = _feeOn(specified);
            if (params.zeroForOne) grossEthIn = specified;
        } else {
            // Exact-output buy or exact-input sell: the ETH side is the unspecified currency.
            uint256 ethMoved = _abs(int256(delta.amount0()));
            fee = _feeOn(ethMoved);
            unspecifiedDelta = fee.toInt128();
            if (params.zeroForOne) grossEthIn = ethMoved + fee;
        }

        if (fee > 0) {
            poolManager.mint(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), fee);
            uint256 creatorShare = fee * CREATOR_SHARE_BPS / BPS;
            uint256 jackpotShare = fee - creatorShare;
            pendingCreatorFees += creatorShare;
            jackpotPool += jackpotShare;
            totalFeesCollected += fee;
            emit FeeCollected(fee, creatorShare, jackpotShare, params.zeroForOne);
        }

        if (params.zeroForOne && grossEthIn >= minTicket) {
            _processTicket(grossEthIn, hookData);
        }

        return (IHooks.afterSwap.selector, unspecifiedDelta);
    }

    /// @inheritdoc IHooks
    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external pure returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    /// @inheritdoc IHooks
    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        revert HookNotImplemented();
    }

    error HookNotImplemented();

    // ---------------------------------------------------------------------
    // Permissionless settlement and claims
    // ---------------------------------------------------------------------

    /// @notice Ends an expired round and pays the winner and the burn address in ETH.
    /// @dev Reverts when no round has expired. A prize the winner cannot receive is parked in
    /// `unclaimedPayout[winner]` and can be retried through `claimPayout`.
    function settleRound() external nonReentrant {
        if (!roundExpired()) revert RoundNotOver();
        address winner = currentLeader;
        _settleExpiredRound();
        _deliver(winner);
        _deliver(BURN_ADDRESS);
    }

    /// @notice Sends the creator's accumulated fees to `creatorFeeRecipient`.
    function claimCreatorFees() external nonReentrant {
        uint256 amount = pendingCreatorFees;
        if (amount == 0) revert NothingToClaim();
        pendingCreatorFees = 0;
        address recipient = creatorFeeRecipient;
        _withdrawFromManager(amount);
        if (_send(recipient, amount)) {
            emit CreatorFeesClaimed(recipient, amount);
        } else {
            unclaimedPayout[recipient] += amount;
            emit PayoutParked(recipient, amount);
        }
    }

    /// @notice Delivers everything recorded in `unclaimedPayout[recipient]`: a prize settled during a
    /// swap, a burn amount, or a transfer that was parked because the recipient rejected ETH.
    function claimPayout(address recipient) external nonReentrant {
        if (unclaimedPayout[recipient] == 0) revert NothingToClaim();
        _deliver(recipient);
    }

    /// @inheritdoc IUnlockCallback
    /// @dev Only reachable from this contract's own `poolManager.unlock` calls: burns the hook's ETH
    /// claims and takes the ETH to this contract.
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        poolManager.burn(address(this), CurrencyLibrary.ADDRESS_ZERO.toId(), amount);
        poolManager.take(CurrencyLibrary.ADDRESS_ZERO, address(this), amount);
        return "";
    }

    /// @dev Only the PoolManager pays this contract (through `take`). Anything else is refused so the
    /// contract's ETH balance always backs recorded payouts and nothing else.
    receive() external payable {
        if (msg.sender != address(poolManager)) revert EthNotAccepted();
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    /// @dev Records an expired round's outcome without any external call.
    function _settleExpiredRound() internal {
        if (!roundExpired()) return;
        address winner = currentLeader;
        (uint256 prize, uint256 burn, uint256 rollover) = _split(jackpotPool);
        jackpotPool = rollover;
        unclaimedPayout[winner] += prize;
        unclaimedPayout[BURN_ADDRESS] += burn;
        emit RoundSettled(roundId, winner, prize, burn, rollover);
        currentLeader = address(0);
        roundEndTime = 0;
    }

    function _split(uint256 pool) internal pure returns (uint256 prize, uint256 burn, uint256 rollover) {
        prize = pool * WINNER_BPS / BPS;
        burn = pool * BURN_BPS / BPS;
        rollover = pool - prize - burn;
    }

    function _processTicket(uint256 grossEthIn, bytes calldata hookData) internal {
        address buyer = _resolveBuyer(hookData);
        // Quoter eth_calls with no sender resolve to zero; the burn address is never a player.
        if (buyer == address(0) || buyer == BURN_ADDRESS) return;

        uint256 cap = block.timestamp + ROUND_DURATION;
        if (currentLeader == address(0)) {
            roundId += 1;
            roundEndTime = cap;
            emit RoundStarted(roundId, buyer, cap);
        } else {
            uint256 extended = roundEndTime + EXTENSION;
            roundEndTime = extended > cap ? cap : extended;
        }
        currentLeader = buyer;
        emit LeaderUpdated(roundId, buyer, grossEthIn, roundEndTime);
    }

    /// @dev 32-byte hookData carries the buyer; otherwise the transaction origin is the buyer.
    function _resolveBuyer(bytes calldata hookData) internal view returns (address) {
        if (hookData.length == 32) {
            uint256 raw = uint256(bytes32(hookData));
            if (raw > type(uint160).max) return address(0);
            return address(uint160(raw));
        }
        return tx.origin;
    }

    /// @dev Pays out and clears `unclaimedPayout[recipient]`; re-parks it when the transfer fails.
    function _deliver(address recipient) internal {
        uint256 amount = unclaimedPayout[recipient];
        if (amount == 0) return;
        unclaimedPayout[recipient] = 0;
        _withdrawFromManager(amount);
        if (_send(recipient, amount)) {
            if (recipient == BURN_ADDRESS) totalBurned += amount;
            else totalPrizesPaid += amount;
            emit PayoutSent(recipient, amount);
        } else {
            unclaimedPayout[recipient] = amount;
            emit PayoutParked(recipient, amount);
        }
    }

    /// @dev Makes sure this contract holds `amount` of ETH, redeeming ERC-6909 claims for the shortfall.
    function _withdrawFromManager(uint256 amount) internal {
        uint256 held = address(this).balance;
        if (held >= amount) return;
        poolManager.unlock(abi.encode(amount - held));
    }

    function _send(address to, uint256 amount) internal returns (bool ok) {
        (ok,) = to.call{value: amount}("");
    }

    /// @dev The specified currency is currency0 (ETH) for exact-input buys and exact-output sells.
    function _ethIsSpecified(SwapParams calldata params) internal pure returns (bool) {
        return params.zeroForOne == (params.amountSpecified < 0);
    }

    function _feeOn(uint256 ethAmount) internal pure returns (uint256) {
        return ethAmount * FEE_BPS / BPS;
    }

    function _abs(int256 x) internal pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }
}
