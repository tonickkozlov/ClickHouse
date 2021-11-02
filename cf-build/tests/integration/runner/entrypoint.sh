#!/bin/bash

set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive
dpkg -i artifacts-in/clickhouse-common-static_*.deb
dpkg -i artifacts-in/clickhouse-common-static-dbg_*.deb
dpkg -i artifacts-in/clickhouse-server_*.deb
dpkg -i artifacts-in/clickhouse-client_*.deb

if [[ -n ${CI+x} ]]; then
  echo "Cleaning up input artifacts to avoid TeamCity republishing them"
  rm -rf artifacts-in
fi

mkdir -p /etc/docker/
echo '{
    "ipv6": true,
    "fixed-cidr-v6": "fd00::/8",
    "ip-forward": true,
    "log-level": "debug",
    "storage-driver": "overlay2"
}' | dd of=/etc/docker/daemon.json 2>/dev/null

dockerd \
    --host=unix:///var/run/docker.sock \
    --host=tcp://0.0.0.0:2375 \
    --default-address-pool base=172.17.0.0/12,size=24 \
    &>/clickhouse/tests/integration/dockerd.log &

set +e
reties=0
while true; do
    docker info &> /dev/null && break
    reties=$((reties+1))
    if [[ $reties -ge 100 ]]; then # 10 sec max
        echo "Can't start docker daemon, timeout exceeded." >&2
        docker info
        cat /var/log/dockerd
        exit 1;
    fi
    sleep 0.1
done
set -e

# "shell" container that is used to run clickhouse servers w/ the binary mounted.
docker build -t clickhouse/integration-test ./cf-build/tests/integration/shell

# Just use the same image. We pre-installed iptables.
docker tag clickhouse/integration-test clickhouse/integration-helper

# Drop extra capabilities which were added when the package was built.
# We don't need them for tests.
setcap -r /usr/bin/clickhouse

if [[ -n ${WAIT_DONT_RUN+x} ]]; then
  echo "Environment prepared, you can now interact with the container via docker exec."
  tail -f /dev/null
fi

mkdir -p artifacts

collect_logs() {
  echo "Collecting logs"
  tar czf /clickhouse/artifacts/test_dir.tar.gz /clickhouse/tests/integration
}
trap collect_logs ERR EXIT

PYTEST_EXTRA_ARGS=${PYTEST_EXTRA_ARGS:-""}

read -ra PYTEST_EXTRA_ARGS <<< "${PYTEST_EXTRA_ARGS:-}"
read -ra TESTS_TO_RUN <<< "${TESTS_TO_RUN:-}";

cd /clickhouse/tests/integration

  set +x # too verbose
if [[ ${#TESTS_TO_RUN[@]} -eq 0 ]]; then
  TESTS_TO_RUN=(
    # Cloudflare tests:
    test_cf_*
    test_backward_compatibility

    # Upstream tests:
    test_aggregation_memory_efficient
    test_alter_codec
    test_attach_without_checksums
    test_attach_without_fetching
    test_authentication
    test_block_structure_mismatch
    test_broken_part_during_merge
    test_check_table
    test_cleanup_dir_after_bad_zk_conn
    test_cluster_all_replicas
    test_compression_codec_read
    test_compression_nested_columns
    test_concurrent_queries_for_all_users_restriction
    test_concurrent_queries_for_user_restriction
    test_config_corresponding_root
    test_config_substitutions
    test_config_xml_full
    test_config_xml_main
    test_config_xml_yaml_mix
    test_consistant_parts_after_move_partition
    test_consistent_parts_after_clone_replica
    test_cross_replication
    test_default_compression_codec
    test_delayed_replica_failover
    test_dictionaries_update_and_reload
    test_dictionary_allow_read_expired_keys
    test_dictionary_custom_settings
    test_distributed_queries_stress
    test_drop_replica
    test_http_and_readonly
    test_https_replication
    test_merge_tree_empty_parts
    test_non_default_compression
    test_optimize_on_insert
    test_part_moves_between_shards
    test_part_uuid
    test_partition
    test_parts_delete_zookeeper
    test_polymorphic_parts
    test_query_deduplication
    test_quorum_inserts_parallel
    test_recovery_replica
    test_reload_clusters_config
    test_reload_zookeeper
    test_reloading_settings_from_users_xml
    test_replace_partition
    test_replicated_mutations
    test_replicated_parse_zk_metadata
    test_replication_credentials
    test_restore_replica
    test_send_crash_reports
    test_settings_constraints
    test_settings_constraints_distributed
    test_timezone_config
    test_ttl_replicated
    test_user_ip_restrictions
    test_version_update_after_mutation
    test_zookeeper_config
    test_lost_part_during_startup
  )
fi
set -x

# Action!
# shellcheck disable=SC2068
pytest ${TESTS_TO_RUN[@]} ${PYTEST_EXTRA_ARGS[@]} | tee /clickhouse/artifacts/test_result.txt
