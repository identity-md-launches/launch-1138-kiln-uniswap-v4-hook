# Kiln

A Uniswap v4 hook for a new ETH/ZTO pool on Ethereum mainnet. Wallets holding Pepeolithic (PEPEO) pieces pay a
lower Kiln cut on every swap. The cut everyone pays is kept in ZTO as a reserve, and the reserve buys Pepeolithic
pieces from anyone and sells them back.

Two contracts, both in `src/`:

| Contract   | Role                                                                                                  |
| ---------- | ----------------------------------------------------------------------------------------------------- |
| `Launcher` | Deploys the Kiln with CREATE2 at a mined salt, checks its hook bits, initializes the pool. Runs once. |
| `Kiln`     | The hook. Fee pass, ZTO claims and reserve, piece bid/ask. Nothing upgradeable, pausable or ownable.  |

There is no admin anywhere. The reserve can never be withdrawn, only paid out for pieces.

## Addresses and constants

| Name                         | Value                                        | Where                      |
| ---------------------------- | -------------------------------------------- | -------------------------- |
| ZTO (ERC-20, 18 decimals)    | `0xd782bdea4ef02a0bd391eb9089470c8080f0a68e` | Launcher constructor arg 1 |
| Pepeolithic PEPEO (ERC-721)  | `0x765956a7307222346b08fff681820a5d77e92028` | Launcher constructor arg 2 |
| Uniswap v4 PoolManager       | `0x000000000004444c5dc75cB358380D2e3dE08A90` | Launcher constructor arg 3 |
| currency0 / currency1        | native ETH (`address(0)`) / ZTO              | code                       |
| `ZTO_DECIMALS`               | 18                                           | code constant              |
| `LP_FEE` (static pool fee)   | 2000 = 0.20%                                 | code constant              |
| `TICK_SPACING`               | 60                                           | code constant              |
| `SPREAD_BPS`                 | 1500 = 15%                                   | code constant              |
| `DEPTH`                      | 50                                           | code constant              |
| `HOOK_FLAGS`                 | `0xCC` (see below)                           | code constant              |

Every number other than the three addresses is a code constant. Both constructors take only `(zto, pepeo,
poolManager)`, make no external call and read nothing on chain, so they deploy on an empty EVM. The Kiln does
not validate its own address bits in its constructor; the Launcher does after CREATE2.

### Tier table

The Kiln reads `PEPEO.balanceOf(tx.origin)` on every swap and applies the highest tier whose `minPepes` is at
most that balance. `kilnCut` is in hundredths of a bip (1e6 = 100%).

| Tier | minPepes | kilnCut | Rate  |
| ---- | -------- | ------- | ----- |
| 0    | 0        | 13000   | 1.30% |
| 1    | 1        | 10000   | 1.00% |
| 2    | 3        | 7500    | 0.75% |
| 3    | 7        | 5000    | 0.50% |
| 4    | 12       | 2500    | 0.25% |
| 5    | 21       | 0       | 0%    |

`tier(i)` returns a row, `tierOf(wallet)` returns the tier a wallet gets right now.

## How a swap is charged

The pool's static 0.20% `LP_FEE` goes to liquidity as usual. On top of it the Kiln takes `kilnCut` of the ZTO
side of the swap, always in ZTO:

| Case | Input | Exact    | ZTO is      | Taken in     | ZTO side the cut is measured on             | What the trader sees                       |
| ---- | ----- | -------- | ----------- | ------------ | ------------------------------------------- | ------------------------------------------ |
| 1    | ZTO   | input    | specified   | `beforeSwap` | the specified ZTO input                     | pays exactly the input; pool gets it − cut |
| 2    | ZTO   | output   | unspecified | `afterSwap`  | the ZTO input the pool computed             | pays pool input + cut, gets exact ETH out  |
| 3    | ETH   | input    | unspecified | `afterSwap`  | the ZTO output the pool computed            | pays exact ETH, gets pool output − cut     |
| 4    | ETH   | output   | specified   | `beforeSwap` | the specified ZTO output                    | gets exactly the output; pays ETH for it + cut |

The cut is not taken as real tokens inside the swap. The hook settles its return delta by minting ERC-6909 ZTO
claim tokens to itself (`poolManager.mint(address(this), zto, cut)`) and adds the amount to `claims`. Tier 5
(21+ pieces) pays no cut at all. Each swap emits `Passed(trader, pepes, kilnCut, ztoTaken)`.

**Partial fills.** A v4 swap stops early, without reverting, when it reaches its `sqrtPriceLimitX96` or the pool
runs out of liquidity. In cases 2 and 3 the cut is measured in `afterSwap` on the ZTO the pool actually moved, so a
partial fill is simply charged on the realised amount. In cases 1 and 4 the cut is taken in `beforeSwap` on the
full specified amount and the hook cannot change that delta afterwards, so `afterSwap` checks that the pool moved
exactly what it was asked to (`|amountSpecified| − cut` for exact input, `amountSpecified + cut` for exact output)
and reverts with `PartialFill(asked, realised)` otherwise. The trader is never charged on ZTO that did not trade.
Routers surface this as a failed swap; re-quote with a smaller size or a wider limit. A wallet that pays no cut
(tier 5) has nothing to reconcile and its ZTO-specified swaps may fill partially like any other v4 swap. On an
empty pool a ZTO exact-input swap therefore reverts instead of paying a cut for nothing.

The hook has no liquidity callbacks and serves exactly one pool: callbacks revert with `NotKilnPool` for any
other pool key that names the Kiln as its hook. Any range position can be added or removed freely.

## Claims, reserve and pieces

- `claims()` is ZTO cut still held as ERC-6909 claims inside the PoolManager.
- `collect()` is permissionless. It burns the Kiln's whole ZTO claim balance and takes real ZTO out of the
  PoolManager (`unlock` → `burn` + `take`), moving the amount into `reserve`. It emits `Collected(amount)` and
  is a harmless no-op when there is nothing to collect. `sell()` and `buy()` call it first.
- `reserve()` is real ZTO held for pieces. It grows with `collect()`, `seed()` and `buy()`, and shrinks only
  through `sell()`. `reserve <= ZTO.balanceOf(kiln)` always holds.
- `bid()` = `reserve / DEPTH`. Real ZTO only, so it is always payable. It falls geometrically as pieces come in
  and rises with every cut, seed and sale.
- `ask()` = `bid() * (10000 + SPREAD_BPS) / 10000`.
- `quoteBid()` / `quoteAsk()` are the same formulas with the pending claims added to the reserve. Because
  `sell()` and `buy()` run `collect()` first, these are the prices they actually execute at; `bid()`/`ask()`
  only equal them when `claims()` is zero. Quote with `quoteBid()`/`quoteAsk()`, or pass a bound.
- `inventory()` lists the ids held; `held(id)` checks one.

| Function              | Effect                                                                                          |
| --------------------- | ----------------------------------------------------------------------------------------------- |
| `sell(id)`            | Runs `collect()`. Price = `bid()` before the transfer. Pulls the piece with `transferFrom` (approve the Kiln on PEPEO first), `reserve -= price`, pays ZTO, emits `Sold`. Reverts `EmptyReserve` if `bid()` is 0. |
| `sell(id, minPrice)`  | Same, but reverts `PriceBelowMin(price, minPrice)` if the price is below `minPrice`.             |
| `buy(id)`             | Runs `collect()`. `id` must be in inventory. Price = `ask()`. Pulls ZTO with `transferFrom` (approve the Kiln on ZTO first), `reserve += price`, sends the piece with `transferFrom` (never `safeTransferFrom`), emits `Bought`. |
| `buy(id, maxPrice)`   | Same, but reverts `PriceAboveMax(price, maxPrice)` if the price is above `maxPrice`.             |
| `seed(amount)`        | Anyone adds ZTO to the reserve with `transferFrom`, emits `Seeded`.                              |

No other function moves ZTO or pieces. There is no `receive`, so the Kiln never holds ETH.

## Caveats

- **The pass is read from `tx.origin`.** Routers are `msg.sender`; the trader is `tx.origin`. A pass only
  needs to be in the wallet during the swap; there is no block-held guard. Smart-contract wallets whose
  `tx.origin` is a relayer get the relayer's tier, and a piece can be borrowed for the duration of a trade.
  A from-less `eth_call` (quoters, simulators) runs with `tx.origin == address(0)`, where Pepeolithic's
  OpenZeppelin `balanceOf` reverts; the Kiln treats a zero origin, and any failing `balanceOf` read, as zero
  pieces (tier 0) so simulations and swaps keep working. A trader whose pass cannot be read pays the full cut.
- **Quote versus execution.** `bid()` and `ask()` read the real reserve only; `sell()` and `buy()` collect the
  pending claims first and execute at `quoteBid()`/`quoteAsk()`, which are at least as high. A buyer who
  approves exactly `ask()` sees `buy()` revert on allowance once any cut is pending; a buyer with an open
  allowance pays the higher amount. Use the quote views, or `buy(id, maxPrice)` / `sell(id, minPrice)` to refuse
  a price that moved between quote and execution. The deviation always favours the reserve.
- **`collect()` inside another PoolManager unlock.** `collect()` opens its own `unlock`, which the PoolManager
  rejects while one is already open. A contract that calls `collect()`, `sell()` or `buy()` from inside its
  own `unlockCallback` succeeds only while `claims()` is zero and reverts `AlreadyUnlocked` otherwise. Trade
  pieces in a separate transaction, or outside the unlock.
- **Pepeolithic's own admin.** The Pepeolithic contract has `admin` and `adam` roles and a `sweep()` that mints
  the unsold pieces of a closed cave to the admin for free. The Kiln buys from anyone at `bid()` with no
  per-seller limit, so an actor holding k zero-cost pieces can convert them into `1 − (49/50)^k` of the reserve
  (50 pieces: about 64%, 100 pieces: about 87%), each sale lowering the next bid by 2%. This is the design the
  brief asks for; the Kiln has no role that could refuse a seller. Holders of ZTO cuts should understand that
  the reserve is open to every Pepeolithic holder, including the collection's admin.
- **Pieces sent by plain transfer are stuck.** Only `sell()` adds a piece to inventory. A PEPEO piece that
  arrives through `transferFrom` or `safeTransferFrom` outside `sell()` is not inventory, cannot be bought and
  cannot be recovered. Likewise ZTO sent directly to the Kiln is not reserve and cannot be recovered; use
  `seed()`.
- **ERC-6909 ZTO claims transferred to the Kiln** are swept into the reserve by the next `collect()`.
- **Dust.** With a reserve under 50 wei `bid()` is 0 and `sell()` reverts; `buy()` likewise reverts when
  `ask()` is 0, so a held piece waits for a `seed()` rather than leaving for free.
- **Partial fills of ZTO-specified swaps revert.** See "Partial fills" above: a ZTO-in exact-input or ETH-in
  exact-output swap that cannot be filled in full reverts `PartialFill` whenever a cut applies.
- **Protocol fee.** Uniswap governance may enable a protocol fee on any v4 pool. It comes out of the LP fee
  side and does not touch the Kiln cut.
- **Fee-on-transfer or rebasing tokens** are out of scope: ZTO is a plain ERC-20 and the Kiln relies on it.

## Deployment

1. Deploy `Launcher(zto, pepeo, poolManager)` with the three mainnet addresses above. Only the Launcher is
   deployed directly; it creates the Kiln.
2. Mine a salt off chain. `launcher.initCodeHash()` is the keccak256 of the Kiln init code with its
   constructor args. The Kiln address is `keccak256(0xff ++ launcher ++ salt ++ initCodeHash)[12:]` and its
   low 14 bits must equal `0xCC`, which is exactly `beforeSwap | afterSwap | beforeSwapReturnDelta |
   afterSwapReturnDelta` (`1<<7 | 1<<6 | 1<<3 | 1<<2`). Equivalently the address ends in `00CC`, `40CC`,
   `80CC` or `C0CC`. `launcher.kilnAddress(salt)` checks a candidate on chain. `cast create2 --deployer
   <launcher> --init-code-hash <hash> --ends-with 00cc` finds one (try the four endings).
3. Call `launcher.open(salt, sqrtPriceX96)` from any account. It reverts `WrongHookAddress` for a salt with
   the wrong bits and `AlreadyOpened` after the first success. `sqrtPriceX96 = sqrt(ZTO per ETH) * 2^96`
   because both currencies have 18 decimals; for example 1,000,000 ZTO per ETH is
   `79228162514264337593543950336000`. The call emits `Opened(kiln, poolId)` and adds no liquidity.
   **Send it through a private relay** (Flashbots Protect or similar), not the public mempool: `open()` is
   permissionless and its arguments are public, so a watcher could call it first with another price. The pool
   key is also predictable from the salt, and the PoolManager lets anyone initialize it before the Kiln exists
   (the Kiln has no initialize hook bits, so no hook call stops them). `open()` cannot be blocked that way: it
   reads the pool's slot0 and, if the pool is already initialized, adopts it at its live price, emits
   `Preinitialized(poolId, livePrice, requestedPrice)` and then `Opened`. The requested price is ignored in that
   case.
4. **Check the live price before adding liquidity**: read slot0 for the pool id (`StateLibrary.getSlot0`, or
   `cast call <poolManager> "extsload(bytes32)"` on the pool state slot) and confirm it is the intended
   `sqrtPriceX96`. If a `Preinitialized` event fired, or someone front-ran `open()` with a different price, move
   the empty pool to the intended tick with a dust swap whose `sqrtPriceLimitX96` is the intended price (ZTO in,
   `zeroForOne = false`, raises the price; ETH in lowers it); with no liquidity the swap moves the price and costs
   only dust. Use a tier-5 wallet or accept the dust cut. A range placed on the wrong side of the live tick would
   demand ETH instead of ZTO.
5. Add the ZTO-only range position through the normal Uniswap v4 PositionManager
   (`0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e` on mainnet). In Uniswap terms the pool price is ZTO per ETH,
   so a range in which ZTO is priced above the opening price is a range of ticks entirely at or below the
   current tick (`tickUpper <= currentTick`), both ticks multiples of 60. Such a position takes only ZTO.
6. Optionally `seed()` the reserve so `bid()` is non-zero from day one.

### Operational responsibilities

- Nobody administers anything. `collect()`, `sell()`, `buy()` and `seed()` are open to everyone.
- The liquidity provider owns and manages the range position through the PositionManager; the Kiln has no
  say in it.
- The pool is on the shared mainnet PoolManager. If PEPEO or ZTO ever misbehave (pausing, blocklists), swaps
  that need them revert; nothing in the Kiln can be changed to compensate.
- The launch manifest is written by the manifest step after review; this tree contains no `launch.json`.
  The protected deployment probe runs the constructors on an empty chain and scans runtime bytecode for
  DELEGATECALL, CALLCODE and SELFDESTRUCT; the Launcher test repeats that scan locally.

## Build and test

```
forge build
forge test
forge fmt --check
```

`foundry.toml` pins `solc = "0.8.26"`, `via_ir = true`, `optimizer_runs = 1`, `evm_version = "cancun"`,
`bytecode_hash = "none"` and `cbor_metadata = false`. Custom errors only, no ReentrancyGuard: state is
updated before external token calls, which come last. Kiln runtime is 6,366 bytes (limit 12,000), Launcher
8,745 bytes including the embedded Kiln init code.

Tests run against the real v4 `PoolManager` with the v4-core test routers (`PoolSwapTest`,
`PoolModifyLiquidityTest`), a mock 18-decimal ZTO and a mock ERC-721:

- `test/Launcher.t.sol`: open() once and only at an address with the right bits, pool initialized with
  lpFee 2000 / tickSpacing 60 / Kiln as hook, rollback when initialization fails, open() adopting a pool
  somebody initialized first (and the dust-swap recovery of its price), `initCodeHash()` and
  `kilnAddress()`, the Kiln constructor not validating its address, runtime size and opcode scan.
- `test/KilnSwap.t.sol`: a ZTO-only range position above the opening price; all four swap cases for wallets
  holding 0, 1, 3, 7, 12 and 21 pieces, checking the cut equals kilnCut of the ZTO side within rounding,
  tier 21 pays nothing, the cut shows in `claims()` and after `collect()` in `reserve()` and the real ZTO
  balance, `collect()` with nothing is a no-op, the trader also paid the LP fee; partial fills: ZTO-specified
  swaps revert `PartialFill` at a price limit, on exhausted liquidity and on an empty pool while tier 5 may
  fill partially, and the afterSwap cases charge the realised amount; a zero `tx.origin` and a reverting
  PEPEO read fall back to tier 0; callbacks reject other callers and other pools; liquidity is unrestricted.
- `test/KilnPieces.t.sol`: sell pays bid and bid falls geometrically; buy charges ask and the piece leaves
  inventory; buy of an id not held reverts; sell at zero reserve reverts; seed grows bid; `quoteBid()` and
  `quoteAsk()` include pending claims and are what `buy()`/`sell()` execute at; the bounded overloads revert
  `PriceAboveMax`/`PriceBelowMin`; failed token transfers revert; stuck transfers; a fuzzed action sequence
  keeps `reserve <= balance`; nobody can withdraw.

Slither is not available in this environment and was not run. The code follows its two relevant rules by
construction: every division comes after the multiplication it scales, and the only `abi.encodePacked` has
static arguments. `forge build` lint warnings are advisory (unsafe-typecast after explicit sign checks,
unused `initialize`/`unlock` return values, and events in `sell`/`buy` emitted after the `collect()` call
the brief requires first).

## Vendored dependencies

`lib/` holds plain copies, no submodules. See `lib/VENDORED.md` for exact commits: Uniswap v4-core v4.0.0
(`src/`, `test/utils/CurrencySettler.sol`), the v4-periphery `HookMiner` test helper, forge-std 1.17.0 and
solmate's `Owned.sol` (needed by v4-core's `ProtocolFees`). v4-periphery's `BaseHook` was deliberately not
used because it validates the hook address in its constructor, which the brief forbids for the Kiln.

Tests passing are not an audit. Independent adversarial review is still required before funds are routed
through the pool.
