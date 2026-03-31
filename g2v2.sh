#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================================================
# GEN2 Ground Probe Installer - g2v2.sh
# Cross-platform: Raspberry Pi OS / Debian / Ubuntu / macOS
#
# Features:
# - Detect existing installation + menu:
#   1) Configure monitors & timers
#   2) Uninstall completely
#   3) Repair / reconfigure
# - Defaults: monitor every 2 minutes, pull every 5 minutes
# - Strong pre-flight checks; safe downloads; syntax verification
# - systemd timer (Linux) + cron fallback; launchd (macOS)
# ==========================================================

# ---------- Constants ----------
GEN2_API_BASE_URL="${GEN2_API_BASE_URL:-https://gen2bullseye.com}"
PULL_AGENT_URL="${PULL_AGENT_URL:-https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/main/pull-agent.sh}"
DEFAULT_WEBHOOK="${DEFAULT_WEBHOOK:-https://nscl.tailc52c94.ts.net/webhook/ps2}"

DEFAULT_MONITOR_INTERVAL_SECONDS="${DEFAULT_MONITOR_INTERVAL_SECONDS:-120}"  # ✅ 2 minutes
DEFAULT_PULL_INTERVAL_SECONDS="${DEFAULT_PULL_INTERVAL_SECONDS:-300}"        # 5 minutes
DEFAULT_MAX_JOBS="${DEFAULT_MAX_JOBS:-3}"

# ---------- Detect OS ----------
OS="linux"
[[ "${OSTYPE:-}" == "darwin"* ]] && OS="macos"

# Determine "real" user/home (important when script is run with sudo)
REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_UID="$(id -u "$REAL_USER" 2>/dev/null || echo "$(id -u)")"
REAL_HOME="$(eval echo "~$REAL_USER" 2>/dev/null || echo "$HOME")"

# Install locations
if [[ "$OS" == "macos" ]]; then
  INSTALL_DIR="${INSTALL_DIR:-$REAL_HOME/.g2serve}"
  QUEUE_DIR_DEFAULT="${QUEUE_DIR_DEFAULT:-$REAL_HOME/.g2serve/queue}"
else
  INSTALL_DIR="${INSTALL_DIR:-/opt/g2serve}"
  QUEUE_DIR_DEFAULT="${QUEUE_DIR_DEFAULT:-/var/lib/g2serve}"
fi

BIN_DIR="$INSTALL_DIR/bin"
CONFIG_FILE="$INSTALL_DIR/agent.env"
AGENT_PATH="$BIN_DIR/g2agent.sh"
PULL_AGENT_PATH="$BIN_DIR/pull-agent.sh"

# Schedulers
SYSTEMD_AGENT_SERVICE="g2agent.service"
SYSTEMD_AGENT_TIMER="g2agent.timer"
SYSTEMD_PULL_SERVICE="g2pull.service"
SYSTEMD_PULL_TIMER="g2pull.timer"

LAUNCHD_AGENT_PLIST="com.gen2.g2agent.plist"
LAUNCHD_PULL_PLIST="com.gen2.g2pull.plist"
LAUNCHD_DIR="$REAL_HOME/Library/LaunchAgents"
LAUNCHD_AGENT_PATH="$LAUNCHD_DIR/$LAUNCHD_AGENT_PLIST"
LAUNCHD_PULL_PATH="$LAUNCHD_DIR/$LAUNCHD_PULL_PLIST"

# ---------- Logging / errors ----------
log()  { echo "[g2] $*"; }
warn() { echo "[g2][WARN] $*" >&2; }
die()  { echo "[g2][ERROR] $*" >&2; exit 1; }

on_err() {
  local exit_code=$?
  local line_no=${1:-"?"}
  warn "Failed (exit=$exit_code) at line $line_no."
  warn "Tip: run: bash -n $0  (syntax check) or: bash -x $0 <command>"
  exit "$exit_code"
}
trap 'on_err $LINENO' ERR

# ---------- Utilities ----------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_root() { [[ "${EUID:-$(id -u)}" -eq 0 ]]; }

need_root_linux() {
  if [[ "$OS" == "linux" && ! "$(is_root && echo yes || echo no)" == "yes" ]]; then
    die "Linux install/repair/uninstall needs sudo/root."
  fi
}

is_systemd() {
  [[ "$OS" == "linux" && -d /run/systemd/system ]] && have_cmd systemctl
}

safe_mkdir() {
  mkdir -p "$1"
}

# Safe download: fail on HTTP errors + validate file looks like script
download_file() {
  local url="$1"
  local out="$2"

  safe_mkdir "$(dirname "$out")"

  # -f: fail on HTTP errors, -S: show error, -L: follow redirects
  if ! curl -fsSL "$url" -o "$out"; then
    die "Download failed: $url"
  fi

  # Basic validation: not HTML, not empty
  if [[ ! -s "$out" ]]; then
    die "Downloaded file is empty: $out"
  fi

  # If it looks like HTML, stop early (common with 404 pages)
  if head -n 2 "$out" | grep -qiE '<!doctype html|<html|not found|404'; then
    warn "Downloaded content does not look like a shell script."
    warn "First lines:"
    head -n 5 "$out" >&2
    die "Refusing to execute invalid download."
  fi

  # Optional: syntax check if it's bash script
  if head -n 1 "$out" | grep -qE '^#!.*(bash|sh)'; then
    bash -n "$out" || die "Syntax check failed for: $out"
  fi
}

mask_secret() {
  # mask all but last 6 chars
  local s="${1:-}"
  local n=${#s}
  if (( n <= 8 )); then echo "****"; return; fi
  echo "****${s: -6}"
}

# ---------- Existing install detection ----------
is_installed() {
  [[ -f "$CONFIG_FILE" && -x "$AGENT_PATH" ]]
}

ensure_dirs() {
  safe_mkdir "$INSTALL_DIR"
  safe_mkdir "$BIN_DIR"
  safe_mkdir "$QUEUE_DIR_DEFAULT"
  chmod 755 "$INSTALL_DIR" "$BIN_DIR" 2>/dev/null || true

  # Ensure correct ownership on macOS
  if [[ "$OS" == "macos" ]]; then
    chown -R "$REAL_USER" "$INSTALL_DIR" 2>/dev/null || true
    chown -R "$REAL_USER" "$QUEUE_DIR_DEFAULT" 2>/dev/null || true
  fi
}

# ---------- Dependencies ----------
install_deps_linux() {
  need_root_linux

  if have_cmd apt-get; then
    apt-get update -y
    apt-get install -y curl jq ca-certificates iputils-ping
  elif have_cmd dnf; then
    dnf install -y curl jq ca-certificates iputils
  elif have_cmd yum; then
    yum install -y curl jq ca-certificates iputils
  else
    die "No supported package manager found (apt/dnf/yum). Install curl+jq manually."
  fi
}

install_deps_macos() {
  # curl is present; jq may not be.
  if ! have_cmd jq; then
    if have_cmd brew; then
      brew install jq
    else
      die "jq not found. Install Homebrew then run: brew install jq"
    fi
  fi
}

install_deps() {
  log "Installing dependencies..."
  if [[ "$OS" == "linux" ]]; then
    install_deps_linux
  else
    install_deps_macos
  fi
}

# ---------- Agent generation (safe + portable) ----------
write_agent() {
  ensure_dirs

  # We avoid fancy bash features (compat with macOS bash 3.2)
  cat > "$AGENT_PATH" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail

# -------- portable overlap lock --------
LOCKDIR="/tmp/g2agent.lockdir"
if ! mkdir "\$LOCKDIR" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "\$LOCKDIR" 2>/dev/null || true' EXIT

BASE_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="\$BASE_DIR/../agent.env"
[[ -f "\$CONFIG_FILE" ]] || exit 0
# shellcheck disable=SC1090
source "\$CONFIG_FILE"

QUEUE_DIR="\${QUEUE_DIR:-$QUEUE_DIR_DEFAULT}"
QUEUE_FILE="\$QUEUE_DIR/queue.jsonl"
WAN_CACHE="/tmp/g2_wan.cache"
mkdir -p "\$QUEUE_DIR"

# --------- helpers ----------
post_payload() {
  # fast POST: no need to read response body
  curl --silent --fail \\
    --connect-timeout "\${CURL_CONNECT_TIMEOUT:-3}" \\
    --max-time "\${CURL_MAX_TIME:-5}" \\
    --retry 2 --retry-delay 1 --retry-all-errors \\
    -X POST "\$N8N_WEBHOOK_URL" \\
    -H "Content-Type: application/json" \\
    -d "\$1" >/dev/null
}

flush_queue() {
  [[ -f "\$QUEUE_FILE" ]] || return 0
  : > "\${QUEUE_FILE}.tmp"
  while IFS= read -r line; do
    [[ -z "\$line" ]] && continue
    post_payload "\$line" || echo "\$line" >> "\${QUEUE_FILE}.tmp"
  done < "\$QUEUE_FILE"
  mv "\${QUEUE_FILE}.tmp" "\$QUEUE_FILE"
}

get_local_ip() {
  if [[ "\${OSTYPE:-}" == "darwin"* ]]; then
    ipconfig getifaddr "\$(route get default 2>/dev/null | awk '/interface:/{print \$2}')" 2>/dev/null || echo ""
  else
    hostname -I 2>/dev/null | awk '{print \$1}'
  fi
}

get_wan_ip() {
  # cache for 1 hour
  if [[ -f "\$WAN_CACHE" ]]; then
    # linux stat
    if stat -c %Y "\$WAN_CACHE" >/dev/null 2>&1; then
      age=\$(( \$(date +%s) - \$(stat -c %Y "\$WAN_CACHE" 2>/dev/null || echo 0) ))
    else
      # mac stat
      age=\$(( \$(date +%s) - \$(stat -f %m "\$WAN_CACHE" 2>/dev/null || echo 0) ))
    fi
    if (( age < \${WAN_TTL:-3600} )); then
      cat "\$WAN_CACHE"
      return 0
    fi
  fi

  wan=\$(curl -s --connect-timeout 2 --max-time 4 https://api.ipify.org || true)
  [[ -n "\$wan" ]] && echo "\$wan" > "\$WAN_CACHE"
  echo "\$wan"
}

# -------- concurrency semaphore (portable) --------
MAX_JOBS="\${MAX_JOBS:-$DEFAULT_MAX_JOBS}"
sem_init() {
  SEM_FIFO="\$(mktemp -u "/tmp/g2sem.XXXX")"
  mkfifo "\$SEM_FIFO"
  exec 3<>"\$SEM_FIFO"
  rm -f "\$SEM_FIFO"
  i=0
  while (( i < MAX_JOBS )); do
    printf '.' >&3
    i=\$((i+1))
  done
}
sem_acquire() { read -r -n 1 -u 3 _; }
sem_release() { printf '.' >&3; }

process_target() {
  entry="\$1"
  NAME="\$(echo "\${entry%%|*}" | xargs)"
  TARGET="\$(echo "\${entry#*|}" | xargs)"

  LOCAL_IP="\$(get_local_ip)"
  WAN_IP="\$(get_wan_ip)"

  # Ping: 1 packet (lightweight)
  if ping -c 1 -W 2 "\$TARGET" >/dev/null 2>&1; then
    PING_STATUS="up"
    PING_LATENCY=1
  else
    PING_STATUS="down"
    PING_LATENCY=0
  fi

  HTTP_STATUS="n/a"
  HTTP_LATENCY=0
  if echo "\$TARGET" | grep -qE '^https?://'; then
    t=\$(curl -o /dev/null -s -w '%{time_total}' --connect-timeout 3 --max-time 6 "\$TARGET" 2>/dev/null || true)
    if [[ -n "\$t" ]]; then
      HTTP_STATUS="up"
      HTTP_LATENCY=\$(awk "BEGIN {print (\$t * 1000)}" 2>/dev/null || echo 0)
    else
      HTTP_STATUS="down"
      HTTP_LATENCY=0
    fi
  fi

  TS=\$(date -u +%Y-%m-%dT%H:%M:%SZ)

  PAYLOAD=\$(jq -n \\
    --arg oid "\$ORG_ID" --arg lic "\$LICENSE_KEY" --arg sid "\$SERVER_ID" \\
    --arg lip "\$LOCAL_IP" --arg wan "\$WAN_IP" \\
    --arg mon "\$NAME" --arg tar "\$TARGET" \\
    --arg ps "\$PING_STATUS" --argjson pl "\$PING_LATENCY" \\
    --arg hs "\$HTTP_STATUS" --argjson hl "\$HTTP_LATENCY" \\
    --arg ts "\$TS" \\
    '{org_id:\$oid,license_key:\$lic,server_id:\$sid,local_ip:\$lip,wan_ip:\$wan,
      monitor:\$mon,target:\$tar,ping_status:\$ps,ping_latency_ms:\$pl,
      http_status:\$hs,http_latency_ms:\$hl,timestamp:\$ts}' )

  if ! post_payload "\$PAYLOAD"; then
    echo "\$PAYLOAD" >> "\$QUEUE_FILE"
  fi
}

main() {
  flush_queue
  sem_init

  for entry in "\${TARGETS[@]}"; do
    sem_acquire
    (
      process_target "\$entry"
      sem_release
    ) &
  done
  wait || true

  flush_queue
}

main
EOF

  chmod +x "$AGENT_PATH"

  # Validate generated agent (prevents silent bad deployments)
  bash -n "$AGENT_PATH" || die "Generated agent has syntax error: $AGENT_PATH"
}

# ---------- Config management ----------
write_config() {
  local org_id="$1"
  local license_key="$2"
  local server_id="$3"
  local webhook="$4"
  local interval="$5"
  local max_jobs="$6"
  shift 6
  local targets=("$@")

  ensure_dirs

  {
    echo "ORG_ID=\"$org_id\""
    echo "LICENSE_KEY=\"$license_key\""
    echo "SERVER_ID=\"$server_id\""
    echo "N8N_WEBHOOK_URL=\"$webhook\""
    echo "MONITOR_INTERVAL=\"$interval\""
    echo "MAX_JOBS=\"$max_jobs\""
    echo "WAN_TTL=\"3600\""
    echo "QUEUE_DIR=\"$QUEUE_DIR_DEFAULT\""
    declare -p targets | sed 's/^declare -a targets=/declare -a TARGETS=/'
  } > "$CONFIG_FILE"

  # permissions
  if [[ "$OS" == "linux" ]]; then
    chmod 640 "$CONFIG_FILE" || true
  else
    chmod 600 "$CONFIG_FILE" || true
    chown "$REAL_USER" "$CONFIG_FILE" 2>/dev/null || true
  fi
}

load_config() {
  [[ -f "$CONFIG_FILE" ]] || die "Config not found: $CONFIG_FILE"
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"

  [[ -n "${ORG_ID:-}" ]] || die "ORG_ID missing in config"
  [[ -n "${LICENSE_KEY:-}" ]] || die "LICENSE_KEY missing in config"
  [[ -n "${SERVER_ID:-}" ]] || die "SERVER_ID missing in config"
  [[ -n "${N8N_WEBHOOK_URL:-}" ]] || die "N8N_WEBHOOK_URL missing in config"
}

prompt_monitors() {
  local arr=()
  while true; do
    read -rp "Monitor name: " n
    read -rp "Target (URL/IP): " t
    arr+=("$n | $t")
    read -rp "Add another monitor? (y/n): " yn
    [[ "$yn" =~ ^[Yy]$ ]] || break
  done

  # Print as newline-separated to stdout for capture
  printf '%s\n' "${arr[@]}"
}

prompt_interval() {
  read -rp "Monitor frequency in minutes (1/2/5) [default 2]: " mins
  case "${mins:-2}" in
    1) echo 60 ;;
    5) echo 300 ;;
    *) echo 120 ;;
  esac
}

# ---------- Pull agent ----------
install_pull_agent() {
  ensure_dirs
  download_file "$PULL_AGENT_URL" "$PULL_AGENT_PATH"
  chmod +x "$PULL_AGENT_PATH"
}

# ---------- Scheduler install/remove ----------
install_systemd_units() {
  local interval="$1"

  need_root_linux
  cat > "/etc/systemd/system/$SYSTEMD_AGENT_SERVICE" <<EOF
[Unit]
Description=GEN2 Ground Probe Agent
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$AGENT_PATH
EOF

  cat > "/etc/systemd/system/$SYSTEMD_AGENT_TIMER" <<EOF
[Unit]
Description=Run GEN2 Agent every ${interval}s

[Timer]
OnBootSec=30s
OnUnitActiveSec=${interval}s
AccuracySec=10s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat > "/etc/systemd/system/$SYSTEMD_PULL_SERVICE" <<EOF
[Unit]
Description=GEN2 Pull Agent
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$PULL_AGENT_PATH
EOF

  cat > "/etc/systemd/system/$SYSTEMD_PULL_TIMER" <<EOF
[Unit]
Description=Run GEN2 Pull Agent every ${DEFAULT_PULL_INTERVAL_SECONDS}s

[Timer]
OnBootSec=60s
OnUnitActiveSec=${DEFAULT_PULL_INTERVAL_SECONDS}s
AccuracySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$SYSTEMD_AGENT_TIMER" "$SYSTEMD_PULL_TIMER"
}

remove_systemd_units() {
  need_root_linux
  systemctl disable --now "$SYSTEMD_AGENT_TIMER" "$SYSTEMD_PULL_TIMER" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SYSTEMD_AGENT_SERVICE" "/etc/systemd/system/$SYSTEMD_AGENT_TIMER" \
        "/etc/systemd/system/$SYSTEMD_PULL_SERVICE" "/etc/systemd/system/$SYSTEMD_PULL_TIMER"
  systemctl daemon-reload 2>/dev/null || true
}

install_launchd_units() {
  local interval="$1"

  safe_mkdir "$LAUNCHD_DIR"

  cat > "$LAUNCHD_AGENT_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.gen2.g2agent</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$AGENT_PATH</string></array>
  <key>StartInterval</key><integer>$interval</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/tmp/g2agent.out</string>
  <key>StandardErrorPath</key><string>/tmp/g2agent.err</string>
</dict></plist>
EOF

  cat > "$LAUNCHD_PULL_PATH" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.gen2.g2pull</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$PULL_AGENT_PATH</string></array>
  <key>StartInterval</key><integer>$DEFAULT_PULL_INTERVAL_SECONDS</integer>
  <key>RunAtLoad</key><true/>
  <key>StandardOutPath</key><string>/tmp/g2pull.out</string>
  <key>StandardErrorPath</key><string>/tmp/g2pull.err</string>
</dict></plist>
EOF

  chown "$REAL_USER" "$LAUNCHD_AGENT_PATH" "$LAUNCHD_PULL_PATH" 2>/dev/null || true

  # Load in the user's GUI session
  sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID" "$LAUNCHD_AGENT_PATH" 2>/dev/null || true
  sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID" "$LAUNCHD_PULL_PATH" 2>/dev/null || true
  sudo -u "$REAL_USER" launchctl bootstrap "gui/$REAL_UID" "$LAUNCHD_AGENT_PATH"
  sudo -u "$REAL_USER" launchctl bootstrap "gui/$REAL_UID" "$LAUNCHD_PULL_PATH"
}

remove_launchd_units() {
  sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID" "$LAUNCHD_AGENT_PATH" 2>/dev/null || true
  sudo -u "$REAL_USER" launchctl bootout "gui/$REAL_UID" "$LAUNCHD_PULL_PATH" 2>/dev/null || true
  rm -f "$LAUNCHD_AGENT_PATH" "$LAUNCHD_PULL_PATH"
}

install_cron_fallback_linux() {
  need_root_linux
  (crontab -l 2>/dev/null | grep -v "$AGENT_PATH" | grep -v "$PULL_AGENT_PATH" || true
   echo "*/2 * * * * $AGENT_PATH >/dev/null 2>&1"
   echo "*/5 * * * * $PULL_AGENT_PATH >/dev/null 2>&1"
  ) | crontab -
}

remove_cron_linux() {
  need_root_linux
  (crontab -l 2>/dev/null | grep -v "$AGENT_PATH" | grep -v "$PULL_AGENT_PATH" || true) | crontab - 2>/dev/null || true
}

install_scheduler() {
  load_config
  local interval="${MONITOR_INTERVAL:-$DEFAULT_MONITOR_INTERVAL_SECONDS}"

  if [[ "$OS" == "linux" ]]; then
    if is_systemd; then
      install_systemd_units "$interval"
    else
      warn "systemd not detected; using cron fallback."
      install_cron_fallback_linux
    fi
  else
    install_launchd_units "$interval"
  fi
}

remove_scheduler() {
  if [[ "$OS" == "linux" ]]; then
    if is_systemd; then
      remove_systemd_units
    fi
    remove_cron_linux
  else
    remove_launchd_units
  fi
}

# ---------- Actions ----------
fresh_install() {
  log "Fresh installation..."
  install_deps
  ensure_dirs

  read -rp "Org ID: " org
  read -rp "License Key: " lic
  read -rp "Server ID: " sid

  local webhook="$DEFAULT_WEBHOOK"
  read -rp "N8N Webhook URL [default: $DEFAULT_WEBHOOK]: " wh
  [[ -n "${wh:-}" ]] && webhook="$wh"

  interval="$(prompt_interval)"

  # Concurrency tuning (Pi-safe default)
  read -rp "Max parallel checks [default ${DEFAULT_MAX_JOBS}]: " mj
  mj="${mj:-$DEFAULT_MAX_JOBS}"

  log "Configure monitors:"
  mapfile -t mons < <(prompt_monitors)

  write_config "$org" "$lic" "$sid" "$webhook" "$interval" "$mj" "${mons[@]}"

  write_agent
  install_pull_agent
  install_scheduler

  log "Installed OK."
  log "Monitor frequency: ${interval}s, pull: ${DEFAULT_PULL_INTERVAL_SECONDS}s, max_jobs: $mj"
}

configure_monitors_and_timers() {
  load_config

  log "Reconfigure monitors & timer"
  interval="$(prompt_interval)"
  read -rp "Max parallel checks [current ${MAX_JOBS:-$DEFAULT_MAX_JOBS}]: " mj
  mj="${mj:-${MAX_JOBS:-$DEFAULT_MAX_JOBS}}"

  log "Configure monitors:"
  mapfile -t mons < <(prompt_monitors)

  write_config "$ORG_ID" "$LICENSE_KEY" "$SERVER_ID" "$N8N_WEBHOOK_URL" "$interval" "$mj" "${mons[@]}"

  write_agent
  install_scheduler

  log "Updated monitors/timers OK."
}

repair_or_reconfigure() {
  log "Repair / reconfigure..."
  install_deps
  ensure_dirs

  if [[ ! -f "$CONFIG_FILE" ]]; then
    warn "Config missing. Running fresh install..."
    fresh_install
    return
  fi

  load_config
  write_agent
  install_pull_agent
  install_scheduler

  log "Repair complete."
}

uninstall_completely() {
  log "Uninstalling..."
  remove_scheduler
  rm -rf "$INSTALL_DIR"
  rm -rf "$QUEUE_DIR_DEFAULT"
  log "Uninstalled completely."
}

status() {
  echo ""
  log "OS: $OS"
  log "Install dir: $INSTALL_DIR"
  log "Config: $CONFIG_FILE"
  log "Agent: $AGENT_PATH"
  log "Pull agent: $PULL_AGENT_PATH"
  echo ""

  if [[ -f "$CONFIG_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG_FILE"
    log "Org ID: ${ORG_ID:-N/A}"
    log "License: $(mask_secret "${LICENSE_KEY:-}")"
    log "Server ID: ${SERVER_ID:-N/A}"
    log "Webhook: ${N8N_WEBHOOK_URL:-N/A}"
    log "Monitor interval: ${MONITOR_INTERVAL:-$DEFAULT_MONITOR_INTERVAL_SECONDS}s"
    log "Max jobs: ${MAX_JOBS:-$DEFAULT_MAX_JOBS}"
    echo ""
  else
    warn "No config found."
  fi

  if [[ "$OS" == "linux" && $(is_systemd && echo yes || echo no) == "yes" ]]; then
    systemctl list-timers --all | grep -E 'g2agent|g2pull' || true
  elif [[ "$OS" == "macos" ]]; then
    sudo -u "$REAL_USER" launchctl print "gui/$REAL_UID/com.gen2.g2agent" 2>/dev/null | head -n 25 || true
    sudo -u "$REAL_USER" launchctl print "gui/$REAL_UID/com.gen2.g2pull" 2>/dev/null | head -n 25 || true
  fi

  echo ""
  if [[ -f "$QUEUE_DIR_DEFAULT/queue.jsonl" ]]; then
    log "Queue lines: $(wc -l < "$QUEUE_DIR_DEFAULT/queue.jsonl" 2>/dev/null || echo 0)"
  else
    log "Queue: empty/not present"
  fi
}

run_once() {
  [[ -x "$AGENT_PATH" ]] || die "Agent missing. Run: $0 repair"
  "$AGENT_PATH"
  log "Run-once completed."
}

menu_existing_install() {
  echo ""
  log "Existing GEN2 installation detected at $INSTALL_DIR"
  echo "1) Configure monitors & timers"
  echo "2) Uninstall completely"
  echo "3) Repair / reconfigure"
  echo "4) Status"
  echo "5) Exit"
  read -rp "Select [1-5]: " choice
  case "$choice" in
    1) configure_monitors_and_timers ;;
    2) uninstall_completely ;;
    3) repair_or_reconfigure ;;
    4) status ;;
    *) exit 0 ;;
  esac
}

usage() {
  cat <<EOF
Usage:
  bash $0 install
  bash $0 configure
  bash $0 repair
  bash $0 uninstall
  bash $0 status
  bash $0 run-once

Notes:
- Linux install/repair/uninstall typically requires sudo.
- macOS install should be run without sudo (preferred), but works with sudo too.
EOF
}

main() {
  local cmd="${1:-}"

  case "$cmd" in
    install)
      if is_installed; then menu_existing_install; else fresh_install; fi
      ;;
    configure)
      if is_installed; then configure_monitors_and_timers; else die "Not installed yet. Run: install"; fi
      ;;
    repair)
      repair_or_reconfigure
      ;;
    uninstall)
      uninstall_completely
      ;;
    status)
      status
      ;;
    run-once)
      run_once
      ;;
    "" )
      # No command: auto behavior
      if is_installed; then menu_existing_install; else fresh_install; fi
      ;;
    -h|--help|help)
      usage
      ;;
    *)
      die "Unknown command: $cmd"
      ;;
  esac
}

main "$@"
