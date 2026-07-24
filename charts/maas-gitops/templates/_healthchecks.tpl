{{/*
=============================================================================
Argo CD custom health checks (Lua) for the MaaS CRDs
=============================================================================
Contract: the script receives the live object as `obj` and returns a table with
`status` (Healthy | Progressing | Degraded | Suspended | Missing | Unknown) and
a human-readable `message`.

Design rule applied throughout: report Progressing only for states that resolve
on their own (a model loading, a controller yet to reconcile). A state that
needs a human — missing governance, an invalid spec, a failed runtime — is
Degraded, so it surfaces in the Argo CD UI instead of spinning forever.
*/}}

{{/* --------------------------------------------------------------------- */}}
{{- define "maas-gitops.health.maasModelRef" -}}
local hs = {}

-- Not yet reconciled by maas-controller.
if obj.status == nil or obj.status.phase == nil or obj.status.phase == "" then
  hs.status = "Progressing"
  hs.message = "Waiting for maas-controller to reconcile"
  return hs
end

local runtimeStatus, runtimeReason, runtimeMsg = "Unknown", "", ""
local govStatus, govReason, govMsg = "Unknown", "", ""
local readyMsg = ""

if obj.status.conditions ~= nil then
  for _, c in ipairs(obj.status.conditions) do
    if c.type == "RuntimeReady" then
      runtimeStatus = c.status or "Unknown"
      runtimeReason = c.reason or ""
      runtimeMsg = c.message or ""
    elseif c.type == "GovernanceAttached" then
      govStatus = c.status or "Unknown"
      govReason = c.reason or ""
      govMsg = c.message or ""
    elseif c.type == "Ready" then
      readyMsg = c.message or ""
    end
  end
end

local phase = obj.status.phase

if phase == "Ready" then
  hs.status = "Healthy"
  if obj.status.endpoint ~= nil and obj.status.endpoint ~= "" then
    hs.message = "Serving at " .. obj.status.endpoint
  else
    hs.message = "Ready"
  end
  return hs
end

-- Governance attached, runtime broken. Callers are being refused right now.
if phase == "Unhealthy" then
  hs.status = "Degraded"
  local m = "Backend runtime failing"
  if runtimeMsg ~= "" then
    m = m .. ": " .. runtimeMsg
  elseif runtimeReason ~= "" then
    m = m .. " (" .. runtimeReason .. ")"
  end
  hs.message = m
  return hs
end

if phase == "Failed" then
  hs.status = "Degraded"
  hs.message = "Reconciliation failed" .. (readyMsg ~= "" and (": " .. readyMsg) or "")
  return hs
end

if phase == "Invalid" then
  hs.status = "Degraded"
  hs.message = "Invalid spec" .. (readyMsg ~= "" and (": " .. readyMsg) or "")
  return hs
end

-- phase == Pending. Distinguish "still starting" from "misconfigured".
-- A missing MaaSAuthPolicy/MaaSSubscription pair never resolves on its own,
-- so it is Degraded, not Progressing.
if govStatus == "False" and (govReason == "NoPairingFound" or govReason == "GovernanceGap") then
  hs.status = "Degraded"
  local m = "No active MaaSAuthPolicy + MaaSSubscription pair covers this model, so every request is denied"
  if govMsg ~= "" then m = m .. ": " .. govMsg end
  hs.message = m
  return hs
end

if runtimeStatus == "False" and runtimeReason == "RuntimeHealthFailure" then
  hs.status = "Degraded"
  hs.message = "Backend runtime unhealthy" .. (runtimeMsg ~= "" and (": " .. runtimeMsg) or "")
  return hs
end

hs.status = "Progressing"
hs.message = "Pending (runtime=" .. runtimeStatus .. ", governance=" .. govStatus .. ")"
return hs
{{- end -}}

{{/* --------------------------------------------------------------------- */}}
{{- define "maas-gitops.health.maasAuthPolicy" -}}
local hs = {}

if obj.status == nil or obj.status.phase == nil or obj.status.phase == "" then
  hs.status = "Progressing"
  hs.message = "Waiting for maas-controller to reconcile"
  return hs
end

local phase = obj.status.phase

-- Count the underlying Kuadrant AuthPolicies that are not healthy, and name
-- the first one — "2 of 5 unhealthy" is far more actionable than "Degraded".
local total, bad, firstBad = 0, 0, ""
if obj.status.authPolicies ~= nil then
  for _, ap in ipairs(obj.status.authPolicies) do
    total = total + 1
    if ap.ready ~= true then
      bad = bad + 1
      if firstBad == "" then
        firstBad = (ap.model or ap.name or "unknown")
        if ap.message ~= nil and ap.message ~= "" then
          firstBad = firstBad .. " (" .. ap.message .. ")"
        end
      end
    end
  end
end

if phase == "Active" then
  hs.status = "Healthy"
  hs.message = "Access policy enforced on " .. tostring(total) .. " model(s)"
  return hs
end

if phase == "Degraded" then
  hs.status = "Degraded"
  hs.message = tostring(bad) .. " of " .. tostring(total) .. " AuthPolicies unhealthy: " .. firstBad
  return hs
end

if phase == "Failed" then
  hs.status = "Degraded"
  hs.message = "AuthPolicy reconciliation failed" .. (firstBad ~= "" and (": " .. firstBad) or "")
  return hs
end

if phase == "Invalid" then
  hs.status = "Degraded"
  hs.message = "Invalid spec: check modelRefs and subjects"
  return hs
end

hs.status = "Progressing"
hs.message = "Pending: waiting for referenced MaaSModelRefs"
return hs
{{- end -}}

{{/* --------------------------------------------------------------------- */}}
{{- define "maas-gitops.health.maasSubscription" -}}
local hs = {}

if obj.status == nil or obj.status.phase == nil or obj.status.phase == "" then
  hs.status = "Progressing"
  hs.message = "Waiting for maas-controller to reconcile"
  return hs
end

local phase = obj.status.phase

local models, badModels, firstBad = 0, 0, ""
if obj.status.modelRefStatuses ~= nil then
  for _, m in ipairs(obj.status.modelRefStatuses) do
    models = models + 1
    if m.ready ~= true then
      badModels = badModels + 1
      if firstBad == "" then firstBad = (m.name or "unknown") end
    end
  end
end

local limits, badLimits = 0, 0
if obj.status.tokenRateLimitStatuses ~= nil then
  for _, t in ipairs(obj.status.tokenRateLimitStatuses) do
    limits = limits + 1
    if t.ready ~= true then badLimits = badLimits + 1 end
  end
end

if phase == "Active" then
  hs.status = "Healthy"
  hs.message = "Quotas enforced on " .. tostring(models) .. " model(s), "
    .. tostring(limits) .. " TokenRateLimitPolicy(ies)"
  return hs
end

if phase == "Degraded" then
  hs.status = "Degraded"
  -- Token limits that are not enforced mean the quota is not actually capping
  -- anything — worth calling out explicitly rather than a generic "degraded".
  local m = "Quota partially enforced: " .. tostring(badModels) .. "/" .. tostring(models)
    .. " models and " .. tostring(badLimits) .. "/" .. tostring(limits) .. " rate limits unhealthy"
  if firstBad ~= "" then m = m .. " (first: " .. firstBad .. ")" end
  hs.message = m
  return hs
end

if phase == "Failed" then
  hs.status = "Degraded"
  hs.message = "Subscription reconciliation failed — token limits may not be enforced"
  return hs
end

if phase == "Invalid" then
  hs.status = "Degraded"
  hs.message = "Invalid spec: check modelRefs, owner and tokenRateLimits windows (s|m|h only)"
  return hs
end

hs.status = "Progressing"
hs.message = "Pending: waiting for referenced MaaSModelRefs"
return hs
{{- end -}}

{{/* --------------------------------------------------------------------- */}}
{{- define "maas-gitops.health.externalModel" -}}
local hs = {}

if obj.status == nil or obj.status.phase == nil or obj.status.phase == "" then
  hs.status = "Progressing"
  hs.message = "Waiting for maas-controller to reconcile"
  return hs
end

local detail = ""
if obj.status.conditions ~= nil then
  for _, c in ipairs(obj.status.conditions) do
    if c.type == "Ready" and c.message ~= nil and c.message ~= "" then
      detail = c.message
    end
  end
end

local target = ""
if obj.spec ~= nil then
  target = (obj.spec.provider or "") .. "/" .. (obj.spec.targetModel or "")
end

if obj.status.phase == "Ready" then
  hs.status = "Healthy"
  hs.message = "External model reachable: " .. target
  return hs
end

if obj.status.phase == "Failed" then
  hs.status = "Degraded"
  -- Nearly always the credential Secret or the ServiceEntry/DestinationRule.
  hs.message = "External model failed: " .. (detail ~= "" and detail or ("check credentialRef Secret and egress to " .. ((obj.spec or {}).endpoint or "the provider")))
  return hs
end

hs.status = "Progressing"
hs.message = "Pending: " .. (detail ~= "" and detail or "resolving provider endpoint")
return hs
{{- end -}}

{{/* --------------------------------------------------------------------- */}}
{{/*
LLMInferenceService uses Knative-style conditions: a top-level Ready condition
aggregating the sub-conditions. Surfacing the failing sub-condition by name is
what turns "not ready" into something actionable.
*/}}
{{- define "maas-gitops.health.llmInferenceService" -}}
local hs = {}

if obj.status == nil or obj.status.conditions == nil then
  hs.status = "Progressing"
  hs.message = "Waiting for KServe to reconcile"
  return hs
end

local ready = nil
local firstFailure = ""

for _, c in ipairs(obj.status.conditions) do
  if c.type == "Ready" then
    ready = c
  elseif c.status == "False" and firstFailure == "" then
    firstFailure = c.type .. "=False"
    if c.reason ~= nil and c.reason ~= "" then
      firstFailure = firstFailure .. " (" .. c.reason .. ")"
    end
  end
end

if ready == nil then
  hs.status = "Progressing"
  hs.message = "No Ready condition reported yet"
  return hs
end

if ready.status == "True" then
  hs.status = "Healthy"
  local url = obj.status.url or ""
  hs.message = url ~= "" and ("Serving at " .. url) or "Model serving"
  return hs
end

if ready.status == "False" then
  -- Distinguish a model still loading from one that will not start.
  -- Image pull and scheduling failures do not clear without intervention.
  local reason = ready.reason or ""
  local msg = ready.message or firstFailure
  if reason == "RevisionFailed" or reason == "ContainerUnhealthy"
     or reason == "ImagePullBackOff" or reason == "ErrImagePull"
     or reason == "Unschedulable" or reason == "CrashLoopBackOff" then
    hs.status = "Degraded"
    hs.message = "Model will not start (" .. reason .. "): " .. msg
    return hs
  end
  hs.status = "Progressing"
  hs.message = "Model not ready yet: " .. (msg ~= "" and msg or reason)
  return hs
end

hs.status = "Progressing"
hs.message = "Readiness unknown: " .. (ready.message or "")
return hs
{{- end -}}

{{/* --------------------------------------------------------------------- */}}
{{/*
The resourceHealthChecks list, in the shape the ArgoCD CR expects. Reused by
both delivery paths so they can never drift apart.
*/}}
{{- define "maas-gitops.resourceHealthChecks" -}}
{{- $k := .Values.healthChecks.kinds -}}
{{- if $k.maasModelRef }}
- group: maas.opendatahub.io
  kind: MaaSModelRef
  check: |
    {{- include "maas-gitops.health.maasModelRef" . | nindent 4 }}
{{- end }}
{{- if $k.maasAuthPolicy }}
- group: maas.opendatahub.io
  kind: MaaSAuthPolicy
  check: |
    {{- include "maas-gitops.health.maasAuthPolicy" . | nindent 4 }}
{{- end }}
{{- if $k.maasSubscription }}
- group: maas.opendatahub.io
  kind: MaaSSubscription
  check: |
    {{- include "maas-gitops.health.maasSubscription" . | nindent 4 }}
{{- end }}
{{- if $k.externalModel }}
- group: maas.opendatahub.io
  kind: ExternalModel
  check: |
    {{- include "maas-gitops.health.externalModel" . | nindent 4 }}
{{- end }}
{{- if $k.llmInferenceService }}
- group: serving.kserve.io
  kind: LLMInferenceService
  check: |
    {{- include "maas-gitops.health.llmInferenceService" . | nindent 4 }}
{{- end }}
{{- end -}}
