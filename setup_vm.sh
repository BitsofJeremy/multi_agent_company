#!/bin/bash

# ==============================================================================
# SECURITY NOTE: This is a convenience bootstrap for a LOCAL, THROWAWAY VM.
# It creates a local user (default 'debian') with a default password 'debian',
# grants passwordless sudo, and shares the user's home over Samba with guest
# access. That is only acceptable on an isolated lab machine. Override the
# defaults with --user/--password, remove NOPASSWD, and disable guest sharing
# before connecting this VM to any network you care about.
# ==============================================================================
set -e

# ==============================================================================
# Unified Debian VM Setup Script
# Creates the local user, configures sudo, installs dev environment and Samba
#
# Usage:
#   setup_vm.sh [--user <name>] [--password <pass>]
#
#   --user <name>       Local user to create (default: debian)
#   --password <pass>   Password for that user (default: debian)
# ==============================================================================

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

VM_USER="debian"
VM_PASSWORD="debian"
PASSWORD_EXPLICIT=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)     VM_USER="$2";             shift 2 ;;
    --password) VM_PASSWORD="$2"; PASSWORD_EXPLICIT=true; shift 2 ;;
    *)
      echo "Unknown option: $1"
      echo "Usage: setup_vm.sh [--user <name>] [--password <pass>]"
      exit 1
      ;;
  esac
done

if ! [[ "${VM_USER}" =~ ^[a-z][a-z0-9_-]*$ ]]; then
  echo "Invalid user name: '${VM_USER}' (must match ^[a-z][a-z0-9_-]*\$)"
  exit 1
fi

echo "=== Unified Debian VM Setup ==="
echo "Local user: ${VM_USER}"

echo "=== Unified Debian VM Setup ==="

# ------------------------------------------------------------------------------
# 1. Create the local user if it doesn't exist
# ------------------------------------------------------------------------------
echo "Setting up '${VM_USER}' user..."
if id "${VM_USER}" &>/dev/null; then
    echo "User '${VM_USER}' already exists, skipping creation."
    # An explicit --password is a valid re-run intent: reset it
    if [ "${PASSWORD_EXPLICIT}" = true ]; then
        echo "${VM_USER}:${VM_PASSWORD}" | chpasswd
        echo "Password for '${VM_USER}' reset from --password."
    fi
else
    useradd -m -s /bin/bash "${VM_USER}"
    echo "${VM_USER}:${VM_PASSWORD}" | chpasswd
    echo "User '${VM_USER}' created."
fi

# ------------------------------------------------------------------------------
# 2. Configure passwordless sudo for the user
# ------------------------------------------------------------------------------
echo "Configuring passwordless sudo for '${VM_USER}'..."
if [ ! -f "/etc/sudoers.d/${VM_USER}_nopasswd" ]; then
    echo "${VM_USER} ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/${VM_USER}_nopasswd"
    chmod 0440 "/etc/sudoers.d/${VM_USER}_nopasswd"
    echo "Passwordless sudo configured."
else
    echo "Passwordless sudo already configured."
fi

# ------------------------------------------------------------------------------
# 3. Update System
# ------------------------------------------------------------------------------
echo "Updating system packages..."
apt-get update -qq
apt-get upgrade -y -qq

# ------------------------------------------------------------------------------
# 4. Install System Dependencies & Core Tools
# ------------------------------------------------------------------------------
echo "Installing core tools..."
apt-get install -y \
    curl \
    git \
    nginx \
    build-essential \
    libssl-dev \
    zlib1g-dev \
    libbz2-dev \
    libreadline-dev \
    libsqlite3-dev \
    libncursesw5-dev \
    xz-utils \
    tk-dev \
    libxml2-dev \
    libxmlsec1-dev \
    libffi-dev \
    liblzma-dev \
    python3-full \
    python3-pip

# ------------------------------------------------------------------------------
# 5. Install uv (Fast Python package installer)
# ------------------------------------------------------------------------------
echo "Installing uv..."
curl -LsSf https://astral.sh/uv/install.sh | sh

# Make uv available globally (idempotent)
if [ -f "$HOME/.cargo/bin/uv" ] && [ ! -f /usr/local/bin/uv ]; then
    mv "$HOME/.cargo/bin/uv" /usr/local/bin/uv
fi

# ------------------------------------------------------------------------------
# 6. Configure Nginx
# ------------------------------------------------------------------------------
echo "Enabling and starting Nginx..."
systemctl enable nginx
systemctl start nginx

# ------------------------------------------------------------------------------
# 7. Install and Configure Samba
# ------------------------------------------------------------------------------
echo "Installing Samba..."
apt-get install -y samba

# Backup existing configuration
cp /etc/samba/smb.conf /etc/samba/smb.conf.bak

# Write unified Samba configuration
cat <<EOF > /etc/samba/smb.conf
#======================= Global Settings =======================

[global]

## Browsing/Identification ###
   workgroup = HOME

#### Debugging/Accounting ####
   log file = /var/log/samba/log.%m
   max log size = 1000
   logging = file
   panic action = /usr/share/samba/panic-action %d

####### Authentication #######
   server role = standalone server
   obey pam restrictions = yes
   unix password sync = yes
   passwd program = /usr/bin/passwd %u
   passwd chat = *Enter\snew\s*\spassword:* %n\n *Retype\snew\s*\spassword:* %n\n *password\supdated\ssuccessfully* .
   pam password change = yes
   map to guest = bad user

# Allow guests
   usershare allow guests = yes

#=========== macOS SMB optimizations ===========
   min protocol = SMB2
   vfs objects = fruit streams_xattr
   fruit:metadata = stream
   fruit:model = MacSamba
   fruit:posix_rename = yes
   fruit:veto_appledouble = no
   fruit:wipe_intentionally_left_blank_rfork = yes
   fruit:delete_empty_adfiles = yes

#======================= Share Definitions =======================

[homes]
   comment = Home Directories
   browseable = no
   read only = yes
   create mask = 0700
   directory mask = 0700
   valid users = %S

[${VM_USER}]
   path = /home/${VM_USER}
   comment = ${VM_USER} User Home
   browseable = yes
   read only = no
   writable = yes
   valid users = ${VM_USER}
   create mask = 0644
   directory mask = 0755
   force user = ${VM_USER}
   vfs objects = fruit streams_xattr
EOF

# Set Samba password for the user (runs on re-runs too, keeping the Samba
# password in sync with the Unix password)
echo "Setting Samba password for '${VM_USER}'..."
(echo "${VM_PASSWORD}"; echo "${VM_PASSWORD}") | smbpasswd -a "${VM_USER}" -s

# Restart Samba services
systemctl restart smbd nmbd

# ------------------------------------------------------------------------------
# 8. Setup UFW Firewall
# ------------------------------------------------------------------------------
echo "Configuring firewall..."
apt-get install -y ufw
ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 445/tcp   # SMB
ufw --force enable

# ------------------------------------------------------------------------------
# 9. Install Sublime Text
# ------------------------------------------------------------------------------
echo "Installing Sublime Text..."
if [ ! -f /usr/share/keyrings/sublimehq-archive.gpg ]; then
    curl -fsSL https://download.sublimetext.com/sublimehq-pub.gpg | gpg --dearmor -o /usr/share/keyrings/sublimehq-archive.gpg
fi
if [ ! -f /etc/apt/sources.list.d/sublime-text.list ]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/sublimehq-archive.gpg] https://download.sublimetext.com/ apt/stable/" > /etc/apt/sources.list.d/sublime-text.list
fi
apt-get update -qq
apt-get install -y sublime-text

# ------------------------------------------------------------------------------
# 10. Install Brave Browser
# ------------------------------------------------------------------------------
echo "Installing Brave Browser..."
if [ ! -f /usr/share/keyrings/brave-browser-archive-keyring.gpg ]; then
    curl -fsSL https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg -o /usr/share/keyrings/brave-browser-archive-keyring.gpg
fi
if [ ! -f /etc/apt/sources.list.d/brave-browser.list ]; then
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" > /etc/apt/sources.list.d/brave-browser.list
fi
apt-get update -qq
apt-get install -y brave-browser

# ------------------------------------------------------------------------------
# 11. Cleanup
# ------------------------------------------------------------------------------
echo "Cleaning up..."
apt-get autoremove -y
apt-get clean

# ------------------------------------------------------------------------------
# 12. Verification
# ------------------------------------------------------------------------------
echo ""
echo "============================================================"
echo "        Setup Complete - Verification"
echo "============================================================"
echo "Git:       $(git --version)"
echo "Python:    $(python3 --version)"
echo "Nginx:     $(nginx -v 2>&1)"
echo "UV:        $(uv --version 2>/dev/null || echo 'not found in PATH')"
echo "Sublime:   $(subl --version 2>/dev/null || echo 'installed (subl not in PATH)')"
echo "Brave:     $(brave-browser --version 2>/dev/null || echo 'installed')"
echo ""
echo "Samba shares configured:"
echo "  - [homes]      -> /home/* (per-user home)"
echo "  - [${VM_USER}] -> /home/${VM_USER}"
echo ""
IP_ADDR=$(hostname -I | awk '{print $1}')
echo "VM IP address: $IP_ADDR"
echo ""
echo "============================================================"
echo "To connect from macOS Finder:"
echo "  Cmd+K -> smb://$IP_ADDR/${VM_USER}"
echo "  Username: ${VM_USER}"
echo "  Password: (the --password you set, or 'debian' by default)"
echo "============================================================"