"""Unit tests for ci/registry_hook_config.py. Offline: no network."""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from registry_hook_config import (  # noqa: E402
    build_frame,
    derive_ctor_expr,
    derive_flags_expr,
    src_root_and_entry,
)


def _entry(addr, chain_id, flags):
    base = {
        "beforeSwapReturnsDelta": False,
        "afterSwapReturnsDelta": False,
        "afterAddLiquidityReturnsDelta": False,
        "afterRemoveLiquidityReturnsDelta": False,
    }
    base.update(flags)
    return {
        "hook": {"address": addr, "chainId": chain_id},
        "flags": base,
    }


def test_build_frame_filters_and_sorts():
    entries = [
        _entry("0x00000000000000000000000000000000000000c8", 1,
               {"afterSwapReturnsDelta": True}),
        _entry("0x0000000000000000000000000000000000000064", 8453,
               {"beforeSwapReturnsDelta": True}),
        # no delta flag: excluded
        _entry("0x0000000000000000000000000000000000000001", 1, {}),
        # allowlisted: excluded
        _entry("0x00000000000000000000000000000000000000aa", 1,
               {"afterSwapReturnsDelta": True}),
        # duplicate address on a second chain: deduped, chain collected
        _entry("0x0000000000000000000000000000000000000064", 130,
               {"beforeSwapReturnsDelta": True}),
    ]
    allow = "allowlist: 0x00000000000000000000000000000000000000aa"
    frame = build_frame(json.dumps(entries).encode(), allow)
    assert [r["address"] for r in frame] == [
        "0x0000000000000000000000000000000000000064",
        "0x00000000000000000000000000000000000000c8",
    ]
    assert frame[0]["chain_ids"] == [130, 8453]


def test_derive_ctor_pool_manager_substitution():
    decoded = [
        ["0x000000000004444c5dc75cB358380D2e3dE08A90",
         {"internalType": "contract IPoolManager", "name": "pm",
          "type": "address"}],
    ]
    expr, limits = derive_ctor_expr(decoded)
    assert expr == "address(manager)"
    assert limits == []


def test_derive_ctor_plain_address_literal():
    decoded = [
        ["0x000000000004444c5dc75cB358380D2e3dE08A90",
         {"internalType": "contract IPoolManager", "name": "pm",
          "type": "address"}],
        ["0x49EF9869FC358b6E755C722eA8514A574Bd8CE8e",
         {"internalType": "address", "name": "vault_", "type": "address"}],
    ]
    expr, limits = derive_ctor_expr(decoded)
    assert expr == ("address(manager), "
                    "address(0x49EF9869FC358b6E755C722eA8514A574Bd8CE8e)")
    assert limits == []


def test_derive_ctor_live_contract_arg_records_limit():
    decoded = [
        ["0x509aC564F6ed0A31AD231E8608e9f1156803D7a3",
         {"internalType": "contract IArkFeeRouter", "name": "feeRouter_",
          "type": "address"}],
    ]
    expr, limits = derive_ctor_expr(decoded)
    assert expr == "address(0x509aC564F6ed0A31AD231E8608e9f1156803D7a3)"
    assert len(limits) == 1
    assert "LIVE_CONTRACT_ARG" in limits[0]


def test_derive_ctor_value_types():
    decoded = [
        ["0", {"internalType": "uint24", "name": "fee", "type": "uint24"}],
        ["true", {"internalType": "bool", "name": "on", "type": "bool"}],
        ["hi", {"internalType": "string", "name": "n", "type": "string"}],
    ]
    expr, limits = derive_ctor_expr(decoded)
    assert expr == 'uint24(0), true, "hi"'
    assert limits == []


def test_derive_ctor_tuple_unsupported():
    decoded = [
        [["0x1", "2"], {"internalType": "struct X", "name": "cfg",
                        "type": "tuple", "components": []}],
    ]
    expr, limits = derive_ctor_expr(decoded)
    assert expr is None
    assert any("UNSUPPORTED_ARG_SHAPE" in l for l in limits)


def test_derive_ctor_empty():
    assert derive_ctor_expr(None) == ("", [])
    assert derive_ctor_expr([]) == ("", [])


def test_derive_flags_low14():
    # low 14 bits of the deployed address encode the permissions
    assert derive_flags_expr("0x745d717620052a97a22deee2e5eba59583f3e0cc") == "8396"
    assert derive_flags_expr("0xced7aa50727f3cd251985b09a2080db056a8c0cc") == "204"


def test_src_root_topmost_component(tmp_path):
    root, entry = src_root_and_entry(str(tmp_path), "src/hooks/A.sol")
    assert root == os.path.join(str(tmp_path), "src")
    assert entry == os.path.join(str(tmp_path), "src", "hooks", "A.sol")
    root2, entry2 = src_root_and_entry(str(tmp_path), "A.sol")
    assert root2 == str(tmp_path)
