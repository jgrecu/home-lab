machine:
  network:
    interfaces:
      - deviceSelector:
          hardwareAddr: "{{ .Node.Data.macAddr }}"
        dhcp: false
        addresses:
          - "{{ .Node.IP }}/{{ .Data.nodeCidrPrefix }}"
        routes:
          - gateway: "{{ .Data.nodeGateway }}"
            network: 0.0.0.0/0
        mtu: {{ .Node.Data.mtu }}
        {{- if eq .Node.Role "control-plane" }}
        vip:
          ip: "{{ .Data.clusterApiAddr }}"
        {{- end }}
