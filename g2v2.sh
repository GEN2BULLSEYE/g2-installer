#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# GEN2 Ground Probe - g2.sh (Cross-platform)
# Supports: Raspberry Pi OS / Debian / Ubuntu / macOS
# Commands: install | repair | uninstall | status | run-once
# ==========================================================

GEN2_API_BASE_URL="${GEN2_API_BASE_URL:-https://gen2bullseye.com}"
PULL_AGENT_URL="${PULL_AGENT_URL:-https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/main/pull-agent.sh}"

# Fixed webhook (your current)
FIXED_WEBHOOK_URL="${FIXED_WEBHOOK_URL:-https://nscl.tailc52c94.ts.net/webhook/ps2}"

# Defaults tuned for Pi Zero 2W stability
MAX_JOBS_DEFAULT="${MAX_JOBS_DEFAULT:-3}"      # concurrency
WAN_TTL_DEFAULT="${WAN_TTL_DEFAULT:-3600}"     # seconds
PING_TIMEOUT_DEFAULT="${PING_TIMEOUT_DEFAULT:-2}"
CURL_CONNECT_TIMEOUT_DEFAULT="${CURL_CONNECT_TIMEOUT_DEFAULT:-3}"
CURL_MAX_TIME_DEFAULT="${CURL_MAX_TIME_DEFAULT:-8}"
HTTP_MAX_TIME_DEFAULT="${HTTP_MAX_TIME_DEFAULT:-6}"

# Pull sync interval
PULL_INTERVAL_SECONDS="${PULL_INTERVAL_SECONDS:-300}" # 5 min

# ---------- helpers ----------
log()  { echo -e "[g2] $*"; }
warn() { echo -e "[g2] \e[33mWARN\e[0m: $*" >&2; }
die()  { echo -e "[g2] \e[31mERROR\e[0m: $*" >&2; exit 1; }
have_cmd(){ command -v "$1" >/dev/null 2>&1; }

# detect OS
OS="linux"
if [[ "${OSTYPE:-}" == "darwin"* ]]; then OS="macos"; fi

# identify "real user" (important when running with sudo on mac)
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_UID="$(id -u "$REAL_USER")"
REAL_HOME="$(eval echo "~$REAL_USER")"

# install dirs
if [[ "$OS" == "macos" ]]; then
  INSTALL_DIR="${INSTALL_DIR:-$REAL_HOME/.g2serve}"
else
  INSTALL_DIR="${INSTALL_DIR:-/opt/g2serve}"
fi

BIN_DIR="$INSTALL_DIR/bin"
CONFIG_FILE="$INSTALL_DIR/agent.env"
AGENT_PATH="$BIN_DIR/g2agent.sh"
PULL_AGENT_PATH="$BIN_DIR/pull-agent.sh"
SELF_PATH="$INSTALL_DIR/g2.sh"

QUEUE_DIR_DEFAULT="/var/lib/g2serve"
if [[ "$OS" == "macos" ]]; then
  QUEUE_DIR_DEFAULT="$REAL_HOME/.g2serve/queue"
fi

# scheduler identifiers
SYSTEMD_AGENT_SERVICE="g2agent.service"
SYSTEMD_AGENT_TIMER="g2agent.timer"
SYSTEMD_PULL_SERVICE="g2pull.service"
SYSTEMD_PULL_TIMER="g2pull.timer"

LAUNCHD_AGENT_PLIST="com.gen2.g2agent.plist"
LAUNCHD_PULL_PLIST="com.gen2.g2pull.plist"
LAUNCHD_AGENT_PATH="$REAL_HOME/Library/LaunchAgents/$LAUNCHD_AGENT_PLIST"
LAUNCHD_PULL_PATH="$REAL_HOME/Library/LaunchAgents/$LAUNCHD_PULL_PLIST"

# ----- root requirements -----
need_root_linux() {
  if [[ "$OS" == "linux" && "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Linux install/repair/uninstall needs root: sudo bash $0 <command>"
  fi
}
need_user_macos() {
  # On macOS, prefer running as user (not root), so LaunchAgent installs correctly.
  if [[ "$OS" == "macos" && "${EUID:-$(id -u)}" -eq 0 ]]; then
    warn "You're running as root on macOS. This is not recommended."
    warn "Prefer: bash g2.sh install (without sudo) so LaunchAgent loads in your session."
  fi
}

safe_mkdir() { mkdir -p "$1"; }
write_file() { safe_mkdir "$(dirname "$1")"; cat > "$1"; }

is_systemd() {
  [[ "$OS" == "linux" && -d /run/systemd/system && $(command -v systemctl >/dev/null 2>&1; echo $?) -eq 0 ]]
}

# portable file mtime (seconds)
file_mtime() {
  local f="$1"
  if [[ "$OS" == "macos" ]]; then
    stat -f %m "$f" 2>/dev/null || echo 0
  else
    stat -c %Y "$f" 2>/dev/null || echo 0
  fi
}

# ---------- dependencies ----------
install_deps_linux() {
  log "Installing dependencies on Linux..."
  # util-linux provides flock; we don't rely on it in agent, but harmless.
  apt-get update -y
  apt-get install -y curl jq iputils-ping ca-certificates || true
}

install_deps_macos() {
  log "Checking dependencies on macOS..."
  # curl & ping exist. jq usually not.
  if ! have_cmd jq; then
    if have_cmd brew; then
      log "Installing jq via Homebrew..."
      brew install jq
    else
      die "jq not found. Install Homebrew (https://brew.sh) then: brew install jq"
    fi
  fi
}

install_deps() {
  if [[ "$OS" == "linux" ]]; then
    need_root_linux
    install_deps_linux
  else
    need_user_macos
    install_deps_macos
  fi
}

# ---------- agent writer (portable + optimized) ----------
write_agent() {
  log "Writing optimized agent: $AGENT_PATH"
  safe_mkdir "$BIN_DIR"

  write_file "$AGENT_PATH" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

# =====================
# Portable overlap lock
# =====================
LOCKDIR="/tmp/g2agent.lockdir"
if ! mkdir "$LOCKDIR" 2>/dev/null; then
  exit 0
fi
cleanup_lock(){ rmdir "$LOCKDIR" 2>/dev/null || true; }
trap cleanup_lock EXIT

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$BASE_DIR/../agent.env"
[[ -f "$CONFIG_FILE" ]] || exit 0
# shellcheck disable=SC1090
source "$CONFIG_FILE"

OS="linux"; [[ "${OSTYPE:-}" == "darwin"* ]] && OS="macos"

# -------- defaults ----------
MAX_JOBS="${MAX_JOBS:-3}"
WAN_TTL="${WAN_TTL:-3600}"
PING_TIMEOUT="${PING_TIMEOUT:-2}"
CURL_CONNECT_TIMEOUT="${CURL_CONNECT_TIMEOUT:-3}"
CURL_MAX_TIME="${CURL_MAX_TIME:-8}"
HTTP_MAX_TIME="${HTTP_MAX_TIME:-6}"
QUEUE_DIR="${QUEUE_DIR:-__QUEUE_DIR__}"
QUEUE_FILE="$QUEUE_DIR/queue.jsonl"
WAN_CACHE="/tmp/g2_wan_ip.cache"

mkdir -p "$QUEUE_DIR"

file_mtime() {
  local f="$1"
  if [[ "$OS" == "macos" ]]; then
    stat -f %m "$f" 2>/dev/null || echo 0
  else
    stat -c %Y "$f" 2>/dev/null || echo 0
  fi
}

post_payload() {
  local payload="$1"
  curl --fail --silent --show-error \
    --connect-timeout "$CURL_CONNECT_TIMEOUT" \
    --max-time "$CURL_MAX_TIME" \
    --retry 3 --retry-delay 1 --retry-all-errors \
    -X POST "$N8N_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$payload" >/dev/null
}

flush_queue() {
  [[ -f "$QUEUE_FILE" ]] || return 0
  local tmp="${QUEUE_FILE}.tmp"
  : > "$tmp"

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if post_payload "$line"; then
      :
    else
      echo "$line" >> "$tmp"
    fi
  done < "$QUEUE_FILE"

  mv "$tmp" "$QUEUE_FILE"
}

get_local_ip() {
  if [[ "$OS" == "macos" ]]; then
    # macOS: best-effort
    ipconfig getifaddr "$(route get default 2>/dev/null | awk '/interface:/{print $2}')" 2>/dev/null || echo ""
  else
    hostname -I 2>/dev/null | awk '{print $1}'
  fi
}

get_wifi_ssid() {
  if [[ "$OS" == "macos" ]]; then
    # Works on most macOS versions; may require location services / permissions
    /System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I 2>/dev/null \
      | awk -F': ' '/ SSID/{print $2; exit}' || echo "N/A"
  else
    if command -v nmcli >/dev/null 2>&1; then
      nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}'
    else
      echo "N/A"
    fi
  fi
}

get_wan_ip() {
  if [[ -f "$WAN_CACHE" ]]; then
    local age=$(( $(date +%s) - $(file_mtime "$WAN_CACHE") ))
    if (( age < WAN_TTL )); then
      cat "$WAN_CACHE"
      return 0
    fi
  fi

  local wan=""
  wan=$(curl -s --connect-timeout 2 --max-time 4 https://api.ipify.org || true)
  if [[ -n "$wan" ]]; then
    echo "$wan" > "$WAN_CACHE"
  fi
  echo "$wan"
}

# ==============================
# Portable semaphore for MAX_JOBS
# (works on macOS Bash 3.2)
# ==============================
sem_init() {
  SEM_FIFO="$(mktemp -u "/tmp/g2sem.XXXX")"
  mkfifo "$SEM_FIFO"
  exec 3<>"$SEM_FIFO"
  rm -f "$SEM_FIFO"
  local i
  for ((i=0; i<MAX_JOBS; i++)); do
    printf '.' >&3
  done
}
sem_acquire() { read -r -n 1 -u 3 _; }
sem_release() { printf '.' >&3; }

process_target() {
  local entry="$1"
  local NAME TARGET
  NAME=$(echo "${entry%%|*}" | xargs)
  TARGET=$(echo "${entry#*|}" | xargs)

  local LOCAL_IP WIFI_SSID WAN_IP
  LOCAL_IP="$(get_local_ip)"
  WIFI_SSID="$(get_wifi_ssid)"
  WAN_IP="$(get_wan_ip)"

  # Ping: 1 probe (lighter, stable for many checks)
  local PING_RESULT PING_LATENCY PING_STATUS
  PING_RESULT=$(ping -c 1 -W "$PING_TIMEOUT" "$TARGET" 2>/dev/null || true)
  PING_LATENCY=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $5}' | tr -dc '0-9.' || true)
  PING_STATUS=$([[ -z "$PING_LATENCY" || "$PING_LATENCY" == "0" ]] && echo "down" || echo "up")

  # HTTP check (only URLs): curl time_total in seconds -> ms
  local HTTP_STATUS HTTP_LATENCY
  HTTP_STATUS="n/a"; HTTP_LATENCY="0"

  if [[ "$TARGET" =~ ^https?:// ]]; then
    local t
    t=$(curl -o /dev/null -s \
      --connect-timeout "$CURL_CONNECT_TIMEOUT" \
      --max-time "$HTTP_MAX_TIME" \
      -w '%{time_total}' "$TARGET" 2>/dev/null || true)

    if [[ -n "$t" ]]; then
      HTTP_STATUS="up"
      HTTP_LATENCY=$(awk "BEGIN {print ($t * 1000)}" 2>/dev/null || echo 0)
    else
      HTTP_STATUS="down"
      HTTP_LATENCY="0"
    fi
  fi

  local TS PAYLOAD
  TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  PAYLOAD=$(jq -n \
    --arg oid "$ORG_ID" --arg lkey "$LICENSE_KEY" --arg sid "$SERVER_ID" \
    --arg lip "$LOCAL_IP" --arg wip "$WAN_IP" --arg ssid "$WIFI_SSID" \
    --arg mon "$NAME" --arg tar "$TARGET" --arg p_sta "$PING_STATUS" \
    --argjson p_lat "${PING_LATENCY:-0}" --arg h_sta "$HTTP_STATUS" \
    --argjson h_lat "${HTTP_LATENCY:-0}" --arg ts "$TS" \
    '{org_id: $oid, license_key: $lkey, server_id: $sid, local_ip: $lip, wan_ip: $wip, wifi_ssid: $ssid, monitor: $mon, target: $tar, ping_status: $p_sta, ping_latency_ms: $p_lat, http_status: $h_sta, http_latency_ms: $h_lat, timestamp: $ts}' )

  if ! post_payload "$PAYLOAD"; then
    echo "$PAYLOAD" >> "$QUEUE_FILE"
  fi
}

main() {
  flush_queue

  sem_init
  for entry in "${TARGETS[@]}"; do
    sem_acquire
    (
      process_target "$entry"
      sem_release
    ) &
  done
  wait || true

  flush_queue
}

main
EOF

  # inject queue dir default
  if [[ "$OS" == "macos" ]]; then
    sed -i '' "s|__QUEUE_DIR__|$QUEUE_DIR_DEFAULT|g" "$AGENT_PATH"
  else
    sed -i "s|__QUEUE_DIR__|$QUEUE_DIR_DEFAULT|g" "$AGENT_PATH"
  fi

  chmod +x "$AGENT_PATH"
}

# ---------- pull agent ----------
install_pull_agent() {
  log "Installing pull agent: $PULL_AGENT_PATH"
  safe_mkdir "$BIN_DIR"
  if curl -fsSL "$PULL_AGENT_URL" -o "$PULL_AGENT_PATH"; then
    chmod +x "$PULL_AGENT_PATH"
  else
    warn "Could not download pull-agent.sh. Remote job sync may not work."
  fi
}

# ---------- config ----------
interactive_config() {
  log "Interactive configuration..."
  local ORG_ID LICENSE_KEY SERVER_ID
  read -rp "Organization ID: " ORG_ID
  read -rp "License Key: " LICENSE_KEY
  read -rp "Server ID: " SERVER_ID

  local targets=()
  while true; do
    echo ""
    read -rp "Monitor Name: " m_name
    read -rp "Target (URL or IP): " m_target
    targets+=("$m_name | $m_target")

    read -rp "Add another monitor? (y/n): " confirm
    [[ "$confirm" == "y" || "$confirm" == "Y" ]] || break
  done

  write_config "$ORG_ID" "$LICENSE_KEY" "$SERVER_ID" "${targets[@]}"
}

write_config() {
  local ORG_ID="$1"; shift
  local LICENSE_KEY="$1"; shift
  local SERVER_ID="$1"; shift
  local targets=("$@")

  safe_mkdir "$INSTALL_DIR"

  {
    echo "ORG_ID=\"$ORG_ID\""
    echo "LICENSE_KEY=\"$LICENSE_KEY\""
    echo "SERVER_ID=\"$SERVER_ID\""
    echo "N8N_WEBHOOK_URL=\"$FIXED_WEBHOOK_URL\""
    echo "MAX_JOBS=\"$MAX_JOBS_DEFAULT\""
    echo "WAN_TTL=\"$WAN_TTL_DEFAULT\""
    echo "PING_TIMEOUT=\"$PING_TIMEOUT_DEFAULT\""
    echo "CURL_CONNECT_TIMEOUT=\"$CURL_CONNECT_TIMEOUT_DEFAULT\""
    echo "CURL_MAX_TIME=\"$CURL_MAX_TIME_DEFAULT\""
    echo "HTTP_MAX_TIME=\"$HTTP_MAX_TIME_DEFAULT\""
    echo "QUEUE_DIR=\"$QUEUE_DIR_DEFAULT\""
    declare -p targets | sed 's/^declare -a targets=/declare -a TARGETS=/'
  } > "$CONFIG_FILE"

  chmod 640 "$CONFIG_FILE" 2>/dev/null || true
  [[ "$OS" == "linux" ]] && chown root:root "$CONFIG_FILE" 2>/dev/null || true
  [[ "$OS" == "macos" ]] && chown "$REAL_USER" "$CONFIG_FILE" 2>/dev/null || true

  log "Config saved: $CONFIG_FILE"
}

# ---------- scheduling ----------
install_systemd() {
  log "Installing systemd units (Linux)..."

  write_file "/etc/systemd/system/$SYSTEMD_AGENT_SERVICE" <<EOF
[Unit]
Description=GEN2 Ground Probe Agent
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$AGENT_PATH

[Install]
WantedBy=multi-user.target
EOF

  write_file "/etc/systemd/system/$SYSTEMD_AGENT_TIMER" <<EOF
[Unit]
Description=Run GEN2 Agent every minute

[Timer]
OnBootSec=30s
OnUnitActiveSec=60s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  write_file "/etc/systemd/system/$SYSTEMD_PULL_SERVICE" <<EOF
[Unit]
Description=GEN2 Pull Agent Sync
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$PULL_AGENT_PATH

[Install]
WantedBy=multi-user.target
EOF

  write_file "/etc/systemd/system/$SYSTEMD_PULL_TIMER" <<EOF
[Unit]
Description=Run GEN2 Pull Agent every 5 minutes

[Timer]
OnBootSec=60s
OnUnitActiveSec=${PULL_INTERVAL_SECONDS}s
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SYSTEMD_AGENT_TIMER" "$SYSTEMD_PULL_TIMER"
}

install_launchd() {
  log "Installing launchd LaunchAgents (macOS)..."
  safe_mkdir "$(dirname "$LAUNCHD_AGENT_PATH")"

  # Agent every 60s
  write_file "$LAUNCHD_AGENT_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.gen2.g2agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$AGENT_PATH</string>
  </array>
  <key>StartInterval</key><integer>60</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/tmp/g2agent.out</string>
  <key>StandardErrorPath</key><string>/tmp/g2agent.err</string>
</dict>
</plist>
EOF

  # Pull every 5 min
  write_file "$LAUNCHD_PULL_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.gen2.g2pull</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$PULL_AGENT_PATH</string>
  </array>
  <key>StartInterval</key><integer>$PULL_INTERVAL_SECONDS</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/tmp/g2pull.out</string>
  <key>StandardErrorPath</key><string>/tmp/g2pull.err</string>
</dict>
</plist>
EOF

  chown "$REAL_USER" "$LAUNCHD_AGENT_PATH" "$LAUNCHD_PULL_PATH" 2>/dev/null || true

  # Load into the user's GUI session
  sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID" "$LAUNCHD_AGENT_PATH" 2>/dev/null || true
  sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID" "$LAUNCHD_PULL_PATH" 2>/dev/null || true
  sudo -u "$REAL_USER" launchctl bootstrap "gui/$REAL_UID" "$LAUNCHD_AGENT_PATH"
  sudo -u "$REAL_USER" launchctl bootstrap "gui/$REAL_UID" "$LAUNCHD_PULL_PATH"

  sudo -u "$REAL_USER" launchctl enable "gui/$REAL_UID/com.gen2.g2agent" 2>/dev/null || true
  sudo -u "$REAL_USER" launchctl enable "gui/$REAL_UID/com.gen2.g2pull" 2>/dev/null || true
}

install_cron_fallback() {
  log "Installing cron fallback..."
  local agent_line="* * * * * /bin/bash $AGENT_PATH >/dev/null 2>&1"
  local pull_line="*/5 * * * * /bin/bash $PULL_AGENT_PATH >/dev/null 2>&1"

  if [[ "$OS" == "linux" ]]; then
    (crontab -l 2>/dev/null | grep -v "$AGENT_PATH" | grep -v "$PULL_AGENT_PATH" || true; \
      echo "$agent_line"; echo "$pull_line") | crontab -
  else
    (sudo -u "$REAL_USER" crontab -l 2>/dev/null | grep -v "$AGENT_PATH" | grep -v "$PULL_AGENT_PATH" || true; \
      echo "$agent_line"; echo "$pull_line") | sudo -u "$REAL_USER" crontab -
  fi
}

schedule_install() {
  if [[ "$OS" == "linux" && $(is_systemd; echo $?) -eq 0 ]]; then
    install_systemd
  elif [[ "$OS" == "macos" ]]; then
    # Prefer launchd; if it fails, fallback to cron
    if have_cmd launchctl; then
      install_launchd || install_cron_fallback
    else
      install_cron_fallback
    fi
  else
    install_cron_fallback
  fi
}

schedule_remove() {
  if [[ "$OS" == "linux" && $(is_systemd; echo $?) -eq 0 ]]; then
    systemctl disable --now "$SYSTEMD_AGENT_TIMER" "$SYSTEMD_PULL_TIMER" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$SYSTEMD_AGENT_TIMER" "/etc/systemd/system/$SYSTEMD_AGENT_SERVICE" \
          "/etc/systemd/system/$SYSTEMD_PULL_TIMER" "/etc/systemd/system/$SYSTEMD_PULL_SERVICE"
    systemctl daemon-reload >/dev/null 2>&1 || true
  elif [[ "$OS" == "macos" ]]; then
    sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID" "$LAUNCHD_AGENT_PATH" 2>/dev/null || true
    sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID" "$LAUNCHD_PULL_PATH" 2>/dev/null || true
    rm -f "$LAUNCHD_AGENT_PATH" "$LAUNCHD_PULL_PATH"
    # Remove cron fallback lines as well
    (sudo -u "$REAL_USER" crontab -l 2>/dev/null | grep -v "$AGENT_PATH" | grep -v "$PULL_AGENT_PATH" || true) \
      | sudo -u "$REAL_USER" crontab - 2>/dev/null || true
  else
    (crontab -l 2>/dev/null | grep -v "$AGENT_PATH" | grep -v "$PULL_AGENT_PATH" || true) | crontab - 2>/dev/null || true
  fi
}

self_install() {
  safe_mkdir "$INSTALL_DIR"
  cp -f "$0" "$SELF_PATH" 2>/dev/null || true
  chmod +x "$SELF_PATH" 2>/dev/null || true
  [[ "$OS" == "linux" ]] && chown root:root "$SELF_PATH" 2>/dev/null || true
  [[ "$OS" == "macos" ]] && chown "$REAL_USER" "$SELF_PATH" 2>/dev/null || true
}

# ---------- commands ----------
install_cmd() {
  install_deps

  safe_mkdir "$BIN_DIR"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    interactive_config
  else
    log "Config exists: $CONFIG_FILE (skipping interactive setup)"
  fi

  write_agent
  install_pull_agent
  schedule_install
  self_install

  log "Install complete."
  log "Run: $SELF_PATH status"
}

repair_cmd() {
  install_deps
  safe_mkdir "$BIN_DIR"
  [[ -f "$CONFIG_FILE" ]] || { warn "Missing config; running interactive setup."; interactive_config; }

  write_agent
  install_pull_agent
  schedule_install
  self_install

  log "Repair complete."
}

uninstall_cmd() {
  if [[ "$OS" == "linux" ]]; then need_root_linux; fi
  schedule_remove
  rm -rf "$INSTALL_DIR"
  # queue cleanup:
  if [[ "$OS" == "linux" ]]; then rm -rf /var/lib/g2serve; fi
  if [[ "$OS" == "macos" ]]; then rm -rf "$REAL_HOME/.g2serve/queue"; fi
  log "Uninstalled."
}

status_cmd() {
  log "OS:          $OS"
  log "Install dir: $INSTALL_DIR"
  log "Config:      $CONFIG_FILE"
  log "Agent:       $AGENT_PATH"
  log "Pull:        $PULL_AGENT_PATH"
  echo ""

  if [[ "$OS" == "linux" && $(is_systemd; echo $?) -eq 0 ]]; then
    systemctl status "$SYSTEMD_AGENT_TIMER" --no-pager || true
    systemctl status "$SYSTEMD_PULL_TIMER" --no-pager || true
    echo ""
    systemctl list-timers --all | grep -E "g2agent|g2pull" || true
  elif [[ "$OS" == "macos" ]]; then
    sudo -u "$REAL_USER" launchctl print "gui/$REAL_UID/com.gen2.g2agent" 2>/dev/null | head -n 40 || true
    sudo -u "$REAL_USER" launchctl print "gui/$REAL_UID/com.gen2.g2pull" 2>/dev/null | head -n 40 || true
    echo ""
    sudo -u "$REAL_USER" crontab -l 2>/dev/null | grep -E "g2agent.sh|pull-agent.sh" || true
  else
    crontab -l 2>/dev/null | grep -E "g2agent.sh|pull-agent.sh" || true
  fi

  echo ""
  if [[ -f "$QUEUE_DIR_DEFAULT/queue.jsonl" ]]; then
    log "Queue lines: $(wc -l < "$QUEUE_DIR_DEFAULT/queue.jsonl" 2>/dev/null || echo 0)"
  else
    log "Queue: empty/not present"
  fi
}

run_once_cmd() {
  [[ -x "$AGENT_PATH" ]] || die "Agent missing. Run: $0 repair"
  "$AGENT_PATH"
  log "Run-once completed."
}

usage() {
  cat <<EOF
GEN2 Ground Probe (g2.sh) - Cross-platform

Usage:
  bash g2.sh install
  bash g2.sh repair
  bash g2.sh uninstall
  bash g2.sh status
  bash g2.sh run-once

Notes:
- Linux install/uninstall typically requires sudo (writes /opt + systemd).
- macOS prefers running WITHOUT sudo so LaunchAgents install to your session.
- Optimized for 20 checks on low-power devices (Pi Zero 2W):
  lock + concurrency cap + retries + queue + WAN caching
EOF
}

main() {
  local cmd="${1:-install}"
  case "$cmd" in
    install)   install_cmd ;;
    repair)    repair_cmd ;;
    uninstall) uninstall_cmd ;;
    status)    status_cmd ;;
    run-once)  run_once_cmd ;;
    -h|--help|help) usage ;;
    *) die "Unknown command: $cmd" ;;
  esac
}

main "$@"
