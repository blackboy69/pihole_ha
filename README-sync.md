# Pi-hole HA Configuration Sync

`install-sync.sh` keeps Pi-hole settings — ad list subscriptions, allow/deny domain
entries, groups, local DNS records, reverse DNS rules, and blocking behavior —
consistent across your HA nodes.

This is a separate concern from [`install.sh`](install.sh) (Keepalived) and
[`install-anycast.sh`](install-anycast.sh) (BGP anycast), which only handle DNS
traffic routing and failover. Neither of those scripts touches Pi-hole's own
configuration, so without this script your nodes will gradually drift apart as you
make changes on one but not the other.

> **Beta:** This script is not yet extensively tested. Keep a Teleporter backup handy
> before relying on it.

Back to the [main README](README.md).

## Overview

- One node is designated the **source**: this is where you make configuration changes.
- Every other node is a **replica**: it runs on a schedule and pulls the latest
  configuration from the source.
- Sync is one-way. Changes made directly on a replica will be overwritten on its next
  sync.

## How it works

Pi-hole v6 provides a REST API that this script uses in two ways:

1. **Teleporter API** (`/api/teleporter`) — Pi-hole's built-in backup/restore
   mechanism. It's used here to sync ad list subscriptions, allow/deny domain
   entries, and the groups they belong to.
2. **Config API** (`/api/config/dns`) — a more granular endpoint used to sync a
   specific set of DNS-related settings: local DNS records, reverse DNS rules,
   blocking behavior, and the local domain suffix.

Two APIs are used because Teleporter's "config" import is all-or-nothing: enabling it
would also overwrite network, interface, DHCP, and web server settings, which are
specific to each node and should never be copied between them. See
[Why not sync everything through Teleporter?](#why-not-sync-everything-through-teleporter)
below.

Each scheduled sync run:

1. Logs in to the source node's API.
2. Reads the DNS settings listed below from the source, if this is enabled.
3. Downloads a Teleporter export from the source, then logs out.
4. Logs in to this node's own local API.
5. Writes the DNS settings to this node — before the next step, since importing can
   restart Pi-hole's DNS service and invalidate the session.
6. Imports the Teleporter export locally, scoped to ad lists, domain entries, and
   groups only.
7. Logs out and removes the temporary export file.

### What gets synced

**Always synced** (via Teleporter):
- Ad list subscriptions
- Allow/deny domain entries
- The groups they belong to

**Synced if enabled** (via the config API, on by default):
- Local DNS records and CNAME records, copied as-is. This works well if you use
  per-node names — e.g. `pihole1.local` and `pihole2.local`, each pointing at a
  specific node's real IP — since those should resolve the same way regardless of
  which node answers the query.
- Reverse DNS / conditional forwarding rules for your local subnets
- Blocking behavior (whether blocking is active, the block mode, and the EDNS
  response type)
- Special-domain handling (Mozilla canary, iCloud Private Relay, designated resolver)
- The local domain suffix (e.g. `lan` or `local`)

**Never synced:**
- Network interface, DHCP server, and web server/API settings — these are specific to
  each node
- Per-client group assignments (not commonly used; can be enabled manually, see
  [Notes](#notes))

## Why not sync everything through Teleporter?

Pi-hole v6 stores everything outside of ad lists and domain entries in a single file,
`/etc/pihole/pihole.toml`. This includes network and interface settings, DHCP
configuration, web server/API settings (including app passwords), and the DNS
settings this script syncs — all in one place.

Teleporter's import only offers a single on/off switch for that entire file. Turning
it on would:

- Overwrite this node's own network/interface configuration to match the source,
  breaking it if the nodes have different IPs or interfaces — which is normal in an
  HA setup
- Potentially overwrite DHCP settings if the two nodes differ on whether DHCP is
  enabled
- Overwrite this node's own app password, since it's stored in the same file, which
  could break the sync script's own ability to log in on its next run

To avoid this, `install-sync.sh` never enables Teleporter's full config import. It
uses the config API instead, which only touches the specific settings listed above.

## Requirements

- Pi-hole v6 on every node. This script relies on v6-only API endpoints that don't
  exist in v5.
- An app password created in the web UI of the source node, and a separate app
  password created in the web UI of every replica node.
- Network connectivity from each replica to the source's web/API port.
- `sudo` access, and `curl`/`wget` if running the script directly from GitHub.

## Setup

1. In the source node's web UI, go to **Settings → Web Interface/API**, switch to
   Expert mode, and select **Configure app password**. Save the value — Pi-hole only
   displays it once. Repeat this on each replica node too.
2. Run the script on the source node. This step is informational only and makes no
   changes:
   ```bash
   curl -sSL https://raw.githubusercontent.com/blackboy69/pihole_ha/main/install-sync.sh | sudo bash
   ```
3. Run the script on each replica node and answer the prompts:
   ```bash
   sudo ./install-sync.sh
   ```

## Configuration prompts (replica nodes)

| Prompt | Description |
|---|---|
| Source URL | Base URL of the source node's Pi-hole, e.g. `http://192.168.1.101` |
| Source app password | The app password created on the source node |
| This node's own URL | Usually `http://127.0.0.1` (default) — the import step runs against this node's own local API |
| This node's own app password | The app password created on this replica node |
| Sync DNS settings | Whether to sync the settings listed above, in addition to the ad lists/domains that always sync. Defaults to yes. |
| Sync interval | How often, in minutes, the replica pulls from the source. Defaults to 5. |

## Files created

| Path | Purpose |
|---|---|
| `/etc/pihole-ha-sync/sync.conf` | Source/local URLs and app passwords. Mode `600`, root-owned. |
| `/usr/local/bin/pihole_sync.sh` | The sync script itself. |
| `/etc/systemd/system/pihole-sync.service` and `.timer` | The scheduled job that runs the sync. |

To rotate a credential, edit `/etc/pihole-ha-sync/sync.conf` directly, or re-run
`install-sync.sh`.

## Troubleshooting

Run a sync manually to see what happens:
```bash
sudo /usr/local/bin/pihole_sync.sh
```

Check the scheduled job:
```bash
systemctl status pihole-sync.timer
systemctl list-timers pihole-sync.timer
```

Watch the logs:
```bash
journalctl -t pihole_sync -f
```

Common errors:

- **Could not authenticate to source** — check the source URL and app password,
  confirm the source's web UI is reachable from the replica
  (`curl -I http://<source-ip>`), and confirm the app password hasn't been revoked.
- **Could not authenticate to local Pi-hole API** — this node needs its own app
  password too; it's separate from the source's.
- **Teleporter export from SOURCE failed** — check that Pi-hole is healthy on the
  source (`systemctl status pihole-FTL`). A known Pi-hole bug (`compression_error`)
  can be fixed by stopping FTL, deleting a corrupt `/etc/pihole/pihole-FTL.db`, and
  restarting.
- **DNS settings sync failed** — logged as a warning, not a hard failure; the ad
  list/domain sync still completes. Check the HTTP status code in the log. A 400
  usually means one of the source's entries is malformed — an invalid IP/hostname in
  a host record, a CNAME record missing its comma, or a malformed reverse DNS rule.
- **Sync succeeds but changes don't appear** — confirm you're editing the node
  actually configured as the source, and that the replica's `sync.conf` points to the
  right URL.

## Notes

- This script only syncs configuration. Use `install.sh` or `install-anycast.sh` for
  DNS traffic routing/failover — see the [main README](README.md).
- Only make configuration changes on the source node. Changes made directly on a
  replica will be overwritten on its next scheduled sync.
- If you have a large number of ad lists, consider a longer sync interval — larger
  exports take longer and use more bandwidth.
- Per-client group assignments aren't synced by default. If you use that feature,
  edit `IMPORT_SCOPE` in `/usr/local/bin/pihole_sync.sh` and set those flags to
  `true`.

## Disclaimer

- This script modifies system configuration and installs software (`curl`, `jq`) on
  each replica. Use at your own risk.
- Back up your Pi-hole configuration (a Teleporter export via the web UI) before
  making large changes.
- The Teleporter API's exact request and response format can change between Pi-hole
  versions. If you see unexpected errors after upgrading Pi-hole, check the API docs
  at `/api/docs` on your instance or at docs.pi-hole.net.
