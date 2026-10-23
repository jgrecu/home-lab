---
apiVersion: v1alpha1
kind: LinkAliasConfig
name: ethSel0
selector:
  match: glob("{{ .Node.Data.macAddr }}", mac(link.hardware_addr))
---
apiVersion: v1alpha1
kind: LinkConfig
name: ethSel0
addresses:
  - address: {{ .Node.IP }}/{{ .Data.nodeCidrPrefix }}
mtu: {{ .Node.Data.mtu }}
routes:
  - gateway: {{ .Data.nodeGateway }}
{{- if eq .Node.Role "control-plane" }}
---
apiVersion: v1alpha1
kind: Layer2VIPConfig
link: ethSel0
name: {{ .Data.clusterApiAddr }}
{{- end }}
