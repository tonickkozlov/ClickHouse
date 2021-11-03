import pytest

from helpers.cluster import ClickHouseCluster

cluster = ClickHouseCluster(__file__)
node1 = cluster.add_instance('node1', with_zookeeper=True, image='yandex/clickhouse-server', tag='21.8', stay_alive=True, with_installed_binary=True)
node2 = cluster.add_instance('node2', with_zookeeper=True)


@pytest.fixture(scope="module")
def start_cluster():
    try:
        cluster.start()
        for i, node in enumerate([node1, node2]):
            node.query_with_retry(
                '''CREATE TABLE t(date Date, id UInt32, lcn LowCardinality(Nullable(String)))
                ENGINE = ReplicatedMergeTree('/clickhouse/tables/test/t', '{}')
                PARTITION BY toYYYYMM(date)
                ORDER BY id
                SETTINGS min_bytes_for_wide_part = 0'''.format(i))

        yield cluster

    finally:
        cluster.shutdown()


def test_backward_compatibility_lcn(start_cluster):
    node1.query("INSERT INTO t VALUES (today(), 1, null), (today(), 2, 'hello')")
    node2.query("SYSTEM SYNC REPLICA t", timeout=10)
    assert node2.query("SELECT count() FROM t") == "2\n"

    node2.query("INSERT INTO t VALUES (today(), 3, 'world')")
    node1.query("SYSTEM SYNC REPLICA t", timeout=10)
    assert node1.query("SELECT count() FROM t") == "3\n"

    assert node1.query("CHECK TABLE t") == "1\n", "node1"
    assert node2.query("CHECK TABLE t") == "1\n", "node2"

    node1.restart_with_latest_version()
    assert node1.query("SELECT count() FROM t") == "3\n"
