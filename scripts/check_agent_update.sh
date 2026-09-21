#!/bin/bash

# For logging details
echo "Script started at $(date --iso-8601=ns)"

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(dirname "$0")"

# MQTT Configuration
STATE_TOPIC="rpi/update_status/state"

# Device info for Home Assistant
DEVICE_ID="rpi_homeassistant_host"
DEVICE_NAME="RPi Host System"

# ============================================================================
# Load Credentials
# ============================================================================

CREDENTIALS_FILE="$SCRIPT_DIR/.mqtt_credentials"

if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "ERROR: MQTT credentials file not found at $CREDENTIALS_FILE" >&2
    echo "Please create it from .mqtt_credentials.example" >&2
    exit 1
fi

# Check file permissions (should be 600)
PERMS=$(stat -c %a "$CREDENTIALS_FILE")
if [[ "$PERMS" != "600" ]]; then
    echo "WARNING: Insecure permissions on $CREDENTIALS_FILE (found: $PERMS, expected: 600)" >&2
fi

source "$CREDENTIALS_FILE"

# Validate required variables
if [[ -z "${MQTT_USER:-}" ]] || [[ -z "${MQTT_PASSWORD:-}" ]] || [[ -z "${MQTT_HOST:-}" ]] || [[ -z "${MQTT_PORT:-}" ]]; then
    echo "ERROR: MQTT_USER, MQTT_PASSWORD, MQTT_HOST or MQTT_PORT not set in $CREDENTIALS_FILE" >&2
    exit 1
fi

# ============================================================================
# Helper Functions
# ============================================================================

# Send MQTT Discovery messages (idempotent, uses retain flag)
send_discovery() {
    echo "Sending MQTT Discovery messages..."

    # Sensor 1: System Updates (number of available updates)
    local discovery_updates=$(cat <<EOF
{
  "name": "System Updates",
  "object_id": "rpi_system_updates",
  "unique_id": "rpi_system_updates",
  "state_topic": "$STATE_TOPIC",
  "value_template": "{{ value_json.system_updates }}",
  "unit_of_measurement": "updates",
  "icon": "mdi:package-up",
  "device": {
    "identifiers": ["$DEVICE_ID"],
    "name": "$DEVICE_NAME",
    "model": "Raspberry Pi",
    "manufacturer": "Raspberry Pi Foundation"
  }
}
EOF
)
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "homeassistant/sensor/rpi_system_updates/config" \
        -m "$discovery_updates" -r

    # Sensor 2: EEPROM Status
    local discovery_eeprom=$(cat <<EOF
{
  "name": "EEPROM Status",
  "object_id": "rpi_eeprom_status",
  "unique_id": "rpi_eeprom_status",
  "state_topic": "$STATE_TOPIC",
  "value_template": "{{ value_json.eeprom_status }}",
  "icon": "mdi:chip",
  "device": {
    "identifiers": ["$DEVICE_ID"],
    "name": "$DEVICE_NAME",
    "model": "Raspberry Pi",
    "manufacturer": "Raspberry Pi Foundation"
  }
}
EOF
)
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "homeassistant/sensor/rpi_eeprom_status/config" \
        -m "$discovery_eeprom" -r

    echo "MQTT Discovery messages sent"
}

# Send state update
send_state() {
    local payload="$1"
    echo "Sending state: $payload"
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "$STATE_TOPIC" \
        -m "$payload"
}

# ============================================================================
# Main Process
# ============================================================================

# Send MQTT Discovery (idempotent, safe to run every time)
send_discovery

# 1. Count available system updates
echo "Checking for system updates..."
UPDATES=$(sudo /usr/bin/apt update 2>/dev/null | /usr/bin/grep "can be upgraded" | /usr/bin/awk '{print $1}')
if [[ -z "$UPDATES" ]]; then
    UPDATES=0
fi
echo "Available updates: $UPDATES"

# 2. Check EEPROM status
echo "Checking EEPROM status..."
EEPROM_STATUS=$(sudo /usr/bin/rpi-eeprom-update | /usr/bin/grep "BOOTLOADER:" | /usr/bin/awk '{print $2,$3,$4}')
if [[ -z "$EEPROM_STATUS" ]]; then
    EEPROM_STATUS="unknown"
fi
echo "EEPROM status: $EEPROM_STATUS"

# 3. Create and send payload
PAYLOAD=$(cat <<EOF
{
  "system_updates": $UPDATES,
  "eeprom_status": "$EEPROM_STATUS",
  "last_check": "$(date --iso-8601=seconds)"
}
EOF
)

send_state "$PAYLOAD"

echo "Script completed at $(date --iso-8601=ns)"
