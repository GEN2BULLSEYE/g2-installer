#!/bin/bash

# --- 1. Global Setup ---
INSTALL_DIR="/opt/g2serve"
[[ "$OSTYPE" == "darwin"* ]] && INSTALL_DIR="$HOME/.g2serve"
AGENT_PATH="$INSTALL_DIR/g2agent.sh"
CONFIG_FILE="$INSTALL_DIR/agent.env" # Store variables here for easy management
FIXED_WEBHOOK_URL="https://nscl.tailc52c94.ts.net/webhook/ps2"

# --- 2. Helper Functions ---

# Detect OS and set package manager
get_os() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "macos"
    elif [ -f /etc/debian_version ]; then
        echo "debian"
    elif [ -f /etc/redhat-release ]; then
        echo "redhat"
    else
        echo "unknown"
    fi
}

install_dependencies() {
    OS_TYPE=$(get_os)
    echo "Installing dependencies for $OS_TYPE..."
    case $OS_TYPE in
        "debian") apt-get update -y && apt-get install -y jq curl httping iputils-ping ;;
        "redhat") dnf install -y jq curl httping iputils-ping || yum install -y jq curl httping ;;
        "macos") 
            if ! command -v brew >/dev/null 2>&1; then echo "Install Homebrew first: https://brew.sh"; exit 1; fi
            brew install jq curl httping 
            ;;
    esac
}

# This generates the actual worker script
write_agent_script() {
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

    if [[ "$OSTYPE" == "darwin"* ]]; then
        PING_RESULT=$(ping -c 3 -W 2000 "$TARGET" 2>/dev/null)
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

# --- 3. Management Logic ---

manage_monitors() {
    source "$CONFIG_FILE"
    echo -e "\n--- Current Monitors ---"
    for i in "${!TARGETS[@]}"; do
        echo "$((i+1))) ${TARGETS[$i]}"
    done
    echo "------------------------"
    echo "1) Add Monitor"
    echo "2) Remove Monitor"
    echo "3) Back"
    read -p "Selection: " m_opt
    
    case $m_opt in
        1)
            read -p "  Name: " n_mon
            read -p "  Target: " t_mon
            TARGETS+=("$n_mon | $t_mon")
            save_config && echo "Added."
            ;;
        2)
            read -p "  Enter number to remove: " r_idx
            idx=$((r_idx-1))
            if [[ ${TARGETS[$idx]} ]]; then
                unset 'TARGETS[$idx]'
                TARGETS=("${TARGETS[@]}") # Re-index array
                save_config && echo "Removed."
            else
                echo "Invalid index."
            fi
            ;;
    esac
}

uninstall_gen2() {
    echo "Uninstalling GEN2..."
    (crontab -l 2>/dev/null | grep -v "g2agent.sh") | crontab -
    rm -rf "$INSTALL_DIR"
    echo "GEN2 completely removed."
    exit 0
}

# --- 4. Main Menu Logic ---

if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
    echo "--- GEN2 Management Console ---"
    echo "Status: INSTALLED"
    echo "1) Manage Monitors"
    echo "2) Change Organization ID (Current: $ORG_ID)"
    echo "3) Change License Key"
    echo "4) Uninstall GEN2"
    echo "5) Exit"
    read -p "Choose an option: " choice

    case $choice in
        1) manage_monitors ;;
        2) read -p "New Org ID: " ORG_ID; save_config ;;
        3) read -p "New License Key: " LICENSE_KEY; save_config ;;
        4) uninstall_gen2 ;;
        *) exit 0 ;;
    esac
else
    # Fresh Installation
    echo "--- GEN2 Agent Deployment ---"
    install_dependencies
    mkdir -p "$INSTALL_DIR"
    read -p "Organization ID: " ORG_ID
    read -p "License Key: " LICENSE_KEY
    read -p "Server ID: " SERVER_ID
    TARGETS=()
    
    # Initial Monitor
    read -p "Add first monitor? (y/n): " init_m
    if [[ "$init_m" == "y" ]]; then
        read -p "  Name: " n_mon
        read -p "  Target: " t_mon
        TARGETS+=("$n_mon | $t_mon")
    fi

    save_config
    write_agent_script
    
    # Cron setup
    CRON_JOB="* * * * * $AGENT_PATH > /dev/null 2>&1"
    (crontab -l 2>/dev/null | grep -v "g2agent.sh"; echo "$CRON_JOB") | crontab -
    echo "Installation Complete!"
fi
