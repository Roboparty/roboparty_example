#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Copyright (c) 2026 wentywenty

# ================= 配置区域 =================
# INTERFACES=("can0" "can1" "can2" "can3")
INTERFACES=("can6")
# INTERFACES=("can4" "can5" "can6" "can7")
BITRATE=1000000
DBITRATE=5000000
SAMPLEPOINT=0.800
SJW=4
DSAMPLEPOINT=0.750
DSJW=2

# MIT 控制帧参数
CANID=00008080      # XY 一拖多 MIT CAN ID (扩展帧 0x8080, 8位十六进制)
NUM_MOTORS=5        # 控制电机数量 (1~7)
SEND_COUNT=10000    # 连发次数
MIT_HZ=750          # MIT 发送频率 (Hz)

# XY MIT 编码(8字节): mode(3)|kp[11:7] | kp[6:0]|kd[8] | kd[7:0] | pos[15:8] | pos[7:0] | spd[11:4] | spd[3:0]|trq[11:8] | trq[7:0]
# 全零: kp=0, kd=0, pos=0→0x8000, spd=0→0x0800, trq=0→0x0800, mode=0
MOTOR_ZERO_DATA="0000008000800800"

ENABLE_RESCUE=false
PARSE_ERROR=0        # 0=不解析电机错误反馈, 1=启动 candump 解析
# [SET] 日志文件路径
RESCUE_LOG="can_rescue_mit.log"
ERROR_LOG="/tmp/xyn_error_$$.log"

# XYN 错误码映射 (0x00F 帧 data[0])
declare -A XYN_ERR_MAP=(
    [01]="OVER_VOLTAGE"
    [02]="OVER_CURRENT"
    [03]="MOTOR_OVER_TEMP"
    [04]="BOARD_OVER_TEMP"
    [05]="UNDER_VOLTAGE"
    [06]="ENCODER_FAULT"
    [07]="COMM_FAULT"
    [08]="WARN_MOTOR_OVER_TEMP"
    [09]="WARN_BOARD_OVER_TEMP"
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

# XY 扩展帧 CAN ID = (device_id << 12) | msg_id
#   使能: msg_id=0x001, data=01; 失能: data=00
#   设模式: msg_id=0x002, data=08 (MIT)
#   标零:  msg_id=0x006, data=(empty)
#   启动:  msg_id=0x004, data=01; 停止: data=00
xyn_canid() {
    local motor=$1 msg=$2
    printf '%08X' $(( (motor << 12) | msg ))
}

echo "=========================================================================================="
echo ">>> 逐电机 使能 + 设MIT模式 + 标零 + 启动 (XY 扩展帧 29bit)"
echo "=========================================================================================="
for IF in "${INTERFACES[@]}"; do
    echo "  [$IF] ${NUM_MOTORS} 个电机..."
    for ((m=1; m<=NUM_MOTORS; m++)); do
        EN_ID=$(xyn_canid $m 0x001)
        MD_ID=$(xyn_canid $m 0x002)
        ZR_ID=$(xyn_canid $m 0x006)
        ST_ID=$(xyn_canid $m 0x004)

        echo -n "    [Motor $m] 使能..."
        cansend "$IF" "${EN_ID}#01"
        sleep 0.3
        echo -n " 停止..."
        cansend "$IF" "${ST_ID}#00"
        sleep 0.2
        echo -n " MIT模式..."
        cansend "$IF" "${MD_ID}#08"
        sleep 0.2
        echo -n " 标零..."
        cansend "$IF" "${ZR_ID}#"
        sleep 0.2
        echo -n " 启动..."
        cansend "$IF" "${ST_ID}#01"
        sleep 0.3
        echo " 完成"
    done
done
echo ""

# 构建 64 字节 CANFD 一拖多数据帧
# XY 一拖多: 扩展帧 msg_id=0x080, 每电机 8 字节, 最多 8 电机(实际 7+风扇)
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

# ---------- 后台 candump 抓包 + 解析 XYN 错误 (EFF 帧 msg_id=0x00F) ----------
start_error_monitor() {
    local ifs=$(IFS=,; echo "${INTERFACES[*]}")
    # XYN 错误帧: EFF can_id=(device_id<<12)|0x00F, candump 显示为 00X0000F#
    stdbuf -oL candump -L "$ifs" 2>/dev/null | stdbuf -oL grep -E '^\([0-9.]+\)\s+can[0-9]+\s+00[0-7]0000F#' | while read -r line; do
        local ts iface canid data
        ts=$(echo "$line" | awk '{print $1}' | tr -d '()')
        iface=$(echo "$line" | awk '{print $2}')
        canid=$(echo "$line" | awk '{print $3}' | cut -d'#' -f1)
        data=$(echo "$line" | awk '{print $3}' | cut -d'#' -f2)
        # XYN EFF ID 编码: device_id = (can_id >> 12) & 0x7F
        local did_hex="${canid:0:2}"
        local did=$((16#$did_hex))
        local err_byte=$((16#${data:0:2}))
        if [[ $err_byte -ne 0 ]]; then
            local err_hex=$(printf '%02X' $err_byte)
            local err_name="${XYN_ERR_MAP[$err_hex]:-UNKNOWN}"
            echo "$ts|$iface|device_$did|$err_byte|$err_name|$data"
        fi
    done >> "$ERROR_LOG" 2>/dev/null &
    CANDUMP_PID=$!
}

stop_error_monitor() {
    [[ -n "${CANDUMP_PID:-}" ]] && kill "$CANDUMP_PID" 2>/dev/null
    rm -f "$ERROR_LOG"
}

parse_error_summary() {
    declare -gA XYN_ERR_LAST
    declare -gA XYN_ERR_LAST_TS
    while IFS='|' read -r ts iface motor err_code err_name data; do
        XYN_ERR_LAST["$iface:$motor"]="$err_name(0x$(printf '%02X' ${err_code:-0}))"
        XYN_ERR_LAST_TS["$iface:$motor"]="$ts"
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

# ---------- 构建 MIT 连发帧 ----------
echo ">>> 构建帧数据: XY MIT MULTI (msg_id=0x080), $NUM_MOTORS 电机, MIT 全零..."
FRAME_DATA=$(build_frame)
echo "    数据: $FRAME_DATA"
echo ""

declare -A last_rx last_tx
INTERVAL_SEC=1

while true; do
    clear
    echo "=========================================================================================="
    echo "    XYN PRH21 CANFD MIT FLOOD [RESCUE ENABLED] - $(date +%T)"
    echo "    CANID: msg=0x${CANID} (extended) | Motors: $NUM_MOTORS | Payload: 64B | Flood: ${SEND_COUNT}x"
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
            local key="$IF:device_$m"
            if [[ -n "${XYN_ERR_LAST[$key]:-}" ]]; then
                printf "    \033[31m[%s device_%d] %s\033[0m (ts %s)\n" \
                    "$IF" "$m" "${XYN_ERR_LAST[$key]}" "${XYN_ERR_LAST_TS[$key]}"
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
