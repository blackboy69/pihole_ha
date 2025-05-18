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
        read -r -p "$prompt_text [$default_answer]: " answer
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
  read -r -p "Is this Pi the PRIMARY (MASTER) or BACKUP node? (Enter MASTER or BACKUP): " MY_ROLE_INPUT
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
  read -r -p "Enter the network interface name for keepalived (e.g., eth0, enp6s18): " MY_INTERFACE
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
  read -r -p "Enter the priority for this node (numeric, $SUGGESTED_PRIORITY_INFO) [Default: $DEFAULT_PRIORITY]: " MY_PRIORITY_INPUT
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
  read -r -p "Enter the Virtual Router ID (numeric, 0
