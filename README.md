# Pi-hole High Availability (HA) Setup Scripts

This repository contains scripts for running Pi-hole as a two-node high-availability
(HA) setup, so DNS ad-blocking keeps working if one node goes down. Each script is
interactive: it asks a few questions and handles installation and configuration for
you.

There are two independent parts to set up:

1. **Traffic routing** — how clients keep reaching a working Pi-hole when a node fails.
2. **Configuration sync** — keeping both nodes' block lists and settings identical
   (optional, but recommended).

## 1. Choose a traffic routing method

Two approaches are supported. Both give clients a single DNS server address to use;
they differ in how failover works under the hood.

| | Keepalived (VRRP) | BGP Anycast |
|---|---|---|
| Script | `install.sh` | `install-anycast.sh` **(beta, not yet extensively tested)** |
| How it works | Uses the Virtual Router Redundancy Protocol (VRRP) to move a shared IP address between nodes. Only one node is active at a time. | Both nodes advertise the same IP address to your router via BGP (Border Gateway Protocol). The router sends traffic to whichever node is healthy. |
| Requirements | None — works with any router or switch. | A router that supports BGP (e.g. a UniFi Cloud Gateway running UniFi OS 4.1.13+). |
| Network layout | Both nodes must be on the same local network segment. | Nodes can be on different subnets or VLANs. |
| Documentation | [README_keepalived.md](README_keepalived.md) | [README-anycast.md](README-anycast.md) |

**Not sure which to use?** Start with `install.sh` (Keepalived). It requires no
router-side configuration and is the simpler option.

## 2. Sync configuration between nodes (recommended)

> **Beta:** `install-sync.sh` is not yet extensively tested. Review what it does before
> relying on it, and keep a Teleporter backup handy.

Neither script above keeps Pi-hole's settings — block list subscriptions, allow/deny
domains, groups, local DNS records — in sync between nodes. Without this step, the two
nodes will gradually drift apart as you make changes on one but not the other.

`install-sync.sh` handles this: one node is designated the source of truth, and the
other node(s) periodically pull its settings using Pi-hole's built-in API. See
[README-sync.md](README-sync.md) for details, including why this approach was chosen
over a shared filesystem or `rsync`.

## Prerequisites

- Two or more Raspberry Pis (or similar Debian-based systems), each with Pi-hole
  already installed and a static IP address.
- Root access (`sudo`), and `curl` or `wget` if running a script directly from GitHub.

## Documentation

- [README_keepalived.md](README_keepalived.md) — Keepalived (VRRP) setup
- [README-anycast.md](README-anycast.md) — BGP anycast setup (beta)
- [README-sync.md](README-sync.md) — configuration sync (beta)
