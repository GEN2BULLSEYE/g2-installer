#!/usr/bin/env bash
set -Eeuo pipefail

# =========================
# GEN2 Ground Probe - g2.sh
# Installer + Uninstaller + Repair (One file)
# Optimized for Raspberry Pi Zero 2W / low-power Linux
# =========================

# ---------- Defaults ----------
GEN2_API_BASE_URL="${GEN2_API_BASE_URL:-https://gen2bullseye.com}"
PULL_AGENT_URL="${PULL_AGENT_URL:-https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/main/pull-agent.sh}"

INSTALL_DIR="${INSTALL_DIR:-/opt/g2serve}"
BIN_DIR="$INSTALL_DIR/bin"
CONFIG_FILE="$INSTALL_DIR/agent.env"
AGENT_PATH="$BIN_DIR/g2agent.sh"
SELF_PATH="$INSTALL_DIR/g2.sh"
PULL_AGENT_PATH="$BIN_DIR/pull-agent.sh"

# Your fixed webhook (as in your current script)
FIXED_WEBHOOK_URL="${FIXED_WEBHOOK_URL:-https://nscl.tailc52c94.ts.net/webhook/ps2}"

# Agent tuning (Pi Zero 2W stable defaults)
MAX_JOBS_DEFAULT="${MAX_JOBS_DEFAULT:-3}"     # concurrency limit
WAN_TTL_DEFAULT="${WAN_TTL_DEFAULT:-3600}"    # seconds, 1 hour cache
PING_TIMEOUT_DEFAULT="${PING_TIMEOUT_DEFAULT:-2}" # seconds
CURL_CONNECT_TIMEOUT_DEFAULT="${CURL_CONNECT_TIMEOUT_DEFAULT:-3}"
CURL_MAX_TIME_DEFAULT="${CURL_MAX_TIME_DEFAULT:-8}"
HTTP_MAX_TIME_DEFAULT="${HTTP_MAX_TIME_DEFAULT:-6}"

# systemd units
SERVICE_NAME="g2agent.service"
TIMER_NAME="g2agent.timer"
WIFI_SERVICE_NAME="g2-wifi-powersave.service"

# ---------- Helpers ----------
log()  { echo -e "[g2] $*"; }
warn() { echo -e "[g2] \e[33mWARN\e[0m: $*" >&2; }
die()  { echo -e "[g2] \e[31mERROR\e[0m: $*" >&2; exit 1; }

need_root() {
  if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "Run as root: sudo bash $0 <command>"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

is_systemd() {
  [[ -d /run/systemd/system ]] && have_cmd systemctl
}

safe_mkdir() {
  mkdir -p "$1"
  chmod 755 "$1" || true
}

write_file() {
  local path="$1"
  shift
  safe_mkdir "$(dirname "$path")"
  cat > "$path" <<EOF
$*
EOF
}

# ---------- Dependency install ----------
install_deps() {
  log "Checking dependencies..."
  local pkgs=(curl jq util-linux iputils-ping ca-certificates)

  # Optional: nmcli for SSID discovery
  # (We don't fail if missing)
  local apt_missing=()
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || apt_missing+=("$p")
  done

  if (( ${#apt_missing[@]} > 0 )); then
    log "Installing: ${apt_missing[*]}"
    apt-get update -y
    apt-get install -y "${apt_missing[@]}"
  else
    log "Dependencies already satisfied."
  fi
}

# ---------- Agent script ----------
write_agent() {
  log "Writing optimized agent to $AGENT_PATH"

  write_file "$AGENT_PATH" "#!/usr/bin/env bash
set -Eeuo pipefail

# --- Lock to prevent overlap ---
exec 9>/var/lock/g2agent.lock
flock -n 9 || exit 0

BASE_DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\"
CONFIG_FILE=\"\$BASE_DIR/../agent.env\"
[[ -f \"\$CONFIG_FILE\" ]] || exit 0
# shellcheck disable=SC1090
source \"\$CONFIG_FILE\"

# --- Config defaults ---
MAX_JOBS=\"\${MAX_JOBS:-$MAX_JOBS_DEFAULT}\"
WAN_TTL=\"\${WAN_TTL:-$WAN_TTL_DEFAULT}\"
PING_TIMEOUT=\"\${PING_TIMEOUT:-$PING_TIMEOUT_DEFAULT}\"
CURL_CONNECT_TIMEOUT=\"\${CURL_CONNECT_TIMEOUT:-$CURL_CONNECT_TIMEOUT_DEFAULT}\"
CURL_MAX_TIME=\"\${CURL_MAX_TIME:-$CURL_MAX_TIME_DEFAULT}\"
HTTP_MAX_TIME=\"\${HTTP_MAX_TIME:-$HTTP_MAX_TIME_DEFAULT}\"

QUEUE_DIR=\"\${QUEUE_DIR:-/var/lib/g2serve}\"
QUEUE_FILE=\"\$QUEUE_DIR/queue.jsonl\"
WAN_CACHE=\"/tmp/g2_wan_ip.cache\"

mkdir -p \"\$QUEUE_DIR\"

# --- Small utility: best-effort JSON send with retries ---
post_payload() {
  local payload=\"\$1\"
  curl --fail --silent --show-error \\
    --connect-timeout \"\$CURL_CONNECT_TIMEOUT\" \\
    --max-time \"\$CURL_MAX_TIME\" \\
    --retry 3 --retry-delay 1 --retry-all-errors \\
    -X POST \"\$N8N_WEBHOOK_URL\" \\
    -H \"Content-Type: application/json\" \\
    -d \"\$payload\" >/dev/null
}

# --- Flush queued payloads first (prevents 'missing packets') ---
flush_queue() {
  [[ -f \"\$QUEUE_FILE\" ]] || return 0
  local tmp=\"\${QUEUE_FILE}.tmp\"
  : > \"\$tmp\"

  while IFS= read -r line; do
    [[ -z \"\$line\" ]] && continue
    if post_payload \"\$line\"; then
      :
    else
      echo \"\$line\" >> \"\$tmp\"
    fi
  done < \"\$QUEUE_FILE\"

  mv \"\$tmp\" \"\$QUEUE_FILE\"
}

# --- Discover IP/SSID with minimal overhead ---
get_local_ip() {
  hostname -I 2>/dev/null | awk '{print \$1}'
}

get_wifi_ssid() {
  if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f active,ssid dev wifi 2>/dev/null | awk -F: '\$1==\"yes\"{print \$2; exit}'
  else
    echo \"N/A\"
  fi
}

# --- Cache WAN IP (avoid external call every minute) ---
get_wan_ip() {
  if [[ -f \"\$WAN_CACHE\" ]]; then
    local age=\$(( \$(date +%s) - \$(stat -c %Y \"\$WAN_CACHE\" 2>/dev/null || echo 0) ))
    if (( age < WAN_TTL )); then
      cat \"\$WAN_CACHE\"
      return 0
    fi
  fi

  local wan=\"\"
  wan=\$(curl -s --connect-timeout 2 --max-time 4 https://api.ipify.org || true)
  if [[ -n \"\$wan\" ]]; then
    echo \"\$wan\" > \"\$WAN_CACHE\"
  fi
  echo \"\$wan\"
}

# --- Core check ---
process_target() {
  local entry=\"\$1\"
  local NAME TARGET
  NAME=\$(echo \"\${entry%%|*}\" | xargs)
  TARGET=\$(echo \"\${entry#*|}\" | xargs)

  local LOCAL_IP WIFI_SSID WAN_IP
  LOCAL_IP=\$(get_local_ip)
  WIFI_SSID=\$(get_wifi_ssid)
  WAN_IP=\$(get_wan_ip)

  # Ping: 1 probe (lightweight), better for Pi Zero 2W
  local PING_RESULT PING_LATENCY PING_STATUS
  PING_RESULT=\$(ping -c 1 -W \"\$PING_TIMEOUT\" \"\$TARGET\" 2>/dev/null || true)
  PING_LATENCY=\$(echo \"\$PING_RESULT\" | tail -1 | awk -F'/' '{print \$5}' | tr -dc '0-9.' || true)
  PING_STATUS=\$([[ -z \"\$PING_LATENCY\" || \"\$PING_LATENCY\" == \"0\" ]] && echo \"down\" || echo \"up\")

  # HTTP check (only if URL): use curl timing (lighter than httping)
  local HTTP_STATUS HTTP_LATENCY
  HTTP_STATUS=\"n/a\"
  HTTP_LATENCY=\"0\"

  if [[ \"\$TARGET\" =~ ^https?:// ]]; then
    local t
    t=\$(curl -o /dev/null -s \\
      --connect-timeout \"\$CURL_CONNECT_TIMEOUT\" \\
      --max-time \"\$HTTP_MAX_TIME\" \\
      -w '%{time_total}' \"\$TARGET\" 2>/dev/null || true)

    if [[ -n \"\$t\" ]]; then
      HTTP_STATUS=\"up\"
      HTTP_LATENCY=\$(awk \"BEGIN {print (\$t * 1000)}\" 2>/dev/null || echo 0)
    else
      HTTP_STATUS=\"down\"
      HTTP_LATENCY=\"0\"
    fi
  fi

  local TS PAYLOAD
  TS=\$(date -u +%Y-%m-%dT%H:%M:%SZ)

  PAYLOAD=\$(jq -n \\
    --arg oid \"\$ORG_ID\" --arg lkey \"\$LICENSE_KEY\" --arg sid \"\$SERVER_ID\" \\
    --arg lip \"\$LOCAL_IP\" --arg wip \"\$WAN_IP\" --arg ssid \"\$WIFI_SSID\" \\
    --arg mon \"\$NAME\" --arg tar \"\$TARGET\" --arg p_sta \"\$PING_STATUS\" \\
    --argjson p_lat \"\${PING_LATENCY:-0}\" --arg h_sta \"\$HTTP_STATUS\" \\
    --argjson h_lat \"\${HTTP_LATENCY:-0}\" --arg ts \"\$TS\" \\
    '{org_id: $oid, license_key: $lkey, server_id: $sid, local_ip: $lip, wan_ip: $wip, wifi_ssid: $ssid, monitor: $mon, target: $tar, ping_status: $p_sta, ping_latency_ms: $p_lat, http_status: $h_sta, http_latency_ms: $h_lat, timestamp: $ts}' )

  if ! post_payload \"\$PAYLOAD\"; then
    # Queue for later resend
    echo \"\$PAYLOAD\" >> \"\$QUEUE_FILE\"
  fi
}

