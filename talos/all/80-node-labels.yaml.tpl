{{- if .Node.Data.mediaNode }}
machine:
  nodeLabels:
    media-node: "true"
{{- end }}
