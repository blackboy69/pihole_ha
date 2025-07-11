#!/bin/bash

# =====================================================================================
# Interactive Script to Setup Keepalived for Pi-hole High Availability (2-Node Setup)
# =====================================================================================
#
# Purpose:
# This script interactively configures 'keepalived' on a Raspberry Pi (or similar
# Debian-based system) to act as a node in a 2-Pi High Availability setup for Pi-hole.
# It sets up a Virtual IP (VIP) that will float between the two Pi-hole nodes.
#
# How to Use (Recommended - Directly from GitHub):
# 1. Ensure 'curl' or 'wget' is installed on the Pi:
#    sudo apt update && sudo apt install -y curl wget
# 2. Execute on EACH Pi (Primary/MASTER first, then Backup/BACKUP):
#    curl -sSL https://raw.githubusercontent.com/blackboy69/pihole_ha/main/install.sh | sudo bash
#    (Replace URL if it's hosted elsewhere or you have a fork)
# 3. Answer the interactive prompts carefully for each Pi.
#
# How to Use (If Downloaded Locally):
# 1. Save this script (e.g., as 'setup_pihole_ha_interactive.sh') on each Pi.
# 2. Make it executable: chmod +x setup_pihole_ha_interactive.sh
# 3. Run as root on EACH Pi: sudo ./setup_pihole_ha_interactive.sh
# 4. Answer the interactive prompts carefully for each Pi.
#
# Prerequisites:
# - Two Raspberry Pis (or similar Debian-based systems).
# - Pi-hole installed and functional independently on each Pi.
# - Network connectivity between the Pis.
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
echo " Pi-hole HA (keepalived) Interactive Setup"
echo "============================================================"
echo "This script will guide you through configuring keepalived for THIS Pi."
echo "You will need to run this script on both your primary and backup Pi-hole nodes."
echo # Newline for readability

# --- Gather Configuration Interactively ---
# This section prompts the user for all necessary configuration parameters.

# 1. MY_ROLE: Determine if this node is the MASTER (primary) or BACKUP.
# The MASTER node will initially hold the VIP if both nodes are up.
while true; do
  read -r -p "Is this Pi the PRIMARY (MASTER) or BACKUP node? (Enter MASTER or BACKUP): " MY_ROLE_INPUT < /dev/tty
  MY_ROLE=$(echo "$MY_ROLE_INPUT" | tr '[:lower:]' '[:upper:]') # Standardize to uppercase
  if [[ "$MY_ROLE" == "MASTER" || "$MY_ROLE" == "BACKUP" ]]; then
    break
  else
    echo "Invalid input. Please enter 'MASTER' or 'BACKUP'."
  fi
done

# 2. MY_INTERFACE: Network interface for keepalived to bind to.
echo
echo "Available network interfaces (excluding loopback 'lo'):"
ip -br a | awk '{print "  - " $1}' | grep -v "lo" # Shows current interfaces with their IPs
INTERFACES_LIST=$(ls /sys/class/net | grep -v "lo" | tr '\n' ' ') # Lists interface names
echo "(Common interface names might be: $INTERFACES_LIST)"
echo "Ensure you choose the interface connected to your main LAN where the VIP will reside."
while true; do
  read -r -p "Enter the network interface name for keepalived (e.g., eth0, enp6s18): " MY_INTERFACE < /dev/tty
  if [ -z "$MY_INTERFACE" ]; then
    echo "Interface name cannot be empty."
  elif ! ip link show "$MY_INTERFACE" > /dev/null 2>&1; then # Check if interface exists
    echo "ERROR: Interface '$MY_INTERFACE' does not appear to exist. Please verify the name."
  else
    break
  fi
done

# 3. MY_PRIORITY: Determines which node takes precedence if both are healthy. Higher number wins.
# MASTER should have a higher priority than BACKUP.
DEFAULT_PRIORITY="100" # Default for BACKUP
SUGGESTED_PRIORITY_INFO="e.g., 100 for BACKUP"
if [ "$MY_ROLE" == "MASTER" ]; then
  DEFAULT_PRIORITY="101" # Default for MASTER
  SUGGESTED_PRIORITY_INFO="e.g., 101 for MASTER"
fi
while true; do
  read -r -p "Enter the priority for this node (numeric, $SUGGESTED_PRIORITY_INFO) [Default: $DEFAULT_PRIORITY]: " MY_PRIORITY_INPUT < /dev/tty
  MY_PRIORITY="${MY_PRIORITY_INPUT:-$DEFAULT_PRIORITY}"
  if [[ "$MY_PRIORITY" =~ ^[0-9]+$ ]]; then
    break
  else
    echo "Invalid input. Priority must be a positive number."
  fi
done

# 4. NOPREEMPT_LINE: Specific to BACKUP node. If set, BACKUP won't give up VIP easily.
NOPREEMPT_LINE="" # Initialize to empty (no nopreempt)
if [ "$MY_ROLE" == "BACKUP" ]; then
  echo
  NOPREEMPT_CHOICE=$(prompt_yes_no "Should this BACKUP node use 'nopreempt'? (Recommended 'yes'. If 'yes', it keeps the VIP once acquired, even if MASTER returns, until this BACKUP node itself fails. This prevents VIP 'flapping')" "yes")
  if [ "$NOPREEMPT_CHOICE" == "yes" ]; then
    NOPREEMPT_LINE="nopreempt" # This string will be added to keepalived.conf
  fi
fi

echo
echo "--- Common Settings (these MUST be identical on both Pi-hole HA nodes) ---"

# 5. VIRTUAL_ROUTER_ID: An identifier for the VRRP group. Must match on both nodes.
DEFAULT_VRID="51" # Arbitrary default, 0-255
while true; do
  read -r -p "Enter the Virtual Router ID (numeric, 0-255, must be same on both nodes) [Default: $DEFAULT_VRID]: " VRID_INPUT < /dev/tty
  VIRTUAL_ROUTER_ID="${VRID_INPUT:-$DEFAULT_VRID}"
  if [[ "$VIRTUAL_ROUTER_ID" =~ ^[0-9]+$ && "$VIRTUAL_ROUTER_ID" -ge 0 && "$VIRTUAL_ROUTER_ID" -le 255 ]]; then
    break
  else
    echo "Invalid input. Must be a number between 0 and 255."
  fi
done

# 6. AUTH_PASS: Password for VRRP authentication between nodes. Must match.
echo
echo "The VRRP authentication password MUST be identical on both HA nodes."
echo "Choose a strong password."
while true; do
  read -s -r -p "Enter the authentication password for VRRP: " AUTH_PASS_INPUT < /dev/tty # -s hides input
  echo # Newline after hidden input
  read -s -r -p "Confirm authentication password: " AUTH_PASS_CONFIRM < /dev/tty
  echo # Newline after hidden input
  if [ -z "$AUTH_PASS_INPUT" ]; then
    echo "Password cannot be empty. Please try again."
  elif [ "$AUTH_PASS_INPUT" == "$AUTH_PASS_CONFIRM" ]; then
    AUTH_PASS="$AUTH_PASS_INPUT"
    break
  else
    echo "Passwords do not match. Please try again."
  fi
done

# 7. VIRTUAL_IP_CIDR: The shared Virtual IP address and its subnet mask (CIDR notation).
echo
DEFAULT_VIP_EXAMPLE="192.168.0.5" # Example, user should adapt to their network
DEFAULT_CIDR="24" # Corresponds to 255.255.255.0
echo "The Virtual IP (VIP) is the IP address your clients will use as their DNS server."
echo "It should be on the same subnet as your Pi-holes but not used by any other device."
while true; do
  read -r -p "Enter the shared Virtual IP (VIP) address (e.g., $DEFAULT_VIP_EXAMPLE): " VIP_ADDRESS < /dev/tty
  # Basic IPv4 format validation
  if [[ "$VIP_ADDRESS" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    break
  else
    echo "Invalid IP address format. Please use format X.X.X.X (e.g., 192.168.1.100)."
  fi
done
while true; do
  read -r -p "Enter the CIDR prefix for the VIP's subnet (e.g., 24 for a 255.255.255.0 subnet) [Default: $DEFAULT_CIDR]: " VIP_CIDR_PREFIX_INPUT < /dev/tty
  VIP_CIDR_PREFIX="${VIP_CIDR_PREFIX_INPUT:-$DEFAULT_CIDR}"
  if [[ "$VIP_CIDR_PREFIX" =~ ^[0-9]+$ && "$VIP_CIDR_PREFIX" -ge 1 && "$VIP_CIDR_PREFIX" -le 32 ]]; then
    break
  else
    echo "Invalid CIDR prefix. Must be a number between 1 and 32."
  fi
done
VIRTUAL_IP_CIDR="$VIP_ADDRESS/$VIP_CIDR_PREFIX" # Combine for keepalived.conf

# --- Display Summary and Confirm Before Proceeding ---
echo
echo "============================================================"
echo " Configuration Summary for this Pi:"
echo "------------------------------------------------------------"
echo " Role:          $MY_ROLE"
echo " Interface:     $MY_INTERFACE"
echo " Priority:      $MY_PRIORITY"
if [ "$MY_ROLE" == "BACKUP" ]; then # Only show nopreempt for BACKUP
  echo " Nopreempt:     '$NOPREEMPT_LINE'"
fi
echo "------------------------------------------------------------"
echo " Shared Settings (verify these are identical on both nodes):"
echo " Virtual IP (VIP):    $VIRTUAL_IP_CIDR"
echo " Virtual Router ID:   $VIRTUAL_ROUTER_ID"
echo " Auth Password:       [set - will not be displayed for security]"
echo "============================================================"
CONFIRMATION=$(prompt_yes_no "Proceed with this configuration and install/configure keepalived?" "yes")

if [[ "$CONFIRMATION" != "yes" ]]; then
  echo "Setup aborted by user. No changes were made."
  exit 1
fi

# --- Start Actual System Setup ---
# The following sections install packages and write configuration files.

CURRENT_SCRIPT_PHASE=1 # Initialize the phase counter, first phase will be 2.

# --- Phase: Keepalived Install ---
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Updating package lists and installing keepalived..."
apt update > /dev/null 2>&1 # Suppress apt update output for cleaner logs
if apt install -y keepalived; then
  echo "SUCCESS: Keepalived package installed."
else
  echo "ERROR: Failed to install keepalived. Please check for errors above. Exiting."
  exit 1
fi

# --- Phase: Create keepalived_script user ---
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Creating 'keepalived_script' user if it doesn't exist..."
if ! id "keepalived_script" &>/dev/null; then
    sudo useradd -r -s /usr/sbin/nologin keepalived_script
    echo "SUCCESS: 'keepalived_script' user created."
else
    echo "INFO: 'keepalived_script' user already exists. Skipping creation."
fi

# --- Phase: Health Check Script ---
# This script is used by keepalived to monitor the health of the local Pi-hole service.
# If Pi-hole FTL is not healthy, keepalived can trigger a failover.
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Creating Pi-hole health check script at /usr/local/bin/pihole_check.sh..."

cat << EOF_HEALTHCHECK > /usr/local/bin/pihole_check.sh
#!/bin/bash
# Health check script for Pi-hole FTL service.
# Exits with 0 if healthy (all required services are up and synchronized), 1 if not.

# Check if pihole-FTL service is active and running
if systemctl is-active --quiet pihole-FTL.service; then
  # Pi-hole FTL is running.

  # Optional: For a more thorough check, you can uncomment the following lines.
  # This performs a live DNS query against the local Pi-hole.
  # Requires 'dnsutils' or 'bind-utils' package (e.g., sudo apt install dnsutils).
  # if host example.com 127.0.0.1 > /dev/null 2>&1; then
  #    exit 0 # Healthy - pihole-FTL is running and DNS query OK
  # else
  #    # FTL might be running but not resolving, or network issue
  #    exit 1 # Unhealthy - DNS query failed
  # fi

  : # Proceed to final success exit
else
  # Pi-hole FTL is not running
  exit 1
fi

# If all checks passed (i.e., script hasn't exited with 1 yet)
exit 0
EOF_HEALTHCHECK

chmod +x /usr/local/bin/pihole_check.sh # Make the script executable
if [ -f /usr/local/bin/pihole_check.sh ]; then
  echo "SUCCESS: Pi-hole health check script created and made executable."
else
  echo "ERROR: Failed to create health check script. Exiting."
  exit 1
fi

# 3. Configure keepalived
# This generates the /etc/keepalived/keepalived.conf file based on user input.
# This configuration tells keepalived how to manage the VIP and uses the
# pihole_check.sh script (generated above) for health monitoring.
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Creating keepalived configuration file (/etc/keepalived/keepalived.conf)..."

# Ensure the nopreempt line is only added if it's set (relevant for BACKUP role)
ACTUAL_NOPREEMPT_CONFIG_LINE="$NOPREEMPT_LINE"

# Using a heredoc to write the keepalived configuration file.
# Variables are substituted from the values gathered earlier.
cat << EOF_KEEPALIVED_CONF > /etc/keepalived/keepalived.conf
# This file is managed by the Pi-hole HA setup script.
# Manual edits may be overwritten if the script is run again.
# Role: $MY_ROLE
# Interface: $MY_INTERFACE

global_defs {
    router_id LVS_DEVEL
    script_user keepalived_script
    enable_script_security
}

# Defines the health check script for Pi-hole
vrrp_script check_pihole {
    script "/usr/local/bin/pihole_check.sh"  # Path to the health check script (monitors Pi-hole)
    interval 2                               # Run check_pihole every 2 seconds
    weight 2                                 # Decrease priority by 2 on failure, increase by 2 on success
    fall 2                                   # Require 2 consecutive failures to mark script as failed
    rise 2                                   # Require 2 consecutive successes to mark script as successful
}

# Defines the VRRP instance for Pi-hole HA
vrrp_instance VI_PIHOLE {
    state $MY_ROLE                           # Initial state: MASTER or BACKUP
    interface $MY_INTERFACE                  # Network interface to use
    virtual_router_id $VIRTUAL_ROUTER_ID     # Must be the same on both nodes
    priority $MY_PRIORITY                    # Higher value takes precedence
    $ACTUAL_NOPREEMPT_CONFIG_LINE            # Adds 'nopreempt' line if configured for BACKUP
    advert_int 1                             # VRRP advertisement interval (seconds)
                                             # Sub-second intervals (e.g., 0.5 for 500ms) are supported but may
                                             # increase network traffic and CPU load. Test thoroughly if changing.

    # Authentication for VRRP messages - MUST match on both nodes
    authentication {
        auth_type PASS
        auth_pass "$AUTH_PASS"               # The password for VRRP communication
    }

    # The Virtual IP address(es) managed by this instance
    virtual_ipaddress {
        $VIRTUAL_IP_CIDR                     # The shared VIP and its subnet mask
    }

    # Track the health check script
    # If 'check_pihole' script fails, this node's effective priority is reduced by 'weight'
    track_script {
        check_pihole
    }
}
EOF_KEEPALIVED_CONF

if [ -f /etc/keepalived/keepalived.conf ]; then
  echo "SUCCESS: Keepalived configuration file created at /etc/keepalived/keepalived.conf."
  chmod 600 /etc/keepalived/keepalived.conf
  echo "Permissions for /etc/keepalived/keepalived.conf set to 600 (root read/write only)."
else
  echo "ERROR: Failed to create /etc/keepalived/keepalived.conf. Exiting."
  exit 1
fi

# 4. Enable and Start/Restart keepalived Service
# Ensures keepalived starts on boot and applies the new configuration.
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Enabling and restarting keepalived service..."
systemctl enable keepalived > /dev/null 2>&1 # Ensure it starts on boot
if systemctl restart keepalived; then # Restart to apply new config, or start if not running
  echo "SUCCESS: Keepalived service enabled and restarted."
else
  echo "ERROR: Failed to restart keepalived service."
  echo "Please check its status with: systemctl status keepalived"
  echo "And review logs with: journalctl -u keepalived"
  exit 1
fi

# 5. Final Status Check and Information
CURRENT_SCRIPT_PHASE=$((CURRENT_SCRIPT_PHASE + 1))
echo
echo ">>> Phase $CURRENT_SCRIPT_PHASE: Final checks and important information..."
sleep 3 # Give keepalived a moment to stabilize and log its initial state

echo "Current keepalived service status:"
systemctl status keepalived --no-pager | grep -E 'Active:|State:' # Shows active status

echo
echo "To verify VIP presence on this node, run:"
# Extract just the IP address part from VIRTUAL_IP_CIDR for grep
VIP_ONLY_ADDRESS=$(echo "$VIRTUAL_IP_CIDR" | cut -d'/' -f1)
echo "  ip addr show $MY_INTERFACE | grep '$VIP_ONLY_ADDRESS'"
echo "To monitor keepalived logs in real-time, run:"
echo "  journalctl -u keepalived -f"
echo

# Attempt to determine and display the current VRRP state more clearly
CURRENT_STATE_INFO="Could not determine current VRRP state from logs reliably."
if systemctl is-active --quiet keepalived; then
    # Check recent syslog entries for state transitions (may vary based on system logging)
    LOG_STATE=$(journalctl -u keepalived --since "1 minute ago" -o cat --no-pager | grep -Eo "Entering (MASTER|BACKUP) STATE" | tail -n 1)
    if [[ "$LOG_STATE" == *"MASTER STATE"* ]]; then
        CURRENT_STATE_INFO="Likely in MASTER state (based on recent logs)."
    elif [[ "$LOG_STATE" == *"BACKUP STATE"* ]]; then
        CURRENT_STATE_INFO="Likely in BACKUP state (based on recent logs)."
    else
        CURRENT_STATE_INFO="State unclear from recent logs; check 'journalctl -u keepalived'."
    fi

    # Cross-verify by checking if the VIP is currently assigned to this node's interface
    if ip addr show "$MY_INTERFACE" | grep -q "$VIP_ONLY_ADDRESS"; then
        CURRENT_STATE_INFO="$CURRENT_STATE_INFO VIP ($VIP_ONLY_ADDRESS) is currently bound to $MY_INTERFACE on this node."
    else
        CURRENT_STATE_INFO="$CURRENT_STATE_INFO VIP ($VIP_ONLY_ADDRESS) is NOT currently bound to $MY_INTERFACE on this node."
    fi
    echo "Keepalived operational status: $CURRENT_STATE_INFO"
else
  echo "WARNING: Keepalived service is not reported as active after restart. Please investigate thoroughly!"
fi

echo
echo "============================================================"
echo " Script Finished for this Node!"
echo "============================================================"
echo " IMPORTANT NEXT STEPS:"
echo " 1. If you haven't already, run this script (answering prompts appropriately for that node)"
echo "    on your OTHER Pi-hole HA node to complete the pair."
echo " 2. Configure your DHCP server (on your router, e.g., UniFi CGM) to use the"
echo "    Virtual IP address ($VIP_ONLY_ADDRESS) as the ONLY DNS server for your clients."
echo " 3. Implement a method to synchronize Pi-hole configurations (adlists,"
echo "    blocklists, whitelists, etc.) between the two Pis. This script does NOT"
echo "    handle Pi-hole settings synchronization. You might consider using Pi-hole's"
echo "    Teleporter feature for manual backup/restore, 'rsync' for specific files,"
echo "    or search for community-maintained synchronization solutions."
echo " 4. VRRP Advertisement Interval: The script sets 'advert_int' to 1 second in"
echo "    '/etc/keepalived/keepalived.conf'. Sub-second intervals (e.g., 'advert_int 0.5')"
echo "    are supported by keepalived for faster failover but will increase network"
echo "    traffic and CPU load. If you require faster failover, you can manually edit"
echo "    this value, but ensure you test the stability of your setup thoroughly,"
echo "    especially on less powerful devices like Raspberry Pis."
echo " 5. NTP Configuration for Clients: The Virtual IP (VIP) is for DNS (Pi-hole) services ONLY."
echo "    Do NOT use the VIP as an NTP server endpoint for your NTP clients."
echo "    If you intend for these Pi-hole nodes to serve time (not typical for a default Chrony client setup),"
echo "    point your NTP clients directly to the real IP addresses of each Pi-hole node."
echo "============================================================"
