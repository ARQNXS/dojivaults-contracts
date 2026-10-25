"""Enable or disable HyperEVM big blocks for the deployer (needed to deploy the ~23KB vault).

usage: python bigblocks.py [on|off] [--mainnet] [--account <foundry keystore name>]
With --account the key is read from ~/.foundry/keystores/<name> (the keystore `cast wallet import` writes); the password
is asked without echo and the key stays in memory. Without it, the key is read from env PK (older runbooks).
"""
import getpass
import json
import os
import sys

import eth_account
from hyperliquid.exchange import Exchange
from hyperliquid.utils import constants

argv = sys.argv[1:]
name = None
if "--account" in argv:
    i = argv.index("--account")
    if i + 1 >= len(argv):
        sys.exit("--account needs a keystore name")
    name = argv[i + 1]
    del argv[i : i + 2]

args = [a for a in argv if not a.startswith("--")]
enable = (args[0] if args else "on") != "off"
api = constants.MAINNET_API_URL if "--mainnet" in argv else constants.TESTNET_API_URL

if name is None:
    wallet = eth_account.Account.from_key(os.environ["PK"])
else:
    with open(os.path.join(os.path.expanduser("~"), ".foundry", "keystores", name), encoding="utf8") as f:
        keystore = json.load(f)
    wallet = eth_account.Account.from_key(eth_account.Account.decrypt(keystore, getpass.getpass(f"Password for keystore {name}: ")))
print("Address:", wallet.address, "| big blocks:", enable, "|", api)
print(Exchange(wallet, api).use_big_blocks(enable))
