#!/bin/bash

# ==========================================================
# WiFi Auto Reconnect Script
# For Ubuntu 24.04 using NetworkManager (nmcli)
# ==========================================================

LOG_FILE="/tmp/wifi_auto_reconnect.log"
DATE_CMD=$(date '+%Y-%m-%d %H:%M:%S')

rm "$LOG_FILE" && touch "$LOG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "========== Script Started =========="

# 1️⃣ 检查 Wi-Fi 是否已连接
WIFI_STATE=$(nmcli -t -f WIFI g)

if [[ "$WIFI_STATE" != "enabled" ]]; then
    log "Wi-Fi is disabled. Attempting to enable..."
    nmcli radio wifi on
    sleep 3
fi

CONNECTED_SSID=$(nmcli -t -f STATE g | grep "connected")
IS_LOCAL=$(nmcli -t -f STATE g | grep "local")

if [[ -n "$CONNECTED_SSID" ]]; then
    if [[ -z "$IS_LOCAL" ]]; then
        log "Already connected: $CONNECTED_SSID"
        log "No action required."
        exit 0
    fi
fi

log "Wi-Fi is disconnected. Starting scan..."

# 2️⃣ 扫描 Wi-Fi 网络
nmcli dev wifi rescan
sleep 3

SCAN_RESULTS=$(nmcli -t -f IN-USE,SSID,SIGNAL,CHAN dev wifi list)

if [[ -z "$SCAN_RESULTS" ]]; then
    log "Scan returned no results."
    exit 1
fi
log "$SCAN_RESULTS"

# 3️⃣ 获取已保存的 Wi-Fi 连接
SAVED_CONNECTIONS=$(nmcli -t -f NAME,TYPE con show | grep ':802-11-wireless$' | cut -d: -f1)

if [[ -z "$SAVED_CONNECTIONS" ]]; then
    log "No saved Wi-Fi connections found."
    exit 1
fi

log "Saved Wi-Fi connections:"
log "$SAVED_CONNECTIONS"

BEST_5G=""
BEST_5G_SIGNAL=0
BEST_24G=""
BEST_24G_SIGNAL=0

# 4️⃣ 遍历扫描结果，筛选已保存网络并进行优先级排序
while IFS=: read -r INUSE SSID SIGNAL CHAN; do
    [[ -z "$SSID" ]] && continue

    if echo "$SAVED_CONNECTIONS" | grep -Fxq "$SSID"; then
        log "Found saved network in scan: $SSID (Signal: $SIGNAL, Channel: $CHAN)"

        # 5GHz频段 (频率 > 5000 MHz)
        if [[ "$CHAN" -ge 36 ]]; then
            if [[ "$SIGNAL" -gt "$BEST_5G_SIGNAL" ]]; then
                BEST_5G="$SSID"
                BEST_5G_SIGNAL="$SIGNAL"
            fi
        else
            if [[ "$SIGNAL" -gt "$BEST_24G_SIGNAL" ]]; then
                BEST_24G="$SSID"
                BEST_24G_SIGNAL="$SIGNAL"
            fi
        fi
    fi
done <<< "$SCAN_RESULTS"

# 5️⃣ 按优先级决定连接目标
TARGET_SSID=""

if [[ -n "$BEST_5G" ]]; then
    TARGET_SSID="$BEST_5G"
    log "Selected 5GHz network: $TARGET_SSID (Signal: $BEST_5G_SIGNAL)"
elif [[ -n "$BEST_24G" ]]; then
    TARGET_SSID="$BEST_24G"
    log "Selected 2.4GHz network: $TARGET_SSID (Signal: $BEST_24G_SIGNAL)"
else
    log "No saved networks found in scan results."
    exit 1
fi

# 6️⃣ 尝试连接
log "Attempting to connect to $TARGET_SSID ..."

nmcli con up "$TARGET_SSID" >> "$LOG_FILE" 2>&1

if [[ $? -eq 0 ]]; then
    log "Successfully connected to $TARGET_SSID"
else
    log "Failed to connect to $TARGET_SSID"
    exit 1
fi

log "========== Script Finished =========="
exit 0
