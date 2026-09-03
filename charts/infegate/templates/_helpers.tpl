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
app.kubernetes.io/name: {{ include "infegate.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{- define "infegate.selectorLabels" -}}
app.kubernetes.io/name: {{ include "infegate.name" .root }}
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .component }}
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
{{- $_ := required "api.database.existingSecret is required" .Values.api.database.existingSecret }}
{{- $_ = required "api.oidc.issuer is required" .Values.api.oidc.issuer }}
{{- $_ = required "api.oidc.clientId is required" .Values.api.oidc.clientId }}
{{- $_ = required "api.oidc.existingSecret is required" .Values.api.oidc.existingSecret }}
{{- $_ = required "api.oidc.authorizationRule is required" .Values.api.oidc.authorizationRule }}
{{- $_ = required "api.runtime.existingSecret is required" .Values.api.runtime.existingSecret }}
{{- if eq .Values.api.audit.capturePayloads nil }}{{ fail "api.audit.capturePayloads must be explicitly true or false" }}{{ end }}
{{- if .Values.api.mcp.enabled }}
{{- $_ = required "api.mcp.jwksUrl is required when MCP is enabled" .Values.api.mcp.jwksUrl }}
{{- if not .Values.api.mcp.audiences }}{{ fail "api.mcp.audiences must contain at least one audience when MCP is enabled" }}{{ end }}
{{- $_ = required "api.mcp.authorizationRule is required when MCP is enabled" .Values.api.mcp.authorizationRule }}
{{- end }}
{{- if or (eq .Values.api.database.existingSecret .Values.api.oidc.existingSecret) (eq .Values.api.database.existingSecret .Values.api.runtime.existingSecret) (eq .Values.api.oidc.existingSecret .Values.api.runtime.existingSecret) }}{{ fail "database, OIDC, and runtime Secret names must be distinct" }}{{ end }}
{{- if .Values.ingress.enabled }}{{ $_ = required "ingress.tls.existingSecret is required when ingress is enabled" .Values.ingress.tls.existingSecret }}{{ end }}
{{- end }}

{{- define "infegate.host" -}}
{{- regexReplaceAll `^https://` .Values.publicUrl "" }}
{{- end }}
