{{- if index .Node.Data "kernelModules" }}
machine:
  kernel:
    modules:
      {{- range index .Node.Data "kernelModules" }}
      - name: {{ . }}
      {{- end }}
{{- end }}
