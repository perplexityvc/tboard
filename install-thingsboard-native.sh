#!/usr/bin/env bash
# =============================================================================
# ThingsBoard CE — One-Click Native Installer (no Docker)
# Target: Ubuntu 22.04 LTS (DigitalOcean, AWS, bare metal, LXC)
# Installs: OpenJDK 17, PostgreSQL 16, ThingsBoard CE .deb package
# Usage:  chmod +x install-thingsboard-native.sh && sudo ./install-thingsboard-native.sh
# =============================================================================

set -euo pipefail

# ─── Colour helpers ───────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; exit 1; }
header()  { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}\n"; }

# ─── Config ───────────────────────────────────────────────────────────────────
TB_VERSION="4.3.1.1"
TB_DEB="thingsboard-${TB_VERSION}.deb"
TB_DEB_URL="https://github.com/thingsboard/thingsboard/releases/download/v${TB_VERSION}/${TB_DEB}"
TB_CONF="/etc/thingsboard/conf/thingsboard.conf"
TB_PORT="8080"
MQTT_PORT="1883"
COAP_PORT="5683"
DB_NAME="thingsboard"
DB_USER="postgres"
DB_PASSWORD="$(openssl rand -base64 16 | tr -dc 'A-Za-z0-9' | head -c 20)"

# ─── Detect init system ───────────────────────────────────────────────────────
#
# systemd  → use systemctl
# upstart  → use initctl  (Ubuntu <= 14.04, rare)
# sysvinit → use service
# none     → direct process control (container/chroot without an init daemon)
#
detect_init() {
  if command -v systemctl &>/dev/null && systemctl list-units &>/dev/null 2>&1; then
    echo "systemd"
  elif command -v initctl &>/dev/null && initctl version &>/dev/null 2>&1; then
    echo "upstart"
  elif command -v service &>/dev/null; then
    echo "sysvinit"
  else
    echo "none"
  fi
}

INIT_SYSTEM="$(detect_init)"
info "Init system detected: ${INIT_SYSTEM}"

# ─── Unified service helper ───────────────────────────────────────────────────
# Usage: svc <enable|start|stop|restart|status> <service-name>
svc() {
  local action="$1"
  local name="$2"

  case "$INIT_SYSTEM" in
    systemd)
      case "$action" in
        enable)  systemctl enable "$name" --quiet ;;
        start)   systemctl start  "$name" ;;
        stop)    systemctl stop   "$name" ;;
        restart) systemctl restart "$name" ;;
        status)  systemctl status  "$name" --no-pager ;;
      esac
      ;;
    upstart)
      case "$action" in
        enable)  true ;;
        start)   initctl start   "$name" 2>/dev/null || service "$name" start ;;
        stop)    initctl stop    "$name" 2>/dev/null || service "$name" stop  ;;
        restart) initctl restart "$name" 2>/dev/null || service "$name" restart ;;
        status)  initctl status  "$name" 2>/dev/null || service "$name" status ;;
      esac
      ;;
    sysvinit)
      case "$action" in
        enable)  update-rc.d "$name" defaults 2>/dev/null || true ;;
        start|stop|restart|status) service "$name" "$action" ;;
      esac
      ;;
    none)
      # No init daemon — start processes directly where possible.
      case "$action" in
        enable)  true ;;
        start)
          if [[ "$name" == "postgresql" ]]; then
            PG_VER=$(pg_lsclusters -h | awk '{print $1}' | head -1)
            PG_CLUSTER=$(pg_lsclusters -h | awk '{print $2}' | head -1)
            pg_ctlcluster "$PG_VER" "$PG_CLUSTER" start || true
          elif [[ "$name" == "thingsboard" ]]; then
            /usr/share/thingsboard/bin/thingsboard.sh start
          fi
          ;;
        stop)
          if [[ "$name" == "thingsboard" ]]; then
            /usr/share/thingsboard/bin/thingsboard.sh stop || true
          fi
          ;;
        restart)
          svc stop  "$name" || true
          sleep 2
          svc start "$name"
          ;;
        status)
          if [[ "$name" == "thingsboard" ]]; then
            /usr/share/thingsboard/bin/thingsboard.sh status || true
          fi
          ;;
      esac
      ;;
  esac
}

# ─── Lift policy-rc.d restriction ────────────────────────────────────────────
# Some Ubuntu images (cloud-init, LXC, minimal) ship a policy-rc.d that blocks
# service starts triggered by dpkg post-install scripts, producing:
#   "invoke-rc.d: policy-rc.d denied execution of start"
# We override it for the duration of this script, then restore it.
POLICY_RC="/usr/sbin/policy-rc.d"
POLICY_RC_BAK="/usr/sbin/policy-rc.d.bak"

restore_policy() {
  if [[ -f "$POLICY_RC_BAK" ]]; then
    mv "$POLICY_RC_BAK" "$POLICY_RC"
  else
    rm -f "$POLICY_RC"
  fi
  # Also clean up any temp download dir
  [[ -n "${TMPDIR_DL:-}" ]] && rm -rf "$TMPDIR_DL"
}
trap restore_policy EXIT

if [[ -f "$POLICY_RC" ]]; then
  cp "$POLICY_RC" "$POLICY_RC_BAK"
  info "Backed up existing policy-rc.d"
fi
printf '#!/bin/sh\nexit 0\n' > "$POLICY_RC"
chmod +x "$POLICY_RC"
info "policy-rc.d overridden (services allowed to start during install)"

# ─── Pre-flight checks ────────────────────────────────────────────────────────
header "Pre-flight checks"

[[ "$EUID" -ne 0 ]] && error "Please run as root: sudo $0"

OS_ID=$(grep -oP '(?<=^ID=).+' /etc/os-release | tr -d '"')
OS_VER=$(grep -oP '(?<=^VERSION_ID=).+' /etc/os-release | tr -d '"')
[[ "$OS_ID" != "ubuntu" ]] && error "This script requires Ubuntu (detected: $OS_ID)."
[[ "$OS_VER" != "22.04" ]] \
  && warn "Tested on Ubuntu 22.04. Detected: $OS_VER — continuing anyway."
success "OS: Ubuntu $OS_VER"

RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$(( RAM_KB / 1024 / 1024 ))
if [[ "$RAM_GB" -lt 3 ]]; then
  error "Insufficient RAM: ${RAM_GB}GB. ThingsBoard requires at least 4GB."
elif [[ "$RAM_GB" -lt 4 ]]; then
  warn "Low RAM (${RAM_GB}GB). ThingsBoard may be unstable. Recommended: 4GB+."
else
  success "RAM: ${RAM_GB}GB — OK"
fi

DISK_AVAIL=$(df / --output=avail -BG | tail -1 | tr -d 'G')
[[ "$DISK_AVAIL" -lt 10 ]] \
  && warn "Low disk space: ${DISK_AVAIL}GB free. Recommend at least 20GB."
success "Disk: ${DISK_AVAIL}GB free — OK"

# ─── Compute JVM heap (half of RAM, min 2G) ───────────────────────────────────
HEAP_GB=$(( RAM_GB / 2 ))
[[ "$HEAP_GB" -lt 2 ]] && HEAP_GB=2
info "JVM heap will be set to ${HEAP_GB}G"

# ─── System update & prerequisites ───────────────────────────────────────────
header "Updating system packages"

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
  wget curl ca-certificates gnupg lsb-release openssl ufw \
  libharfbuzz0b fontconfig fonts-dejavu-core

success "System packages updated"

# ─── Install OpenJDK 17 ───────────────────────────────────────────────────────
header "Installing OpenJDK 17"

if java -version 2>&1 | grep -q 'openjdk version "17'; then
  success "OpenJDK 17 already installed — skipping"
else
  apt-get install -y -qq openjdk-17-jdk-headless
  update-alternatives --set java \
    "$(update-alternatives --list java | grep java-17 | head -1)" 2>/dev/null || true
  success "OpenJDK 17 installed: $(java -version 2>&1 | head -1)"
fi

# ─── Install PostgreSQL 16 ────────────────────────────────────────────────────
header "Installing PostgreSQL 16"

if command -v pg_isready &>/dev/null && pg_isready -q 2>/dev/null; then
  success "PostgreSQL is already running — skipping install"
else
  apt-get install -y -qq postgresql-common
  /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y
  apt-get update -qq
  apt-get install -y -qq postgresql-16
  success "PostgreSQL 16 package installed"
fi

# Start PostgreSQL via whichever init system we have
svc enable postgresql
svc start  postgresql

# Wait for PostgreSQL to accept connections
RETRIES=15
until pg_isready -q 2>/dev/null || [[ "$RETRIES" -eq 0 ]]; do
  info "Waiting for PostgreSQL to accept connections…"
  sleep 2
  (( RETRIES-- )) || true
done
pg_isready -q || error "PostgreSQL failed to start. Check: pg_lsclusters"

success "PostgreSQL is running"

# ─── Configure PostgreSQL ─────────────────────────────────────────────────────
header "Configuring PostgreSQL"

sudo -u postgres psql -c "ALTER USER postgres WITH PASSWORD '${DB_PASSWORD}';" \
  > /dev/null 2>&1

DB_EXISTS=$(sudo -u postgres psql -tAc \
  "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';" 2>/dev/null || echo "")

if [[ "$DB_EXISTS" == "1" ]]; then
  warn "Database '${DB_NAME}' already exists — skipping creation"
else
  sudo -u postgres psql -c "CREATE DATABASE ${DB_NAME};" > /dev/null
  success "Database '${DB_NAME}' created"
fi

PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -d "$DB_NAME" \
  -h 127.0.0.1 -c "SELECT 1;" > /dev/null 2>&1 \
  || error "PostgreSQL connection test failed — check pg_hba.conf allows md5/scram on 127.0.0.1"

success "PostgreSQL configured and connection verified"

# ─── Download & install ThingsBoard .deb ──────────────────────────────────────
header "Downloading ThingsBoard CE v${TB_VERSION}"

TMPDIR_DL="$(mktemp -d)"

if dpkg -l thingsboard 2>/dev/null | grep -q "^ii"; then
  INSTALLED_VER=$(dpkg -l thingsboard | awk '/^ii/{print $3}')
  if [[ "$INSTALLED_VER" == "$TB_VERSION" ]]; then
    success "ThingsBoard ${TB_VERSION} already installed — skipping download"
  else
    warn "ThingsBoard $INSTALLED_VER detected. Downloading $TB_VERSION for upgrade."
    wget -q --show-progress -O "$TMPDIR_DL/$TB_DEB" "$TB_DEB_URL"
    dpkg -i "$TMPDIR_DL/$TB_DEB"
  fi
else
  wget -q --show-progress -O "$TMPDIR_DL/$TB_DEB" "$TB_DEB_URL"
  dpkg -i "$TMPDIR_DL/$TB_DEB"
  success "ThingsBoard CE installed"
fi

# ─── Write ThingsBoard configuration ──────────────────────────────────────────
header "Configuring ThingsBoard"

if [[ ! -f "${TB_CONF}.orig" ]]; then
  cp "$TB_CONF" "${TB_CONF}.orig"
fi

MARKER_START="# >>> tb-installer-config >>>"
MARKER_END="# <<< tb-installer-config <<<"

# Idempotent — remove previous block before re-writing
if grep -q "$MARKER_START" "$TB_CONF" 2>/dev/null; then
  sed -i "/$MARKER_START/,/$MARKER_END/d" "$TB_CONF"
fi

cat >> "$TB_CONF" <<EOF

${MARKER_START}
# Database
export DATABASE_TS_TYPE=sql
export SPRING_DATASOURCE_URL=jdbc:postgresql://localhost:5432/${DB_NAME}
export SPRING_DATASOURCE_USERNAME=${DB_USER}
export SPRING_DATASOURCE_PASSWORD=${DB_PASSWORD}
export SQL_POSTGRES_TS_KV_PARTITIONING=MONTHS

# JVM heap (~half of total RAM, min 2G)
export JAVA_OPTS="\$JAVA_OPTS -Xms${HEAP_GB}G -Xmx${HEAP_GB}G"
${MARKER_END}
EOF

success "ThingsBoard config written to $TB_CONF"

# ─── Configure firewall ───────────────────────────────────────────────────────
header "Configuring UFW firewall"

if command -v ufw &>/dev/null; then
  ufw --force reset > /dev/null
  ufw default deny incoming  > /dev/null
  ufw default allow outgoing > /dev/null
  ufw allow ssh                  comment 'SSH'            > /dev/null
  ufw allow "${TB_PORT}"/tcp     comment 'ThingsBoard UI' > /dev/null
  ufw allow "${MQTT_PORT}"/tcp   comment 'MQTT'           > /dev/null
  ufw allow "${COAP_PORT}"/udp   comment 'CoAP'           > /dev/null
  ufw --force enable > /dev/null
  success "Firewall configured (SSH, $TB_PORT, $MQTT_PORT, $COAP_PORT)"
else
  warn "UFW not available — skipping. Configure your cloud firewall manually."
fi

# ─── Initialise ThingsBoard database ──────────────────────────────────────────
header "Initialising ThingsBoard database (this may take 2-3 minutes)"

/usr/share/thingsboard/bin/install/install.sh --loadDemo \
  || error "ThingsBoard install script failed. Check /var/log/thingsboard/install.log"

success "Database schema initialised with demo data"

# ─── Enable & start ThingsBoard ───────────────────────────────────────────────
header "Starting ThingsBoard service"

svc enable thingsboard
svc start  thingsboard
success "ThingsBoard service started"

# ─── Wait for ThingsBoard to respond ─────────────────────────────────────────
header "Waiting for ThingsBoard to become ready (up to 3 minutes)"

TIMEOUT=180
ELAPSED=0
INTERVAL=10

while [[ "$ELAPSED" -lt "$TIMEOUT" ]]; do
  HTTP_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
    "http://localhost:${TB_PORT}/api/v1/features" 2>/dev/null || echo "000")

  if [[ "$HTTP_STATUS" == "200" || "$HTTP_STATUS" == "401" ]]; then
    success "ThingsBoard is up! (HTTP $HTTP_STATUS after ${ELAPSED}s)"
    break
  fi

  info "Still starting… (${ELAPSED}s, HTTP $HTTP_STATUS)"
  sleep "$INTERVAL"
  ELAPSED=$(( ELAPSED + INTERVAL ))
done

if [[ "$ELAPSED" -ge "$TIMEOUT" ]]; then
  warn "No response within ${TIMEOUT}s — it may still be starting."
  warn "Tail the log:  tail -f /var/log/thingsboard/thingsboard.log"
  warn "Check errors:  grep ERROR /var/log/thingsboard/thingsboard.log"
fi

# ─── Build service management commands for the summary ───────────────────────
case "$INIT_SYSTEM" in
  systemd)
    CMD_STATUS="sudo systemctl status thingsboard"
    CMD_RESTART="sudo systemctl restart thingsboard"
    CMD_LOGS="sudo journalctl -u thingsboard -f"
    ;;
  none)
    CMD_STATUS="sudo /usr/share/thingsboard/bin/thingsboard.sh status"
    CMD_RESTART="sudo /usr/share/thingsboard/bin/thingsboard.sh restart"
    CMD_LOGS="tail -f /var/log/thingsboard/thingsboard.log"
    ;;
  *)
    CMD_STATUS="sudo service thingsboard status"
    CMD_RESTART="sudo service thingsboard restart"
    CMD_LOGS="tail -f /var/log/thingsboard/thingsboard.log"
    ;;
esac

# ─── Save credentials ─────────────────────────────────────────────────────────
CREDS_FILE="/root/thingsboard-credentials.txt"
cat > "$CREDS_FILE" <<EOF
=== ThingsBoard CE Credentials ===
Generated : $(date)
Version   : ${TB_VERSION}
Init sys  : ${INIT_SYSTEM}

PostgreSQL password : ${DB_PASSWORD}

Default logins (change these immediately after first login!):
  System Admin  : sysadmin@thingsboard.org  / sysadmin
  Tenant Admin  : tenant@thingsboard.org    / tenant
  Customer      : customer@thingsboard.org  / customer

Config file   : ${TB_CONF}
Log directory : /var/log/thingsboard/

Useful commands:
  Status  : ${CMD_STATUS}
  Restart : ${CMD_RESTART}
  Logs    : ${CMD_LOGS}
  Errors  : grep ERROR /var/log/thingsboard/thingsboard.log
EOF
chmod 600 "$CREDS_FILE"
success "Credentials saved to $CREDS_FILE"

# ─── Done ─────────────────────────────────────────────────────────────────────
PUBLIC_IP=$(curl -s --max-time 5 https://api.ipify.org || hostname -I | awk '{print $1}')

echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}${GREEN}║     ThingsBoard CE — Install Complete! (native)  ║${RESET}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════════════╝${RESET}"
echo ""
echo -e "  ${BOLD}Web UI:${RESET}       http://${PUBLIC_IP}:${TB_PORT}"
echo -e "  ${BOLD}MQTT broker:${RESET}  ${PUBLIC_IP}:${MQTT_PORT}"
echo -e "  ${BOLD}Init system:${RESET}  ${INIT_SYSTEM}"
echo -e "  ${BOLD}Config:${RESET}       ${TB_CONF}"
echo -e "  ${BOLD}Logs:${RESET}         /var/log/thingsboard/"
echo -e "  ${BOLD}Credentials:${RESET}  ${CREDS_FILE}"
echo ""
echo -e "  ${BOLD}Useful commands:${RESET}"
echo -e "    Status:   ${CMD_STATUS}"
echo -e "    Restart:  ${CMD_RESTART}"
echo -e "    Logs:     ${CMD_LOGS}"
echo -e "    Errors:   grep ERROR /var/log/thingsboard/thingsboard.log"
echo ""
echo -e "  ${YELLOW}⚠  Change the default passwords immediately after first login!${RESET}"
echo -e "  ${YELLOW}⚠  For HTTPS: https://thingsboard.io/docs/user-guide/install/pe/add-haproxy-ubuntu${RESET}"
echo ""
