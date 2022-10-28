#!/usr/bin/env bash
set -eu
set -o pipefail

# exit code
EXIT_CODE_OK=0
EXIT_CODE_METRIC_NOT_SELECTED=1
EXIT_CODE_RETRIVE_RAWINFO_TIMEOUT=2
EXIT_CODE_RETRIVE_RAWINFO_HTTPCODE=3

# env file
NODE_ENV_FILE="/opt/app/bin/envs/node.env"
# hack for an undefined variable
SERVICES=
source $NODE_ENV_FILE
# need source predefined env file
getExporterHostName() {
    local res=$(host $MY_IP | awk '{print $NF}')
    res=${res:0:-1}
    echo $res
}

# loccal service endpoint
EXPORTER_HOST_NAME=$(getExporterHostName)
PORT="9200"

# metric level
LVLCLUSTER="cluster"
LVLNODE="node"

# METRIC for searching
# use '/' to split the settings
# display name/metric level/real metric key/json selector names/filters/value type flag
# metric level: cluster/node
# value type flag: i=integer,f=float,s=string
METRIC_SELECTORS=$(cat <<METRIC_SELECTORS
os_cluster_status/${LVLCLUSTER}/es_cluster_status///i
os_cluster_shards_number/${LVLCLUSTER}/es_cluster_shards_number/type//i
os_cluster_task_max_waiting_time_seconds/${LVLCLUSTER}/es_cluster_task_max_waiting_time_seconds///i
os_cluster_datanodes_number/${LVLCLUSTER}/es_cluster_datanodes_number///i
os_cluster_nodes_number/${LVLCLUSTER}/es_cluster_nodes_number///i
os_cluster_shards_active_percent/${LVLCLUSTER}/es_cluster_shards_active_percent///i
os_cluster_pending_tasks_number/${LVLCLUSTER}/es_cluster_pending_tasks_number///i
os_cluster_inflight_fetch_number/${LVLCLUSTER}/es_cluster_inflight_fetch_number///i
os_cluster_task_max_waiting_time_seconds/${LVLCLUSTER}/es_cluster_task_max_waiting_time_seconds///i
os_jvm_mem_heap_used_percent/${LVLNODE}/es_jvm_mem_heap_used_percent///i
METRIC_SELECTORS
)

# store the raw info retrived from exporter
RAWINFO=

main() {
    if [ $# -lt 1 ] || [ -z "$1" ]; then
        echo "{}"
        return $EXIT_CODE_OK
    fi
    if [ ! "$1" = "cluster" ] && [ ! "$1" = "node" ]; then
        echo "{}"
        return $EXIT_CODE_OK
    fi
    if ! getRowInfoFromExporter; then
        echo "{}"
        return $EXIT_CODE_OK
    fi
    if [ -z "$RAWINFO" ]; then
        echo "{}"
        return $EXIT_CODE_OK
    fi
    
    echo "{"
    if [ "$1" = "cluster" ]; then
        getClusterMetrics
    else
        getNodeMetrics
    fi
    echo "}"
}

getRowInfoFromExporter() {
    local tmpstr
    if ! tmpstr=$(curl -m 10 -s -u "$MY_ADMIN_USER":"$MY_ADMIN_PASSWORD" ${EXPORTER_HOST_NAME}:${PORT}/_prometheus/metrics -w "\n%{http_code}"); then
        RAWINFO=""
        return $EXIT_CODE_RETRIVE_RAWINFO_TIMEOUT
    fi
    local code=$(echo "$tmpstr" | tail -n1)
    code=${code:0:-1}
    if [ ! "$code" = "20" ];then
        RAWINFO=""
        return $EXIT_CODE_RETRIVE_RAWINFO_TIMEOUT
    fi
    RAWINFO=$(echo "$tmpstr" | awk 'NR>1{print p}{p=$0}')
}

# calculate health metrics
getClusterHealthMetric() {
    #local tmp=$(curl -s -u $)
    :
}

getClusterMetrics() {
    local ms=$(echo "$METRIC_SELECTORS" | grep "/$LVLCLUSTER/")
    while read line; do
        runPipeline "$line"
    done <<<"$ms"
}

getNodeMetrics() {
    local ms=$(echo "$METRIC_SELECTORS" | grep "/$LVLNODE/")
    while read line; do
        runPipeline "$line"
    done <<<"$ms"
}

runPipeline() {
    local line=$1
    local display=$(echo $line | awk -F'/' '{print $1}')
    local level=$(echo $line | awk -F'/' '{print $2}')
    local key=$(echo $line | awk -F'/' '{print $3}')
    local filters=$(echo $line | awk -F'/' '{print $4}')
    local query=$(echo $line | awk -F'/' '{print $5}')
    local flag=$(echo $line | awk -F'/' '{print $6}')

    local target=$(echo "$RAWINFO" | grep "^$key")
    local value
    local json
    while read item; do
        value="${item##* }"
        json=$(extractJson "$item")
        render "$display" "$level" "$json" "$value" "$flag" "$filters" "$query"
    done <<<"$target"
}

extractJson() {
    local origin=$(echo "$1" | grep -o '{.*}')
    # get rid of '{' and ',}'
    origin=\"${origin:1:-2}
    # subtitude '=' to '":'
    origin=${origin//=/\":}
    # subtitude ',' to ',"'
    origin=\{${origin//,/\,\"}\}
    echo "$origin"
}

# rander the metrics output
# input params
# 1 display, 2 level, 3 json, 4 value, 5 flag, 6 filters, 7 query
render() {
    local value=$(formatValue "$4" "$5")
    local suffix

    if ! isMetricOk "$2" "$3" "$7"; then return $EXIT_CODE_OK; fi

    if [ -n "$6" ]; then
        suffix=$(getSuffix "$3" "$6")
    else
        suffix=""
    fi
    if [ -z "$suffix" ]; then
        echo "\"$1\":$value,"
    else
        echo "\"${1}${suffix}\":$value,"
    fi
}

# check if the metric is selected
# input params
# 1 level, 2 json, 3 filters
isMetricOk() {
    local tmp=""
    if [ "$1" = "$LVLCLUSTER" ]; then return $EXIT_CODE_OK; fi
    if [ -z "$3" ]; then
        tmp="echo \"\$2\" | jq 'select(.node==\"$EXPORTER_HOST_NAME\")'"
        tmp=$(eval "$tmp")
        if [ -z "$tmp" ]; then return $EXIT_CODE_METRIC_NOT_SELECTED; else return $EXIT_CODE_OK; fi
    fi
    # process filters for future

    return $EXIT_CODE_OK
}

# convert the value with proper format
# input params
# 1 value, 2 value type flag
formatValue() {
    case "$2" in
        "i")
            printf "%.0f" "$1"
        ;;
        "s")
            echo "\"$1\""
        ;;
        *)
            echo "$1"
        ;;
    esac
}

# calculate suffix string
# input params
# 1 json 2 selectors
getSuffix() {
    local sels=($2)
    local len=${#sels[@]}
    local tmp=""
    local res=""
    for((i=0;i<len;i++)); do
        tmp=$(echo "$1" | jq .${sels[i]})
        tmp=${tmp//\"}
        res="${res}_${tmp}"
    done
    echo $res
}

main $@
