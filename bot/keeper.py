#!/usr/bin/env python3
"""
Stateless keeper for the up33 position compounder.

Every run:
  1. pages CompounderRegistry.compounders() through KeeperMulticall.scan()
  2. asks KeeperMulticall.isCompoundable() for each compounder (same rules the contracts enforce)
  3. submits KeeperMulticall.batch() in chunks

Nothing is cached between runs; all inputs come from chain state.

Env:
  RPC_URL, KEEPER_MULTICALL, OPERATOR_PRIVATE_KEY
  MIN_PENDING_UP (wei, default 1e18), GAS_PER_POSITION (default 1_500_000),
  BATCH_SIZE (default 10), DRY_RUN (default 0)

Requires: pip install web3
"""
import os
import sys
from web3 import Web3

MULTICALL_ABI = [
    {"name": "scan", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "offset", "type": "uint256"}, {"name": "limit", "type": "uint256"}],
     "outputs": [{"name": "list", "type": "tuple[]", "components": [
         {"name": "compounder", "type": "address"}, {"name": "owner", "type": "address"},
         {"name": "version", "type": "uint16"}, {"name": "keeper", "type": "address"},
         {"name": "active", "type": "bool"}, {"name": "gasBalance", "type": "uint256"},
         {"name": "minUpToCompound", "type": "uint256"}, {"name": "lastCompoundAt", "type": "uint40"},
         {"name": "totalUpClaimed", "type": "uint256"}, {"name": "totalFeesPaid", "type": "uint256"},
         {"name": "totalGasReimbursed", "type": "uint256"}, {"name": "positionCount", "type": "uint256"},
         {"name": "pendingUp", "type": "uint256"}]},
         {"name": "total", "type": "uint256"}]},
    {"name": "isCompoundable", "type": "function", "stateMutability": "view",
     "inputs": [{"name": "compounder", "type": "address"}, {"name": "gasPrice", "type": "uint256"},
                {"name": "gasEstimate", "type": "uint256"}, {"name": "minPendingUp", "type": "uint256"}],
     "outputs": [{"name": "ok", "type": "bool"}, {"name": "reason", "type": "uint8"},
                 {"name": "s", "type": "tuple", "components": [
                     {"name": "compounder", "type": "address"}, {"name": "owner", "type": "address"},
                     {"name": "version", "type": "uint16"}, {"name": "keeper", "type": "address"},
                     {"name": "active", "type": "bool"}, {"name": "gasBalance", "type": "uint256"},
                     {"name": "minUpToCompound", "type": "uint256"}, {"name": "lastCompoundAt", "type": "uint40"},
                     {"name": "totalUpClaimed", "type": "uint256"}, {"name": "totalFeesPaid", "type": "uint256"},
                     {"name": "totalGasReimbursed", "type": "uint256"}, {"name": "positionCount", "type": "uint256"},
                     {"name": "pendingUp", "type": "uint256"}]}]},
    {"name": "batch", "type": "function", "stateMutability": "nonpayable",
     "inputs": [{"name": "compounders", "type": "address[]"}],
     "outputs": [{"name": "succeeded", "type": "uint256"}]},
]

SKIP = ["None", "NotCompounder", "NotDelegated", "Inactive", "NoPositions", "BelowThreshold", "Unfunded"]


def main():
    w3 = Web3(Web3.HTTPProvider(os.environ["RPC_URL"]))
    mc = w3.eth.contract(address=Web3.to_checksum_address(os.environ["KEEPER_MULTICALL"]), abi=MULTICALL_ABI)
    acct = w3.eth.account.from_key(os.environ["OPERATOR_PRIVATE_KEY"])
    min_pending = int(os.environ.get("MIN_PENDING_UP", 10**18))
    gas_per_pos = int(os.environ.get("GAS_PER_POSITION", 1_500_000))
    batch_size = int(os.environ.get("BATCH_SIZE", 10))
    dry_run = os.environ.get("DRY_RUN", "0") == "1"
    gas_price = w3.eth.gas_price

    # 1. page the registry
    offset, page = 0, 50
    snapshots = []
    while True:
        rows, total = mc.functions.scan(offset, page).call()
        snapshots.extend(rows)
        offset += page
        if offset >= total:
            break

    # 2. filter with the on-chain rule set
    targets = []
    for s in snapshots:
        est = gas_per_pos * max(1, s[11])
        ok, reason, _ = mc.functions.isCompoundable(s[0], gas_price, est, min_pending).call()
        print(f"{s[0]} positions={s[11]} pendingUp={s[12] / 1e18:.4f} gas={s[5] / 1e18:.5f} -> {SKIP[reason]}")
        if ok:
            targets.append((s[0], est))

    if not targets:
        print("nothing to compound")
        return

    # 3. submit in chunks
    for i in range(0, len(targets), batch_size):
        chunk = targets[i:i + batch_size]
        addrs = [a for a, _ in chunk]
        gas_limit = sum(e for _, e in chunk) + 200_000
        tx = mc.functions.batch(addrs).build_transaction({
            "from": acct.address,
            "nonce": w3.eth.get_transaction_count(acct.address),
            "gas": gas_limit,
            "gasPrice": gas_price,
        })
        if dry_run:
            print("DRY RUN batch:", addrs)
            continue
        signed = acct.sign_transaction(tx)
        h = w3.eth.send_raw_transaction(signed.raw_transaction)
        receipt = w3.eth.wait_for_transaction_receipt(h)
        print(f"batch {addrs} -> tx {h.hex()} status={receipt.status} gasUsed={receipt.gasUsed}")


if __name__ == "__main__":
    sys.exit(main())
