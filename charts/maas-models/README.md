# maas-models

Renders the per-model resources for Models-as-a-Service on Red Hat OpenShift AI.

One Argo CD `Application` per environment points at this chart with an
`environments/<env>/values.yaml`. See the [repository README](../../README.md)
for installation and day-2 operations, and
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md) for the design.

## What it renders

Per entry in `models[]`:

| Wave | Object | Namespace |
|---|---|---|
| -10 | `Namespace` (optional) | — |
| -5 | `Secret` (external credentials, sandbox only) | model namespace |
| 0 | `LLMInferenceService` or `ExternalModel` | model namespace |
| 10 | `MaaSModelRef` | model namespace |
| 10 | `MaaSAuthPolicy` (from `accessPolicies[]`) | tenant namespace |
| 10 | `MaaSSubscription` (from `subscriptions[]`) | tenant namespace |
| 20 | inventory `ConfigMap`, `PrometheusRule`, kube-state-metrics config | tenant namespace |

## Values

`values.yaml` is the reference — every key carries a `# --` comment explaining
what it does and why it defaults the way it does. `values.schema.json` enforces
types, enums and patterns before templating starts.

Top-level keys:

| Key | Purpose |
|---|---|
| `environment` | Environment name; becomes `maas.pase52.io/environment` on every object |
| `global` | Tenant namespace, model namespace, gateway coordinates, pull secrets, registry mirror |
| `namespaces` | Optional namespace creation |
| `argocd` | Sync waves and sync/compare options on the rendered resources |
| `modelDefaults` | Replicas, resources, probes, placement and security context inherited by every model |
| `models[]` | The catalogue |
| `accessPolicies[]` | Who may call which models |
| `subscriptions[]` | Token quotas |
| `observability` | Inventory ConfigMap, kube-state-metrics config, PrometheusRule |
| `validation` | Fail-fast guardrails |

## Guardrails

The chart refuses to render — before anything reaches the cluster — when a
values file would produce a model that syncs green and never serves:

| Guard | Controlled by |
|---|---|
| Model with no access policy | `validation.requireAccessPolicy` |
| Model with no subscription | `validation.requireSubscription` |
| Inline API key in git | `validation.forbidInlineSecrets` |
| Duplicate model name in a namespace | always |
| Rate-limit window using days (`1d`) | always |
| External endpoint with scheme or path | always |
| `external.tls: false` with a credential attached | requires `allowInsecureCredentials: true` |
| Selector matching no model | always |

## Testing

```bash
helm lint charts/maas-models
helm template test charts/maas-models -f environments/prod/values.yaml --kube-version 1.32.0
../../tests/render.sh
```

`--kube-version` is required locally because the chart declares
`kubeVersion: ">=1.32.0-0"`.
