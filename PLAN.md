# up33 CL Position Auto-Compounder — Build Plan

Standalone Foundry project on Robinhood Chain (chain id 4663). Not a Yearn V3 strategy.
Users keep full control of range and liquidity; the protocol only claims UP, takes a fee, and
adds the rest back into the user's own position NFT.

## Protocol facts that shape the design

- up33 is a Velodrome V2 + Slipstream fork. CL positions are NFTs (`UP-POS`, position manager
  `0x07F44c47743A2f36414A82b9F558ECFCf0EEdCEf`). Staking = `CLGauge.deposit(tokenId)`; only the
  staker can `getReward`/`withdraw`. The gauge has NO `increaseStakedLiquidity`, so every compound
  is: claim -> swap -> `gauge.withdraw` -> `nft.increaseLiquidity` -> `gauge.deposit`.
- Reward token is UP (`0x57C0E45cB534413D1C20A4240955d6bB250BB4F1`). Deepest UP liquidity is the
  WETH/UP CL pool at tick spacing 200. Swap router is Slipstream style (`int24 tickSpacing`).
- Gauge `deposit` requires `voter.isAlive(gauge)`; `withdraw` returns the NFT with
  `safeTransferFrom` (contracts must implement `onERC721Received`).
- Blocks are ~0.1s; pool TWAP buffers cover 30–60 min. Cardinality can be increased permissionlessly.

## Contracts

### 1. `CompounderRegistry` (singleton, `Ownable2Step`)

Single source of truth for protocol config, enabled pools, implementation versions, and the user
directory. Everything is enumerable so bots and UIs never need event history.

Protocol config (owner-set, read by clones at call time):
- `treasury`, `feeBps` (hard cap 2000), `paused` (halts compounding and deposits, never withdrawals)
- `slippageBps`, `twapWindow`, `maxTwapDeviationBps`
- `gasPremiumBps`, `gasOverhead` (fixed gas added to reimbursements), `protocolKeeper`
  (the `KeeperMulticall`; the address users delegate to)
- `routes[tokenIn][tokenOut] = bytes path` (Slipstream packed path: token, int24 spacing, token, ...)

Implementations:
- `implementations[version] -> address`, `implementationEnabled[version]`, `latestVersion`
- `setImplementation(address)` bumps `latestVersion`; `setImplementationEnabled(version, bool)`
  lets us deprecate a version (deposits/compounds on deprecated clones revert, withdrawals work).

Pools:
- `enablePool(pool)`: reads `token0/token1/tickSpacing` from the pool, `gauge = voter.gauges(pool)`,
  requires gauge alive and routes UP->token0 and UP->token1 present (or token == UP). Stores
  `PoolInfo { pool, gauge, token0, token1, tickSpacing, enabled, enabledAtVersion, index }`.
- `disablePool(pool)`: blocks new deposits and compounding for that pool; withdrawals unaffected.
- `poolList[]`, `poolCount()`, `pools(offset, limit)`, `poolInfo(pool)`.

Users:
- `createCompounder()` -> EIP-1167 clone of the latest implementation, one active per user.
- `compounderOf[user]`, `ownerOfCompounder[compounder]`, `isCompounder`, `compounderList[]`,
  `compounderCount()`, `compounders(offset, limit)`, `previousCompounders[user][]` (after upgrades).
- `upgradeCompounder()`: user gets a fresh clone at `latestVersion`; old one is kept in history.
  (Phase 5 adds `migrate(tokenIds)` that moves NFTs old -> new in one tx.)

### 2. `UserCompounder` (clone, one per user, any number of enabled pools)

State (all readable on-chain):
- `owner`, `registry`, `version`, `keeper`, `minUpToCompound`, `lastCompoundAt`,
  `totalUpClaimed`, `totalFeesPaid`, `totalGasReimbursed`
- `positionIds` (EnumerableSet), `positionInfo[tokenId] = { pool, depositedAt, lastCompoundedAt,
  compoundCount, upClaimed, staked }`
- gas balance = `address(this).balance`

Owner functions:
- `deposit(tokenId)`: derives the pool from the NFT (`CLFactory.getPool(t0, t1, spacing)`),
  requires pool enabled and not paused, pulls NFT, stakes. Any fees the gauge collects on staking
  are forwarded to the owner.
- `withdraw(tokenId, to)`: unstake (claims pending UP -> fee to treasury, rest to owner in UP),
  transfer NFT out, delete position info.
- `increaseLiquidity(tokenId, a0, a1, min0, min1)`, `decreaseLiquidity(tokenId, liq, min0, min1)`
  passthroughs that unstake/restake around the position manager call. Proceeds go to owner.
- `claim(tokenId)`: claim UP without compounding (fee applies).
- `setKeeper(address)`, `setMinUpToCompound(uint256)`, `fundGas() payable`, `withdrawGas(amount)`,
  `sweep(token, to)`, `emergencyUnstake(tokenId)` (unstake without restake if the gauge misbehaves).

Compounding (`owner` or `keeper`):
- `compound(uint256[] tokenIds)` and `compoundAll()`. Per position:
  1. `gauge.getReward(tokenId)`; measure UP received. Skip if below `minUpToCompound` (compoundAll).
  2. Fee = `up * feeBps / 1e4` -> treasury. Net stays.
  3. Read pool `slot0` and TWAP; revert if deviation > `maxTwapDeviationBps`.
  4. `PositionMath.split(range, sqrtPrice)` gives the token1 value weight `w`. Swap `net*(1-w)` UP
     to token0 and `net*w` to token1 via registry routes, `minOut` = TWAP quote minus `slippageBps`.
     Idle token0/token1 already in the clone are included.
  5. `gauge.withdraw` -> `nft.increaseLiquidity` (mins from TWAP tolerance) -> `gauge.deposit` if
     the gauge is alive, else leave held and mark `staked = false`.
  6. Update stats, emit `Compounded(tokenId, up, fee, added0, added1, liquidity)`.
- Gas reimbursement when `msg.sender == keeper`: `(gasUsed + gasOverhead) * tx.gasprice *
  (1e4 + gasPremiumBps) / 1e4`, paid from the clone's ETH balance to `msg.sender`; reverts with
  `InsufficientGas` if unfunded so the multicall skips it.
- Nonreentrant. Nothing in the registry or keeper can move a user's NFT.

Views for UI/bots: `positions()`, `positionsByPool(pool)`, `earned(tokenId)`, `pendingUp()`,
`gasBalance()`, `snapshot()` (one struct with everything above).

### 3. `KeeperMulticall` (protocol-owned)

- `operators` allowlist. `batch(address[] compounders)` calls `compoundAll()` on each inside
  try/catch, emits `BatchItem(compounder, ok, gasUsed)`. Reimbursements accumulate here;
  `withdrawETH(to)` for the owner.
- `snapshot(address[] compounders) -> CompounderSnapshot[]` and
  `positionSnapshots(compounder) -> PositionSnapshot[]` (tokenId, pool, liquidity, ticks, in-range,
  earned, staked, lastCompoundedAt). `isCompoundable(compounder, gasPrice)` applies the same rules
  the clone uses so bots never send failing txs.
- Stateless bot loop: page `registry.compounders(offset, limit)` -> `snapshot` -> filter
  (`keeper == multicall`, gas balance covers estimate, `pendingUp >= minUpToCompound`, pool
  enabled, not paused) -> `batch` in chunks sized to the block gas limit.

### 4. Libraries and interfaces

- `PositionMath`: amounts for liquidity and value split for a range at a sqrt price
  (Uniswap `0.8` branch `TickMath`, `FullMath`, `LiquidityAmounts`, `OracleLibrary` as submodules).
- `SlipstreamSwapLib`: `exactInput` with packed `int24` paths, multi-hop TWAP quote by walking the
  path's pools via `CLFactory.getPool`.
- `interfaces/up33/`: `ICLPool`, `ICLFactory`, `ICLGauge`, `INonfungiblePositionManager`,
  `ISwapRouter`, `IVoter`.

## Tests (fork of Robinhood Chain)

- Setup: deploy registry, implementation, multicall; enable WETH/USDG (spacing 10) and WETH/UP
  (spacing 200); set routes; mint test positions through the position manager (in-range and
  out-of-range) with dealt/swapped tokens.
- Registry: pool enable/disable, route requirements, version gating, one compounder per user,
  pagination views.
- Compounder: deposit/withdraw round trip, fee-on-withdraw claim, passthroughs, `skip` inside an
  epoch then compound by owner (liquidity increased, fee at treasury, stats updated), out-of-range
  single-sided compound, dust reuse, dead-gauge path (prank voter `killGauge`), TWAP deviation
  revert, paused registry, deprecated version.
- Keeper: delegation, gas reimbursement math, unfunded skip, batch with mixed success,
  snapshot correctness, gas report per batch size.

## Build order

1. Reset repo to a plain Foundry project (remove Yearn submodules and scaffolding), add
   submodules, interfaces, libraries, fork `Setup`.
2. `CompounderRegistry` + `UserCompounder` deposit/withdraw/passthrough/claim with tests.
3. `compound` with fee, swaps, restake, dust, stats, gas reimbursement, with tests.
4. `KeeperMulticall` with batch, snapshots, `isCompoundable`, with tests and gas snapshots.
5. Deploy script (registry, impl v1, multicall, initial pools/routes), `migrate` helper,
   minimal keeper bot script that only reads chain state.

## Status (2026-09-04)

Built and passing on a Robinhood Chain fork (54 tests):
- `src/CompounderRegistry.sol`, `src/UserCompounder.sol` (22.6 KB, under the size limit),
  `src/KeeperMulticall.sol` + `src/CompounderLens.sol`, libraries and up33 interfaces.
- `script/Deploy.s.sol`, `bot/keeper.py` (stateless, reads `scan` + `isCompoundable`, submits `batch`).
- Measured gas: ~1.49M per compound with two swaps; ~5.7M for a 5-position batch.

Not done / follow-ups:
- `migrate(tokenIds)` helper for moving positions between compounder versions.
- Deploy to mainnet (needs deployer key, owner multisig, treasury).
- Enable more pools + routes (each pool needs UP -> token0 and UP -> token1 routes set first).
