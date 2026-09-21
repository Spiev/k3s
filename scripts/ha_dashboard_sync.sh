#!/bin/bash
# =============================================================================
# HA Dashboard Sync
# =============================================================================
# Kopiert Dashboard-YAMLs aus dem lokalen Quellverzeichnis in das
# Home Assistant Config-PVC und löst einen HA-Reload aus.
#
# Setup:
#   chmod 700 ha_dashboard_sync.sh
#   cp .ha.env.example .ha.env && chmod 600 .ha.env
#   # HA_TOKEN: Long-lived access token (HA → Profil → Sicherheit)
#   # HA_URL:   https://<ha-host>:8123
#
# Cron (z.B. nach Bedarf oder bei git pull):
#   0 * * * * /home/stefan/k3s/scripts/ha_dashboard_sync.sh >> /home/stefan/k3s/logs/ha_dashboard_sync.log 2>&1
# =============================================================================

set -euo pipefail

echo "HA dashboard sync started at $(date --iso-8601=ns)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ENV_FILE="$SCRIPT_DIR/.ha.env"

# ============================================================================
# Load Credentials
# ============================================================================

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: $ENV_FILE not found" >&2
    exit 1
fi
if [[ "$(stat -c %a "$ENV_FILE")" != "600" ]]; then
    echo "WARNING: Insecure permissions on $ENV_FILE (expected 600)" >&2
fi
source "$ENV_FILE"

if [[ -z "${HA_TOKEN:-}" ]] || [[ -z "${HA_URL:-}" ]]; then
    echo "ERROR: HA_TOKEN or HA_URL not set in $ENV_FILE" >&2
    exit 1
fi

# ============================================================================
# Resolve paths
# ============================================================================

DASHBOARD_SRC_DIR="$HOME/k3s/apps/homeassistant/dashboards"

if [[ ! -d "$DASHBOARD_SRC_DIR" ]]; then
    echo "ERROR: Source directory not found: $DASHBOARD_SRC_DIR" >&2
    exit 1
fi

# Resolve HA config PVC dir dynamically (local-path names include a UUID prefix)
STORAGE="/var/lib/rancher/k3s/storage"
HA_PVC=$(sudo -S -p '' find "$STORAGE" -maxdepth 1 -name "*_homeassistant_homeassistant-config" -type d 2>/dev/null | head -1)

if [[ -z "$HA_PVC" ]] || ! sudo test -d "$HA_PVC"; then
    echo "ERROR: HA config PVC directory not found under $STORAGE" >&2
    exit 1
fi

DASHBOARD_DST_DIR="$HA_PVC/dashboards"
sudo -S -p '' mkdir -p "$DASHBOARD_DST_DIR"

# ============================================================================
# Deploy dashboards
# ============================================================================

echo "Source:      $DASHBOARD_SRC_DIR"
echo "Destination: $DASHBOARD_DST_DIR"
echo ""
echo "Deploying dashboards..."

for src in "$DASHBOARD_SRC_DIR"/*.yaml; do
    fname="$(basename "$src")"
    echo "  - $fname"
    sudo -S -p '' cp "$src" "$DASHBOARD_DST_DIR/$fname"
done

# ============================================================================
# Reload Home Assistant
# ============================================================================

echo ""
echo "Reloading Home Assistant config..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST "${HA_URL}/api/services/homeassistant/reload_all" \
    -H "Authorization: Bearer ${HA_TOKEN}" \
    -H "Content-Type: application/json" \
    --insecure)

if [[ "$HTTP_CODE" == "200" ]]; then
    echo "Reload successful."
else
    echo "ERROR: HA reload returned HTTP $HTTP_CODE" >&2
    exit 1
fi

echo ""
echo "HA dashboard sync finished at $(date --iso-8601=ns)"
