{{- define "amq.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "amq.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "amq.selectorLabels" -}}
app.kubernetes.io/name: {{ include "amq.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "amq.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{ include "amq.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: alfresco
{{- end -}}

{{- define "amq.secretName" -}}
{{- default (include "amq.fullname" .) .Values.auth.existingSecret.name -}}
{{- end -}}

{{- define "amq.claimName" -}}
{{- default (printf "%s-store" (include "amq.fullname" .)) .Values.persistence.sharedVolume.existingClaim -}}
{{- end -}}

{{- define "amq.serviceFQDN" -}}
{{- printf "%s.%s.svc.%s" (include "amq.fullname" .) .Release.Namespace .Values.clusterDomain -}}
{{- end -}}

{{/* failover URL for Alfresco components (OpenWire) */}}
{{- define "amq.brokerUrl" -}}
{{- $c := .Values.alfrescoConnection -}}
{{- printf "failover:(%s://%s:%d)?%s" $c.scheme (include "amq.serviceFQDN" .) (.Values.broker.transports.openwire.port | int) $c.urlOptions -}}
{{- end -}}

{{- define "amq.validate" -}}
{{- if not (has .Values.persistence.mode (list "sharedVolume" "jdbc")) -}}
{{- fail "persistence.mode must be sharedVolume or jdbc" -}}
{{- end -}}
{{- if and (eq .Values.persistence.mode "jdbc") (not .Values.persistence.jdbc.url) -}}
{{- fail "persistence.jdbc.url is required when persistence.mode=jdbc" -}}
{{- end -}}
{{- if and (eq .Values.persistence.mode "jdbc") (not .Values.persistence.jdbc.existingSecret.name) -}}
{{- fail "persistence.jdbc.existingSecret.name is required when persistence.mode=jdbc" -}}
{{- end -}}
{{- if not .Values.broker.transports.openwire.enabled -}}
{{- fail "broker.transports.openwire must stay enabled (Alfresco and the readiness probe use it)" -}}
{{- end -}}
{{- end -}}
