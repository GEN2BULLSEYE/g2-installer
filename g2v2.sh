#!/usr/bin/env bash
# GEN2 Ground Probe Installer / Management Console (Optimized for low-power devices like Raspberry Pi Zero 2W)
# Key improvements:
#  - Prevent overlapping runs (lock)
#  - Curl timeouts + retries
#  - WAN IP caching
#  - Bounded concurrency
#  - Local spool/queue for guaranteed delivery on intermittent networks
#  - Optional Wi-Fi power-save disable (systemd) on Linux
set -u

GEN2_API_BASE_URL="https://gen2bullseye.com"
PULL_AGENT_URL="https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/main/pull-agent.sh"

# --- 1. Global Setup ---
if [[ "${OSTYPE:-}" == "darwin"* ]]; then
  OS_TYPE="macos"
  INSTALL_DIR="$HOME/.g2serve"
  if [ -d "$INSTALL_DIR" ] && [ "$(stat -f '%u' "$INSTALL_DIR" 2>/dev/null || echo 9999)" -eq 0 ]; then
    sudo chown -R "$(whoami)" "$INSTALL_DIR" || true
  fi
else
  OS_TYPE="linux"
  INSTALL_DIR="/opt/g2serve"
fi

# Require root on Linux (because /opt and systemd units)
if [[ "$OS_TYPE" == "linux" ]] && [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root on Linux: sudo bash $0"
  exit 1
fi

AGENT_PATH="$INSTALL_DIR/g2agent.sh"
PULL_AGENT_PATH="$INSTALL_DIR/pull-agent.sh"
CONFIG_FILE="$INSTALL_DIR/agent.env"
FIXED_WEBHOOK_URL="https://nscl.tailc52c94.ts.net/webhook/ps2"

# Optional logs/spool locations (kept inside INSTALL_DIR for portability)
SPOOL_DIR="$INSTALL_DIR/spool"
LOG_DIR="$INSTALL_DIR/logs"
AGENT_LOG="$LOG_DIR/g2agent.log"

# --- 2. Dependency Installer ---
install_dependencies() {
  echo "Checking dependencies for $OS_TYPE..."
  if [[ "$OS_TYPE" == "macos" ]]; then
    if ! command -v brew >/dev/null 2>&1; then
      echo "Error: Homebrew not found. Install it at https://brew.sh"
      exit 1
    fi
    brew install jq curl || true
  else
    # util-linux provides flock, iputils-ping provides ping; iw for Wi-Fi powersave controls
    apt-get update -y && apt-get install -y jq curl iputils-ping util-linux iw ca-certificates || \
    dnf install -y jq curl iputils-ping util-linux iw ca-certificates
  fi
}

# --- 3. Optimized Monitoring Agent (Worker) ---
write_agent_script() {
  mkdir -p "$INSTALL_DIR" "$SPOOL_DIR" "$LOG_DIR"

  cat <<'EOF' > "$AGENT_PATH"
#!/usr/bin/env bash
set -u
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$BASE_DIR/agent.env"

# -----------------------
# Tunables (safe defaults)
# -----------------------
: "${MAX_JOBS:=3}"                 # Max parallel targets (Pi Zero 2W: 2-4 recommended)
: "${PING_COUNT:=1}"               # Reduce CPU/network overhead (was 3)
: "${PING_TIMEOUT:=2}"             # Seconds
: "${HTTP_CONNECT_TIMEOUT:=3}"     # Seconds
: "${HTTP_MAX_TIME:=6}"            # Seconds (whole operation)
: "${POST_CONNECT_TIMEOUT:=3}"     # Seconds
: "${POST_MAX_TIME:=8}"            # Seconds
: "${CURL_RETRY:=3}"
: "${CURL_RETRY_DELAY:=1}"
: "${WAN_TTL_SECONDS:=3600}"       # Cache WAN IP for 1 hour
: "${WAN_IP_PROVIDER:=https://api.ipify.org}" # More stable than some endpoints; override if needed

SPOOL_DIR="${SPOOL_DIR:-$BASE_DIR/spool}"
LOG_DIR="${LOG_DIR:-$BASE_DIR/logs}"
AGENT_LOG="${AGENT_LOG:-$LOG_DIR/g2agent.log}"
mkdir -p "$SPOOL_DIR" "$LOG_DIR" >/dev/null 2>&1 || true

LOCK_FILE="${LOCK_FILE:-$SPOOL_DIR/g2agent.lock}"
QUEUE_FILE="${QUEUE_FILE:-$SPOOL_DIR/queue.jsonl}"
WAN_CACHE="${WAN_CACHE:-$SPOOL_DIR/wan_ip.cache}"

log() {
  printf "%s %s\n" "$(date -Is)" "$*" >> "$AGENT_LOG" 2>/dev/null || true
}

# -----------------------
# Lock: prevent overlap
# -----------------------
acquire_lock() {
  if command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK_FILE" || exit 0
    flock -n 9 || exit 0
  else
    # Fallback lock (best-effort)
    if [[ -f "$LOCK_FILE" ]]; then
      local oldpid
      oldpid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
      if [[ -n "$oldpid" ]] && kill -0 "$oldpid" 2>/dev/null; then
        exit 0
      fi
    fi
    echo "$$" > "$LOCK_FILE" 2>/dev/null || true
  fi
}
acquire_lock

# -----------------------
# Network discovery (once)
# -----------------------
if [[ "${OSTYPE:-}" == "darwin"* ]]; then
  LOCAL_IP="$(ipconfig getifaddr "$(route get default | awk '/interface:/{print $2}')" 2>/dev/null || echo "")"
  WIFI_SSID="$(networksetup -getairportnetwork en0 2>/dev/null | cut -d ":" -f 2- | sed 's/^ //' )"
  [[ -z "$WIFI_SSID" || "$WIFI_SSID" == *"Error"* ]] && WIFI_SSID="N/A"
else
  LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}' || echo "")"
  if command -v nmcli >/dev/null 2>&1; then
    WIFI_SSID="$(nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '$1=="yes"{print $2; exit}')"
    [[ -z "$WIFI_SSID" ]] && WIFI_SSID="N/A"
  else
    WIFI_SSID="N/A"
  fi
fi

# -----------------------
# WAN IP cache (avoid per-minute external call)
# -----------------------
get_wan_ip() {
  local now cache_age
  now="$(date +%s)"
  if [[ -f "$WAN_CACHE" ]]; then
    cache_age=$(( now - $(stat -c %Y "$WAN_CACHE" 2>/dev/null || echo 0) ))
  else
    cache_age=$((WAN_TTL_SECONDS + 1))
  fi

  if [[ -f "$WAN_CACHE" && "$cache_age" -lt "$WAN_TTL_SECONDS" ]]; then
    cat "$WAN_CACHE" 2>/dev/null || echo ""
    return 0
  fi

  local ip
  ip="$(curl -fsS --connect-timeout 2 --max-time 4 "$WAN_IP_PROVIDER" 2>/dev/null || true)"
  if [[ -n "$ip" ]]; then
    echo "$ip" > "$WAN_CACHE" 2>/dev/null || true
    echo "$ip"
  else
    # fallback (old endpoint)
    ip="$(curl -fsS --connect-timeout 2 --max-time 4 "https://ifconfig.me" 2>/dev/null || true)"
    [[ -n "$ip" ]] && echo "$ip" > "$WAN_CACHE" 2>/dev/null || true
    echo "$ip"
  fi
}

WAN_IP="$(get_wan_ip)"

# -----------------------
# Reliable POST with retries; spool on failure
# -----------------------
post_payload() {
  local payload="$1"
  if curl --fail --silent --show-error \
      --connect-timeout "$POST_CONNECT_TIMEOUT" --max-time "$POST_MAX_TIME" \
      --retry "$CURL_RETRY" --retry-delay "$CURL_RETRY_DELAY" --retry-all-errors \
      -X POST "$N8N_WEBHOOK_URL" -H "Content-Type: application/json" -d "$payload" \
      >/dev/null 2>>"$AGENT_LOG"; then
    return 0
  fi
  echo "$payload" >> "$QUEUE_FILE" 2>/dev/null || true
  return 1
}

flush_queue() {
  [[ -s "$QUEUE_FILE" ]] || return 0
  local tmp="${QUEUE_FILE}.tmp"
  : > "$tmp" 2>/dev/null || return 0

  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    if ! curl --fail --silent --show-error \
        --connect-timeout "$POST_CONNECT_TIMEOUT" --max-time "$POST_MAX_TIME" \
        --retry 2 --retry-delay 1 --retry-all-errors \
        -X POST "$N8N_WEBHOOK_URL" -H "Content-Type: application/json" -d "$line" \
        >/dev/null 2>>"$AGENT_LOG"; then
      echo "$line" >> "$tmp" 2>/dev/null || true
    fi
  done < "$QUEUE_FILE"

  mv "$tmp" "$QUEUE_FILE" 2>/dev/null || true
}

flush_queue

# -----------------------
# Target processing
# -----------------------
process_target() {
  local entry="$1"
  local NAME TARGET
  NAME="$(echo "${entry%%|*}" | xargs)"
  TARGET="$(echo "${entry#*|}" | xargs)"

  # Ping
  local PING_LATENCY="" PING_STATUS="down"
  if [[ "${OSTYPE:-}" == "darwin"* ]]; then
    # macOS ping uses -t for TTL; timeout behavior differs; keep small
    local out
    out="$(ping -c "$PING_COUNT" -t "$PING_TIMEOUT" "$TARGET" 2>/dev/null || true)"
    PING_LATENCY="$(echo "$out" | awk -F'/' 'END{print $5}' | tr -dc '0-9.')"
  else
    local out
    out="$(ping -c "$PING_COUNT" -W "$PING_TIMEOUT" "$TARGET" 2>/dev/null || true)"
    PING_LATENCY="$(echo "$out" | awk -F'/' 'END{print $5}' | tr -dc '0-9.')"
  fi
  [[ -n "$PING_LATENCY" && "$PING_LATENCY" != "0" ]] && PING_STATUS="up"

  # HTTP check (lighter than httping): one curl, capture code + time_total
  local HTTP_STATUS="n/a" HTTP_LATENCY_MS=0
  if [[ "$TARGET" == http* ]]; then
    local res code ttotal
    res="$(curl -sS -o /dev/null -w '%{http_code} %{time_total}' \
      --connect-timeout "$HTTP_CONNECT_TIMEOUT" --max-time "$HTTP_MAX_TIME" \
      "$TARGET" 2>/dev/null || echo "000 0")"

    code="$(echo "$res" | awk '{print $1}')"
    ttotal="$(echo "$res" | awk '{print $2}')"

    # Consider reachable if curl got a response code (even 404 is "reachable")
    if [[ "$code" != "000" ]]; then
      HTTP_STATUS="up"
      HTTP_LATENCY_MS="$(awk -v t="$ttotal" 'BEGIN{printf "%.0f", (t*1000)}')"
    else
      HTTP_STATUS="down"
      HTTP_LATENCY_MS=0
    fi
  fi

  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  # Build payload with jq (safe escaping)
  local PAYLOAD
  PAYLOAD="$(jq -n \
    --arg oid "$ORG_ID" --arg lkey "$LICENSE_KEY" --arg sid "$SERVER_ID" \
    --arg lip "${LOCAL_IP:-}" --arg wip "${WAN_IP:-}" --arg ssid "${WIFI_SSID:-N/A}" \
    --arg mon "$NAME" --arg tar "$TARGET" --arg p_sta "$PING_STATUS" \
    --argjson p_lat "${PING_LATENCY:-0}" --arg h_sta "$HTTP_STATUS" \
    --argjson h_lat "${HTTP_LATENCY_MS:-0}" --arg ts "$ts" \
    '{org_id:$oid, license_key:$lkey, server_id:$sid,
      local_ip:$lip, wan_ip:$wip, wifi_ssid:$ssid,
      monitor:$mon, target:$tar,
      ping_status:$p_sta, ping_latency_ms:$p_lat,
      http_status:$h_sta, http_latency_ms:$h_lat,
      timestamp:$ts }' 2>/dev/null )"

  if [[ -n "$PAYLOAD" ]]; then
    post_payload "$PAYLOAD" || log "Queued payload (post failed) for: $NAME -> $TARGET"
  else
    log "ERROR: jq failed building payload for: $NAME -> $TARGET"
  fi
}

# -----------------------
# Concurrency limiter
# -----------------------
run_targets() {
  local -i running=0
  for entry in "${TARGETS[@]}"; do
    process_target "$entry" &
    running=$((running+1))
    if [[ "$running" -ge "$MAX_JOBS" ]]; then
      # wait -n exists on modern bash (Debian/RPi OS). If unavailable, fallback to full wait.
      if wait -n 2>/dev/null; then
        running=$((running-1))
      else
        wait
        running=0
      fi
    fi
  done
  wait
}

run_targets
EOF

  chmod +x "$AGENT_PATH"
}

save_config() {
  mkdir -p "$INSTALL_DIR" "$SPOOL_DIR" "$LOG_DIR" 2>/dev/null || true
  {
    echo "ORG_ID=\"$ORG_ID\""
    echo "LICENSE_KEY=\"$LICENSE_KEY\""
    echo "SERVER_ID=\"$SERVER_ID\""
    echo "N8N_WEBHOOK_URL=\"$FIXED_WEBHOOK_URL\""

    # Optimized defaults (can be edited by user later)
    echo "MAX_JOBS=\"${MAX_JOBS:-3}\""
    echo "PING_COUNT=\"${PING_COUNT:-1}\""
    echo "PING_TIMEOUT=\"${PING_TIMEOUT:-2}\""
    echo "HTTP_CONNECT_TIMEOUT=\"${HTTP_CONNECT_TIMEOUT:-3}\""
    echo "HTTP_MAX_TIME=\"${HTTP_MAX_TIME:-6}\""
    echo "POST_CONNECT_TIMEOUT=\"${POST_CONNECT_TIMEOUT:-3}\""
    echo "POST_MAX_TIME=\"${POST_MAX_TIME:-8}\""
    echo "CURL_RETRY=\"${CURL_RETRY:-3}\""
    echo "CURL_RETRY_DELAY=\"${CURL_RETRY_DELAY:-1}\""
    echo "WAN_TTL_SECONDS=\"${WAN_TTL_SECONDS:-3600}\""
    echo "WAN_IP_PROVIDER=\"${WAN_IP_PROVIDER:-https://api.ipify.org}\""
    echo "SPOOL_DIR=\"$SPOOL_DIR\""
    echo "LOG_DIR=\"$LOG_DIR\""
    echo "AGENT_LOG=\"$AGENT_LOG\""

    declare -p TARGETS
  } > "$CONFIG_FILE"
}

# --- 3b. Linux-only: systemd timer (preferred) or cron fallback ---
install_scheduler() {
  if [[ "$OS_TYPE" != "linux" ]]; then
    # macOS fallback: cron
    (crontab -l 2>/dev/null | grep -v "g2agent.sh"; echo "* * * * * $AGENT_PATH >> /dev/null 2>&1") | crontab -
    return 0
  fi

  if command -v systemctl >/dev/null 2>&1; then
    cat > /etc/systemd/system/g2agent.service <<EOF
[Unit]
Description=GEN2 Ground Probe Agent
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=$AGENT_PATH
EOF

    cat > /etc/systemd/system/g2agent.timer <<EOF
[Unit]
Description=Run GEN2 Ground Probe Agent every minute

[Timer]
OnBootSec=30
OnUnitActiveSec=60
AccuracySec=5
Persistent=true

[Install]
WantedBy=timers.target
EOF

    systemctl daemon-reload
    systemctl enable --now g2agent.timer
    echo "Scheduler: systemd timer enabled (g2agent.timer)."
  else
    # cron fallback with overlap prevention at agent level (lock inside agent)
    (crontab -l 2>/dev/null | grep -v "g2agent.sh"; echo "* * * * * $AGENT_PATH >> /dev/null 2>&1") | crontab -
    echo "Scheduler: cron installed (every minute)."
  fi
}

# --- 3c. Optional: Disable Wi-Fi power save on Linux (helps with drop/latency) ---
install_wifi_powersave_fix() {
  [[ "$OS_TYPE" != "linux" ]] && return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  command -v iw >/dev/null 2>&1 || return 0

  cat > /etc/systemd/system/g2-wifi-powersave.service <<'EOF'
[Unit]
Description=Disable Wi-Fi power saving (wlan0) for stable monitoring
After=sys-subsystem-net-devices-wlan0.device
Wants=sys-subsystem-net-devices-wlan0.device

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/iw dev wlan0 set power_save off

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now g2-wifi-powersave.service || true
  echo "Wi-Fi power save: attempted disable via systemd (g2-wifi-powersave.service)."
}

install_pull_agent() {
  echo "Downloading GEN2 pull agent..."
  if curl -fsSL "$PULL_AGENT_URL" -o "$PULL_AGENT_PATH" && chmod +x "$PULL_AGENT_PATH"; then
    (crontab -l 2>/dev/null | grep -v "pull-agent.sh"; echo "*/5 * * * * $PULL_AGENT_PATH >> /dev/null 2>&1") | crontab -
    echo "Remote management enabled — monitors dispatched from your dashboard will sync within 5 minutes."
  else
    echo "Warning: Could not download pull agent. Remote management will not be active."
  fi
}

dispatch_remote_job() {
  local action="$1" name="$2" target="$3"
  local RESP HTTP_CODE BODY
  RESP="$(curl -s -w "\n%{http_code}" -X POST \
    "${GEN2_API_BASE_URL}/api/groundprobe/dispatch?license_key=${LICENSE_KEY}&org_id=${ORG_ID}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg a "$action" --arg n "$name" --arg t "$target" '{action:$a,monitor_name:$n,target:$t}')" )"
  HTTP_CODE="$(echo "$RESP" | tail -1)"
  BODY="$(echo "$RESP" | head -n -1)"
  if [ "$HTTP_CODE" = "200" ]; then
    echo "Job dispatched successfully. The pull agent will apply this within 5 minutes."
  else
    echo "API error (HTTP $HTTP_CODE): $BODY"
    echo "Tip: Check your License Key and Org ID in $CONFIG_FILE"
  fi
}

view_remote_jobs() {
  echo ""
  echo "Fetching pending jobs from GEN2..."
  local RESP HTTP_CODE BODY COUNT PENDING_COUNT COMPLETED_COUNT
  RESP="$(curl -s -w "\n%{http_code}" \
    "${GEN2_API_BASE_URL}/api/groundprobe/jobs/status?license_key=${LICENSE_KEY}&org_id=${ORG_ID}")"
  HTTP_CODE="$(echo "$RESP" | tail -1)"
  BODY="$(echo "$RESP" | head -n -1)"

  if [ "$HTTP_CODE" != "200" ]; then
    echo "Could not reach GEN2 (HTTP $HTTP_CODE). Check your network connection."
    return
  fi

  COUNT="$(echo "$BODY" | jq 'length' 2>/dev/null || echo 0)"
  if [ -z "$COUNT" ] || [ "$COUNT" = "0" ]; then
    echo "No jobs found. Dispatch monitors from your dashboard at ${GEN2_API_BASE_URL}"
    return
  fi

  PENDING_COUNT="$(echo "$BODY" | jq '[.[] | select(.status == "pending" or .status == "delivered")] | length')"
  COMPLETED_COUNT="$(echo "$BODY" | jq '[.[] | select(.status == "completed")] | length')"

  echo "--- Remote Jobs: $PENDING_COUNT pending/in-progress, $COMPLETED_COUNT completed ---"
  for i in $(seq 0 $((COUNT - 1))); do
    local STATUS ACTION NAME TARGET CREATED
    STATUS="$(echo "$BODY" | jq -r ".[$i].status")"
    [[ "$STATUS" == "completed" ]] && continue
    ACTION="$(echo "$BODY" | jq -r ".[$i].action")"
    NAME="$(echo "$BODY" | jq -r ".[$i].monitor_name")"
    TARGET="$(echo "$BODY" | jq -r ".[$i].target")"
    CREATED="$(echo "$BODY" | jq -r ".[$i].created_at")"
    echo "  [$STATUS] [$ACTION] $NAME -> $TARGET  (created: $CREATED)"
  done
  if [ "$COMPLETED_COUNT" -gt 0 ]; then
    echo "  ... $COMPLETED_COUNT completed job(s) (see dashboard for full history)"
  fi
}

# --- Uninstall (removes cron + systemd units + files) ---
do_uninstall() {
  (crontab -l 2>/dev/null | grep -v "g2agent.sh" | grep -v "pull-agent.sh") | crontab - || true

  if [[ "$OS_TYPE" == "linux" ]] && command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now g2agent.timer 2>/dev/null || true
    rm -f /etc/systemd/system/g2agent.service /etc/systemd/system/g2agent.timer
    systemctl disable --now g2-wifi-powersave.service 2>/dev/null || true
    rm -f /etc/systemd/system/g2-wifi-powersave.service
    systemctl daemon-reload 2>/dev/null || true
  fi

  rm -rf "$INSTALL_DIR"
  echo "Uninstalled."
}

# --- 4. Main Menu Logic ---
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
  PULL_ACTIVE=$([[ -f "$PULL_AGENT_PATH" ]] && echo "yes" || echo "no")

  echo "--- GEN2 Management Console (Optimized) ---"
  if [[ "$PULL_ACTIVE" == "yes" ]]; then
    echo "Remote Management: enabled (syncs every 5 min from ${GEN2_API_BASE_URL})"
  else
    echo "Remote Management: not installed (re-run installer to enable)"
  fi
  echo ""
  echo "1) Manage Monitors"
  echo "2) Change Credentials"
  echo "3) Reinstall/Repair Scheduler"
  echo "4) Uninstall GEN2"
  echo "5) Exit"
  read -r -p "Select: " choice
  case "${choice:-}" in
    1)
      while true; do
        echo -e "\n--- Current Monitors (local snapshot) ---"
        for i in "${!TARGETS[@]}"; do echo "$((i+1))) ${TARGETS[$i]}"; done
        echo "-----------------------------------------"
        echo "1) Add Monitor (via GEN2 remote job)"
        echo "2) Remove Monitor (via GEN2 remote job)"
        echo "3) View Remote Job Status"
        echo "4) Back"
        if [[ "$PULL_ACTIVE" != "yes" ]]; then
          echo ""
          echo "  [!] Pull agent not found — jobs will queue in GEN2 but won't be applied"
          echo "      until pull-agent.sh is installed. Re-run the installer to enable it."
        fi
        read -r -p "Selection: " m_opt
        if [[ "${m_opt:-}" == "1" ]]; then
          read -r -p "  Monitor Name: " m_name
          read -r -p "  Target (URL/IP): " m_target
          dispatch_remote_job "add" "$m_name" "$m_target"
        elif [[ "${m_opt:-}" == "2" ]]; then
          read -r -p "  Monitor Name to remove: " m_name
          read -r -p "  Target to remove: " m_target
          dispatch_remote_job "remove" "$m_name" "$m_target"
        elif [[ "${m_opt:-}" == "3" ]]; then
          view_remote_jobs
        else
          break
        fi
      done
      ;;
    2)
      read -r -p "New Org ID: " ORG_ID
      read -r -p "New License: " LICENSE_KEY
      save_config
      ;;
    3)
      write_agent_script
      install_scheduler
      install_wifi_powersave_fix
      echo "Scheduler repaired."
      ;;
    4)
      do_uninstall
      ;;
    *)
      exit 0
      ;;
  esac
else
  # Fresh Installation
  install_dependencies
  mkdir -p "$INSTALL_DIR" "$SPOOL_DIR" "$LOG_DIR"
  read -r -p "Organization ID: " ORG_ID
  read -r -p "License Key: " LICENSE_KEY
  read -r -p "Server ID: " SERVER_ID

  # Optional tunables
  read -r -p "Max parallel checks (MAX_JOBS) [default 3]: " MAX_JOBS_IN
  MAX_JOBS="${MAX_JOBS_IN:-3}"

  TARGETS=()
  while true; do
    echo -e "\n--- Add a Monitor ---"
    read -r -p "  Monitor Name (e.g., Google): " m_name
    read -r -p "  Target (URL or IP): " m_target
    TARGETS+=("$m_name | $m_target")

    read -r -p "Add another monitor? (y/n): " confirm
    [[ "${confirm:-n}" != "y" ]] && break
  done

  save_config
  write_agent_script

  # Install scheduler (systemd timer preferred, cron fallback)
  install_scheduler

  # Always install pull agent for remote management
  install_pull_agent

  # Optional Wi-Fi power-save fix for stability on Pi
  install_wifi_powersave_fix

  echo ""
  echo "Installation Complete (Optimized)!"
  echo "Logs:   $AGENT_LOG"
  echo "Spool:  $SPOOL_DIR (queued payloads retry automatically)"
  echo "Your probe is connected. Dispatch monitors remotely from:"
  echo "  ${GEN2_API_BASE_URL} → Ground Probe Onboarding → Dispatch"
fi
