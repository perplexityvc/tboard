#!/usr/bin/env bash
# =============================================================================
# ThingsBoard CE — One-Click Native Installer (no Docker)
# Target: Ubuntu 22.04 LTS (DigitalOcean, AWS, bare metal, LXC)
# Installs: OpenJDK 17, PostgreSQL 16, ThingsBoard CE .deb package
# Usage:  chmod +x install-thingsboard-native-noinit.sh && sudo ./install-thingsboard-native-noinit.sh
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
        reload)  systemctl reload  "$name" ;;
        status)  systemctl status  "$name" --no-pager ;;
      esac ;;
    upstart)
      case "$action" in
        enable)  true ;;
        reload)  service "$name" reload || true ;;
        start|stop|restart|status) initctl "$action" "$name" 2>/dev/null || service "$name" "$action" ;;
      esac ;;
    sysvinit)
      case "$action" in
        enable)
          if [[ "$name" == "thingsboard" ]]; then
            true  # no sysvinit registration for ThingsBoard .deb; managed via script
          else
            update-rc.d "$name" defaults 2>/dev/null || true
          fi ;;
        reload)  service "$name" reload || true ;;
        start|stop|restart|status)
          if [[ "$name" == "thingsboard" ]]; then
            case "$action" in
              start)   tb_start ;;
              stop)    tb_stop ;;
              restart) tb_stop; sleep 2; tb_start ;;
              status)  tb_status ;;
            esac
          else
            service "$name" "$action"
          fi ;;
      esac ;;
    none)
      case "$action" in
        enable)  true ;;
        reload)
          if [[ "$name" == "postgresql" ]]; then
            local pgv pgc
            pgv=$(pg_lsclusters -h | awk '{print $1}' | head -1)
            pgc=$(pg_lsclusters -h | awk '{print $2}' | head -1)
            pg_ctlcluster "$pgv" "$pgc" reload || true
          fi ;;
        start)
          if [[ "$name" == "postgresql" ]]; then
            local pgv pgc
            pgv=$(pg_lsclusters -h | awk '{print $1}' | head -1)
            pgc=$(pg_lsclusters -h | awk '{print $2}' | head -1)
            pg_ctlcluster "$pgv" "$pgc" start || true
          elif [[ "$name" == "thingsboard" ]]; then
            tb_start
          fi ;;
        stop)
          if [[ "$name" == "thingsboard" ]]; then
            tb_stop
          fi ;;
        restart)
          svc stop  "$name" || true; sleep 2; svc start "$name" ;;
        status)
          if [[ "$name" == "thingsboard" ]]; then
            tb_status
          fi ;;
      esac ;;
  esac
}


# ─── ThingsBoard direct-launch helpers (no systemd) ──────────────────────────
# The ThingsBoard .deb ships a systemd unit only — no sysvinit/upstart script.
# In containers or minimal environments we launch the Spring Boot fat JAR
# directly as the thingsboard user, matching the ExecStart in the .service file.
TB_JAR="/usr/share/thingsboard/bin/thingsboard.jar"
TB_PID="/var/run/thingsboard/thingsboard.pid"
TB_LOG="/var/log/thingsboard/thingsboard.log"

tb_start() {
  mkdir -p /var/log/thingsboard /var/run/thingsboard
  chown thingsboard:thingsboard /var/log/thingsboard /var/run/thingsboard

  if [[ -f "$TB_PID" ]] && kill -0 "$(cat "$TB_PID")" 2>/dev/null; then
    warn "ThingsBoard is already running (PID $(cat "$TB_PID"))"
    return 0
  fi

  su -s /bin/bash thingsboard -c "
    source /etc/thingsboard/conf/thingsboard.conf
    ${TB_JAR} >> ${TB_LOG} 2>&1 &
    echo \$! > ${TB_PID}
    echo "ThingsBoard started with PID \$!"
  "
}

tb_stop() {
  if [[ -f "$TB_PID" ]]; then
    local pid
    pid=$(cat "$TB_PID")
    if kill -0 "$pid" 2>/dev/null; then
      kill "$pid"
      info "Sent SIGTERM to ThingsBoard (PID $pid)"
      local waited=0
      while kill -0 "$pid" 2>/dev/null && [[ $waited -lt 30 ]]; do
        sleep 1; (( waited++ )) || true
      done
      kill -0 "$pid" 2>/dev/null && kill -9 "$pid" || true
    fi
    rm -f "$TB_PID"
  else
    warn "No PID file found at $TB_PID"
  fi
}

tb_status() {
  if [[ -f "$TB_PID" ]] && kill -0 "$(cat "$TB_PID")" 2>/dev/null; then
    success "ThingsBoard is running (PID $(cat "$TB_PID"))"
  else
    warn "ThingsBoard is NOT running"
    return 1
  fi
}

# ─── Lift policy-rc.d restriction ────────────────────────────────────────────
POLICY_RC="/usr/sbin/policy-rc.d"
POLICY_RC_BAK="/usr/sbin/policy-rc.d.bak"

restore_policy() {
  if [[ -f "$POLICY_RC_BAK" ]]; then
    mv "$POLICY_RC_BAK" "$POLICY_RC"
  else
    rm -f "$POLICY_RC"
  fi
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

# In container environments /proc/meminfo reports the HOST machine RAM,
# not the container's allocation. Cap at 64GB to avoid absurd heap sizes.
RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
RAM_GB=$(( RAM_KB / 1024 / 1024 ))
MAX_REPORTED_RAM=64
if [[ "$RAM_GB" -gt "$MAX_REPORTED_RAM" ]]; then
  warn "Detected RAM (${RAM_GB}GB) looks like a container reporting host RAM."
  warn "Capping reported RAM at ${MAX_REPORTED_RAM}GB for heap calculation."
  RAM_GB=$MAX_REPORTED_RAM
fi
if   [[ "$RAM_GB" -lt 3 ]]; then error "Insufficient RAM: ${RAM_GB}GB. Need at least 4GB."
elif [[ "$RAM_GB" -lt 4 ]]; then warn  "Low RAM (${RAM_GB}GB). Recommended: 4GB+."
else success "RAM: ${RAM_GB}GB — OK"; fi

DISK_AVAIL=$(df / --output=avail -BG | tail -1 | tr -d 'G')
[[ "$DISK_AVAIL" -lt 10 ]] && warn "Low disk: ${DISK_AVAIL}GB free. Recommend 20GB+."
success "Disk: ${DISK_AVAIL}GB free — OK"

# Heap = half of RAM, min 2G, max 8G (single-node install).
# Giving more than 8G to a single ThingsBoard node on PostgreSQL
# offers no real benefit and risks long GC pauses.
HEAP_GB=$(( RAM_GB / 2 ))
[[ "$HEAP_GB" -lt 2 ]] && HEAP_GB=2
[[ "$HEAP_GB" -gt 8 ]] && HEAP_GB=8
info "JVM heap will be set to ${HEAP_GB}G (half of ${RAM_GB}GB RAM, capped at 8G)"

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

svc enable postgresql
svc start  postgresql

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

# Locate the active cluster's pg_hba.conf
PG_VERSION=$(pg_lsclusters -h | awk '{print $1}' | head -1)
PG_CLUSTER=$(pg_lsclusters -h  | awk '{print $2}' | head -1)
PG_HBA="/etc/postgresql/${PG_VERSION}/${PG_CLUSTER}/pg_hba.conf"
info "Cluster: ${PG_VERSION}/${PG_CLUSTER} — pg_hba.conf: ${PG_HBA}"

# PostgreSQL defaults to peer auth for local socket connections, but ThingsBoard
# connects via TCP (127.0.0.1) and needs password auth. Add the entry if absent.
HBA_LINE="host    all             postgres        127.0.0.1/32            scram-sha-256"
if grep -qF "127.0.0.1/32" "$PG_HBA" 2>/dev/null; then
  info "pg_hba.conf already has a 127.0.0.1 entry — skipping"
else
  echo "$HBA_LINE" >> "$PG_HBA"
  info "Added scram-sha-256 TCP entry for 127.0.0.1 to pg_hba.conf"
fi

# Reload so the pg_hba.conf change takes effect
svc reload postgresql
sleep 2

# Set the postgres superuser password (via local socket — always succeeds)
runuser -u postgres -- psql -c "ALTER USER postgres WITH PASSWORD '${DB_PASSWORD}';" \
  || error "Failed to set PostgreSQL password. Is the cluster running? Run: pg_lsclusters"

# Create the thingsboard database
DB_EXISTS=$(runuser -u postgres -- psql -tAc \
  "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}';" || echo "")
DB_EXISTS="${DB_EXISTS//[[:space:]]/}"

if [[ "$DB_EXISTS" == "1" ]]; then
  warn "Database '${DB_NAME}' already exists — skipping creation"
else
  runuser -u postgres -- psql -c "CREATE DATABASE ${DB_NAME};" \
    || error "Failed to create database '${DB_NAME}'"
  success "Database '${DB_NAME}' created"
fi

# Verify TCP password auth works — this is exactly how ThingsBoard connects
PGPASSWORD="$DB_PASSWORD" psql -U "$DB_USER" -d "$DB_NAME" -h 127.0.0.1 \
  -c "SELECT 1;" > /dev/null \
  || error "TCP connection test failed. pg_hba.conf reload may not have applied. Try: pg_ctlcluster ${PG_VERSION} ${PG_CLUSTER} reload"

success "PostgreSQL configured and TCP connection verified"

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

[[ ! -f "${TB_CONF}.orig" ]] && cp "$TB_CONF" "${TB_CONF}.orig"

MARKER_START="# >>> tb-installer-config >>>"
MARKER_END="# <<< tb-installer-config <<<"

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

# UFW requires kernel-level iptables/netfilter access.
# Containers (LXC, OpenVZ, Docker) usually lack these capabilities.
# Test first by probing iptables — if it fails, skip UFW and advise the user
# to configure their cloud provider firewall instead.
can_use_iptables() {
  iptables -L INPUT -n > /dev/null 2>&1
}

if ! command -v ufw &>/dev/null; then
  warn "UFW not installed — skipping firewall setup."
  warn "Open ports ${TB_PORT}/tcp (UI), ${MQTT_PORT}/tcp (MQTT), ${COAP_PORT}/udp (CoAP) in your cloud firewall."
elif ! can_use_iptables; then
  warn "iptables is not accessible (container/restricted environment) — skipping UFW."
  warn "Configure your cloud firewall (e.g. DigitalOcean Firewall) to allow:"
  warn "  TCP ${TB_PORT}  — ThingsBoard web UI"
  warn "  TCP ${MQTT_PORT} — MQTT"
  warn "  UDP ${COAP_PORT} — CoAP"
  warn "  TCP 22  — SSH (make sure this is already open!)"
else
  ufw --force reset > /dev/null
  ufw default deny incoming  > /dev/null
  ufw default allow outgoing > /dev/null
  ufw allow ssh                  comment 'SSH'            > /dev/null
  ufw allow "${TB_PORT}"/tcp     comment 'ThingsBoard UI' > /dev/null
  ufw allow "${MQTT_PORT}"/tcp   comment 'MQTT'           > /dev/null
  ufw allow "${COAP_PORT}"/udp   comment 'CoAP'           > /dev/null
  ufw --force enable > /dev/null
  success "Firewall configured (SSH, $TB_PORT, $MQTT_PORT, $COAP_PORT)"
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

TIMEOUT=180; ELAPSED=0; INTERVAL=10

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
  warn "No response within ${TIMEOUT}s — may still be starting."
  warn "Check: tail -f /var/log/thingsboard/thingsboard.log"
fi

# ─── Service command strings for the summary ─────────────────────────────────
case "$INIT_SYSTEM" in
  systemd)
    CMD_STATUS="sudo systemctl status thingsboard"
    CMD_RESTART="sudo systemctl restart thingsboard"
    CMD_LOGS="sudo journalctl -u thingsboard -f" ;;
  none|*)
    # No systemd — ThingsBoard is managed via the tb_start/tb_stop helpers
    # which launch the Spring Boot JAR directly.
    CMD_STATUS="kill -0 \$(cat /var/run/thingsboard/thingsboard.pid) 2>/dev/null && echo running || echo stopped"
    CMD_RESTART="tb_stop; sleep 2; tb_start   # (re-run this script's tb_* functions)"
    CMD_LOGS="tail -f /var/log/thingsboard/thingsboard.log" ;;
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
