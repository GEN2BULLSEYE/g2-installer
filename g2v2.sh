#!/usr/bin/env bash
set -euo pipefail

# ==================================================
# GEN2 Ground Probe - g2v2.sh
# Auto-detect install | Configure | Repair | Uninstall
# ==================================================

INSTALL_DIR="/opt/g2serve"
BIN_DIR="$INSTALL_DIR/bin"
CFG="$INSTALL_DIR/agent.env"
AGENT="$BIN_DIR/g2agent.sh"
QUEUE_DIR="/var/lib/g2serve"

PULL_AGENT_URL="https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/main/pull-agent.sh"
DEFAULT_WEBHOOK="https://nscl.tailc52c94.ts.net/webhook/ps2"

MONITOR_INTERVAL_DEFAULT=120   # seconds
PULL_INTERVAL=300

# ---------------- helpers ----------------
log(){ echo "[g2] $*"; }
die(){ echo "[g2][ERROR] $*" >&2; exit 1; }

[[ $EUID -ne 0 ]] && die "Run with sudo"

is_installed() {
  [[ -f "$CFG" && -x "$AGENT" ]]
}

pause() {
  read -rp "Press ENTER to continue..."
}

# ---------------- deps ----------------
install_deps() {
  apt-get update -y
  apt-get install -y curl jq iputils-ping ca-certificates
}

# ---------------- agent ----------------
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
    --connect-timeout 3 --max-time 5 \
    -X POST "$N8N_WEBHOOK_URL" \
    -H "Content-Type: application/json" \
    -d "$1" >/dev/null
}

flush_queue() {
  [[ -f "$QUEUE_FILE" ]] || return
  >"$QUEUE_FILE.tmp"
  while read -r l; do
    post "$l" || echo "$l" >>"$QUEUE_FILE.tmp"
  done <"$QUEUE_FILE"
  mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"
}

get_wan() {
  [[ -f "$WAN_CACHE" && $(( $(date +%s) - $(stat -c %Y "$WAN_CACHE" 2>/dev/null || echo 0) )) -lt 3600 ]] \
    && cat "$WAN_CACHE" && return
  curl -s https://api.ipify.org | tee "$WAN_CACHE"
}

flush_queue

for entry in "${TARGETS[@]}"; do
(
  NAME="${entry%%|*}"; TARGET="${entry#*|}"
  LIP="$(hostname -I | awk '{print $1}')"
  WAN="$(get_wan)"

  ping -c 1 -W 2 "$TARGET" >/dev/null && P="up" || P="down"

  HS="n/a"; HL=0
  if [[ "$TARGET" =~ ^https?:// ]]; then
    t=$(curl -o /dev/null -s -w '%{time_total}' --connect-timeout 3 --max-time 6 "$TARGET" || true)
    [[ -n "$t" ]] && HS="up" && HL=$(awk "BEGIN{print $t*1000}")
  fi

  jq -n \
    --arg oid "$ORG_ID" --arg lic "$LICENSE_KEY" --arg sid "$SERVER_ID" \
    --arg mon "$NAME" --arg tar "$TARGET" \
    --arg lip "$LIP" --arg wan "$WAN" \
    --arg ps "$P" --arg hs "$HS" \
    --argjson hl "$HL" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{org_id:$oid,license_key:$lic,server_id:$sid,monitor:$mon,target:$tar,
      local_ip:$lip,wan_ip:$wan,ping_status:$ps,
      http_status:$hs,http_latency_ms:$hl,timestamp:$ts}' \
    | { read p; post "$p" || echo "$p" >>"$QUEUE_FILE"; }
)&
done
wait
flush_queue
EOF

chmod +x "$AGENT"
}

# ---------------- systemd ----------------
write_systemd() {
cat > /etc/systemd/system/g2agent.service <<EOF
[Service]
Type=oneshot
ExecStart=$AGENT
EOF

cat > /etc/systemd/system/g2agent.timer <<EOF
[Timer]
OnBootSec=30s
OnUnitActiveSec=${MONITOR_INTERVAL}s
Persistent=true
EOF

cat > /etc/systemd/system/g2pull.service <<EOF
[Service]
Type=oneshot
ExecStart=$BIN_DIR/pull-agent.sh
EOF

cat > /etc/systemd/system/g2pull.timer <<EOF
[Timer]
OnBootSec=60s
OnUnitActiveSec=${PULL_INTERVAL}s
Persistent=true
EOF

systemctl daemon-reload
systemctl enable --now g2agent.timer g2pull.timer
}

# ---------------- config ----------------
configure_monitors() {
  source "$CFG"

  TARGETS=()
  while true; do
    read -rp "Monitor name: " n
    read -rp "Target (IP/URL): " t
    TARGETS+=("$n | $t")
    read -rp "Add another? (y/n): " a
    [[ "$a" != "y" ]] && break
  done

  read -rp "Monitor interval in minutes (1/2/5) [2]: " mi
  case "$mi" in
    1) MONITOR_INTERVAL=60 ;;
    5) MONITOR_INTERVAL=300 ;;
    *) MONITOR_INTERVAL=120 ;;
  esac

  {
    echo "ORG_ID=\"$ORG_ID\""
    echo "LICENSE_KEY=\"$LICENSE_KEY\""
    echo "SERVER_ID=\"$SERVER_ID\""
    echo "N8N_WEBHOOK_URL=\"$N8N_WEBHOOK_URL\""
    declare -p TARGETS
  } > "$CFG"

  write_agent
  write_systemd
}

# ---------------- actions ----------------
fresh_install() {
  install_deps
  read -rp "Org ID: " ORG_ID
  read -rp "License Key: " LICENSE_KEY
  read -rp "Server ID: " SERVER_ID

  mkdir -p "$INSTALL_DIR"
  MONITOR_INTERVAL=$MONITOR_INTERVAL_DEFAULT

  {
    echo "ORG_ID=\"$ORG_ID\""
    echo "LICENSE_KEY=\"$LICENSE_KEY\""
    echo "SERVER_ID=\"$SERVER_ID\""
    echo "N8N_WEBHOOK_URL=\"$DEFAULT_WEBHOOK\""
    echo "declare -a TARGETS=()"
  } > "$CFG"

  curl -fsSL "$PULL_AGENT_URL" -o "$BIN_DIR/pull-agent.sh"
  chmod +x "$BIN_DIR/pull-agent.sh"

  configure_monitors
  log "Fresh installation complete"
}

repair_install() {
  install_deps
  source "$CFG"
  MONITOR_INTERVAL=${MONITOR_INTERVAL:-$MONITOR_INTERVAL_DEFAULT}
  write_agent
  curl -fsSL "$PULL_AGENT_URL" -o "$BIN_DIR/pull-agent.sh"
  chmod +x "$BIN_DIR/pull-agent.sh"
  write_systemd
  log "Repair complete"
}

uninstall_all() {
  systemctl disable --now g2agent.timer g2pull.timer 2>/dev/null || true
  rm -rf "$INSTALL_DIR" "$QUEUE_DIR"
  log "Uninstalled completely"
}

# ---------------- main ----------------
if is_installed; then
  echo ""
  log "Existing GEN2 installation detected"
  echo "1) Configure monitors & timers"
  echo "2) Repair / reconfigure installation"
  echo "3) Uninstall completely"
  echo "4) Exit"
  read -rp "Select [1-4]: " c
  case "$c" in
    1) configure_monitors ;;
    2) repair_install ;;
    3) uninstall_all ;;
    *) exit 0 ;;
  esac
else
  fresh_install
fi
