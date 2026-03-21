#!/bin/bash

# k3s Node & Cluster Monitor
# Collects system metrics (CPU, RAM, NVMe, temperatures, fan) and k3s cluster
# status (node health, unhealthy pods, unbound PVCs) and pushes them to Home
# Assistant via MQTT Discovery.
#
# Runs on the k3s Server-Node (k3s.fritz.box).
# Pushes to Mosquitto on raspberrypi.fritz.box.
#
# Setup:
#   1. cp scripts/.mqtt_credentials.example scripts/.mqtt_credentials
#   2. chmod 600 scripts/.mqtt_credentials
#   3. Fill in MQTT_USER and MQTT_PASSWORD
#   4. Add to crontab: */5 * * * * /path/to/scripts/k3s-monitor.sh >> /path/to/logs/k3s-monitor.log 2>&1
#
# Dependencies: mosquitto-clients, kubectl (kubeconfig at ~/.kube/config)

echo "Script started at $(date --iso-8601=ns)"

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

MQTT_HOST="raspberrypi.fritz.box"
MQTT_PORT="1883"
STATE_TOPIC="k3s/monitor/state"

DEVICE_ID="k3s_server_node"
DEVICE_NAME="k3s Server Node"

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# ============================================================================
# Load Credentials
# ============================================================================

CREDENTIALS_FILE="$SCRIPT_DIR/.mqtt_credentials"

if [[ ! -f "$CREDENTIALS_FILE" ]]; then
    echo "ERROR: MQTT credentials file not found at $CREDENTIALS_FILE" >&2
    echo "Please create it from .mqtt_credentials.example" >&2
    exit 1
fi

PERMS=$(stat -c %a "$CREDENTIALS_FILE")
if [[ "$PERMS" != "600" ]]; then
    echo "WARNING: Insecure permissions on $CREDENTIALS_FILE (found: $PERMS, expected: 600)" >&2
fi

source "$CREDENTIALS_FILE"

if [[ -z "${MQTT_USER:-}" ]] || [[ -z "${MQTT_PASSWORD:-}" ]]; then
    echo "ERROR: MQTT_USER or MQTT_PASSWORD not set in $CREDENTIALS_FILE" >&2
    exit 1
fi

# ============================================================================
# Helper Functions
# ============================================================================

mqtt_pub() {
    local topic="$1"
    local payload="$2"
    local retain="${3:-}"
    mosquitto_pub -h "$MQTT_HOST" -p "$MQTT_PORT" \
        -u "$MQTT_USER" -P "$MQTT_PASSWORD" \
        -t "$topic" -m "$payload" ${retain:+-r}
}

# Sensor discovery config — args: object_id, name, unit, icon, [device_class]
send_sensor_discovery() {
    local object_id="$1"
    local name="$2"
    local unit="$3"
    local icon="$4"
    local device_class="${5:-}"

    local device_class_json=""
    if [[ -n "$device_class" ]]; then
        device_class_json=",\"device_class\": \"$device_class\""
    fi

    local payload
    payload=$(cat <<EOF
{
  "name": "$name",
  "object_id": "$object_id",
  "unique_id": "$object_id",
  "state_topic": "$STATE_TOPIC",
  "value_template": "{{ value_json.$object_id }}",
  "unit_of_measurement": "$unit",
  "icon": "$icon"
  $device_class_json,
  "device": {
    "identifiers": ["$DEVICE_ID"],
    "name": "$DEVICE_NAME",
    "model": "Raspberry Pi 5",
    "manufacturer": "Raspberry Pi Ltd"
  }
}
EOF
)
    mqtt_pub "homeassistant/sensor/${object_id}/config" "$payload" retain
}

# Binary sensor discovery — args: object_id, name, icon, device_class
send_binary_discovery() {
    local object_id="$1"
    local name="$2"
    local icon="$3"
    local device_class="${4:-}"

    local device_class_json=""
    if [[ -n "$device_class" ]]; then
        device_class_json=",\"device_class\": \"$device_class\""
    fi

    local payload
    payload=$(cat <<EOF
{
  "name": "$name",
  "object_id": "$object_id",
  "unique_id": "$object_id",
  "state_topic": "$STATE_TOPIC",
  "value_template": "{{ value_json.$object_id }}"
  $device_class_json,
  "payload_on": "ON",
  "payload_off": "OFF",
  "icon": "$icon",
  "device": {
    "identifiers": ["$DEVICE_ID"],
    "name": "$DEVICE_NAME",
    "model": "Raspberry Pi 5",
    "manufacturer": "Raspberry Pi Ltd"
  }
}
EOF
)
    mqtt_pub "homeassistant/binary_sensor/${object_id}/config" "$payload" retain
}

# ============================================================================
# MQTT Discovery (idempotent, uses retain — safe to send every run)
# ============================================================================

send_discovery() {
    echo "Sending MQTT Discovery configs..."

    # Node metrics
    send_sensor_discovery "k3s_cpu_usage"       "CPU Usage"           "%"    "mdi:cpu-64-bit"
    send_sensor_discovery "k3s_ram_usage"        "RAM Usage"           "%"    "mdi:memory"
    send_sensor_discovery "k3s_disk_usage"       "NVMe Usage"          "%"    "mdi:harddisk"
    send_sensor_discovery "k3s_cpu_temp"         "CPU Temperature"     "°C"   "mdi:thermometer"   "temperature"
    send_sensor_discovery "k3s_nvme_temp"        "NVMe Temperature"    "°C"   "mdi:thermometer"   "temperature"
    send_sensor_discovery "k3s_fan_rpm"          "Fan Speed"           "RPM"  "mdi:fan"
    send_sensor_discovery "k3s_fan_pwm"          "Fan PWM"             "%"    "mdi:fan"

    # k3s cluster metrics
    send_sensor_discovery "k3s_unhealthy_pods"   "Unhealthy Pods"      ""     "mdi:kubernetes"
    send_sensor_discovery "k3s_unbound_pvcs"     "Unbound PVCs"        ""     "mdi:database-alert"

    # Binary sensors
    send_binary_discovery "k3s_node_ready"       "k3s Node Ready"      "mdi:kubernetes"        "connectivity"
    send_binary_discovery "k3s_undervoltage"     "k3s Undervoltage"    "mdi:lightning-bolt"    "problem"

    echo "MQTT Discovery configs sent"
}

# ============================================================================
# Metric Collection
# ============================================================================

# CPU usage over 1-second interval (%)
get_cpu_usage() {
    local cpu1
    local cpu2
    cpu1=($(head -1 /proc/stat))
    sleep 1
    cpu2=($(head -1 /proc/stat))

    local total1=0 total2=0
    for v in "${cpu1[@]:1}"; do total1=$((total1 + v)); done
    for v in "${cpu2[@]:1}"; do total2=$((total2 + v)); done

    local idle1=${cpu1[4]}
    local idle2=${cpu2[4]}
    local diff_total=$((total2 - total1))
    local diff_idle=$((idle2 - idle1))

    if [[ $diff_total -eq 0 ]]; then echo 0; return; fi
    echo $(( (diff_total - diff_idle) * 100 / diff_total ))
}

# RAM usage (%)
get_ram_usage() {
    local total used
    total=$(grep MemTotal /proc/meminfo | awk '{print $2}')
    local available
    available=$(grep MemAvailable /proc/meminfo | awk '{print $2}')
    used=$((total - available))
    echo $(( used * 100 / total ))
}

# NVMe disk usage (%)
get_disk_usage() {
    df / | awk 'NR==2 {gsub("%",""); print $5}'
}

# Temperature from hwmon (millidegrees → °C, one decimal)
get_temp() {
    local hwmon_name="$1"
    local hwmon_dir
    hwmon_dir=$(grep -rl "^${hwmon_name}$" /sys/class/hwmon/*/name 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
    if [[ -z "$hwmon_dir" ]] || [[ ! -f "$hwmon_dir/temp1_input" ]]; then
        echo "null"; return
    fi
    local raw
    raw=$(cat "$hwmon_dir/temp1_input")
    # millidegrees to °C with one decimal
    echo $(( raw / 100 ))e-1 | awk '{printf "%.1f", $1}'
}

# Fan RPM
get_fan_rpm() {
    local hwmon_dir
    hwmon_dir=$(grep -rl "^pwmfan$" /sys/class/hwmon/*/name 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
    if [[ -z "$hwmon_dir" ]] || [[ ! -f "$hwmon_dir/fan1_input" ]]; then
        echo "null"; return
    fi
    cat "$hwmon_dir/fan1_input"
}

# Fan PWM as percentage (0–255 → 0–100%)
get_fan_pwm() {
    local hwmon_dir
    hwmon_dir=$(grep -rl "^pwmfan$" /sys/class/hwmon/*/name 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
    if [[ -z "$hwmon_dir" ]] || [[ ! -f "$hwmon_dir/pwm1" ]]; then
        echo "null"; return
    fi
    local raw
    raw=$(cat "$hwmon_dir/pwm1")
    echo $(( raw * 100 / 255 ))
}

# Undervoltage alarm (1 = alarm active)
get_undervoltage() {
    local hwmon_dir
    hwmon_dir=$(grep -rl "^rpi_volt$" /sys/class/hwmon/*/name 2>/dev/null | head -1 | xargs dirname 2>/dev/null)
    if [[ -z "$hwmon_dir" ]] || [[ ! -f "$hwmon_dir/in0_lcrit_alarm" ]]; then
        echo "OFF"; return
    fi
    local val
    val=$(cat "$hwmon_dir/in0_lcrit_alarm")
    [[ "$val" == "1" ]] && echo "ON" || echo "OFF"
}

# k3s node Ready status
get_node_ready() {
    local status
    status=$(KUBECONFIG="$KUBECONFIG" kubectl get nodes \
        --no-headers -o custom-columns="STATUS:.status.conditions[-1].type,READY:.status.conditions[-1].status" \
        2>/dev/null | head -1)
    if echo "$status" | grep -q "Ready.*True"; then
        echo "ON"
    else
        echo "OFF"
    fi
}

# Count pods not in Running/Succeeded/Completed phase
get_unhealthy_pods() {
    KUBECONFIG="$KUBECONFIG" kubectl get pods --all-namespaces --no-headers 2>/dev/null \
        | awk '{print $4}' \
        | grep -vcE "^(Running|Succeeded|Completed)$" \
        || echo "0"
}

# Count PVCs not in Bound state
get_unbound_pvcs() {
    KUBECONFIG="$KUBECONFIG" kubectl get pvc --all-namespaces --no-headers 2>/dev/null \
        | awk '{print $3}' \
        | grep -vc "^Bound$" \
        || echo "0"
}

# ============================================================================
# Main
# ============================================================================

send_discovery

echo "Collecting metrics..."

CPU_USAGE=$(get_cpu_usage)
RAM_USAGE=$(get_ram_usage)
DISK_USAGE=$(get_disk_usage)
CPU_TEMP=$(get_temp "cpu_thermal")
NVME_TEMP=$(get_temp "nvme")
FAN_RPM=$(get_fan_rpm)
FAN_PWM=$(get_fan_pwm)
UNDERVOLTAGE=$(get_undervoltage)
NODE_READY=$(get_node_ready)
UNHEALTHY_PODS=$(get_unhealthy_pods)
UNBOUND_PVCS=$(get_unbound_pvcs)

echo "CPU: ${CPU_USAGE}%, RAM: ${RAM_USAGE}%, Disk: ${DISK_USAGE}%"
echo "CPU temp: ${CPU_TEMP}°C, NVMe temp: ${NVME_TEMP}°C"
echo "Fan: ${FAN_RPM} RPM (${FAN_PWM}%)"
echo "Node ready: ${NODE_READY}, Unhealthy pods: ${UNHEALTHY_PODS}, Unbound PVCs: ${UNBOUND_PVCS}"
echo "Undervoltage: ${UNDERVOLTAGE}"

PAYLOAD=$(cat <<EOF
{
  "k3s_cpu_usage": $CPU_USAGE,
  "k3s_ram_usage": $RAM_USAGE,
  "k3s_disk_usage": $DISK_USAGE,
  "k3s_cpu_temp": $CPU_TEMP,
  "k3s_nvme_temp": $NVME_TEMP,
  "k3s_fan_rpm": $FAN_RPM,
  "k3s_fan_pwm": $FAN_PWM,
  "k3s_undervoltage": "$UNDERVOLTAGE",
  "k3s_node_ready": "$NODE_READY",
  "k3s_unhealthy_pods": $UNHEALTHY_PODS,
  "k3s_unbound_pvcs": $UNBOUND_PVCS,
  "last_updated": "$(date --iso-8601=seconds)"
}
EOF
)

echo "Sending state..."
mqtt_pub "$STATE_TOPIC" "$PAYLOAD"

echo "Script completed at $(date --iso-8601=ns)"
