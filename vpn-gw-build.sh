#!/usr/bin/env bash
# ============================================================
#  vpn-gw-build.sh — builds vmbr1 + the vpn-gw NordVPN gateway LXC
#  Run as root on the Proxmox host.
#  v2: Nord token is validated (and re-prompted) before any install step
# ============================================================
set -euo pipefail

# ---------------- adjust ----------------
GW_VMID=200
GW_LAN_IP="192.168.1.11/24"    # vpn-gw on your LAN (must be free)
GW_LAN_GW="192.168.1.1"         # your router
GW_INT_IP="10.10.10.1/24"       # vpn-gw on the caged network
LAN_NET="192.168.1.0/24"
CLIENT_NET="10.10.10.0/24"
SAMBA_IP="192.168.1.50"         # your Samba host
TEMPLATE_STORE="local"           # CT template storage
TEMPLATE="debian-13-standard_13.6-1_amd64.tar.zst"   # pveam template (bump version here)
ROOTFS="local-lvm:2"
NORD_COUNTRY="DE"               # Nord country code; used when fetching a conf
# ----------------------------------------

# 0) Pre-flight: obtain + validate the Nord token BEFORE building anything.
#    (Skipped entirely if you've placed a ready-made conf at /root/nord.conf.)
#    A token supplied via $NORD_TOKEN is validated too — a rejected value
#    is dropped and the user is re-prompted.
TOKEN="${NORD_TOKEN:-}"
if [[ ! -f /root/nord.conf ]]; then
  while :; do
    if [[ -z "$TOKEN" ]]; then
      read -rs -p "Nord Account access token (input hidden): " TOKEN; echo
      if [[ -z "$TOKEN" ]]; then
        echo "  (empty — paste it again, or Ctrl+C to abort)"
        continue
      fi
    fi
    code=$(curl -s -m 10 -o /dev/null -w '%{http_code}' \
             -u "token:${TOKEN}" \
             https://api.nordvpn.com/v1/users/services/credentials || true)
    case "$code" in
      200) echo "-- token accepted by Nord"; break ;;
      401|403)
        echo "!! Nord rejected that token (expired / revoked / typo)."
        echo "!! Generate a fresh one (shown once — copy it immediately) at:"
        echo "!! https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/"
        TOKEN=""
        ;;
      *)
        echo "!! Cannot reach the Nord API (HTTP ${code:-none}) — retrying in 5s, Ctrl+C to abort"
        sleep 5
        ;;
    esac
  done
fi

# 1) WireGuard kernel module on the host
modprobe wireguard 2>/dev/null || true
grep -qx wireguard /etc/modules 2>/dev/null || echo wireguard >> /etc/modules

# 2) Internal bridge vmbr1 (skip if you create it via the GUI instead)
if ! grep -qw vmbr1 /etc/network/interfaces; then
cat >> /etc/network/interfaces <<'EOF'

auto vmbr1
iface vmbr1 inet manual
    bridge-ports none
    bridge-stp off
    bridge-fd 0
EOF
  ifreload -a 2>/dev/null || ifup vmbr1
fi

# 3) Debian template
pveam update >/dev/null
pveam list "$TEMPLATE_STORE" | grep -qF "$TEMPLATE" \
  || pveam download "$TEMPLATE_STORE" "$TEMPLATE"

# 4) Create the gateway container (single-homed to vmbr0 + vmbr1)
if ! pct status "$GW_VMID" &>/dev/null; then
  pct create "$GW_VMID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
    --hostname vpn-gw --unprivileged 1 \
    --cores 1 --memory 512 --swap 512 \
    --rootfs "$ROOTFS" \
    --net0 "name=net0,bridge=vmbr0,ip=${GW_LAN_IP},gw=${GW_LAN_GW}" \
    --net1 "name=net1,bridge=vmbr1,ip=${GW_INT_IP}" \
    --nameserver "$GW_LAN_GW" \
    --onboot 1 --tags vpn-gateway \
    --features nesting=1   # trixie's systemd 257 wants nesting in unprivileged CTs
fi
pct start "$GW_VMID" 2>/dev/null || true
for _ in $(seq 1 30); do pct exec "$GW_VMID" -- true 2>/dev/null && break; sleep 1; done

# 5) Everything that runs inside the gateway container
cat > /tmp/gw-setup.sh <<'GWSETUP'
#!/usr/bin/env bash
set -euo pipefail
LAN_NET="${LAN_NET:?}"; CLIENT_NET="${CLIENT_NET:?}"; SAMBA_IP="${SAMBA_IP:?}"
NORD_TOKEN="${NORD_TOKEN:-}"; NORD_COUNTRY="${NORD_COUNTRY:-}"

echo "### gateway setup"
export DEBIAN_FRONTEND=noninteractive
apt-get update -q
apt-get install -y -q wireguard jq curl openresolv iptables-persistent

# -- sanity: can this container create WireGuard interfaces?
if ! ip link add wg-probe type wireguard 2>/dev/null; then
  echo "!! Cannot create a WireGuard interface (EPERM)." >&2
  echo "!! Check 'modprobe wireguard' on the host; if it persists, use a privileged CT or a small VM." >&2
  exit 1
fi
ip link del wg-probe

# -- /etc/wireguard/wg0.conf  (name wg0 => interface wg0 => matches firewall rules)
if [[ -f /root/nord.conf ]]; then
  install -m600 /root/nord.conf /etc/wireguard/wg0.conf
elif [[ -n "$NORD_TOKEN" ]]; then
  echo "-- fetching NordLynx credentials via API"
  privkey=$(curl -fsS -u "token:${NORD_TOKEN}" \
    https://api.nordvpn.com/v1/users/services/credentials \
    | jq -er '.nordlynx_private_key') \
    || { echo "!! credential fetch failed — bad token?" >&2; exit 1; }

  code="${NORD_COUNTRY^^}"
  # country code -> Nord country id (small, current endpoint; DE = 81)
  cid=$(curl -fsS https://api.nordvpn.com/v1/servers/countries \
    | jq -r --arg c "$code" '.[] | select(.code == $c) | .id' | head -n1)
  if [[ -z "$cid" ]]; then
    echo "!! unknown country code '$code'" >&2
    exit 1
  fi
  # server recommendations — the current endpoint; the legacy bulk /v1/servers
  # list no longer carries usable WireGuard data. (-g = --globoff: the [] in
  # the query string are literal, not curl glob ranges)
  srv=$(curl -fsSg "https://api.nordvpn.com/v1/servers/recommendations?filters[country_id]=${cid}&filters[servers_technologies][identifier]=wireguard_udp&limit=10" \
    | jq 'sort_by(.load) | .[0]')
  if [[ -z "$srv" || "$srv" == "null" ]]; then
    echo "!! no WireGuard server found for country '$code'" >&2
    exit 1
  fi
  host=$(jq -r '.hostname' <<<"$srv")
  endpoint=$(jq -r '.station' <<<"$srv")
  # public key: technologies[].metadata is an array of {name, value} pairs here
  pubkey=$(jq -er '.technologies[] | select(.identifier == "wireguard_udp")
                   | .metadata[] | select(.name == "public_key") | .value' <<<"$srv") \
    || { echo "!! could not extract the server public key" >&2; exit 1; }
  cat > /etc/wireguard/wg0.conf <<CONF
# NordVPN ${host}
[Interface]
Address = 10.5.0.2/32
PrivateKey = ${privkey}
DNS = 103.86.96.100, 103.86.99.100

[Peer]
PublicKey = ${pubkey}
Endpoint = ${endpoint}:51820
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
CONF
  chmod 600 /etc/wireguard/wg0.conf
  echo "-- wg0.conf built for ${host} (${endpoint})"
else
  echo "!! Need either /root/nord.conf or NORD_TOKEN." >&2
  exit 1
fi

# -- strip ::/0 from a user-supplied conf (we run v4-only)
sed -i -E 's/(AllowedIPs *= *0\.0\.0\.0\/0) *, *::\/0 */\1/' /etc/wireguard/wg0.conf

# -- forwarding on, IPv6 off (no side door)
cat > /etc/sysctl.d/99-vpngw.conf <<SYSCTL
net.ipv4.ip_forward = 1
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
SYSCTL
# apply only OUR keys — in an unprivileged LXC, `sysctl --system` also
# processes Debian's stock files (kernel.*, fs.*, vm.* — host-global keys),
# fails with "permission denied" and exits nonzero, killing the script
sysctl -p /etc/sysctl.d/99-vpngw.conf
[[ "$(cat /proc/sys/net/ipv4/ip_forward)" == 1 ]] \
  || { echo "!! could not enable ip_forward" >&2; exit 1; }

# -- tunnel up (before lockdown, so creds/API already fetched)
systemctl enable --now wg-quick@wg0
hs=0
for _ in $(seq 1 30); do
  hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -n1)
  [[ "${hs:-0}" -gt 0 ]] && break
  sleep 1
done
if [[ "${hs:-0}" -gt 0 ]]; then
  echo "-- tunnel up: $(wg show wg0 endpoints)"
else
  echo "!! No handshake in 30s — token/endpoint/LAN UDP-51820 egress? (continuing)" >&2
fi

# -- NAT + kill switch + Samba pinhole (persisted, loaded at boot)
mkdir -p /etc/iptables
cat > /etc/iptables/rules.v4 <<IPT
*nat
-A POSTROUTING -s ${CLIENT_NET} -o wg0 -j MASQUERADE
-A POSTROUTING -s ${CLIENT_NET} -d ${LAN_NET} -o net0 -j MASQUERADE
COMMIT
*filter
:FORWARD DROP [0:0]
-A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A FORWARD -i net1 -o wg0 -j ACCEPT
-A FORWARD -i net1 -o net0 -d ${SAMBA_IP} -p tcp -m multiport --dports 139,445 -j ACCEPT
-A FORWARD -i net1 -j DROP
-A OUTPUT -o net0 -d ${LAN_NET} -j ACCEPT
-A OUTPUT -o net0 -p udp --dport 51820 -j ACCEPT
-A OUTPUT -o net0 -j DROP
COMMIT
IPT
iptables-restore < /etc/iptables/rules.v4
systemctl enable netfilter-persistent >/dev/null

# -- watchdog: restart tunnel on stale handshake (respects deliberate stops)
cat > /usr/local/sbin/wg-watchdog <<'WD'
#!/usr/bin/env bash
systemctl is-active --quiet wg-quick@wg0 || exit 0
MAX_AGE=180
hs=$(wg show wg0 latest-handshakes 2>/dev/null | awk '{print $2}' | head -n1)
now=$(date +%s)
if [[ -z "${hs:-}" || "${hs:-0}" -eq 0 || $((now - hs)) -gt "$MAX_AGE" ]]; then
  logger -t wg-watchdog "stale handshake — restarting wg-quick@wg0"
  systemctl restart wg-quick@wg0
fi
WD
chmod 700 /usr/local/sbin/wg-watchdog

cat > /etc/systemd/system/wg-watchdog.service <<'WDS'
[Unit]
Description=Restart WireGuard tunnel on stale handshake
After=wg-quick@wg0.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/wg-watchdog
WDS

cat > /etc/systemd/system/wg-watchdog.timer <<'WDT'
[Unit]
Description=Minute WireGuard handshake check
[Timer]
OnBootSec=2min
OnUnitActiveSec=1min
[Install]
WantedBy=timers.target
WDT
systemctl daemon-reload
systemctl enable --now wg-watchdog.timer >/dev/null

# -- auto-restart wg-quick on failure
mkdir -p /etc/systemd/system/wg-quick@wg0.service.d
printf '[Service]\nRestart=on-failure\nRestartSec=15\n' \
  > /etc/systemd/system/wg-quick@wg0.service.d/override.conf

echo "### gateway ready — egress IP via tunnel:"
curl -fsS -m 10 https://api.ipify.org && echo || echo "(no egress yet — check handshake)"
GWSETUP

pct push "$GW_VMID" /tmp/gw-setup.sh /root/gw-setup.sh --perms 700
rm -f /tmp/gw-setup.sh

# manual conf, if you prepared one yourself
[[ -f /root/nord.conf ]] && pct push "$GW_VMID" /root/nord.conf /root/nord.conf --perms 600 || true

# token acquired + validated up front in step 0; nothing is built with a bad one

pct exec "$GW_VMID" -- env \
  NORD_TOKEN="$TOKEN" NORD_COUNTRY="$NORD_COUNTRY" \
  LAN_NET="$LAN_NET" CLIENT_NET="$CLIENT_NET" SAMBA_IP="$SAMBA_IP" \
  bash /root/gw-setup.sh

echo
echo "=== vpn-gw built. Next: make-caged-client.sh, then run the kill-switch drill. ==="
