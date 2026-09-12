{{- define "infegate.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "infegate.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}{{ .Release.Name | trunc 63 | trimSuffix "-" }}{{ else }}{{ printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}{{ end }}
{{- end }}
{{- end }}

{{- define "infegate.componentName" -}}
{{- printf "%s-%s" (include "infegate.fullname" .root) .component | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "infegate.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | quote }}
app.kubernetes.io/name: {{ include "infegate.name" . | quote }}
app.kubernetes.io/instance: {{ .Release.Name | quote }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service | quote }}
{{- end }}

{{- define "infegate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "infegate.name" .root | quote }}
app.kubernetes.io/instance: {{ .root.Release.Name | quote }}
app.kubernetes.io/component: {{ .component | quote }}
{{- end }}

{{- define "infegate.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}{{ default (include "infegate.fullname" .) .Values.serviceAccount.name }}{{ else }}{{ default "default" .Values.serviceAccount.name }}{{ end }}
{{- end }}

{{- define "infegate.image" -}}
{{- if .image.digest }}{{ printf "%s@%s" .image.repository .image.digest }}{{ else }}{{ printf "%s:%s" .image.repository .image.tag }}{{ end }}
{{- end }}

{{- define "infegate.validate" -}}
{{- $publicUrl := required "publicUrl is required" .Values.publicUrl }}
{{- if not (regexMatch `^https://[^/?#]+$` $publicUrl) }}{{ fail "publicUrl must be an HTTPS origin without a path, query, or fragment" }}{{ end }}
{{- $publicUrlParts := urlParse $publicUrl }}
{{- $publicUrlHost := get $publicUrlParts "host" }}
{{- $publicUrlHostname := get $publicUrlParts "hostname" }}
{{- $_ := required "api.database.existingSecret is required" .Values.api.database.existingSecret }}
{{- if eq .Values.api.management.authenticationMode "oidc" }}
{{- $_ = required "api.oidc.issuer is required" .Values.api.oidc.issuer }}
{{- $_ = required "api.oidc.clientId is required" .Values.api.oidc.clientId }}
{{- $_ = required "api.oidc.existingSecret is required" .Values.api.oidc.existingSecret }}
{{- $_ = required "api.oidc.authorizationRule is required" .Values.api.oidc.authorizationRule }}
{{- else if eq .Values.api.management.authenticationMode "externalJwt" }}
{{- $_ = required "api.management.externalJwt.issuer is required when management uses external JWT" .Values.api.management.externalJwt.issuer }}
{{- if not .Values.api.management.externalJwt.audiences }}{{ fail "api.management.externalJwt.audiences must contain at least one audience when management uses external JWT" }}{{ end }}
{{- $_ = required "api.management.externalJwt.jwksUrl is required when management uses external JWT" .Values.api.management.externalJwt.jwksUrl }}
{{- $_ = required "api.management.externalJwt.headerName is required when management uses external JWT" .Values.api.management.externalJwt.headerName }}
{{- $_ = required "api.management.externalJwt.authorizationRule is required when management uses external JWT" .Values.api.management.externalJwt.authorizationRule }}
{{- end }}
{{- $_ = required "api.runtime.existingSecret is required" .Values.api.runtime.existingSecret }}
{{- if eq .Values.api.audit.capturePayloads nil }}{{ fail "api.audit.capturePayloads must be explicitly true or false" }}{{ end }}
{{- if and .Values.api.metrics.enabled (has (int .Values.api.metrics.port) (list 3000 3001 3002 4000 15021)) }}{{ fail "api.metrics.port conflicts with a reserved Infegate listener port" }}{{ end }}
{{- if gt (int .Values.api.autoscaling.minReplicas) (int .Values.api.autoscaling.maxReplicas) }}{{ fail "api.autoscaling.minReplicas must not exceed maxReplicas" }}{{ end }}
{{- if and .Values.api.autoscaling.enabled (not (or .Values.api.autoscaling.targetCPUUtilizationPercentage .Values.api.autoscaling.targetMemoryUtilizationPercentage)) }}{{ fail "api.autoscaling requires at least one utilization target" }}{{ end }}
{{- if gt (int .Values.ui.autoscaling.minReplicas) (int .Values.ui.autoscaling.maxReplicas) }}{{ fail "ui.autoscaling.minReplicas must not exceed maxReplicas" }}{{ end }}
{{- if and .Values.ui.autoscaling.enabled (not (or .Values.ui.autoscaling.targetCPUUtilizationPercentage .Values.ui.autoscaling.targetMemoryUtilizationPercentage)) }}{{ fail "ui.autoscaling requires at least one utilization target" }}{{ end }}
{{- if .Values.api.mcp.enabled }}
{{- if eq .Values.api.mcp.authenticationMode "nativeOAuth" }}
{{- $_ = required "api.oidc.issuer is required when MCP uses native OAuth" .Values.api.oidc.issuer }}
{{- else if eq .Values.api.mcp.authenticationMode "externalJwt" }}
{{- $_ = required "api.mcp.issuer is required when MCP uses external JWT" .Values.api.mcp.issuer }}
{{- $_ = required "api.mcp.headerName is required when MCP uses external JWT" .Values.api.mcp.headerName }}
{{- end }}
{{- $_ = required "api.mcp.jwksUrl is required when MCP is enabled" .Values.api.mcp.jwksUrl }}
{{- if not .Values.api.mcp.audiences }}{{ fail "api.mcp.audiences must contain at least one audience when MCP is enabled" }}{{ end }}
{{- $_ = required "api.mcp.authorizationRule is required when MCP is enabled" .Values.api.mcp.authorizationRule }}
{{- end }}
{{- if .Values.api.audit.retention.enabled }}
{{- if le (int .Values.api.audit.retention.payloadDays) 0 }}{{ fail "api.audit.retention.payloadDays must be greater than zero" }}{{ end }}
{{- if le (int .Values.api.audit.retention.metadataDays) (int .Values.api.audit.retention.payloadDays) }}{{ fail "api.audit.retention.metadataDays must be greater than payloadDays" }}{{ end }}
{{- end }}
{{- if eq .Values.api.management.authenticationMode "oidc" }}
{{- if or (eq .Values.api.database.existingSecret .Values.api.oidc.existingSecret) (eq .Values.api.database.existingSecret .Values.api.runtime.existingSecret) (eq .Values.api.oidc.existingSecret .Values.api.runtime.existingSecret) }}{{ fail "database, OIDC, and runtime Secret names must be distinct" }}{{ end }}
{{- else if eq .Values.api.database.existingSecret .Values.api.runtime.existingSecret }}{{ fail "database and runtime Secret names must be distinct" }}
{{- end }}
{{- if and .Values.ingress.enabled .Values.gateway.enabled }}{{ fail "ingress.enabled and gateway.enabled cannot both be true" }}{{ end }}
{{- if .Values.ingress.enabled }}{{ $_ = required "ingress.tls.existingSecret is required when ingress is enabled" .Values.ingress.tls.existingSecret }}{{ end }}
{{- if .Values.gateway.enabled }}
{{- if not (regexMatch `^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)*$` $publicUrlHostname) }}{{ fail "publicUrl hostname must be a valid Gateway API hostname" }}{{ end }}
{{- if .Values.gateway.create }}
{{- $publicUrlPort := regexFind `:[0-9]+$` $publicUrlHost }}
{{- if and $publicUrlPort (ne $publicUrlPort ":443") }}{{ fail "publicUrl port must be 443 when creating a Gateway" }}{{ end }}
{{- $_ = required "gateway.gatewayClassName is required when creating a Gateway" .Values.gateway.gatewayClassName }}
{{- $_ = required "gateway.tls.existingSecret is required when creating a Gateway" .Values.gateway.tls.existingSecret }}
{{- else }}
{{- $_ = required "gateway.parentRef.name is required when using an existing Gateway" .Values.gateway.parentRef.name }}
{{- end }}
{{- end }}
{{- end }}

{{- define "infegate.host" -}}
{{- get (urlParse .Values.publicUrl) "hostname" }}
{{- end }}

{{- define "infegate.httpRouteRule" -}}
- matches:
    - path:
        type: {{ .type | quote }}
        value: {{ .path | quote }}
  backendRefs:
    - group: ""
      kind: Service
      name: {{ include "infegate.componentName" (dict "root" .root "component" .component) | quote }}
      port: {{ .port }}
      weight: 1
{{- end }}
