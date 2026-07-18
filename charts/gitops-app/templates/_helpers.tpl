{{/*
Expand the name of the chart.
*/}}
{{- define "gitops-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "gitops-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- printf "%s" $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Common labels - applied to all resources for consistent selection.
*/}}
{{- define "gitops-app.labels" -}}
helm.sh/chart: {{ include "gitops-app.name" . }}-{{ .Chart.Version | replace "+" "_" }}
{{ include "gitops-app.selectorLabels" . }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}

{{/*
Selector labels - used in matchLabels and pod template labels.
Must be IMMUTABLE after first deploy (changing them breaks the Deployment).
*/}}
{{- define "gitops-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gitops-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}