#!/usr/bin/env bash
# =============================================================================
# Chart render tests
# =============================================================================
# Renders every environment and asserts the structural invariants that make a
# model actually serve traffic. Run before opening a PR; wire into CI.
#
# Requires: helm, yq
# Usage:    ./tests/render.sh
# =============================================================================
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KUBE_VERSION="${KUBE_VERSION:-1.32.0}"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

pass=0
fail=0

ok()   { printf 'ok    %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf 'FAIL  %s\n        %s\n' "$1" "${2:-}"; fail=$((fail + 1)); }

for tool in helm yq; do
  command -v "${tool}" >/dev/null || { echo "missing required tool: ${tool}" >&2; exit 1; }
done

# -----------------------------------------------------------------------------
echo "==> helm lint"
# -----------------------------------------------------------------------------
for chart in maas-models maas-gitops; do
  if out="$(helm lint "${ROOT}/charts/${chart}" 2>&1)"; then
    ok "lint ${chart}"
  else
    bad "lint ${chart}" "${out}"
  fi
done

# -----------------------------------------------------------------------------
echo
echo "==> environments render and satisfy invariants"
# -----------------------------------------------------------------------------
for env_dir in "${ROOT}"/environments/*/; do
  env="$(basename "${env_dir}")"
  out="${WORK}/${env}.yaml"

  if ! err="$(helm template "maas-${env}" "${ROOT}/charts/maas-models" \
        -f "${env_dir}/values.yaml" --kube-version "${KUBE_VERSION}" 2>&1 > "${out}")"; then
    bad "render ${env}" "${err}"
    continue
  fi
  ok "render ${env}"

  if yq -e '.' "${out}" >/dev/null 2>&1; then
    ok "${env}: all documents are valid YAML"
  else
    bad "${env}: YAML parse" "$(yq '.' "${out}" 2>&1 | head -3)"
  fi

  # --- every MaaSModelRef points at a workload that this render also creates.
  # A dangling reference reconciles to phase=Pending forever.
  refs="$(yq -r 'select(.kind=="MaaSModelRef") | .spec.modelRef.kind + "/" + .metadata.namespace + "/" + .spec.modelRef.name' "${out}" | sort -u)"
  workloads="$(yq -r 'select(.kind=="LLMInferenceService" or .kind=="ExternalModel") | .kind + "/" + .metadata.namespace + "/" + .metadata.name' "${out}" | sort -u)"
  missing="$(comm -23 <(echo "${refs}") <(echo "${workloads}") | grep -v '^$' || true)"
  if [[ -z "${missing}" ]]; then
    ok "${env}: every MaaSModelRef has a matching backend"
  else
    bad "${env}: dangling MaaSModelRef backends" "${missing}"
  fi

  # --- every governance modelRef points at a MaaSModelRef this render creates.
  modelrefs="$(yq -r 'select(.kind=="MaaSModelRef") | .metadata.namespace + "/" + .metadata.name' "${out}" | sort -u)"
  govrefs="$(yq -r 'select(.kind=="MaaSAuthPolicy") | .spec.modelRefs[] | .namespace + "/" + .name' "${out}" | sort -u)"
  govrefs="${govrefs}"$'\n'"$(yq -r 'select(.kind=="MaaSSubscription") | .spec.modelRefs[] | .namespace + "/" + .name' "${out}" | sort -u)"
  govmissing="$(comm -23 <(echo "${govrefs}" | sort -u | grep -v '^$') <(echo "${modelrefs}") || true)"
  if [[ -z "${govmissing}" ]]; then
    ok "${env}: every governance reference resolves to a MaaSModelRef"
  else
    bad "${env}: governance references unknown models" "${govmissing}"
  fi

  # --- every LLMInferenceService goes through the MaaS gateway.
  # Without the gateway ref the model serves traffic but bypasses Authorino and
  # Limitador entirely: no authentication, no quota. Renders green, leaks badly.
  total_llm="$(yq -r 'select(.kind=="LLMInferenceService") | .metadata.name' "${out}" | grep -c . || true)"
  gated="$(yq -r 'select(.kind=="LLMInferenceService") | select(.spec.router.gateway.refs != null) | .metadata.name' "${out}" | grep -c . || true)"
  if [[ "${total_llm}" -eq "${gated}" ]]; then
    ok "${env}: all ${total_llm} LLMInferenceService(s) attached to the MaaS gateway"
  else
    bad "${env}: LLMInferenceService bypassing the gateway" "${gated}/${total_llm} attached"
  fi

  # --- every s3:// model must name a ServiceAccount, and that ServiceAccount
  # must exist in the same namespace. KServe resolves object-storage credentials
  # only through the pod ServiceAccount; a missing link fails the download at
  # runtime with no render-time symptom.
  s3_bad=""
  while IFS=$'\t' read -r name ns sa; do
    [[ -z "${name}" ]] && continue
    if [[ -z "${sa}" || "${sa}" == "null" ]]; then
      s3_bad="${s3_bad} ${ns}/${name}(no serviceAccountName)"
      continue
    fi
    # A ServiceAccount this chart does not render is a supported configuration
    # (inference.serviceAccountName pointing at one the platform team manages),
    # so this is reported, not failed — but it is worth seeing in a diff,
    # because the chart cannot verify it exists or carries a usable Secret.
    if ! yq -e "select(.kind==\"ServiceAccount\" and .metadata.name==\"${sa}\" and .metadata.namespace==\"${ns}\")" "${out}" >/dev/null 2>&1; then
      printf 'note  %s: %s uses ServiceAccount %s/%s, which this chart does not render — it must already exist and reference an S3 Secret\n' \
        "${env}" "${name}" "${ns}" "${sa}"
    fi
  done < <(yq -r 'select(.kind=="LLMInferenceService") | select(.spec.model.uri | test("^s3://")) | .metadata.name + "\t" + .metadata.namespace + "\t" + (.spec.template.serviceAccountName // "")' "${out}")

  s3_total="$(yq -r 'select(.kind=="LLMInferenceService") | select(.spec.model.uri | test("^s3://")) | .metadata.name' "${out}" | grep -c . || true)"
  if [[ -z "${s3_bad}" ]]; then
    ok "${env}: all ${s3_total} s3:// model(s) have a resolvable ServiceAccount"
  else
    bad "${env}: s3:// models without usable credentials" "${s3_bad}"
  fi

  # --- Vault chain: ExternalSecret -> Secret name -> ServiceAccount.secrets[].
  # Every link is name-based and resolved at runtime by a different controller,
  # so a rename in one place fails silently at pod start rather than at sync.
  es_bad=""
  while IFS=$'\t' read -r esname ns target; do
    [[ -z "${esname}" ]] && continue
    linked="$(yq -r "select(.kind==\"ServiceAccount\" and .metadata.namespace==\"${ns}\") | select([.secrets // [] | .[] | select(.name==\"${target}\")] | length > 0) | .metadata.name" "${out}" | head -1)"
    if [[ -z "${linked}" ]]; then
      es_bad="${es_bad} ${ns}/${esname}(Secret ${target} referenced by no ServiceAccount)"
    fi
    # mergePolicy Replace would discard the Vault data and leave an annotated,
    # empty Secret — the failure looks like a credentials error on a Secret that
    # renders correctly.
    mp="$(yq -r "select(.kind==\"ExternalSecret\" and .metadata.name==\"${esname}\" and .metadata.namespace==\"${ns}\") | .spec.target.template.mergePolicy // \"Replace\"" "${out}")"
    if [[ -n "$(yq -r "select(.kind==\"ExternalSecret\" and .metadata.name==\"${esname}\") | .spec.target.template.metadata.annotations // empty" "${out}")" && "${mp}" != "Merge" ]]; then
      es_bad="${es_bad} ${ns}/${esname}(template sets annotations but mergePolicy=${mp}, which drops the Vault data)"
    fi
  done < <(yq -r 'select(.kind=="ExternalSecret") | .metadata.name + "\t" + .metadata.namespace + "\t" + .spec.target.name' "${out}")

  es_total="$(yq -r 'select(.kind=="ExternalSecret") | .metadata.name' "${out}" | grep -c . || true)"
  if [[ -z "${es_bad}" ]]; then
    ok "${env}: all ${es_total} ExternalSecret(s) reach a ServiceAccount with data preserved"
  else
    bad "${env}: broken ExternalSecret chain" "${es_bad}"
  fi

  # --- every ExternalSecret names a store that is rendered here or declared external.
  while IFS=$'\t' read -r esname store kind; do
    [[ -z "${esname}" ]] && continue
    if ! yq -e "select(.kind==\"${kind}\" and .metadata.name==\"${store}\")" "${out}" >/dev/null 2>&1; then
      printf 'note  %s: %s references %s/%s, which this chart does not render — it must already exist\n' \
        "${env}" "${esname}" "${kind}" "${store}"
    fi
  done < <(yq -r 'select(.kind=="ExternalSecret") | .metadata.name + "\t" + .spec.secretStoreRef.name + "\t" + .spec.secretStoreRef.kind' "${out}")

  # --- an s3:// model with no ephemeral-storage request on the storage-initializer
  # gets evicted partway through a large download. Advisory, not fatal.
  while IFS= read -r name; do
    [[ -z "${name}" ]] && continue
    printf 'note  %s: %s has no storage-initializer ephemeral-storage request\n' "${env}" "${name}"
  done < <(yq -r 'select(.kind=="LLMInferenceService") | select(.spec.model.uri | test("^s3://")) | select([.spec.template.initContainers // [] | .[] | select(.name=="storage-initializer") | .resources.requests["ephemeral-storage"] // empty] | length == 0) | .metadata.name' "${out}")

  # --- MaaSModelRef and governance must share a sync wave, or Argo CD deadlocks.
  wave_ref="$(yq -r 'select(.kind=="MaaSModelRef") | .metadata.annotations."argocd.argoproj.io/sync-wave"' "${out}" | sort -u | head -1)"
  wave_gov="$(yq -r 'select(.kind=="MaaSAuthPolicy" or .kind=="MaaSSubscription") | .metadata.annotations."argocd.argoproj.io/sync-wave"' "${out}" | sort -u | head -1)"
  if [[ -z "${wave_ref}" || "${wave_ref}" == "${wave_gov}" ]]; then
    ok "${env}: modelRef and governance share sync wave (${wave_ref:-n/a})"
  else
    bad "${env}: sync-wave deadlock" "modelRef=${wave_ref} governance=${wave_gov} — these must match"
  fi

  # --- no plaintext credentials rendered into a Secret in a non-sandbox env.
  if [[ "${env}" != "sandbox" ]]; then
    if yq -e 'select(.kind=="Secret") | .stringData' "${out}" >/dev/null 2>&1; then
      bad "${env}: inline Secret rendered" "set validation.forbidInlineSecrets=true and use an external secret store"
    else
      ok "${env}: no inline Secrets"
    fi
  fi
done

# -----------------------------------------------------------------------------
echo
echo "==> maas-gitops policy invariants"
# -----------------------------------------------------------------------------
gitops="${WORK}/gitops.yaml"
if ! err="$(helm template maas-gitops "${ROOT}/charts/maas-gitops" \
      --kube-version "${KUBE_VERSION}" 2>&1 > "${gitops}")"; then
  bad "render maas-gitops" "${err}"
else
  ok "render maas-gitops"

  # Operating policy: ops drive the syncs. Catch an accidental auto-sync/prune
  # or a cascade-delete finalizer sneaking into the defaults.
  autos="$(yq -r 'select(.kind=="Application") | select(.spec.syncPolicy.automated != null) | .metadata.name' "${gitops}" | grep -v '^$' || true)"
  if [[ -z "${autos}" ]]; then
    ok "no Application has auto-sync enabled"
  else
    printf 'note  auto-sync enabled on: %s (intentional? confirm with ops)\n' "$(echo "${autos}" | tr '\n' ' ')"
  fi

  prunes="$(yq -r 'select(.kind=="Application") | select(.spec.syncPolicy.automated.prune == true) | .metadata.name' "${gitops}" | grep -v '^$' || true)"
  if [[ -z "${prunes}" ]]; then
    ok "no Application auto-prunes"
  else
    bad "auto-prune enabled" "${prunes} — ops policy is no auto-destroy"
  fi

  fins="$(yq -r 'select(.kind=="Application") | select(.metadata.finalizers != null) | .metadata.name' "${gitops}" | grep -v '^$' || true)"
  if [[ -z "${fins}" ]]; then
    ok "no Application carries a cascade-delete finalizer"
  else
    bad "cascade-delete finalizer present" "${fins} — deleting the Application would delete every model"
  fi

  # Every health check kind must actually be emitted.
  checks="$(yq -r 'select(.kind=="ConfigMap") | .data["patch.yaml"]' "${gitops}" | yq -r '.spec.resourceHealthChecks[].kind' | sort -u)"
  for kind in MaaSModelRef MaaSAuthPolicy MaaSSubscription ExternalModel LLMInferenceService; do
    if grep -qx "${kind}" <<<"${checks}"; then
      ok "health check present: ${kind}"
    else
      bad "health check missing: ${kind}" "Argo CD would report this kind Healthy unconditionally"
    fi
  done
fi

echo
echo "==> ${pass} passed, ${fail} failed"
[[ "${fail}" -eq 0 ]]
