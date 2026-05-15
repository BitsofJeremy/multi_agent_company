#!/bin/bash
set -e

# ==============================================================================
# Unified Debian VM Setup Script
# Creates debian user, configures sudo, installs dev environment and Samba
# ==============================================================================

# Check if running as root
if [ "$EUID" -ne 0 ]; then
  echo "Please run as root (sudo)"
  exit 1
fi

echo "=== Unified Debian VM Setup ==="

# ------------------------------------------------------------------------------
# 1. Create 'debian' user if it doesn't exist
# ------------------------------------------------------------------------------
echo "Setting up 'debian' user..."
if id "debian" &>/dev/null; then
    echo "User 'debian' already exists, skipping creation."
else
    useradd -m -s /bin/bash debian
    echo "debian:debian" | chpasswd
    echo "User 'debian' created with password 'debian'"
fi

# ------------------------------------------------------------------------------
# 2. Configure passwordless sudo for 'debian' user
# ------------------------------------------------------------------------------
echo "Configuring passwordless sudo for 'debian'..."
if [ ! -f /etc/sudoers.d/debian_nopasswd ]; then
    echo "debian ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/debian_nopasswd
    chmod 0440 /etc/sudoers.d/debian_nopasswd
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

[debian]
   path = /home/debian
   comment = Debian User Home
   browseable = yes
   read only = no
   writable = yes
   valid users = debian
   create mask = 0644
   directory mask = 0755
   force user = debian
   vfs objects = fruit streams_xattr
EOF

# Set Samba password for debian user
echo "Setting Samba password for 'debian'..."
(echo "debian"; echo "debian") | smbpasswd -a debian -s

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
echo "  - [homes]    -> /home/* (per-user home)"
echo "  - [debian]   -> /home/debian"
echo ""
IP_ADDR=$(hostname -I | awk '{print $1}')
echo "VM IP address: $IP_ADDR"
echo ""
echo "============================================================"
echo "To connect from macOS Finder:"
echo "  Cmd+K -> smb://$IP_ADDR/debian"
echo "  Username: debian"
echo "  Password: debian"
echo "============================================================"