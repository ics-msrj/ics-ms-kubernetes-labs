{{/*
Common labels applied to every object this chart creates.
*/}}
{{- define "online-boutique.labels" -}}
app.kubernetes.io/part-of: online-boutique
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end -}}

{{/*
Full image reference for a service name using the chart-wide registry/tag.
*/}}
{{- define "online-boutique.image" -}}
{{ .registry }}/{{ .name }}:{{ .tag }}
{{- end -}}
