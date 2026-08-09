#!/bin/bash

# =====================================================================================
# Interactive Script to Setup Pi-hole Config Synchronization (Teleporter API)
# =====================================================================================
#
# Purpose:
# install.sh and install-anycast.sh only handle DNS traffic failover/routing - neither
# keeps your Pi-hole SETTINGS (adlists, allow/deny domain lists, groups, local DNS
# records, reverse DNS rules, blocking behavior) in sync between nodes. This script
# fills that gap using two separate Pi-hole v6 APIs, on a one-way, scheduled pull from
# a SOURCE node (wherever you make edits):
#   1. Teleporter (/api/teleporter) - gravity data only: adlist subscriptions,
#      blacklist/whitelist domain entries, and the groups they belong to (NOT
#      per-client group assignments). Teleporter's "config" scope is all-or-nothing
#      and would overwrite this node's own network/interface/DHCP/webserver settings,
#      so it's never used here.
#   2. The granular config API (/api/config/dns) - local DNS records (custom hosts +
#      CNAMEs), reverse DNS/conditional forwarding rules (revServers), blocking
#      behavior, special-domain toggles, and the local domain suffix. These are
#      LAN-wide/behavioral settings, not per-node identity, so this endpoint lets us
#      PATCH just these specific fields, leaving everything else on this node alone.
# No shared filesystem and no direct manipulation of Pi-hole's internal database files.
#
# How to Use (Recommended - Directly from GitHub):
# 1. In the Pi-hole web UI of EACH node (SOURCE and every REPLICA), create an "app
#    password": Settings -> Web Interface/API -> switch to Expert mode -> Configure
#    app password. Save each one somewhere safe - Pi-hole only shows it once.
# 2. Run this script on your SOURCE node first (the node where you make config
#    changes) - it just prints a reminder, no changes are made:
#      curl -sSL https://raw.githubusercontent.com/blackboy69/pihole_ha/main/install-sync.sh | sudo bash
# 3. Run this script on EACH REPLICA node, answering the prompts (SOURCE URL, SOURCE
#    app password, this node's own URL/app password, sync interval).
#
# How to Use (If Downloaded Locally):
# 1. Save this script (e.g., as 'install-sync.sh') on each Pi.
# 2. Make it executable: chmod +x install-sync.sh
# 3. Run as root: sudo ./install-sync.sh
#
# Prerequisites:
# - Pi-hole v6 (this script uses v6-only REST endpoints: POST /api/auth,
#   GET/POST /api/teleporter, and GET/PATCH /api/config/dns - none of these exist on
#   Pi-hole v5).
# - An "app password" created in the web UI of the SOURCE node AND of every REPLICA
#   node (Settings -> Web Interface/API -> Expert mode -> Configure app password).
# - Network connectivity from each REPLICA to the SOURCE node's web/API port.
# - `sudo` access, and `curl`/`wget` if running directly from GitHub.
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
echo " Pi-hole HA Config Sync (Teleporter API) Interactive Setup"
echo "============================================================"
echo "This keeps Pi-hole SETTINGS (adlist subscriptions, allow/deny domain entries,"
echo "groups, local DNS records/CNAMEs, reverse DNS rules, and blocking behavior) in"
echo "sync between nodes. It is separate from - and complements - install.sh"
echo "(keepalived) or install-anycast.sh (BGP anycast), which only handle DNS traffic"
echo "routing."
echo # Newline for readability

# 1. ROLE: SOURCE (where you make config changes) or REPLICA (pulls from SOURCE).
while true; do
  read -r -p "Is this node the config SOURCE (where you make changes) or a REPLICA (pulls from SOURCE)? (Enter SOURCE or REPLICA): " MY_ROLE_INPUT < /dev/tty
  MY_ROLE=$(echo "$MY_ROLE_INPUT" | tr '[:lower:]' '[:upper:]') # Standardize to uppercase
  if [[ "$MY_ROLE" == "SOURCE" || "$MY_ROLE" == "REPLICA" ]]; then
    break
  else
    echo "Invalid input. Please enter 'SOURCE' or 'REPLICA'."
  fi
done

if [ "$MY_ROLE" == "SOURCE" ]; then
  echo
  echo "============================================================"
  echo " Nothing to install here - this node is the config SOURCE."
  echo "============================================================"
  echo "Make sure you've created an app password for THIS node's Pi-hole:"
  echo "  Pi-hole web UI -> Settings -> Web Interface/API -> Expert mode ->"
  echo "  'Configure app password'. Save the value shown - Pi-hole only displays it"
  echo "  once. You'll enter this node's URL and that app password when you run this"
  echo "  script on each REPLICA node."
  echo
  echo "Continue making your Pi-hole config changes (adlists, allow/deny domains,"
  echo "groups, local DNS records) on THIS node as usual - REPLICA nodes will pull"
  echo "them on their own schedule."
  echo "See README-sync.md in this repo for more detail."
  echo "============================================================"
  exit 0
fi

# --- ROLE == REPLICA: gather configuration to pull from SOURCE ---

if [ ! -d /etc/pihole ]; then
  echo
  echo "WARNING: /etc/pihole was not found on this node - Pi-hole does not appear to"
  echo "be installed here yet. This script imports INTO the local Pi-hole, so it needs"
  echo "Pi-hole to already be installed and running."
  PROCEED_NO_PIHOLE=$(prompt_yes_no "Continue anyway?" "no")
  if [[ "$PROCEED_NO_PIHOLE" != "yes" ]]; then
    echo "Setup aborted by user. No changes were made."
    exit 1
  fi
fi

echo
echo "--- SOURCE Node Settings ---"
echo "The SOURCE is the node where you make Pi-hole config changes (adlists,"
echo "allow/deny domains, groups). This REPLICA will periodically pull a Teleporter"
echo "export from it."
while true; do
  read -r -p "Enter the SOURCE Pi-hole's base URL (e.g., http://192.168.1.101): " REMOTE_URL_INPUT < /dev/tty
  REMOTE_URL="${REMOTE_URL_INPUT%/}" # Strip any trailing slash
  if [[ "$REMOTE_URL" =~ ^https?://.+ ]]; then
    break
  else
    echo "Invalid input. Please include the scheme, e.g. http://192.168.1.101 or https://192.168.1.101."
  fi
done

while true; do
  read -s -r -p "Enter the SOURCE node's app password: " REMOTE_APP_PASSWORD_INPUT < /dev/tty
  echo
  read -s -r -p "Confirm the SOURCE node's app password: " REMOTE_APP_PASSWORD_CONFIRM < /dev/tty
  echo
  if [ -z "$REMOTE_APP_PASSWORD_INPUT" ]; then
    echo "App password cannot be empty. Please try again."
  elif [ "$REMOTE_APP_PASSWORD_INPUT" == "$REMOTE_APP_PASSWORD_CONFIRM" ]; then
    REMOTE_APP_PASSWORD="$REMOTE_APP_PASSWORD_INPUT"
    break
  else
    echo "Values do not match. Please try again."
  fi
done

echo
echo "--- This Node's (REPLICA) Own API Settings ---"
echo "Teleporter import happens through this Pi-hole's OWN local API, so it also"
echo "needs its own app password (create one in this node's web UI first, if you"
echo "haven't already: Settings -> Web Interface/API -> Expert mode -> 'Configure"
echo "app password')."
DEFAULT_LOCAL_URL="http://127.0.0.1"
read -r -p "Enter this node's own Pi-hole base URL [$DEFAULT_LOCAL_URL]: " LOCAL_URL_INPUT < /dev/tty
LOCAL_URL_INPUT="${LOCAL_URL_INPUT:-$DEFAULT_LOCAL_URL}"
LOCAL_URL="${LOCAL_URL_INPUT%/}" # Strip any trailing slash

while true; do
  read -s -r -p "Enter this node's own app password: " LOCAL_APP_PASSWORD_INPUT < /dev/tty
  echo
  read -s -r -p "Confirm this node's own app password: " LOCAL_APP_PASSWORD_CONFIRM < /dev/tty
  echo
  if [ -z "$LOCAL_APP_PASSWORD_INPUT" ]; then
    echo "App password cannot be empty. Please try again."
  elif [ "$LOCAL_APP_PASSWORD_INPUT" == "$LOCAL_APP_PASSWORD_CONFIRM" ]; then
    LOCAL_APP_PASSWORD="$LOCAL_APP_PASSWORD_INPUT"
    break
  else
    echo "Values do not match. Please try again."
  fi
done

echo
echo "--- Sync Scope ---"
echo "Adlist subscriptions, blacklist/whitelist domain entries, and the groups they"
echo "belong to are synced via Teleporter - not per-client group assignments. General"
echo "Pi-hole settings (network/interface/DHCP/webserver config) are NEVER synced by"
echo "this script - Teleporter's only switch for that is all-or-nothing, and turning"
echo "it on would overwrite this node's own network identity to match the SOURCE."
echo
echo "A handful of other DNS settings CAN be synced separately and safely too, via"
echo "narrow API calls that only ever touch these specific fields - never this node's"
echo "own network/interface/DHCP/webserver settings:"
echo "  - Local DNS records (custom A/AAAA hosts and CNAMEs), copied verbatim. If you"
echo "    use fixed per-node hostnames (e.g. 'pihole1.local'/'pihole2.local' each"
echo "    pointing at a specific node's real IP), those stay correct on every node."
echo "  - Reverse DNS / conditional forwarding rules (revServers) - which local"
echo "    subnets/VLANs to reverse-resolve and where."
echo "  - Blocking behavior (active/mode/EDNS) and special-domain toggles (Mozilla"
echo "    canary, iCloud Private Relay, designated resolver)."
echo "  - The local domain suffix (e.g. 'lan' or 'local')."
echo "These are LAN-wide/behavioral settings, not per-node identity, so they're safe"
echo "to keep identical across nodes. Recommended if you've customized any of them."
SYNC_DNS_SETTINGS=$(prompt_yes_no "Also sync these DNS settings (local records, revServers, blocking, domain)?" "yes")

echo
DEFAULT_SYNC_INTERVAL="5"
while true; do
  read -r -p "Enter sync interval in minutes [$DEFAULT_SYNC_INTERVAL]: " SYNC_INTERVAL_INPUT < /dev/tty
  SYNC_INTERVAL_MINUTES="${SYNC_INTERVAL_INPUT:-$DEFAULT_SYNC_INTERVAL}"
  if [[ "$SYNC_INTERVAL_MINUTES" =~ ^[0-9]+$ && "$SYNC_INTERVAL_MINUTES" -ge 1 ]]; then
    break
  else
    echo "Invalid input. Must be a whole number of minutes, 1 or greater."
  fi
done

# --- Display Summary and Confirm Before Proceeding ---
echo
echo "============================================================"
echo " Configuration Summary for this REPLICA:"
echo "------------------------------------------------------------"
echo " SOURCE URL:          $REMOTE_URL"
echo " This node's URL:     $LOCAL_URL"
echo " Sync DNS settings:   $SYNC_DNS_SETTINGS"
echo " Sync interval:       every ${SYNC_INTERVAL_MINUTES} minute(s)"
echo "============================================================"
CONFIRMATION=$(prompt_yes_no "Proceed with this configuration and install the sync timer?" "yes")

if [[ "$CONFIRMATION" != "yes" ]]; then
  echo "Setup aborted by user. No changes were made."
  exit 1
fi

# --- Start Actual System Setup ---

CURRENT_SCRIPT_PHASE=1 # Initialize the phase counter, first phase will be 2.

# --- Phase: Install curl + jq ---
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Updating package lists and installing curl and jq..."
apt update > /dev/null 2>&1
if apt install -y curl jq; then
  echo "SUCCESS: Packages installed."
else
  echo "ERROR: Failed to install packages. Please check for errors above. Exiting."
  exit 1
fi

# --- Phase: Write sync credentials/config file ---
# Stored separately from the sync script itself (like keepalived.conf's AUTH_PASS)
# so credentials can be rotated without regenerating the script, and locked down to
# root-only (600). Values are written with `%q` shell-quoting so passwords containing
# $, ", `, or other special characters survive being re-sourced correctly.
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Writing sync configuration to /etc/pihole-ha-sync/sync.conf..."

mkdir -p /etc/pihole-ha-sync

{
  echo "# This file is managed by the Pi-hole HA sync setup script (install-sync.sh)."
  echo "# Manual edits may be overwritten if the script is run again. Contains secrets - keep mode 600."
  printf 'REMOTE_URL=%q\n' "$REMOTE_URL"
  printf 'REMOTE_APP_PASSWORD=%q\n' "$REMOTE_APP_PASSWORD"
  printf 'LOCAL_URL=%q\n' "$LOCAL_URL"
  printf 'LOCAL_APP_PASSWORD=%q\n' "$LOCAL_APP_PASSWORD"
  printf 'SYNC_DNS_SETTINGS=%q\n' "$SYNC_DNS_SETTINGS"
} > /etc/pihole-ha-sync/sync.conf

if [ -f /etc/pihole-ha-sync/sync.conf ]; then
  chmod 600 /etc/pihole-ha-sync/sync.conf
  chown root:root /etc/pihole-ha-sync/sync.conf
  echo "SUCCESS: Wrote /etc/pihole-ha-sync/sync.conf (mode 600, root-owned)."
else
  echo "ERROR: Failed to write /etc/pihole-ha-sync/sync.conf. Exiting."
  exit 1
fi

# --- Phase: Write the sync script ---
# Pulls a Teleporter export from SOURCE, then imports it into this node's own local
# Pi-hole via its own API (Teleporter import always goes through the LOCAL API, even
# though the data came from elsewhere) - see README-sync.md for why two separate API
# sessions are needed.
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Creating sync script at /usr/local/bin/pihole_sync.sh..."

cat << 'EOF_SYNC_SCRIPT' > /usr/local/bin/pihole_sync.sh
#!/bin/bash
# Pi-hole HA config sync script (Teleporter API pull from SOURCE).
# Generated by install-sync.sh - re-run the installer to change settings, or edit
# /etc/pihole-ha-sync/sync.conf directly to rotate credentials.

CONF_FILE="/etc/pihole-ha-sync/sync.conf"
if [ ! -f "$CONF_FILE" ]; then
  logger -t pihole_sync "ERROR: config file $CONF_FILE not found"
  echo "ERROR: config file $CONF_FILE not found" >&2
  exit 1
fi
# shellcheck disable=SC1090
source "$CONF_FILE"

log() { logger -t pihole_sync "$1"; }
fail() {
  log "ERROR: $1"
  echo "ERROR: $1" >&2
  exit 1
}

TMP_ZIP=$(mktemp /tmp/pihole_teleporter_XXXXXX.zip)
REMOTE_AUTH_RESP=$(mktemp)
LOCAL_AUTH_RESP=$(mktemp)
IMPORT_RESP=$(mktemp)
DNS_GET_RESP=$(mktemp)
DNS_PATCH_RESP=$(mktemp)
cleanup() { rm -f "$TMP_ZIP" "$REMOTE_AUTH_RESP" "$LOCAL_AUTH_RESP" "$IMPORT_RESP" "$DNS_GET_RESP" "$DNS_PATCH_RESP" 2>/dev/null || true; }
trap cleanup EXIT

DNS_SETTINGS_SYNC_OK="skipped"

# --- Authenticate to SOURCE ---
REMOTE_HTTP_CODE=$(curl -sk -o "$REMOTE_AUTH_RESP" -w '%{http_code}' -X POST "$REMOTE_URL/api/auth" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg password "$REMOTE_APP_PASSWORD" '{password:$password}')")
[ "$REMOTE_HTTP_CODE" = "200" ] || fail "Could not authenticate to SOURCE ($REMOTE_URL) - HTTP $REMOTE_HTTP_CODE"
REMOTE_SID=$(jq -r '.session.sid // empty' "$REMOTE_AUTH_RESP")
[ -n "$REMOTE_SID" ] || fail "SOURCE auth response did not contain a session id"

# --- While authenticated to SOURCE: read the DNS settings we sync, if enabled ---
# Uses the narrow /api/config/dns endpoint, NOT Teleporter's all-or-nothing "config"
# scope - this only ever reads/writes these specific fields, nothing else (not
# interface, DHCP, webserver/API, or upstream resolver settings).
if [ "$SYNC_DNS_SETTINGS" = "yes" ]; then
  DNS_GET_HTTP_CODE=$(curl -sk -o "$DNS_GET_RESP" -w '%{http_code}' -H "X-FTL-SID: $REMOTE_SID" "$REMOTE_URL/api/config/dns")
  if [ "$DNS_GET_HTTP_CODE" != "200" ]; then
    log "WARNING: could not read DNS settings from SOURCE - HTTP $DNS_GET_HTTP_CODE"
    echo "WARNING: could not read DNS settings from SOURCE - HTTP $DNS_GET_HTTP_CODE" >&2
    DNS_SETTINGS_SYNC_OK="failed"
  else
    # hosts/cnameRecords are copied verbatim - homelab "hosts" entries are typically
    # static infrastructure mappings (e.g. fixed per-node names like
    # "pihole1.local"/"pihole2.local" each pointing at a specific node's real IP,
    # plus entries for other devices on the network), not self-referencing records
    # that should change per node.
    REMOTE_DNS_HOSTS=$(jq -c '.config.dns.hosts // []' "$DNS_GET_RESP")
    REMOTE_DNS_CNAMES=$(jq -c '.config.dns.cnameRecords // []' "$DNS_GET_RESP")
    # revServers, blocking, specialDomains, and domain are LAN-wide/behavioral
    # settings (not per-node identity), so they're safe to keep identical too.
    REMOTE_DNS_REVSERVERS=$(jq -c '.config.dns.revServers // []' "$DNS_GET_RESP")
    REMOTE_DNS_BLOCKING=$(jq -c '.config.dns.blocking // {}' "$DNS_GET_RESP")
    REMOTE_DNS_SPECIALDOMAINS=$(jq -c '.config.dns.specialDomains // {}' "$DNS_GET_RESP")
    REMOTE_DNS_DOMAIN=$(jq -r '.config.dns.domain // "lan"' "$DNS_GET_RESP")
  fi
fi

# --- Export Teleporter archive from SOURCE ---
EXPORT_HTTP_CODE=$(curl -sk -o "$TMP_ZIP" -w '%{http_code}' -H "X-FTL-SID: $REMOTE_SID" "$REMOTE_URL/api/teleporter")
curl -sk -X DELETE -H "X-FTL-SID: $REMOTE_SID" "$REMOTE_URL/api/auth" > /dev/null 2>&1 || true
[ "$EXPORT_HTTP_CODE" = "200" ] || fail "Teleporter export from SOURCE failed - HTTP $EXPORT_HTTP_CODE"
[ -s "$TMP_ZIP" ] || fail "Teleporter export from SOURCE was empty"

# --- Authenticate to this node's own (local) API ---
LOCAL_HTTP_CODE=$(curl -sk -o "$LOCAL_AUTH_RESP" -w '%{http_code}' -X POST "$LOCAL_URL/api/auth" \
  -H "Content-Type: application/json" \
  -d "$(jq -n --arg password "$LOCAL_APP_PASSWORD" '{password:$password}')")
[ "$LOCAL_HTTP_CODE" = "200" ] || fail "Could not authenticate to local Pi-hole API ($LOCAL_URL) - HTTP $LOCAL_HTTP_CODE"
LOCAL_SID=$(jq -r '.session.sid // empty' "$LOCAL_AUTH_RESP")
[ -n "$LOCAL_SID" ] || fail "Local auth response did not contain a session id"

# --- Apply DNS settings FIRST, while this session is fresh ---
# (Teleporter import below can trigger an FTL restart, which may invalidate the
# session - so anything using LOCAL_SID that we still need has to happen before it.)
if [ "$SYNC_DNS_SETTINGS" = "yes" ] && [ -n "${REMOTE_DNS_HOSTS:-}" ]; then
  DNS_PATCH_HTTP_CODE=$(curl -sk -o "$DNS_PATCH_RESP" -w '%{http_code}' -X PATCH -H "X-FTL-SID: $LOCAL_SID" \
    -H "Content-Type: application/json" \
    -d "$(jq -n \
      --argjson hosts "$REMOTE_DNS_HOSTS" \
      --argjson cnames "$REMOTE_DNS_CNAMES" \
      --argjson revservers "$REMOTE_DNS_REVSERVERS" \
      --argjson blocking "$REMOTE_DNS_BLOCKING" \
      --argjson specialdomains "$REMOTE_DNS_SPECIALDOMAINS" \
      --arg domain "$REMOTE_DNS_DOMAIN" \
      '{config:{dns:{hosts:$hosts,cnameRecords:$cnames,revServers:$revservers,blocking:$blocking,specialDomains:$specialdomains,domain:$domain}}}')" \
    "$LOCAL_URL/api/config")
  if [ "$DNS_PATCH_HTTP_CODE" = "200" ]; then
    DNS_SETTINGS_SYNC_OK="ok"
  else
    log "WARNING: DNS settings sync failed - HTTP $DNS_PATCH_HTTP_CODE ($(cat "$DNS_PATCH_RESP" 2>/dev/null))"
    echo "WARNING: DNS settings sync failed - HTTP $DNS_PATCH_HTTP_CODE" >&2
    DNS_SETTINGS_SYNC_OK="failed"
  fi
fi

# --- Import scope: adlist subscriptions, blacklist/whitelist domain entries, and the
# groups they belong to (needed for referential integrity - domain/adlist entries can
# be assigned to custom groups). "config" and "dhcp_leases" are always false: general
# settings are never synced through Teleporter (see the local DNS step above for the
# one exception that IS synced, via a safer, narrower API call). client/client_by_group
# (per-client group assignments) is intentionally left out - re-enable it here if you
# use that feature.
IMPORT_SCOPE='{"config":false,"dhcp_leases":false,"gravity":{"group":true,"adlist":true,"adlist_by_group":true,"domainlist":true,"domainlist_by_group":true,"client":false,"client_by_group":false}}'

# --- Import into this node's local Pi-hole (this restarts local FTL automatically) ---
IMPORT_HTTP_CODE=$(curl -sk -o "$IMPORT_RESP" -w '%{http_code}' -H "X-FTL-SID: $LOCAL_SID" \
  -F "file=@${TMP_ZIP};type=application/zip" \
  -F "import=${IMPORT_SCOPE};type=application/json" \
  "$LOCAL_URL/api/teleporter")
curl -sk -X DELETE -H "X-FTL-SID: $LOCAL_SID" "$LOCAL_URL/api/auth" > /dev/null 2>&1 || true

if [ "$IMPORT_HTTP_CODE" != "200" ]; then
  fail "Teleporter import into local Pi-hole failed - HTTP $IMPORT_HTTP_CODE ($(cat "$IMPORT_RESP" 2>/dev/null))"
fi

log "Sync succeeded: pulled gravity data from $REMOTE_URL and imported locally (DNS settings sync: $DNS_SETTINGS_SYNC_OK)."
echo "SUCCESS: Synced Pi-hole config from $REMOTE_URL (DNS settings sync: $DNS_SETTINGS_SYNC_OK)."
exit 0
EOF_SYNC_SCRIPT

chmod 700 /usr/local/bin/pihole_sync.sh
if [ -f /usr/local/bin/pihole_sync.sh ]; then
  echo "SUCCESS: Sync script created and made executable."
else
  echo "ERROR: Failed to create sync script. Exiting."
  exit 1
fi

# --- Phase: systemd service + timer to run the sync periodically ---
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Creating systemd service/timer to run the sync every ${SYNC_INTERVAL_MINUTES} minute(s)..."

cat << EOF_SYNC_SERVICE > /etc/systemd/system/pihole-sync.service
[Unit]
Description=Pi-hole HA config sync (Teleporter pull from SOURCE)
After=network-online.target pihole-FTL.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/pihole_sync.sh
EOF_SYNC_SERVICE

cat << EOF_SYNC_TIMER > /etc/systemd/system/pihole-sync.timer
[Unit]
Description=Run Pi-hole HA config sync every ${SYNC_INTERVAL_MINUTES} minute(s)

[Timer]
OnBootSec=2min
OnUnitActiveSec=${SYNC_INTERVAL_MINUTES}min
AccuracySec=30s
Unit=pihole-sync.service

[Install]
WantedBy=timers.target
EOF_SYNC_TIMER

systemctl daemon-reload
if systemctl enable --now pihole-sync.timer > /dev/null 2>&1; then
  echo "SUCCESS: pihole-sync.timer enabled and started."
else
  echo "ERROR: Failed to enable pihole-sync.timer. Exiting."
  exit 1
fi

# --- Phase: Run an initial sync now, so problems surface immediately ---
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Running an initial sync now to verify everything works..."
if /usr/local/bin/pihole_sync.sh; then
  echo "SUCCESS: Initial sync completed."
else
  echo "WARNING: Initial sync failed - see the error above and README-sync.md's"
  echo "Troubleshooting section. The timer is still installed and will retry on its"
  echo "own schedule, but you should fix the underlying issue (check URLs, app"
  echo "passwords, and network connectivity to SOURCE) rather than leaving it failing."
fi

# --- Final Status Check and Information ---
echo
echo "============================================================"
echo " Script Finished for this Node!"
echo "============================================================"
echo " IMPORTANT NEXT STEPS:"
echo " 1. Repeat this script on any additional REPLICA nodes."
echo " 2. To sync on demand at any time (in addition to the automatic schedule), run:"
echo "      sudo systemctl start pihole-sync.service"
echo " 3. To monitor sync activity, run:"
echo "      journalctl -t pihole_sync -f"
echo " 4. This script only syncs Pi-hole SETTINGS. It does NOT handle DNS traffic"
echo "    routing/failover - use install.sh (keepalived) or install-anycast.sh (BGP"
echo "    anycast) for that, if you haven't already."
echo " 5. See README-sync.md in this repo for how this works, security notes, and"
echo "    troubleshooting."
echo "============================================================"
