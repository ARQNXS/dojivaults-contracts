"""Move USDC from the signer's HyperCore spot balance to HyperEVM (spot send to the USDC system address).

usage: python usdc_to_evm.py <amount_usdc> [--mainnet]
Reads the signing key from env PK only. The USDC arrives at the same address on HyperEVM after ~1 minute.
"""
import os
import sys

import eth_account
from hyperliquid.exchange import Exchange
from hyperliquid.info import Info
from hyperliquid.utils import constants

USDC_SYSTEM_ADDRESS = "0x2000000000000000000000000000000000000000"

args = [a for a in sys.argv[1:] if not a.startswith("--")]
if not args:
    sys.exit("usage: usdc_to_evm.py <amount_usdc> [--mainnet]")
amount = float(args[0])
api = constants.MAINNET_API_URL if "--mainnet" in sys.argv else constants.TESTNET_API_URL

wallet = eth_account.Account.from_key(os.environ["PK"])
info = Info(api, skip_ws=True)
usdc = next(t for t in info.spot_meta()["tokens"] if t["name"] == "USDC")
token = f"USDC:{usdc['tokenId']}"
print("Address:", wallet.address, "| token:", token, "| amount:", amount, "|", api)
print(Exchange(wallet, api).spot_transfer(amount, USDC_SYSTEM_ADDRESS, token))
