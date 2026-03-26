#!/bin/bash
# GEN2 Pull Agent — polls GEN2 for pending monitor jobs and updates agent.env
# Hosted at: https://raw.githubusercontent.com/GEN2BULLSEYE/g2-installer/main/pull-agent.sh
# Runs every 5 minutes via cron (registered by g2.sh during install)

GEN2_API_BASE_URL="https://gen2bullseye.com"

# --- Determine install dir (matches g2.sh) ---
if [[ "$OSTYPE" == "darwin"* ]]; then
  INSTALL_DIR="$HOME/.g2serve"
else
  INSTALL_DIR="/opt/g2serve"
fi

CONFIG_FILE="$INSTALL_DIR/agent.env"
LOG_FILE="$INSTALL_DIR/pull-agent.log"
MAX_LOG_LINES=500

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $1" >> "$LOG_FILE"
  local lines
  lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [ "$lines" -gt "$MAX_LOG_LINES" ]; then
    tail -n "$MAX_LOG_LINES" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
  fi
}

save_config() {
  {
    echo "ORG_ID=\"$ORG_ID\""
    echo "LICENSE_KEY=\"$LICENSE_KEY\""
    echo "SERVER_ID=\"$SERVER_ID\""
    echo "N8N_WEBHOOK_URL=\"$N8N_WEBHOOK_URL\""
    declare -p TARGETS
  } > "$CONFIG_FILE"
}

# --- Validate config ---
if [ ! -f "$CONFIG_FILE" ]; then
  log "ERROR: agent.env not found at $CONFIG_FILE — run g2.sh install first"
  exit 1
fi

source "$CONFIG_FILE"

if [ -z "$LICENSE_KEY" ] || [ -z "$ORG_ID" ]; then
  log "ERROR: LICENSE_KEY or ORG_ID not set in agent.env"
  exit 1
fi

# --- Poll for pending jobs ---
RESPONSE=$(curl -s -w "\n%{http_code}" \
  "${GEN2_API_BASE_URL}/api/groundprobe/jobs?license_key=${LICENSE_KEY}&org_id=${ORG_ID}")
HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" != "200" ]; then
  log "ERROR: Failed to fetch jobs (HTTP $HTTP_CODE): $BODY"
  exit 1
fi

JOB_COUNT=$(echo "$BODY" | jq 'length' 2>/dev/null)
if [ -z "$JOB_COUNT" ] || [ "$JOB_COUNT" = "0" ]; then
  log "INFO: No pending jobs"
  exit 0
fi

log "INFO: Received $JOB_COUNT job(s)"

# --- Process each job ---
for i in $(seq 0 $((JOB_COUNT - 1))); do
  JOB_ID=$(echo "$BODY" | jq -r ".[$i].id")
  ACTION=$(echo "$BODY" | jq -r ".[$i].action")
  MONITOR_NAME=$(echo "$BODY" | jq -r ".[$i].monitor_name")
  TARGET=$(echo "$BODY" | jq -r ".[$i].target")

  log "INFO: Processing job $JOB_ID — action=$ACTION monitor='$MONITOR_NAME' target='$TARGET'"

  # Reload current TARGETS from agent.env in case previous iteration changed it
  source "$CONFIG_FILE"

  if [ "$ACTION" = "add" ]; then
    ENTRY="${MONITOR_NAME} | ${TARGET}"
    ALREADY_EXISTS=0
    for t in "${TARGETS[@]}"; do
      if [ "$t" = "$ENTRY" ]; then
        ALREADY_EXISTS=1
        break
      fi
    done

    if [ "$ALREADY_EXISTS" = "1" ]; then
      log "INFO: Monitor '$MONITOR_NAME' already exists — skipping add"
    else
      TARGETS+=("$ENTRY")
      save_config
      log "INFO: Added monitor '$MONITOR_NAME' -> '$TARGET'"
    fi

  elif [ "$ACTION" = "remove" ]; then
    NEW_TARGETS=()
    FOUND=0
    for t in "${TARGETS[@]}"; do
      ENTRY_NAME=$(echo "${t%%|*}" | xargs)
      if [ "$ENTRY_NAME" = "$MONITOR_NAME" ]; then
        FOUND=1
        log "INFO: Removed monitor '$MONITOR_NAME'"
      else
        NEW_TARGETS+=("$t")
      fi
    done
    if [ "$FOUND" = "0" ]; then
      log "INFO: Monitor '$MONITOR_NAME' not found in TARGETS — nothing to remove"
    fi
    TARGETS=("${NEW_TARGETS[@]}")
    save_config

  else
    log "WARN: Unknown action '$ACTION' for job $JOB_ID — skipping"
  fi

  # --- Acknowledge job ---
  ACK_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
    "${GEN2_API_BASE_URL}/api/groundprobe/jobs/${JOB_ID}/ack?license_key=${LICENSE_KEY}&org_id=${ORG_ID}")
  if [ "$ACK_CODE" = "200" ]; then
    log "INFO: Acknowledged job $JOB_ID"
  else
    log "WARN: Failed to ack job $JOB_ID (HTTP $ACK_CODE)"
  fi
done
