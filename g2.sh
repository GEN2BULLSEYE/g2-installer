#!/bin/bash

# --- 1. Global Setup ---
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS_TYPE="macos"
    INSTALL_DIR="$HOME/.g2serve"
    # Ensure standard user owns the directory
    if [ -d "$INSTALL_DIR" ] && [ "$(stat -f '%u' "$INSTALL_DIR")" -eq 0 ]; then
        echo "Repairing directory permissions..."
        sudo chown -R $(whoami) "$INSTALL_DIR"
    fi
else
    OS_TYPE="linux"
    INSTALL_DIR="/opt/g2serve"
fi

AGENT_PATH="$INSTALL_DIR/g2agent.sh"
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
# Ensure Homebrew and System paths are available to Cron
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

source "$(dirname "$0")/agent.env"

# Network Discovery
if [[ "$OSTYPE" == "darwin"* ]]; then
    LOCAL_IP=$(ipconfig getifaddr $(route get default | grep interface | awk '{print $2}'))
else
    LOCAL_IP=$(hostname -I | awk '{print $1}')
fi
WAN_IP=$(curl -s https://ifconfig.me)

process_target() {
    local entry=$1
    NAME=$(echo "${entry%%|*}" | xargs)
    TARGET=$(echo "${entry#*|}" | xargs)

    # Ping Logic (macOS vs Linux)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # Mac Summary: round-trip min/avg/max/stddev = 10.1/12.4/15.2/2.1 ms
        PING_RESULT=$(ping -c 3 -t 2 "$TARGET" 2>/dev/null)
        PING_LATENCY=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $5}' | tr -dc '0-9.')
    else
        PING_RESULT=$(ping -c 3 -W 2 "$TARGET" 2>/dev/null)
        PING_LATENCY=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $5}' | tr -dc '0-9.')
    fi

    PING_STATUS=$([[ -z "$PING_LATENCY" || "$PING_LATENCY" == "0" ]] && echo "down" || echo "up")

    # HTTP Logic
    if [[ "$TARGET" == http* ]]; then
        HTTP_RESULT=$(httping -G -g "$TARGET" -c 3 -t 3 2>/dev/null)
        HTTP_LATENCY=$(echo "$HTTP_RESULT" | grep "avg" | awk -F'/' '{print $5}' | tr -dc '0-9.')
        HTTP_STATUS=$([[ -z "$HTTP_LATENCY" || "$HTTP_LATENCY" == "0" ]] && echo "down" || echo "up")
    else
        HTTP_STATUS="n/a"; HTTP_LATENCY=0
    fi

    # JSON Payload
    PAYLOAD=$(jq -n \
      --arg oid "$ORG_ID" --arg lkey "$LICENSE_KEY" --arg sid "$SERVER_ID" \
      --arg lip "$LOCAL_IP" --arg wip "$WAN_IP" --arg mon "$NAME" \
      --arg tar "$TARGET" --arg p_sta "$PING_STATUS" --argjson p_lat "${PING_LATENCY:-0}" \
      --arg h_sta "$HTTP_STATUS" --argjson h_lat "${HTTP_LATENCY:-0}" \
      --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{org_id: $oid, license_key: $lkey, server_id: $sid, local_ip: $lip, wan_ip: $wip, monitor: $mon, target: $tar, ping_status: $p_sta, ping_latency_ms: $p_lat, http_status: $h_sta, http_latency_ms: $h_lat, timestamp: $ts}')

    curl -X POST "$N8N_WEBHOOK_URL" -H "Content-Type: application/json" -d "$PAYLOAD" -s -o /dev/null
}

for entry in "${TARGETS[@]}"; do
    process_target "$entry" &
done
wait
EOF
    chmod +x "$AGENT_PATH"
}

# --- 4. Configuration Manager ---
save_config() {
    {
        echo "ORG_ID=\"$ORG_ID\""
        echo "LICENSE_KEY=\"$LICENSE_KEY\""
        echo "SERVER_ID=\"$SERVER_ID\""
        echo "N8N_WEBHOOK_URL=\"$FIXED_WEBHOOK_URL\""
        declare -p TARGETS
    } > "$CONFIG_FILE"
}

# --- 5. Main Control Loop ---
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "--- GEN2 Management (macOS Ready) ---"
    echo "1) Manage Monitors"
    echo "2) Change Org/License"
    echo "3) Uninstall GEN2"
    echo "4) Exit"
    read -p "Select: " opt
    case $opt in
        1) 
           echo "Current: ${TARGETS[@]}"
           read -p "Add new? (name|url): " nt && TARGETS+=("$nt") && save_config && echo "Added." ;;
        2) read -p "New Org: " ORG_ID; read -p "New Key: " LICENSE_KEY; save_config ;;
        3) (crontab -l 2>/dev/null | grep -v "g2agent.sh") | crontab - && rm -rf "$INSTALL_DIR" && echo "Removed." ;;
        *) exit 0 ;;
    esac
else
    # First Time Setup
    install_dependencies
    read -p "Org ID: " ORG_ID
    read -p "License: " LICENSE_KEY
    read -p "Server ID: " SERVER_ID
    TARGETS=()
    read -p "First Monitor (Name | Target): " fm && TARGETS+=("$fm")
    save_config
    write_agent_script
    (crontab -l 2>/dev/null | grep -v "g2agent.sh"; echo "* * * * * $AGENT_PATH > /dev/null 2>&1") | crontab -
    echo "Installation Complete! Status should be UP within 1 minute."
fi
