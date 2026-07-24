{{/*
=============================================================================
Fail-fast validation
=============================================================================
Runs before any resource is rendered. The goal is that an invalid values.yaml
fails in CI (`helm template`) or at Argo CD sync time with a precise message —
instead of syncing "Healthy" while a model silently never serves traffic.
*/}}

{{- define "maas-models.validate" -}}
{{- $root := . -}}
{{- $v := $root.Values.validation | default dict -}}
{{- $seen := dict -}}

{{- range $m := (include "maas-models.enabledModels" $root | fromJsonArray) -}}

  {{/* --- identity ------------------------------------------------------ */}}
  {{- if not $m.name -}}
    {{- fail "models[]: every model requires a `name`" -}}
  {{- end -}}
  {{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" $m.name) -}}
    {{- fail (printf "models[%s]: `name` must be a lowercase DNS-1123 label (a-z, 0-9, -)" $m.name) -}}
  {{- end -}}
  {{- if gt (len $m.name) 63 -}}
    {{- fail (printf "models[%s]: `name` exceeds 63 characters" $m.name) -}}
  {{- end -}}

  {{/* Duplicate names collide on MaaSModelRef and silently overwrite each other. */}}
  {{- $ns := include "maas-models.modelNamespace" (dict "root" $root "model" $m) -}}
  {{- $key := printf "%s/%s" $ns $m.name -}}
  {{- if hasKey $seen $key -}}
    {{- fail (printf "models[%s]: duplicate model name in namespace %s — names must be unique per namespace" $m.name $ns) -}}
  {{- end -}}
  {{- $seen = set $seen $key true -}}

  {{/* --- backend ------------------------------------------------------- */}}
  {{- $backend := $m.backend | default "LLMInferenceService" -}}
  {{- if not (has $backend (list "LLMInferenceService" "ExternalModel")) -}}
    {{- fail (printf "models[%s]: `backend` must be LLMInferenceService or ExternalModel, got %q" $m.name $backend) -}}
  {{- end -}}

  {{- if eq $backend "LLMInferenceService" -}}
    {{- $inf := $m.inference | default dict -}}
    {{- if not $inf.modelUri -}}
      {{- fail (printf "models[%s]: LLMInferenceService backend requires `inference.modelUri` (oci://, hf://, s3://, pvc://)" $m.name) -}}
    {{- end -}}
    {{- if not $inf.modelName -}}
      {{- fail (printf "models[%s]: LLMInferenceService backend requires `inference.modelName` — this is the model identity clients send in the OpenAI `model` field" $m.name) -}}
    {{- end -}}

    {{/* --- object storage credentials --------------------------------- */}}
    {{- $si := $inf.storageInitializer | default dict -}}
    {{- $needsCreds := and (hasPrefix "s3://" $inf.modelUri) (ne $si.enabled false) -}}
    {{- if $needsCreds -}}
      {{- $profileName := $inf.storageProfile | default "" -}}
      {{- if and (not $profileName) (not $inf.serviceAccountName) -}}
        {{- fail (printf "models[%s]: an s3:// modelUri needs credentials. KServe's storage-initializer reads them only from the Secrets attached to the pod's ServiceAccount, so set `inference.storageProfile` (defined under `storage.s3`) or `inference.serviceAccountName` for a ServiceAccount you manage yourself." $m.name) -}}
      {{- end -}}
      {{- if $profileName -}}
        {{- $found := dict -}}
        {{- range $p := (($root.Values.storage | default dict).s3 | default list) -}}
          {{- if eq $p.name $profileName -}}{{- $found = $p -}}{{- end -}}
        {{- end -}}
        {{- if not $found.name -}}
          {{- fail (printf "models[%s]: `inference.storageProfile: %s` does not match any entry in `storage.s3[].name`" $m.name $profileName) -}}
        {{- end -}}
        {{- if eq $found.enabled false -}}
          {{- fail (printf "models[%s]: storage profile %q is disabled, so no ServiceAccount is rendered and the download will fail with a credentials error" $m.name $profileName) -}}
        {{- end -}}
        {{/* Exactly one credential source, or the ServiceAccount points at nothing usable. */}}
        {{- $es := $found.externalSecret | default dict -}}
        {{- $sources := list -}}
        {{- if $es.enabled -}}{{- $sources = append $sources "externalSecret" -}}{{- end -}}
        {{- if $found.existingSecret -}}{{- $sources = append $sources "existingSecret" -}}{{- end -}}
        {{- if $found.create -}}{{- $sources = append $sources "create" -}}{{- end -}}
        {{- if $found.roleArn -}}{{- $sources = append $sources "roleArn" -}}{{- end -}}

        {{/* --- Vault / External Secrets --- */}}
        {{- if $es.enabled -}}
          {{- $store := ($root.Values.storage | default dict).secretStore | default dict -}}
          {{- $storeRef := $es.storeRef | default dict -}}
          {{/*
          `storage.secretStore.name` carries a default, so its presence proves
          nothing — the store only exists if it was enabled, or if this profile
          points at one managed elsewhere.
          */}}
          {{- if and (not $store.enabled) (not $storeRef.name) -}}
            {{- fail (printf "storage.s3[%s]: `externalSecret.enabled` is set but no secret store is available. Set `storage.secretStore.enabled: true` with the Vault settings, or point this profile at a store managed elsewhere with `externalSecret.storeRef.name`." $profileName) -}}
          {{- end -}}
          {{- $storeName := $storeRef.name | default $store.name -}}
          {{- if not $storeName -}}
            {{- fail (printf "storage.s3[%s]: no secret store name resolved — set `storage.secretStore.name` or `externalSecret.storeRef.name`" $profileName) -}}
          {{- end -}}
          {{- if not $es.basePath -}}
            {{- fail (printf "storage.s3[%s]: `externalSecret.basePath` is required — it is the Vault folder holding one secret per model, e.g. maas/models. The model name (or `inference.externalSecretKey`) is appended to it." $profileName) -}}
          {{- end -}}
          {{- if hasPrefix "/" $es.basePath -}}
            {{- fail (printf "storage.s3[%s]: `externalSecret.basePath` must not start with / — it is relative to the KV mount configured as storage.secretStore.vault.path" $profileName) -}}
          {{- end -}}
          {{/*
          A store this chart neither renders nor was told to reference by name is
          almost always a typo; ESO reports SecretSyncedError only at runtime.
          */}}
          {{- if and $store.enabled $store.create (not $storeRef.name) -}}
            {{- $wantKind := $storeRef.kind | default $store.kind | default "ClusterSecretStore" -}}
            {{- if ne $wantKind ($store.kind | default "ClusterSecretStore") -}}
              {{- fail (printf "storage.s3[%s]: `externalSecret.storeRef.kind: %s` does not match the rendered store kind %s" $profileName $wantKind ($store.kind | default "ClusterSecretStore")) -}}
            {{- end -}}
          {{- end -}}
        {{- end -}}
        {{- if empty $sources -}}
          {{- if ne ($found.useAnonymousCredential | toString) "true" -}}
            {{- fail (printf "storage.s3[%s]: no credential source. Set one of `existingSecret` (recommended), `create: true` (sandbox only), or `roleArn` (AWS IRSA) — or `useAnonymousCredential: \"true\"` for a public bucket." $profileName) -}}
          {{- end -}}
        {{- else if gt (len $sources) 1 -}}
          {{- fail (printf "storage.s3[%s]: %s are mutually exclusive credential sources — pick one" $profileName (join " and " $sources)) -}}
        {{- end -}}
        {{- if and $found.create (not $found.accessKeyId) -}}
          {{- fail (printf "storage.s3[%s]: `create: true` but `accessKeyId` is empty" $profileName) -}}
        {{- end -}}
        {{- if and $v.forbidInlineSecrets $found.create -}}
          {{- fail (printf "storage.s3[%s]: `create: true` writes the S3 access key into git, which validation.forbidInlineSecrets forbids in this environment. Use `existingSecret` with an ESO/Sealed Secret, or `roleArn` for IRSA." $profileName) -}}
        {{- end -}}
        {{/*
        A referenced Secret must carry the S3 annotations or the initContainer
        gets keys with no endpoint or region. The chart can apply them, but only
        if asked — silently patching a Secret it does not own would be worse.
        */}}
        {{- if and $found.existingSecret (not $found.annotateExistingSecret) -}}
          {{- if or $found.endpoint $found.region -}}
            {{- fail (printf "storage.s3[%s]: `endpoint`/`region` are set but `annotateExistingSecret` is false, so they would never reach the storage-initializer — KServe reads S3 settings from the Secret's annotations. Set `annotateExistingSecret: true` to have the chart apply them, or put them on %s yourself and remove them here." $profileName $found.existingSecret) -}}
          {{- end -}}
        {{- end -}}
      {{- end -}}
    {{- end -}}

  {{- else -}}
    {{- $ext := $m.external | default dict -}}
    {{- if not $ext.provider -}}
      {{- fail (printf "models[%s]: ExternalModel backend requires `external.provider`" $m.name) -}}
    {{- end -}}
    {{- if not (has $ext.provider (list "openai" "anthropic" "azure-openai" "vertex" "bedrock-openai")) -}}
      {{- fail (printf "models[%s]: `external.provider` must be one of openai|anthropic|azure-openai|vertex|bedrock-openai, got %q" $m.name $ext.provider) -}}
    {{- end -}}
    {{- if not $ext.endpoint -}}
      {{- fail (printf "models[%s]: ExternalModel backend requires `external.endpoint` (FQDN only, no scheme or path)" $m.name) -}}
    {{- end -}}
    {{- if or (hasPrefix "http://" $ext.endpoint) (hasPrefix "https://" $ext.endpoint) (contains "/" $ext.endpoint) -}}
      {{- fail (printf "models[%s]: `external.endpoint` must be a bare FQDN such as api.openai.com — no scheme, no path" $m.name) -}}
    {{- end -}}
    {{- if not $ext.targetModel -}}
      {{- fail (printf "models[%s]: ExternalModel backend requires `external.targetModel` (the upstream provider's model id)" $m.name) -}}
    {{- end -}}
    {{- $cred := $ext.credentials | default dict -}}
    {{- if and (not $cred.secretName) (not $cred.create) -}}
      {{- fail (printf "models[%s]: ExternalModel requires `external.credentials.secretName` (pre-existing Secret) or `external.credentials.create: true`" $m.name) -}}
    {{- end -}}
    {{- if and $cred.create (not $cred.apiKey) -}}
      {{- fail (printf "models[%s]: `external.credentials.create` is true but `apiKey` is empty" $m.name) -}}
    {{- end -}}
    {{- if and $v.forbidInlineSecrets $cred.apiKey -}}
      {{- fail (printf "models[%s]: inline `external.credentials.apiKey` is forbidden in this environment (validation.forbidInlineSecrets). Reference a Secret managed by ESO/Sealed Secrets via `credentials.secretName` instead." $m.name) -}}
    {{- end -}}
    {{/*
    TLS off + a credentialRef means the provider API key crosses the network in
    cleartext. Upstream permits it for trusted isolated networks; require the
    operator to say so explicitly rather than reaching it by omission.
    */}}
    {{- if and (hasKey $ext "tls") (not $ext.tls) -}}
      {{- if not $ext.allowInsecureCredentials -}}
        {{- fail (printf "models[%s]: `external.tls: false` sends the provider API key in cleartext. If the network path to %s is genuinely trusted and isolated, set `external.allowInsecureCredentials: true` to acknowledge it." $m.name $ext.endpoint) -}}
      {{- end -}}
    {{- end -}}
    {{- if and (hasKey $ext "port") $ext.port -}}
      {{- if or (lt (int $ext.port) 1) (gt (int $ext.port) 65535) -}}
        {{- fail (printf "models[%s]: `external.port` must be between 1 and 65535" $m.name) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}

  {{/* --- governance coverage ------------------------------------------- */}}
  {{- if $v.requireAccessPolicy -}}
    {{- if ne (include "maas-models.hasAccessPolicy" (dict "root" $root "model" $m)) "true" -}}
      {{- fail (printf "models[%s]: no accessPolicy selects this model. Without a MaaSAuthPolicy every request is denied and the model never reaches phase=Ready. Add it to an accessPolicy `modelSelector`, or set validation.requireAccessPolicy=false." $m.name) -}}
    {{- end -}}
  {{- end -}}
  {{- if $v.requireSubscription -}}
    {{- if ne (include "maas-models.hasSubscription" (dict "root" $root "model" $m)) "true" -}}
      {{- fail (printf "models[%s]: no subscription selects this model. Without a MaaSSubscription no token quota exists and the model never reaches phase=Ready. Add it to a subscription `modelSelector`, or set validation.requireSubscription=false." $m.name) -}}
    {{- end -}}
  {{- end -}}

{{- end -}}

{{/* --- secret store ----------------------------------------------------- */}}
{{- $store := ($root.Values.storage | default dict).secretStore | default dict -}}
{{- if and $store.enabled $store.create -}}
  {{- if not $store.name -}}
    {{- fail "storage.secretStore: `name` is required" -}}
  {{- end -}}
  {{- if not (has ($store.kind | default "ClusterSecretStore") (list "SecretStore" "ClusterSecretStore")) -}}
    {{- fail (printf "storage.secretStore: `kind` must be SecretStore or ClusterSecretStore, got %q" $store.kind) -}}
  {{- end -}}
  {{- $vault := $store.vault | default dict -}}
  {{- if not $vault.server -}}
    {{- fail "storage.secretStore.vault: `server` is required, e.g. https://vault.example.com" -}}
  {{- end -}}
  {{- if not (hasPrefix "http" $vault.server) -}}
    {{- fail (printf "storage.secretStore.vault: `server` must include the scheme, got %q" $vault.server) -}}
  {{- end -}}
  {{- if not (has ($vault.version | default "v2") (list "v1" "v2")) -}}
    {{- fail (printf "storage.secretStore.vault: `version` must be v1 or v2, got %q" $vault.version) -}}
  {{- end -}}
  {{- $auth := $vault.auth | default dict -}}
  {{- $k8s := $auth.kubernetes | default dict -}}
  {{- $approle := $auth.appRole | default dict -}}
  {{- $token := $auth.tokenSecretRef | default dict -}}
  {{- $methods := list -}}
  {{- if $k8s.enabled -}}{{- $methods = append $methods "kubernetes" -}}{{- end -}}
  {{- if $approle.enabled -}}{{- $methods = append $methods "appRole" -}}{{- end -}}
  {{- if $token.name -}}{{- $methods = append $methods "tokenSecretRef" -}}{{- end -}}
  {{- if empty $methods -}}
    {{- fail "storage.secretStore.vault.auth: no authentication method enabled. Prefer `kubernetes` — Vault validates the ESO ServiceAccount token, so no static credential is stored in the cluster." -}}
  {{- end -}}
  {{- if gt (len $methods) 1 -}}
    {{- fail (printf "storage.secretStore.vault.auth: %s are mutually exclusive — enable one" (join " and " $methods)) -}}
  {{- end -}}
  {{- if $k8s.enabled -}}
    {{- if not $k8s.role -}}
      {{- fail "storage.secretStore.vault.auth.kubernetes: `role` is required — it is the Vault role bound to the ESO ServiceAccount" -}}
    {{- end -}}
    {{- if not (($k8s.serviceAccountRef | default dict).name) -}}
      {{- fail "storage.secretStore.vault.auth.kubernetes: `serviceAccountRef.name` is required" -}}
    {{- end -}}
    {{/*
    A ClusterSecretStore is cluster-scoped, so a bare ServiceAccount name is
    ambiguous — ESO cannot guess which namespace it lives in.
    */}}
    {{- if and (eq ($store.kind | default "ClusterSecretStore") "ClusterSecretStore") (not (($k8s.serviceAccountRef | default dict).namespace)) -}}
      {{- fail "storage.secretStore.vault.auth.kubernetes: `serviceAccountRef.namespace` is required for a ClusterSecretStore — a cluster-scoped store cannot resolve a bare ServiceAccount name" -}}
    {{- end -}}
  {{- end -}}
  {{- if and $approle.enabled (not $approle.roleId) -}}
    {{- fail "storage.secretStore.vault.auth.appRole: `roleId` is required" -}}
  {{- end -}}
  {{- if and $approle.enabled (not (($approle.secretRef | default dict).name)) -}}
    {{- fail "storage.secretStore.vault.auth.appRole: `secretRef.name` is required — the Secret holding the AppRole secretId" -}}
  {{- end -}}
{{- end -}}

{{/* --- access policies ------------------------------------------------- */}}
{{- range $p := $root.Values.accessPolicies -}}
{{- if ne $p.enabled false -}}
  {{- if not $p.name -}}
    {{- fail "accessPolicies[]: every policy requires a `name`" -}}
  {{- end -}}
  {{- $subj := $p.subjects | default dict -}}
  {{- if and (empty ($subj.groups | default list)) (empty ($subj.users | default list)) -}}
    {{- fail (printf "accessPolicies[%s]: at least one of `subjects.groups` or `subjects.users` must be set" $p.name) -}}
  {{- end -}}
  {{- $sel := (include "maas-models.selectModels" (dict "root" $root "selector" $p.modelSelector) | fromJsonArray) -}}
  {{- if empty $sel -}}
    {{- fail (printf "accessPolicies[%s]: `modelSelector` matches no enabled model. A MaaSAuthPolicy with an empty modelRefs list is rejected by the API server." $p.name) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/* --- subscriptions --------------------------------------------------- */}}
{{- range $s := $root.Values.subscriptions -}}
{{- if ne $s.enabled false -}}
  {{- if not $s.name -}}
    {{- fail "subscriptions[]: every subscription requires a `name`" -}}
  {{- end -}}
  {{- $owner := $s.owner | default dict -}}
  {{- if and (empty ($owner.groups | default list)) (empty ($owner.users | default list)) -}}
    {{- fail (printf "subscriptions[%s]: at least one of `owner.groups` or `owner.users` must be set" $s.name) -}}
  {{- end -}}
  {{- $sel := (include "maas-models.selectModels" (dict "root" $root "selector" $s.modelSelector) | fromJsonArray) -}}
  {{- if empty $sel -}}
    {{- fail (printf "subscriptions[%s]: `modelSelector` matches no enabled model" $s.name) -}}
  {{- end -}}

  {{/* Validate every rate-limit window that will be rendered, including per-model overrides. */}}
  {{- range $m := $sel -}}
    {{- $limits := $s.tokenRateLimits | default list -}}
    {{- $ovr := get ($s.perModel | default dict) $m.name -}}
    {{- if and $ovr $ovr.tokenRateLimits -}}
      {{- $limits = $ovr.tokenRateLimits -}}
    {{- end -}}
    {{- if empty $limits -}}
      {{- fail (printf "subscriptions[%s]: model %q has no tokenRateLimits — MaaSSubscription requires at least one per model" $s.name $m.name) -}}
    {{- end -}}
    {{- range $l := $limits -}}
      {{- if not (regexMatch "^[1-9][0-9]{0,3}(s|m|h)$" ($l.window | toString)) -}}
        {{- fail (printf "subscriptions[%s]: invalid window %q for model %q. Must match ^[1-9][0-9]{0,3}(s|m|h)$ — days are not supported, use 24h instead of 1d." $s.name ($l.window | toString) $m.name) -}}
      {{- end -}}
      {{- if not $l.limit -}}
        {{- fail (printf "subscriptions[%s]: tokenRateLimits entry for model %q is missing `limit`" $s.name $m.name) -}}
      {{- end -}}
      {{- if le (int64 $l.limit) 0 -}}
        {{- fail (printf "subscriptions[%s]: `limit` must be a positive integer for model %q" $s.name $m.name) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- end -}}
