# REKTD launch: token and RektJackpotHook

Contracts for the REKTD launch on Robinhood Chain (chain id 4663): a fixed-supply ERC-20 and a
Uniswap v4 hook that charges a 1% ETH fee on every swap of the REKTD / native ETH pool, splits it
between the creator and a jackpot, and runs a 10-minute "king of the hill" blitz round.

This repository is the contract stage only. The web dashboard, the launch manifest (`launch.json`),
publication, attestation and deployment are later steps owned by other assignments and by IMD's
deployer. No `launch.json` is written here on purpose.

| Contract            | File                        | Role                                                            |
| ------------------- | --------------------------- | --------------------------------------------------------------- |
| `RektdToken`        | `src/RektdToken.sol`        | REKTD, 1,000,000,000 tokens at 18 decimals, minted once to the deployer (the launch factory). |
| `RektJackpotHook`   | `src/RektJackpotHook.sol`   | The v4 hook: fee, jackpot, countdown, settlement and claims.     |
| `HookFlags`         | `src/HookFlags.sol`         | Internal library of hook-address permission bits used by tests. |

ABI exports: `docs/abi/RektJackpotHook.json`, `docs/abi/RektdToken.json` (from `forge inspect`).

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `evm_version = "cancun"`, `bytecode_hash = "none"`,
`optimizer_runs = 200`, no `ffi`, no `fs_permissions`, and the fuzz seed the verifier uses. All
dependencies are vendored as ordinary files under `lib/` (no submodules):

| Library                 | Source                                            | Commit         |
| ----------------------- | ------------------------------------------------- | -------------- |
| v4-core (`src/`, `test/utils/CurrencySettler.sol` etc.) | github.com/Uniswap/v4-core        | `46c6834`      |
| forge-std               | github.com/foundry-rs/forge-std                   | `0258fe8`      |
| openzeppelin-contracts  | github.com/OpenZeppelin/openzeppelin-contracts    | v5.4.0         |
| solmate (v4-core needs `Owned`) | github.com/transmissions11/solmate        | `89365b8`      |

v4-periphery is not vendored: its current main no longer ships `BaseHook`, so the hook implements
`IHooks` from v4-core directly, with every callback it does not enable reverting
`HookNotImplemented` and every enabled one gated to the PoolManager.

## Constructor arguments (for the manifest step)

`RektdToken` takes no constructor arguments.

`RektJackpotHook(IPoolManager poolManager_, address owner_)`

| Argument        | Manifest value   | Meaning                                                                 |
| --------------- | ---------------- | ----------------------------------------------------------------------- |
| `poolManager_`  | `"$poolManager"` | The chain's Uniswap v4 PoolManager. Never hardcoded; tests deploy their own. |
| `owner_`        | `"$owner"`       | Launch owner `0x08cD4437B077928E7fA09CF7dcDf3F7624743Bd2`. Also the initial `creatorFeeRecipient`. |

The constructor makes no external calls and only rejects a zero PoolManager. `msg.sender` (the
factory) and `tx.origin` are never used for ownership. The hook does not take the token as a
constructor argument: it reads it from the pool key in `beforeInitialize` as the currency that is
not ETH.

Launch terms used by the hook and its tests: pair = native ETH (`currency0 = address(0)`), LP fee
12500 (1.25%), tick spacing 60. `beforeInitialize` accepts any fee and spacing; it only requires
`currency0` to be native ETH and refuses a second pool on the same hook.

## Hook configuration (OpenZeppelin Wizard record)

```json
{
  "hook": "BaseHook",
  "name": "RektJackpotHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": true,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "ownable",
  "info": { "license": "MIT" }
}
```

Address flags: `0x20CC` (beforeInitialize | beforeSwap | afterSwap | beforeSwapReturnDelta |
afterSwapReturnDelta). The deployer mines a CREATE2 salt for these bits; the tests do the same.

Callbacks beyond the brief's list: the brief named `beforeSwap`, `afterSwap` and both swap return
deltas. `beforeInitialize` was added because every IMD hook launch needs an initialization callback
so nobody can open the predicted pool before the factory deploys the hook; here it also pins the
hook to a single native-ETH pool and records the launch token. No liquidity or donate callbacks are
enabled, so the factory's fee collect (a zero liquidity change) is never touched by the hook.

## The fee

Every swap pays a hook fee of 1% (`FEE_BPS = 100`) on the ETH side, on top of the pool's 1.25% LP
fee. It is always taken in ETH, never in REKTD, and nothing is converted later:

| Swap shape                     | Where the fee is taken                          | Formula                                   |
| ------------------------------ | ----------------------------------------------- | ----------------------------------------- |
| Buy, exact input (ETH in)      | `beforeSwap` return delta on the specified side | 1% of the ETH the trader sends; the pool swaps the other 99%. |
| Sell, exact output (ETH out)   | `beforeSwap` return delta on the specified side | 1% of the ETH the trader asked for; the pool outputs that much more; the trader receives exactly the amount asked. |
| Buy, exact output (REKTD out)  | `afterSwap` return delta on the unspecified side| 1% of the ETH the pool took; the trader pays it on top. |
| Sell, exact input (REKTD in)   | `afterSwap` return delta on the unspecified side| 1% of the ETH the pool paid out; the trader receives the other 99%. |

In `afterSwap` the hook mints itself an ERC-6909 claim on the PoolManager for the fee
(`poolManager.mint(address(this), 0, fee)`), which zeroes the delta the return values credited it.
It never calls `take`, never transfers ETH and never needs the manager to hold ETH, so the first
buy on a pool seeded with tokens only works (tested). Because the deltas are fixed functions of the
swap parameters, the V4Quoter returns the exact net amounts.

Each fee splits 50/50: `pendingCreatorFees` for `creatorFeeRecipient` and `jackpotPool`. The
creator share is withdrawn by anyone calling `claimCreatorFees()`, which unlocks the manager, burns
the claim, takes the ETH to the hook and forwards it to `creatorFeeRecipient`.

## The jackpot round

Constants (all in `RektJackpotHook`):

| Constant            | Value        | Meaning                                                   |
| ------------------- | ------------ | --------------------------------------------------------- |
| `ROUND_DURATION`    | 600 s        | Length of a fresh round and the cap on any extension.     |
| `EXTENSION`         | 120 s        | Added to the countdown by each qualifying buy.            |
| `MIN_TICKET_FLOOR`  | 0.0005 ETH   | Floor of `minimumTicket()`.                               |
| `TICKET_POOL_BPS`   | 500 (5%)     | `minimumTicket() = max(floor, ceil(5% of jackpotPool))`.   |
| `WINNER_BPS`        | 6000         | Winner's share of the jackpot at settlement.              |
| `BURN_BPS`          | 2000         | Share sent to `0x000000000000000000000000000000000000dEaD`. |
| `ROLLOVER_BPS`      | 2000         | Share kept in `jackpotPool` for the next round.           |

Rules:

- A buy (ETH to REKTD) whose gross ETH input is at least `minimumTicket()` makes the resolved
  buyer `currentLeader`. Gross input is the amount sent on an exact-input buy, and pool input plus
  fee on an exact-output buy. The minimum ticket is evaluated against `jackpotPool` as it stood
  before this swap's fee was added, which is what a dashboard reading `minimumTicket()` shows.
- The buyer is the address in `hookData` when it is exactly 32 bytes, else `tx.origin`. A zero or
  `dEaD` buyer (for example a quoter `eth_call` with no sender) is charged the fee but does not take
  the lead, and no revert happens. `hookData` of any other length, or 32 bytes that are not a clean
  address, also falls back without reverting.
- A qualifying buy with no running round starts one: `roundEndTime = now + 600`, `roundId + 1`.
  With a running round it extends `roundEndTime` by 120 s, capped at `now + 600`.
- A round is expired when `currentLeader != 0 && block.timestamp > roundEndTime`. `beforeSwap`
  settles an expired round first, recording the prize in `unclaimedPayout[leader]` and the burn in
  `unclaimedPayout[dEaD]` with no external calls, so the current swap can open the next round.
- `settleRound()` (anyone) settles an expired round and pays the winner and the burn address in
  ETH. `claimPayout(address)` (anyone) delivers whatever `unclaimedPayout[address]` holds.

Sells never affect the round. Nothing in the hook uses randomness.

## ETH custody and failure handling

Everything the hook owes is held as ERC-6909 ETH claims on the PoolManager, plus any ETH already
redeemed and sitting on the hook. The tested invariant is
`claims + hook.balance == pendingCreatorFees + jackpotPool + sum(unclaimedPayout)`.

- Claims are redeemed only in `settleRound`, `claimCreatorFees` and `claimPayout`, through
  `poolManager.unlock`; `unlockCallback` burns the claim and takes ETH to the hook. The hook's
  `receive` accepts ETH only from the PoolManager, so stray ETH cannot distort the accounting.
- If a recipient rejects ETH, the amount is parked in `unclaimedPayout[recipient]` and the call
  does not revert, so a rejecting winner or creator wallet can never block settlement. A parked
  amount can be retried with `claimPayout`; a contract that always rejects keeps it parked for good.
- The burn address has no code, so the burn transfer always succeeds. `totalBurned` counts ETH
  actually delivered there.
- All three claim functions are `nonReentrant`; state is updated before any transfer.

## After launch: operational responsibilities

Nothing needs configuring for the hook to work: `$owner` becomes both owner and
`creatorFeeRecipient` at deployment. Ongoing operations, all permissionless unless noted:

| Action                         | Who       | Notes                                                                  |
| ------------------------------ | --------- | ---------------------------------------------------------------------- |
| `settleRound()`                | anyone    | Once a round expires. The dashboard exposes it; nothing settles by itself without a call or a swap. |
| `claimPayout(address)`         | anyone    | For prizes and burns settled inside a swap, and for parked transfers.  |
| `claimCreatorFees()`           | anyone    | Sends accumulated creator fees to `creatorFeeRecipient`.               |
| `setCreatorFeeRecipient(addr)` | owner     | Emits `CreatorFeeRecipientUpdated`; rejects the zero address. Amounts already parked under the old recipient stay claimable for it. |

The owner has no other power: no pause, no fee change, no withdrawal of the jackpot, no upgrade.
The token has no owner at all.

## Assumptions and choices the brief left open

- `tx.origin` as the fallback buyer identity is what the brief specifies so the canonical
  UniversalRouter works with empty `hookData`. It is identity for a prize, not authorization, but a
  contract wallet buying through a relayer resolves to the relayer's EOA unless it passes its own
  address in `hookData`; the dashboard should always pass the connected wallet as 32-byte `hookData`.
- Exact-output fee bases (1% of the pool-side ETH amount) are my choice where the brief says "1% on
  the ETH side"; the table above is the exact definition.
- `jackpotPool` is read before the swap's own fee for the ticket threshold (choice documented above).
- No router allowlist, as the brief requires. Any router and any quoter can swap and quote.
- The hook accepts initialization from any sender (the factory included) and does not take a
  `$factory` argument; it refuses only non-ETH pairs and a second pool.

## What the brief asked that the token does not do

Nothing extra was asked of the token itself: REKTD is a standard fixed-supply ERC-20 with no
mint, owner, pause, blocklist, fee or upgrade function. All fee logic lives in the hook. The supply
split (80% pool, 10% swarm distributor, 10% payer) is done by the factory, not by these contracts.

## Tests

`test/RektdToken.t.sol` (6) and `test/RektJackpotHook.t.sol` (36, three of them fuzzed) cover:
supply and transfer; permissions versus address bits; every enabled callback refusing callers other
than the PoolManager; single-pool and ETH-pair initialization rules; the fee on all four swap shapes,
including a sell that stops at a price limit and a buy on a fresh PoolManager seeded with tokens
only; ticket thresholds, leader changes, extensions and the cap; buyer resolution from `hookData`,
`tx.origin`, zero, `dEaD` and malformed data; settlement by `settleRound` and inside a later swap;
rejecting recipients being parked and retried; creator fee claims; the backing invariant across a
full cycle.

`test/mocks/`, `test/floor/OwnerChecks.sol` and `src/HookFlags.sol` match what the launch floor
tests under `.imd/reads/protected/univ4_hook/` import; those floor tests were rehearsed locally
against this build (13 passed, including the factory's zero-liquidity fee collect with the hook
live) but they are the verifier's to run.

Not done here, and needed before real funds: an independent adversarial review, Slither or
Mythril runs (not available on this machine), and a fork rehearsal against Robinhood Chain state.
