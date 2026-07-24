# Architecture

How MaaS works, what these charts render, and why the design is what it is.

- [Platform prerequisites](#platform-prerequisites)
- [The request path](#the-request-path)
- [The resource graph](#the-resource-graph)
- [Namespace layout](#namespace-layout)
- [Sync waves and the circular dependency](#sync-waves-and-the-circular-dependency)
- [Health model](#health-model)
- [Design decisions](#design-decisions)
- [Multi-tenancy](#multi-tenancy)
- [Disconnected clusters](#disconnected-clusters)

---

## Platform prerequisites

These charts assume a working MaaS installation. That installation is a separate,
one-off, cluster-admin task and is **out of scope** here. It provides:

| Component | Provided by | What it does |
|---|---|---|
| `maas-api` | MaaS operator | Model discovery (`/v1/models`), API key issuance, subscription lookup |
| `maas-controller` | MaaS operator | Reconciles `MaaSModelRef`, `MaaSAuthPolicy`, `MaaSSubscription` into Kuadrant policies |
| `maas-default-gateway` | Cluster admin | Gateway API `Gateway` in `openshift-ingress` — the single ingress for model traffic |
| Authorino | Kuadrant / RHCL | Authenticates callers and strips the `Authorization` header before the backend sees it |
| Limitador | Kuadrant / RHCL | Enforces token rate limits |
| KServe | OpenShift AI | Runs `LLMInferenceService` workloads |
| CRDs | MaaS operator | `maas.opendatahub.io/v1alpha1`, `serving.kserve.io/v1alpha1` |

Kuadrant **1.4.2 or later** is a hard floor. Earlier versions forward the
caller's `Authorization` header to the model backend, so a compromised or merely
curious model server can harvest OpenShift tokens and MaaS API keys.

---

## The request path

```
       client
         │  Authorization: Bearer <OpenShift token | MaaS API key>
         ▼
┌────────────────────────────────────────────────────────────┐
│ maas-default-gateway   (Gateway API, openshift-ingress)     │
│  TLS termination                                            │
└───────────────────────────┬────────────────────────────────┘
                            │
                            ▼
              ┌─────────────────────────────┐
              │ Authorino  (AuthPolicy)     │
              │  · validates the credential │──── callback ──▶ maas-api
              │  · selects the subscription │
              │  · STRIPS Authorization     │
              └─────────────┬───────────────┘
                            │  denied ──▶ 401 / 403
                            ▼
              ┌─────────────────────────────┐
              │ Limitador (TokenRateLimit)  │
              │  · counts tokens per        │
              │    subject × model × window │
              └─────────────┬───────────────┘
                            │  over quota ──▶ 429
                            ▼
              ┌─────────────────────────────┐
              │ backend                     │
              │  vLLM pod (LLMInferenceSvc) │
              │      or                     │
              │  ServiceEntry ──▶ provider  │  (ExternalModel)
              └─────────────────────────────┘
```

The `AuthPolicy` and `TokenRateLimitPolicy` objects in that diagram are **not**
written by these charts. `maas-controller` generates them from the
`MaaSAuthPolicy` and `MaaSSubscription` objects the charts do write. That
indirection is the point: the charts express intent ("the premium group gets 2M
tokens an hour"), the controller expresses mechanism.

---

## The resource graph

For one model named `granite-3-1-8b` in tier `standard`:

```
environments/prod/values.yaml
   │
   │  models[]                         accessPolicies[]        subscriptions[]
   │  name: granite-3-1-8b             modelSelector:          modelSelector:
   │  tier: standard                     tiers: [standard]       tiers: [standard]
   │                                       │                       │
   ▼                                       │                       │
┌──────────────────────────┐               │                       │
│ LLMInferenceService      │  wave 0       │                       │
│ ns: llm-prod             │               │                       │
│ router.gateway.refs ─────┼──▶ maas-default-gateway               │
└──────────┬───────────────┘               │                       │
           │ referenced by name            │                       │
           ▼                               ▼                       ▼
┌──────────────────────────┐    ┌────────────────────┐  ┌────────────────────┐
│ MaaSModelRef             │◀───│ MaaSAuthPolicy     │  │ MaaSSubscription   │
│ ns: llm-prod   wave 10   │    │ ns: models-as-a-   │  │ ns: models-as-a-   │
│                          │    │     service        │  │     service        │
│ status.phase             │    │ wave 10            │  │ wave 10            │
│ status.endpoint          │    │ subjects.groups    │  │ owner.groups       │
│ RuntimeReady ────────────┼─▶  │  [maas-users]      │  │ tokenRateLimits    │
│ GovernanceAttached ◀─────┼────┴────────────────────┴──┘                    │
└──────────────────────────┘                                                 │
           │                                                                 │
           │ maas-controller expands                                         │
           ▼                                                                 ▼
   Kuadrant AuthPolicy                                    Kuadrant TokenRateLimitPolicy
   (per model, on the HTTPRoute)                          (enforced by Limitador)
```

Note the two arrows into `MaaSModelRef`: `GovernanceAttached` is set by the
controller only once **both** a `MaaSAuthPolicy` and a `MaaSSubscription`
reference the model. This is what makes the dependency circular — see below.

Cross-namespace references are explicit `{name, namespace}` pairs because the
governance objects live in the tenant namespace while the models live in the
workload namespace.

---

## Model artifact loading

`modelUri` selects the mechanism. KServe decides from the scheme; the chart only
supplies what that mechanism needs.

| Scheme | Mechanism | Chart must supply |
|---|---|---|
| `s3://` | `storage-initializer` initContainer downloads to an emptyDir | ServiceAccount + annotated Secret |
| `hf://` | Same initContainer, Hugging Face token | ServiceAccount + token Secret |
| `oci://` | ModelCar image mounted directly; no download | `storageInitializer.enabled: false`, pull secret |
| `pvc://` | Pre-populated PersistentVolumeClaim mounted | The PVC |

For `s3://`:

```
        initContainer  storage-initializer
                       args: [s3://bucket/prefix/, /mnt/models]
                       env:  AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY,
                             S3_ENDPOINT, AWS_DEFAULT_REGION, S3_VERIFY_SSL …
                       mount: kserve-provision-location → /mnt/models  (rw)
                          │
                          │  runs to completion, then exits
                          ▼
        container      main (vLLM)
                       mount: kserve-provision-location → /mnt/models  (ro)
```

It is an **initContainer**, not a sidecar: it finishes before vLLM starts, so
download failures surface as `Init:Error` rather than a crashing model container,
and the download time is charged to pod startup before the readiness probe first
fires.

### How credentials resolve

KServe's credential builder looks in exactly one place, in this order:

1. `eks.amazonaws.com/role-arn` annotation on the ServiceAccount → AWS IRSA
2. A cluster-wide storage-secret-name annotation, if the platform configured one
   in `inferenceservice-config` (unset by default — do not depend on it)
3. **`serviceAccount.secrets[]`** — the dependable path, and what this chart uses

The S3 connection settings (endpoint, region, TLS behaviour) come from
**annotations on the Secret**, not from the ServiceAccount and not from the
`LLMInferenceService`. A correctly annotated Secret that no ServiceAccount
references is invisible; a ServiceAccount referencing an unannotated Secret
yields credentials with no endpoint. Both halves are required, which is why
`storage.s3[]` renders them together and `_validate.tpl` refuses a profile that
has settings but no way to apply them.

Secret keys are KServe's defaults and must not be renamed: `awsAccessKeyID`,
`awsSecretAccessKey`.

### Operational consequences

- Weights occupy **node ephemeral storage**, not a PVC, and are re-fetched on
  every pod start. Three replicas of a 140 GB model means three copies and three
  downloads. `storageInitializer.resources` must request enough
  `ephemeral-storage` or the kubelet evicts the pod mid-download.
- For large models or high replica counts, `oci://` (ModelCar, cached by the node
  image store) or `pvc://` (fetched once, mounted many times) scale better.
- `storageInitializer.enabled: false` skips the step entirely — required for
  ModelCars, which already carry the weights, and for weightless simulators.

---

## Namespace layout

| Namespace | Contents | Set by |
|---|---|---|
| `openshift-ingress` | `maas-default-gateway` | Platform install |
| `models-as-a-service` | `maas-api`, `MaaSAuthPolicy`, `MaaSSubscription`, inventory ConfigMap, PrometheusRule | `global.tenantNamespace` |
| `llm-sandbox` / `llm-prod` | `LLMInferenceService`, `ExternalModel`, `MaaSModelRef`, credential Secrets | `global.modelNamespace` |
| `openshift-gitops` | `AppProject`, `Application`s, health-check ConfigMap | `argocd.namespace` |

Two constraints come from the CRDs, not from taste:

- A `MaaSModelRef` **must** live in the same namespace as its backend.
- `MaaSAuthPolicy` and `MaaSSubscription` **must** live in the tenant namespace
  (`models-as-a-service` for the default tenant, `ai-tenant-<id>` otherwise).

The chart enforces both; overriding `namespace` on a model moves the workload and
its `MaaSModelRef` together.

---

## Sync waves and the circular dependency

```
wave -10  Namespace                      (only if namespaces.create=true)
wave  -5  Secret                         (external model credentials)
wave   0  LLMInferenceService / ExternalModel
wave  10  MaaSModelRef + MaaSAuthPolicy + MaaSSubscription
wave  20  PrometheusRule, inventory ConfigMap, KSM metrics config
```

Argo CD applies a wave, waits for every resource in it to report **Healthy**,
then moves on.

`MaaSModelRef`, `MaaSAuthPolicy` and `MaaSSubscription` share wave 10 because
their readiness is mutually dependent:

- `MaaSModelRef` reaches `Ready` only when `GovernanceAttached` is true, which
  needs an active `MaaSAuthPolicy` **and** `MaaSSubscription` covering it.
- `MaaSAuthPolicy` and `MaaSSubscription` reach `Active` only when the
  `MaaSModelRef` they reference exists and resolves.

Split across waves in either order, the earlier wave never goes Healthy and Argo
CD never applies the later one. The sync hangs indefinitely. Applied together,
all three converge in a single reconcile loop.

`tests/render.sh` asserts these waves match, so the deadlock cannot be
reintroduced by a values edit.

Wave 0 is separate and genuinely sequential: the model must be loaded and serving
before governance is worth attaching. With the `LLMInferenceService` health check
installed, this means a first sync of a large GPU model legitimately sits in
*Progressing* for 10–20 minutes.

---

## Health model

Argo CD assumes any CRD it does not recognise is Healthy. Left alone, it reports
a green tick for a `MaaSModelRef` that will never serve a request. The Lua health
checks in `charts/maas-gitops/templates/_healthchecks.tpl` fix that.

The governing rule: **Progressing means "wait", Degraded means "a human is
needed".** A state that resolves on its own is Progressing; a state that will
still be broken tomorrow is Degraded, even when the CRD calls it `Pending`.

| Object | Condition | Argo CD |
|---|---|---|
| `MaaSModelRef` | `phase=Ready` | Healthy — message carries the endpoint |
| | `phase=Pending`, `RuntimeReady=False/BackendNotReady` | Progressing — model loading |
| | `phase=Pending`, `GovernanceAttached=False/NoPairingFound` | **Degraded** — no policy covers it; requests are denied |
| | `phase=Unhealthy` | Degraded — live outage, governance fine, backend failing |
| | `phase=Failed` / `Invalid` | Degraded |
| `MaaSAuthPolicy` | `phase=Active` | Healthy |
| | `phase=Degraded` | Degraded — reports *n of m* underlying AuthPolicies unhealthy |
| `MaaSSubscription` | `phase=Active` | Healthy |
| | `phase=Degraded` | Degraded — names how many rate limits are unenforced |
| `ExternalModel` | `phase=Ready` | Healthy |
| | `phase=Failed` | Degraded — points at the credential Secret and egress |
| `LLMInferenceService` | `Ready=True` | Healthy |
| | `Ready=False`, transient reason | Progressing |
| | `Ready=False`, `ImagePullBackOff` / `Unschedulable` / `CrashLoopBackOff` | **Degraded** — will not self-resolve |

Distinguishing a transient `Ready=False` from a permanent one is the difference
between a sync that eventually succeeds and one that spins for hours on a
mistyped image tag.

`tests/lua/run.sh` runs every one of these paths against fixtures.

---

## Design decisions

**Two charts, not one.** The Argo CD `Application` that deploys the models cannot
also be the thing that creates itself. `maas-gitops` is applied once by an admin;
`maas-models` is what the Applications point at.

**Selectors, not repeated model names.** `accessPolicies` and `subscriptions`
select models by `tier`, `name`, or `all`. Adding a model to an existing tier
needs no edit to either — which removes the most common way to deploy a model
that nobody can call.

**Selectors fail closed.** An empty selector matches nothing. A typo in a tier
name therefore removes access rather than silently granting it everywhere.

**Validation at render time.** Six classes of misconfiguration produce a model
that syncs green and never serves. `_validate.tpl` fails the render with a
message naming the model and the fix. `values.schema.json` catches type and
pattern errors before templating even starts.

**`enabled: false` over deletion.** Keeps the historical record in git and stops
the policies referencing the model. Combined with `prune: false`, withdrawal is a
deliberate two-step: disable in git, then delete the objects.

**No auto-sync, no finalizers.** Ops drive syncs; deleting an Application must
not delete the models it manages. Both are one-line reversals in
`charts/maas-gitops/values.yaml` if the policy changes.

**Escape hatch on the workload spec.** `inference.extraSpec` is merged over the
generated `LLMInferenceService` spec, so a prefill/decode split or a LoRA
configuration does not require a chart change.

---

## Multi-tenancy

The default tenant (`models-as-a-service`) covers most clusters. For hard
isolation between business units, MaaS provides `AITenant`, which derives a
namespace `ai-tenant-<name>` with its own gateway context and `maas-api`
instance.

To place a model in a non-default tenant, set `tenantRef` on the model:

```yaml
models:
  - name: granite-3-1-8b
    tenantRef: business-unit-a
```

and point `global.tenantNamespace` at that tenant's namespace so the governance
objects land in the right place. Creating the `AITenant` itself is a platform
task, outside these charts. Note `AITenant` names are limited to 41 characters so
derived resource names stay within Kubernetes' 63-character limit.

---

## Disconnected clusters

Set `global.registryMirror` to rewrite Red Hat registry references — both
container images and `oci://` model URIs — onto an internal mirror:

```yaml
global:
  registryMirror: mirror.corp.example.com/rh
```

`registry.redhat.io/rhaiis/vllm-cuda-rhel9:3.3.0` becomes
`mirror.corp.example.com/rh/rhaiis/vllm-cuda-rhel9:3.3.0`. Rewriting covers
`registry.redhat.io`, `registry.access.redhat.com` and `quay.io`; anything else
is passed through untouched, so a mirror-hosted image can be named directly.

This rewrite is cosmetic convenience on top of cluster-level
`ImageDigestMirrorSet` / `ImageTagMirrorSet` configuration — it does not replace it.
