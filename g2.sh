#!/bin/bash

# --- 1. Global Setup & Permission Guard ---
OS_TYPE="unknown"
if [[ "$OSTYPE" == "darwin"* ]]; then
    OS_TYPE="macos"
    INSTALL_DIR="$HOME/.g2serve"
    # MAC SAFETY: Homebrew refuses to run as root. 
    if [[ $EUID -eq 0 ]]; then
       echo "--------------------------------------------------------"
       echo "ERROR: Do NOT run this script with 'sudo' on macOS."
       echo "Homebrew (required for jq/httping) forbids root access."
       echo "Please run as: bash $0 install"
       echo "--------------------------------------------------------"
       exit 1
    fi
elif [ -f /etc/debian_version ]; then
    OS_TYPE="debian"
    INSTALL_DIR="/opt/g2serve"
elif [ -f /etc/redhat-release ]; then
    OS_TYPE="redhat"
    INSTALL_DIR="/opt/g2serve"
fi

AGENT_PATH="$INSTALL_DIR/g2agent.sh"
CONFIG_FILE="$INSTALL_DIR/agent.env"
FIXED_WEBHOOK_URL="https://nscl.tailc52c94.ts.net/webhook/ps2"

# --- 2. Dependency Management ---
install_dependencies() {
    echo "--- Installing Dependencies for $OS_TYPE ---"
    case $OS_TYPE in
        "macos")
            if ! command -v brew >/dev/null 2>&1; then
                echo "Homebrew not found. Please install it first at https://brew.sh"
                exit 1
            fi
            brew install jq curl httping
            ;;
        "debian")
            sudo apt-get update -y && sudo apt-get install -y jq curl httping iputils-ping
            ;;
        "redhat")
            sudo dnf install -y jq curl httping iputils-ping || sudo yum install -y jq curl httping
            ;;
    esac
}

# --- 3. Script Generator ---
write_agent_script() {
    # Ensure directory exists
    if [[ "$OS_TYPE" == "macos" ]]; then
        mkdir -p "$INSTALL_DIR"
    else
        sudo mkdir -p "$INSTALL_DIR"
        sudo chown $USER "$INSTALL_DIR"
    fi

    cat << 'EOF' > "$AGENT_PATH"
#!/bin/bash
source "$(dirname "$0")/agent.env"

# Cross-platform Local IP
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

    # Ping syntax varies by OS
    if [[ "$OSTYPE" == "darwin"* ]]; then
        PING_RESULT=$(ping -c 3 -t 2 "$TARGET" 2>/dev/null)
    else
        PING_RESULT=$(ping -c 3 -W 2 "$TARGET" 2>/dev/null)
    fi

    if [ $? -eq 0 ]; then
        PING_STATUS="up"
        PING_LATENCY=$(echo "$PING_RESULT" | tail -1 | awk -F'/' '{print $5}')
    else
        PING_STATUS="down"
        PING_LATENCY=0
    fi

    if [[ "$TARGET" == http* ]]; then
        HTTP_RESULT=$(httping -G -g "$TARGET" -c 3 -t 3 2>/dev/null)
        HTTP_LATENCY=$(echo "$HTTP_RESULT" | grep "avg" | awk -F'/' '{print $5}' | tr -dc '0-9.')
        HTTP_STATUS=$([[ -z "$HTTP_LATENCY" ]] && echo "down" || echo "up")
        [[ -z "$HTTP_LATENCY" ]] && HTTP_LATENCY=0
    else
        HTTP_STATUS="n/a"; HTTP_LATENCY=0
    fi

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

save_config() {
    {
        echo "ORG_ID=\"$ORG_ID\""
        echo "LICENSE_KEY=\"$LICENSE_KEY\""
        echo "SERVER_ID=\"$SERVER_ID\""
        echo "N8N_WEBHOOK_URL=\"$FIXED_WEBHOOK_URL\""
        declare -p TARGETS
    } > "$CONFIG_FILE"
}

# --- 4. Management Console ---
manage_monitors() {
    source "$CONFIG_FILE"
    while true; do
        echo -e "\n--- Monitor List ---"
        for i in "${!TARGETS[@]}"; do echo "$((i+1))) ${TARGETS[$i]}"; done
        echo "--------------------"
        echo "1) Add Monitor"
        echo "2) Remove Monitor"
        echo "3) Back"
        read -p "Select: " m_opt
        case $m_opt in
            1) read -p "Name: " n; read -p "Target: " t; TARGETS+=("$n | $t"); save_config ;;
            2) read -p "ID: " r; idx=$((r-1)); unset 'TARGETS[$idx]'; TARGETS=("${TARGETS[@]}"); save_config ;;
            3) break ;;
        esac
    done
}

uninstall_gen2() {
    echo "Removing GEN2 components..."
    (crontab -l 2>/dev/null | grep -v "g2agent.sh") | crontab -
    rm -rf "$INSTALL_DIR"
    echo "GEN2 Uninstalled."
    exit 0
}

# --- 5. Main Loop ---
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "--- GEN2 Management ---"
    echo "1) Manage Monitors"
    echo "2) Change Organization ID"
    echo "3) Change License Key"
    echo "4) Uninstall GEN2"
    echo "5) Exit"
    read -p "Option: " choice
    case $choice in
        1) manage_monitors ;;
        2) read -p "New Org: " ORG_ID; save_config ;;
        3) read -p "New Key: " LICENSE_KEY; save_config ;;
        4) uninstall_gen2 ;;
        *) exit 0 ;;
    esac
else
    # First Time Setup
    install_dependencies
    mkdir -p "$INSTALL_DIR"
    read -p "Org ID: " ORG_ID
    read -p "License: " LICENSE_KEY
    read -p "Server ID: " SERVER_ID
    TARGETS=()
    read -p "Add first target? (y/n): " ymon
    if [[ "$ymon" == "y" ]]; then
        read -p "Name: " n; read -p "Target: " t; TARGETS+=("$n | $t")
    fi
    save_config
    write_agent_script
    
    # Set Cron
    CRON_JOB="* * * * * $AGENT_PATH > /dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "g2agent.sh"; echo "$CRON_JOB") | crontab -
    echo "Installation Successful!"
fi
