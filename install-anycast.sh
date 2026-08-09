#!/bin/bash

# =====================================================================================
# Interactive Script to Setup BGP Anycast Routing for Pi-hole High Availability
# =====================================================================================
#
# Purpose:
# This script interactively configures 'bird2' on a Raspberry Pi (or similar
# Debian-based system) to act as a node in a BGP anycast HA setup for Pi-hole.
# Instead of a floating VIP (see install.sh / keepalived), EACH node advertises the
# SAME anycast IP (a /32 host route on the loopback interface) to your router via
# eBGP. The router (a UniFi Cloud Gateway, e.g. UCG-Fiber/UDM-Pro/UDM-SE) picks the
# best/only healthy path. A local health check adds or removes the anycast IP on
# 'lo', which causes bird2 to advertise or withdraw the BGP route automatically.
#
# How to Use (Recommended - Directly from GitHub):
# 1. Ensure 'curl' or 'wget' is installed on the Pi:
#    sudo apt update && sudo apt install -y curl wget
# 2. Execute on EACH Pi-hole node, using a different local ASN for each one:
#    curl -sSL https://raw.githubusercontent.com/blackboy69/pihole_ha/main/install-anycast.sh | sudo bash
#    (Replace URL if it's hosted elsewhere or you have a fork)
# 3. Answer the interactive prompts carefully for each Pi.
# 4. Upload the generated UniFi BGP config to your Cloud Gateway (see printed
#    instructions at the end of the script, and README-anycast.md).
#
# How to Use (If Downloaded Locally):
# 1. Save this script (e.g., as 'install-anycast.sh') on each Pi.
# 2. Make it executable: chmod +x install-anycast.sh
# 3. Run as root on EACH Pi: sudo ./install-anycast.sh
# 4. Answer the interactive prompts carefully for each Pi.
#
# Prerequisites:
# - Two (or more) Raspberry Pis (or similar Debian-based systems).
# - Pi-hole installed and functional independently on each Pi.
# - A UniFi Cloud Gateway (UCG-Fiber, UDM-Pro, UDM-SE, UCG-Max/Ultra, UXG-Enterprise)
#   running UniFi OS 4.1.13 or later, which supports uploading an FRR-format BGP
#   config via Settings -> Routing -> BGP -> Create New Route.
# - Network connectivity between the Pis and the router.
# - `sudo` access.
#
# =====================================================================================

# --- Function to prompt for yes/no with a default ---
# Arguments: $1: Prompt text, $2: Default answer ("yes" or "no")
prompt_yes_no() {
    local prompt_text="$1"
    local default_answer="$2"
    local answer

    while true; do
        # Explicitly read from /dev/tty for user interaction
        read -r -p "$prompt_text [$default_answer]: " answer < /dev/tty
        answer="${answer:-$default_answer}" # Default if user just hits Enter
        answer_lower=$(echo "$answer" | tr '[:upper:]' '[:lower:]') # Case-insensitive comparison
        if [[ "$answer_lower" == "yes" || "$answer_lower" == "y" ]]; then
            echo "yes"
            return
        elif [[ "$answer_lower" == "no" || "$answer_lower" == "n" ]]; then
            echo "no"
            return
        else
            echo "Invalid input. Please enter 'yes' or 'no'."
        fi
    done
}

# --- Script Execution Starts Here ---

# Ensure script is run as root, as it performs system-level configurations
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: This script must be run as root. Please use 'sudo' when executing."
  exit 1
fi

echo "============================================================"
echo " Pi-hole HA (BGP Anycast via bird2) Interactive Setup"
echo "============================================================"
echo "This script will guide you through configuring bird2 for THIS Pi so it"
echo "advertises a shared anycast IP to your UniFi Cloud Gateway over eBGP."
echo "You will need to run this script on each of your Pi-hole nodes (each with its"
echo "own local ASN), and then upload a small BGP config file to your Cloud Gateway."
echo # Newline for readability

# --- Gather Configuration Interactively ---
# This section prompts the user for all necessary configuration parameters.
# Note: all nodes are equal peers here - there is no MASTER/BACKUP distinction.
# Every healthy node advertises the anycast route with equal preference, and the
# router picks between them (true active-active anycast, not active/standby).

# 1. NODE_LABEL: A short identifier for this node, used for bird's router id lookup,
# logging, and to tell the generated UniFi config files apart.
DEFAULT_NODE_LABEL="pihole-$(hostname -s 2>/dev/null || echo node)"
read -r -p "Enter a short label for this node (e.g., pihole1) [$DEFAULT_NODE_LABEL]: " NODE_LABEL_INPUT < /dev/tty
NODE_LABEL="${NODE_LABEL_INPUT:-$DEFAULT_NODE_LABEL}"

# 2. MY_INTERFACE: Network interface used to reach the router (BGP transport).
echo
echo "Available network interfaces (excluding loopback 'lo'):"
ip -br a | awk '{print "  - " $1}' | grep -v "lo" # Shows current interfaces with their IPs

# Attempt to auto-detect the default active interface
DEFAULT_INTERFACE=$(ip -4 route ls | grep default | grep -Eo 'dev [^ ]+' | awk '{print $2}' | head -1)
# Fallback to the first non-loopback interface if no default route is found
if [ -z "$DEFAULT_INTERFACE" ]; then
    DEFAULT_INTERFACE=$(ls /sys/class/net | grep -v "lo" | head -n 1)
fi

echo "Ensure you choose the interface connected to your main LAN, on the same"
echo "network as your UniFi Cloud Gateway."
while true; do
  read -r -p "Enter the network interface name used to reach the router [$DEFAULT_INTERFACE]: " MY_INTERFACE_INPUT < /dev/tty
  MY_INTERFACE="${MY_INTERFACE_INPUT:-$DEFAULT_INTERFACE}"
  if [ -z "$MY_INTERFACE" ]; then
    echo "Interface name cannot be empty."
  elif ! ip link show "$MY_INTERFACE" > /dev/null 2>&1; then # Check if interface exists
    echo "ERROR: Interface '$MY_INTERFACE' does not appear to exist. Please verify the name."
  else
    break
  fi
done

# Determine this node's current IP on that interface (used as the bird router id
# and as the neighbor address the router will peer with).
MY_CURRENT_IP=$(ip -4 addr show dev "$MY_INTERFACE" 2>/dev/null | grep -w inet | awk '{print $2}' | cut -d/ -f1 | head -n 1)
if [ -z "$MY_CURRENT_IP" ]; then
  echo "ERROR: Could not determine an IPv4 address on interface '$MY_INTERFACE'. Please configure a static IP first."
  exit 1
fi
echo "This node's IP on $MY_INTERFACE: $MY_CURRENT_IP (this is the BGP neighbor address for the router config)."

# 3. LOCAL_ASN: This node's own private BGP AS number. Each node needs a UNIQUE ASN
# (this is single-hop eBGP, one small AS per Pi-hole, peering with the router's AS).
DEFAULT_LOCAL_ASN="65001"
echo
echo "--- BGP Settings ---"
echo "Each Pi-hole node needs its own private ASN (recommended range 64512-65534),"
echo "different from every other Pi-hole node and from the router's ASN (e.g. 65001,"
echo "65002, 65003, ... - one per node)."
while true; do
  read -r -p "Enter this node's local ASN [$DEFAULT_LOCAL_ASN]: " LOCAL_ASN_INPUT < /dev/tty
  LOCAL_ASN="${LOCAL_ASN_INPUT:-$DEFAULT_LOCAL_ASN}"
  if [[ "$LOCAL_ASN" =~ ^[0-9]+$ ]]; then
    break
  else
    echo "Invalid input. ASN must be a positive number."
  fi
done

# 4. ROUTER_ASN / ROUTER_IP: The UniFi Cloud Gateway's BGP ASN and LAN IP.
# These MUST be identical on both Pi-hole nodes.
echo
echo "--- Router Settings (these MUST be identical on both Pi-hole HA nodes) ---"
DEFAULT_ROUTER_ASN="65000"
while true; do
  read -r -p "Enter the router's (UniFi Cloud Gateway) ASN [$DEFAULT_ROUTER_ASN]: " ROUTER_ASN_INPUT < /dev/tty
  ROUTER_ASN="${ROUTER_ASN_INPUT:-$DEFAULT_ROUTER_ASN}"
  if [[ "$ROUTER_ASN" =~ ^[0-9]+$ ]]; then
    break
  else
    echo "Invalid input. ASN must be a positive number."
  fi
done

DEFAULT_ROUTER_IP=$(ip -4 route ls | grep default | grep -Eo 'via [^ ]+' | awk '{print $2}' | head -1)
while true; do
  read -r -p "Enter the router's LAN IP (BGP neighbor address) [$DEFAULT_ROUTER_IP]: " ROUTER_IP_INPUT < /dev/tty
  ROUTER_IP="${ROUTER_IP_INPUT:-$DEFAULT_ROUTER_IP}"
  if [[ "$ROUTER_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    break
  else
    echo "Invalid IP address format. Please use format X.X.X.X (e.g., 192.168.1.1)."
  fi
done

# 5. ANYCAST_IP: The shared host address both nodes will advertise via BGP.
# This does NOT need to be inside your LAN subnet - it is reached via a routed
# /32, not ARP - but it must not collide with any other address you use.
echo
echo "--- Anycast Address (must be identical on both Pi-hole HA nodes) ---"
echo "This is the single IP address your clients will use as their DNS server."
echo "It is advertised as a /32 route by whichever node(s) are currently healthy."
DEFAULT_ANYCAST_IP="10.10.53.53"
while true; do
  read -r -p "Enter the shared anycast IP address [$DEFAULT_ANYCAST_IP]: " ANYCAST_IP_INPUT < /dev/tty
  ANYCAST_IP="${ANYCAST_IP_INPUT:-$DEFAULT_ANYCAST_IP}"
  if [[ "$ANYCAST_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    break
  else
    echo "Invalid IP address format. Please use format X.X.X.X (e.g., 10.10.53.53)."
  fi
done

# 6. HEALTHCHECK_INTERVAL: How often (seconds) to check Pi-hole and toggle the VIP.
DEFAULT_HC_INTERVAL="2"
read -r -p "Enter health check interval in seconds [$DEFAULT_HC_INTERVAL]: " HC_INTERVAL_INPUT < /dev/tty
HEALTHCHECK_INTERVAL="${HC_INTERVAL_INPUT:-$DEFAULT_HC_INTERVAL}"
if ! [[ "$HEALTHCHECK_INTERVAL" =~ ^[0-9]+$ ]]; then
  HEALTHCHECK_INTERVAL="$DEFAULT_HC_INTERVAL"
fi

# --- Display Summary and Confirm Before Proceeding ---
echo
echo "============================================================"
echo " Configuration Summary for this Pi:"
echo "------------------------------------------------------------"
echo " Node Label:        $NODE_LABEL"
echo " Interface:          $MY_INTERFACE ($MY_CURRENT_IP)"
echo " Local ASN:           $LOCAL_ASN"
echo "------------------------------------------------------------"
echo " Shared Settings (verify these are identical on both nodes):"
echo " Anycast IP:          $ANYCAST_IP/32"
echo " Router ASN:          $ROUTER_ASN"
echo " Router IP (neighbor): $ROUTER_IP"
echo " Health check interval: ${HEALTHCHECK_INTERVAL}s"
echo "============================================================"
CONFIRMATION=$(prompt_yes_no "Proceed with this configuration and install/configure bird2?" "yes")

if [[ "$CONFIRMATION" != "yes" ]]; then
  echo "Setup aborted by user. No changes were made."
  exit 1
fi

# --- Start Actual System Setup ---
# The following sections install packages and write configuration files.

CURRENT_SCRIPT_PHASE=1 # Initialize the phase counter, first phase will be 2.

# --- Phase: bird2 Install ---
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Updating package lists and installing bird2..."
apt update > /dev/null 2>&1 # Suppress apt update output for cleaner logs
if apt install -y bird2; then
  echo "SUCCESS: Packages installed."
else
  echo "ERROR: Failed to install packages. Please check for errors above. Exiting."
  exit 1
fi
systemctl stop bird > /dev/null 2>&1 # Stop while we (re)configure it

# --- Phase: Health Check + Anycast VIP Toggle Script ---
# This script checks whether Pi-hole's DNS resolver (port 53) is up and, based on
# the result, adds or removes the anycast IP on 'lo'. bird2's "direct" protocol
# only advertises routes for addresses that actually exist on the interface, so
# adding/removing the address is what triggers BGP advertise/withdraw.
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Creating Pi-hole anycast health check script at /usr/local/bin/pihole_anycast_check.sh..."

cat << EOF_HEALTHCHECK > /usr/local/bin/pihole_anycast_check.sh
#!/bin/bash
# Health check + anycast VIP toggle script for Pi-hole HA (BGP anycast).
# Generated by install-anycast.sh - re-run the installer to change settings.
# Checks the kernel to see if port 53 (TCP or UDP) is actively listening, then
# adds/removes the anycast IP on lo so bird2 advertises/withdraws the BGP route.

VIP_ADDR="$ANYCAST_IP"
VIP_IFACE="lo"

has_vip() {
  ip -4 addr show dev "\$VIP_IFACE" | grep -qw "\$VIP_ADDR"
}

if ss -lntu | grep -q -E '(:53\s)'; then
  # Pi-hole (or another DNS resolver) is listening - node is healthy.
  if ! has_vip; then
    if ip addr add "\$VIP_ADDR/32" dev "\$VIP_IFACE" 2>/dev/null; then
      logger -t pihole_anycast "Pi-hole healthy: added \$VIP_ADDR/32 to \$VIP_IFACE"
    fi
  fi
else
  # DNS not listening - node is unhealthy, withdraw the anycast address.
  if has_vip; then
    if ip addr del "\$VIP_ADDR/32" dev "\$VIP_IFACE" 2>/dev/null; then
      logger -t pihole_anycast "Pi-hole unhealthy: removed \$VIP_ADDR/32 from \$VIP_IFACE"
    fi
  fi
fi
EOF_HEALTHCHECK

chmod +x /usr/local/bin/pihole_anycast_check.sh
if [ -f /usr/local/bin/pihole_anycast_check.sh ]; then
  echo "SUCCESS: Pi-hole anycast health check script created and made executable."
else
  echo "ERROR: Failed to create health check script. Exiting."
  exit 1
fi

# --- Phase: systemd timer to run the health check periodically ---
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Creating systemd service/timer to run the health check every ${HEALTHCHECK_INTERVAL}s..."

cat << EOF_HC_SERVICE > /etc/systemd/system/pihole-anycast-check.service
[Unit]
Description=Pi-hole anycast health check (adds/removes $ANYCAST_IP/32 on lo)
After=network-online.target pihole-FTL.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pihole_anycast_check.sh
EOF_HC_SERVICE

cat << EOF_HC_TIMER > /etc/systemd/system/pihole-anycast-check.timer
[Unit]
Description=Run Pi-hole anycast health check every ${HEALTHCHECK_INTERVAL}s

[Timer]
OnBootSec=5
OnUnitActiveSec=${HEALTHCHECK_INTERVAL}s
AccuracySec=1s
Unit=pihole-anycast-check.service

[Install]
WantedBy=timers.target
EOF_HC_TIMER

systemctl daemon-reload
if systemctl enable --now pihole-anycast-check.timer > /dev/null 2>&1; then
  echo "SUCCESS: pihole-anycast-check.timer enabled and started."
else
  echo "ERROR: Failed to enable pihole-anycast-check.timer. Exiting."
  exit 1
fi
# Run once immediately so the VIP is present (if healthy) before bird2 starts.
systemctl start pihole-anycast-check.service

# --- Phase: Configure bird2 ---
# This generates /etc/bird/bird.conf. bird2's "direct" protocol picks up the
# anycast address once the health check script adds it to lo, and re-advertises
# (or withdraws) the /32 route to the router over eBGP accordingly.
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Creating bird2 configuration file (/etc/bird/bird.conf)..."

cat << EOF_BIRD_CONF > /etc/bird/bird.conf
# This file is managed by the Pi-hole HA anycast setup script (install-anycast.sh).
# Manual edits may be overwritten if the script is run again.
# Node: $NODE_LABEL
# Interface: $MY_INTERFACE

log syslog all;
router id $MY_CURRENT_IP;

protocol device {
}

# Picks up the anycast address once pihole_anycast_check.sh adds it to 'lo'.
protocol direct anycast_vip {
    interface "lo";
    ipv4;
}

# Do not let bird install routes learned from the router into the kernel table -
# this node only originates the anycast route, it does not need to consume BGP
# routes from the router.
protocol kernel {
    ipv4 {
        export none;
    };
}

# Only ever advertise the single anycast /32 - never anything else on lo (e.g. 127.0.0.1).
# All nodes export with equal preference - true active-active anycast, no
# MASTER/BACKUP path preference. The router picks between whichever node(s)
# are currently advertising the route.
filter export_anycast_vip {
    if net = $ANYCAST_IP/32 then {
        accept;
    }
    reject;
}

protocol bgp udm_gateway {
    local as $LOCAL_ASN;
    neighbor $ROUTER_IP as $ROUTER_ASN;
    hold time 9;         # Fast-ish failure detection; tune if the session flaps.
    keepalive time 3;
    ipv4 {
        import none;               # We don't need routes from the router, just to originate ours.
        export filter export_anycast_vip;
    };
}
EOF_BIRD_CONF

if [ -f /etc/bird/bird.conf ]; then
  echo "SUCCESS: bird2 configuration file created at /etc/bird/bird.conf."
  chmod 640 /etc/bird/bird.conf
else
  echo "ERROR: Failed to create /etc/bird/bird.conf. Exiting."
  exit 1
fi

# --- Phase: Enable and Start/Restart bird2 Service ---
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Enabling and restarting bird2 service..."
systemctl enable bird > /dev/null 2>&1 # Ensure it starts on boot
if systemctl restart bird; then
  echo "SUCCESS: bird2 service enabled and restarted."
else
  echo "ERROR: Failed to restart bird2 service."
  echo "Please check its status with: systemctl status bird"
  echo "And review logs with: journalctl -u bird"
  exit 1
fi

# --- Phase: Generate UniFi Cloud Gateway BGP config snippet ---
# UniFi OS (4.1.13+) accepts BGP config only as an uploaded plain-text FRR-format
# file (Settings -> Routing -> BGP -> Create New Route) - there is no per-neighbor
# "add" in the GUI. Because this script only knows about THIS node, it writes out
# a per-node neighbor snippet, and a best-effort combined file if a snippet from
# the other node is already present from a previous run copied into this folder.
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Generating UniFi Cloud Gateway BGP config snippet..."

OUT_DIR="/root/pihole_ha_anycast"
mkdir -p "$OUT_DIR"
SNIPPET_FILE="$OUT_DIR/unifi-bgp-neighbor-$NODE_LABEL.conf"

cat << EOF_SNIPPET > "$SNIPPET_FILE"
neighbor $MY_CURRENT_IP remote-as $LOCAL_ASN
EOF_SNIPPET

COMBINED_FILE="$OUT_DIR/unifi-bgp-combined.conf"
cat << EOF_COMBINED_HEADER > "$COMBINED_FILE"
! UniFi Cloud Gateway BGP config for Pi-hole anycast DNS.
! Upload via: UniFi Network -> Settings -> Routing -> BGP -> Create New Route
! (requires UniFi OS 4.1.13+). This REPLACES any previously uploaded config for
! that route entry, so combine ALL of your Pi-hole nodes' neighbor lines below
! before uploading - do not upload one node's snippet at a time.
router bgp $ROUTER_ASN
 bgp router-id $ROUTER_IP
 no bgp ebgp-requires-policy
 neighbor $MY_CURRENT_IP remote-as $LOCAL_ASN
 !!! Add a "neighbor <other-pi-ip> remote-as <other-pi-asn>" line here for each additional Pi-hole node !!!
 !
 address-family ipv4 unicast
  neighbor $MY_CURRENT_IP activate
  !!! Add a matching "neighbor <other-pi-ip> activate" line here for each additional Pi-hole node !!!
 exit-address-family
!
EOF_COMBINED_HEADER

echo "SUCCESS: Wrote $SNIPPET_FILE and a starter combined config at $COMBINED_FILE."

# --- Final Status Check and Information ---
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Final checks and important information..."
sleep 3 # Give bird2 a moment to stabilize and attempt the BGP session

echo "Current bird2 service status:"
systemctl status bird --no-pager | grep -E 'Active:' # Shows active status

echo
echo "To verify the anycast VIP is present on this node (only if Pi-hole is healthy), run:"
echo "  ip addr show lo | grep '$ANYCAST_IP'"
echo "To check the BGP session and advertised routes, run:"
echo "  birdc show protocols"
echo "  birdc show route"
echo "To monitor bird2 logs in real-time, run:"
echo "  journalctl -u bird -f"
echo

echo "============================================================"
echo " Script Finished for this Node!"
echo "============================================================"
echo " IMPORTANT NEXT STEPS:"
echo " 1. If you haven't already, run this script (answering prompts appropriately"
echo "    for that node, with a DIFFERENT local ASN) on your OTHER Pi-hole node."
echo " 2. Combine the neighbor lines from every node into ONE config file - see"
echo "    $COMBINED_FILE for a starter template - then upload it to your"
echo "    UniFi Cloud Gateway at:"
echo "      UniFi Network -> Settings -> Routing -> BGP -> Create New Route"
echo "    (Requires UniFi OS 4.1.13+ on UCG-Fiber/UDM-Pro/UDM-SE/UCG-Max/Ultra/UXG-Enterprise.)"
echo "    Re-uploading REPLACES the previous config for that route entry, so always"
echo "    upload the full combined file, not a single node's snippet."
echo " 3. Configure your DHCP server (in UniFi Network) to hand out the anycast IP"
echo "    ($ANYCAST_IP) as the ONLY DNS server for your clients."
echo " 4. Implement a method to synchronize Pi-hole configurations (adlists,"
echo "    blocklists, whitelists, etc.) between your Pi-hole nodes. This script does"
echo "    NOT handle Pi-hole settings synchronization. Use install-sync.sh (see"
echo "    README-sync.md in this repo) for a ready-made Teleporter-API-based sync."
echo " 5. See README-anycast.md in this repo for troubleshooting and more detail"
echo "    on how BGP anycast failover works compared to the keepalived VIP approach."
echo "============================================================"
