{{/*
=============================================================================
Naming
=============================================================================
*/}}

{{- define "maas-models.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "maas-models.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Standard labels applied to every rendered object.
Follows the Kubernetes recommended label set plus a MaaS-specific environment
label so the DevOps team can slice by environment across namespaces:
    oc get maasmodelref -A -l maas.pase52.io/environment=prod
*/}}
{{- define "maas-models.labels" -}}
helm.sh/chart: {{ include "maas-models.chart" . }}
app.kubernetes.io/name: {{ include "maas-models.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: models-as-a-service
maas.pase52.io/environment: {{ .Values.environment | quote }}
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
Per-model labels. Adds the model identity and tier so a single label selector
answers "show me everything that makes up model X".
Usage: include "maas-models.modelLabels" (dict "root" $ "model" $m "component" "modelref")
*/}}
{{- define "maas-models.modelLabels" -}}
{{ include "maas-models.labels" .root }}
app.kubernetes.io/component: {{ .component }}
maas.pase52.io/model: {{ .model.name | quote }}
maas.pase52.io/tier: {{ .model.tier | default "default" | quote }}
maas.pase52.io/backend: {{ .model.backend | default "LLMInferenceService" | quote }}
{{- end -}}

{{/*
=============================================================================
Argo CD annotations
=============================================================================
Renders sync-wave / sync-options / compare-options for a given wave key.
Usage: include "maas-models.argoAnnotations" (dict "root" $ "wave" "modelRef")
*/}}
{{- define "maas-models.argoAnnotations" -}}
{{- $root := .root -}}
{{- $argo := $root.Values.argocd | default dict -}}
{{- if $argo.enabled -}}
argocd.argoproj.io/sync-wave: {{ get ($argo.syncWaves | default dict) .wave | default "0" | quote }}
{{- with $argo.syncOptions }}
argocd.argoproj.io/sync-options: {{ join "," . | quote }}
{{- end }}
{{- with $argo.compareOptions }}
argocd.argoproj.io/compare-options: {{ . | quote }}
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Common metadata block: labels + argo annotations + user annotations.
Usage: include "maas-models.metadata" (dict "root" $ "model" $m "component" "x" "wave" "workload" "annotations" $extra)
*/}}
{{- define "maas-models.metadata" -}}
labels:
  {{- if .model }}
  {{- include "maas-models.modelLabels" (dict "root" .root "model" .model "component" .component) | nindent 2 }}
  {{- else }}
  {{- include "maas-models.labels" .root | nindent 2 }}
  app.kubernetes.io/component: {{ .component }}
  {{- end }}
  {{- with .extraLabels }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
annotations:
  {{- include "maas-models.argoAnnotations" (dict "root" .root "wave" .wave) | nindent 2 }}
  {{- with .root.Values.commonAnnotations }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
  {{- with .annotations }}
  {{- toYaml . | nindent 2 }}
  {{- end }}
{{- end -}}

{{/*
=============================================================================
Model resolution
=============================================================================
*/}}

{{/* Namespace a model's workload + MaaSModelRef live in. */}}
{{- define "maas-models.modelNamespace" -}}
{{- .model.namespace | default .root.Values.global.modelNamespace -}}
{{- end -}}

{{/*
Enabled models as a JSON array. Every template starts from this so a model
disabled in one place is disabled everywhere.
Usage: {{- $models := (include "maas-models.enabledModels" $ | fromJsonArray) }}
*/}}
{{- define "maas-models.enabledModels" -}}
{{- $out := list -}}
{{- range $m := .Values.models -}}
{{- if ne $m.enabled false -}}
{{- $out = append $out $m -}}
{{- end -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/*
Resolve a `modelSelector` to the list of matching *enabled* models (JSON array).
Selector semantics — a model matches when ANY of these is true:
    all: true              -> every enabled model
    tiers: [a, b]          -> model.tier is in the list
    names: [x, y]          -> model.name is in the list
An empty selector matches nothing (fail closed — never grant access by accident).
Usage:
  {{- $sel := (include "maas-models.selectModels" (dict "root" $ "selector" $p.modelSelector) | fromJsonArray) }}
*/}}
{{- define "maas-models.selectModels" -}}
{{- $root := .root -}}
{{- $sel := .selector | default dict -}}
{{- $names := $sel.names | default list -}}
{{- $tiers := $sel.tiers | default list -}}
{{- $out := list -}}
{{- range $m := (include "maas-models.enabledModels" $root | fromJsonArray) -}}
{{- $hit := false -}}
{{- if $sel.all -}}
{{- $hit = true -}}
{{- else if has $m.name $names -}}
{{- $hit = true -}}
{{- else if has ($m.tier | default "default") $tiers -}}
{{- $hit = true -}}
{{- end -}}
{{- if $hit -}}
{{- $out = append $out $m -}}
{{- end -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/*
Render a MaaS `modelRefs:` list (name + namespace pairs) from a selector.
Shared by MaaSAuthPolicy and MaaSSubscription, which both reference
MaaSModelRef objects cross-namespace.
*/}}
{{- define "maas-models.modelRefList" -}}
{{- $root := .root -}}
{{- $out := list -}}
{{- range $m := .models -}}
{{- $out = append $out (dict "name" $m.name "namespace" (include "maas-models.modelNamespace" (dict "root" $root "model" $m))) -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
Render a `subjects`/`owner` block. Emits only the keys that have content:
an empty `groups:` key serialises to null and is rejected by the CRD schema.
Usage: include "maas-models.subjectBlock" (dict "groups" $g "users" $u)
*/}}
{{- define "maas-models.subjectBlock" -}}
{{- $out := dict -}}
{{- $groups := .groups | default list -}}
{{- $users := .users | default list -}}
{{- if $groups -}}
{{- $gl := list -}}
{{- range $g := $groups -}}
{{- $gl = append $gl (dict "name" $g) -}}
{{- end -}}
{{- $_ := set $out "groups" $gl -}}
{{- end -}}
{{- if $users -}}
{{- $_ := set $out "users" $users -}}
{{- end -}}
{{- toYaml $out -}}
{{- end -}}

{{/*
=============================================================================
Object storage
=============================================================================
Look up the storage.s3 profile a model references. Returns the profile as JSON,
or "{}" when the model names none.
Usage: {{- $p := (include "maas-models.storageProfile" (dict "root" $ "model" $m) | fromJson) }}
*/}}
{{- define "maas-models.storageProfile" -}}
{{- $name := ((.model.inference | default dict).storageProfile | default "") -}}
{{- $out := dict -}}
{{- if $name -}}
{{- range $p := ((.root.Values.storage | default dict).s3 | default list) -}}
{{- if eq $p.name $name -}}{{- $out = $p -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- $out | toJson -}}
{{- end -}}

{{/*
Name of the ServiceAccount that carries a model's object-storage credentials.
Empty when the model needs none.

The name depends on the credential source, because the ServiceAccount has to
point at whichever Secret holds the keys:
  · explicit serviceAccountName  -> used as-is (a ServiceAccount you manage)
  · Vault ExternalSecret         -> per model, since each model has its own
                                    Vault secret and therefore its own Secret
  · shared Secret / IRSA         -> per profile, one ServiceAccount for all
                                    models using that bucket
*/}}
{{- define "maas-models.storageServiceAccount" -}}
{{- $inf := .model.inference | default dict -}}
{{- if $inf.serviceAccountName -}}
{{- $inf.serviceAccountName -}}
{{- else -}}
{{- $p := (include "maas-models.storageProfile" (dict "root" .root "model" .model) | fromJson) -}}
{{- if $p.name -}}
{{- if (($p.externalSecret | default dict).enabled) -}}
{{- printf "maas-s3-%s" .model.name -}}
{{- else -}}
{{- $p.serviceAccountName | default (printf "maas-s3-%s" $p.name) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
The Vault key holding a model's credential. One secret per model, all under the
profile's basePath folder.
*/}}
{{- define "maas-models.vaultKey" -}}
{{- $inf := .model.inference | default dict -}}
{{- $key := $inf.externalSecretKey | default .model.name -}}
{{- $base := ((.profile.externalSecret | default dict).basePath | default "") | trimSuffix "/" -}}
{{- if $base -}}
{{- printf "%s/%s" $base $key -}}
{{- else -}}
{{- $key -}}
{{- end -}}
{{- end -}}

{{/*
S3 connection settings as Secret annotations. KServe reads these from the
Secret, not from the ServiceAccount or the LLMInferenceService. Values pass
straight through to environment variables, so they are strings.
*/}}
{{- define "maas-models.s3Annotations" -}}
{{- $p := . -}}
{{- $ann := dict -}}
{{- with $p.endpoint }}{{- $_ := set $ann "serving.kserve.io/s3-endpoint" (. | toString) }}{{- end }}
{{- with $p.region }}{{- $_ := set $ann "serving.kserve.io/s3-region" (. | toString) }}{{- end }}
{{- with $p.useHttps }}{{- $_ := set $ann "serving.kserve.io/s3-usehttps" (. | toString) }}{{- end }}
{{- with $p.verifySsl }}{{- $_ := set $ann "serving.kserve.io/s3-verifyssl" (. | toString) }}{{- end }}
{{- with $p.useVirtualBucket }}{{- $_ := set $ann "serving.kserve.io/s3-usevirtualbucket" (. | toString) }}{{- end }}
{{- with $p.useAccelerate }}{{- $_ := set $ann "serving.kserve.io/s3-useaccelerate" (. | toString) }}{{- end }}
{{- with $p.useAnonymousCredential }}{{- $_ := set $ann "serving.kserve.io/s3-useanoncredential" (. | toString) }}{{- end }}
{{- with $p.caBundleConfigMap }}{{- $_ := set $ann "serving.kserve.io/s3-cabundle-configmap" (. | toString) }}{{- end }}
{{- $ann | toJson -}}
{{- end -}}

{{/*
Comma-joined names of a model list. Used for the `managed-models` annotation so
`oc describe maasauthpolicy X` shows what it covers without cross-referencing.
Usage: include "maas-models.modelNames" $modelList
*/}}
{{- define "maas-models.modelNames" -}}
{{- $names := list -}}
{{- range $m := . -}}
{{- $names = append $names $m.name -}}
{{- end -}}
{{- $names | join "," -}}
{{- end -}}

{{/*
Regex alternation of every namespace this release deploys models into.
Used to scope PromQL selectors to just this release's workloads.
*/}}
{{- define "maas-models.namespaceRegex" -}}
{{- $root := . -}}
{{- $ns := list -}}
{{- range $m := (include "maas-models.enabledModels" $root | fromJsonArray) -}}
{{- $ns = append $ns (include "maas-models.modelNamespace" (dict "root" $root "model" $m)) -}}
{{- end -}}
{{- if empty $ns -}}
{{- $ns = list $root.Values.global.modelNamespace -}}
{{- end -}}
{{- $ns | uniq | sortAlpha | join "|" -}}
{{- end -}}

{{/*
=============================================================================
Image / URI rewriting for disconnected clusters
=============================================================================
Rewrites a Red Hat registry reference onto global.registryMirror when set.
Handles plain image refs and oci:// model URIs.
*/}}
{{- define "maas-models.image" -}}
{{- $mirror := .root.Values.global.registryMirror | default "" -}}
{{- $ref := .ref -}}
{{- if $mirror -}}
{{- $scheme := "" -}}
{{- if hasPrefix "oci://" $ref -}}
{{- $scheme = "oci://" -}}
{{- $ref = trimPrefix "oci://" $ref -}}
{{- end -}}
{{- range $host := (list "registry.redhat.io/" "registry.access.redhat.com/" "quay.io/") -}}
{{- if hasPrefix $host $ref -}}
{{- $ref = printf "%s/%s" $mirror (trimPrefix $host $ref) -}}
{{- end -}}
{{- end -}}
{{- printf "%s%s" $scheme $ref -}}
{{- else -}}
{{- $ref -}}
{{- end -}}
{{- end -}}

{{/*
=============================================================================
Governance coverage — used by validation and by the inventory ConfigMap
=============================================================================
Returns "true" when at least one enabled accessPolicy selects the given model.
*/}}
{{- define "maas-models.hasAccessPolicy" -}}
{{- $root := .root -}}
{{- $name := .model.name -}}
{{- $found := false -}}
{{- range $p := $root.Values.accessPolicies -}}
{{- if ne $p.enabled false -}}
{{- range $m := (include "maas-models.selectModels" (dict "root" $root "selector" $p.modelSelector) | fromJsonArray) -}}
{{- if eq $m.name $name -}}{{- $found = true -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}

{{/* Returns "true" when at least one enabled subscription selects the given model. */}}
{{- define "maas-models.hasSubscription" -}}
{{- $root := .root -}}
{{- $name := .model.name -}}
{{- $found := false -}}
{{- range $s := $root.Values.subscriptions -}}
{{- if ne $s.enabled false -}}
{{- range $m := (include "maas-models.selectModels" (dict "root" $root "selector" $s.modelSelector) | fromJsonArray) -}}
{{- if eq $m.name $name -}}{{- $found = true -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $found -}}
{{- end -}}
