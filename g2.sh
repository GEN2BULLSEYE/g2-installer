#!/bin/bash

GEN2_API_BASE_URL="https://gen2bullseye.com"
PULL_AGENT_URL="https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/main/pull-agent.sh"

# --- 1. Global Setup ---
if [[ "$OSTYPE" == "darwin"* ]]; then
  OS_TYPE="macos"
  INSTALL_DIR="$HOME/.g2serve"
  if [ -d "$INSTALL_DIR" ] && [ "$(stat -f '%u' "$INSTALL_DIR")" -eq 0 ]; then
    sudo chown -R $(whoami) "$INSTALL_DIR"
  fi
else
  OS_TYPE="linux"
  INSTALL_DIR="/opt/g2serve"
fi

AGENT_PATH="$INSTALL_DIR/g2agent.sh"
PULL_AGENT_PATH="$INSTALL_DIR/pull-agent.sh"
CONFIG_FILE="$INSTALL_DIR/agent.env"
FIXED_WEBHOOK_URL="https://nscl.tailc52c94.ts.net/webhook/ps2"

# --- 2. Dependency Installer ---
install_dependencies() {
  echo "Checking dependencies for $OS_TYPE..."
  if [[ "$OS_TYPE" == "macos" ]]; then
    if ! command -v brew >/dev/null 2>&1; then
      echo "Error: Homebrew not found. Install it at https://brew.sh"
      exit 1
    fi
    brew install jq curl httping
  else
    sudo apt-get update -y && sudo apt-get install -y jq curl httping iputils-ping || \
    sudo dnf install -y jq curl httping iputils-ping
  fi
}

# --- 3. The Core Monitoring Agent (The Worker) ---
write_agent_script() {
  mkdir -p "$INSTALL_DIR"
  cat << 'EOF' > "$AGENT_PATH"
#!/bin/bash
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
source "$(dirname "$0")/agent.env"

# Network Discovery
if [[ "$OSTYPE" == "darwin"* ]]; then
  LOCAL_IP=$(ipconfig getifaddr $(route get default | grep interface | awk '{print $2}'))
  WIFI_SSID=$(networksetup -getairportnetwork en0 | cut -d ":" -f 2- | sed 's/^ //')
  [[ "$WIFI_SSID" == *"Error"* ]] && WIFI_SSID="N/A"
else
  LOCAL_IP=$(hostname -I | awk '{print $1}')
  if command -v nmcli >/dev/null 2>&1; then
    WIFI_SSID=$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2)
  else
    WIFI_SSID="N/A"
  fi
fi
WAN_IP=$(curl -s https://ifconfig.me)

process_target() {
  local entry=$1
  NAME=$(echo "${entry%%|*}" | xargs)
  TARGET=$(echo "${entry#*|}" | xargs)

  if [[ "$OSTYPE" == "darwin"* ]]; then
    PING_RESULT=$(ping -c 3 -t 2 "$TARGET" 2>/dev/null)
    PING_LATENCY=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $5}' | tr -dc '0-9.')
  else
    PING_RESULT=$(ping -c 3 -W 2 "$TARGET" 2>/dev/null)
    PING_LATENCY=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $5}' | tr -dc '0-9.')
  fi

  PING_STATUS=$([[ -z "$PING_LATENCY" || "$PING_LATENCY" == "0" ]] && echo "down" || echo "up")

  if [[ "$TARGET" == http* ]]; then
    HTTP_RESULT=$(httping -G -g "$TARGET" -c 3 -t 3 2>/dev/null)
    HTTP_LATENCY=$(echo "$HTTP_RESULT" | grep "avg" | awk -F'/' '{print $5}' | tr -dc '0-9.')
    HTTP_STATUS=$([[ -z "$HTTP_LATENCY" || "$HTTP_LATENCY" == "0" ]] && echo "down" || echo "up")
  else
    HTTP_STATUS="n/a"; HTTP_LATENCY=0
  fi

  PAYLOAD=$(jq -n \
    --arg oid "$ORG_ID" --arg lkey "$LICENSE_KEY" --arg sid "$SERVER_ID" \
    --arg lip "$LOCAL_IP" --arg wip "$WAN_IP" --arg ssid "$WIFI_SSID" \
    --arg mon "$NAME" --arg tar "$TARGET" --arg p_sta "$PING_STATUS" \
    --argjson p_lat "${PING_LATENCY:-0}" --arg h_sta "$HTTP_STATUS" \
    --argjson h_lat "${HTTP_LATENCY:-0}" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{org_id: $oid, license_key: $lkey, server_id: $sid, local_ip: $lip, wan_ip: $wip, wifi_ssid: $ssid, monitor: $mon, target: $tar, ping_status: $p_sta, ping_latency_ms: $p_lat, http_status: $h_sta, http_latency_ms: $h_lat, timestamp: $ts}')

  curl -X POST "$N8N_WEBHOOK_URL" -H "Content-Type: application/json" -d "$PAYLOAD" -s -o /dev/null
}

for entry in "${TARGETS[@]}"; do
  process_target "$entry" &
done
wait
EOF
  chmod +x "$AGENT_PATH"
}

save_config() {
  {
    echo "ORG_ID=\"$ORG_ID\""
    echo "LICENSE_KEY=\"$LICENSE_KEY\""
    echo "SERVER_ID=\"$SERVER_ID\""
    echo "N8N_WEBHOOK_URL=\"$FIXED_WEBHOOK_URL\""
    declare -p TARGETS
  } > "$CONFIG_FILE"
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

# Dispatch a job to GEN2 via device-facing API (no admin session required)
dispatch_remote_job() {
  local action="$1" name="$2" target="$3"
  RESP=$(curl -s -w "\n%{http_code}" -X POST \
    "${GEN2_API_BASE_URL}/api/groundprobe/dispatch?license_key=${LICENSE_KEY}&org_id=${ORG_ID}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg a "$action" --arg n "$name" --arg t "$target" '{action:$a,monitor_name:$n,target:$t}')")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | head -n -1)
  if [ "$HTTP_CODE" = "200" ]; then
    echo "Job dispatched successfully. The pull agent will apply this within 5 minutes."
  else
    echo "API error (HTTP $HTTP_CODE): $BODY"
    echo "Tip: Check your License Key and Org ID in $CONFIG_FILE"
  fi
}

# View remote jobs (non-mutating — does NOT mark jobs as delivered)
# Shows pending/delivered jobs first, then completed
view_remote_jobs() {
  echo ""
  echo "Fetching pending jobs from GEN2..."
  RESP=$(curl -s -w "\n%{http_code}" \
    "${GEN2_API_BASE_URL}/api/groundprobe/jobs/status?license_key=${LICENSE_KEY}&org_id=${ORG_ID}")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | head -n -1)

  if [ "$HTTP_CODE" != "200" ]; then
    echo "Could not reach GEN2 (HTTP $HTTP_CODE). Check your network connection."
    return
  fi

  COUNT=$(echo "$BODY" | jq 'length' 2>/dev/null)
  if [ -z "$COUNT" ] || [ "$COUNT" = "0" ]; then
    echo "No jobs found. Dispatch monitors from your dashboard at ${GEN2_API_BASE_URL}"
    return
  fi

  # Show pending/delivered first
  PENDING_COUNT=$(echo "$BODY" | jq '[.[] | select(.status == "pending" or .status == "delivered")] | length')
  COMPLETED_COUNT=$(echo "$BODY" | jq '[.[] | select(.status == "completed")] | length')

  echo "--- Remote Jobs: $PENDING_COUNT pending/in-progress, $COMPLETED_COUNT completed ---"
  # Pending/delivered first
  for i in $(seq 0 $((COUNT - 1))); do
    STATUS=$(echo "$BODY" | jq -r ".[$i].status")
    [[ "$STATUS" == "completed" ]] && continue
    ACTION=$(echo "$BODY" | jq -r ".[$i].action")
    NAME=$(echo "$BODY" | jq -r ".[$i].monitor_name")
    TARGET=$(echo "$BODY" | jq -r ".[$i].target")
    CREATED=$(echo "$BODY" | jq -r ".[$i].created_at")
    echo "  [$STATUS] [$ACTION] $NAME -> $TARGET  (created: $CREATED)"
  done
  if [ "$COMPLETED_COUNT" -gt 0 ]; then
    echo "  ... $COMPLETED_COUNT completed job(s) (see dashboard for full history)"
  fi
}

# --- 4. Main Menu Logic ---
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
  PULL_ACTIVE=$([[ -f "$PULL_AGENT_PATH" ]] && echo "yes" || echo "no")

  echo "--- GEN2 Management Console ---"
  if [[ "$PULL_ACTIVE" == "yes" ]]; then
    echo "Remote Management: enabled (syncs every 5 min from ${GEN2_API_BASE_URL})"
  else
    echo "Remote Management: not installed (re-run installer to enable)"
  fi
  echo ""
  echo "1) Manage Monitors"
  echo "2) Change Credentials"
  echo "3) Uninstall GEN2"
  echo "4) Exit"
  read -p "Select: " choice
  case $choice in
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
        read -p "Selection: " m_opt
        if [[ "$m_opt" == "1" ]]; then
          read -p "  Monitor Name: " m_name
          read -p "  Target (URL/IP): " m_target
          dispatch_remote_job "add" "$m_name" "$m_target"
        elif [[ "$m_opt" == "2" ]]; then
          read -p "  Monitor Name to remove: " m_name
          read -p "  Target to remove: " m_target
          dispatch_remote_job "remove" "$m_name" "$m_target"
        elif [[ "$m_opt" == "3" ]]; then
          view_remote_jobs
        else
          break
        fi
      done
      ;;
    2) read -p "New Org ID: " ORG_ID; read -p "New License: " LICENSE_KEY; save_config ;;
    3)
      (crontab -l 2>/dev/null | grep -v "g2agent.sh" | grep -v "pull-agent.sh") | crontab -
      rm -rf "$INSTALL_DIR"
      echo "Uninstalled."
      ;;
    *) exit 0 ;;
  esac
else
  # Fresh Installation
  install_dependencies
  mkdir -p "$INSTALL_DIR"
  read -p "Organization ID: " ORG_ID
  read -p "License Key: " LICENSE_KEY
  read -p "Server ID: " SERVER_ID

  TARGETS=()
  while true; do
    echo -e "\n--- Add a Monitor ---"
    read -p "  Monitor Name (e.g., Google): " m_name
    read -p "  Target (URL or IP): " m_target
    TARGETS+=("$m_name | $m_target")

    read -p "Add another monitor? (y/n): " confirm
    [[ "$confirm" != "y" ]] && break
  done

  save_config
  write_agent_script

  # Register monitoring cron (every minute)
  (crontab -l 2>/dev/null | grep -v "g2agent.sh"; echo "* * * * * $AGENT_PATH > /dev/null 2>&1") | crontab -

  # Always install pull agent for remote management
  install_pull_agent

  echo ""
  echo "Installation Complete!"
  echo "Your probe is connected. Dispatch monitors remotely from:"
  echo "  ${GEN2_API_BASE_URL} → Ground Probe Onboarding → Dispatch"
fi
