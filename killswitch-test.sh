#!/usr/bin/env bash
# ============================================================
#  killswitch-test.sh — prove the VPN cage is fail-closed
#  Run as root on the Proxmox host.
#
#  Checks, in order:
#   1. client egress is NOT the host's ISP IP (i.e. it exits via NordVPN)
#   2. with the tunnel stopped, the client loses the internet
#   3. with the tunnel stopped, the Samba share still works
#   4. after the tunnel restarts, egress is via NordVPN again
#
#  Note: the gateway's handshake watchdog deliberately ignores
#  manually-stopped tunnels (it checks `systemctl is-active` first), so the
#  stop in step 2 sticks for the duration of the drill. Crashed tunnels in
#  normal operation are still auto-restarted within a minute.
# ============================================================
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 <client-vmid> <gateway-vmid>

  client-vmid   a CT built by make-caged-client.sh (curl + share mounted)
  gateway-vmid  the vpn-gw CT built by vpn-gw-build.sh

Example: $0 201 200
EOF
}
if [[ $# -ne 2 ]]; then
  echo "!! wrong number of arguments: got $#, expected 2" >&2
  usage
  exit 1
fi
CLIENT=$1
GW=$2
FAILS=0
note() { echo "   $*"; }
fail() { echo "   !! FAIL — $*" >&2; FAILS=$((FAILS+1)); }

echo "== kill-switch drill: client $CLIENT egress via gateway $GW =="

echo "1) Baseline: client egress must not be your ISP address"
HOST_IP=$(curl -fsS -m 10 https://api.ipify.org)
CLIENT_IP=$(pct exec "$CLIENT" -- curl -fsS -m 15 https://api.ipify.org)
note "host ISP egress: $HOST_IP"
note "client egress:   $CLIENT_IP"
if [[ "$CLIENT_IP" == "$HOST_IP" ]]; then
  fail "client egress equals the host's ISP IP — traffic is bypassing the tunnel"
else
  note "OK — client egress differs from the ISP address (NordVPN exit)"
fi

echo "2) Stopping the tunnel on the gateway"
pct exec "$GW" -- systemctl stop wg-quick@wg0
sleep 3

echo "3) Tunnel down: the client must NOT reach the internet"
if pct exec "$CLIENT" -- curl -fsS -m 8 https://api.ipify.org >/dev/null 2>&1; then
  fail "client reached the internet with the tunnel down — the cage is NOT fail-closed"
else
  note "OK — no internet with the tunnel down (fail-closed)"
fi

echo "4) Tunnel down: the Samba share must still work"
if pct exec "$CLIENT" -- bash -c 'dd if=/dev/zero of=/srv/share/killswitch-test.bin bs=1M count=8 2>/dev/null && sync && rm -f /srv/share/killswitch-test.bin'; then
  note "OK — share write path intact"
else
  fail "share write failed — check /etc/cifs-creds and: pct exec $CLIENT -- ls /srv/share"
fi

echo "5) Restarting the tunnel and waiting for egress to return"
pct exec "$GW" -- systemctl start wg-quick@wg0
CLIENT_IP2=""
for _ in $(seq 1 10); do
  if CLIENT_IP2=$(pct exec "$CLIENT" -- curl -fsS -m 8 https://api.ipify.org); then break; fi
  sleep 3
done
if [[ -z "$CLIENT_IP2" ]]; then
  fail "client never regained internet after the tunnel restarted"
elif [[ "$CLIENT_IP2" == "$HOST_IP" ]]; then
  fail "post-restart egress is the ISP address — tunnel is not carrying traffic"
else
  note "OK — egress via NordVPN restored: $CLIENT_IP2"
fi

echo
if (( FAILS == 0 )); then
  echo "== PASS: internet is tunnel-only, the share is tunnel-independent =="
else
  echo "== $FAILS check(s) FAILED — see the !! lines above ==" >&2
fi
exit "$FAILS"