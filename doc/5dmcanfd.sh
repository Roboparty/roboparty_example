#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 wentywenty

# ================= 配置区域 =================
# INTERFACES=("can0" "can1" "can2" "can3")
INTERFACES=("can7")
# INTERFACES=("can4" "can5" "can6" "can7")
BITRATE=1000000
DBITRATE=5000000
SAMPLEPOINT=0.800
SJW=4
DSAMPLEPOINT=0.750
DSJW=2

# MIT 控制帧参数
NUM_MOTORS=7        # 控制电机数量 (1~8)
SEND_COUNT=10000    # 连发次数 (每轮发送 NUM_MOTORS 帧)
MIT_HZ=750          # MIT 发送频率 (Hz)

# DM MIT 编码(8字节): pos(16) | vel(12) | kp(12) | kd(12) | torque(12)
# 全零: pos=0→0x7FFF, vel=0→0x7FF, kp=0→0x000, kd=0→0x000, torque=0→0x7FF
# 字节序: 7F FF 7F F0 00 00 07 FF
MIT_ZERO="7FFF7FF0000007FF"

ENABLE_RESCUE=false
PARSE_ERROR=0        # 0=不解析电机错误反馈, 1=启动 candump 解析
# [SET] 日志文件路径
RESCUE_LOG="can_rescue_mit.log"
ERROR_LOG="/tmp/dm_error_$$.log"

# DM 错误码映射 (data[0] bits 7-4, 值范围 0x08~0x0F)
declare -A DM_ERR_MAP=(
    [08]="OVER_VOLT"
    [09]="UNDER_VOLT"
    [0A]="OVER_CURRENT"
    [0B]="MOS_OVER_TEMP"
    [0C]="COIL_OVER_TEMP"
    [0D]="LOST_CONN"
    [0E]="OVER_LOAD"
)
# ============================================

if [ "$EUID" -ne 0 ]; then
  echo "请使用 sudo 运行"
  exit
fi

echo ">>> 配置 restart-ms + txqueuelen..."
for IF in "${INTERFACES[@]}"; do
    ip link set "$IF" down
    ip link set "$IF" type can bitrate $BITRATE sample-point $SAMPLEPOINT sjw $SJW \
            dbitrate $DBITRATE dsample-point $DSAMPLEPOINT dsjw $DSJW fd on restart-ms 100
    ip link set "$IF" mtu 72
    ip link set "$IF" txqueuelen 10000
    ip link set "$IF" up
    echo "  [$IF] ${BITRATE}/$DBITRATE ds${DSAMPLEPOINT} restart-ms=100 qlen=10000"
done
echo ""

# 初始清理并创建/清空日志
echo "--- CANFD MIT Flood Log Start: $(date) ---" > "$RESCUE_LOG"
> "$ERROR_LOG"

# ---------- 后台 candump 抓包 + 解析 DM 错误 ----------
start_error_monitor() {
    local ifs=$(IFS=,; echo "${INTERFACES[*]}")
    # candump 只抓 0x001-0x007 的回复帧 (DM 回复 ID = motor_id)
    stdbuf -oL candump -L "$ifs" 2>/dev/null | stdbuf -oL grep -E '^\([0-9.]+\)\s+can[0-9]+\s+00[1-7]#' | while read -r line; do
        local ts iface midhex data
        ts=$(echo "$line" | awk '{print $1}' | tr -d '()')
        iface=$(echo "$line" | awk '{print $2}')
        midhex=$(echo "$line" | awk '{print $3}' | cut -d'#' -f1)
        data=$(echo "$line" | awk '{print $3}' | cut -d'#' -f2)
        # DM: error = (data[0] >> 4), 有效范围 8-15
        local err_byte=${data:0:2}
        local err_code=$((16#${err_byte} >> 4))
        if [[ $err_code -ge 8 && $err_code -le 15 ]]; then
            local mid=$((16#$midhex))
            local err_name="${DM_ERR_MAP[$(printf '%02X' $err_code)]:-UNKNOWN}"
            echo "$ts|$iface|motor_$mid|$err_code|$err_name|$data"
        fi
    done >> "$ERROR_LOG" 2>/dev/null &
    CANDUMP_PID=$!
}

stop_error_monitor() {
    [[ -n "${CANDUMP_PID:-}" ]] && kill "$CANDUMP_PID" 2>/dev/null
    rm -f "$ERROR_LOG"
}

parse_error_summary() {
    # 统计每个电机的最近错误
    declare -gA DM_ERR_LAST
    declare -gA DM_ERR_LAST_TS
    while IFS='|' read -r ts iface motor err_code err_name data; do
        DM_ERR_LAST["$iface:$motor"]="$err_name(0x$(printf '%02X' ${err_code:-0}))"
        DM_ERR_LAST_TS["$iface:$motor"]="$ts"
    done < "$ERROR_LOG"
}

cleanup() {
    echo -e "\n[!] 正在停止所有测试进程..."
    stop_error_monitor
    kill $(jobs -p) 2>/dev/null
    exit
}
trap cleanup INT

# 启动错误监控
if [[ $PARSE_ERROR -eq 1 ]]; then
    start_error_monitor
fi

# ---------- 逐电机使能 + 标零 (DM: motor_id, 8B, FF..+CMD) ----------
# 使能=0xFC, 标零=0xFE, 失能=0xFD
CMD_ENABLE="FFFFFFFFFFFFFFFC"
CMD_ZERO="FFFFFFFFFFFFFFFE"

echo "=========================================================================================="
echo ">>> 逐电机 使能 + 标零 (DM motor_id 直接控制)"
echo "=========================================================================================="
for IF in "${INTERFACES[@]}"; do
    echo "  [$IF] ${NUM_MOTORS} 个电机..."
    for ((m=1; m<=NUM_MOTORS; m++)); do
        MID=$(printf '%03X' $m)
        echo -n "    [Motor $m] 使能..."
        cansend "$IF" "${MID}#${CMD_ENABLE}"
        sleep 0.3
        echo -n " 标零..."
        cansend "$IF" "${MID}#${CMD_ZERO}"
        sleep 0.2
        echo -n " 再使能..."
        cansend "$IF" "${MID}#${CMD_ENABLE}"
        sleep 0.3
        echo " 完成"
    done
done
echo ""

echo ">>> DM 单电机 MIT 逐帧连发: ${NUM_MOTORS} 电机 × ${SEND_COUNT} 轮, ${MIT_HZ}Hz"
echo "    MIT 全零帧: ${MIT_ZERO}"
echo ""

declare -A last_rx last_tx
INTERVAL_SEC=1

while true; do
    clear
    echo "=========================================================================================="
    echo "    DM CANFD MIT FLOOD [RESCUE ENABLED] - $(date +%T)"
    echo "    Motors: $NUM_MOTORS | Per-motor MIT frame | Flood: ${SEND_COUNT} rounds"
    echo "    Log: $RESCUE_LOG | Config: 1M/5M BRS"
    echo "=========================================================================================="
    printf "%-5s %-12s %-8s %-10s %-10s %-8s %-8s %-10s\n" "IF" "State" "TEC/REC" "RX-PPS" "TX-PPS" "BusErr" "ArbLst" "Action"
    echo "------------------------------------------------------------------------------------------"

    for IF in "${INTERFACES[@]}"; do
        ip_info=$(ip -d -s link show $IF)
        state=$(echo "$ip_info" | grep -oE "ERROR-(ACTIVE|WARNING|PASSIVE)|BUS-OFF|STOPPED" | head -1)
        tec_rec=$(echo "$ip_info" | grep -A 1 "bus-errors" | tail -n 1 | awk '{print $1"/"$2}')
        bus_err=$(echo "$ip_info" | grep -oP "bus-errors \K[0-9]+")
        arb_lst=$(echo "$ip_info" | grep -oP "arbitration-lost \K[0-9]+")
        sp=$(echo "$ip_info" | grep "sample-point" | head -1 | awk '{print $2}')
        dsp=$(echo "$ip_info" | grep "sample-point" | tail -1 | awk '{print $2}')
        err_details=$(echo "$ip_info" | grep -E "ack|crc|stuff|form" | xargs | sed 's/  */ /g')

        action="IDLE"
        if [[ "$state" == "BUS-OFF" ]] || [[ "$state" == "STOPPED" ]]; then
            if [ "$ENABLE_RESCUE" = true ]; then
                action="RESTARTING"
                log_msg="[$(date +%T)] [$IF] Event: $state | TEC/REC: $tec_rec | Stats: $err_details | SP: $sp/$dsp"
                echo "$log_msg" >> "$RESCUE_LOG"
                ip link set $IF type can restart 2>/dev/null
            fi
        fi

        curr_rx=$(cat /sys/class/net/$IF/statistics/rx_packets 2>/dev/null || echo 0)
        curr_tx=$(cat /sys/class/net/$IF/statistics/tx_packets 2>/dev/null || echo 0)
        rx_rate=$((curr_rx - ${last_rx[$IF]:-$curr_rx}))
        tx_rate=$((curr_tx - ${last_tx[$IF]:-$curr_tx}))
        last_rx[$IF]=$curr_rx
        last_tx[$IF]=$curr_tx

        color="\033[32m"
        [[ "$state" != "ERROR-ACTIVE" ]] && color="\033[33m"
        [[ "$state" == "BUS-OFF" ]] && color="\033[31m"

        printf "%-5s ${color}%-12s\033[0m %-8s %-10s %-10s %-8s %-8s %-10s\n" \
                "$IF" "$state" "$tec_rec" "$rx_rate" "$tx_rate" "$bus_err" "$arb_lst" "$action"
        echo -e "      \033[90m└─ SP: ${sp}/${dsp} | Errors: ${err_details}\033[0m"
    done

    echo ""
    echo "------------------------------------------------------------------------------------------"
    if [[ $PARSE_ERROR -eq 1 ]]; then
    echo "  电机错误反馈:"
    parse_error_summary
    local err_count=0
    for IF in "${INTERFACES[@]}"; do
        for ((m=1; m<=NUM_MOTORS; m++)); do
            local key="$IF:motor_$m"
            if [[ -n "${DM_ERR_LAST[$key]:-}" ]]; then
                printf "    \033[31m[%s motor_%d] %s\033[0m (ts %s)\n" \
                    "$IF" "$m" "${DM_ERR_LAST[$key]}" "${DM_ERR_LAST_TS[$key]}"
                ((err_count++))
            fi
        done
    done
    if [[ $err_count -eq 0 ]]; then
        echo "    \033[32m全部正常\033[0m"
    fi
    fi
    echo "------------------------------------------------------------------------------------------"
    printf "  [INPUT] r=开始连发 | q=退出 | 其他=刷新状态\n"
    echo "------------------------------------------------------------------------------------------"

    read -rs -t $INTERVAL_SEC -N 1 key
    if [[ "$key" == "q" ]]; then
        echo ""
        echo "[!] 退出。"
        exit 0
    elif [[ "$key" == "r" ]]; then
        echo ""
        echo ">>> 开始连发 ${SEND_COUNT} 轮 (每轮 ${NUM_MOTORS} 帧 MIT 全零)..."
        START_TIME=$(date +%s%N)
        SUCCESS=0
        FAIL=0
        for IF in "${INTERFACES[@]}"; do
            IF_OK=0
            IF_FAIL=0
            SLEEP_US=$(( 1000000 / MIT_HZ ))
            for ((i=1; i<=SEND_COUNT; i++)); do
                for ((m=1; m<=NUM_MOTORS; m++)); do
                    MID=$(printf '%03X' $m)
                    if cansend "$IF" "${MID}#${MIT_ZERO}"; then
                        ((IF_OK++))
                    else
                        ((IF_FAIL++))
                    fi
                done
                usleep "$SLEEP_US" 2>/dev/null || sleep 0.001333
            done
            echo "  [$IF] 完成: 成功=$IF_OK, 失败=$IF_FAIL"
            ((SUCCESS += IF_OK))
            ((FAIL += IF_FAIL))
        done
        END_TIME=$(date +%s%N)
        ELAPSED=$(( (END_TIME - START_TIME) / 1000000 ))
        TOTAL=$((SUCCESS + FAIL))
        if [[ $ELAPSED -gt 0 ]]; then
            echo "  汇总: ${TOTAL} 帧 / ${ELAPSED}ms = $(echo "scale=1; $TOTAL * 1000 / $ELAPSED" | bc) 帧/s"
        fi
        echo "  日志: $RESCUE_LOG"
    fi
done
