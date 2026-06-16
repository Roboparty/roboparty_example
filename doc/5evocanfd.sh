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
CANID=020          # MIT 模式 CAN ID
NUM_MOTORS=5        # 控制电机数量 (1~8)
SEND_COUNT=10000    # 连发次数
MIT_HZ=750          # MIT 发送频率 (Hz)

# 单电机全部为0的 MIT 数据: Kp=0, Kd=0, θ=0, V=0, T=0
# 协议定义: Byte0-1=位置(0x7FFF=0rad), Byte2-3=速度(0x7FF=0rad/s),
#           Byte3-4=Kp(0x000=0), Byte5-6=Kd(0x000=0), Byte6-7=扭矩(0x7FF=0Nm)
MOTOR_ZERO_DATA="7FFF7FF0000017FF"  # 7F FF 7F F0 00 00 17 FF (Kd=1)

ENABLE_RESCUE=false
PARSE_ERROR=0        # 0=不解析电机错误反馈, 1=启动 candump 解析
# [SET] 日志文件路径
RESCUE_LOG="can_rescue_mit.log"
ERROR_LOG="/tmp/evo_error_$$.log"

# EVO CANFD 错误 bitmask → 错误码映射
# 解码顺序同 C++ decode_evo_canfd_error，优先返回最高优先级错误
# bit13=0x10  COMM_LOST, bit12=0x0D POS_OVER_LIMIT, bit11=0x02 UNDER_VOLT
# bit10=0x09  PCB_OVER_TEMP, bit8=0x0F STALL, bit4=0x0E OVER_SPEED
# bit3=0x0A   COIL_OVER_TEMP, bit2=0x06 PHASE_A_OVER_CURRENT, bit1=0x01 OVER_VOLT
declare -A EVO_ERR_MAP=(
    [2000]="COMM_LOST"
    [1000]="POS_OVER_LIMIT"
    [0800]="UNDER_VOLT"
    [0400]="PCB_OVER_TEMP"
    [0100]="STALL"
    [0010]="OVER_SPEED"
    [0008]="COIL_OVER_TEMP"
    [0004]="PHASE_A_OVER_CURRENT"
    [0002]="OVER_VOLT"
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

# 构建 64 字节 CANFD 数据帧
# 前 NUM_MOTORS 个槽位填入 MOTOR_ZERO_DATA，剩余填 00
build_frame() {
    local frame=""
    for ((i=0; i<NUM_MOTORS; i++)); do
        frame+="$MOTOR_ZERO_DATA"
    done
    local remaining=$((8 - NUM_MOTORS))
    for ((i=0; i<remaining; i++)); do
        frame+="0000000000000000"
    done
    echo "$frame"
}

# 初始清理并创建/清空日志
echo "--- CANFD MIT Flood Log Start: $(date) ---" > "$RESCUE_LOG"
> "$ERROR_LOG"

# ---------- 后台 candump 抓包 + 解析 EVO CANFD 错误 ----------
start_error_monitor() {
    local ifs=$(IFS=,; echo "${INTERFACES[*]}")
    # EVO 回复帧: can_id = motor_id (0x001-0x005), len >= 8
    stdbuf -oL candump -L "$ifs" 2>/dev/null | stdbuf -oL grep -E '^\([0-9.]+\)\s+can[0-9]+\s+00[1-5]#' | while read -r line; do
        local ts iface midhex data
        ts=$(echo "$line" | awk '{print $1}' | tr -d '()')
        iface=$(echo "$line" | awk '{print $2}')
        midhex=$(echo "$line" | awk '{print $3}' | cut -d'#' -f1)
        data=$(echo "$line" | awk '{print $3}' | cut -d'#' -f2)
        # EVO CANFD: error_word = data[6]<<8 | data[7]
        local err_hi=${data:12:2}
        local err_lo=${data:14:2}
        local err_word=$(( (16#${err_hi} << 8) | 16#${err_lo} ))
        if [[ $err_word -ne 0 ]]; then
            local mid=$((16#$midhex))
            local err_name="UNKNOWN"
            # 按 C++ decode_evo_canfd_error 顺序检查
            if   (( err_word & (1 << 13) )); then err_name="COMM_LOST"
            elif (( err_word & (1 << 12) )); then err_name="POS_OVER_LIMIT"
            elif (( err_word & (1 << 11) )); then err_name="UNDER_VOLT"
            elif (( err_word & (1 << 10) )); then err_name="PCB_OVER_TEMP"
            elif (( err_word & (1 << 8)  )); then err_name="STALL"
            elif (( err_word & (1 << 4)  )); then err_name="OVER_SPEED"
            elif (( err_word & (1 << 3)  )); then err_name="COIL_OVER_TEMP"
            elif (( err_word & (1 << 2)  )); then err_name="PHASE_A_OVER_CURRENT"
            elif (( err_word & (1 << 1)  )); then err_name="OVER_VOLT"
            fi
            echo "$ts|$iface|motor_$mid|$err_word|$err_name|$data"
        fi
    done >> "$ERROR_LOG" 2>/dev/null &
    CANDUMP_PID=$!
}

stop_error_monitor() {
    [[ -n "${CANDUMP_PID:-}" ]] && kill "$CANDUMP_PID" 2>/dev/null
    rm -f "$ERROR_LOG"
}

parse_error_summary() {
    declare -gA EVO_ERR_LAST
    declare -gA EVO_ERR_LAST_TS
    while IFS='|' read -r ts iface motor err_word err_name data; do
        EVO_ERR_LAST["$iface:$motor"]="$err_name(0x$(printf '%04X' ${err_word:-0}))"
        EVO_ERR_LAST_TS["$iface:$motor"]="$ts"
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


# ---------- 逐电机使能 + 标零 (8字节经典CAN帧) ----------
# CANID = Motor ID, 8B, 经典CAN格式
CMD_ENABLE="FFFFFFFFFFFFFFFC"  # 使能: FF FF FF FF FF FF FF FC
CMD_ZERO="FFFFFFFFFFFFFFFE"    # 标零: FF FF FF FF FF FF FF FE

echo "=========================================================================================="
echo ">>> 逐接口 逐电机 使能 + 标零"
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

# ---------- 构建 MIT 连发帧 ----------
echo ">>> 构建帧数据: CANID=0x${CANID}, $NUM_MOTORS 电机, MIT 全零..."
FRAME_DATA=$(build_frame)
echo "    数据: $FRAME_DATA"
echo ""

declare -A last_rx last_tx
INTERVAL_SEC=1

while true; do
    clear
    echo "=========================================================================================="
    echo "    EVO CANFD MIT FLOOD [RESCUE ENABLED] - $(date +%T)"
    echo "    CANID: 0x${CANID} | Motors: $NUM_MOTORS | Payload: 64B | Flood: ${SEND_COUNT}x"
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
            if [[ -n "${EVO_ERR_LAST[$key]:-}" ]]; then
                printf "    \033[31m[%s motor_%d] %s\033[0m (ts %s)\n" \
                    "$IF" "$m" "${EVO_ERR_LAST[$key]}" "${EVO_ERR_LAST_TS[$key]}"
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
        echo ">>> 开始连发 ${SEND_COUNT} 帧 MIT 全零指令..."
        START_TIME=$(date +%s%N)
        SUCCESS=0
        FAIL=0
        for IF in "${INTERFACES[@]}"; do
            IF_OK=0
            IF_FAIL=0
            SLEEP_US=$(( 1000000 / MIT_HZ ))
            for ((i=1; i<=SEND_COUNT; i++)); do
                if cansend "$IF" "${CANID}##1${FRAME_DATA}"; then
                    ((IF_OK++))
                else
                    ((IF_FAIL++))
                fi
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
