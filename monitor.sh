#!/bin/sh

# 获取脚本所在目录
SCRIPT_DIR=$(dirname "$0")

# 配置文件和输出文件路径
ENV_FILE="$SCRIPT_DIR/.env"
DATA_FILE="$SCRIPT_DIR/traffic_usage.log"  # 当前月流量使用情况
LAST_TX_BYTES_FILE="$SCRIPT_DIR/last_transmission_bytes.log"  # 上次传输字节数
HISTORY_FILE="$SCRIPT_DIR/traffic_history.log"  # 历史流量日志

# 读取 .env 文件
if [ -f "$ENV_FILE" ]; then
    export $(grep -v '^#' "$ENV_FILE" | xargs)
else
    echo ".env 文件不存在: $ENV_FILE"
    exit 1
fi

# 检查环境变量中的必要参数
if [ -z "$TRAFFIC_LIMIT_GB" ] || [ -z "$NETWORK_INTERFACE" ] || [ -z "$SHUTDOWN_DELAY_MINUTES" ] || [ -z "$WECHAT_PUSH_ENABLED" ]; then
    echo ".env 文件中缺少必要的参数"
    exit 1
fi

# 如果 WECHAT_PUSH_ENABLED 为 1，则检查企业微信相关配置
if [ "$WECHAT_PUSH_ENABLED" -eq 1 ]; then
    if [ -z "$CORP_ID" ] || [ -z "$CORP_SECRET" ] || [ -z "$TO_USER" ] || [ -z "$AGENT_ID" ]; then
        echo ".env 文件中缺少企业微信相关的参数"
        exit 1
    fi
fi

# 使用 .env 文件中的网口名称
INTERFACE="$NETWORK_INTERFACE"

# 获取当前日期中的月份 (用于检测是否需要重置流量统计)
CURRENT_MONTH=$(date +"%Y-%m")

# 如果流量日志文件不存在，创建并初始化
if [ ! -f $DATA_FILE ]; then
    echo "$CURRENT_MONTH 0" > $DATA_FILE
fi

# 读取保存的月份和累计流量
SAVED_MONTH=$(awk '{print $1}' $DATA_FILE)
SAVED_TRAFFIC=$(awk '{print $2}' $DATA_FILE)

# 如果月份改变，重置累计流量，并记录上个月的流量
if [ "$SAVED_MONTH" != "$CURRENT_MONTH" ]; then
    # 记录上个月的流量到历史日志文件
    echo "$SAVED_MONTH $SAVED_TRAFFIC" >> $HISTORY_FILE
    
    # 重置累计流量
    SAVED_TRAFFIC=0
    echo "$CURRENT_MONTH 0" > $DATA_FILE
fi

# 获取当前的出站字节数
CURRENT_TX_BYTES=$(cat /sys/class/net/$INTERFACE/statistics/tx_bytes)
CURRENT_TX_BYTES=$((CURRENT_TX_BYTES))

# 读取上次运行时记录的字节数（或默认为 0）
if [ ! -f $LAST_TX_BYTES_FILE ]; then
    LAST_TX_BYTES=0
else
    LAST_TX_BYTES=$(cat $LAST_TX_BYTES_FILE)
    LAST_TX_BYTES=$((LAST_TX_BYTES))
fi

# 计算自上次运行以来的新增流量
if [ "$CURRENT_TX_BYTES" -ge "$LAST_TX_BYTES" ]; then
    NEW_TRAFFIC=$((CURRENT_TX_BYTES - LAST_TX_BYTES))
else
    NEW_TRAFFIC=$CURRENT_TX_BYTES
fi

# 更新累计流量
TOTAL_TRAFFIC=$((SAVED_TRAFFIC + NEW_TRAFFIC))

# 将当前字节数保存以供下次使用
echo "$CURRENT_TX_BYTES" > $LAST_TX_BYTES_FILE

# 将累计流量和当前月份写回到文件
echo "$CURRENT_MONTH $TOTAL_TRAFFIC" > $DATA_FILE

# 将字节数转换为 GB
TRAFFIC_DISPLAY=$(echo "scale=2; $TOTAL_TRAFFIC / 1024 / 1024 / 1024" | bc)

# 输出格式化结果到控制台
echo "本月累计流量: ${TRAFFIC_DISPLAY}GB"

# 检查流量是否超过 .env 文件中的阈值
LIMIT=$(echo "$TRAFFIC_LIMIT_GB * 1024 * 1024 * 1024" | bc)

if (( $(echo "$TOTAL_TRAFFIC >= $LIMIT" | bc -l) )); then
    if [ "$WECHAT_PUSH_ENABLED" -eq 1 ]; then
        # 获取企业微信 Access Token
        get_access_token() {
            local token_url="https://qyapi.weixin.qq.com/cgi-bin/gettoken?corpid=$CORP_ID&corpsecret=$CORP_SECRET"
            ACCESS_TOKEN=$(curl -s "$token_url" | grep -o '"access_token":"[^"]*"' | awk -F\" '{print $4}')
        }

        # 发送消息到企业微信
        send_wechat_message() {
            local send_url="https://qyapi.weixin.qq.com/cgi-bin/message/send?access_token=$ACCESS_TOKEN"
            local message="本月累计流量: ${TRAFFIC_DISPLAY}GB, 已超过${TRAFFIC_LIMIT_GB}GB限制！"
            
            # 准备 JSON 数据
            local data=$(cat <<EOF
{
   "touser" : "$TO_USER",
   "msgtype" : "text",
   "agentid" : "$AGENT_ID",
   "text" : {
       "content" : "$message"
   },
   "safe":0
}
EOF
)

            # 使用 curl 发送 POST 请求，并丢弃返回值
            response=$(curl -s -o /dev/null -w "%{http_code}" -X POST -H "Content-Type: application/json" -d "$data" "$send_url")
            if [ "$response" -ne 200 ]; then
                echo "消息发送失败，HTTP 状态码: $response"
            fi
        }

        # 调用函数
        get_access_token
        send_wechat_message
    fi

    # 读取关机等待时间
    SHUTDOWN_DELAY_SECONDS=$((SHUTDOWN_DELAY_MINUTES * 60))

    if [ "$SHUTDOWN_DELAY_SECONDS" -gt 0 ]; then
        echo "流量已超出限制，系统将在 $SHUTDOWN_DELAY_MINUTES 分钟后关机。"
        sleep $SHUTDOWN_DELAY_SECONDS  # 等待指定分钟数

        # 执行关机命令
        if command -v shutdown > /dev/null; then
            shutdown -h now
        else
            poweroff
        fi
    fi
fi
