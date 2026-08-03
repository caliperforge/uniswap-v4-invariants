#!/usr/bin/env bash
# run_registry_hook.sh -- one command from a public deployment to a full
# caliper walk, with every input derived rather than typed (T-P034-B1).
#
# Usage:
#   ci/run_registry_hook.sh --rule-index J [workdir]
#       Resolve the target by the published deterministic sampling rule
#       (see ci/registry_hook_config.py header), fetch its verified
#       source, derive flags + constructor args from the deployed
#       address and the decoded on-chain ABI, then run
#       `./caliper run <entry>` on it.
#
#   ci/run_registry_hook.sh --address 0x... --chain-id N [workdir]
#       Same, for an explicit deployment.
#
# The derived configuration is printed before the run and persisted at
# <workdir>/_derived.env; provenance (resolved address, compiler,
# decoded args, limits) at <workdir>/_meta.json. Nothing is hand-typed
# per hook, and no target source is edited.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

STEP="args"
on_err() {
  local rc=$?
  echo ""
  echo "run-registry-hook: FAIL at step '${STEP}' (rc=${rc})."
  exit "$rc"
}
trap on_err ERR

SELECT_ARGS=()
WORKDIR=""
while [ $# -gt 0 ]; do
  case "$1" in
    --rule-index|--address|--chain-id)
      SELECT_ARGS+=("$1" "$2"); shift 2 ;;
    *)
      WORKDIR="$1"; shift ;;
  esac
done
if [ ${#SELECT_ARGS[@]} -eq 0 ]; then
  echo "usage: ci/run_registry_hook.sh (--rule-index J | --address 0x... --chain-id N) [workdir]"
  exit 4
fi
if [ -z "${WORKDIR}" ]; then
  WORKDIR="$(mktemp -d /tmp/caliper-registry.XXXXXX)"
fi

STEP="derive-config"
python3 ci/registry_hook_config.py "${SELECT_ARGS[@]}" --outdir "${WORKDIR}"

STEP="load-config"
# shellcheck disable=SC1091
. "${WORKDIR}/_derived.env"

STEP="caliper-run"
./caliper run "${CALIPER_REGISTRY_HOOK_ENTRY}"
