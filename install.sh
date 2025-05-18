#!/bin/bash

# ==============================================================================
# Interactive Script to Setup Keepalived for Pi-hole High Availability
# ==============================================================================
#
# Instructions:
# 1. Save this script on each Pi you want to configure.
# 2. Make it executable: chmod +x setup_pihole_ha_interactive.sh
# 3. Run as root: sudo ./setup_pihole_ha_interactive.sh
# 4. Answer the prompts carefully for each Pi.
#
# ==============================================================================

# --- Function to prompt for yes/no with a default ---
prompt_yes_no() {
    local prompt_text="$1"
    local default_answer="$2"
    local answer

    while true; do
        read -r -p "$prompt_text [$default_answer]: " answer
        answer="${answer:-$default_answer}"
        answer_lower=$(echo "$answer" | tr '[:upper:]' '[:lower:]')
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

# Check if script is run as root
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use 'sudo ./setup_pihole_ha_interactive.sh'"
  exit 1
fi

echo "============================================================"
echo " Pi-hole HA (keepalived) Interactive Setup"
echo "============================================================"
echo "This script will guide you through configuring keepalived for this Pi."
echo "You will need to run this script on both your primary and backup Pi-holes."
echo

# --- Gather Configuration Interactively ---

# 1. MY_ROLE
while true; do
  read -r -p "Is this Pi the PRIMARY (MASTER) or BACKUP node? (Enter MASTER or BACKUP): " MY_ROLE_INPUT
  MY_ROLE=$(echo "$MY_ROLE_INPUT" | tr '[:lower:]' '[:upper:]')
  if [[ "$MY_ROLE" == "MASTER" || "$MY_ROLE" == "BACKUP" ]]; then
    break
  else
    echo "Invalid input. Please enter 'MASTER' or 'BACKUP'."
  fi
done

# 2. MY_INTERFACE
echo
echo "Available network interfaces:"
ip -br a | awk '{print "  - " $1}' | grep -v "lo"
INTERFACES_LIST=$(ls /sys/class/net | grep -v "lo" | tr '\n' ' ')
echo "(Common choices might be: $INTERFACES_LIST)"
while true; do
  read -r -p "Enter the network interface name for keepalived (e.g., eth0, enp6s18): " MY_INTERFACE
  if [ -z "$MY_INTERFACE" ]; then
    echo "Interface name cannot be empty."
  elif ! ip link show "$MY_INTERFACE" > /dev/null 2>&1; then
    echo "ERROR: Interface '$MY_INTERFACE' does not seem to exist. Please check the name."
  else
    break
  fi
done

# 3. MY_PRIORITY
DEFAULT_PRIORITY="100"
SUGGESTED_PRIORITY_INFO="100 for BACKUP"
if [ "$MY_ROLE" == "MASTER" ]; then
  DEFAULT_PRIORITY="101"
  SUGGESTED_PRIORITY_INFO="101 for MASTER"
fi
while true; do
  read -r -p "Enter the priority for this node (numeric, higher wins, e.g., $SUGGESTED_PRIORITY_INFO) [Default: $DEFAULT_PRIORITY]: " MY_PRIORITY_INPUT
  MY_PRIORITY="${MY_PRIORITY_INPUT:-$DEFAULT_PRIORITY}"
  if [[ "$MY_PRIORITY" =~ ^[0-9]+$ ]]; then
    break
  else
    echo "Invalid input. Priority must be a number."
  fi
done

# 4. NOPREEMPT_LINE (only if role is BACKUP)
NOPREEMPT_LINE=""
if [ "$MY_ROLE" == "BACKUP" ]; then
  echo
  NOPREEMPT_CHOICE=$(prompt_yes_no "Should this BACKUP node use 'nopreempt'? (Recommended. If yes, it keeps VIP if MASTER returns briefly)" "yes")
  if [ "$NOPREEMPT_CHOICE" == "yes" ]; then
    NOPREEMPT_LINE="nopreempt"
  fi
fi

echo
echo "--- Common Settings (must be identical on both Pi-hole HA nodes) ---"

# 5. VIRTUAL_ROUTER_ID
DEFAULT_VRID="51"
while true; do
  read -r -p "Enter the Virtual Router ID (numeric, 0-255, must be same on both nodes) [Default: $DEFAULT_VRID]: " VRID_INPUT
  VIRTUAL_ROUTER_ID="${VRID_INPUT:-$DEFAULT_VRID}"
  if [[ "$VIRTUAL_ROUTER_ID" =~ ^[0-9]+$ && "$VIRTUAL_ROUTER_ID" -ge 0 && "$VIRTUAL_ROUTER_ID" -le 255 ]]; then
    break
  else
    echo "Invalid input. Must be a number between 0 and 255."
  fi
done

# 6. AUTH_PASS
echo
echo "The authentication password MUST be identical on both HA nodes."
while true; do
  read -s -r -p "Enter the authentication password for VRRP: " AUTH_PASS_INPUT
  echo
  read -s -r -p "Confirm authentication password: " AUTH_PASS_CONFIRM
  echo
  if [ -z "$AUTH_PASS_INPUT" ]; then
    echo "Password cannot be empty."
  elif [ "$AUTH_PASS_INPUT" == "$AUTH_PASS_CONFIRM" ]; then
    AUTH_PASS="$AUTH_PASS_INPUT"
    break
  else
    echo "Passwords do not match. Please try again."
  fi
done

# 7. VIRTUAL_IP_CIDR
echo
DEFAULT_VIP_EXAMPLE="192.168.0.5" # Adjust if your network is different
DEFAULT_CIDR="24"
while true; do
  read -r -p "Enter the shared Virtual IP (VIP) address (e.g., $DEFAULT_VIP_EXAMPLE): " VIP_ADDRESS
  # Basic IP format validation
  if [[ "$VIP_ADDRESS" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    break
  else
    echo "Invalid IP address format. Please use format X.X.X.X"
  fi
done
while true; do
  read -r -p "Enter the CIDR prefix for the VIP's subnet (e.g., 24 for 255.255.255.0) [Default: $DEFAULT_CIDR]: " VIP_CIDR_PREFIX_INPUT
  VIP_CIDR_PREFIX="${VIP_CIDR_PREFIX_INPUT:-$DEFAULT_CIDR}"
  if [[ "$VIP_CIDR_PREFIX" =~ ^[0-9]+$ && "$VIP_CIDR_PREFIX" -ge 1 && "$VIP_CIDR_PREFIX" -le 32 ]]; then
    break
  else
    echo "Invalid CIDR prefix. Must be a number between 1 and 32."
  fi
done
VIRTUAL_IP_CIDR="$VIP_ADDRESS/$VIP_CIDR_PREFIX"

# --- Display Summary and Confirm ---
echo
echo "============================================================"
echo " Configuration Summary for this Pi:"
echo "------------------------------------------------------------"
echo " Role:                $MY_ROLE"
echo " Interface:           $MY_INTERFACE"
echo " Priority:            $MY_PRIORITY"
if [ "$MY_ROLE" == "BACKUP" ]; then
  echo " Nopreempt:           '$NOPREEMPT_LINE'"
fi
echo "------------------------------------------------------------"
echo " Shared Settings (verify these are identical on both nodes):"
echo " Virtual IP (VIP):    $VIRTUAL_IP_CIDR"
echo " Virtual Router ID:   $VIRTUAL_ROUTER_ID"
echo " Auth Password:       [set - will not be displayed]"
echo "============================================================"
CONFIRMATION=$(prompt_yes_no "Proceed with this configuration?" "yes")

if [[ "$CONFIRMATION" != "yes" ]]; then
  echo "Setup aborted by user."
  exit 1
fi

# --- Start Actual Setup ---

# 1. Update package lists and install keepalived
echo
echo ">>> Phase 1: Updating package lists and installing keepalived..."
apt update > /dev/null 2>&1
if apt install -y keepalived; then
  echo "SUCCESS: Keepalived installed."
else
  echo "ERROR: Failed to install keepalived. Please check for errors above. Exiting."
  exit 1
fi

# 2. Create Pi-hole Health Check Script
echo
echo ">>> Phase 2: Creating Pi-hole health check script (/usr/local/bin/pihole_check.sh)..."
cat << 'EOF_HEALTHCHECK' > /usr/local/bin/pihole_check.sh
#!/bin/bash

# Check if pihole-FTL service is active
if systemctl is-active --quiet pihole-FTL.service; then
  # Optional: uncomment below to perform a live DNS query test against localhost.
  # Requires 'dnsutils' (sudo apt install dnsutils)
  # if host flurry.com 127.0.0.1 > /dev/null 2>&1; then
  #   exit 0 # Healthy - pihole-FTL is running and DNS query OK
  # else
  #   exit 1 # Unhealthy - DNS query failed
  # fi
  exit 0 # Healthy - pihole-FTL is running
else
  exit 1 # Unhealthy - pihole-FTL is not running
fi
EOF_HEALTHCHECK

chmod +x /usr/local/bin/pihole_check.sh
if [ -f /usr/local/bin/pihole_check.sh ]; then
  echo "SUCCESS: Pi-hole health check script created."
else
  echo "ERROR: Failed to create health check script. Exiting."
  exit 1
fi

# 3. Configure keepalived
echo
echo ">>> Phase 3: Creating keepalived configuration file (/etc/keepalived/keepalived.conf)..."

# Handle nopreempt line based on user choice (already stored in NOPREEMPT_LINE)
ACTUAL_NOPREEMPT_CONFIG_LINE="$NOPREEMPT_LINE"

# Create the keepalived.conf content
cat << EOF_KEEPALIVED_CONF > /etc/keepalived/keepalived.conf
# Configuration created by setup_pihole_ha_interactive.sh script
# Role: $MY_ROLE
# Interface: $MY_INTERFACE

vrrp_script check_pihole {
    script "/usr/local/bin/pihole_check.sh"
    interval 2  # Check every 2 seconds
    weight 2    # Add 2 to priority if script succeeds
    fall 2      # Require 2 failures to mark script as failed
    rise 2      # Require 2 successes to mark script as successful
}

vrrp_instance VI_PIHOLE {
    state $MY_ROLE
    interface $MY_INTERFACE
    virtual_router_id $VIRTUAL_ROUTER_ID
    priority $MY_PRIORITY
    $ACTUAL_NOPREEMPT_CONFIG_LINE
    advert_int 1

    authentication {
        auth_type PASS
        auth_pass "$AUTH_PASS"
    }

    virtual_ipaddress {
        $VIRTUAL_IP_CIDR
    }

    track_script {
        check_pihole
    }
}
EOF_KEEPALIVED_CONF

if [ -f /etc/keepalived/keepalived.conf ]; then
  echo "SUCCESS: Keepalived configuration file created."
else
  echo "ERROR: Failed to create keepalived.conf. Exiting."
  exit 1
fi

# 4. Enable and Start/Restart keepalived Service
echo
echo ">>> Phase 4: Enabling and restarting keepalived service..."
systemctl enable keepalived > /dev/null 2>&1
if systemctl restart keepalived; then
  echo "SUCCESS: Keepalived service enabled and restarted."
else
  echo "ERROR: Failed to restart keepalived. Check 'systemctl status keepalived' or 'journalctl -u keepalived'."
  exit 1
fi

# 5. Final Status Check and Information
echo
echo ">>> Phase 5: Final checks and information..."
sleep 3 # Give keepalived a moment to stabilize

echo "Current keepalived service status:"
systemctl status keepalived --no-pager | grep -E 'Active:|State:'

echo
echo "To verify VIP presence, run: ip addr show $MY_INTERFACE | grep '$VIP_ADDRESS'" # Check for just IP part
echo "To monitor keepalived logs, run: journalctl -u keepalived -f"
echo

# Attempt to determine state
CURRENT_STATE_INFO="Could not determine current VRRP state from logs reliably."
if systemctl is-active --quiet keepalived; then
    LOG_STATE=$(journalctl -u keepalived --since "1 minute ago" -o cat --no-pager | grep -Eo "Entering (MASTER|BACKUP) STATE" | tail -n 1)
    if [[ "$LOG_STATE" == *"MASTER STATE"* ]]; then
        CURRENT_STATE_INFO="Likely MASTER (based on recent logs)"
    elif [[ "$LOG_STATE" == *"BACKUP STATE"* ]]; then
        CURRENT_STATE_INFO="Likely BACKUP (based on recent logs)"
    fi

    if ip addr show "$MY_INTERFACE" | grep -q "$VIP_ADDRESS"; then # Check for just IP part
        CURRENT_STATE_INFO="$CURRENT_STATE_INFO - VIP ($VIP_ADDRESS) is bound to $MY_INTERFACE."
    else
        CURRENT_STATE_INFO="$CURRENT_STATE_INFO - VIP ($VIP_ADDRESS) is NOT bound to $MY_INTERFACE."
    fi
    echo "Keepalived appears to be running. $CURRENT_STATE_INFO"
else
  echo "WARNING: Keepalived service is not reported as active after restart. Please investigate!"
fi

echo
echo "============================================================"
echo " Script Finished!"
echo "============================================================"
echo " IMPORTANT NEXT STEPS:"
echo " 1. If you haven't already, run this script (answering appropriately)"
echo "    on your OTHER Pi-hole HA node."
echo " 2. Configure your DHCP server to use the VIP ($VIP_ADDRESS)"
echo "    as the DNS server for your clients."
echo " 3. Implement a method to synchronize Pi-hole configurations"
echo "    (e.g., blocklists, adlists, whitelists) between the two Pis."
echo "    Consider using a tool like 'Gravity Sync'."
echo "============================================================"
