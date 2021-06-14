#!/bin/bash

# Adapted from docker/test/stateless
set -e -x -o pipefail

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

# These are now moved to `docker/test/base/Dockerfile` in upstream.
echo "TSAN_OPTIONS='verbosity=1000 halt_on_error=1 history_size=7'" >> /etc/environment
echo "TSAN_SYMBOLIZER_PATH=/usr/lib/llvm-11/bin/llvm-symbolizer" >> /etc/environment
echo "UBSAN_OPTIONS='print_stacktrace=1'" >> /etc/environment
echo "ASAN_SYMBOLIZER_PATH=/usr/lib/llvm-11/bin/llvm-symbolizer" >> /etc/environment
echo "UBSAN_SYMBOLIZER_PATH=/usr/lib/llvm-11/bin/llvm-symbolizer" >> /etc/environment
echo "LLVM_SYMBOLIZER_PATH=/usr/lib/llvm-11/bin/llvm-symbolizer" >> /etc/environment

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

    # teamcity agents resolve a host which they can't connect to
    ADDITIONAL_OPTIONS+=('00646_url_engine')

    # depends on Yandex internal infrastructure
    ADDITIONAL_OPTIONS+=('01801_s3_cluster')
    # End tests to skip.

    clickhouse-test --testname --shard --zookeeper --hung-check --print-time \
            --use-skip-list "${ADDITIONAL_OPTIONS[@]}" 2>&1 \
        | ts '%Y-%m-%d %H:%M:%S' \
        | tee -a test_output/test_result.txt
}

run_tests

clickhouse-client -q "system flush logs" ||:
