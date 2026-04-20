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
#   1. cp scripts/.mqtt.env.example scripts/.mqtt.env
#   2. chmod 600 scripts/.mqtt.env
#   3. Fill in MQTT_HOST, MQTT_PORT, MQTT_USER and MQTT_PASSWORD
#   4. Add to crontab: */5 * * * * /path/to/scripts/k3s-monitor.sh >> /path/to/logs/k3s-monitor.log 2>&1
#
# Dependencies: mosquitto-clients, kubectl (kubeconfig at ~/.kube/config)

echo "Script started at $(date --iso-8601=ns)"

# ============================================================================
# Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

STATE_TOPIC="k3s/monitor/state"
DEVICE_ID="k3s_server_node"
DEVICE_NAME="k3s Server Node"

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
KUBECTL="kubectl --request-timeout=10s"

# Cache files for Flux sensors — preserves last known values when kubectl fails
FLUX_APPLIED_REVISION_CACHE="$SCRIPT_DIR/.flux_applied_revision_cache"
FLUX_GIT_REVISION_CACHE="$SCRIPT_DIR/.flux_git_revision_cache"
FLUX_GIT_FETCHED_AT_CACHE="$SCRIPT_DIR/.flux_git_fetched_at_cache"

# Cache for apt update results — refreshed at most once per hour
APT_CACHE="$SCRIPT_DIR/.apt_updates_cache"
APT_CACHE_MAX_AGE=3600

# ============================================================================
# Load Credentials & Environment Config
# ============================================================================

MQTT_ENV="$SCRIPT_DIR/.mqtt.env"

if [[ ! -f "$MQTT_ENV" ]]; then
    echo "ERROR: MQTT config not found at $MQTT_ENV" >&2
    echo "Please create it from .mqtt.env.example" >&2
    exit 1
fi

PERMS=$(stat -c %a "$MQTT_ENV")
if [[ "$PERMS" != "600" ]]; then
    echo "WARNING: Insecure permissions on $MQTT_ENV (found: $PERMS, expected: 600)" >&2
fi

source "$MQTT_ENV"

if [[ -z "${MQTT_HOST:-}" ]] || [[ -z "${MQTT_PORT:-}" ]] || \
   [[ -z "${MQTT_USER:-}" ]] || [[ -z "${MQTT_PASSWORD:-}" ]]; then
    echo "ERROR: MQTT_HOST, MQTT_PORT, MQTT_USER or MQTT_PASSWORD not set in $MQTT_ENV" >&2
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
    send_sensor_discovery "k3s_disk_free_gb"     "NVMe Free"           "GB"   "mdi:harddisk"
    send_sensor_discovery "k3s_cpu_temp"         "CPU Temperature"     "°C"   "mdi:thermometer"   "temperature"
    send_sensor_discovery "k3s_nvme_temp"        "NVMe Temperature"    "°C"   "mdi:thermometer"   "temperature"
    send_sensor_discovery "k3s_fan_rpm"          "Fan Speed"           "RPM"  "mdi:fan"
    send_sensor_discovery "k3s_fan_pwm"          "Fan PWM"             "%"    "mdi:fan"
    send_sensor_discovery "k3s_last_boot"        "Last Boot"           ""     "mdi:restart"       "timestamp"

    # k3s cluster metrics
    send_sensor_discovery "k3s_unhealthy_pods"   "Unhealthy Pods"      ""     "mdi:kubernetes"
    send_sensor_discovery "k3s_unbound_pvcs"     "Unbound PVCs"        ""     "mdi:database-alert"

    # Flux CD metrics
    send_sensor_discovery "k3s_flux_git_revision"      "Flux Git Revision"      ""  "mdi:source-branch"
    send_sensor_discovery "k3s_flux_applied_revision"  "Flux Applied Revision"  ""  "mdi:check-circle"
    send_sensor_discovery "k3s_flux_git_fetched_at"    "Flux Git Fetched At"    ""  "mdi:sync"  "timestamp"

    # OS update sensors
    send_sensor_discovery "k3s_system_updates"   "System Updates"      "updates" "mdi:package-up"
    send_sensor_discovery "k3s_eeprom_status"    "EEPROM Status"       ""        "mdi:chip"

    # Binary sensors
    send_binary_discovery "k3s_node_ready"       "k3s Node Ready"      "mdi:kubernetes"        "connectivity"
    send_binary_discovery "k3s_undervoltage"     "k3s Undervoltage"    "mdi:lightning-bolt"    "problem"
    send_binary_discovery "k3s_flux_ready"       "Flux Ready"          "mdi:sync-alert"        "problem"

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

# NVMe free space (GB)
get_disk_free_gb() {
    df / | awk 'NR==2 {printf "%.1f", $4/1024/1024}'
}

# Last boot time (ISO 8601 for HA timestamp device_class)
get_last_boot() {
    date -d "$(uptime -s)" --iso-8601=seconds
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
    status=$(KUBECONFIG="$KUBECONFIG" $KUBECTL get nodes \
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
    local result
    result=$(KUBECONFIG="$KUBECONFIG" $KUBECTL get pods --all-namespaces --no-headers 2>/dev/null \
        | awk '{print $4}' \
        | { grep -vcE "^(Running|Succeeded|Completed)$" || true; })
    echo "${result:-0}"
}

# Flux: are all kustomizations Ready?
# Returns ON (no problem) or OFF (problem detected — inverted for HA problem device_class)
get_flux_ready() {
    local not_ready
    not_ready=$(KUBECONFIG="$KUBECONFIG" $KUBECTL get kustomizations -n flux-system \
        -o jsonpath='{.items[*].status.conditions[?(@.type=="Ready")].status}' \
        2>/dev/null \
        | tr ' ' '\n' \
        | { grep -vc "^True$" || true; })
    [[ "${not_ready:-1}" == "0" ]] && echo "OFF" || echo "ON"
}

# Flux: short SHA that Flux has fetched from GitHub (GitRepository artifact revision)
get_flux_git_revision() {
    local rev
    rev=$(KUBECONFIG="$KUBECONFIG" $KUBECTL get gitrepository flux-system -n flux-system \
        -o jsonpath='{.status.artifact.revision}' 2>/dev/null)
    if [[ -z "$rev" ]]; then
        [[ -f "$FLUX_GIT_REVISION_CACHE" ]] && cat "$FLUX_GIT_REVISION_CACHE" || echo "-"
        return
    fi
    # "main@sha1:ee7755bb..." → "ee7755bb"
    local short
    short=$(echo "$rev" | sed 's/.*sha[0-9]*://' | cut -c1-8)
    echo "$short" > "$FLUX_GIT_REVISION_CACHE"
    echo "$short"
}

# Flux: short SHA of last applied revision for apps kustomization
# When this matches get_flux_git_revision, the cluster is fully up to date.
get_flux_applied_revision() {
    local rev
    rev=$(KUBECONFIG="$KUBECONFIG" $KUBECTL get kustomization apps -n flux-system \
        -o jsonpath='{.status.lastAppliedRevision}' 2>/dev/null)
    if [[ -z "$rev" ]]; then
        [[ -f "$FLUX_APPLIED_REVISION_CACHE" ]] && cat "$FLUX_APPLIED_REVISION_CACHE" || echo "-"
        return
    fi
    local short
    short=$(echo "$rev" | sed 's/.*sha[0-9]*://' | cut -c1-8)
    echo "$short" > "$FLUX_APPLIED_REVISION_CACHE"
    echo "$short"
}

# Flux: timestamp when Flux last successfully fetched from GitHub.
# Comes directly from Flux's own status — no script-derived cache needed.
get_flux_git_fetched_at() {
    local ts
    ts=$(KUBECONFIG="$KUBECONFIG" $KUBECTL get gitrepository flux-system -n flux-system \
        -o jsonpath='{.status.artifact.lastUpdateTime}' 2>/dev/null)
    if [[ -z "$ts" ]]; then
        [[ -f "$FLUX_GIT_FETCHED_AT_CACHE" ]] && cat "$FLUX_GIT_FETCHED_AT_CACHE"
        return
    fi
    echo "$ts" > "$FLUX_GIT_FETCHED_AT_CACHE"
    echo "$ts"
}

# Available system updates — cached for APT_CACHE_MAX_AGE seconds to avoid running apt every 5 min
get_system_updates() {
    local now cache_age
    now=$(date +%s)
    if [[ -f "$APT_CACHE" ]]; then
        cache_age=$(( now - $(stat -c %Y "$APT_CACHE") ))
        if [[ $cache_age -lt $APT_CACHE_MAX_AGE ]]; then
            cat "$APT_CACHE"
            return
        fi
    fi
    local count
    count=$(sudo /usr/bin/apt update 2>/dev/null \
        | grep "can be upgraded" \
        | awk '{print $1}')
    count="${count:-0}"
    echo "$count" > "$APT_CACHE"
    echo "$count"
}

# EEPROM bootloader update status
get_eeprom_status() {
    local status
    status=$(sudo /usr/bin/rpi-eeprom-update 2>/dev/null \
        | grep "BOOTLOADER:" \
        | awk '{print $2,$3,$4}')
    echo "${status:-unknown}"
}

# Count PVCs not in Bound state
get_unbound_pvcs() {
    local result
    result=$(KUBECONFIG="$KUBECONFIG" $KUBECTL get pvc --all-namespaces --no-headers 2>/dev/null \
        | awk '{print $3}' \
        | { grep -vc "^Bound$" || true; })
    echo "${result:-0}"
}

# ============================================================================
# Main
# ============================================================================

send_discovery

echo "Collecting metrics..."

CPU_USAGE=$(get_cpu_usage)
RAM_USAGE=$(get_ram_usage)
DISK_USAGE=$(get_disk_usage)
DISK_FREE_GB=$(get_disk_free_gb)
LAST_BOOT=$(get_last_boot)
CPU_TEMP=$(get_temp "cpu_thermal")
NVME_TEMP=$(get_temp "nvme")
FAN_RPM=$(get_fan_rpm)
FAN_PWM=$(get_fan_pwm)
UNDERVOLTAGE=$(get_undervoltage)
NODE_READY=$(get_node_ready)
UNHEALTHY_PODS=$(get_unhealthy_pods)
UNBOUND_PVCS=$(get_unbound_pvcs)
FLUX_READY=$(get_flux_ready)
FLUX_GIT_REVISION=$(get_flux_git_revision)
FLUX_APPLIED_REVISION=$(get_flux_applied_revision)
FLUX_GIT_FETCHED_AT=$(get_flux_git_fetched_at)
SYSTEM_UPDATES=$(get_system_updates)
EEPROM_STATUS=$(get_eeprom_status)

echo "CPU: ${CPU_USAGE}%, RAM: ${RAM_USAGE}%, Disk: ${DISK_USAGE}% (${DISK_FREE_GB} GB free)"
echo "CPU temp: ${CPU_TEMP}°C, NVMe temp: ${NVME_TEMP}°C"
echo "Fan: ${FAN_RPM} RPM (${FAN_PWM}%)"
echo "Node ready: ${NODE_READY}, Unhealthy pods: ${UNHEALTHY_PODS}, Unbound PVCs: ${UNBOUND_PVCS}"
echo "Undervoltage: ${UNDERVOLTAGE}"
echo "Flux ready: ${FLUX_READY}, git: ${FLUX_GIT_REVISION}, applied: ${FLUX_APPLIED_REVISION}, fetched at: ${FLUX_GIT_FETCHED_AT}"
echo "System updates: ${SYSTEM_UPDATES}, EEPROM: ${EEPROM_STATUS}"

PAYLOAD=$(cat <<EOF
{
  "k3s_cpu_usage": $CPU_USAGE,
  "k3s_ram_usage": $RAM_USAGE,
  "k3s_disk_usage": $DISK_USAGE,
  "k3s_disk_free_gb": $DISK_FREE_GB,
  "k3s_last_boot": "$LAST_BOOT",
  "k3s_cpu_temp": $CPU_TEMP,
  "k3s_nvme_temp": $NVME_TEMP,
  "k3s_fan_rpm": $FAN_RPM,
  "k3s_fan_pwm": $FAN_PWM,
  "k3s_undervoltage": "$UNDERVOLTAGE",
  "k3s_node_ready": "$NODE_READY",
  "k3s_unhealthy_pods": $UNHEALTHY_PODS,
  "k3s_unbound_pvcs": $UNBOUND_PVCS,
  "k3s_flux_ready": "$FLUX_READY",
  "k3s_flux_git_revision": "$FLUX_GIT_REVISION",
  "k3s_flux_applied_revision": "$FLUX_APPLIED_REVISION",
  "k3s_flux_git_fetched_at": "$FLUX_GIT_FETCHED_AT",
  "k3s_system_updates": $SYSTEM_UPDATES,
  "k3s_eeprom_status": "$EEPROM_STATUS",
  "last_updated": "$(date --iso-8601=seconds)"
}
EOF
)

echo "Sending state..."
mqtt_pub "$STATE_TOPIC" "$PAYLOAD" retain

echo "Script completed at $(date --iso-8601=ns)"
