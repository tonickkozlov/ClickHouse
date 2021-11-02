#!/bin/bash

# Adapted from docker/test/stateless
set -e -x -o pipefail

# Hardcode localhost hostname, test results depend on it.
hostname localhost

# Choose random timezone for this test run.
TZ="$(grep -v '#' /usr/share/zoneinfo/zone.tab  | awk '{print $3}' | shuf | head -n1)"
echo "Choosen random timezone $TZ"
ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && echo "$TZ" > /etc/timezone

export DEBIAN_FRONTEND=noninteractive
dpkg -i artifacts-in/clickhouse-common-static_*.deb
dpkg -i artifacts-in/clickhouse-common-static-dbg_*.deb
dpkg -i artifacts-in/clickhouse-server_*.deb
dpkg -i artifacts-in/clickhouse-client_*.deb
dpkg -i artifacts-in/clickhouse-test_*.deb

if [[ -n ${CI+x} ]]; then
  echo "Cleaning up input artifacts to avoid TeamCity republishing them"
  rm -rf artifacts-in
fi

# install test configs
/usr/share/clickhouse-test/config/install.sh

# teamcity agents resolve a host which they can't connect to
cat > /etc/clickhouse-server/config.d/local_interserver.xml << EOF
<yandex>
  <interserver_http_host>localhost</interserver_http_host>
</yandex>
EOF

ln -s /usr/lib/llvm-11/bin/llvm-symbolizer /usr/bin/llvm-symbolizer

# These are now moved to `docker/test/base/Dockerfile` in upstream.
echo "TSAN_OPTIONS='verbosity=1000 halt_on_error=1 history_size=7 suppressions=$PWD/cf-build/tests/tsan_suppressions.txt'" >> /etc/environment
echo "MSAN_OPTIONS='abort_on_error=1 poison_in_dtor=1'" >> /etc/environment
echo "UBSAN_OPTIONS='print_stacktrace=1'" >> /etc/environment

service clickhouse-server start && sleep 5

mkdir -p artifacts
mkdir -p test_output

collect_logs() {
  service clickhouse-server stop ||:

  echo "Collecting logs"
  cp -rf test_output/ artifacts/

  tar czf artifacts/logs.tar.gz /var/log/clickhouse-server
  tar czf artifacts/data.tar.gz /var/lib/clickhouse
  tar czf artifacts/config.tar.gz  /etc/clickhouse-server
}
trap collect_logs ERR EXIT

function run_tests()
{
    set -x
    # We can have several additional options so we path them as array because it's
    # more ideologically correct.
    read -ra ADDITIONAL_OPTIONS <<< "${ADDITIONAL_OPTIONS:-}"

#    with_sanitizer=$(clickhouse client -q "SELECT count() FROM system.build_options WHERE name = 'CXX_FLAGS' AND value like '%-fsanitize%'")

    ADDITIONAL_OPTIONS+=('--jobs')
    ADDITIONAL_OPTIONS+=('8')

    # Start tests to skip.
    ADDITIONAL_OPTIONS+=('--skip')
    # Cloudflare: we don't build some 3rd parties
    ADDITIONAL_OPTIONS+=('_arrow')
    ADDITIONAL_OPTIONS+=('_avro')
    ADDITIONAL_OPTIONS+=('_build_id')
    ADDITIONAL_OPTIONS+=('_hdfs')
    ADDITIONAL_OPTIONS+=('_msgpack')
    ADDITIONAL_OPTIONS+=('_mysql')
    ADDITIONAL_OPTIONS+=('_odbc')
    ADDITIONAL_OPTIONS+=('_orc')
    ADDITIONAL_OPTIONS+=('_parquet')
    ADDITIONAL_OPTIONS+=('_protobuf')
    ADDITIONAL_OPTIONS+=('_sqlite')

    # Depends on mysql table function which we don't build.
    ADDITIONAL_OPTIONS+=('01747_system_session_log_long')

    # Cloudflare CI fails localhost resolution
    ADDITIONAL_OPTIONS+=('00646_url_engine')
    ADDITIONAL_OPTIONS+=('01622_defaults_for_url_engine')
    ADDITIONAL_OPTIONS+=('01854_HTTP_dict_decompression')
    ADDITIONAL_OPTIONS+=('01720_dictionary_create_source_with_functions')
    ADDITIONAL_OPTIONS+=('01501_cache_dictionary_all_fields')
    ADDITIONAL_OPTIONS+=('01257_dictionary_mismatch_types')

    # These need investigation.
    ADDITIONAL_OPTIONS+=('01288_shard_max_network_bandwidth')
    ADDITIONAL_OPTIONS+=('01658_read_file_to_stringcolumn')
    ADDITIONAL_OPTIONS+=('01737_clickhouse_server_wait_server_pool_long')
    ADDITIONAL_OPTIONS+=('01507_clickhouse_server_start_with_embedded_config')
    ADDITIONAL_OPTIONS+=('01594_too_low_memory_limits')

    # depends on Yandex internal infrastructure
    ADDITIONAL_OPTIONS+=('01801_s3_cluster')
    ADDITIONAL_OPTIONS+=('02012_settings_clause_for_s3')
    ADDITIONAL_OPTIONS+=('01944_insert_partition_by')

    # No ipv6 in Docker on the metal CI agents.
    ADDITIONAL_OPTIONS+=('01293_show_clusters')

    # Not interested.
    ADDITIONAL_OPTIONS+=('01606_git_import')
    # End tests to skip.

    set +e
    clickhouse-test --testname --shard --zookeeper --check-zookeeper-session --hung-check --print-time \
            "${ADDITIONAL_OPTIONS[@]}" 2>&1 \
        | ts '%Y-%m-%d %H:%M:%S' \
        | tee -a test_output/test_result.txt
    set -e
}

run_tests

clickhouse-client -q "system flush logs" ||:
