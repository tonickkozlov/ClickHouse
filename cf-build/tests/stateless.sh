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

mkdir -p /etc/clickhouse-server/dict_examples
ln -s /usr/share/clickhouse-test/config/ints_dictionary.xml /etc/clickhouse-server/dict_examples/
ln -s /usr/share/clickhouse-test/config/strings_dictionary.xml /etc/clickhouse-server/dict_examples/
ln -s /usr/share/clickhouse-test/config/decimals_dictionary.xml /etc/clickhouse-server/dict_examples/
ln -s /usr/share/clickhouse-test/config/zookeeper.xml /etc/clickhouse-server/config.d/
ln -s /usr/share/clickhouse-test/config/listen.xml /etc/clickhouse-server/config.d/
ln -s /usr/share/clickhouse-test/config/part_log.xml /etc/clickhouse-server/config.d/
ln -s /usr/share/clickhouse-test/config/text_log.xml /etc/clickhouse-server/config.d/
ln -s /usr/share/clickhouse-test/config/metric_log.xml /etc/clickhouse-server/config.d/
ln -s /usr/share/clickhouse-test/config/custom_settings_prefixes.xml /etc/clickhouse-server/config.d/
ln -s /usr/share/clickhouse-test/config/log_queries.xml /etc/clickhouse-server/users.d/
ln -s /usr/share/clickhouse-test/config/readonly.xml /etc/clickhouse-server/users.d/
ln -s /usr/share/clickhouse-test/config/access_management.xml /etc/clickhouse-server/users.d/
ln -s /usr/share/clickhouse-test/config/ints_dictionary.xml /etc/clickhouse-server/
ln -s /usr/share/clickhouse-test/config/strings_dictionary.xml /etc/clickhouse-server/
ln -s /usr/share/clickhouse-test/config/decimals_dictionary.xml /etc/clickhouse-server/
ln -s /usr/share/clickhouse-test/config/macros.xml /etc/clickhouse-server/config.d/
ln -s /usr/share/clickhouse-test/config/disks.xml /etc/clickhouse-server/config.d/
ln -s /usr/share/clickhouse-test/config/secure_ports.xml /etc/clickhouse-server/config.d/
ln -s /usr/share/clickhouse-test/config/clusters.xml /etc/clickhouse-server/config.d/
ln -s /usr/share/clickhouse-test/config/graphite.xml /etc/clickhouse-server/config.d/
ln -s /usr/share/clickhouse-test/config/server.key /etc/clickhouse-server/
ln -s /usr/share/clickhouse-test/config/server.crt /etc/clickhouse-server/
ln -s /usr/share/clickhouse-test/config/dhparam.pem /etc/clickhouse-server/

# Retain any pre-existing config and allow ClickHouse to load it if required
ln -s --backup=simple --suffix=_original.xml \
    /usr/share/clickhouse-test/config/query_masking_rules.xml /etc/clickhouse-server/config.d/

if [[ -n "$USE_POLYMORPHIC_PARTS" ]] && [[ "$USE_POLYMORPHIC_PARTS" -eq 1 ]]; then
    ln -s /usr/share/clickhouse-test/config/polymorphic_parts.xml /etc/clickhouse-server/config.d/
fi
if [[ -n "$USE_DATABASE_ATOMIC" ]] && [[ "$USE_DATABASE_ATOMIC" -eq 1 ]]; then
    ln -s /usr/share/clickhouse-test/config/database_atomic_configd.xml /etc/clickhouse-server/config.d/
    ln -s /usr/share/clickhouse-test/config/database_atomic_usersd.xml /etc/clickhouse-server/users.d/
fi

ln -sf /usr/share/clickhouse-test/config/client_config.xml /etc/clickhouse-client/config.xml

# teamcity agents resolve a host which they can't connect to
cat > /etc/clickhouse-server/config.d/local_interserver.xml << EOF
<yandex>
  <interserver_http_host>localhost</interserver_http_host>
</yandex>
EOF

echo "TSAN_OPTIONS='verbosity=1000 halt_on_error=1 history_size=7'" >> /etc/environment
echo "TSAN_SYMBOLIZER_PATH=/usr/lib/llvm-10/bin/llvm-symbolizer" >> /etc/environment
echo "UBSAN_OPTIONS='print_stacktrace=1'" >> /etc/environment
echo "ASAN_SYMBOLIZER_PATH=/usr/lib/llvm-10/bin/llvm-symbolizer" >> /etc/environment
echo "UBSAN_SYMBOLIZER_PATH=/usr/lib/llvm-10/bin/llvm-symbolizer" >> /etc/environment
echo "LLVM_SYMBOLIZER_PATH=/usr/lib/llvm-10/bin/llvm-symbolizer" >> /etc/environment

service clickhouse-server start && sleep 5

if cat /usr/bin/clickhouse-test | grep -q -- "--use-skip-list"; then
    SKIP_LIST_OPT="--use-skip-list"
fi

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

clickhouse-test --testname --shard --zookeeper --print-time "$SKIP_LIST_OPT" $ADDITIONAL_OPTIONS $SKIP_TESTS_OPTION 2>&1 | ts '%Y-%m-%d %H:%M:%S' | tee test_output/test_result.txt
