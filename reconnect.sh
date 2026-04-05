#!/bin/bash

# 设置：在连接有线网的情况下不再自动连接Wi-Fi？
# y = 有线已连接时不自动连 Wi-Fi
# n = 即使有线网络已连接，也自动重新连接到Wi-Fi
NO_RECONNECT_IF_WIRED_CONNECTED="n"

DATE_STR=$(date '+%F')
LOG_DIR="/tmp/wifi_auto_reconnect"
LOG_FILE="${LOG_DIR}/${DATE_STR}.log"

# 如果目录不存在就创建它
[[ ! -d "$LOG_DIR" ]] && mkdir -p "$LOG_DIR"

# 自动清理旧日志，防止日志堆积
find "${LOG_DIR}" -name "*.log" -mtime +1 -delete 2>/dev/null || true

touch "$LOG_FILE"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

log "========== Script Started =========="

# 1️⃣ 检查 Wi-Fi 是否已连接

# 检查整个网络的连接状态，不区分有线或无线
CONNECT_STATE=$(nmcli -t -f STATE g)

if [[ "$CONNECT_STATE" == "connected" && "$NO_RECONNECT_IF_WIRED_CONNECTED" == "y" ]]; then
    log "Already connected: $CONNECT_STATE"
    log "No action required."
    exit 0
fi

# 检查无线网卡是否启用
WIFI_STATE=$(nmcli -t -f WIFI g)

if [[ "$WIFI_STATE" != "enabled" ]]; then
    log "Wi-Fi is disabled. Attempting to enable..."
    nmcli radio wifi on
    sleep 10
fi

# 检查无线网络连接状态
WIFI_CONNECT_STATE=$(nmcli -t device status | grep -F 'wifi:connected')

if [[ -n "$WIFI_CONNECT_STATE" ]]; then
    log "$WIFI_CONNECT_STATE"
    log "Wi-Fi is connected. No action required."
    exit 0
fi

log "Wi-Fi is disconnected. Starting scan..."

# 2️⃣ 扫描 Wi-Fi 网络
nmcli dev wifi rescan
sleep 3

SCAN_RESULTS=$(nmcli -t -f SSID,SIGNAL,CHAN,FREQ,IN-USE dev wifi list)

if [[ -z "$SCAN_RESULTS" ]]; then
    log "Scan returned no results."
    exit 1
fi
log "$SCAN_RESULTS"

# 3️⃣ 获取已保存的 Wi-Fi 连接的真实 SSID

SAVED_CONNECTIONS=$(nmcli -t -f UUID,TYPE,NAME con show)
log "Saved Connections:"
log "$SAVED_CONNECTIONS"

if [[ -z "$SAVED_CONNECTIONS" ]]; then
    log "No saved connections from nmcli."
    exit 1
fi

# 先获取所有类型为 802-11-wireless 的连接的 UUID
# (使用 UUID 比 NAME 更安全，不会受空格或特殊字符干扰)
WIFI_UUIDS=$(printf "%s" "$SAVED_CONNECTIONS" | grep -F ':802-11-wireless:' | cut -d: -f1)

if [[ -z "$WIFI_UUIDS" ]]; then
    log "No saved Wi-Fi connections found in NetworkManager."
    exit 1
fi

SAVED_SSIDS=""
UUID_SSID_LIST=""

# 遍历每个 UUID，查询它配置中真实的 SSID
for uuid in $WIFI_UUIDS; do
    # 使用 -g (get) 参数查询特定字段，它会直接输出纯文本值
    actual_ssid=$(nmcli -g 802-11-wireless.ssid con show "$uuid" 2>/dev/null)
    
    # 如果获取到了 SSID，就追加到列表中，每个 SSID 占一行
    if [[ -n "$actual_ssid" ]]; then
        SAVED_SSIDS="${SAVED_SSIDS}${actual_ssid}\n"
        UUID_SSID_LIST="${UUID_SSID_LIST}${uuid}:${actual_ssid}\n"
    fi
done

# 将带有 \n 的字符串转换为真正的多行文本
SAVED_SSIDS=$(printf "%b" "$SAVED_SSIDS")
UUID_SSID_LIST=$(printf "%b" "$UUID_SSID_LIST")

if [[ -z "$SAVED_SSIDS" ]]; then
    log "No valid SSIDs could be extracted from saved connections."
    exit 1
fi

log "Saved Wi-Fi SSIDs:"
log "$SAVED_SSIDS"

log "List of UUIDs and SSIDs:"
log "$UUID_SSID_LIST"

BEST_5G=""
BEST_5G_SIGNAL=0
BEST_24G=""
BEST_24G_SIGNAL=0

# 4️⃣ 遍历扫描结果，筛选已保存网络并进行优先级排序
while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # TODO: 带冒号的SSID转义问题
    if [[ -n $(printf "%s" "$line" | grep -F '\') ]]; then
        log 'Escaped characters in SSID!!!'
        log "Ignored: '$line'"
        continue
    fi
    
    # 分割扫描结果
    IFS=: read -r SSID SIGNAL CHAN FREQ INUSE <<< "$line"

    log "SSID: '$SSID' | SIGNAL: '$SIGNAL' | CHAN: '$CHAN' | FREQ: '$FREQ' | IN-USE: '$INUSE'"
    
    # 丢弃空SSID（隐藏的网络）
    [[ -z "$SSID" ]] && continue

    if echo "$SAVED_SSIDS" | grep -Fxq "$SSID"; then
        # 去除FREQ后面的' MHz'只保留数字
        FREQ=$(printf "%s" "$FREQ" | sed 's/[^0-9]//g')
        
        log "Found saved network in scan: $SSID (Signal: $SIGNAL, Channel: $CHAN, Frequency: $FREQ)"

        # 通过FREQ判断是否5GHz/6GHz网络
        if [[ -n "$FREQ" && "$FREQ" -ge 5000 ]]; then
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

# 5️⃣ 按优先级决定连接目标，优先连接5GHz，2.4GHz作为备用
TARGET_SSID=""
BACKUP_SSID=""

if [[ -n "$BEST_5G" ]]; then
    TARGET_SSID="$BEST_5G"
    log "Selected 5GHz network: $TARGET_SSID (Signal: $BEST_5G_SIGNAL)"
    if [[ -n "$BEST_24G" ]]; then
        BACKUP_SSID="$BEST_24G"
        log "Backup 2.4GHz network: $BACKUP_SSID (Signal: $BEST_24G_SIGNAL)"
    fi
elif [[ -n "$BEST_24G" ]]; then
    TARGET_SSID="$BEST_24G"
    log "Selected 2.4GHz network: $TARGET_SSID (Signal: $BEST_24G_SIGNAL)"
else
    log "No saved networks found in scan results."
    exit 1
fi

# 6️⃣ 尝试连接
log "Attempting to connect to '$TARGET_SSID' ..."
TARGET_CONN=$(printf "%s" "$SAVED_CONNECTIONS" | grep -F "$(printf "%s" "$UUID_SSID_LIST" | grep -F "$TARGET_SSID" | cut -d: -f1)" | sed -E 's/^.+:802-11-wireless://')

if [[ -z "$TARGET_CONN" ]]; then
    log "Failed to find connection name for SSID: '$TARGET_SSID'"
    exit 1
fi

log "Connection name is '$TARGET_CONN'"

nmcli con up "$TARGET_CONN" >> "$LOG_FILE" 2>&1

if [[ $? -eq 0 ]]; then
    log "Successfully connected to $TARGET_SSID"
else
    log "Failed to connect to $TARGET_SSID"
    if [[ -n "$BACKUP_SSID" ]]; then
        log "Attempting to connect to $BACKUP_SSID ..."
        BACKUP_CONN=$(printf "%s" "$SAVED_CONNECTIONS" | grep -F "$(printf "%s" "$UUID_SSID_LIST" | grep -F "$TARGET_SSID" | cut -d: -f1)" | sed -E 's/^.+:802-11-wireless://')

        if [[ -z "$BACKUP_CONN" ]]; then
            log "Failed to find connection name for SSID: '$BACKUP_SSID'"
            exit 1
        fi

        log "Connection name is '$BACKUP_CONN'"
        
        nmcli con up "$BACKUP_CONN" >> "$LOG_FILE" 2>&1
        if [[ $? -eq 0 ]]; then
            log "Successfully connected to $BACKUP_SSID"
        else
            log "Failed to connect to $BACKUP_SSID"
            exit 1
        fi
    else
        exit 1
    fi
fi

log "========== Script Finished =========="
exit 0

