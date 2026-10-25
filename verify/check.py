"""Check the round 2 release bytecode.

  python verify/check.py [--solc <path>]
      Compiles verify/solc-input.json (the release's exact compiler input) with solc 0.8.28 and compares the 13
      deployable contracts with audit/fix-round/RELEASE-BYTECODE.md. Prints ALL MATCH when every hash matches.

  python verify/check.py [--solc <path>] --rpc <url> --record deployments/mainnet.json|deployments/arbitrum.json
      The same build, then the code deployed at the record's addresses (eth_getCode) against the same table.

Hashes are keccak256 of the bytecode with every value known only at deploy time set to zero bytes: linked library
addresses, immutables (the factories' constructor values) and a library's own deploy address. The compiled artifact
holds zeros there too, so the build and the chain compare equal. The RPC URL is used for eth_getCode only.

Needs Python 3.8+ and the solc 0.8.28+commit.7893614a binary (from https://binaries.soliditylang.org, or Foundry's
copy, which `forge build` downloads); no Python packages.
"""

import json
import os
import re
import subprocess
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
INPUT = os.path.join(ROOT, "verify", "solc-input.json")
TABLE = os.path.join(ROOT, "audit", "fix-round", "RELEASE-BYTECODE.md")
SOLC_VERSION = "0.8.28+commit.7893614a"

# contract -> (source file in the compiler input, record key)
DEPLOYABLE = {
    999: [
        ("VaultLogic", "src/VaultLogic.sol", "vaultLogicLibrary"),
        ("VaultGovernance", "src/VaultGovernance.sol", "vaultGovernanceLibrary"),
        ("HyperVault", "src/HyperVault.sol", "vaultImplementation"),
        ("VaultPolicy", "src/VaultPolicy.sol", "policyImplementation"),
        ("HyperVaultLens", "src/HyperVaultLens.sol", "lens"),
        ("HyperVaultFactory", "src/HyperVaultFactory.sol", "factory"),
    ],
    42161: [
        ("GainsNav", "src/gains/GainsNav.sol", "gainsNavLibrary"),
        ("GainsVaultLogic", "src/gains/GainsVaultLogic.sol", "vaultLogicLibrary"),
        ("GainsVaultGovernance", "src/gains/GainsVaultGovernance.sol", "vaultGovernanceLibrary"),
        ("GainsVault", "src/gains/GainsVault.sol", "vaultImplementation"),
        ("GainsVaultPolicy", "src/gains/GainsVaultPolicy.sol", "policyImplementation"),
        ("GainsVaultLens", "src/gains/GainsVaultLens.sol", "lens"),
        ("GainsVaultFactory", "src/gains/GainsVaultFactory.sol", "factory"),
    ],
}

# ---------------------------------------------------------------- keccak256 (Keccak-f[1600], the pre-SHA-3 padding)
_RC = [
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000, 0x000000000000808B,
    0x0000000080000001, 0x8000000080008081, 0x8000000000008009, 0x000000000000008A, 0x0000000000000088,
    0x0000000080008009, 0x000000008000000A, 0x000000008000808B, 0x800000000000008B, 0x8000000000008089,
    0x8000000000008003, 0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
]
_ROT = [[0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61], [28, 55, 25, 21, 56], [27, 20, 39, 8, 14]]
_M = (1 << 64) - 1


def _f(a):
    for rc in _RC:
        c = [a[x][0] ^ a[x][1] ^ a[x][2] ^ a[x][3] ^ a[x][4] for x in range(5)]
        d = [c[(x - 1) % 5] ^ (((c[(x + 1) % 5] << 1) | (c[(x + 1) % 5] >> 63)) & _M) for x in range(5)]
        a = [[a[x][y] ^ d[x] for y in range(5)] for x in range(5)]
        b = [[0] * 5 for _ in range(5)]
        for x in range(5):
            for y in range(5):
                r = _ROT[x][y]
                b[y][(2 * x + 3 * y) % 5] = ((a[x][y] << r) | (a[x][y] >> (64 - r))) & _M if r else a[x][y]
        a = [[b[x][y] ^ ((~b[(x + 1) % 5][y]) & b[(x + 2) % 5][y]) for y in range(5)] for x in range(5)]
        a[0][0] ^= rc
    return a


def keccak256(data: bytes) -> str:
    rate = 136
    msg = bytearray(data) + b"\x01"
    msg += b"\x00" * ((-len(msg)) % rate)
    msg[-1] |= 0x80
    a = [[0] * 5 for _ in range(5)]
    for off in range(0, len(msg), rate):
        block = msg[off : off + rate]
        for i in range(rate // 8):
            a[i % 5][i // 5] ^= int.from_bytes(block[8 * i : 8 * i + 8], "little")
        a = _f(a)
    out = b"".join(a[i % 5][i // 5].to_bytes(8, "little") for i in range(4))
    return "0x" + out.hex()


assert keccak256(b"") == "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470"

# ---------------------------------------------------------------- hashes


def zeroed(code_hex, links, immutables=None):
    """Bytecode with every link reference and immutable zeroed (placeholders __$..$__ become zeros too)."""
    h = code_hex[2:] if code_hex.startswith("0x") else code_hex
    h = re.sub(r"__\$[0-9a-fA-F]{34}\$__", "0" * 40, h)
    b = bytearray(bytes.fromhex(h))
    ranges = [(r["start"], r["length"]) for libs in (links or {}).values() for rs in libs.values() for r in rs]
    ranges += [(r["start"], r["length"]) for rs in (immutables or {}).values() for r in rs]
    for start, length in ranges:
        b[start : start + length] = bytes(length)
    return bytes(b)


def table():
    rows = {}
    with open(TABLE, encoding="utf-8") as fh:
        for line in fh:
            m = re.match(r"\|\s*(\w+)\s*\|\s*(\w+)\s*\|\s*`(0x[0-9a-f]{64})`\s*\|\s*([\d,]+)\s*\|\s*`(0x[0-9a-f]{64})`\s*\|", line)
            if m:
                rows[m.group(1)] = (m.group(3), m.group(5))
    return rows


def find_solc(argv):
    if "--solc" in argv:
        return argv[argv.index("--solc") + 1]
    home = os.path.expanduser("~")
    for p in (
        os.path.join(home, ".svm", "0.8.28", "solc-0.8.28"),
        os.path.join(home, ".svm", "0.8.28", "solc-0.8.28.exe"),
        os.path.join(os.environ.get("APPDATA", ""), "svm", "0.8.28", "solc-0.8.28"),
        os.path.join(os.environ.get("APPDATA", ""), "svm", "0.8.28", "solc-0.8.28.exe"),
        "solc",
    ):
        try:
            if SOLC_VERSION in subprocess.run([p, "--version"], capture_output=True, text=True).stdout:
                return p
        except OSError:
            pass
    sys.exit(f"solc {SOLC_VERSION} not found: pass --solc <path> (run `forge build` once to let Foundry fetch it)")


def compile_release(solc):
    with open(INPUT, encoding="utf-8") as fh:
        job = json.load(fh)
    # Only the 13 deployable contracts get code: the output depends on the sources and settings, not on this.
    sel = ["evm.bytecode.object", "evm.bytecode.linkReferences", "evm.deployedBytecode.object",
           "evm.deployedBytecode.linkReferences", "evm.deployedBytecode.immutableReferences"]
    job["settings"]["outputSelection"] = {src: {name: sel} for c in DEPLOYABLE.values() for name, src, _ in c}
    out = subprocess.run([solc, "--version"], capture_output=True, text=True).stdout
    if SOLC_VERSION not in out:
        sys.exit(f"{solc} is not solc {SOLC_VERSION}")
    print(f"compiling verify/solc-input.json ({len(job['sources'])} sources) with solc {SOLC_VERSION}, via_ir: "
          "about a minute")
    res = subprocess.run([solc, "--standard-json"], input=json.dumps(job), capture_output=True, text=True)
    if res.returncode != 0 and not res.stdout:
        sys.exit(res.stderr)
    data = json.loads(res.stdout)
    errors = [e for e in data.get("errors", []) if e["severity"] == "error"]
    if errors:
        sys.exit("\n".join(e["formattedMessage"] for e in errors))
    return data["contracts"]


def main(argv):
    want = table()
    built = compile_release(find_solc(argv))
    bad = 0
    if "--rpc" in argv:
        url = argv[argv.index("--rpc") + 1]
        with open(argv[argv.index("--record") + 1], encoding="utf-8") as fh:
            record = json.load(fh)
        for name, src, key in DEPLOYABLE[record["chainId"]]:
            evm = built[src][name]["evm"]["deployedBytecode"]
            body = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "eth_getCode", "params": [record[key], "latest"]})
            req = urllib.request.Request(url, body.encode(), {"content-type": "application/json", "user-agent": "check.py"})
            code = json.load(urllib.request.urlopen(req, timeout=30))["result"]
            got = keccak256(zeroed(code, evm.get("linkReferences"), evm.get("immutableReferences")))
            ok = got == want[name][0]
            bad += not ok
            print(f"{'match   ' if ok else 'MISMATCH'} {name:22} {record[key]} {got}")
    else:
        for chain in DEPLOYABLE.values():
            for name, src, _ in chain:
                evm = built[src][name]["evm"]
                rt = keccak256(zeroed(evm["deployedBytecode"]["object"], evm["deployedBytecode"].get("linkReferences"),
                                      evm["deployedBytecode"].get("immutableReferences")))
                cr = keccak256(zeroed(evm["bytecode"]["object"], evm["bytecode"].get("linkReferences")))
                ok = want.get(name) == (rt, cr)
                bad += not ok
                print(f"{'match   ' if ok else 'MISMATCH'} {name:22} runtime {rt}")
    print("ALL MATCH" if bad == 0 else f"{bad} MISMATCH")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
