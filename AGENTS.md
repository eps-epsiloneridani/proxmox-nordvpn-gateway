# AGENTS.md

Guidance for AI agents (and humans) making changes to this repository.

## What this repository is

Three bash scripts that build a fail-closed NordVPN (WireGuard/NordLynx) egress gateway on Proxmox VE, plus "caged" client containers behind it. Clients must have **no path to the internet except through the VPN tunnel**, while keeping access to a LAN Samba share. Enforcement is topological (single NIC on an internal bridge, default route via the gateway only), not app-level. `README.md` explains the architecture for newcomers — read it first.

## The invariants — do not break these

1. Client containers are single-homed on the internal bridge (`vmbr1`) with default gateway = vpn-gw only. Never add a second NIC, a second route, or a DHCP path.
2. On the gateway, `FORWARD` from the client net (`net1`) to the physical NIC (`net0`) is only ever opened for explicit, named pinholes (today: Samba 139/445 to one host). New pinholes get a new explicit rule — never loosen the catch-all `DROP`, and never add a `FORWARD … -o net0` rule that isn't destination-restricted.
3. The gateway's `OUTPUT` chain may reach the LAN and the Nord endpoint, and nothing else outside the tunnel. That is the gateway's own kill switch.
4. IPv6 stays disabled on gateway and clients — no side doors.
5. Scripts are idempotent (safe to re-run) and fail loudly (`set -euo pipefail`). Bad credentials must abort **before** any install step — that's why the token pre-flight is step 0 of `vpn-gw-build.sh`.
6. Any change that touches routing or firewall rules must end with a passing `./killswitch-test.sh <client> <gateway>` run.

## Secrets handling

- Interactive secrets (Nord token, root console passwords) are read with `read -rs` — never echoed, never passed as command-line arguments, never written to files in this repo.
- The Nord token is single-use at build time and revocable afterwards. The WireGuard private key lives only in `/etc/wireguard/wg0.conf` (mode 600) inside the gateway container. `.gitignore` blocks `nord.conf`/`wg0.conf` — keep it that way.
- Passwords reach the container via `printf | pct exec -- chpasswd` (piped stdin) so they never appear in `ps`, PVE task logs, or shell history. Preserve that pattern.

## Environment quirks — all learned the hard way; verify before "fixing"

- **Unprivileged LXC:** apply sysctls with `sysctl -p <our-own-file>` on netns-scoped keys only. `sysctl --system` also processes Debian's stock host-global keys (`kernel.*`, `fs.*`, `vm.*`), fails with "permission denied", exits **nonzero**, and kills any `set -e` script.
- **curl:** bracketed query strings need `-g` (`--globoff`) or curl aborts with "bad range in URL position".
- **NordVPN API:**
  - Resolve country via `/v1/servers/countries` (`.code` → `.id`), then pick a server via `/v1/servers/recommendations?filters[country_id]=<id>&filters[servers_technologies][identifier]=wireguard_udp`. The legacy bulk `/v1/servers` list no longer carries usable WireGuard data — don't go back to it.
  - On the recommendations endpoint, `technologies[].metadata` is an **array** of `{name, value}` pairs (the public key is `name == "public_key"`).
  - The private key from `/v1/users/services/credentials` (Basic auth, username literally `token`) is JSON-escaped — parse with `jq`, not grep.
  - If you change an API integration, verify the endpoint **live** with curl/jq before committing; several "documented" endpoints have been deprecated without notice.
- **Debian 13 (systemd 257) containers** need `--features nesting=1` in unprivileged CTs; Proxmox warns otherwise and systemd units (journald et al.) can misbehave.
- **`pct exec`** always uses the `--` separator; complex commands go through `pct exec <vmid> -- bash -c '…'`.

## Conventions

- Bash with `set -euo pipefail`. Argument errors print `!! …` to stderr and exit 1, via a `usage()` function that explains each argument (see `make-caged-client.sh`).
- Progress messages use `-- …`; errors use `!! …`.
- Comments explain *why* (especially workarounds), not *what*. Someone will eventually try to "clean up" the `-g` flag or the `sysctl -p` pattern — a comment is the only thing that stops them.
- Keep the Nord-facing values (country default, DNS servers `103.86.96.100`/`103.86.99.100`, client address `10.5.0.2/32`) consistent across scripts if changed.

## Testing

`./killswitch-test.sh <client-vmid> <gateway-vmid>` is the acceptance test — it must pass before merging changes that touch routing, firewall rules, or the WireGuard config. It compares the client's egress against the Proxmox host's own ISP IP, so a bypass is detected automatically. `bash -n <script>` for a syntax gate before anything else.

## History / provenance

Extracted from a working build (design document v3). Lineage: v1 = the original working gateway; v2 = Nord token pre-flight, client argument validation, `nesting=1`, client `sysctl -p` fix; v3 = root console password + curl for the drill. This repository is now the source of truth — the changelog continues in commit history.