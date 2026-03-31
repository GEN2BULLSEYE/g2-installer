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

