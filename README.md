# NordVPN Egress Gateway for Proxmox Containers

Fail-closed NordVPN (WireGuard / NordLynx) internet routing for Proxmox LXC containers, with a pinhole for a local Samba share.

One gateway container holds the VPN tunnel and enforces routing; any number of "caged" client containers sit behind it and can only reach the internet through that tunnel. If the tunnel dies, the clients lose the internet — and nothing else. The share keeps working the whole time. No client-side VPN app, no per-client kill switches: the enforcement is topological.

## How it works

```
                        Internet
                           │
                    NordVPN tunnel (wg0)
                           │
              ┌────────────┴────────────┐
              │   vpn-gw (LXC)         │
              │   net0: 192.168.1.10   │
              │   net1: 10.10.10.1     │
              └─────┬──────────────┬────┘
             vmbr0  │              │  vmbr1 (internal bridge,
        ┌───────────┴───┐   ┌──────┴────────────┐  no physical port)
        │ Home LAN      │   │ "caged" LXCs      │
        │ router  .1   │   │ 10.10.10.2, .3 …  │
        │ samba   .50 ◄┼───┤ default gw: .1    │
        └──────────────┘   └───────────────────┘
```

- **`vpn-gw`** — one CT, two NICs: one on your LAN, one on an internal bridge (`vmbr1`) with no physical port. It runs a WireGuard tunnel to NordVPN and NATs client traffic into it. Firewall rules allow exactly two things out of the client net: the tunnel, and Samba (139/445) to one named host. Everything else is dropped, and the gateway itself can't leak around its own tunnel.
- **Caged clients** — one CT per service, single NIC on `vmbr1`, default gateway = vpn-gw. There is no other route to anywhere. That topology, not a VPN application, is what makes the "must use NordVPN" rule unbreakable.

### Why "fail-closed"

| Scenario | Result |
|---|---|
| Normal operation | All client internet egresses via NordVPN; Samba works |
| Tunnel dies / Nord unreachable | Clients lose the internet entirely; **Samba keeps working**; nothing leaks |
| Someone inside a client tries to bypass | No second NIC, no LAN route, gateway drops non-Samba LAN traffic — structurally impossible |
| `wg-quick` crashes | Auto-restart (`Restart=on-failure`) plus a 60 s handshake watchdog |
| Stale handshake (server reboot, path change) | Watchdog restarts the tunnel |

Split tunnelling is free: `AllowedIPs = 0.0.0.0/0` sends everything through the tunnel, while the LAN's more-specific connected routes keep local traffic direct — which is why the share runs at full LAN speed and survives the tunnel going down.

## Files

| File | Purpose |
|---|---|
| `vpn-gw-build.sh` | Run once on the PVE host. Creates the internal bridge + gateway CT, validates your Nord token against the API first, fetches a WireGuard config, brings up the tunnel, installs NAT + kill-switch rules and a handshake watchdog. Idempotent — re-running is safe. |
| `make-caged-client.sh` | One per client. Creates a single-homed CT on the internal bridge, prompts for (and applies) a root console password, installs curl and the Samba mount. `Usage: ./make-caged-client.sh <vmid> <hostname> <last-octet>` |
| `killswitch-test.sh` | The acceptance test: egress is NordVPN, internet dies with the tunnel down, the share survives, egress returns on restart. Exits non-zero on any failure. `Usage: ./killswitch-test.sh <client-vmid> <gateway-vmid>` |

## Quick start

Prerequisites: Proxmox VE 8/9, a NordVPN subscription, root on the PVE host, a Samba server on your LAN, and free CT IDs (defaults below: 200 gateway, 201+ clients).

1. **Adjust the variables** at the top of both build scripts — LAN subnet, router, Samba host IP, storage names, template version, Nord country code. The defaults assume `192.168.1.0/24` with the share at `.50`.
2. **Get a NordVPN access token:** Nord Account → Services → NordVPN → Manual setup (`https://my.nordaccount.com/dashboard/nordvpn/manual-configuration/`) → "Set up NordVPN manually" → Generate new token. It's shown once — copy it immediately. A short expiry is fine, and it can be revoked afterwards: the tunnel only needs the private key the build writes into the gateway.
3. **Build the gateway** (as root on the PVE host):

   ```bash
   ./vpn-gw-build.sh      # validates the token against Nord's API before building anything
   ```

4. **Build a client** — the gateway must be up, because the client's apt and DNS traffic flow through the tunnel:

   ```bash
   ./make-caged-client.sh 201 appbox 2      # -> CT 201 'appbox' at 10.10.10.2
   ```

   …then finish the Samba side with the two commands the script prints (`/etc/cifs-creds` and a mount trigger).

5. **Run the drill:**

   ```bash
   ./killswitch-test.sh 201 200
   ```

   Expect: `PASS: internet is tunnel-only, the share is tunnel-independent`.

## Day-to-day

- **Console access to a client:** `pct console <vmid>` (or the PVE GUI console), user `root`, the password the build prompted for. `Ctrl-A` then `Q` detaches. This is the *only* interactive door — the cage has no SSH pinhole, so the virtual console is genuinely the front door.
- **Change Nord country/server:** edit `NORD_COUNTRY` and re-run `vpn-gw-build.sh` (token prompt again; the same private key is re-fetched), or drop a hand-made WireGuard conf at `/root/nord.conf` on the host to bypass the API entirely.
- **More LAN pinholes:** copy the Samba `FORWARD` line in the gateway's `/etc/iptables/rules.v4`, adjust destination/ports, `iptables-restore` it back. Everything else stays closed.
- **Reboots:** both CTs are `--onboot`; `wg-quick` plus the watchdog bring the tunnel back. Nothing manual after a host reboot.
- **More clients:** another `make-caged-client.sh` run with a new vmid and a unique last octet (2–254). One Nord device slot is used regardless of client count.

## Security model

**Enforced:** no client internet path except the tunnel (topology + gateway firewall); the gateway itself cannot leak around its own tunnel (OUTPUT rules); LAN reach from clients is one host on two ports; IPv6 disabled across the cage; no inbound network access to clients at all.

**Out of scope:** a compromised Proxmox host (`pct enter` is root in any CT), the VPN provider itself, the Samba server, physical access. Enabling the LXC `nesting` feature (required for Debian 13's systemd) does not weaken the cage — it only relaxes mount/namespace permissions inside the guest so its own systemd works; see the [Proxmox docs](https://pve.proxmox.com/pve-docs/pct.1.html) on `features`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "no WireGuard server found for country X" / "unknown country code" | Valid codes: `curl -s https://api.nordvpn.com/v1/servers/countries \| jq -r '.[].code'` — or bring your own conf at `/root/nord.conf` |
| Credential fetch fails | Token expired/revoked/typo — regenerate (shown once) |
| `WARN: Systemd 257 detected … enable nesting` | Expected without the feature; the scripts set `--features nesting=1` at creation. Existing CT: `pct set <vmid> --features nesting=1` + restart |
| `sysctl: permission denied` noise inside CTs | Debian's stock host-global keys, which an unprivileged CT can't touch — harmless. The scripts apply only their own netns-scoped keys |
| Client build hangs on apt/DNS | Gateway tunnel must be up first — client traffic, including DNS, flows through it |
| Console login refused | `make-caged-client.sh` sets root's password when it prompts; for older CTs: `pct exec <vmid> -- passwd root` |
| Samba mount by hostname fails | Nord DNS doesn't know your LAN names — mount by IP or add `/etc/hosts` entries |
| No handshake after build | `pct exec 200 -- wg show wg0`; check token validity and that the LAN allows outbound UDP/51820 |

## Notes

- NordVPN does not publish official WireGuard config files. The build exchanges a manual-setup access token for your NordLynx private key via their public API — the same mechanism the official Linux client uses for `nordvpn login --token`. It's undocumented-but-stable and widely relied on by router/gateway tooling; the scripts fail loudly if it ever changes, and `/root/nord.conf` is the manual escape hatch.
- Built and proven against NordVPN's live API and Proxmox VE 8/9 with the Debian 13 template. `AGENTS.md` records the environment quirks the scripts work around.

## License

MIT — see [LICENSE](LICENSE).