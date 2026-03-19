#!/bin/bash

# --- 1. Global Setup ---
INSTALL_DIR="/opt/g2serve"
AGENT_PATH="$INSTALL_DIR/g2agent.sh"

# Ensure script is run as root
if [[ $EUID -ne 0 ]]; then
   echo "Error: This script must be run as root (use sudo)."
   exit 1
fi

# --- 2. Installation Logic ---
install_agent() {
    echo "--- Starting G2 Monitor Agent Installation ---"
    
    # Install Dependencies
    echo "Installing dependencies (jq, curl, httping)..."
    apt-get update -y && apt-get install -y jq curl httping iputils-ping

    # Gather User Configuration
    read -p "Enter Organization ID: " USER_ORG_ID
    read -p "Enter License Key: " USER_LKEY
    read -p "Enter Server ID (e.g., G2MON): " USER_SID
    read -p "Enter Webhook URL: " USER_URL

    # Interactive Target Loop
    TARGETS_STRING=""
    while true; do
        read -p "Add a monitor? (y/n): " confirm
        [[ "$confirm" != "y" ]] && break
        
        read -p "  Monitor Name (e.g., Google): " m_name
        read -p "  Target (URL or IP): " m_target
        
        TARGETS_STRING+=$'\n    '
        TARGETS_STRING+="\"$m_name | $m_target\""
    done

    # Create Directory
    mkdir -p "$INSTALL_DIR"

    # Generate the g2agent.sh file
    cat << EOF > "$AGENT_PATH"
#!/bin/bash
# --- Generated Configuration ---
ORG_ID="$USER_ORG_ID"
LICENSE_KEY="$USER_LKEY"
SERVER_ID="$USER_SID"
N8N_WEBHOOK_URL="$USER_URL"

TARGETS=( $TARGETS_STRING 
)

# --- Runtime Logic ---
LOCAL_IP=\$(hostname -I | awk '{print \$1}')
WAN_IP=\$(curl -s https://ifconfig.me)

if command -v nmcli >/dev/null 2>&1; then
    WIFI_SSID=\$(nmcli -t -f active,ssid dev wifi | grep '^yes' | cut -d: -f2)
elif command -v iwgetid >/dev/null 2>&1; then
    WIFI_SSID=\$(iwgetid -r)
else
    WIFI_SSID="N/A"
fi

process_target() {
    local entry=\$1
    MONITOR_NAME=\$(echo "\${entry%%|*}" | xargs)
    TARGET=\$(echo "\${entry#*|}" | xargs)

    PING_RESULT=\$(ping -c 3 -W 2 "\$TARGET" 2>/dev/null)
    if [ \$? -eq 0 ]; then
        PING_STATUS="up"
        PING_LATENCY=\$(echo "\$PING_RESULT" | tail -1 | awk -F'/' '{print \$5}')
    else
        PING_STATUS="down"
        PING_LATENCY=0
    fi

    if [[ "\$TARGET" == http* ]]; then
        HTTP_RESULT=\$(httping -G -g "\$TARGET" -c 3 -t 3 2>/dev/null)
        HTTP_LATENCY=\$(echo "\$HTTP_RESULT" | grep "avg" | awk -F'/' '{print \$5}' | tr -dc '0-9.')
        HTTP_STATUS=\$([[ -z "\$HTTP_LATENCY" ]] && echo "down" || echo "up")
        [[ -z "\$HTTP_LATENCY" ]] && HTTP_LATENCY=0
    else
        HTTP_STATUS="n/a"
        HTTP_LATENCY=0
    fi

    PAYLOAD=\$(jq -n \\
      --arg oid "\$ORG_ID" \\
      --arg lkey "\$LICENSE_KEY" \\
      --arg sid "\$SERVER_ID" \\
      --arg lip "\$LOCAL_IP" \\
      --arg wip "\$WAN_IP" \\
      --arg ssid "\$WIFI_SSID" \\
      --arg mon "\$MONITOR_NAME" \\
      --arg tar "\$TARGET" \\
      --arg p_sta "\$PING_STATUS" \\
      --argjson p_lat "\${PING_LATENCY:-0}" \\
      --arg h_sta "\$HTTP_STATUS" \\
      --argjson h_lat "\${HTTP_LATENCY:-0}" \\
      --arg ts "\$(date -u +%Y-%m-%dT%H:%M:%SZ)" \\
      '{
        org_id: \$oid,
        license_key: \$lkey,
        server_id: \$sid,
        local_ip: \$lip,
        wan_ip: \$wip,
        wifi_ssid: \$ssid,
        monitor: \$mon,
        target: \$tar,
        ping_status: \$p_sta,
        ping_latency_ms: \$p_lat,
        http_status: \$h_sta,
        http_latency_ms: \$h_lat,
        timestamp: \$ts
      }')

    curl -X POST "\$N8N_WEBHOOK_URL" \\
         -H "Content-Type: application/json" \\
         -d "\$PAYLOAD" \\
         --connect-timeout 5 \\
         --max-time 10 \\
         -s -o /dev/null
}

for entry in "\${TARGETS[@]}"; do
    process_target "\$entry" & 
done
wait
EOF

    # Finalize Permissions and Cron
    chmod +x "$AGENT_PATH"
    CRON_JOB="* * * * * $AGENT_PATH > /dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "$AGENT_PATH"; echo "$CRON_JOB") | crontab -

    echo "--- Installation Complete ---"
    echo "Agent located at: $AGENT_PATH"
}

# --- 3. Uninstallation Logic ---
uninstall_agent() {
    echo "--- Starting G2 Monitor Agent Uninstallation ---"
    
    # Remove Cron
    echo "Removing cron job..."
    (crontab -l 2>/dev/null | grep -v "$AGENT_PATH") | crontab -

    # Remove Files
    if [ -d "$INSTALL_DIR" ]; then
        echo "Deleting $INSTALL_DIR..."
        rm -rf "$INSTALL_DIR"
    fi

    echo "--- Uninstallation Complete ---"
}

# --- 4. Main Menu ---
case "$1" in
    install)
        install_agent
        ;;
    uninstall)
        uninstall_agent
        ;;
    *)
        echo "Usage: sudo $0 {install|uninstall}"
        exit 1
        ;;
esac
