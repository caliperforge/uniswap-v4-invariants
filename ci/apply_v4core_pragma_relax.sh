#!/usr/bin/env bash
# substrate-modern reproducible patch: upstream v4-core v1.0.2 ships
# lib/v4-core/src/PoolManager.sol with `pragma solidity 0.8.26;` (exact
# pin). foundry.toml on substrate-modern pins solc 0.8.33 (documented
# combo-wall rationale: Moonpot's exact `0.8.33` pragma + Labs BaseHook
# lineage + live Permit2/POSM). Foundry refuses `=0.8.26` when
# `solc_version = "0.8.33"` is set, so we relax that one pragma
# reproducibly on every fresh clone / CI checkout. Caret keeps the
# minimum floor at 0.8.26 so no other invariant is loosened.
#
# Rails:
#   - Only touches the ONE file whose exact pin is documented as needing
#     a relax. Any other pragma edit is out of scope.
#   - Idempotent: re-running is a no-op once the caret is in.
#   - Fails hard if the file is missing or the expected pin is absent
#     (both indicate the submodule pointer has drifted and the CI
#     assumptions need re-review — do NOT silently continue).
#   - Uses portable sed (BSD + GNU both).
#
# Invoked from .github/workflows/{ci,bring-your-hook}.yml between the
# `submodules: recursive` checkout step and the `forge build` step.

set -euo pipefail

FILE="lib/v4-core/src/PoolManager.sol"

if [[ ! -f "$FILE" ]]; then
    echo "apply_v4core_pragma_relax.sh: $FILE not found — submodule not initialized?" >&2
    exit 1
fi

if grep -qE '^pragma solidity \^0\.8\.26;' "$FILE"; then
    echo "apply_v4core_pragma_relax.sh: pragma already relaxed in $FILE — no-op."
    exit 0
fi

if ! grep -qE '^pragma solidity 0\.8\.26;' "$FILE"; then
    echo "apply_v4core_pragma_relax.sh: expected 'pragma solidity 0.8.26;' NOT found in $FILE." >&2
    echo "apply_v4core_pragma_relax.sh: submodule pointer may have drifted; re-review before continuing." >&2
    head -5 "$FILE" >&2
    exit 2
fi

# Portable in-place edit (works on BSD sed via -i.bak, and GNU sed).
tmp=$(mktemp)
sed 's/^pragma solidity 0\.8\.26;/pragma solidity ^0.8.26;/' "$FILE" > "$tmp"
mv "$tmp" "$FILE"

# Post-condition
if ! grep -qE '^pragma solidity \^0\.8\.26;' "$FILE"; then
    echo "apply_v4core_pragma_relax.sh: patch did not apply cleanly." >&2
    exit 3
fi

echo "apply_v4core_pragma_relax.sh: relaxed $FILE to '^0.8.26'."
