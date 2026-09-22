#!/usr/bin/env bash
# usage: ./make-caged-client.sh <vmid> <hostname> <last-octet>   e.g. 201 appbox 2
# prompts (hidden) for a root console password, and installs curl for the
# kill-switch drill.
set -euo pipefail
usage() {
  cat >&2 <<EOF
Usage: $0 <vmid> <hostname> <last-octet>

  vmid        free Proxmox CT number (200 is the gateway)
  hostname    container hostname
  last-octet  its IP on the caged net: 10.10.10.<octet>, 2-254 (.1 is the gateway)

Example: $0 201 appbox 2   -> CT 201 'appbox' at 10.10.10.2
EOF
}
if [[ $# -lt 3 ]]; then
  echo "!! too few arguments: got $#, expected 3" >&2
  usage; exit 1
fi
if [[ $# -gt 3 ]]; then
  echo "!! too many arguments: got $#, expected 3" >&2
  usage; exit 1
fi
VMID=$1; HOST=$2; OCTET=$3
[[ "$VMID" =~ ^[0-9]+$ ]]  || { echo "!! vmid must be numeric: '$VMID'" >&2; exit 1; }
[[ "$OCTET" =~ ^[0-9]+$ ]] || { echo "!! last octet must be numeric: '$OCTET'" >&2; exit 1; }
if (( OCTET < 2 || OCTET > 254 )); then
  echo "!! last octet must be 2-254 — 10.10.10.1 is the gateway, .0/.255 reserved" >&2
  exit 1
fi

# root console password — the Debian template ships root locked, and the
# Proxmox virtual console (pct console / GUI) is the only way into a caged
# client (the gateway firewall has no SSH pinhole), so this is the front door.
PASS=""
while [[ -z "$PASS" ]]; do
  read -rs -p "Password for root on '$HOST' (console login, input hidden): " PASS; echo
  [[ -n "$PASS" ]] || echo "  (empty won't work — try again, or Ctrl+C to abort)"
done
TEMPLATE_STORE=local
TEMPLATE=debian-13-standard_13.6-1_amd64.tar.zst
ROOTFS=local-lvm:4
SAMBA_IP=192.168.1.50
SAMBA_SHARE=media          # share name

pveam list "$TEMPLATE_STORE" | grep -qF "$TEMPLATE" \
  || pveam download "$TEMPLATE_STORE" "$TEMPLATE"

pct create "$VMID" "${TEMPLATE_STORE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOST" --unprivileged 1 \
  --cores 1 --memory 512 \
  --rootfs "$ROOTFS" \
  --net0 "name=net0,bridge=vmbr1,ip=10.10.10.${OCTET}/24,gw=10.10.10.1" \
  --nameserver 103.86.96.100,103.86.99.100 \
  --onboot 1 --tags vpn-caged \
  --features nesting=1   # trixie's systemd 257 wants nesting in unprivileged CTs
pct start "$VMID"
for _ in $(seq 1 30); do pct exec "$VMID" -- true 2>/dev/null && break; sleep 1; done

# no IPv6 side door — sysctl -p on OUR file only; `--system` trips over
# Debian's stock host-global keys in unprivileged CTs and exits nonzero
pct exec "$VMID" -- bash -c 'printf "net.ipv6.conf.all.disable_ipv6=1\nnet.ipv6.conf.default.disable_ipv6=1\n" > /etc/sysctl.d/99-noipv6.conf && sysctl -p /etc/sysctl.d/99-noipv6.conf'

# console login: set root's password (piped to chpasswd — never on a command
# line, in PVE task logs, or in shell history)
printf 'root:%s\n' "$PASS" | pct exec "$VMID" -- chpasswd
echo "-- root console password set"

# CIFS mount (lazy automount, so boot never hangs if the share/gateway is down)
pct exec "$VMID" -- bash -c '
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q && apt-get install -y -q cifs-utils curl   # curl: kill-switch drill
  mkdir -p /srv/share
  printf "//%s/%s /srv/share cifs _netdev,credentials=/etc/cifs-creds,vers=3.0,x-systemd.automount,x-systemd.idle-timeout=10min 0 0\n" "$1" "$2" >> /etc/fstab
' _ "$SAMBA_IP" "$SAMBA_SHARE"

echo "Now set the Samba credentials inside the client:"
echo "  pct exec $VMID -- bash -c 'umask 077; printf \"username=YOUR_USER\npassword=YOUR_PASS\n\" > /etc/cifs-creds'"
echo "Then trigger the mount:  pct exec $VMID -- ls /srv/share"
echo "Console login:  pct console $VMID   (user: root, password: the one you entered above)"
