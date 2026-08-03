#!/usr/bin/env python3
"""Registry-hook config derivation (T-P034-B1, wall W5 automation).

Given a deployed, source-verified v4 hook, assemble everything the
`./caliper run <hook.sol>` adopter path needs, with ZERO hand-typed
per-hook input:

  1. Fetch the verified source file set from a public Blockscout
     instance (keyless, read-only) and materialise it into a workdir.
  2. Derive `CALIPER_HOOK_FLAGS_EXPR` mechanically from the deployed
     address: v4 requires the low 14 address bits to encode the hook's
     permissions, so the address IS the flags.
  3. Derive `CALIPER_HOOK_CTOR_ARGS_EXPR` mechanically from the
     explorer's decoded constructor arguments (the on-chain ABI), by a
     fixed type-driven mapping with no per-hook cases:

       param internalType `contract IPoolManager` -> `address(manager)`
           (the harness substitutes its local PoolManager; that
           substitution is the entire point of the fuzz environment)
       plain `address` / other value types        -> the decoded
           on-chain literal, verbatim
       any OTHER `contract X` internalType        -> the decoded
           literal, PLUS a recorded LIMIT line: the live dependency
           contract is NOT present in the fuzz environment. Serving
           such hooks is out of scope by rule; we record the limit
           rather than special-case it.
       tuple / array params                       -> unsupported;
           derivation refuses with a recorded LIMIT and the run
           proceeds with no ctor override (the previous cold
           behaviour), so the outcome stays mechanical.

  4. Write a shell-sourceable `_derived.env` next to the fetched
     source, so a reader sees exactly what was derived rather than
     typed, and `_meta.json` with full provenance (resolved address,
     compiler, decoded args).

Selection modes:
  --address 0x... --chain-id N     explicit target
  --rule-index J                   resolve the target by the published
      deterministic sampling rule (R1-R4 of the P034 census rule set):
      frame = hooklist.json entries carrying any *ReturnsDelta flag
      whose address is absent from the routing allowlist, deduped by
      lowercased address, sorted by address as an unsigned integer;
      stride s = floor(F/10); index J picks frame[J*s]. If the frame
      entry is not source-verified, walk upward (J*s+1, ...) per the
      rule's NO_SOURCE replacement. The PRIOR_HANDPICKED and
      DUPLICATE_IMPL replacement clauses are NOT implemented here
      (recorded limit; they never fired on the 2026-08-01 frame).

Stdlib only. No pip. Exit codes: 0 ok, 2 not verified / no source,
3 unsupported ctor shape is NOT an exit condition (see above), 4 bad
usage, 5 frame/selection failure.
"""

import json
import os
import re
import sys
import urllib.request

EXPLORERS = {
    1: "https://eth.blockscout.com",
    8453: "https://base.blockscout.com",
    130: "https://unichain.blockscout.com",
    4663: "https://robinhoodchain.blockscout.com",
    42161: "https://arbitrum.blockscout.com",
    10: "https://optimism.blockscout.com",
    137: "https://polygon.blockscout.com",
}

HOOKLIST_URL = "https://raw.githubusercontent.com/Uniswap/hooklist/main/hooklist.json"
ALLOWLIST_URL = (
    "https://raw.githubusercontent.com/Uniswap/routing-api/main/lib/util/"
    "hooksAddressesAllowlist.ts"
)

DELTA_FLAG_RE = re.compile(r".*returnsdelta$", re.IGNORECASE)


def http_get(url):
    req = urllib.request.Request(url, headers={"User-Agent": "curl/8"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.read()


def build_frame(hooklist_bytes, allowlist_text):
    """R1-R3: delta-flag entries not on the routing allowlist, deduped by
    lowercased address, sorted by address as an unsigned integer.
    Returns a list of dicts: {address, chain_ids (sorted asc)}."""
    entries = json.loads(hooklist_bytes)
    allow = allowlist_text.lower()
    by_addr = {}
    for e in entries:
        flags = e.get("flags") or {}
        has_delta = any(
            bool(v) for k, v in flags.items() if DELTA_FLAG_RE.match(k)
        )
        if not has_delta:
            continue
        hook = e.get("hook") or {}
        addr = (hook.get("address") or "").lower()
        if not addr.startswith("0x"):
            continue
        if addr in allow:
            continue
        row = by_addr.setdefault(addr, {"address": addr, "chain_ids": set()})
        cid = hook.get("chainId")
        if isinstance(cid, int):
            row["chain_ids"].add(cid)
    frame = sorted(by_addr.values(), key=lambda r: int(r["address"], 16))
    for row in frame:
        row["chain_ids"] = sorted(row["chain_ids"])
    return frame


def fetch_verified(addr, chain_id):
    """Fetch the verified-contract record; None when unverified/absent."""
    base = EXPLORERS.get(chain_id)
    if base is None:
        return None
    try:
        d = json.loads(http_get(f"{base}/api/v2/smart-contracts/{addr}").decode())
    except Exception:
        return None
    if not d.get("is_verified"):
        return None
    return d


def _sol_string_escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')


def derive_ctor_expr(decoded):
    """Map the explorer's decoded constructor args to a Solidity
    argument-list expression. Returns (expr_or_None, limits).

    expr is None when the shape is unsupported (tuple/array), in which
    case the caller runs with no ctor override. expr is "" for a
    no-argument constructor."""
    limits = []
    if not decoded:
        return "", limits
    parts = []
    for value, param in decoded:
        ptype = param.get("type", "")
        itype = param.get("internalType", "") or ""
        name = param.get("name", "") or "<unnamed>"
        if ptype == "address":
            if itype == "contract IPoolManager":
                parts.append("address(manager)")
            elif itype.startswith("contract "):
                parts.append(f"address({value})")
                limits.append(
                    f"LIVE_CONTRACT_ARG {name} ({itype}): decoded literal "
                    "passed verbatim; the deployed dependency is NOT present "
                    "in the fuzz environment. Out of scope by rule."
                )
            else:
                parts.append(f"address({value})")
        elif ptype == "bool":
            parts.append("true" if str(value).lower() == "true" else "false")
        elif re.fullmatch(r"u?int\d*", ptype):
            parts.append(f"{ptype}({value})")
        elif re.fullmatch(r"bytes\d+", ptype):
            parts.append(f"{ptype}({value})")
        elif ptype == "bytes":
            hexv = str(value)[2:] if str(value).startswith("0x") else str(value)
            parts.append(f'hex"{hexv}"')
        elif ptype == "string":
            parts.append(f'"{_sol_string_escape(str(value))}"')
        else:
            limits.append(
                f"UNSUPPORTED_ARG_SHAPE {name} ({ptype}): tuple/array "
                "constructor params are not derivable mechanically; running "
                "with no ctor override."
            )
            return None, limits
    return ", ".join(parts), limits


def derive_flags_expr(addr):
    """v4 encodes hook permissions in the low 14 address bits."""
    return str(int(addr, 16) & 0x3FFF)


def src_root_and_entry(outdir, entry_rel):
    """SRC_ROOT bounds relative-import resolution: the topmost directory
    of the verified entry-file path (usually `src/`)."""
    entry_rel = entry_rel.lstrip("/")
    parts = entry_rel.split("/")
    if len(parts) > 1:
        root = os.path.join(outdir, parts[0])
    else:
        root = outdir
    return os.path.abspath(root), os.path.abspath(os.path.join(outdir, entry_rel))


def materialise(record, outdir):
    files = {record["file_path"]: record["source_code"]}
    for a in record.get("additional_sources") or []:
        files[a["file_path"]] = a["source_code"]
    os.makedirs(outdir, exist_ok=True)
    for p, src in files.items():
        fp = os.path.join(outdir, p.lstrip("/"))
        os.makedirs(os.path.dirname(fp) or outdir, exist_ok=True)
        with open(fp, "w") as f:
            f.write(src)
    return files


def main(argv):
    args = {}
    it = iter(argv)
    for a in it:
        if a in ("--address", "--chain-id", "--rule-index", "--outdir"):
            args[a[2:].replace("-", "_")] = next(it, None)
        else:
            print(f"registry-hook-config: unknown arg {a}", file=sys.stderr)
            return 4
    outdir = args.get("outdir")
    if not outdir:
        print("registry-hook-config: --outdir required", file=sys.stderr)
        return 4

    limits = []
    if args.get("rule_index") is not None:
        j = int(args["rule_index"])
        hooklist = http_get(HOOKLIST_URL)
        allowlist = http_get(ALLOWLIST_URL).decode()
        frame = build_frame(hooklist, allowlist)
        F = len(frame)
        s = F // 10
        print(f"registry-hook-config: frame F={F} stride s={s} rule-index j={j}")
        limits.append(
            "RULE_CLAUSES_NOT_IMPLEMENTED: PRIOR_HANDPICKED and "
            "DUPLICATE_IMPL replacement clauses are not implemented by this "
            "tool (never fired on the 2026-08-01 frame)."
        )
        idx = j * s
        record = None
        chain_id = None
        addr = None
        while idx < F:
            cand = frame[idx]
            for cid in cand["chain_ids"]:
                record = fetch_verified(cand["address"], cid)
                if record is not None:
                    chain_id = cid
                    addr = cand["address"]
                    break
            if record is not None:
                if idx != j * s:
                    limits.append(
                        f"NO_SOURCE_REPLACEMENT: primary index {j * s} "
                        f"replaced by upward walk to index {idx}."
                    )
                break
            idx += 1
        if record is None:
            print("registry-hook-config: NO_SOURCE for rule index and all "
                  "replacements", file=sys.stderr)
            return 5
    else:
        addr = (args.get("address") or "").lower()
        chain_id = int(args.get("chain_id") or 0)
        if not addr.startswith("0x") or chain_id == 0:
            print("registry-hook-config: need --address and --chain-id, or "
                  "--rule-index", file=sys.stderr)
            return 4
        record = fetch_verified(addr, chain_id)
        if record is None:
            print("registry-hook-config: contract not source-verified on the "
                  "explorer (or explorer unsupported)", file=sys.stderr)
            return 2

    files = materialise(record, outdir)
    flags_expr = derive_flags_expr(addr)
    ctor_expr, ctor_limits = derive_ctor_expr(record.get("decoded_constructor_args"))
    limits.extend(ctor_limits)
    src_root, entry_abs = src_root_and_entry(outdir, record["file_path"])

    meta = {
        "address": addr,
        "chain_id": chain_id,
        "name": record.get("name"),
        "compiler": record.get("compiler_version"),
        "evm_version": record.get("evm_version"),
        "entry": record["file_path"],
        "nfiles": len(files),
        "proxy_type": record.get("proxy_type"),
        "constructor_args": record.get("constructor_args"),
        "decoded_constructor_args": record.get("decoded_constructor_args"),
        "derived_flags_expr": flags_expr,
        "derived_ctor_args_expr": ctor_expr,
        "limits": limits,
    }
    meta_tmp = os.path.join(outdir, "_meta.json.tmp")
    with open(meta_tmp, "w") as f:
        json.dump(meta, f, indent=1, default=str)
    os.replace(meta_tmp, os.path.join(outdir, "_meta.json"))

    env_lines = [
        "# AUTO-DERIVED by ci/registry_hook_config.py. Nothing here was hand-typed.",
        f"export CALIPER_HOOK_FLAGS_EXPR='{flags_expr}'",
    ]
    if ctor_expr is not None and ctor_expr != "":
        env_lines.append(f"export CALIPER_HOOK_CTOR_ARGS_EXPR='{ctor_expr}'")
    env_lines.append(f"export CALIPER_HOOK_SRC_ROOT='{src_root}'")
    env_lines.append(f"export CALIPER_REGISTRY_HOOK_ENTRY='{entry_abs}'")
    env_tmp = os.path.join(outdir, "_derived.env.tmp")
    with open(env_tmp, "w") as f:
        f.write("\n".join(env_lines) + "\n")
    os.replace(env_tmp, os.path.join(outdir, "_derived.env"))

    print("registry-hook-config: derived configuration "
          "(also at _derived.env in the workdir):")
    print(f"  files fetched:   {len(files)} (verified source, keyless explorer read)")
    print(f"  flags expr:      {flags_expr}  (low 14 bits of the deployed address)")
    if ctor_expr is None:
        print("  ctor args expr:  <none: unsupported constructor shape, see limits>")
    elif ctor_expr == "":
        print("  ctor args expr:  <no-argument constructor>")
    else:
        print(f"  ctor args expr:  {ctor_expr}  (from the decoded on-chain ABI)")
    for lim in limits:
        print(f"  LIMIT: {lim}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
