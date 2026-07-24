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
{{/*
Everything below builds dicts and `toYaml`s them, rather than emitting YAML line
by line. Concatenating YAML fragments lets the same key be written twice — the
API server rejects that, but `yq` and `helm template` both accept it silently, so
the failure surfaces only at apply time. Merging dicts makes it impossible.
*/}}
{{- define "maas-models.labelsDict" -}}
{{- $l := dict
      "helm.sh/chart" (include "maas-models.chart" .)
      "app.kubernetes.io/name" (include "maas-models.name" .)
      "app.kubernetes.io/instance" .Release.Name
      "app.kubernetes.io/version" (.Chart.AppVersion | toString)
      "app.kubernetes.io/managed-by" .Release.Service
      "app.kubernetes.io/part-of" "models-as-a-service"
      "maas.pase52.io/environment" (.Values.environment | toString)
-}}
{{- merge $l (.Values.commonLabels | default dict) | toJson -}}
{{- end -}}

{{- define "maas-models.labels" -}}
{{- include "maas-models.labelsDict" . | fromJson | toYaml -}}
{{- end -}}

{{/*
Per-model labels. Adds the model identity and tier so a single label selector
answers "show me everything that makes up model X".
*/}}
{{- define "maas-models.modelLabelsDict" -}}
{{- $l := include "maas-models.labelsDict" .root | fromJson -}}
{{- $_ := set $l "app.kubernetes.io/component" .component -}}
{{- $_ := set $l "maas.pase52.io/model" (.model.name | toString) -}}
{{- $_ := set $l "maas.pase52.io/tier" (.model.tier | default "default" | toString) -}}
{{- $_ := set $l "maas.pase52.io/backend" (.model.backend | default "LLMInferenceService" | toString) -}}
{{- $l | toJson -}}
{{- end -}}

{{/*
=============================================================================
Argo CD annotations
=============================================================================
`syncOptions` lets a caller add resource-specific options (e.g. Prune=false on a
PVC) that are merged into the single sync-options annotation rather than
emitting a second one.
Usage: include "maas-models.argoAnnotationsDict" (dict "root" $ "wave" "modelRef" "syncOptions" (list "Prune=false"))
*/}}
{{- define "maas-models.argoAnnotationsDict" -}}
{{- $root := .root -}}
{{- $argo := $root.Values.argocd | default dict -}}
{{- $ann := dict -}}
{{- if $argo.enabled -}}
{{- $_ := set $ann "argocd.argoproj.io/sync-wave" (get ($argo.syncWaves | default dict) .wave | default "0" | toString) -}}
{{- $opts := concat ($argo.syncOptions | default list) (.syncOptions | default list) | uniq -}}
{{- if $opts -}}
{{- $_ := set $ann "argocd.argoproj.io/sync-options" (join "," $opts) -}}
{{- end -}}
{{- with $argo.compareOptions -}}
{{- $_ := set $ann "argocd.argoproj.io/compare-options" . -}}
{{- end -}}
{{- else -}}
{{/* Sync waves off, but a resource-specific option still has to be honoured. */}}
{{- with .syncOptions -}}
{{- $_ := set $ann "argocd.argoproj.io/sync-options" (join "," (. | uniq)) -}}
{{- end -}}
{{- end -}}
{{- $ann | toJson -}}
{{- end -}}

{{/*
Common metadata block: labels + argo annotations + user annotations.
Later sources win on conflict, so a caller can deliberately override a default.
Usage: include "maas-models.metadata" (dict "root" $ "model" $m "component" "x" "wave" "workload" "annotations" $extra "syncOptions" (list "Prune=false"))
*/}}
{{- define "maas-models.metadata" -}}
{{- $labels := dict -}}
{{- if .model -}}
{{- $labels = include "maas-models.modelLabelsDict" (dict "root" .root "model" .model "component" .component) | fromJson -}}
{{- else -}}
{{- $labels = include "maas-models.labelsDict" .root | fromJson -}}
{{- $_ := set $labels "app.kubernetes.io/component" .component -}}
{{- end -}}
{{- $labels = merge (deepCopy (.extraLabels | default dict)) $labels -}}
{{- $ann := include "maas-models.argoAnnotationsDict" (dict "root" .root "wave" .wave "syncOptions" .syncOptions) | fromJson -}}
{{- $ann = mergeOverwrite $ann (deepCopy (.root.Values.commonAnnotations | default dict)) (deepCopy (.annotations | default dict)) -}}
labels:
  {{- toYaml $labels | nindent 2 }}
annotations:
  {{- toYaml $ann | nindent 2 }}
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
The volume name KServe uses for the model directory. Declaring a volume with
this exact name in spec.template.volumes makes AddModelMount skip creating its
default emptyDir and use ours instead — that check is how a PVC is substituted.
Changing this string silently reverts every model to node ephemeral storage.
*/}}
{{- define "maas-models.provisionVolumeName" -}}
kserve-provision-location
{{- end -}}

{{/*
Effective persistence settings for a model: per-model over modelDefaults.
Returns JSON; "{}"-equivalent when disabled.
*/}}
{{- define "maas-models.persistence" -}}
{{- $d := (.root.Values.modelDefaults | default dict).persistence | default dict -}}
{{- $m := ((.model.inference | default dict).persistence | default dict) -}}
{{- mergeOverwrite (deepCopy $d) $m | toJson -}}
{{- end -}}

{{/* Name of the PVC backing a model's weights. */}}
{{- define "maas-models.pvcName" -}}
{{- $p := (include "maas-models.persistence" (dict "root" .root "model" .model) | fromJson) -}}
{{- $p.existingClaim | default (printf "maas-model-%s" .model.name) -}}
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
