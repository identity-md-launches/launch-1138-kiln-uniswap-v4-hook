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
- `inventory()` lists the ids held; `held(id)` checks one.

| Function      | Effect                                                                                                  |
| ------------- | ------------------------------------------------------------------------------------------------------- |
| `sell(id)`    | Price = `bid()` before the transfer. Pulls the piece with `transferFrom` (approve the Kiln on PEPEO first), `reserve -= price`, pays ZTO, emits `Sold`. Reverts `EmptyReserve` if `bid()` is 0. |
| `buy(id)`     | `id` must be in inventory. Price = `ask()`. Pulls ZTO with `transferFrom` (approve the Kiln on ZTO first), `reserve += price`, sends the piece with `transferFrom` (never `safeTransferFrom`), emits `Bought`. |
| `seed(amount)`| Anyone adds ZTO to the reserve with `transferFrom`, emits `Seeded`.                                     |

No other function moves ZTO or pieces. There is no `receive`, so the Kiln never holds ETH.

## Caveats

- **The pass is read from `tx.origin`.** Routers are `msg.sender`; the trader is `tx.origin`. A pass only
  needs to be in the wallet during the swap; there is no block-held guard. Smart-contract wallets whose
  `tx.origin` is a relayer get the relayer's tier, and a piece can be borrowed for the duration of a trade.
- **Pieces sent by plain transfer are stuck.** Only `sell()` adds a piece to inventory. A PEPEO piece that
  arrives through `transferFrom` or `safeTransferFrom` outside `sell()` is not inventory, cannot be bought and
  cannot be recovered. Likewise ZTO sent directly to the Kiln is not reserve and cannot be recovered; use
  `seed()`.
- **ERC-6909 ZTO claims transferred to the Kiln** are swept into the reserve by the next `collect()`.
- **Dust.** With a reserve under 50 wei `bid()` is 0 and `sell()` reverts; `buy()` likewise reverts when
  `ask()` is 0, so a held piece waits for a `seed()` rather than leaving for free.
- **Exact-output ETH-in swaps that hit the price limit** still pay the cut on the specified amount, so the
  trader may receive less than the specified output. Routers enforce their minimum-output checks as usual.
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
4. Add the ZTO-only range position through the normal Uniswap v4 PositionManager
   (`0xbd216513d74c8cf14cf4747e6aaa6420ff64ee9e` on mainnet). In Uniswap terms the pool price is ZTO per ETH,
   so a range in which ZTO is priced above the opening price is a range of ticks entirely at or below the
   current tick (`tickUpper <= currentTick`), both ticks multiples of 60. Such a position takes only ZTO.
5. Optionally `seed()` the reserve so `bid()` is non-zero from day one.

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
updated before external token calls, which come last. Kiln runtime is about 5.8 KB (limit 12,000 bytes),
Launcher about 8 KB including the embedded Kiln init code.

Tests run against the real v4 `PoolManager` with the v4-core test routers (`PoolSwapTest`,
`PoolModifyLiquidityTest`), a mock 18-decimal ZTO and a mock ERC-721:

- `test/Launcher.t.sol`: open() once and only at an address with the right bits, pool initialized with
  lpFee 2000 / tickSpacing 60 / Kiln as hook, rollback when initialization fails, `initCodeHash()` and
  `kilnAddress()`, the Kiln constructor not validating its address, runtime size and opcode scan.
- `test/KilnSwap.t.sol`: a ZTO-only range position above the opening price; all four swap cases for wallets
  holding 0, 1, 3, 7, 12 and 21 pieces, checking the cut equals kilnCut of the ZTO side within rounding,
  tier 21 pays nothing, the cut shows in `claims()` and after `collect()` in `reserve()` and the real ZTO
  balance, `collect()` with nothing is a no-op, the trader also paid the LP fee, callbacks reject other
  callers and other pools, liquidity is unrestricted.
- `test/KilnPieces.t.sol`: sell pays bid and bid falls geometrically; buy charges ask and the piece leaves
  inventory; buy of an id not held reverts; sell at zero reserve reverts; seed grows bid; failed token
  transfers revert; stuck transfers; a fuzzed action sequence keeps `reserve <= balance`; nobody can
  withdraw.

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
