#!/bin/bash

GEN2_API_BASE_URL="https://gen2bullseye.com"
PULL_AGENT_URL="https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/main/pull-agent.sh"

# --- 1. Global Setup ---
if [[ "$OSTYPE" == "darwin"* ]]; then
  OS_TYPE="macos"
  # Use absolute path to avoid $HOME resolution issues in cron
  CURRENT_USER=$(whoami)
  INSTALL_DIR="/Users/$CURRENT_USER/.g2serve"
  if [ -d "$INSTALL_DIR" ] && [ "$(stat -f '%u' "$INSTALL_DIR")" -eq 0 ]; then
    sudo chown -R "$CURRENT_USER" "$INSTALL_DIR"
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
    brew install jq curl httping speedtest-cli
  else
    sudo apt-get update -y && sudo apt-get install -y jq curl httping iputils-ping speedtest-cli || \
    sudo dnf install -y jq curl httping iputils-ping speedtest-cli
  fi
}

# --- 3. The Core Monitoring Agent ---
write_agent_script() {
  mkdir -p "$INSTALL_DIR"
  cat << EOF > "$AGENT_PATH"
#!/bin/bash
# Hardcoded path for consistency
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:\$PATH"
source "$CONFIG_FILE"

# Network Discovery
if [[ "\$OSTYPE" == "darwin"* ]]; then
  LOCAL_IP=\$(ipconfig getifaddr \$(route get default | grep interface | awk '{print \$2}'))
  WIFI_SSID=\$(networksetup -getairportnetwork en0 | cut -d ":" -f 2- | sed 's/^ //')
  [[ "\$WIFI_SSID" == *"Error"* ]] && WIFI_SSID="N/A"
  ACTIVE_DEVICES=\$(arp -a | grep -v "incomplete" | wc -l | xargs)
else
  LOCAL_IP=\$(hostname -I | awk '{print \$1}')
  if command -v nmcli >/dev/null 2>&1; then
    WIFI_SSID=\$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2)
  else
    WIFI_SSID="N/A"
  fi
  ACTIVE_DEVICES=\$(ip neighbor show | grep -E "REACHABLE|DELAY|STALE" | wc -l | xargs)
fi
WAN_IP=\$(curl -s https://ifconfig.me)

# Throttled Speed Test (Every 15 Minutes)
LAST_TEST_FILE="$INSTALL_DIR/.last_speedtest"
NOW=\$(date +%s)
LAST_TEST=\$(cat "\$LAST_TEST_FILE" 2>/dev/null || echo 0)

if (( NOW - LAST_TEST >= 900 )); then
  SPEED_DATA=\$(speedtest-cli --simple 2>/dev/null)
  DOWNLOAD_SPEED=\$(echo "\$SPEED_DATA" | grep "Download" | awk '{print \$2}')
  UPLOAD_SPEED=\$(echo "\$SPEED_DATA" | grep "Upload" | awk '{print \$2}')
  echo "\$NOW" > "\$LAST_TEST_FILE"
  echo "\${DOWNLOAD_SPEED:-0}" > "$INSTALL_DIR/.last_dl"
  echo "\${UPLOAD_SPEED:-0}" > "$INSTALL_DIR/.last_ul"
else
  DOWNLOAD_SPEED=\$(cat "$INSTALL_DIR/.last_dl" 2>/dev/null || echo "0")
  UPLOAD_SPEED=\$(cat "$INSTALL_DIR/.last_ul" 2>/dev/null || echo "0")
fi

process_target() {
  local entry=\$1
  NAME=\$(echo "\${entry%%|*}" | xargs)
  TARGET=\$(echo "\${entry#*|}" | xargs)

  if [[ "\$OSTYPE" == "darwin"* ]]; then
    PING_RESULT=\$(ping -c 3 -t 2 "\$TARGET" 2>/dev/null)
    PING_LATENCY=\$(echo "\$PING_RESULT" | tail -1 | awk -F'/' '{print \$5}' | tr -dc '0-9.')
  else
    PING_RESULT=\$(ping -c 3 -W 2 "\$TARGET" 2>/dev/null)
    PING_LATENCY=\$(echo "\$PING_RESULT" | tail -1 | awk -F'/' '{print \$5}' | tr -dc '0-9.')
  fi

  PING_STATUS=\$([[ -z "\$PING_LATENCY" || "\$PING_LATENCY" == "0" ]] && echo "down" || echo "up")

  if [[ "\$TARGET" == http* ]]; then
    HTTP_RESULT=\$(httping -G -g "\$TARGET" -c 3 -t 3 2>/dev/null)
    HTTP_LATENCY=\$(echo "\$HTTP_RESULT" | grep "avg" | awk -F'/' '{print \$5}' | tr -dc '0-9.')
    HTTP_STATUS=\$([[ -z "\$HTTP_LATENCY" || "\$HTTP_LATENCY" == "0" ]] && echo "down" || echo "up")
  else
    HTTP_STATUS="n/a"; HTTP_LATENCY=0
  fi

  PAYLOAD=\$(jq -n \\
    --arg oid "\$ORG_ID" --arg lkey "\$LICENSE_KEY" --arg sid "\$SERVER_ID" \\
    --arg lip "\$LOCAL_IP" --arg wip "\$WAN_IP" --arg ssid "\$WIFI_SSID" \\
    --arg mon "\$NAME" --arg tar "\$TARGET" --arg p_sta "\$PING_STATUS" \\
    --argjson p_lat "\${PING_LATENCY:-0}" --arg h_sta "\$HTTP_STATUS" \\
    --argjson h_lat "\${HTTP_LATENCY:-0}" \\
    --argjson active_devs "\${ACTIVE_DEVICES:-0}" \\
    --arg dl "\$DOWNLOAD_SPEED" --arg ul "\$UPLOAD_SPEED" \\
    --arg ts "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \\
    '{org_id: \$oid, license_key: \$lkey, server_id: \$sid, local_ip: \$lip, wan_ip: \$wip, wifi_ssid: \$ssid, monitor: \$mon, target: \$tar, ping_status: \$p_sta, ping_latency_ms: \$p_lat, http_status: \$h_sta, http_latency_ms: \$h_lat, active_devices: \$active_devs, download_mbps: \$dl, upload_mbps: \$ul, timestamp: \$ts}')

  curl -X POST "\$N8N_WEBHOOK_URL" -H "Content-Type: application/json" -d "\$PAYLOAD" -s -o /dev/null
}

for entry in "\${TARGETS[@]}"; do
  process_target "\$entry" &
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
    # Use the absolute path for the crontab to avoid macOS environment issues
    (crontab -l 2>/dev/null | grep -v "pull-agent.sh"; echo "*/5 * * * * /bin/bash $PULL_AGENT_PATH >> $INSTALL_DIR/pull-agent.log 2>&1") | crontab -
    echo "Remote management enabled. Logs: $INSTALL_DIR/pull-agent.log"
  else
    echo "Warning: Could not download pull agent."
  fi
}

dispatch_remote_job() {
  local action="$1" name="$2" target="$3"
  RESP=$(curl -s -w "\n%{http_code}" -X POST \
    "${GEN2_API_BASE_URL}/api/groundprobe/dispatch?license_key=${LICENSE_KEY}&org_id=${ORG_ID}" \
    -H "Content-Type: application/json" \
    -d "$(jq -n --arg a "$action" --arg n "$name" --arg t "$target" '{action:$a,monitor_name:$n,target:$t}')")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | head -n -1)
  if [ "$HTTP_CODE" = "200" ]; then
    echo "Job dispatched successfully. Syncing in ~5 mins."
  else
    echo "API error (HTTP $HTTP_CODE): $BODY"
  fi
}

view_remote_jobs() {
  echo ""
  echo "Fetching pending jobs from GEN2..."
  RESP=$(curl -s -w "\n%{http_code}" \
    "${GEN2_API_BASE_URL}/api/groundprobe/jobs/status?license_key=${LICENSE_KEY}&org_id=${ORG_ID}")
  HTTP_CODE=$(echo "$RESP" | tail -1)
  BODY=$(echo "$RESP" | head -n -1)

  if [ "$HTTP_CODE" != "200" ]; then
    echo "Could not reach GEN2 (HTTP $HTTP_CODE)."
    return
  fi

  COUNT=$(echo "$BODY" | jq 'length' 2>/dev/null)
  if [ -z "$COUNT" ] || [ "$COUNT" = "0" ]; then
    echo "No jobs found."
    return
  fi

  echo "--- Remote Jobs ---"
  for i in $(seq 0 $((COUNT - 1))); do
    STATUS=$(echo "$BODY" | jq -r ".[$i].status")
    [[ "$STATUS" == "completed" ]] && continue
    ACTION=$(echo "$BODY" | jq -r ".[$i].action")
    NAME=$(echo "$BODY" | jq -r ".[$i].monitor_name")
    TARGET=$(echo "$BODY" | jq -r ".[$i].target")
    echo "  [$STATUS] [$ACTION] $NAME -> $TARGET"
  done
}

# --- 4. Main Menu Logic ---
if [ -f "$CONFIG_FILE" ]; then
  source "$CONFIG_FILE"
  echo "--- GEN2 Management Console ---"
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
        echo "1) Add Monitor"
        echo "2) Remove Monitor"
        echo "3) View Remote Job Status"
        echo "4) Back"
        read -p "Selection: " m_opt
        if [[ "$m_opt" == "1" ]]; then
          read -p "  Name: " m_name; read -p "  Target: " m_target; dispatch_remote_job "add" "$m_name" "$m_target"
        elif [[ "$m_opt" == "2" ]]; then
          read -p "  Name: " m_name; read -p "  Target: " m_target; dispatch_remote_job "remove" "$m_name" "$m_target"
        elif [[ "$m_opt" == "3" ]]; then view_remote_jobs
        else break; fi
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
  install_dependencies
  mkdir -p "$INSTALL_DIR"
  read -p "Organization ID: " ORG_ID
  read -p "License Key: " LICENSE_KEY
  read -p "Server ID: " SERVER_ID

  TARGETS=()
  while true; do
    read -p "Monitor Name: " m_name
    read -p "Target (URL or IP): " m_target
    TARGETS+=("$m_name | $m_target")
    read -p "Add another? (y/n): " confirm
    [[ "$confirm" != "y" ]] && break
  done

  save_config
  write_agent_script

  (crontab -l 2>/dev/null | grep -v "g2agent.sh"; echo "*/1 * * * * /bin/bash $AGENT_PATH > /dev/null 2>&1") | crontab -
  install_pull_agent

  echo "Installation Complete! Running every 1 minute."
fi
