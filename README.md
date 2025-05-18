# Pi-hole High Availability (HA) Setup Script using Keepalived

This script provides an interactive way to configure a two-node High Availability (HA) setup for your Pi-hole instances using `keepalived`. It automates the installation and configuration of `keepalived` to manage a Virtual IP (VIP) address that will float between your two Pi-hole servers, ensuring continuous DNS ad-blocking even if one Pi-hole node goes down.

## Features

* **Interactive Setup:** Guides you through the configuration process with clear prompts.
* **Automated `keepalived` Installation:** Installs `keepalived` if it's not already present.
* **Automatic `keepalived.conf` Generation:** Creates the necessary `keepalived` configuration file based on your input.
* **Pi-hole Health Checking:** Deploys a simple script that `keepalived` uses to monitor the status of the local Pi-hole FTL service. If the service fails, `keepalived` can trigger a failover to the healthy node.
* **Support for Primary (MASTER) and Backup (BACKUP) Roles:** Allows designation of node roles and priorities.
* **Optional `nopreempt` Configuration:** For the backup node, to prevent the VIP from "flapping" if the primary node recovers and fails repeatedly.

## Prerequisites

Before running this script on each Pi-hole node, ensure you have:

1.  **Two Raspberry Pis (or similar Debian-based systems):** Each running a functional Pi-hole installation.
2.  **Static IP Addresses:** Each Pi-hole node should have its own unique static IP address (these are *not* the VIP).
3.  **Network Connectivity:** Both Pis must be on the same network/subnet.
4.  **`sudo` Access:** The script requires root privileges to install packages and modify system configurations.
5.  **`curl` or `wget`:** Required if you plan to run the script directly from GitHub. Most systems have these pre-installed. If not:
    ```bash
    sudo apt update && sudo apt install -y curl wget
    ```
6.  **A Chosen Virtual IP (VIP) Address:** This IP address must be on the same subnet as your Pi-holes but **not** currently used by any other device. This will be the IP address your clients use as their DNS server.

## How to Use

You need to run this script on **both** of your Pi-hole nodes. Run it on your intended Primary/MASTER node first, then on your intended Backup/BACKUP node.

### Option 1: Directly from GitHub (Recommended)

This method downloads and executes the latest version of the script.

1.  **Open a terminal on your first Pi-hole node.**
2.  Run the following command:
    ```bash
    curl -sSL https://raw.githubusercontent.com/blackboy69/pihole_ha/main/install.sh | sudo bash
    ```
    *(Replace the URL if you are using a different repository or branch.)*
3.  **Answer the interactive prompts** based on the role and settings for this specific node.
4.  **Repeat steps 1-3 on your second Pi-hole node**, answering the prompts according to its role.

**Security Note:** Always be cautious when running scripts directly from the internet with `sudo`. It's good practice to review the script's content by opening the URL in a browser before execution if you have any concerns.

### Option 2: Download and Run Locally

1.  **Download the script** (e.g., `install.sh`) to each Pi-hole node. You can clone the repository or download the raw file.
    Using `curl`:
    ```bash
    curl -sSL -o install.sh https://raw.githubusercontent.com/blackboy69/pihole_ha/main/install.sh
    ```
3.  **Make the script executable:**
    ```bash
    chmod +x install.sh
    ```
4.  **Run the script as root:**
    ```bash
    sudo ./install.sh
    ```
5.  **Answer the interactive prompts** for each node.

## Configuration Prompts

The script will ask you for the following information for each node:

* **Role:** `MASTER` (primary) or `BACKUP`.
* **Network Interface:** The network interface connected to your LAN (e.g., `eth0`, `enp6s18`).
* **Priority:** A numeric value; the MASTER node should have a higher priority (e.g., `101`) than the BACKUP node (e.g., `100`).
* **Nopreempt (for BACKUP node):** Whether the BACKUP node, once it becomes MASTER, should retain the VIP even if the original MASTER comes back online. Recommended is 'yes'.
* **Virtual Router ID:** A number (0-255) that identifies the VRRP group. **Must be the same on both nodes.**
* **Authentication Password:** A password used for VRRP communication between the nodes. **Must be the same on both nodes.**
* **Virtual IP (VIP) Address and CIDR:** The shared IP address clients will use for DNS, along with its subnet prefix (e.g., `192.168.0.5` and `24`). **Must be the same on both nodes.**

## How It Works

* **`keepalived`:** This daemon implements the Virtual Router Redundancy Protocol (VRRP). It allows two or more machines to share a common Virtual IP address (VIP).
* **VRRP Roles:**
    * One machine acts as the `MASTER`, actively handling traffic for the VIP.
    * The other(s) act as `BACKUP`(s), monitoring the MASTER.
* **Failover:** If the MASTER node fails (or its `keepalived` service detects a problem via the health check), one of the BACKUP nodes takes over the VIP and becomes the new MASTER.
* **Health Check Script (`/usr/local/bin/pihole_check.sh`):**
    * This script is created by the setup process.
    * `keepalived` periodically runs this script to check if the `pihole-FTL.service` (Pi-hole's DNS resolver) is active.
    * If the script reports Pi-hole as unhealthy, `keepalived` reduces the node's effective priority, potentially triggering a failover to the other node if it's healthy and has a higher effective priority.

## Post-Installation Steps

1.  **Configure DHCP Server:**
    * Log in to your router (e.g., UniFi Dream Machine, pfSense, etc.).
    * Navigate to your DHCP server settings.
    * Change the DNS server(s) provided to your clients to be **only** the **Virtual IP (VIP) address** you configured.
    * Clients will need to renew their DHCP lease (e.g., by restarting their network interface or rebooting) to pick up the new DNS server.

2.  **Synchronize Pi-hole Configurations (Crucial!):**
    * This script **only** handles IP address failover. It **does not** synchronize your Pi-hole settings (adlists, blocklists, whitelists, regex filters, client configurations, etc.).
    * You **must** implement a separate mechanism to keep these settings consistent between your two Pi-hole nodes.
    * A popular tool for this is **[Gravity Sync](https://github.com/vmstan/gravity-sync)**.
    * Alternatively, you can use scheduled `pihole -a -t` (teleporter) backups and restores, or rsync specific configuration files.

3.  **Test Failover:**
    * Identify which Pi-hole is currently the `MASTER` (it will have the VIP assigned to its network interface: `ip addr show <interface_name>`).
    * Simulate a failure on the `MASTER` node:
        * Stop the `keepalived` service: `sudo systemctl stop keepalived`
        * Stop the Pi-hole FTL service: `sudo systemctl stop pihole-FTL.service` (or `sudo pihole disable`)
        * Reboot the `MASTER` Pi: `sudo reboot`
    * Verify that the `BACKUP` node takes over the VIP and becomes the new `MASTER`.
    * Confirm that DNS resolution continues to work for your clients using the VIP.
    * Restore the original `MASTER` node and observe if it reclaims the VIP (behavior depends on priorities and `nopreempt` setting).

## Troubleshooting

* **Check `keepalived` Status:**
    ```bash
    sudo systemctl status keepalived
    ```
* **View `keepalived` Logs:**
    ```bash
    journalctl -u keepalived -f
    ```
    Look for messages about state transitions (MASTER, BACKUP, FAULT), VRRP advertisements, and health check script results.
* **Verify VIP Assignment:**
    On each node, check if the VIP is assigned to the configured network interface:
    ```bash
    ip addr show <your_interface_name>
    ```
    Only the current `MASTER` node should have the VIP.
* **Firewall:** Ensure your firewalls (if any running on the Pis, like `ufw`) are not blocking VRRP traffic. VRRP uses IP protocol number 112. Typically, for communication within the same LAN, this is not an issue unless restrictive rules are in place.
* **Health Check Script:** Test the health check script manually:
    ```bash
    sudo /usr/local/bin/pihole_check.sh
    echo $?
    ```
    It should output `0` if Pi-hole FTL is running, and `1` otherwise.
* **Identical "Common Settings":** Double-check that `Virtual Router ID`, `Authentication Password`, and `Virtual IP CIDR` are absolutely identical in the `/etc/keepalived/keepalived.conf` files on both nodes.

## Disclaimer

* This script modifies system configurations and installs software. Use it at your own risk.
* Always back up your systems before making significant changes.
* Ensure you understand the commands being executed, especially when running scripts downloaded from the internet.

