# Pi-hole High Availability (HA) Setup Script using BGP Anycast (bird2)

> **Beta:** This script is not yet extensively tested. Review it before running on
> production nodes.

> Looking for the simpler, no-router-config option? See [README_keepalived.md](README_keepalived.md)
> for the keepalived (VRRP) version of this setup. Back to the [index](README.md).

`install-anycast.sh` is an alternative to `install.sh` (keepalived/VRRP). Instead of a
single Virtual IP that floats between two Pi-holes on the same LAN segment, every node
advertises the **same** anycast IP address to your router over eBGP using `bird2`. The
router installs a route to whichever node(s) currently report themselves healthy.

This approach is aimed at a UniFi Cloud Gateway (UCG-Fiber, UDM-Pro, UDM-SE, UCG-Max/
Ultra, UXG-Enterprise) running **UniFi OS 4.1.13+**, which can accept an uploaded
FRR-format BGP config via `Settings -> Routing -> BGP -> Create New Route`.

## Anycast vs. keepalived - which should I use?

* **keepalived (`install.sh`)** - simpler, no router configuration required, works with
  any router/switch. Failover relies on ARP/VRRP on a single L2 segment, and only one
  node (the MASTER) serves traffic at a time.
* **BGP anycast (`install-anycast.sh`)** - requires a BGP-capable router (e.g. UniFi
  Cloud Gateway). In exchange, failover doesn't depend on VRRP/ARP timing, nodes can
  live on different subnets/VLANs, and all healthy nodes serve traffic simultaneously
  with equal preference (true active-active), rather than one active/one standby.

## Features

* **Interactive Setup:** Same style of guided prompts as `install.sh`.
* **Automated `bird2` Installation.**
* **Per-Node Health Check + VIP Toggle:** `/usr/local/bin/pihole_anycast_check.sh`,
  run every N seconds by a systemd timer, adds the anycast IP to `lo` when Pi-hole's
  resolver (port 53) is listening, and removes it when it isn't. `bird2`'s `direct`
  protocol only advertises routes that actually exist on the interface, so this is
  what triggers BGP advertise/withdraw - no route-map scripting needed.
* **Active-Active, Equal Preference:** Every node is a peer - there's no MASTER/BACKUP
  role or path preference. All currently-healthy nodes advertise the anycast route with
  equal weight, and the router distributes traffic among them; if a node's route is
  withdrawn, traffic simply shifts to whichever nodes remain.
* **Generates a UniFi BGP Config Snippet:** Writes `/root/pihole_ha_anycast/` files
  with the `neighbor` lines this node needs, plus a starter combined config to upload
  to the router.

## Prerequisites

1. Two (or more) Raspberry Pis (or similar Debian-based systems), each running Pi-hole.
2. Static IP addresses for each Pi-hole node.
3. A UniFi Cloud Gateway on UniFi OS 4.1.13+ with LAN connectivity to both nodes.
4. `sudo` access, and `curl`/`wget` if running directly from GitHub.
5. A chosen anycast IP address not otherwise in use. It does **not** need to be inside
   your LAN subnet - it's reached via a routed `/32`, not ARP.

## How to Use

Run this script on **each** Pi-hole node, each with a **different local ASN**, then
combine the generated neighbor lines into a single file and upload it to your router.

```bash
curl -sSL https://raw.githubusercontent.com/blackboy69/pihole_ha/main/install-anycast.sh | sudo bash
```

or, downloaded locally:

```bash
chmod +x install-anycast.sh
sudo ./install-anycast.sh
```

## Configuration Prompts

* **Node Label:** A short name for this node, used for generated file names/logging.
* **Network Interface:** The interface facing your router.
* **Local ASN:** This node's private BGP ASN (default `65001`, suggested `65002`,
  `65003`, ... for additional nodes). **Must be unique per node.**
* **Router ASN / Router IP:** Your UniFi Cloud Gateway's BGP ASN and LAN IP (BGP
  neighbor address). **Must be identical on all nodes.**
* **Anycast IP:** The shared address clients will use for DNS. **Must be identical on
  all nodes.**
* **Health Check Interval:** How often (seconds) to check Pi-hole and toggle the VIP.

## Uploading the BGP Config to Your UniFi Cloud Gateway

UniFi's BGP GUI (`Settings -> Routing -> BGP -> Create New Route`) takes a single
uploaded plain-text FRR-format file per route entry - there's no "add a neighbor"
button, and re-uploading **replaces** the previous config. Each run of
`install-anycast.sh` writes:

* `/root/pihole_ha_anycast/unifi-bgp-neighbor-<node>.conf` - just this node's
  `neighbor` line, so you can copy it into a combined file.
* `/root/pihole_ha_anycast/unifi-bgp-combined.conf` - a starter template with a
  placeholder comment for each additional node's `neighbor`/`activate` lines.

A finished two-node example (router ASN 65000 at 192.168.1.1, node 1 at
192.168.1.101/ASN 65001, node 2 at 192.168.1.102/ASN 65002) looks like:

```
router bgp 65000
 bgp router-id 192.168.1.1
 no bgp ebgp-requires-policy
 neighbor 192.168.1.101 remote-as 65001
 neighbor 192.168.1.102 remote-as 65002
 !
 address-family ipv4 unicast
  neighbor 192.168.1.101 activate
  neighbor 192.168.1.102 activate
 exit-address-family
!
```

Upload this combined file via the UniFi Network web UI. `no bgp ebgp-requires-policy`
is required because these eBGP peers have no route-map applied, which FRR otherwise
rejects by default.

## How It Works

* **`bird2` `direct` protocol:** Watches the `lo` interface and picks up the anycast
  `/32` address only while it's actually assigned there.
* **Export filter:** Only ever exports the anycast `/32` (never `127.0.0.1` or anything
  else that might exist on `lo`).
* **Health check + toggle script (`pihole_anycast_check.sh`):** Runs on a systemd timer
  (default every 2s). Adds the anycast IP to `lo` when `ss -lntu` shows something
  listening on port 53; removes it otherwise. Logs via `logger -t pihole_anycast`
  (check with `journalctl -t pihole_anycast`).
* **BGP session:** Single-hop eBGP to the router, `hold time 9` / `keepalive time 3`
  for reasonably fast failure detection. The router only installs routes it currently
  hears - when a node withdraws its route (VIP removed), traffic shifts to the
  remaining healthy node(s) automatically.
* **Equal preference, no prepending:** Every node exports the anycast route the same
  way, with no AS-path prepending or other preference mechanism. All currently-healthy
  nodes are advertised and used simultaneously (true active-active anycast).

## Troubleshooting

* **Check `bird2` status:** `sudo systemctl status bird`
* **View `bird2` logs:** `journalctl -u bird -f`
* **Check BGP session / routes:** `sudo birdc show protocols` and `sudo birdc show route`
* **Check the health check timer:** `systemctl status pihole-anycast-check.timer` and
  `journalctl -t pihole_anycast -f`
* **Verify VIP on this node:** `ip addr show lo | grep <anycast-ip>`
* **BGP session won't establish:** double-check `Router ASN`/`Router IP` match what
  you uploaded to UniFi, and that `no bgp ebgp-requires-policy` is present in the
  uploaded config. Also confirm nothing (e.g. a firewall rule) blocks TCP/179 between
  the Pi and the router.
* **Route not advertised:** confirm the anycast IP is present on `lo`
  (`ip addr show lo`) - if it's missing, the health check thinks Pi-hole is down;
  test manually with `sudo /usr/local/bin/pihole_anycast_check.sh` then re-check.

## Post-Installation Steps

1. Configure DHCP in UniFi Network to hand out the anycast IP as the only DNS server.
2. Synchronize Pi-hole configuration between nodes - this script only handles routing,
   not Pi-hole settings sync. Use [`install-sync.sh`](install-sync.sh) (see
   [README-sync.md](README-sync.md)) for a ready-made Teleporter-API-based sync.
3. Test failover: stop Pi-hole/FTL on one node (`sudo systemctl stop pihole-FTL`),
   confirm the VIP disappears from its `lo` (within `HEALTHCHECK_INTERVAL` seconds),
   confirm `birdc show route` on the other node(s) still shows the anycast route, and
   confirm clients can still resolve DNS via the anycast IP.

## Disclaimer

* This script modifies system configurations, installs software, and expects you to
  make matching changes on your router. Use it at your own risk.
* Always back up your systems and router config before making significant changes.
* BGP configuration on UniFi hardware/firmware may change between UniFi OS releases -
  verify the current menu path and config format against Ubiquiti's documentation if
  the upload is rejected.
