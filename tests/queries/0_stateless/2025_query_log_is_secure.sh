#!/usr/bin/env bash

CURDIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=../shell_config.sh
. "$CURDIR"/../shell_config.sh

QUERY_ID=$(${CLICKHOUSE_CLIENT} -q "select lower(hex(reverse(reinterpretAsString(generateUUIDv4()))))")

# Native secure
${CLICKHOUSE_CLIENT_SECURE} --log_queries=1 --query_id "${QUERY_ID}" -q "SELECT 1"
${CLICKHOUSE_CLIENT} -q "system flush logs"
${CLICKHOUSE_CLIENT} -q "select is_secure from system.query_log where query_id = '${QUERY_ID}' and type = 'QueryFinish' and current_database = currentDatabase()"

# HTTP secure
QUERY_ID=$(${CLICKHOUSE_CLIENT} -q "select lower(hex(reverse(reinterpretAsString(generateUUIDv4()))))")

${CLICKHOUSE_CURL} -sS --insecure "${CLICKHOUSE_URL_HTTPS}&query_id=${QUERY_ID}" -d "SELECT 1"
${CLICKHOUSE_CLIENT} -q "system flush logs"
${CLICKHOUSE_CLIENT} -q "select is_secure from system.query_log where query_id = '${QUERY_ID}' and type = 'QueryFinish' and current_database = currentDatabase()"

# Native insecure
QUERY_ID=$(${CLICKHOUSE_CLIENT} -q "select lower(hex(reverse(reinterpretAsString(generateUUIDv4()))))")

${CLICKHOUSE_CLIENT} --log_queries=1 --query_id "${QUERY_ID}" -q "SELECT 1"
${CLICKHOUSE_CLIENT} -q "system flush logs"
${CLICKHOUSE_CLIENT} -q "select is_secure from system.query_log where query_id = '${QUERY_ID}' and type = 'QueryFinish' and current_database = currentDatabase()"

# HTTP insecure
QUERY_ID=$(${CLICKHOUSE_CLIENT} -q "select lower(hex(reverse(reinterpretAsString(generateUUIDv4()))))")

${CLICKHOUSE_CURL} -sS "${CLICKHOUSE_URL}&query_id=${QUERY_ID}" -d "SELECT 1"
${CLICKHOUSE_CLIENT} -q "system flush logs"
${CLICKHOUSE_CLIENT} -q "select is_secure from system.query_log where query_id = '${QUERY_ID}' and type = 'QueryFinish' and current_database = currentDatabase()"
