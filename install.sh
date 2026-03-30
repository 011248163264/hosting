#!/bin/bash
set -e

# Tor Hosting - Automated Installer for Debian 13 (Trixie)
# https://github.com/bigbong420/hosting
#
# One-liner install:
#   curl -sSL https://raw.githubusercontent.com/bigbong420/hosting/upgrades/install.sh | bash
# Or with options:
#   curl -sSL https://raw.githubusercontent.com/bigbong420/hosting/upgrades/install.sh | bash -s -- --non-interactive

REPO_URL="https://github.com/bigbong420/hosting.git"
REPO_BRANCH="upgrades"
ORIGINAL_ARGS=("$@")

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'
# Restore state from env vars (set when re-exec'd after auto-clone)
NONINTERACTIVE=${HOSTING_NONINTERACTIVE:-false}
SKIP_BINARIES=${HOSTING_SKIP_BINARIES:-false}
VANITY_PREFIX="${HOSTING_VANITY_PREFIX:-}"
VANITY_THREADS="${HOSTING_VANITY_THREADS:-}"
DB_HOSTING_PASS="${HOSTING_DB_PASS:-}"
DB_PMA_PASS="${HOSTING_PMA_PASS:-}"
ADMIN_PASS="${HOSTING_ADMIN_PASS:-}"
BLOWFISH_SECRET=""
ONION_ENC_KEY=""
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
log_step "Pre-flight checks"

if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

if [ -f /etc/os-release ]; then
    . /etc/os-release
fi

if [ -f /etc/debian_version ]; then
    DEBIAN_FULL=$(cat /etc/debian_version)
    DEBIAN_VERSION=$(echo "$DEBIAN_FULL" | cut -d. -f1)
    # Ubuntu 24.04 reports "trixie/sid", treat as compatible
    if echo "$DEBIAN_FULL" | grep -q "trixie"; then
        DEBIAN_VERSION=13
    fi
    if [ "$DEBIAN_VERSION" -ge 13 ] 2>/dev/null; then
        : # ok
    else
        log_error "Debian 13+ or Ubuntu 24.04+ required. You have: $DEBIAN_FULL"
        exit 1
    fi
elif [ "$ID" = "ubuntu" ]; then
    UBUNTU_MAJOR=$(echo "$VERSION_ID" | cut -d. -f1)
    if [ "$UBUNTU_MAJOR" -lt 24 ]; then
        log_error "Ubuntu 24.04+ required. You have: $VERSION_ID"
        exit 1
    fi
else
    log_error "This script requires Debian 13+ or Ubuntu 24.04+"
    exit 1
fi

log_ok "Running as root on ${PRETTY_NAME:-Debian $DEBIAN_FULL}"

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
    # Re-exec from the cloned copy, passing state via env vars
    export HOSTING_NONINTERACTIVE="$NONINTERACTIVE"
    export HOSTING_SKIP_BINARIES="$SKIP_BINARIES"
    export HOSTING_VANITY_PREFIX="$VANITY_PREFIX"
    export HOSTING_VANITY_THREADS="$VANITY_THREADS"
    export HOSTING_DB_PASS="$DB_HOSTING_PASS"
    export HOSTING_PMA_PASS="$DB_PMA_PASS"
    export HOSTING_ADMIN_PASS="$ADMIN_PASS"
    exec "$SCRIPT_DIR/install.sh" "${ORIGINAL_ARGS[@]}"
fi

log_ok "Repository found at $SCRIPT_DIR"

# Interactive prompts (skipped with --non-interactive)

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
log_step "Step 1: Purge conflicting packages"

DEBIAN_FRONTEND=noninteractive apt purge -y apache2* dnsmasq* eatmydata exim4* \
    imagemagick-6-common mysql-client* mysql-server* nginx* libnginx-mod* \
    php7* resolvconf 2>/dev/null || true

systemctl disable systemd-resolved.service 2>/dev/null || true
systemctl stop systemd-resolved.service 2>/dev/null || true

echo "nameserver 1.1.1.1" > /etc/resolv.conf
log_ok "DNS set to 1.1.1.1"
log_step "Step 2: Add repositories"

apt update -qq
apt install -y -qq git apt-transport-tor curl lsb-release

CODENAME=$(lsb_release -cs)
IS_UBUNTU=false
[ "${ID:-}" = "ubuntu" ] && IS_UBUNTU=true

curl -sSL https://deb.torproject.org/torproject.org/A3C4F0F979CAA22CDBA8F512EE8CBC9E886DDD89.asc \
    > /etc/apt/trusted.gpg.d/torproject.asc
grep -q "torproject.org" /etc/apt/sources.list || \
    echo "deb tor://apow7mjfryruh65chtdydfmqfpj5btws7nbocgtaovhvezgccyjazpqd.onion/torproject.org/ $CODENAME main" >> /etc/apt/sources.list

# Sury nginx repo only needed on Debian (Ubuntu has nginx + brotli natively)
if [ "$IS_UBUNTU" = false ]; then
    curl -sSL https://packages.sury.org/nginx/apt.gpg \
        > /etc/apt/trusted.gpg.d/sury.gpg
    grep -q "sury.org" /etc/apt/sources.list || \
        echo "deb https://packages.sury.org/nginx/ $CODENAME main" >> /etc/apt/sources.list
fi

# Prevent Ubuntu from auto-rebooting during upgrade
if [ "$IS_UBUNTU" = true ]; then
    systemctl mask needrestart.service 2>/dev/null || true
    export NEEDRESTART_SUSPEND=1
    export NEEDRESTART_MODE=l
fi

apt update -qq
DEBIAN_FRONTEND=noninteractive apt upgrade -y

if [ "$IS_UBUNTU" = true ]; then
    systemctl unmask needrestart.service 2>/dev/null || true
fi
log_ok "Repositories configured"
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
log_step "Step 5: Copy site and config files"

cp -a "$SCRIPT_DIR/var/www/"* /var/www/
cp -a "$SCRIPT_DIR/etc/"* /etc/
chown root:bind /etc/bind/ -R 2>/dev/null || true
# Remove Ubuntu module-enabled symlinks that conflict with our nginx.conf
rm -f /etc/nginx/modules-enabled/mod-http-brotli-*.conf /etc/nginx/modules-enabled/mod-stream.conf 2>/dev/null || true

log_ok "Files copied"
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
log_step "Step 7: Configure Tor"

systemctl restart bind9.service 2>/dev/null || systemctl restart named.service 2>/dev/null || true
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
log_step "Step 8: Configure hosting"

ADMIN_HASH=$(php8.2 -r "echo password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);" 2>/dev/null || \
             php8.5 -r "echo password_hash('$ADMIN_PASS', PASSWORD_DEFAULT);")
sed -i "s|const DBPASS='MY_PASSWORD'|const DBPASS='$DB_HOSTING_PASS'|" /var/www/common.php
sed -i "s|const ADMIN_PASSWORD='MY_PASSWORD'|const ADMIN_PASSWORD='$ADMIN_HASH'|" /var/www/common.php
sed -i "s|const ONION_KEY_ENCRYPTION_KEY=''|const ONION_KEY_ENCRYPTION_KEY='$ONION_ENC_KEY'|" /var/www/common.php
sed -i "s|password = MY_PASSWORD|password = $DB_HOSTING_PASS|" /etc/postfix/sql/alias.cf
sed -i "s|hosts = localhost|hosts = 127.0.0.1|" /etc/postfix/sql/alias.cf

# Replace default onion domain everywhere
DEFAULT_ONION="dhosting4xxoydyaivckq7tsmtgi4wfs3flpeyitekkmqwu4v4r46syd.onion"
ONION_CONFIG_FILES="/etc/postfix/sql/alias.cf /etc/postfix/sender_login_maps /etc/postfix/main.cf /var/www/skel/www/index.hosting.html /var/www/common.php /etc/postfix/canonical /etc/postfix-clearnet/canonical /var/www/html/squirrelmail/config/config.php"
sed -i "s/$DEFAULT_ONION/$ONION_ADDR/g" $ONION_CONFIG_FILES

log_ok "Configuration applied"
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
log_step "Step 10: Configure Postfix"

postalias /etc/aliases
postmap /etc/postfix/canonical /etc/postfix/sender_login_maps /etc/postfix/transport

log_ok "Postfix maps created"
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
log_step "Step 12: Install Composer dependencies"

echo "nameserver 1.1.1.1" > /etc/resolv.conf
cd /var/www
COMPOSER_ALLOW_SUPERUSER=1 composer install 2>&1 | tail -3

if [ ! -f /var/www/vendor/autoload.php ]; then
    log_warn "Composer install failed, retrying..."
    sleep 5
    COMPOSER_ALLOW_SUPERUSER=1 composer install 2>&1 | tail -3
fi

if [ ! -f /var/www/vendor/autoload.php ]; then
    log_error "Composer install failed. Check DNS/network."
    exit 1
fi

log_ok "Composer dependencies installed"
log_step "Step 13: Configure MySQL"

mysql -e "CREATE USER IF NOT EXISTS 'phpmyadmin'@'%' IDENTIFIED BY '$DB_PMA_PASS';
CREATE DATABASE IF NOT EXISTS phpmyadmin;
GRANT ALL PRIVILEGES ON phpmyadmin.* TO 'phpmyadmin'@'%';
CREATE USER IF NOT EXISTS 'hosting'@'%' IDENTIFIED BY '$DB_HOSTING_PASS';
GRANT ALL PRIVILEGES ON *.* TO 'hosting'@'%' WITH GRANT OPTION;
FLUSH PRIVILEGES;"

mysql phpmyadmin < /var/www/html/phpmyadmin/sql/create_tables.sql 2>/dev/null || true
sed -i "s|\$cfg\['blowfish_secret'\] = '.*'|\$cfg['blowfish_secret'] = '$BLOWFISH_SECRET'|" \
    /var/www/html/phpmyadmin/config.inc.php
sed -i "s|YOUR_PASSWORD|$DB_PMA_PASS|g" /var/www/html/phpmyadmin/config.inc.php 2>/dev/null || true

log_ok "MySQL users and databases created"
log_step "Step 14: Run setup.php"

php8.2 /var/www/setup.php 2>&1 || true
mkdir -p /var/log/nginx /var/run/nginx
for ver in 8.2 8.3 8.4 8.5; do
    systemctl enable "php$ver-fpm@default" 2>/dev/null || true
    systemctl start "php$ver-fpm@default" 2>/dev/null || true
done
systemctl restart nginx 2>/dev/null || true

log_ok "Setup complete"
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
    sed -i "s|$ONION_ADDR|$NEW_ONION|g" $ONION_CONFIG_FILES

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
log_step "Step 16: Final configuration"

systemctl enable hosting-del.timer hosting.timer hosting-autoscale.timer
systemctl start hosting-autoscale.timer
sed -i 's/^Subsystem/#Subsystem/' /etc/ssh/sshd_config
systemctl restart nginx postfix dovecot
systemctl restart tor@default.service

log_ok "Timers enabled, services configured"
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
echo -e "${BOLD}Instances:${NC}    auto-scaling (1 per ~250 accounts, checked hourly)"
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
