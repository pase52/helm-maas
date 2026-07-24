{{- define "maas-gitops.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "maas-gitops.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "maas-gitops.labels" -}}
helm.sh/chart: {{ include "maas-gitops.chart" . }}
app.kubernetes.io/name: {{ include "maas-gitops.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: models-as-a-service
{{- end -}}

{{/*
Merge an application entry over applicationDefaults.
`merge` is shallow-per-key with deep behaviour on maps, and the override wins.
Booleans set to false in an override are preserved because they are explicit
keys, not absent ones.
*/}}
{{- define "maas-gitops.appConfig" -}}
{{- $defaults := deepCopy .root.Values.applicationDefaults -}}
{{- $app := deepCopy .app -}}
{{- mergeOverwrite $defaults $app | toJson -}}
{{- end -}}
