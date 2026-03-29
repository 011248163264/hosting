#!/bin/bash
set -e

# ============================================================================
# Tor Hosting - Automated Installer for Debian 13 (Trixie)
# https://github.com/bigbong420/hosting
#
# One-liner install:
#   curl -sSL https://raw.githubusercontent.com/bigbong420/hosting/upgrades/install.sh | bash
# Or with options:
#   curl -sSL https://raw.githubusercontent.com/bigbong420/hosting/upgrades/install.sh | bash -s -- --non-interactive
# ============================================================================

REPO_URL="https://github.com/bigbong420/hosting.git"
REPO_BRANCH="upgrades"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
NONINTERACTIVE=false
SKIP_BINARIES=false
VANITY_PREFIX=""
VANITY_THREADS=""
DB_HOSTING_PASS=""
DB_PMA_PASS=""
ADMIN_PASS=""
BLOWFISH_SECRET=""
ONION_ENC_KEY=""

# ============================================================================
# Functions
# ============================================================================

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}\n"; }

gen_pass() { openssl rand -hex 16; }

usage() {
    cat <<'EOF'
Usage: ./install.sh [OPTIONS]

Options:
  --non-interactive     Skip all prompts, generate random passwords
  --skip-binaries       Skip compiling PHP/ImageMagick (use if already built)
  --vanity <prefix>     Generate a vanity .onion address with this prefix
  --vanity-threads <n>  Number of threads for vanity generation (default: nproc)
  --db-pass <pass>      Set hosting MySQL password
  --pma-pass <pass>     Set phpMyAdmin MySQL password
  --admin-pass <pass>   Set admin panel password
  -h, --help            Show this help

Examples:
  ./install.sh                          # Interactive install
  ./install.sh --non-interactive        # Fully automated with random passwords
  ./install.sh --vanity mysite          # Generate vanity onion starting with "mysite"
EOF
    exit 0
}

# ============================================================================
# Parse arguments
# ============================================================================

while [[ $# -gt 0 ]]; do
    case "$1" in
        --non-interactive) NONINTERACTIVE=true; shift ;;
        --skip-binaries)   SKIP_BINARIES=true; shift ;;
        --vanity)          VANITY_PREFIX="$2"; shift 2 ;;
        --vanity-threads)  VANITY_THREADS="$2"; shift 2 ;;
        --db-pass)         DB_HOSTING_PASS="$2"; shift 2 ;;
        --pma-pass)        DB_PMA_PASS="$2"; shift 2 ;;
        --admin-pass)      ADMIN_PASS="$2"; shift 2 ;;
        -h|--help)         usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

# ============================================================================
# Pre-flight checks
# ============================================================================

log_step "Pre-flight checks"

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

if [ ! -f /etc/debian_version ]; then
    log_error "This script requires Debian"
    exit 1
fi

DEBIAN_VERSION=$(cat /etc/debian_version | cut -d. -f1)
if [ "$DEBIAN_VERSION" -lt 13 ]; then
    log_error "Debian 13 (Trixie) or newer is required. You have: $(cat /etc/debian_version)"
    log_error "Upgrade to Debian 13 first."
    exit 1
fi

log_ok "Running as root on Debian $(cat /etc/debian_version)"

# Auto-clone repo if not running from within it
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
if [ ! -f "$SCRIPT_DIR/install_binaries.sh" ]; then
    log_info "Repository not found locally. Cloning..."
    apt update -qq
    apt install -y -qq git 2>/dev/null
    SCRIPT_DIR="/root/hosting"
    if [ -d "$SCRIPT_DIR" ]; then
        cd "$SCRIPT_DIR" && git pull origin "$REPO_BRANCH" 2>/dev/null || true
    else
        git clone -b "$REPO_BRANCH" "$REPO_URL" "$SCRIPT_DIR"
    fi
    log_ok "Repository cloned to $SCRIPT_DIR"
    # Re-exec from the cloned copy so all paths work
    exec "$SCRIPT_DIR/install.sh" "$@"
fi

log_ok "Repository found at $SCRIPT_DIR"

# ============================================================================
# Interactive prompts (skipped with --non-interactive)
# ============================================================================

if [ "$NONINTERACTIVE" = false ]; then
    log_step "Configuration"

    # --- Passwords ---
    echo -e "${BOLD}Password Configuration${NC}"
    echo "You can enter custom passwords or let the installer generate secure random ones."
    echo ""

    if [ -z "$DB_HOSTING_PASS" ]; then
        read -p "Hosting MySQL password [leave empty to generate]: " DB_HOSTING_PASS
    fi
    if [ -z "$DB_PMA_PASS" ]; then
        read -p "phpMyAdmin MySQL password [leave empty to generate]: " DB_PMA_PASS
    fi
    if [ -z "$ADMIN_PASS" ]; then
        read -p "Admin panel password [leave empty to generate]: " ADMIN_PASS
    fi

    # --- Vanity onion ---
    echo ""
    echo -e "${BOLD}Onion Address Configuration${NC}"
    echo "You can generate a vanity .onion address with a custom prefix."
    echo "Only characters a-z and 2-7 are valid (base32)."
    echo ""
    echo "Estimated generation times:"
    echo "  3 chars  ~seconds"
    echo "  4 chars  ~minutes"
    echo "  5 chars  ~10-30 minutes"
    echo "  6 chars  ~hours"
    echo "  7+ chars ~days (not recommended)"
    echo ""

    if [ -z "$VANITY_PREFIX" ]; then
        read -p "Vanity onion prefix [leave empty for random]: " VANITY_PREFIX
    fi

    if [ -n "$VANITY_PREFIX" ]; then
        # Validate base32
        if ! echo "$VANITY_PREFIX" | grep -qP '^[a-z2-7]+$'; then
            log_error "Invalid prefix. Only lowercase a-z and digits 2-7 are allowed."
            exit 1
        fi
        PREFIX_LEN=${#VANITY_PREFIX}
        if [ "$PREFIX_LEN" -gt 7 ]; then
            log_warn "Prefix '$VANITY_PREFIX' is $PREFIX_LEN characters. This could take days or weeks."
            read -p "Continue anyway? [y/N]: " CONFIRM
            if [ "$CONFIRM" != "y" ] && [ "$CONFIRM" != "Y" ]; then
                exit 0
            fi
        fi
    fi
fi

# Generate any passwords that weren't provided
[ -z "$DB_HOSTING_PASS" ] && DB_HOSTING_PASS=$(gen_pass)
[ -z "$DB_PMA_PASS" ]     && DB_PMA_PASS=$(gen_pass)
[ -z "$ADMIN_PASS" ]      && ADMIN_PASS=$(gen_pass)
[ -z "$BLOWFISH_SECRET" ] && BLOWFISH_SECRET=$(gen_pass)
[ -z "$ONION_ENC_KEY" ]   && ONION_ENC_KEY=$(openssl rand -hex 32)

echo ""
log_info "Installation will proceed with the following:"
echo "  Hosting DB password:   $DB_HOSTING_PASS"
echo "  phpMyAdmin DB password: $DB_PMA_PASS"
echo "  Admin panel password:   $ADMIN_PASS"
echo "  Vanity prefix:          ${VANITY_PREFIX:-<random>}"
echo ""

if [ "$NONINTERACTIVE" = false ]; then
    read -p "Proceed with installation? [Y/n]: " CONFIRM
    if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
        exit 0
    fi
fi

# Save credentials to file
CREDS_FILE="/root/hosting-credentials.txt"
cat > "$CREDS_FILE" <<EOF
=== Daniel's Hosting Credentials ===
Generated: $(date)

Hosting MySQL User:     hosting
Hosting MySQL Password: $DB_HOSTING_PASS

phpMyAdmin MySQL User:     phpmyadmin
phpMyAdmin MySQL Password: $DB_PMA_PASS

Admin Panel Password: $ADMIN_PASS

Blowfish Secret:          $BLOWFISH_SECRET
Onion Key Encryption Key: $ONION_ENC_KEY
EOF
chmod 600 "$CREDS_FILE"
log_ok "Credentials saved to $CREDS_FILE"

# ============================================================================
# Step 1: Purge conflicting packages and fix DNS
# ============================================================================

log_step "Step 1: Purge conflicting packages"

DEBIAN_FRONTEND=noninteractive apt purge -y apache2* dnsmasq* eatmydata exim4* \
    imagemagick-6-common mysql-client* mysql-server* nginx* libnginx-mod* \
    php7* resolvconf 2>/dev/null || true

systemctl disable systemd-resolved.service 2>/dev/null || true
systemctl stop systemd-resolved.service 2>/dev/null || true

echo "nameserver 1.1.1.1" > /etc/resolv.conf
log_ok "DNS set to 1.1.1.1"

# ============================================================================
# Step 2: Add repositories
# ============================================================================

log_step "Step 2: Add repositories"

apt update -qq
apt install -y -qq git apt-transport-tor curl lsb-release

curl -sSL https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc \
    > /etc/apt/trusted.gpg.d/torproject.asc
curl -sSL https://packages.sury.org/nginx/apt.gpg \
    > /etc/apt/trusted.gpg.d/sury.gpg

CODENAME=$(lsb_release -cs)

# Only add if not already present
grep -q "torproject.org" /etc/apt/sources.list || \
    echo "deb tor://apow7mjfryruh65chtdydfmqfpj5btws7nbocgtaovhvezgccyjazpqd.onion/torproject.org/ $CODENAME main" >> /etc/apt/sources.list
grep -q "sury.org" /etc/apt/sources.list || \
    echo "deb https://packages.sury.org/nginx/ $CODENAME main" >> /etc/apt/sources.list

apt update -qq
DEBIAN_FRONTEND=noninteractive apt upgrade -y
log_ok "Repositories configured"

# ============================================================================
# Step 3: Build binaries (PHP, ImageMagick, etc)
# ============================================================================

if [ "$SKIP_BINARIES" = true ]; then
    log_step "Step 3: Skipping binary compilation (--skip-binaries)"
else
    log_step "Step 3: Building binaries (this will take a while)"
    log_info "Compiling ImageMagick, PHP 8.5, 8.4, 8.3, 8.2, and web applications..."

    cd "$SCRIPT_DIR"
    bash ./install_binaries.sh 2>&1 | tee /root/install_binaries.log

    if [ ${PIPESTATUS[0]} -ne 0 ]; then
        log_error "install_binaries.sh failed. Check /root/install_binaries.log"
        exit 1
    fi
    log_ok "All binaries compiled and installed"
fi

# ============================================================================
# Step 4: Vanity onion generation (if requested)
# ============================================================================

if [ -n "$VANITY_PREFIX" ]; then
    log_step "Step 4: Generating vanity .onion address (prefix: $VANITY_PREFIX)"

    if [ ! -d /tmp/mkp224o ]; then
        cd /tmp
        apt install -y -qq libsodium-dev autoconf make gcc
        git clone https://github.com/cathugger/mkp224o.git mkp224o
        cd mkp224o
        ./autogen.sh
        ./configure --enable-donna64
        make -j$(nproc)
    fi

    VANITY_THREADS=${VANITY_THREADS:-$(nproc)}
    VANITY_OUT="/tmp/vanity-onion"
    mkdir -p "$VANITY_OUT"

    log_info "Searching for prefix '$VANITY_PREFIX' with $VANITY_THREADS threads..."
    log_info "This may take a while depending on prefix length."

    /tmp/mkp224o/mkp224o -t "$VANITY_THREADS" -n 1 -s -d "$VANITY_OUT" "$VANITY_PREFIX"

    VANITY_DIR=$(ls -d "$VANITY_OUT"/*.onion 2>/dev/null | head -1)
    if [ -z "$VANITY_DIR" ]; then
        log_error "Vanity generation failed — no match found"
        VANITY_PREFIX=""
    else
        VANITY_HOSTNAME=$(cat "$VANITY_DIR/hostname" | tr -d '[:space:]')
        VANITY_SECRET=$(cat "$VANITY_DIR/hs_ed25519_secret_key" | base64 -w0)
        log_ok "Generated vanity address: ${GREEN}${VANITY_HOSTNAME}${NC}"
    fi
else
    log_step "Step 4: Skipping vanity generation (random onion)"
fi

# ============================================================================
# Step 5: Copy site and config files
# ============================================================================

log_step "Step 5: Copy site and config files"

cp -a "$SCRIPT_DIR/var/www/"* /var/www/
cp -a "$SCRIPT_DIR/etc/"* /etc/

log_ok "Files copied"

# ============================================================================
# Step 6: Create systemd service files for all PHP versions
# ============================================================================

log_step "Step 6: Create PHP-FPM systemd service files"

# 8.2 service files should exist from install_binaries.sh packages
for ver in 8.3 8.4 8.5; do
    for tmpl in /etc/systemd/system/php8.2-fpm*.service; do
        [ -f "$tmpl" ] || continue
        newfile=$(echo "$tmpl" | sed "s/8.2/$ver/g")
        [ -f "$newfile" ] || sed "s/8.2/$ver/g" "$tmpl" > "$newfile"
    done
done

systemctl daemon-reload
log_ok "PHP-FPM service files created for 8.2, 8.3, 8.4, 8.5"

# ============================================================================
# Step 7: Start Tor and get .onion address
# ============================================================================

log_step "Step 7: Configure Tor"

systemctl restart bind9.service
systemctl restart tor@default.service
sleep 3

ONION_ADDR=$(cat /var/lib/tor/hidden_service/hostname 2>/dev/null || echo "")
if [ -z "$ONION_ADDR" ]; then
    log_error "Tor hidden service hostname not found. Waiting..."
    sleep 10
    ONION_ADDR=$(cat /var/lib/tor/hidden_service/hostname 2>/dev/null || echo "")
fi

if [ -z "$ONION_ADDR" ]; then
    log_error "Could not get .onion address. Check tor configuration."
    exit 1
fi

log_ok "Onion address: ${GREEN}${ONION_ADDR}${NC}"

# ============================================================================
# Step 8: Configure common.php
# ============================================================================

log_step "Step 8: Configure hosting"

ADMIN_HASH=$(php8.2 -r "echo password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);" 2>/dev/null || \
             php8.5 -r "echo password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);")

# Replace passwords and settings
sed -i "s|const DBPASS='MY_PASSWORD'|const DBPASS='$DB_HOSTING_PASS'|" /var/www/common.php
sed -i "s|const ADMIN_PASSWORD='MY_PASSWORD'|const ADMIN_PASSWORD='$ADMIN_HASH'|" /var/www/common.php
sed -i "s|const ONION_KEY_ENCRYPTION_KEY=''|const ONION_KEY_ENCRYPTION_KEY='$ONION_ENC_KEY'|" /var/www/common.php

# Replace default onion domain everywhere
DEFAULT_ONION="dhosting4xxoydyaivckq7tsmtgi4wfs3flpeyitekkmqwu4v4r46syd.onion"
sed -i "s/$DEFAULT_ONION/$ONION_ADDR/g" \
    /etc/postfix/sql/alias.cf \
    /etc/postfix/sender_login_maps \
    /etc/postfix/main.cf \
    /var/www/skel/www/index.hosting.html \
    /var/www/common.php \
    /etc/postfix/canonical \
    /etc/postfix-clearnet/canonical \
    /var/www/html/squirrelmail/config/config.php

log_ok "Configuration applied"

# ============================================================================
# Step 9: Configure Dovecot for Debian 13
# ============================================================================

log_step "Step 9: Configure Dovecot"

# Dovecot 2.4 in trixie has different config syntax
# Comment out old conf.d include if it causes issues
if ! doveconf 2>&1 | grep -q "^# OS:"; then
    log_warn "Dovecot config has errors, applying Debian 13 fix..."
    sed -i 's|^!include conf.d|#!include conf.d|' /etc/dovecot/dovecot.conf
    cat > /etc/dovecot/local.conf <<'DOVECOT'
mail_driver = maildir
mail_path = ~/Maildir
protocols = imap pop3 lmtp
listen = 127.0.0.1
ssl = no
auth_mechanisms = plain login
passdb pam {
  driver = pam
}
userdb passwd {
  driver = passwd
}
service lmtp {
  unix_listener /var/spool/postfix/private/dovecot-lmtp {
    mode = 0600
    user = postfix
    group = postfix
  }
}
service auth {
  unix_listener /var/spool/postfix/private/auth {
    mode = 0660
    user = postfix
    group = postfix
  }
}
DOVECOT
fi

systemctl restart dovecot
log_ok "Dovecot configured"

# ============================================================================
# Step 10: Postfix maps
# ============================================================================

log_step "Step 10: Configure Postfix"

postalias /etc/aliases
postmap /etc/postfix/canonical /etc/postfix/sender_login_maps /etc/postfix/transport

log_ok "Postfix maps created"

# ============================================================================
# Step 11: Configure fstab (tmpfs, hidepid, quota)
# ============================================================================

log_step "Step 11: Configure fstab and quota"

grep -q "tmpfs /tmp" /etc/fstab || \
    echo "tmpfs /tmp tmpfs defaults,noatime 0 0" >> /etc/fstab
grep -q "tmpfs /var/log/nginx" /etc/fstab || \
    echo "tmpfs /var/log/nginx tmpfs rw,user,noatime 0 0" >> /etc/fstab
grep -q "hidepid" /etc/fstab || \
    echo "proc /proc proc defaults,hidepid=2 0 0" >> /etc/fstab

# Add quota options to root or /home mount
if grep -q "/home" /etc/fstab && ! grep -q "usrjquota" /etc/fstab; then
    sed -i '/\/home/s/defaults/defaults,noatime,usrjquota=aquota.user,jqfmt=vfsv1/' /etc/fstab
elif ! grep -q "usrjquota" /etc/fstab; then
    sed -i '/errors=remount-ro/s/errors=remount-ro/errors=remount-ro,noatime,usrjquota=aquota.user,jqfmt=vfsv1/' /etc/fstab
fi

systemctl daemon-reload
QUOTA_TARGET=$(findmnt -n -o TARGET --target /home 2>/dev/null || echo "/")
mount -o remount "$QUOTA_TARGET" 2>/dev/null || true
quotacheck -cMu "$QUOTA_TARGET" 2>/dev/null || true
quotaon "$QUOTA_TARGET" 2>/dev/null || true

log_ok "Filesystem configured"

# ============================================================================
# Step 12: Composer install (sodium_compat)
# ============================================================================

log_step "Step 12: Install Composer dependencies"

cd /var/www
COMPOSER_ALLOW_SUPERUSER=1 composer install 2>&1 | tail -3

log_ok "Composer dependencies installed"

# ============================================================================
# Step 13: MySQL setup
# ============================================================================

log_step "Step 13: Configure MySQL"

mysql -e "CREATE USER IF NOT EXISTS 'phpmyadmin'@'%' IDENTIFIED BY '$DB_PMA_PASS';
CREATE DATABASE IF NOT EXISTS phpmyadmin;
GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'phpmyadmin'@'%';
FLUSH PRIVILEGES;"

mysql phpmyadmin < /var/www/html/phpmyadmin/sql/create_tables.sql 2>/dev/null || true

mysql -e "CREATE USER IF NOT EXISTS 'hosting'@'%' IDENTIFIED BY '$DB_HOSTING_PASS';
GRANT ALL PRIVILEGES ON *.* TO 'hosting'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;"

# Configure phpMyAdmin
sed -i "s|\$cfg\['blowfish_secret'\] = '.*'|\$cfg['blowfish_secret'] = '$BLOWFISH_SECRET'|" \
    /var/www/html/phpmyadmin/config.inc.php
sed -i "s|YOUR_PASSWORD|$DB_PMA_PASS|g" /var/www/html/phpmyadmin/config.inc.php 2>/dev/null || true

log_ok "MySQL users and databases created"

# ============================================================================
# Step 14: Run setup.php
# ============================================================================

log_step "Step 14: Run setup.php"

php8.2 /var/www/setup.php 2>&1 || true

# Ensure nginx runtime directories exist
mkdir -p /var/log/nginx /var/run/nginx

log_ok "Setup complete"

# ============================================================================
# Step 15: Vanity onion import (if generated)
# ============================================================================

if [ -n "$VANITY_PREFIX" ] && [ -n "$VANITY_SECRET" ]; then
    log_step "Step 15: Import vanity onion address"

    # Replace the auto-generated hidden service with our vanity one
    rm -rf /var/lib/tor/hidden_service/*
    cp "$VANITY_DIR/hostname" /var/lib/tor/hidden_service/hostname
    cp "$VANITY_DIR/hs_ed25519_secret_key" /var/lib/tor/hidden_service/hs_ed25519_secret_key
    cp "$VANITY_DIR/hs_ed25519_public_key" /var/lib/tor/hidden_service/hs_ed25519_public_key
    chown -R debian-tor:debian-tor /var/lib/tor/hidden_service/
    chmod 700 /var/lib/tor/hidden_service/
    chmod 600 /var/lib/tor/hidden_service/*

    # Update all config files with the vanity address
    NEW_ONION=$(cat /var/lib/tor/hidden_service/hostname | tr -d '[:space:]')
    sed -i "s|$ONION_ADDR|$NEW_ONION|g" \
        /etc/postfix/sql/alias.cf \
        /etc/postfix/sender_login_maps \
        /etc/postfix/main.cf \
        /var/www/skel/www/index.hosting.html \
        /var/www/common.php \
        /etc/postfix/canonical \
        /etc/postfix-clearnet/canonical \
        /var/www/html/squirrelmail/config/config.php

    # Rebuild postfix maps with new address
    postmap /etc/postfix/canonical /etc/postfix/sender_login_maps /etc/postfix/transport

    ONION_ADDR="$NEW_ONION"
    systemctl restart tor@default.service

    # Update credentials file
    echo "" >> "$CREDS_FILE"
    echo "Vanity Onion: $ONION_ADDR" >> "$CREDS_FILE"

    log_ok "Vanity address imported: ${GREEN}${ONION_ADDR}${NC}"

    # Cleanup
    rm -rf /tmp/vanity-onion /tmp/mkp224o
else
    log_step "Step 15: Skipping vanity import"
fi

# ============================================================================
# Step 16: Enable timers and disable sftp subsystem
# ============================================================================

log_step "Step 16: Final configuration"

systemctl enable hosting-del.timer hosting.timer
sed -i 's/^Subsystem/#Subsystem/' /etc/ssh/sshd_config

# Restart all services
systemctl restart nginx postfix dovecot
systemctl restart tor@default.service

log_ok "Timers enabled, services configured"

# ============================================================================
# Summary
# ============================================================================

log_step "Installation Complete"

echo -e "${BOLD}Onion Address:${NC}  ${GREEN}http://${ONION_ADDR}${NC}"
echo ""
echo -e "${BOLD}Credentials:${NC}"
echo "  Hosting DB password:    $DB_HOSTING_PASS"
echo "  phpMyAdmin DB password: $DB_PMA_PASS"
echo "  Admin panel password:   $ADMIN_PASS"
echo ""
echo -e "${BOLD}Credentials saved to:${NC} $CREDS_FILE"
echo ""
echo -e "${BOLD}PHP Versions:${NC} 8.2, 8.3, 8.4, 8.5 (default: 8.5)"
echo ""
echo -e "${YELLOW}Recommended: Reboot the server now and wait ~5 minutes for all services to start.${NC}"
echo ""

if [ "$NONINTERACTIVE" = false ]; then
    read -p "Reboot now? [Y/n]: " REBOOT
    if [ "$REBOOT" != "n" ] && [ "$REBOOT" != "N" ]; then
        log_info "Rebooting..."
        reboot
    fi
else
    log_info "Non-interactive mode: skipping reboot. Run 'reboot' when ready."
fi
