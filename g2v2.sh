#!/usr/bin/env bash
set -Eeuo pipefail

# ============================================================
# GEN2 Ground Probe - g2v2.sh
# One script: install / repair / uninstall / status / run-once
# Monitoring frequency: 2 minutes
# ============================================================

# -------------------------
# Global configuration
# -------------------------
GEN2_API_BASE_URL="https://gen2bullseye.com"
PULL_AGENT_URL="https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/main/pull-agent.sh"
N8N_WEBHOOK_URL_DEFAULT="https://nscl.tailc52c94.ts.net/webhook/ps2"

MONITOR_INTERVAL_SECONDS=120    # ✅ 2 minutes
PULL_INTERVAL_SECONDS=300       # 5 minutes
MAX_JOBS_DEFAULT=3              # concurrency cap (Pi-safe)

# -------------------------
# OS detection
# -------------------------
OS="linux"
[[ "${OSTYPE:-}" == "darwin"* ]] && OS="macos"

REAL_USER="${SUDO_USER:-$(id -un)}"
REAL_UID="$(id -u "$REAL_USER")"
REAL_HOME="$(eval echo "~$REAL_USER")"

if [[ "$OS" == "macos" ]]; then
  INSTALL_DIR="$REAL_HOME/.g2serve"
  QUEUE_DIR="$INSTALL_DIR/queue"
else
  INSTALL_DIR="/opt/g2serve"
  QUEUE_DIR="/var/lib/g2serve"
fi

BIN_DIR="$INSTALL_DIR/bin"
CONFIG_FILE="$INSTALL_DIR/agent.env"
AGENT="$BIN_DIR/g2agent.sh"
PULL_AGENT="$BIN_DIR/pull-agent.sh"
SELF="$INSTALL_DIR/g2.sh"

# -------------------------
# Helpers
# -------------------------
log(){ echo "[g2] $*"; }
die(){ echo "[g2][ERROR] $*" >&2; exit 1; }
need_root(){ [[ "$OS" == "linux" && $EUID -ne 0 ]] && die "Run with sudo on Linux"; }

safe_mkdir(){ mkdir -p "$1"; }
write_file(){ safe_mkdir "$(dirname "$1")"; cat > "$1"; }

# -------------------------
# Dependencies
# -------------------------
install_deps() {
  if [[ "$OS" == "linux" ]]; then
    need_root
    apt-get update -y
    apt-get install -y curl jq iputils-ping ca-certificates
  else
    command -v jq >/dev/null || {
      command -v brew >/dev/null || die "Install Homebrew first"
      brew install jq
    }
  fi
}

# -------------------------
# Write monitoring agent
# -------------------------
write_agent() {
write_file "$AGENT" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

LOCK="/tmp/g2.lock"
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK"' EXIT

BASE="$(cd "$(dirname "$0")" && pwd)"
source "$BASE/../agent.env"

OS="linux"; [[ "${OSTYPE:-}" == "darwin"* ]] && OS="macos"

QUEUE_FILE="$QUEUE_DIR/queue.jsonl"
WAN_CACHE="/tmp/g2_wan.cache"
mkdir -p "$QUEUE_DIR"

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
  name="${entry%%|*}"; target="${entry#*|}"
  lip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  wan="$(get_wan)"
  ping -c 1 -W 2 "$target" >/dev/null && pstatus=up || pstatus=down

  http_status="n/a"; http_latency=0
  if [[ "$target" =~ ^https?:// ]]; then
    t=$(curl -o /dev/null -s -w '%{time_total}' --connect-timeout 3 --max-time 6 "$target")
    [[ -n "$t" ]] && http_status=up && http_latency=$(awk "BEGIN{print $t*1000}")
  fi

  payload=$(jq -n \
    --arg org "$ORG_ID" --arg lic "$LICENSE_KEY" --arg sid "$SERVER_ID" \
    --arg mon "$name" --arg tar "$target" \
    --arg lip "$lip" --arg wan "$wan" \
    --arg ps "$pstatus" --arg hs "$http_status" \
    --argjson hl "$http_latency" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{org_id:$org,license_key:$lic,server_id:$sid,monitor:$mon,target:$tar,local_ip:$lip,wan_ip:$wan,ping_status:$ps,http_status:$hs,http_latency_ms:$hl,timestamp:$ts}')

  post "$payload" || echo "$payload" >>"$QUEUE_FILE"
)&
done
wait
flush_queue
EOF

sed -i "s|QUEUE_DIR=.*|QUEUE_DIR=\"$QUEUE_DIR\"|" "$AGENT" 2>/dev/null || true
chmod +x "$AGENT"
}

# -------------------------
# Scheduler
# -------------------------
install_scheduler() {
  if [[ "$OS" == "linux" ]]; then
    write_file /etc/systemd/system/g2agent.timer <<EOF
[Timer]
OnBootSec=30s
OnUnitActiveSec=${MONITOR_INTERVAL_SECONDS}s
Persistent=true
EOF

    write_file /etc/systemd/system/g2agent.service <<EOF
[Service]
Type=oneshot
ExecStart=$AGENT
EOF

    write_file /etc/systemd/system/g2pull.timer <<EOF
[Timer]
OnBootSec=60s
OnUnitActiveSec=${PULL_INTERVAL_SECONDS}s
Persistent=true
EOF

    write_file /etc/systemd/system/g2pull.service <<EOF
[Service]
Type=oneshot
ExecStart=$PULL_AGENT
EOF

    systemctl daemon-reload
    systemctl enable --now g2agent.timer g2pull.timer
  else
    safe_mkdir "$REAL_HOME/Library/LaunchAgents"

    write_file "$REAL_HOME/Library/LaunchAgents/com.gen2.g2agent.plist" <<EOF
<plist><dict>
<key>Label</key><string>com.gen2.g2agent</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$AGENT</string></array>
<key>StartInterval</key><integer>${MONITOR_INTERVAL_SECONDS}</integer>
<key>RunAtLoad</key><true/>
</dict></plist>
EOF

    write_file "$REAL_HOME/Library/LaunchAgents/com.gen2.g2pull.plist" <<EOF
<plist><dict>
<key>Label</key><string>com.gen2.g2pull</string>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>$PULL_AGENT</string></array>
<key>StartInterval</key><integer>${PULL_INTERVAL_SECONDS}</integer>
<key>RunAtLoad</key><true/>
</dict></plist>
EOF

