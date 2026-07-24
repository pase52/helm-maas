# AGENTS.md — orientation for AI agents

Machine-facing companion to [README.md](README.md). Read this before changing
anything in this repository.

Applies to the whole repo. `CLAUDE.md` symlinks here.

---

## 1. What this repository is

Two Helm charts that manage the **model catalogue** of Models-as-a-Service (MaaS)
on Red Hat OpenShift AI, driven by Argo CD.

| Path | Role |
|---|---|
| `charts/maas-models` | Renders the per-model resources. One Argo CD Application per environment points here. |
| `charts/maas-gitops` | Renders the Argo CD `AppProject`, `Application`s, and the Lua health checks. Applied once by an admin. |
| `environments/<env>/values.yaml` | The per-environment catalogue. **Most user requests are a change to one of these files, not to a template.** |
| `tests/render.sh` | Renders every environment and asserts structural invariants. |
| `tests/lua/run.sh` | Executes the Argo CD health checks against status fixtures using gopher-lua. |

**Out of scope:** installing the MaaS platform itself (`maas-api`,
`maas-controller`, the Gateway, Kuadrant/RHCL, the CRDs). If a request needs
those, say so rather than adding templates for them here.

---

## 2. Before you finish: run the tests

```bash
./tests/render.sh      # requires helm, yq
./tests/lua/run.sh     # requires helm, yq, go
```

Both must pass. `helm template` alone is not sufficient — it does not check that
governance references resolve, that models are attached to the gateway, or that
the sync waves cannot deadlock.

If `helm` is unavailable in your environment, it can be built from source:
`go install helm.sh/helm/v3/cmd/helm@v3.16.4` (`get.helm.sh` may be blocked by
egress policy; `proxy.golang.org` generally is not).

Note `helm template` needs `--kube-version 1.32.0` because `Chart.yaml` sets
`kubeVersion: ">=1.32.0-0"` and the local default is older.

---

## 3. The domain model

Each entry in `models[]` produces up to four objects. All four are required for
the model to serve traffic:

```
LLMInferenceService | ExternalModel      the workload
MaaSModelRef                             publishes it to the MaaS catalogue
MaaSAuthPolicy                           who may call it      (from accessPolicies[])
MaaSSubscription                         token quota          (from subscriptions[])
```

`accessPolicies` and `subscriptions` do not name models directly. They select
them:

```yaml
modelSelector:
  all: false          # every enabled model
  tiers: [premium]    # models whose `tier` is in this list
  names: [granite]    # models by explicit name
```

A model matches if **any** criterion matches. An empty selector matches nothing.

### Verified API facts

These were read from the upstream CRD Go types, not inferred. Do not "correct"
them from memory:

| Fact | Value |
|---|---|
| API group | `maas.opendatahub.io/v1alpha1` |
| `MaaSModelRef.status.phase` | `Pending` \| `Ready` \| `Unhealthy` \| `Failed` \| `Invalid` |
| `MaaSAuthPolicy` / `MaaSSubscription` `.status.phase` | `Pending` \| `Active` \| `Degraded` \| `Failed` \| `Invalid` |
| `ExternalModel.status.phase` | `Pending` \| `Ready` \| `Failed` |
| `MaaSModelRef` condition types | `Ready`, `RuntimeReady`, `GovernanceAttached` |
| `MaaSModelRef.spec.modelRef.kind` | `LLMInferenceService` or `ExternalModel` only |
| Rate-limit window pattern | `^[1-9][0-9]{0,3}(s\|m\|h)$` — **days are not accepted**, use `24h` |
| `ExternalModel.spec.provider` | `openai` \| `anthropic` \| `azure-openai` \| `vertex` \| `bedrock-openai` |
| `ExternalModel.spec.endpoint` | bare FQDN, no scheme, no path |
| LLMInferenceService gateway ref | `spec.router.gateway.refs[]` (**not** `spec.gateway.refs`) |
| `MaaSModelRef` namespace | same namespace as its backend — hard CRD requirement |
| `MaaSAuthPolicy` / `MaaSSubscription` namespace | the tenant namespace (`models-as-a-service` by default) |
| `LLMInferenceService.spec.template` | a plain `corev1.PodSpec` — supports `serviceAccountName`, `initContainers`, etc. |
| `spec.storageInitializer.enabled` | `*bool`; nil and true both mean "create it" |
| storage-initializer mount path | `/mnt/models` (`constants.DefaultModelLocalMountPath`) |
| storage-initializer volume | emptyDir `kserve-provision-location`, rw in the init container, ro in `main` |
| S3 credential resolution | IRSA SA annotation → cluster storage-secret annotation (unset by default) → **`serviceAccount.secrets[]`** |
| S3 Secret data keys | `awsAccessKeyID`, `awsSecretAccessKey` — KServe defaults, do not rename |
| S3 settings location | annotations on the **Secret** (`serving.kserve.io/s3-*`), not on the SA or the LLMIS |
| ESO API version | `external-secrets.io/v1` is served+storage; `v1beta1` is no longer served in current ESO |
| `ExternalSecret.spec.target.template.mergePolicy` | defaults to **`Replace`**, which discards provider data — must be `Merge` for a metadata-only template |
| ESO Vault auth | `kubernetes` (preferred), `appRole`, `tokenSecretRef` — under `spec.provider.vault.auth` |
| ClusterSecretStore `serviceAccountRef` | requires `namespace`; cluster-scoped stores cannot resolve a bare name |
| Substituting the model volume | declare a volume named `kserve-provision-location`; `AddModelMount` skips its emptyDir when one already exists |
| S3 download idempotency | **none** — `_download_s3` writes unconditionally; a PVC does not avoid the re-download |

### Model artifact loading

`modelUri` scheme picks the mechanism. `s3://` and `hf://` get a
`storage-initializer` **initContainer** (not a sidecar — it runs to completion
before vLLM starts). `oci://` is a ModelCar with no download. `pvc://` mounts a
volume. The chart templates none of the initContainer: KServe injects it. The
chart supplies the ServiceAccount and annotated Secret that make credentials
resolvable, plus optional `storageInitializer.resources` for ephemeral-storage
headroom.

---

## 4. Invariants — do not break these

Each is enforced by a test. If a change makes a test fail, the change is wrong,
not the test.

1. **`MaaSModelRef` and governance share a sync wave.** Their readiness is
   circular: the ModelRef needs the policy+subscription pair to report
   `GovernanceAttached`, and those need the ModelRef to exist. Separate waves
   deadlock the Argo CD sync permanently.
   *Enforced by:* `tests/render.sh` sync-wave check.

2. **Every `LLMInferenceService` carries `spec.router.gateway.refs`.** Without it
   the model serves traffic bypassing Authorino and Limitador — no auth, no
   quota. It renders green and leaks.
   *Enforced by:* `tests/render.sh` gateway check.

3. **Selectors fail closed.** An empty `modelSelector` matches nothing. Never
   "helpfully" make it default to all.
   *Enforced by:* `_validate.tpl` empty-selector guard.

4. **Argo CD defaults stay off.** No `automated`, no `prune`, no `selfHeal`, no
   `resources-finalizer.argocd.argoproj.io`. This is the user's stated operating
   policy, not an oversight. Values must remain configurable; defaults must
   remain off.
   *Enforced by:* `tests/render.sh` policy checks.

5. **Health checks distinguish transient from permanent.** `Progressing` means
   "wait", `Degraded` means "a human is needed". A `Pending` caused by missing
   governance is Degraded, because it never self-resolves.
   *Enforced by:* `tests/lua/cases.txt`.

6. **`modelUri` is weights; `image` is the runtime.** A ModelCar OCI image in
   `inference.image` fails at startup with `vllm: command not found`. Keep the
   comments that say so.

7. **An `s3://` model needs a ServiceAccount.** KServe resolves object-storage
   credentials only through the Secrets attached to the pod's ServiceAccount.
   Rendering an `s3://` model without `serviceAccountName` produces a pod that
   fails in the initContainer with `Unable to locate credentials`.
   *Enforced by:* `_validate.tpl` S3 guard and `tests/render.sh` S3 check.

8. **S3 settings belong on the Secret's annotations.** Not the ServiceAccount,
   not the `LLMInferenceService`. Putting them anywhere else means the
   initContainer gets keys with no endpoint and silently tries AWS.
   *Enforced by:* `_validate.tpl` `annotateExistingSecret` guard.

9. **Generated `ExternalSecret`s set `mergePolicy: Merge`.** ESO's template
   defaults to `Replace`, which keeps only templated data and throws away
   everything read from Vault. Since the template exists solely to attach the S3
   annotations, `Replace` yields an annotated Secret with no keys — and the
   symptom appears much later, as a credentials error on a Secret that renders
   correctly.
   *Enforced by:* `tests/render.sh` ExternalSecret chain check.

10. **Placeholder defaults are worse than empty ones.** `storage.secretStore`
    ships with `vault.server: ""` and `auth.kubernetes.role: ""`, and
    `persistence.size` is `""`, on purpose. A plausible default such as
    `https://vault.example.com` or `100Gi` satisfies validation and then fails at
    runtime. Leave required fields empty and let `_validate.tpl` demand them.
    This has bitten twice; both times the guard existed and was simply
    unreachable because the default filled the field in.

11. **The model volume must be named `kserve-provision-location`.** Any other
    name and KServe appends its own emptyDir; the PVC binds, stays empty, and the
    weights silently go to node disk. Use the
    `maas-models.provisionVolumeName` helper, never a literal.
    *Enforced by:* `tests/render.sh` volume-name check.

12. **Do not claim a PVC avoids re-downloading.** It does not — the
    storage-initializer rewrites the directory on every pod start. Persistence
    changes where the bytes land, nothing more. Keep the values.yaml and docs
    wording that says so; it is the question every reviewer asks.

---

## 5. Common tasks

### Add or change a model

Edit `environments/<env>/values.yaml`, not the templates. Make sure the model's
`tier` is covered by an `accessPolicy` and a `subscription`, or the render fails
by design.

### Add a field to the rendered CRDs

1. Add it to `values.yaml` with a `# --` comment explaining *why* it exists.
2. Add it to `values.schema.json` — the schema is the first line of validation.
3. Render it in the relevant `templates/*.yaml`.
4. If it can be set wrongly in a way that produces a green-but-broken model, add
   a guard to `_validate.tpl` with an actionable message naming the model.
5. Run both test suites.

### Change a health check

1. Edit `charts/maas-gitops/templates/_healthchecks.tpl`.
2. Add a case to `tests/lua/cases.txt` covering the state that motivated it.
3. Run `./tests/lua/run.sh`.

A Lua error does **not** fail a Helm render or an Argo CD sync — Argo CD falls
back to reporting Healthy. The test suite is the only thing that catches it.

---

## 6. Helm traps present in this codebase

- **`default` treats `false` as empty.** `$x | default true` returns `true` when
  `$x` is `false`. Use `hasKey $dict "x"` instead. This bug already occurred once
  on `external.tls` — see the comment in `11-externalmodel.yaml`.
- **`pluck` is variadic over dicts**, not a list. `pluck "name" $list` fails with
  a type error. Use the `maas-models.modelNames` helper.
- **`include` returns a string.** Lists are passed between templates as JSON:
  `include "..." $ | fromJsonArray`.
- **Empty list keys serialise to `null`.** An empty `groups:` is rejected by the
  CRD schema, so `maas-models.subjectBlock` builds a dict and omits empty keys.
- **`toYaml` on a dict has no leading newline; a bare `{{- if }}` block does.**
  Build dicts and `toYaml` them rather than emitting YAML line by line.

---

## 7. Style

- Comment **why**, not what. `# -- ` prefixes in `values.yaml` are helm-docs
  format and are user-facing.
- Error messages name the offending model and the fix, not just the rule.
- Every rendered object carries the standard `app.kubernetes.io/*` labels plus
  `maas.pase52.io/{environment,model,tier,backend}` — the operational queries in
  the docs depend on those.
- Chart-specific labels use the `maas.pase52.io/` prefix; never invent
  `maas.opendatahub.io/` labels, which belong to the upstream API.
- Target OpenShift only. Use `Route`/Gateway API, never `Ingress`. Assume the
  `restricted-v2` SCC: never set `runAsUser`, always drop all capabilities.

---

## 8. Reference

- Upstream MaaS: <https://github.com/opendatahub-io/models-as-a-service>
- CRD sources: `maas-controller/api/maas/v1alpha1/*_types.go` in that repo — the
  authoritative reference when the docs and the code disagree. They have
  disagreed before: the published docs list `MaaSModelRef` phases as
  Pending/Ready/Failed, while the Go type also defines `Unhealthy` and `Invalid`.
- Red Hat docs: <https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index>
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — design decisions and rationale
- [docs/HEALTH.md](docs/HEALTH.md) — the operational runbook
