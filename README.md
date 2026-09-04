# up33 CL Position Auto-Compounder

Standalone protocol on Robinhood Chain (chain id 4663) that auto-compounds a user's own
[up33](https://up33.xyz) concentrated liquidity positions.

- The user keeps full control of the range and liquidity. The protocol only claims UP emissions,
  takes a fee, swaps the rest into the pair and adds it back into the **same** position NFT.
- Each user gets a personal minimal proxy (`UserCompounder`) that holds and stakes their NFTs across
  any number of enabled pools.
- A user can compound themselves, or delegate to the protocol keeper and fund it with ETH for gas.
- Every piece of state a UI or keeper needs is stored on-chain and enumerable. Bots run stateless.

## Contracts

| Contract | Role |
|---|---|
| `CompounderRegistry` | Protocol config (fee, treasury, slippage, TWAP, gas terms, routes), enabled pools, implementation versions, user directory. Paginated views. |
| `UserCompounder` | Per-user clone. `deposit`, `withdraw`, `claim`, `compound`, `compoundAll`, `increaseLiquidity`, `decreaseLiquidity`, `emergencyUnstake`, `restake`, keeper delegation and gas funding. |
| `KeeperMulticall` | Protocol keeper. Allowlisted operators call `batch(compounders)`; reimbursements accumulate here. Inherits `CompounderLens`. |
| `CompounderLens` | Read-only aggregation: `scan`, `snapshots`, `positionSnapshots`, `userView`, `isCompoundable`. |

### Compound cycle (per position)

1. `gauge.getReward(tokenId)` and record what was claimed.
2. Send `feeBps` of it to the treasury.
3. Check the pool's spot tick against its TWAP (`maxTickDeviation`).
4. Split the remaining UP by the value ratio the range needs at the current price, net of route
   swap fees, and swap through the configured Slipstream routes with a TWAP-derived minimum output.
5. `gauge.withdraw`, `nft.increaseLiquidity`, `gauge.deposit` (the up33 gauge has no
   `increaseStakedLiquidity`). If the gauge was killed the NFT is held unstaked.

Leftover dust stays in the user's compounder and is used on the next compound.

### Keeper delegation

`setKeeper(keeperMulticall)` and `fundGas()` on the user's compounder. When the keeper compounds,
the compounder reimburses `(gasUsed + gasOverhead) * min(tx.gasprice, maxGasPrice) * (1 + premium)`
from its ETH balance. Unfunded compounders revert with `InsufficientGas` and are skipped by the batch.

## Development

```sh
cp .env.example .env   # set ROBINHOOD_RPC_URL
forge build
forge test             # all tests fork Robinhood Chain
```

Deploy: `script/Deploy.s.sol`. Keeper bot: `bot/keeper.py` (see header for env vars).

## up33 addresses (mainnet)

Voter `0x7F749fDD351C1Ceed82d76d7699CB631Eb8332a7`, CLFactory `0x1ac9dB4a2608ba45D6127B1737949b51Bb54B7F3`,
PositionManager `0x07F44c47743A2f36414A82b9F558ECFCf0EEdCEf`, SwapRouter `0xC062b870E813fcA720f1e002c234369Ab3aB9415`,
UP `0x57C0E45cB534413D1C20A4240955d6bB250BB4F1`.
