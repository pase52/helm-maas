# helm-maas — Models-as-a-Service model management for Red Hat OpenShift AI

Helm charts that let a platform team manage the **model catalogue** of
[Models-as-a-Service](https://github.com/opendatahub-io/models-as-a-service) (MaaS)
on Red Hat OpenShift AI declaratively, one `values.yaml` per environment, driven
by Argo CD.

Adding a model, changing who may call it, or raising a token quota is a pull
request against a values file — reviewed, versioned and revertible. Argo CD shows
whether each model is actually deployed and actually healthy.

---

## Table of contents

- [What this is and is not](#what-this-is-and-is-not)
- [Repository layout](#repository-layout)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Day-2 operations](#day-2-operations)
- [Checking model health](#checking-model-health)
- [The values file](#the-values-file)
- [Argo CD behaviour](#argo-cd-behaviour)
- [Testing changes](#testing-changes)
- [Further reading](#further-reading)

---

## What this is and is not

**This repository manages models.** For each model it renders the four objects
MaaS needs, in the right order, with the right cross-references:

| Object | Purpose |
|---|---|
| `LLMInferenceService` (KServe) or `ExternalModel` | The workload — vLLM on-cluster, or an external provider such as OpenAI |
| `MaaSModelRef` | Publishes the model into the MaaS catalogue and `GET /v1/models` |
| `MaaSAuthPolicy` | Who may call it — expands into Kuadrant AuthPolicies |
| `MaaSSubscription` | Token quotas — expands into Kuadrant TokenRateLimitPolicies |

**This repository does not install the MaaS platform.** The Gateway, Kuadrant /
Red Hat Connectivity Link, `maas-api`, `maas-controller` and the CRDs are a
day-1 cluster-admin task, done once per cluster. See
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#platform-prerequisites) for what must
exist before these charts do anything useful.

Two charts, deliberately separate:

- **`charts/maas-models`** — the models. Deployed by Argo CD, once per environment.
- **`charts/maas-gitops`** — the Argo CD wiring: `AppProject`, `Application`s,
  and the custom health checks. Deployed once by an admin.

---

## Repository layout

```
charts/
  maas-models/            The model catalogue chart
    values.yaml           Documented defaults — read this first
    values.schema.json    Hard validation; a typo fails the sync, not the model
    templates/
      _validate.tpl       Fail-fast guardrails (see "Guardrails" below)
      10-llminferenceservice.yaml
      11-externalmodel.yaml
      20-maasmodelref.yaml
      30-maasauthpolicy.yaml
      31-maassubscription.yaml
      4x-*.yaml           Inventory ConfigMap, PrometheusRule, KSM metrics config
  maas-gitops/            Argo CD AppProject, Applications, health checks
    templates/
      _healthchecks.tpl   The Lua that makes model health visible in Argo CD

environments/
  sandbox/values.yaml     Broad access, small quotas, CPU models
  prod/values.yaml        Named groups only, tiered quotas, GPU models, alerting

docs/
  ARCHITECTURE.md         How the pieces fit; design decisions and why
  HEALTH.md               Health model and runbook — alerts link here

tests/
  lua/run.sh              Executes the Argo CD health checks against fixtures
  render.sh               Renders every environment and asserts invariants

AGENTS.md                 Orientation for AI agents working in this repo
```

---

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| OpenShift | 4.19.9+ | Gateway API GA |
| Red Hat OpenShift AI | 3.4+ | MaaS component enabled |
| Kuadrant / Red Hat Connectivity Link | RHCL 1.3+ / Kuadrant 1.4.2+ | 1.4.2 is the floor — earlier versions do not strip the `Authorization` header, leaking caller credentials to model backends |
| OpenShift GitOps | 1.14+ | Argo CD |
| MaaS platform | installed | `maas-api`, `maas-controller`, `maas-default-gateway` |

Confirm the platform is ready before installing:

```bash
oc get crd maasmodelrefs.maas.opendatahub.io \
           maasauthpolicies.maas.opendatahub.io \
           maassubscriptions.maas.opendatahub.io \
           llminferenceservices.serving.kserve.io

oc get gateway maas-default-gateway -n openshift-ingress
oc get pods -n models-as-a-service
```

If the CRDs are missing, install MaaS first — these charts render objects the
API server will reject.

---

## Installation

### 1. Install the Argo CD health checks

Do this before deploying any model. Without it Argo CD treats the MaaS CRDs as
unknown kinds and reports every model **Healthy** the moment it is created —
including models that will never serve a request.

```bash
helm template maas-gitops charts/maas-gitops | oc apply -f -

# Apply the health checks to the ArgoCD instance
oc get cm maas-gitops-argocd-health-checks -n openshift-gitops \
  -o jsonpath='{.data.patch\.yaml}' > /tmp/maas-health.yaml

oc patch argocd openshift-gitops -n openshift-gitops \
  --type merge --patch-file /tmp/maas-health.yaml
```

Verify:

```bash
oc get argocd openshift-gitops -n openshift-gitops \
  -o jsonpath='{range .spec.resourceHealthChecks[*]}{.group}/{.kind}{"\n"}{end}'
```

If your GitOps instance is itself managed in git, set
`healthChecks.argocdResource.enabled=true` instead and let Argo CD apply the
partial `ArgoCD` resource. Do not use both paths on one instance.

### 2. Point the Applications at your fork

Edit `charts/maas-gitops/values.yaml`:

```yaml
appProject:
  sourceRepos:
    - https://github.com/<your-org>/helm-maas.git
  destinations:
    - server: https://kubernetes.default.svc
      namespace: models-as-a-service
    - server: https://kubernetes.default.svc
      namespace: llm-prod

applicationDefaults:
  repoURL: https://github.com/<your-org>/helm-maas.git
  targetRevision: main
```

Then apply. The `AppProject` and both `Application`s appear in Argo CD
**OutOfSync** — that is intended. Nothing is deployed until someone syncs.

### 3. Sync

In the Argo CD UI, review the diff on `maas-models-sandbox` and press **Sync**.

First sync of a large model takes 10–20 minutes: the health check holds the
Application in *Progressing* until the model has genuinely loaded and is serving.
That wait is the signal working, not a stuck sync.

---

## Day-2 operations

Everything below is a pull request against a file in `environments/`.

### Add a model

Append to `models:` in the relevant environment file, then make sure an access
policy and a subscription cover it — a model with neither is deployed but
unreachable, and the chart refuses to render it:

```yaml
models:
  - name: mistral-7b
    enabled: true
    backend: LLMInferenceService
    tier: standard                      # matched by the selectors below
    catalog:
      displayName: "Mistral 7B Instruct"
      description: "General purpose chat"
      genaiUseCase: chat
      contextWindow: 8192
      capabilities: ["text-generation", "chat"]
    inference:
      modelUri: oci://registry.redhat.io/rhelai1/modelcar-mistral-7b:1.0
      modelName: mistralai/Mistral-7B-Instruct-v0.3
      image: registry.redhat.io/rhaiis/vllm-cuda-rhel9:3.3.0
      replicas: 2
```

Because `tier: standard` is already covered by the `standard-access` policy and
the `standard-plan` subscription in `environments/prod/values.yaml`, nothing else
is needed. Verify locally, then open the PR:

```bash
./tests/render.sh
```

> `modelUri` carries the **weights**; `image` is the **vLLM runtime**. A ModelCar
> image in `image:` fails at startup with `vllm: command not found`, because a
> ModelCar contains model artifacts and no vLLM binary.

### Serve a model from an S3 bucket

`modelUri` accepts `s3://`, `hf://`, `oci://` and `pvc://`. For `s3://` and
`hf://`, KServe injects an **initContainer** called `storage-initializer` that
downloads the prefix into an `emptyDir` before vLLM starts:

```
initContainer storage-initializer     args: [s3://bucket/prefix/, /mnt/models]
    ↓  emptyDir "kserve-provision-location", read-write
container main (vLLM)                 same volume at /mnt/models, read-only
```

The chart templates none of that — KServe creates it. What the chart must supply
is credentials, and KServe looks for them in exactly one place: **the Secrets
attached to the pod's ServiceAccount.** Define the bucket once:

```yaml
storage:
  s3:
    - name: models
      endpoint: s3.openshift-storage.svc:443   # omit for real AWS S3
      region: us-east-1
      useHttps: "1"
      verifySsl: "1"
      existingSecret: odf-model-bucket         # keys: awsAccessKeyID / awsSecretAccessKey
      annotateExistingSecret: true             # stamps the settings above onto it
```

then reference it from any number of models:

```yaml
models:
  - name: llama-3-3-70b
    inference:
      modelUri: s3://maas-models/llama-3.3-70b-instruct/
      modelName: meta-llama/Llama-3.3-70B-Instruct
      image: registry.redhat.io/rhaiis/vllm-cuda-rhel9:3.3.0
      storageProfile: models
      storageInitializer:
        resources:
          requests: { ephemeral-storage: 160Gi }
          limits:   { ephemeral-storage: 200Gi }
```

The chart renders the `Secret` annotations and a `ServiceAccount` that references
it, in every namespace that uses the profile, and sets `serviceAccountName` on
the pod. Credential sources are mutually exclusive — pick one:

| Source | Use |
|---|---|
| `existingSecret` | Production. Secret managed by ESO / Sealed Secrets |
| `create: true` | Sandbox only — writes the access key into git |
| `roleArn` | AWS IRSA. Annotates the ServiceAccount, no static keys at all |
| `useAnonymousCredential: "true"` | Public bucket |

Two things to size before you deploy:

- **Ephemeral storage.** The weights land on the node's disk, not a PVC, and are
  re-downloaded on every pod start. Without an explicit
  `storageInitializer.resources` request the kubelet evicts the pod partway
  through a large download. For very large models or many replicas, an
  `oci://` ModelCar or a pre-populated `pvc://` avoids the repeated transfer
  entirely.
- **Readiness probe.** Download time is counted before the first probe fires.
  Raise `readinessProbe.initialDelaySeconds` and `failureThreshold` accordingly.

`annotateExistingSecret: true` needs `ServerSideApply=true` in the Application's
`syncOptions` — the chart renders only annotations on that Secret, and a
client-side apply would prune the credential keys. It is already set in both
environments here.

For `oci://` ModelCars and the weightless simulator, skip the download step:

```yaml
      storageInitializer:
        enabled: false
```

### Withdraw a model

Set `enabled: false` rather than deleting the block — the entry stays in git as a
record of what was once published, and the policies stop referencing it:

```yaml
  - name: mistral-7b
    enabled: false
```

With `prune: false` (the default) Argo CD reports the leftover objects as
out-of-sync but does not delete them. Remove them deliberately:

```bash
oc delete llminferenceservice,maasmodelref mistral-7b -n llm-prod
```

### Change a quota

```yaml
subscriptions:
  - name: standard-plan
    tokenRateLimits:
      - limit: 1000000      # was 500000
        window: 1h
```

Windows accept `s`, `m` or `h` only. Days were removed from the API — write
`24h`, not `1d`. Both the JSON schema and the template guard reject `1d`.

### Grant a group access to a tier

```yaml
accessPolicies:
  - name: standard-access
    subjects:
      groups:
        - "maas-users"
        - "data-science"    # new
```

### Onboard an external provider

```yaml
models:
  - name: claude-sonnet
    backend: ExternalModel
    tier: premium
    external:
      provider: anthropic
      endpoint: api.anthropic.com     # bare FQDN, no scheme, no path
      targetModel: claude-sonnet-4-5-20241022
      credentials:
        secretName: anthropic-credentials
```

Create the Secret out of band — with External Secrets Operator or Sealed Secrets,
never inline in git. `validation.forbidInlineSecrets: true` is set in prod and
fails the render if anyone tries.

---

## Checking model health

`MaaSModelRef` is the one object worth watching: it aggregates backend readiness
and governance into a single phase.

```bash
# The catalogue at a glance
oc get maasmodelref -A -l maas.pase52.io/environment=prod

# Everything that is not Ready, with the reason
oc get maasmodelref -A -l maas.pase52.io/environment=prod -o jsonpath='
{range .items[?(@.status.phase!="Ready")]}{.metadata.namespace}/{.metadata.name}{"\t"}{.status.phase}{"\t"}{range .status.conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}'
```

| Phase | Meaning | Argo CD shows |
|---|---|---|
| `Ready` | Backend serving **and** governance attached | Healthy |
| `Pending` | Backend still starting, or no policy/subscription pair | Progressing, or Degraded if governance is missing |
| `Unhealthy` | Governance fine, backend runtime failing — a live outage | Degraded |
| `Failed` | Unrecoverable reconcile error | Degraded |
| `Invalid` | Malformed spec | Degraded |

`Ready` requires **both** halves. A perfectly healthy vLLM pod still reports
`Pending` if no `MaaSAuthPolicy` and `MaaSSubscription` cover it, because callers
would be refused. [docs/HEALTH.md](docs/HEALTH.md) is the runbook.

End-to-end check through the gateway — this exercises auth, routing and quota
together, which no `oc get` can:

```bash
TOKEN=$(oc whoami -t)
MAAS=$(oc get route maas-api-route -n models-as-a-service -o jsonpath='{.spec.host}')
curl -sS -H "Authorization: Bearer $TOKEN" https://$MAAS/v1/models | jq '.data[] | {id, ready, url}'
```

---

## The values file

Three top-level lists, joined by selectors rather than by repeating model names:

```yaml
models:            # what is deployed
  - name: granite-3-1-8b
    tier: standard

accessPolicies:    # who may call it
  - name: standard-access
    modelSelector:
      tiers: ["standard"]        # ← matches the model above
    subjects:
      groups: ["maas-users"]

subscriptions:     # how much they may use
  - name: standard-plan
    modelSelector:
      tiers: ["standard"]        # ← same
    owner:
      groups: ["maas-users"]
    tokenRateLimits:
      - limit: 500000
        window: 1h
```

A selector matches a model when **any** of `all: true`, `tiers`, or `names`
matches. An empty selector matches nothing — it fails closed, so a typo in a tier
name removes access rather than granting it to everything.

`modelDefaults` supplies replicas, resources, probes, node placement and security
context to every model, so an individual entry only states what makes it
different.

### Guardrails

`helm template` fails — before anything reaches the cluster — on:

- a model with no access policy or no subscription (`validation.require*`)
- duplicate model names in one namespace
- an invalid rate-limit window such as `1d`
- an external endpoint with a scheme or path (`https://api.openai.com/v1`)
- an inline API key where `forbidInlineSecrets` is set
- `external.tls: false` with a credential attached, unless explicitly
  acknowledged with `allowInsecureCredentials: true`
- a selector that matches no model

Each of these otherwise produces a model that syncs green and never serves.

---

## Argo CD behaviour

Configured to the stated operating policy: **ops drive the syncs.**

| Setting | Default | Effect |
|---|---|---|
| `syncPolicy.automated.enabled` | `false` | No auto-sync. Argo CD shows OutOfSync and waits |
| `automated.prune` | `false` | Nothing is deleted automatically |
| `automated.selfHeal` | `false` | Manual cluster edits are not reverted — ops can hot-fix during an incident |
| `cascadeDeleteFinalizer` | `false` | Deleting the Application leaves the models running |

All of it is configurable in `charts/maas-gitops/values.yaml`, per environment.
Enabling auto-sync for sandbox only is a two-line change on that Application:

```yaml
applications:
  - name: maas-models-sandbox
    syncPolicy:
      automated:
        enabled: true
        prune: false
        selfHeal: false
```

Also available per environment: `syncOptions`, `retry`, `ignoreDifferences`,
`revisionHistoryLimit`, `prunePropagationPolicy`, `info`, and `AppProject`
`syncWindows` for change-freeze periods.

### Sync waves

```
wave  0   LLMInferenceService / ExternalModel
wave 10   MaaSModelRef + MaaSAuthPolicy + MaaSSubscription
wave 20   PrometheusRule, inventory ConfigMap
```

`MaaSModelRef` and the two governance objects share wave 10 on purpose. A
`MaaSModelRef` only becomes Ready once a policy and subscription cover it, and
those only become Active once the `MaaSModelRef` exists. Put them in separate
waves and the sync deadlocks: the earlier wave never goes Healthy, so the later
one is never applied.

---

## Testing changes

```bash
./tests/render.sh      # renders every environment, asserts structural invariants
./tests/lua/run.sh     # runs the Argo CD health checks against status fixtures
```

`tests/lua/run.sh` executes the Lua in gopher-lua — the interpreter Argo CD
embeds. A syntax error or wrong branch in a health check does not fail a Helm
render or an Argo CD sync; it fails silently at runtime and shows a broken model
as green. This suite is what catches that.

Both scripts need `helm` and `yq`; the Lua suite also needs `go`.

---

## Further reading

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — request path, resource graph, design decisions
- [docs/HEALTH.md](docs/HEALTH.md) — health model and incident runbook
- [AGENTS.md](AGENTS.md) — orientation for AI agents
- [Upstream MaaS](https://github.com/opendatahub-io/models-as-a-service)
- [Red Hat: Govern LLM access with Models-as-a-Service](https://docs.redhat.com/en/documentation/red_hat_openshift_ai_self-managed/3.4/html-single/govern_llm_access_with_models-as-a-service/index)
