#!/usr/bin/env bash

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CURDIR"/../shell_config.sh

${CLICKHOUSE_CLIENT_SECURE} --log_queries=1 --query_id "2025_${CLICKHOUSE_DATABASE}_query_1" -q "select 1"
${CLICKHOUSE_CLIENT} -q "system flush logs"
${CLICKHOUSE_CLIENT} -q "select is_secure from system.query_log where query_id = '2025_${CLICKHOUSE_DATABASE}_query_1' and type = 'QueryFinish' and current_database = currentDatabase()"

QUERY_ID=$RANDOM

${CLICKHOUSE_CURL} -sS "${CLICKHOUSE_URL_HTTPS}&query_id=${QUERY_ID}" -d "SELECT 1"
${CLICKHOUSE_CLIENT} -q "system flush logs"
${CLICKHOUSE_CLIENT} -q "select is_secure from system.query_log where query_id = '${QUERY_ID}' and type = 'QueryFinish' and current_database = currentDatabase()"

${CLICKHOUSE_CLIENT} --log_queries=1 --query_id "2025_${CLICKHOUSE_DATABASE}_query_2" -q "select 1"
${CLICKHOUSE_CLIENT} -q "system flush logs"
${CLICKHOUSE_CLIENT} -q "select is_secure from system.query_log where query_id = '2025_${CLICKHOUSE_DATABASE}_query_2' and type = 'QueryFinish' and current_database = currentDatabase()"

QUERY_ID=$RANDOM

${CLICKHOUSE_CURL} -sS "${CLICKHOUSE_URL}&query_id=${QUERY_ID}" -d "SELECT 1"
${CLICKHOUSE_CLIENT} -q "system flush logs"
${CLICKHOUSE_CLIENT} -q "select is_secure from system.query_log where query_id = '${QUERY_ID}' and type = 'QueryFinish' and current_database = currentDatabase()"
