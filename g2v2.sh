#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# GEN2 Ground Probe - g2v2.sh (Linux)
# Detect existing install + menu:
# 1) Configure monitors & timers
# 2) Uninstall completely
# 3) Repair / reconfigure
# ==================================================

INSTALL_DIR="/opt/g2serve"
BIN_DIR="$INSTALL_DIR/bin"
CFG="$INSTALL_DIR/agent.env"
AGENT="$BIN_DIR/g2agent.sh"
PULL_AGENT="$BIN_DIR/pull-agent.sh"
QUEUE_DIR="/var/lib/g2serve"

PULL_AGENT_URL="https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/main/pull-agent.sh"
DEFAULT_WEBHOOK="https://nscl.tailc52c94.ts.net/webhook/ps2"

DEFAULT_MONITOR_INTERVAL=120   # ✅ 2 minutes
PULL_INTERVAL=300              # 5 minutes

log(){ echo "[g2] $*"; }
die(){ echo "[g2][ERROR] $*" >&2; exit 1; }

[[ ${EUID:-$(id -u)} -ne 0 ]] && die "Run with sudo"

is_installed() {
  [[ -f "$CFG" && -x "$AGENT" ]]
}

ensure_dirs() {
  mkdir -p "$INSTALL_DIR" "$BIN_DIR" "$QUEUE_DIR"
  chmod 755 "$INSTALL_DIR" "$BIN_DIR" 2>/dev/null || true
}

install_deps() {
  apt-get update -y
  apt-get install -y curl jq iputils-ping ca-certificates
}

write_agent() {
  ensure_dirs
  cat > "$AGENT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Prevent overlap
LOCKDIR="/tmp/g2agent.lockdir"
mkdir "$LOCKDIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCKDIR" 2>/dev/null || true' EXIT

BASE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1090
source "$BASE/../agent.env"

QUEUE_FILE="/var/lib/g2serve/queue.jsonl"
WAN_CACHE="/tmp/g2_wan.cache"
mkdir -p /var/lib/g2serve

post_payload() {
  # fire-and-forget style; we only need success/fail
  curl --silent --fail \
    --connect-timeout 3 --max-time 5 \
    --retry 2 --retry-delay 1 --retry-all-errors \
    -X POST "$N8N_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$1" >/dev/null
}

flush_queue() {
  [[ -f "$QUEUE_FILE" ]] || return 0
  : > "${QUEUE_FILE}.tmp"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    post_payload "$line" || echo "$line" >> "${QUEUE_FILE}.tmp"
  done < "$QUEUE_FILE"
  mv "${QUEUE_FILE}.tmp" "$QUEUE_FILE"
}

get_wan_ip() {
  if [[ -f "$WAN_CACHE" ]] && (( $(date +%s) - $(stat -c %Y "$WAN_CACHE" 2>/dev/null || echo 0) < 3600 )); then
    cat "$WAN_CACHE"
  else
    curl -s --connect-timeout 2 --max-time 4 https://api.ipify.org | tee "$WAN_CACHE"
  fi
}

flush_queue

for entry in "${TARGETS[@]}"; do
(
  NAME="$(echo "${entry%%|*}" | xargs)"
  TARGET="$(echo "${entry#*|}" | xargs)"

  LOCAL_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  WAN_IP="$(get_wan_ip)"

  # Ping: 1 probe
  if ping -c 1 -W 2 "$TARGET" >/dev/null 2>&1; then
    PING_STATUS="up"
  else
    PING_STATUS="down"
  fi

  # HTTP check for URLs: curl timing
  HTTP_STATUS="n/a"
  HTTP_LATENCY=0
  if [[ "$TARGET" =~ ^https?:// ]]; then
    t=$(curl -o /dev/null -s -w '%{time_total}' --connect-timeout 3 --max-time 6 "$TARGET" || true)
    if [[ -n "$t" ]]; then
      HTTP_STATUS="up"
      HTTP_LATENCY=$(awk "BEGIN{print $t*1000}")
    else
      HTTP_STATUS="down"
      HTTP_LATENCY=0
    fi
  fi

  PAYLOAD=$(jq -n \
    --arg oid "$ORG_ID" --arg lic "$LICENSE_KEY" --arg sid "$SERVER_ID" \
    --arg lip "$LOCAL_IP" --arg wan "$WAN_IP" \
    --arg mon "$NAME" --arg tar "$TARGET" \
    --arg ps "$PING_STATUS" \
    --arg hs "$HTTP_STATUS" --argjson hl "$HTTP_LATENCY" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{org_id:$oid,license_key:$lic,server_id:$sid,local_ip:$lip,wan_ip:$wan,
      monitor:$mon,target:$tar,ping_status:$ps,http_status:$hs,http_latency_ms:$hl,
      timestamp:$ts}')

  post_payload "$PAYLOAD" || echo "$PAYLOAD" >> "$QUEUE_FILE"
)&
done

wait
flush_queue
EOF
  chmod +x "$AGENT"
}

write_systemd() {
  local monitor_interval="${1:-120}"

  cat > /etc/systemd/system/g2agent.service <<EOF
[Unit]
Description=GEN2 Ground Probe Agent
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$AGENT
EOF

  cat > /etc/systemd/system/g2agent.timer <<EOF
[Unit]
Description=Run GEN2 Agent every ${monitor_interval}s

[Timer]
OnBootSec=30s
OnUnitActiveSec=${monitor_interval}s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  cat > /etc/systemd/system/g2pull.service <<EOF
[Unit]
Description=GEN2 Pull Agent
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=$PULL_AGENT
EOF

  cat > /etc/systemd/system/g2pull.timer <<EOF
[Unit]
Description=Run GEN2 Pull Agent every ${PULL_INTERVAL}s

[Timer]
OnBootSec=60s
OnUnitActiveSec=${PULL_INTERVAL}s
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now g2agent.timer g2pull.timer
}

download_pull_agent() {
  ensure_dirs
  curl -fsSL "$PULL_AGENT_URL" -o "$PULL_AGENT"
  chmod +x "$PULL_AGENT"
}

configure_monitors_and_timers() {
  # Load existing config
  # shellcheck disable=SC1090
  source "$CFG"

  echo ""
  log "Configure Monitors"
  TARGETS=()
  while true; do
    read -rp "Monitor name: " m_name
    read -rp "Target (URL/IP): " m_target
    TARGETS+=("$m_name | $m_target")
    read -rp "Add another monitor? (y/n): " yn
    [[ "$yn" =~ ^[Yy]$ ]] || break
  done

  echo ""
  read -rp "Monitor frequency in minutes (1/2/5) [default 2]: " mins
  case "${mins:-2}" in
    1) MONITOR_INTERVAL=60 ;;
    5) MONITOR_INTERVAL=300 ;;
    *) MONITOR_INTERVAL=120 ;;
  esac

  # Preserve creds + webhook
  {
    echo "ORG_ID=\"$ORG_ID\""
    echo "LICENSE_KEY=\"$LICENSE_KEY\""
    echo "SERVER_ID=\"$SERVER_ID\""
    echo "N8N_WEBHOOK_URL=\"$N8N_WEBHOOK_URL\""
    echo "MONITOR_INTERVAL=\"$MONITOR_INTERVAL\""
    declare -p TARGETS
  } > "$CFG"

  write_agent
  write_systemd "$MONITOR_INTERVAL"
  log "Updated monitors and timer to ${MONITOR_INTERVAL}s"
}

repair_or_reconfigure() {
  install_deps
  ensure_dirs

  if [[ ! -f "$CFG" ]]; then
    log "No config found. Running fresh setup..."
    fresh_install
    return
  fi

  # shellcheck disable=SC1090
  source "$CFG"
  local interval="${MONITOR_INTERVAL:-$DEFAULT_MONITOR_INTERVAL}"

  write_agent
  download_pull_agent
  write_systemd "$interval"

  log "Repair complete."
}

uninstall_completely() {
  systemctl disable --now g2agent.timer g2pull.timer 2>/dev/null || true
  rm -f /etc/systemd/system/g2agent.service /etc/systemd/system/g2agent.timer \
