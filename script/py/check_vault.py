"""Print a vault's HyperCore state: coreActive (EVM precompile view), perp equity, spot balances incl. HYPE,
approved agents (API wallets) and the recent non-funding ledger.

usage: python check_vault.py <address> [--mainnet] [--lens 0x...]
Read only, no key needed.
"""
import json
import sys

import requests
from eth_utils import keccak
from hyperliquid.info import Info
from hyperliquid.utils import constants

if len(sys.argv) < 2:
    sys.exit("usage: check_vault.py <address> [--mainnet] [--lens 0x...]")
user = sys.argv[1]
mainnet = "--mainnet" in sys.argv
api = constants.MAINNET_API_URL if mainnet else constants.TESTNET_API_URL
rpc = "https://rpc.hyperliquid.xyz/evm" if mainnet else "https://rpc.hyperliquid-testnet.xyz/evm"
info = Info(api, skip_ws=True)


def evm_call(sig: str) -> str:
    sel = "0x" + keccak(text=sig).hex()[:8]
    body = {"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [{"to": user, "data": sel}, "latest"]}
    r = requests.post(rpc, json=body, timeout=20).json()
    return r.get("result") or f"error: {r.get('error')}"


def as_bool(hexdata: str) -> str:
    if not hexdata.startswith("0x") or len(hexdata) < 66:
        # The legacy DojiPad Vault predates the clone factory and has no hosted()/protocolShareBps() selectors.
        return "n/a (legacy vault, no such selector)"
    return "true" if hexdata.endswith("1") else "false"


def lens_address() -> str | None:
    """--lens 0x... wins; otherwise contracts/deployments/mainnet.json next to this script's repo."""
    if "--lens" in sys.argv:
        return sys.argv[sys.argv.index("--lens") + 1]
    import os
    rec = os.path.join(os.path.dirname(__file__), "..", "..", "deployments", "mainnet.json" if mainnet else "testnet.json")
    try:
        with open(rec) as f:
            return json.load(f).get("lens")
    except OSError:
        return None


def lens_call(lens: str, sig: str) -> str:
    """Lens views take the vault as their only argument."""
    sel = "0x" + keccak(text=sig).hex()[:8]
    data = sel + user[2:].lower().rjust(64, "0")
    body = {"jsonrpc": "2.0", "id": 1, "method": "eth_call", "params": [{"to": lens, "data": data}, "latest"]}
    r = requests.post(rpc, json=body, timeout=20).json()
    return r.get("result") or f"error: {r.get('error')}"


print("VAULT", user, "|", "mainnet" if mainnet else "testnet")
is_factory_vault = as_bool(evm_call("hosted()")) != "n/a (legacy vault, no such selector)"
if is_factory_vault:
    lens = lens_address()
    if lens:
        print("LENS", lens)
        print("coreActive():", as_bool(lens_call(lens, "coreActive(address)")), "| epochOverdue():", as_bool(lens_call(lens, "epochOverdue(address)")), "(HyperVaultLens; factory vaults have no coreActive() of their own)")
    else:
        print("coreActive(): unknown (no lens: pass --lens 0x... or keep contracts/deployments/mainnet.json)")
else:
    print("coreActive():", as_bool(evm_call("coreActive()")), "(legacy vault selector)")
print("hosted():    ", as_bool(evm_call("hosted()")))
print("breached():  ", as_bool(evm_call("breached()")), "| emergency():", as_bool(evm_call("emergency()")))
agent = evm_call("agent()")
print("agent():     ", "0x" + agent[-40:] if agent.startswith("0x") else agent)

perp = info.user_state(user)
print("PERP accountValue:", perp["marginSummary"]["accountValue"], "withdrawable:", perp["withdrawable"])

spot = info.spot_user_state(user)
balances = [(b["coin"], b["total"]) for b in spot["balances"] if float(b["total"]) > 0]
print("SPOT balances:", balances)
print("SPOT USDC:", next((t for c, t in balances if c == "USDC"), "0"), "| SPOT HYPE:", next((t for c, t in balances if c == "HYPE"), "0"))

try:
    agents = info.post("/info", {"type": "extraAgents", "user": user})
    print("AGENTS (extraAgents):", [(a.get("name"), a.get("address"), a.get("validUntil")) for a in agents])
except Exception as e:  # noqa: BLE001
    print("AGENTS: lookup failed:", e)

ledger = info.post("/info", {"type": "userNonFundingLedgerUpdates", "user": user, "startTime": 0})
print("LEDGER (last 10):")
for row in ledger[-10:]:
    print(json.dumps(row["delta"]))
