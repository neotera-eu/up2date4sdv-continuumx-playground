#!/bin/bash
# Patch edgecore.yaml for this playground.
#
# You may change:
# - mqttServerExternal (MQTT broker address)
# - mqttMode (2 = external broker only)
# - serviceBus server/port (HTTP target on the edge, default 127.0.0.1:3000 via rules)

cfg=/etc/kubeedge/config/edgecore.yaml
[[ -f "$cfg" ]] || return 0 2>/dev/null || exit 0

# Rootless Podman runs this node inside a user namespace, and the host has
# swap. The generated kubelet config refuses both unless it is patched in
# place. A second featureGates block would be overwritten by the one kubeedge
# already writes, so the gate has to be added to that block.
awk '
  function indent_of(line,    n) {
    match(line, /^[[:space:]]*/)
    return RLENGTH
  }
  function leave_kubelet(    pad) {
    if (!in_kubelet) return
    if (in_gates && !saw_gate) {
      printf "%*sKubeletInUserNamespace: true\n", gates_indent + 2, ""
      saw_gate = 1
      in_gates = 0
    }
    if (!saw_enforce) {
      pad = tk_indent + 2
      printf "%*senforceNodeAllocatable: []\n", pad, ""
      saw_enforce = 1
    }
    if (!saw_fail) {
      pad = tk_indent + 2
      printf "%*sfailSwapOn: false\n", pad, ""
      saw_fail = 1
    }
    if (!saw_gate) {
      pad = tk_indent + 2
      printf "%*sfeatureGates:\n", pad, ""
      printf "%*sKubeletInUserNamespace: true\n", pad + 2, ""
      saw_gate = 1
    }
    in_kubelet = 0
  }
  {
    if (skip_list) {
      if ($0 ~ /^[[:space:]]*-/) {
        next
      }
      skip_list = 0
    }

    if ($0 ~ /^[[:space:]]*tailoredKubeletConfig:[[:space:]]*$/) {
      in_kubelet = 1
      tk_indent = indent_of($0)
      print
      next
    }

    if (in_gates && $0 ~ /^[[:space:]]*[A-Za-z0-9_]+:/) {
      if (indent_of($0) <= gates_indent) {
        if (!saw_gate) {
          printf "%*sKubeletInUserNamespace: true\n", gates_indent + 2, ""
          saw_gate = 1
        }
        in_gates = 0
      }
    }

    if (in_kubelet && $0 ~ /^[[:space:]]*[A-Za-z0-9_]+:/) {
      if (indent_of($0) <= tk_indent) leave_kubelet()
    }

    if (in_servicebus && $0 ~ /^[[:space:]]*[A-Za-z0-9_]+:/) {
      if (indent_of($0) <= sb_indent) in_servicebus = 0
    }

    if ($0 ~ /^[[:space:]]*serviceBus:[[:space:]]*$/) {
      in_servicebus = 1
      sb_indent = indent_of($0)
      print
      next
    }

    if (in_kubelet && $0 ~ /^[[:space:]]*enforceNodeAllocatable:/) {
      printf "%*senforceNodeAllocatable: []\n", indent_of($0), ""
      saw_enforce = 1
      skip_list = 1
      next
    }
    if (in_kubelet && $0 ~ /failSwapOn:/) {
      sub(/true/, "false")
      saw_fail = 1
    }
    if (in_kubelet && $0 ~ /oomScoreAdj:/) {
      sub(/-999/, "0")
    }
    if (in_kubelet && $0 ~ /KubeletInUserNamespace:/) saw_gate = 1
    if (in_kubelet && $0 ~ /^[[:space:]]*featureGates:[[:space:]]*$/) {
      in_gates = 1
      gates_indent = indent_of($0)
      print
      next
    }

    if (in_servicebus && $0 ~ /^[[:space:]]*enable:/) sub(/enable:.*/, "enable: true")
    if (in_servicebus && $0 ~ /^[[:space:]]*port:/) sub(/port:.*/, "port: 9060")
    if (in_servicebus && $0 ~ /^[[:space:]]*server:/) sub(/server:.*/, "server: 127.0.0.1")
    if (in_servicebus && $0 ~ /^[[:space:]]*timeout:/) sub(/timeout:.*/, "timeout: 60")

    if ($0 ~ /^([[:space:]]*)mqttMode:/) {
      sub(/mqttMode:.*/, "mqttMode: 2")
    }
    if ($0 ~ /^([[:space:]]*)mqttServerExternal:/) {
      sub(/mqttServerExternal:.*/, "mqttServerExternal: tcp://mqtt-broker:1883")
    }

    print
  }
  END { leave_kubelet() }
' "$cfg" > "${cfg}.tmp"
mv "${cfg}.tmp" "$cfg"

grep -q 'KubeletInUserNamespace: true' "$cfg"
grep -q 'failSwapOn: false' "$cfg"
grep -q 'mqttMode: 2' "$cfg"
grep -q 'mqttServerExternal: tcp://mqtt-broker:1883' "$cfg"
grep -q 'enforceNodeAllocatable: \[\]' "$cfg"
