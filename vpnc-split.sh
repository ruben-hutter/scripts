#!/usr/bin/env bash
# vpnc-script wrapper that FORCES split tunneling.
#
# Delegates all interface/DNS/MTU setup to the stock /etc/vpnc/vpnc-script,
# but injects CISCO_SPLIT_INC so it takes its native split path: it installs
# ONLY the subnets listed below via the tunnel and NEVER installs a default
# route. Tailscale, Docker, and your normal internet stay on the local
# network while the FHNW VPN is up.
#
# To add more FHNW ranges, append to SPLITS as "ADDR MASK MASKLEN".

REAL=/etc/vpnc/vpnc-script

SPLITS=(
  "10.0.0.0 255.0.0.0 8"        # FHNW private (VMs, DNS 10.51.x, internal services)
  "147.86.0.0 255.255.0.0 16"   # FHNW public range (gateway 147.86.3.240 has its own host route via local)
)

# Hostnames whose traffic should also egress via the VPN.
# Resolved to /32 host routes at connect time, so only these exact public IPs
# use the tunnel (everything else stays local). Add/remove as needed.
OPENCODE_HOSTS=(
  llm.cybersec-fhnw.org   # opencode GLM model endpoint
  api.z.ai                # opencode MCP servers (web search / reader / zread)
)

# Drop any split-inc the server pushed, then inject our own.
for v in "${!CISCO_SPLIT_INC@}"; do unset "$v"; done

i=0
for entry in "${SPLITS[@]}"; do
  read -r addr mask masklen <<< "$entry"
  export "CISCO_SPLIT_INC_${i}_ADDR=$addr"
  export "CISCO_SPLIT_INC_${i}_MASK=$mask"
  export "CISCO_SPLIT_INC_${i}_MASKLEN=$masklen"
  i=$((i + 1))
done
export CISCO_SPLIT_INC=$i

# Run the stock script (interface, split subnets, DNS). Don't exec — we add
# host routes for OPENCODE_HOSTS after, on connect.
"$REAL" "$@"
rc=$?

if [ "${reason:-}" = "connect" ] && [ -n "${TUNDEV:-}" ]; then
  for host in "${OPENCODE_HOSTS[@]}"; do
    for ip in $(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}' | sort -u); do
      if ip route replace "$ip/32" dev "$TUNDEV" 2>/dev/null; then
        echo "[vpnc-split] $host -> $ip via $TUNDEV" >&2
      fi
    done
  done
fi

exit $rc
