# maas-gitops

Argo CD wiring for MaaS model management: the `AppProject`, the per-environment
`Application`s, and — most importantly — the custom health checks that make model
health visible.

Applied once by a cluster admin. See the
[repository README](../../README.md#installation) for the install sequence.

## The health checks

Argo CD assumes any CRD it does not recognise is Healthy. Without these checks a
`MaaSModelRef` shows a green tick the moment it is created, whether or not the
model ever serves a request.

The Lua in `templates/_healthchecks.tpl` reads `status.phase` and the
`RuntimeReady` / `GovernanceAttached` conditions and maps them onto Argo CD
states. The governing rule: **Progressing means "wait", Degraded means "a human
is needed"** — so a `Pending` caused by missing governance reports Degraded,
because it never resolves on its own.

Covers `MaaSModelRef`, `MaaSAuthPolicy`, `MaaSSubscription`, `ExternalModel` and
`LLMInferenceService`. Full mapping in
[docs/ARCHITECTURE.md](../../docs/ARCHITECTURE.md#health-model).

### Delivery

The OpenShift GitOps operator owns `argocd-cm`, so writing health checks there
directly gets reverted. Two supported paths:

| Mode | Values | Use when |
|---|---|---|
| ConfigMap artifact (default) | `healthChecks.configMap.enabled=true` | Normal case. Renders the patch; an admin applies it with `oc patch argocd`. |
| Partial `ArgoCD` resource | `healthChecks.argocdResource.enabled=true` | The GitOps instance is itself managed in git. **Replaces** the instance's `resourceHealthChecks` list. |

Do not enable both for one instance.

### Testing

```bash
../../tests/lua/run.sh
```

Executes the rendered Lua in gopher-lua — the interpreter Argo CD embeds —
against status fixtures. A Lua error does not fail a Helm render or an Argo CD
sync; Argo CD falls back to Healthy. This suite is the only thing that catches it.

## Operating policy defaults

Set to "ops drive the syncs", per the stated requirement:

| Setting | Default | Effect |
|---|---|---|
| `syncPolicy.automated.enabled` | `false` | No auto-sync; Argo CD shows OutOfSync and waits |
| `automated.prune` | `false` | Nothing deleted automatically |
| `automated.selfHeal` | `false` | Manual cluster edits survive — ops can hot-fix during an incident |
| `cascadeDeleteFinalizer` | `false` | Deleting the Application leaves the models running |

Everything remains configurable per environment. Enabling auto-sync for sandbox:

```yaml
applications:
  - name: maas-models-sandbox
    syncPolicy:
      automated:
        enabled: true
        prune: false
        selfHeal: false
```

Also configurable: `syncOptions`, `retry` with backoff, `ignoreDifferences`,
`revisionHistoryLimit`, `prunePropagationPolicy`, `info` links, and `AppProject`
`syncWindows` for change-freeze periods.

`tests/render.sh` asserts the defaults have not drifted — auto-prune and cascade
finalizers fail the suite.

## Values

| Key | Purpose |
|---|---|
| `argocd.namespace` / `argocd.instanceName` | Which Argo CD instance to target |
| `healthChecks` | Enable/disable, delivery mode, per-kind toggles |
| `appProject` | Source repos, destinations, resource allow/deny lists, sync windows |
| `applicationDefaults` | Standard Argo CD knobs inherited by every Application |
| `applications[]` | Per-environment overrides |
