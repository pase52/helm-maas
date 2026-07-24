#!/usr/bin/env bash
# =============================================================================
# Argo CD health-check test suite
# =============================================================================
# Renders the maas-gitops chart, extracts the Lua health checks, and runs them
# against the fixtures in cases.txt using gopher-lua — the same interpreter
# Argo CD embeds.
#
# Why this exists: a Lua syntax error or a wrong branch does not fail a Helm
# render or an Argo CD sync. It fails silently at runtime, and the symptom is a
# broken model showing a green tick. This suite is the only thing that catches it.
#
# Requires: helm, yq, go (network access to proxy.golang.org on first run).
# Usage:    ./tests/lua/run.sh
# =============================================================================
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

for tool in helm yq go; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 1; }
done

echo "==> Building Lua harness"
(cd "${HERE}" && go build -o "${WORK}/luatest" .)

echo "==> Rendering health checks from charts/maas-gitops"
helm template healthcheck-test "${ROOT}/charts/maas-gitops" \
  --kube-version 1.32.0 \
  --set healthChecks.configMap.enabled=true \
  2>/dev/null \
  | yq -r 'select(.kind=="ConfigMap") | .data["patch.yaml"]' > "${WORK}/patch.yaml"

mapfile -t KINDS < <(yq -r '.spec.resourceHealthChecks[].kind' "${WORK}/patch.yaml")
for kind in "${KINDS[@]}"; do
  yq -r ".spec.resourceHealthChecks[] | select(.kind==\"${kind}\") | .check" \
    "${WORK}/patch.yaml" > "${WORK}/${kind}.lua"
done
echo "    extracted: ${KINDS[*]}"

echo "==> Running cases"
pass=0; fail=0
while IFS= read -r line; do
  [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]] && continue

  kind="$(cut -d'|' -f1 <<<"${line}" | xargs)"
  want="$(cut -d'|' -f2 <<<"${line}" | xargs)"
  desc="$(cut -d'|' -f3 <<<"${line}" | xargs)"
  obj="$(cut -d'|' -f4- <<<"${line}" | sed 's/^[[:space:]]*//')"

  if [[ ! -f "${WORK}/${kind}.lua" ]]; then
    printf 'SKIP  %-20s %s (check disabled in values)\n' "${kind}" "${desc}"
    continue
  fi

  printf '%s' "${obj}" > "${WORK}/obj.json"
  if ! out="$("${WORK}/luatest" "${WORK}/${kind}.lua" "${WORK}/obj.json" 2>&1)"; then
    printf 'FAIL  %-20s %s\n        lua error: %s\n' "${kind}" "${desc}" "${out}"
    fail=$((fail + 1)); continue
  fi

  got="$(cut -f1 <<<"${out}")"
  msg="$(cut -f2- <<<"${out}")"
  if [[ "${got}" == "${want}" ]]; then
    printf 'ok    %-20s %-48s -> %s\n' "${kind}" "${desc}" "${msg}"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-20s %s\n        want=%s got=%s (%s)\n' "${kind}" "${desc}" "${want}" "${got}" "${msg}"
    fail=$((fail + 1))
  fi
done < "${HERE}/cases.txt"

echo
echo "==> ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
