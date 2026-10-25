"""Sends a forge broadcast plan to HyperEVM with explicit gas limits: the HyperEVM big-block deploy.

Why: `forge script` simulates against the chain's latest header, and a HyperEVM small block has a 2-3M gas limit, so
the deploy of the vault implementation runs OutOfGas at the header limit, with or without --gas-limit, even with big
blocks switched on for the sender. So the deploy is planned on a local anvil fork of the chain with a 30M block (the
big block size), and this script sends the planned transactions to the real chain, unchanged, each with its gas
limit set from the fork's receipt. Nothing is simulated or estimated against the real chain.

The plan is forge's broadcast file of that fork run (broadcast/<script>/<chainId>/run-latest.json). The fork starts
at the live state, so the planned nonces, and with them every CREATE address and every library link, are the live
ones, as long as the sender sends nothing else on HyperEVM between the plan and the send (HyperCore actions, such as
switching big blocks, do not touch the EVM nonce).

Before sending: the chain id, the sender and every nonce are checked; the plan is printed (contract, gas limit,
expected address) and sent only after "yes". Each transaction waits for its receipt: status 1, and for a CREATE, the
planned address. Re-running the same command resumes: a transaction whose nonce is already used is skipped if its
planned effect is on chain (a CREATE's code at the planned address), and the run stops otherwise.

The key: decrypted in this process from the Foundry keystore after a hidden password prompt. Never from the
environment or the command line, never printed, never written.

The RPC: read from the environment variable named by --rpc-env (default HYPEREVM_RPC_URL), never printed. --rpc takes
a URL for a local anvil or the public testnet RPC only.

usage (from contracts/):
  python script/py/send_planned.py --plan deployments/plan-testnet.json --chain-id 998 \
      --rpc https://rpc.hyperliquid-testnet.xyz/evm --account d14-owner \
      --record-in deployments/plan-testnet-record.json --record-out deployments/testnet.json
  python script/py/send_planned.py --plan deployments/plan-mainnet.json --chain-id 999 --rpc-env HYPEREVM_RPC_URL \
      --account deployer --record-in deployments/plan-mainnet-record.json --record-out deployments/mainnet.json
"""
import argparse
import getpass
import json
import math
import os
import sys
import time
import urllib.request

from eth_account import Account
from eth_utils import to_checksum_address

BIG_BLOCK_GAS = 30_000_000
CREATES = ("CREATE", "CREATE2")  # CREATE2: forge's libraries, through the deterministic deployer 0x4e59...956C


class Rpc:
    def __init__(self, url):
        self.url = url
        self.id = 0

    def call(self, method, params=None, allow_error=False):
        self.id += 1
        body = json.dumps({"jsonrpc": "2.0", "id": self.id, "method": method, "params": params or []}).encode()
        req = urllib.request.Request(self.url, data=body, headers={"content-type": "application/json"})
        for attempt in range(5):
            try:
                with urllib.request.urlopen(req, timeout=60) as r:
                    out = json.load(r)
                break
            except Exception as e:  # network blips: retry, never print the URL
                if attempt == 4:
                    sys.exit(f"rpc {method} failed: {type(e).__name__}")
                time.sleep(2 * (attempt + 1))
        if "error" in out:
            if allow_error:
                return None
            sys.exit(f"rpc {method} error: {out['error'].get('message', out['error'])}")
        return out["result"]


def h2i(x):
    return int(x, 16) if isinstance(x, str) else int(x)


def load_wallet(name, folder, password_file):
    folder = folder or os.path.join(os.path.expanduser("~"), ".foundry", "keystores")
    path = os.path.join(folder, name)
    if not os.path.isfile(path):
        sys.exit(f"no keystore {path} (cast wallet list shows the names)")
    with open(path) as f:
        ks = json.load(f)
    if password_file:  # rehearsals with a throwaway keystore only
        with open(password_file) as f:
            password = f.read().strip()
    else:
        password = getpass.getpass(f"keystore password for {name}: ")
    try:
        return Account.from_key(Account.decrypt(ks, password))
    except ValueError:
        sys.exit("wrong password")


def load_plan(path):
    with open(path) as f:
        run = json.load(f)
    receipts = {r["transactionHash"].lower(): r for r in run.get("receipts", [])}
    steps = []
    for t in run["transactions"]:
        tx = t["transaction"]
        r = receipts.get((t.get("hash") or "").lower())
        if r is None or h2i(r["status"]) != 1:
            sys.exit(f"the plan has no successful fork receipt for {t.get('contractName')} {t.get('function')}: re-plan")
        steps.append({
            "kind": t["transactionType"],
            "name": t.get("contractName") or "",
            "fn": t.get("function") or "",
            "to": tx.get("to"),
            "from": tx["from"].lower(),
            "data": tx.get("input") or tx.get("data") or "0x",
            "value": h2i(tx.get("value") or "0x0"),
            "nonce": h2i(tx["nonce"]),
            "chain": h2i(tx.get("chainId") or "0x0"),
            "address": (t.get("contractAddress") or "").lower() or None,
            "used": h2i(r["gasUsed"]),
            "forge_gas": h2i(tx.get("gas") or "0x0"),
        })
    return steps


def gas_limit(s, margin):
    g = max(s["forge_gas"], math.ceil(s["used"] * margin))
    return min(g, BIG_BLOCK_GAS - 1)


def wait_receipt(rpc, h, timeout):
    t0 = time.time()
    while time.time() - t0 < timeout:
        r = rpc.call("eth_getTransactionReceipt", [h], allow_error=True)
        if r:
            return r
        time.sleep(3)
    return None


def has_code(rpc, a):
    return len(rpc.call("eth_getCode", [a, "latest"]) or "0x") > 2


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--plan", required=True, help="forge broadcast file of the fork run")
    p.add_argument("--chain-id", required=True, type=int)
    g = p.add_mutually_exclusive_group()
    g.add_argument("--rpc", help="a local anvil or the public testnet RPC")
    g.add_argument("--rpc-env", default="HYPEREVM_RPC_URL", help="environment variable holding the RPC URL")
    p.add_argument("--account", required=True, help="Foundry keystore name (cast wallet list)")
    p.add_argument("--keystore-dir", default=None)
    p.add_argument("--password-file", default=None, help="rehearsals with a throwaway keystore only")
    p.add_argument("--gas-price", type=int, default=None, help="wei; default: eth_bigBlockGasPrice x 1.2")
    p.add_argument("--margin", type=float, default=1.25, help="gas limit = fork gas used x margin (at least forge's)")
    p.add_argument("--timeout", type=int, default=600, help="seconds to wait for each receipt (big blocks: 1/min)")
    p.add_argument("--record-in", default=None, help="the deployment record the fork run wrote")
    p.add_argument("--record-out", default=None, help="where to write the live record (block and time from chain)")
    p.add_argument("--yes", action="store_true", help="rehearsals only: no prompt")
    p.add_argument("--stop-after", type=int, default=None, help="rehearsals only: stop after N sends (resume test)")
    a = p.parse_args()

    url = a.rpc or os.environ.get(a.rpc_env or "")
    if not url:
        sys.exit(f"set {a.rpc_env} or pass --rpc")
    rpc = Rpc(url)
    chain = h2i(rpc.call("eth_chainId"))
    if chain != a.chain_id:
        sys.exit(f"the RPC is chain {chain}, not {a.chain_id}")
    steps = load_plan(a.plan)
    if not steps:
        sys.exit("empty plan")
    senders = {s["from"] for s in steps}
    if len(senders) != 1:
        sys.exit(f"the plan has several senders: {senders}")
    sender = senders.pop()
    for s in steps:
        if s["chain"] not in (0, a.chain_id):
            sys.exit(f"the plan was made for chain {s['chain']}, not {a.chain_id}")
    nonces = [s["nonce"] for s in steps]
    if nonces != list(range(nonces[0], nonces[0] + len(nonces))):
        sys.exit(f"the plan's nonces are not consecutive: {nonces}")

    if a.gas_price is not None:
        price = a.gas_price
    else:
        bb = rpc.call("eth_bigBlockGasPrice", allow_error=True)
        if bb is None:
            sys.exit("eth_bigBlockGasPrice is not available on this RPC: pass --gas-price")
        price = math.ceil(h2i(bb) * 1.2)

    live = h2i(rpc.call("eth_getTransactionCount", [sender, "latest"]))
    pending = h2i(rpc.call("eth_getTransactionCount", [sender, "pending"]))
    if live < nonces[0]:
        sys.exit(f"the sender's nonce is {live}, the plan starts at {nonces[0]}: re-plan")
    if pending != live:
        sys.exit(f"the sender has {pending - live} pending transaction(s): wait for them, then run again")
    # nonces already used must be ours, with their planned effect on chain
    for s in steps:
        if s["nonce"] < live and (s["kind"] not in CREATES or not s["address"] or not has_code(rpc, s["address"])):
            sys.exit(f"nonce {s['nonce']} is used on chain but the planned {s['name'] or s['fn']} is not there: "
                     "something else was sent from this address; re-plan")
    todo = [s for s in steps if s["nonce"] >= live]
    # receipts of this plan, kept next to it, so a resumed run still knows the deploy block
    prog_path = a.plan + ".sent.json"
    prog = {}
    if os.path.isfile(prog_path):
        with open(prog_path) as f:
            prog = json.load(f)

    total = sum(gas_limit(s, a.margin) for s in todo)
    print(f"chain {chain}, sender {sender}, nonce {live}, gas price {price} wei")
    print(f"{len(steps)} planned transactions, {len(steps) - len(todo)} already on chain, {len(todo)} to send:")
    for s in steps:
        tag = "done" if s["nonce"] < live else "send"
        what = s["name"] + (f".{s['fn']}" if s["fn"] else "") if s["kind"] not in CREATES else f"new {s['name']}"
        print(f"  {tag} nonce {s['nonce']:>4} {s['kind']:<6} {what:<46} gas {gas_limit(s, a.margin):>10,} "
              f"(fork used {s['used']:>10,}) {s['address'] or s['to']}")
    bal = h2i(rpc.call("eth_getBalance", [sender, "latest"]))
    cost = total * price + sum(s["value"] for s in todo)
    print(f"at most {cost / 1e18:.6f} native for gas and value; balance {bal / 1e18:.6f}")
    if bal < cost:
        sys.exit("the balance does not cover the gas limits at this price")
    if not todo:
        print("nothing to send")
    else:
        wallet = load_wallet(a.account, a.keystore_dir, a.password_file)
        if wallet.address.lower() != sender:
            sys.exit(f"the keystore {a.account} is {wallet.address}, the plan's sender is {sender}")
        if not a.yes and input(f'type "yes" to sign and send {len(todo)} transactions on chain {chain}: ').strip() != "yes":
            sys.exit("not sent")
        sent = 0
        for s in todo:
            tx = {"nonce": s["nonce"], "gas": gas_limit(s, a.margin), "gasPrice": price, "value": s["value"],
                  "data": s["data"], "chainId": chain}
            if s["kind"] != "CREATE":
                tx["to"] = to_checksum_address(s["to"])
            raw = wallet.sign_transaction(tx)
            raw_hex = raw.raw_transaction.hex() if hasattr(raw, "raw_transaction") else raw.rawTransaction.hex()
            h = rpc.call("eth_sendRawTransaction", [raw_hex if raw_hex.startswith("0x") else "0x" + raw_hex])
            print(f"  sent nonce {s['nonce']} {h}", flush=True)
            r = wait_receipt(rpc, h, a.timeout)
            if r is None:
                sys.exit(f"no receipt after {a.timeout}s for {h}: check the gas price (eth_bigBlockGasPrice), then "
                         "run the same command again (it resumes)")
            if h2i(r["status"]) != 1:
                sys.exit(f"reverted on chain: {h} (gas used {h2i(r['gasUsed']):,} of {tx['gas']:,})")
            if s["kind"] == "CREATE" and (r.get("contractAddress") or "").lower() != s["address"]:
                sys.exit(f"created {r.get('contractAddress')}, planned {s['address']}")
            if s["kind"] in CREATES and not has_code(rpc, s["address"]):
                sys.exit(f"no code at the planned {s['address']} ({s['name']}) after {h}")
            print(f"  ok   block {h2i(r['blockNumber'])} gas used {h2i(r['gasUsed']):,} (fork {s['used']:,})", flush=True)
            prog[str(s["nonce"])] = {"hash": h, "block": h2i(r["blockNumber"]), "gasUsed": h2i(r["gasUsed"])}
            with open(prog_path, "w") as f:
                json.dump(prog, f, indent=2)
            sent += 1
            if a.stop_after is not None and sent >= a.stop_after:
                sys.exit(f"stopped after {sent} (--stop-after)")

    for s in steps:
        if s["kind"] in CREATES and s["address"] and not has_code(rpc, s["address"]):
            sys.exit(f"no code at {s['address']} ({s['name']})")
    print(f"ALL SENT: {len(steps)} transactions, every created contract has code")

    if a.record_out:
        if not a.record_in:
            sys.exit("--record-out needs --record-in")
        with open(a.record_in) as f:
            rec = json.load(f)
        if int(rec["chainId"]) != chain:
            sys.exit("the fork record is for another chain")
        # the deploy block: the receipt block of the plan's first transaction (kept in the progress file)
        first = prog.get(str(steps[0]["nonce"]))
        if first is None:
            sys.exit(f"no receipt of nonce {steps[0]['nonce']} in {prog_path}: set the record's block by hand")
        block = first["block"]
        b = rpc.call("eth_getBlockByNumber", [hex(block), False])
        rec["block"] = block
        rec["timestamp"] = h2i(b["timestamp"])
        with open(a.record_out, "w") as f:
            json.dump(rec, f, indent=2)
            f.write("\n")
        print(f"Written {a.record_out} (block {block})")


if __name__ == "__main__":
    main()
