#!/usr/bin/env bash
set -euo pipefail

# ==============================
# GEN2 Ground Probe - g2v2.sh
# Install / Repair / Uninstall
# Monitor frequency: 2 minutes
# ==============================

INSTALL_DIR="/opt/g2serve"
BIN_DIR="$INSTALL_DIR/bin"
CONFIG_FILE="$INSTALL_DIR/agent.env"
AGENT="$BIN_DIR/g2agent.sh"
PULL_AGENT="$BIN_DIR/pull-agent.sh"
QUEUE_DIR="/var/lib/g2serve"

N8N_WEBHOOK_URL_DEFAULT="https://nscl.tailc52c94.ts.net/webhook/ps2"
PULL_AGENT_URL="https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/main/pull-agent.sh"

MONITOR_INTERVAL_SECONDS=120   # ✅ 2 minutes
PULL_INTERVAL_SECONDS=300      # 5 minutes

# -------------------------
# Require root
# -------------------------
if [[ $EUID -ne 0 ]]; then
  echo "[g2] Run with sudo"
  exit 1
fi

log(){ echo "[g2] $*"; }

# -------------------------
# Dependencies
# -------------------------
install_deps() {
  apt-get update -y
  apt-get install -y curl jq iputils-ping ca-certificates
}

# -------------------------
# Agent script
# -------------------------
write_agent() {
  mkdir -p "$BIN_DIR" "$QUEUE_DIR"

  cat > "$AGENT" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

LOCK="/tmp/g2agent.lock"
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK"' EXIT

BASE="$(cd "$(dirname "$0")" && pwd)"
source "$BASE/../agent.env"

QUEUE_FILE="/var/lib/g2serve/queue.jsonl"
WAN_CACHE="/tmp/g2_wan.cache"

mkdir -p /var/lib/g2serve

post() {
  curl --silent --fail \
    --connect-timeout 3 \
    --max-time 5 \
    -X POST "$N8N_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$1" >/dev/null
}

flush_queue() {
  [[ -f "$QUEUE_FILE" ]] || return
  >"$QUEUE_FILE.tmp"
  while IFS= read -r line; do
    post "$line" || echo "$line" >>"$QUEUE_FILE.tmp"
  done <"$QUEUE_FILE"
  mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"
}

get_wan() {
  if [[ -f "$WAN_CACHE" ]] && (( $(date +%s) - $(stat -c %Y "$WAN_CACHE") < 3600 )); then
    cat "$WAN_CACHE"
  else
    curl -s https://api.ipify.org | tee "$WAN_CACHE"
  fi
}

flush_queue

for entry in "${TARGETS[@]}"; do
(
  NAME="${entry%%|*}"
  TARGET="${entry#*|}"

  LOCAL_IP="$(hostname -I | awk '{print $1}')"
  WAN_IP="$(get_wan)"

  ping -c 1 -W 2 "$TARGET" >/dev/null && PING_STATUS="up" || PING_STATUS="down"

  HTTP_STATUS="n/a"
  HTTP_LATENCY=0
  if [[ "$TARGET" =~ ^https?:// ]]; then
    t=$(curl -o /dev/null -s -w '%{time_total}' --connect-timeout 3 --max-time 6 "$TARGET" || true)
    if [[ -n "$t" ]]; then
      HTTP_STATUS="up"
      HTTP_LATENCY=$(awk "BEGIN{print $t*1000}")
    fi
  fi

  PAYLOAD=$(jq -n \
    --arg oid "$ORG_ID" \
    --arg lic "$LICENSE_KEY" \
    --arg sid "$SERVER_ID" \
    --arg mon "$NAME" \
    --arg tar "$TARGET" \
    --arg lip "$LOCAL_IP" \
    --arg wan "$WAN_IP" \
    --arg ps "$PING_STATUS" \
    --arg hs "$HTTP_STATUS" \
    --argjson hl "$HTTP_LATENCY" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{org_id:$oid,license_key:$lic,server_id:$sid,monitor:$mon,target:$tar,local_ip:$lip,wan_ip:$wan,ping_status:$ps,http_status:$hs,http_latency_ms:$hl,timestamp:$ts}'
  )

  post "$PAYLOAD" || echo "$PAYLOAD" >>"$QUEUE_FILE"
)&
done
wait

flush_queue
EOF

  chmod +x "$AGENT"
}

# -------------------------
# systemd timers (2 min)
# -------------------------
install_systemd() {
  cat > /etc/systemd/system/g2agent.service <<EOF
[Service]
Type=oneshot
ExecStart=$AGENT
EOF

  cat > /etc/systemd/system/g2agent.timer <<EOF
[Timer]
OnBootSec=30s
OnUnitActiveSec=${MONITOR_INTERVAL_SECONDS}s
Persistent=true
EOF

  cat > /etc/systemd/system/g2pull.service <<EOF
[Service]
Type=oneshot
ExecStart=$PULL_AGENT
EOF

  cat > /etc/systemd/system/g2pull.timer <<EOF
[Timer]
OnBootSec=60s
OnUnitActiveSec=${PULL_INTERVAL_SECONDS}s
Persistent=true
EOF

  systemctl daemon-reload
  systemctl enable --now g2agent.timer g2pull.timer
}

# -------------------------
# Install
# -------------------------
install() {
  install_deps
  mkdir -p "$INSTALL_DIR"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    read -rp "Org ID: " ORG_ID
    read -rp "License Key: " LICENSE_KEY
    read -rp "Server ID: " SERVER_ID

    {
      echo "ORG_ID=\"$ORG_ID\""
      echo "LICENSE_KEY=\"$LICENSE_KEY\""
      echo "SERVER_ID=\"$SERVER_ID\""
      echo "N8N_WEBHOOK_URL=\"$N8N_WEBHOOK_URL_DEFAULT\""
      echo "declare -a TARGETS=()"
    } > "$CONFIG_FILE"
  fi

  write_agent
  curl -fsSL "$PULL_AGENT_URL" -o "$PULL_AGENT"
  chmod +x "$PULL_AGENT"

  install_systemd
  log "Installed. Monitoring every 2 minutes."
}

case "${1:-install}" in
  install) install ;;
  repair) install ;;
  uninstall) systemctl disable --now g2agent.timer g2pull.timer; rm -rf "$INSTALL_DIR" "$QUEUE_DIR" ;;
  run-once) bash "$AGENT" ;;
  *) echo "Usage: install|repair|uninstall|run-once" ;;
esac
