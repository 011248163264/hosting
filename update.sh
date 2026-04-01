#!/bin/bash
set -e

# Tor Hosting - Update Script
# https://github.com/DanWin/hosting
#
# Updates the hosting platform without rebuilding binaries.
# For full reinstall including PHP/ImageMagick, use install.sh instead.
#
# Usage:
#   ./update.sh                  # Update code + configs
#   ./update.sh --rebuild        # Also rebuild PHP/ImageMagick
#   ./update.sh --php-only       # Only rebuild PHP (skip ImageMagick)
#   ./update.sh --code-only      # Only update PHP code, no config changes

REPO_URL="https://github.com/DanWin/hosting.git"
REPO_BRANCH="master"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

REBUILD=false
PHP_ONLY=false
CODE_ONLY=false

log_info()  { echo -e "${CYAN}[INFO]${NC} $1"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }
log_step()  { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}\n"; }

usage() {
    cat <<'EOF'
Usage: ./update.sh [OPTIONS]

Options:
  --rebuild       Rebuild PHP and ImageMagick from source
  --php-only      Only rebuild PHP (skip ImageMagick if already built)
  --code-only     Only update PHP code files, skip config/service changes
  -h, --help      Show this help

What this script does:
  1. Pulls latest code from the repository
  2. Updates PHP files in /var/www/
  3. Preserves your passwords, onion address, and encryption keys
  4. Restarts PHP-FPM and nginx
  5. Optionally rebuilds PHP/ImageMagick binaries
EOF
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --rebuild)   REBUILD=true; shift ;;
        --php-only)  PHP_ONLY=true; shift ;;
        --code-only) CODE_ONLY=true; shift ;;
        -h|--help)   usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done
log_step "Pre-flight checks"

if [ "$(id -u)" -ne 0 ]; then
    log_error "Must be run as root"
    exit 1
fi

if [ -d "/root/hosting" ]; then
    REPO_DIR="/root/hosting"
elif [ -d "$(dirname "$0")/.git" ]; then
    REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    log_error "Repository not found. Expected at /root/hosting"
    exit 1
fi

log_ok "Repository at $REPO_DIR"
log_step "Backing up current configuration"

BACKUP_DIR="/root/hosting-backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
if [ -f /var/www/common.php ]; then
    cp /var/www/common.php "$BACKUP_DIR/common.php.bak"
    eval $(php8.2 -r "
        require('/var/www/common.php');
        echo 'DBHOST=' . escapeshellarg(DBHOST) . '\n';
        echo 'DBPASS=' . escapeshellarg(DBPASS) . '\n';
        echo 'ADMIN_PASSWORD=' . escapeshellarg(ADMIN_PASSWORD) . '\n';
        echo 'ADDRESS=' . escapeshellarg(ADDRESS) . '\n';
        echo 'ONION_KEY_ENCRYPTION_KEY=' . escapeshellarg(ONION_KEY_ENCRYPTION_KEY) . '\n';
    " 2>/dev/null)
    log_ok "Secrets extracted from current config"
else
    log_error "No /var/www/common.php found. Run install.sh first."
    exit 1
fi

if [ -z "$DBPASS" ] || [ -z "$ADDRESS" ]; then
    log_error "Could not read current configuration. Aborting."
    exit 1
fi

log_ok "Backup saved to $BACKUP_DIR"
log_step "Pulling latest code"

cd "$REPO_DIR"
OLD_BINARIES_HASH=""
if [ -f "$REPO_DIR/install_binaries.sh" ]; then
    OLD_BINARIES_HASH=$(md5sum "$REPO_DIR/install_binaries.sh" | cut -d' ' -f1)
fi

git fetch origin "$REPO_BRANCH"
git reset --hard "origin/$REPO_BRANCH"

NEW_BINARIES_HASH=$(md5sum "$REPO_DIR/install_binaries.sh" | cut -d' ' -f1)

log_ok "Code updated to latest"
BINARIES_CHANGED=false
if [ "$OLD_BINARIES_HASH" != "$NEW_BINARIES_HASH" ] && [ -n "$OLD_BINARIES_HASH" ]; then
    BINARIES_CHANGED=true
    log_warn "install_binaries.sh has changed since last update"

    # Detect what changed
    CHANGES=""
    # Check for PHP version tag changes
    NEW_PHP_VERSIONS=$(grep -oP 'git checkout php-\K[0-9.]+' "$REPO_DIR/install_binaries.sh" | sort)
    for ver in $NEW_PHP_VERSIONS; do
        MAJOR_MINOR=$(echo "$ver" | cut -d. -f1-2)
        if [ ! -f "/usr/sbin/php-fpm$MAJOR_MINOR" ]; then
            CHANGES="$CHANGES  - PHP $ver (new, not yet built)\n"
        else
            INSTALLED_VER=$("/usr/bin/php$MAJOR_MINOR" -v 2>/dev/null | grep -oP 'PHP \K[0-9.]+' || echo "unknown")
            if [ "$INSTALLED_VER" != "$ver" ]; then
                CHANGES="$CHANGES  - PHP $MAJOR_MINOR: installed=$INSTALLED_VER, repo=$ver\n"
            fi
        fi
    done

    # Check ImageMagick version
    NEW_IM_VER=$(grep -oP 'git checkout \K[0-9.]+[-0-9]*' "$REPO_DIR/install_binaries.sh" | head -1)
    CUR_IM_VER=$(magick --version 2>/dev/null | grep -oP 'ImageMagick \K[0-9.]+-[0-9]+' || echo "not installed")
    if [ "$NEW_IM_VER" != "$CUR_IM_VER" ]; then
        CHANGES="$CHANGES  - ImageMagick: installed=$CUR_IM_VER, repo=$NEW_IM_VER\n"
    fi

    # Check extension versions
    for ext_line in $(grep -oP '(igbinary|imagick|php-ext-brotli|msgpack-php|apcu).*checkout \K\S+' "$REPO_DIR/install_binaries.sh"); do
        CHANGES="$CHANGES  - Extension update: $ext_line\n"
    done

    if [ -n "$CHANGES" ]; then
        echo -e "${YELLOW}Binary changes detected:${NC}"
        echo -e "$CHANGES"
    fi
fi

if [ "$REBUILD" = true ]; then
    log_step "Rebuilding all binaries (PHP + ImageMagick)"
    bash "$REPO_DIR/install_binaries.sh" 2>&1 | tee /root/rebuild.log
    log_ok "Binaries rebuilt"
elif [ "$PHP_ONLY" = true ]; then
    log_step "Rebuilding PHP only"
    if [ ! -f /usr/local/lib/libMagickCore-7.Q16HDRI.so ]; then
        log_error "ImageMagick not found. Use --rebuild for full build."
        exit 1
    fi
    bash "$REPO_DIR/install_binaries.sh" 2>&1 | tee /root/rebuild.log
    log_ok "PHP rebuilt"
elif [ "$BINARIES_CHANGED" = true ] && [ "$CODE_ONLY" != true ]; then
    log_warn "Binary build script changed. Run with --rebuild to apply."
    log_warn "Continuing with code-only update for now."
fi

log_step "Updating code files"
cp -a "$REPO_DIR/var/www/common.php" /var/www/common.php
cp -a "$REPO_DIR/var/www/html/home.php" /var/www/html/home.php
cp -a "$REPO_DIR/var/www/html/login.php" /var/www/html/login.php
cp -a "$REPO_DIR/var/www/html/admin.php" /var/www/html/admin.php
cp -a "$REPO_DIR/var/www/html/files.php" /var/www/html/files.php
cp -a "$REPO_DIR/var/www/html/password.php" /var/www/html/password.php
cp -a "$REPO_DIR/var/www/html/pgp.php" /var/www/html/pgp.php
cp -a "$REPO_DIR/var/www/html/register.php" /var/www/html/register.php
cp -a "$REPO_DIR/var/www/html/index.php" /var/www/html/index.php
cp -a "$REPO_DIR/var/www/html/list.php" /var/www/html/list.php
cp -a "$REPO_DIR/var/www/html/faq.php" /var/www/html/faq.php
cp -a "$REPO_DIR/var/www/html/delete.php" /var/www/html/delete.php
cp -a "$REPO_DIR/var/www/html/log.php" /var/www/html/log.php 2>/dev/null || true
cp -a "$REPO_DIR/var/www/html/logout.php" /var/www/html/logout.php 2>/dev/null || true
cp -a "$REPO_DIR/var/www/html/upgrade.php" /var/www/html/upgrade.php 2>/dev/null || true
cp -a "$REPO_DIR/var/www/setup.php" /var/www/setup.php
cp -a "$REPO_DIR/var/www/cron.php" /var/www/cron.php
cp -a "$REPO_DIR/var/www/find_old.php" /var/www/find_old.php 2>/dev/null || true

log_ok "Code files updated"

log_step "Restoring configuration"

DEFAULT_ONION="dhosting4xxoydyaivckq7tsmtgi4wfs3flpeyitekkmqwu4v4r46syd.onion"
sed -i "s|const DBHOST='127.0.0.1'|const DBHOST='$DBHOST'|" /var/www/common.php
sed -i "s|const DBPASS='MY_PASSWORD'|const DBPASS='$DBPASS'|" /var/www/common.php
sed -i "s|const ADMIN_PASSWORD='MY_PASSWORD'|const ADMIN_PASSWORD='$ADMIN_PASSWORD'|" /var/www/common.php
sed -i "s|const ONION_KEY_ENCRYPTION_KEY=''|const ONION_KEY_ENCRYPTION_KEY='$ONION_KEY_ENCRYPTION_KEY'|" /var/www/common.php
sed -i "s|$DEFAULT_ONION|$ADDRESS|g" /var/www/common.php
sed -i "s|$DEFAULT_ONION|$ADDRESS|g" /var/www/skel/www/index.hosting.html 2>/dev/null || true
chown root:www-data /var/www/common.php
chmod 640 /var/www/common.php

log_ok "Configuration restored (onion: $ADDRESS)"

if [ "$CODE_ONLY" = true ]; then
    log_step "Code-only update complete"
    log_ok "Restart services manually if needed: systemctl restart nginx"
    exit 0
fi

log_step "Updating services"
php8.2 /var/www/setup.php 2>&1 || true
mkdir -p /var/log/nginx /var/run/nginx
for ver in 8.2 8.3 8.4 8.5; do
    systemctl restart "php$ver-fpm@default" 2>/dev/null || true
done
systemctl restart nginx 2>/dev/null || true
FAILS=0
for svc in nginx php8.2-fpm@default php8.3-fpm@default php8.4-fpm@default php8.5-fpm@default; do
    if ! systemctl is-active --quiet "$svc"; then
        log_warn "$svc is not running"
        FAILS=$((FAILS + 1))
    fi
done

if [ "$FAILS" -eq 0 ]; then
    log_ok "All services running"
else
    log_warn "$FAILS service(s) need attention"
fi

log_step "Update Complete"

echo -e "${BOLD}Onion:${NC}   $ADDRESS"
echo -e "${BOLD}Backup:${NC} $BACKUP_DIR"
echo ""
TITLE=$(curl -s --max-time 30 --socks5-hostname 127.0.0.1:9050 "http://$ADDRESS/" 2>/dev/null | grep -o "<title>[^<]*</title>")
if [ -n "$TITLE" ]; then
    log_ok "Site responding: $TITLE"
else
    log_warn "Site not responding via Tor (may need a moment)"
fi
