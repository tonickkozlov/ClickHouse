#!/usr/bin/env python3

import pytest
import time
import threading
from helpers.client import QueryRuntimeException
from helpers.cluster import ClickHouseCluster
from helpers.network import PartitionManager
import random
import string

cluster = ClickHouseCluster(__file__)

node1 = cluster.add_instance('node1', with_zookeeper=True)
node2 = cluster.add_instance('node2', main_configs=['configs/notleader.xml'], with_zookeeper=True)
node3 = cluster.add_instance('node3', main_configs=['configs/notleader.xml'], with_zookeeper=True)

nodes = [node1, node2, node3]

STRING_LENGTH = 5
UINT32 = 2**32


class DataBlock(object):

    def __init__(self, data, rate=0, helper_text="", burst=1300000):
        self._data = data
        self._len = len(data)
        self._rate = rate
        self._current_offset = 0
        self._helper_text = helper_text
        self._burst = burst

    def read(self, size):
        if self._rate and self._rate < size:
            datablock = self._rate
        else:
            datablock = size

        if self._burst and self._current_offset < self._burst:
            datablock = size

        if self._helper_text:
            print("{} OFFSET: {}".format(self._helper_text, self._current_offset))

        right_limit = self._current_offset+datablock
        if right_limit >= self._len:
            right_limit = self._len
        data_to_send = self._data[self._current_offset:right_limit]
        self._current_offset = right_limit
        if self._current_offset > self._burst:
            time.sleep(1)
        if not data_to_send:
            return None
        return bytes(data_to_send, encoding='utf8')

    @property
    def len(self):
        return self._len


@pytest.fixture(scope="module")
def started_cluster():
    try:
        cluster.start()

        yield cluster

    finally:
        cluster.shutdown()


def get_random_string(length):
    return ''.join(random.choice(string.ascii_uppercase + string.digits) for _ in range(length))


def alter_table(node, delay=1, thread_number=1):
    i = 0
    while True:
        last_ex = ""
        try:
            print("THREAD({}) NODE ({}): ALTER data, starting attempt {}".format(thread_number, node.name, i))
            node.query("ALTER TABLE t MODIFY COLUMN IF EXISTS value UInt64")
            print("THREAD({}) NODE ({}): ALTER data, finished attempt {}".format(thread_number, node.name, i))
        except Exception as ex:
            last_ex = str(ex)
            print("THREAD({}) NODE ({}): ALTER data, errored attempt {}".format(thread_number, node.name, i))

        if last_ex and not (last_ex.find("Code: 517") != -1 or last_ex.find("Code: 210") != -1):
            assert False, "Expected to get 517 or 210 error code"

        i += 1
        time.sleep(delay)


def generate_data(volume=1):
    values = list()
    for i in range(volume):
        values.append("({},{},'{}')".format(i, random.randint(0, UINT32), ''))
    return ",".join(values)


def generate_insert_query(volume=1):
    return "INSERT INTO t VALUES {}".format(generate_data(volume))


def streamed_insert(node, volume=1, rate=1, thread_number=1, data=None):
    print("THREAD({}) NODE ({}): STREAMED INSERT data volume {}".format(thread_number, node.name, volume))
    # message = "THREAD({}) NODE ({}): STREAMED INSERT".format(thread_number, node.name)
    message = ""
    if data:
        db = DataBlock(data, rate, message)
    else:
        db = DataBlock(generate_data(volume), rate, message)
    last_ex = ""
    try:
        node.http_query("INSERT INTO t VALUES", data=db, params={'query_id': "insert_query_id_{}".format(thread_number)})
    except Exception as ex:
        last_ex = str(ex)

    if last_ex:
        assert last_ex.find("Code: 210") != -1, "Expected 210 error code"


def insert(node, volume=1, delay=1, thread_number=1):
    print("THREAD({}) NODE ({}): INSERT data volume {}".format(thread_number, node.name, volume))
    data = generate_insert_query(volume)

    def query():
        last_ex = ""
        try:
            node.query(data)
        except Exception as ex:
            last_ex = str(ex)

        if last_ex:
            assert last_ex.find("Code: 210") != -1, "Expected to 210 error code"

    if delay:
        while True:
            query()
            # last_ex = ""
            # try:
            #     node.query(data)
            # except Exception as ex:
            #     last_ex = str(ex)
            #
            # # Code: 210
            # # print(str(ex))
            time.sleep(delay)
    else:
        query()
        # node.query(data)


def select_from_table(node, delay=1, thread_number=1):
    while True:
        if int(node.query("select count() from system.mutations where is_done").strip()) > 0:
            print("THREAD({}) NODE ({}): Mutation is done".format(thread_number, node.name))
            return
        print("NODE ({}): parts count {}".format(node.name, node.query("select count() from system.parts").strip()))
        print("NODE ({}): replication queue {}".format(node.name, node.query("select count() from system.replication_queue").strip()))
        time.sleep(delay)


def create_table(node):
    node.query("CREATE TABLE t (key UInt64, value UInt32, data String) ENGINE = ReplicatedMergeTree('/clickhouse/test/t', '{}') ORDER BY tuple() PARTITION BY key%99".format(node.name))


def test_no_stall(started_cluster):
    # if nodes[0].is_built_with_sanitizer():
    pytest.skip("TODO(cloudflare): Flaky test. Improve or drop.")

    for node in nodes:
        create_table(node)
        node.query("SYSTEM STOP MERGES")

    # fill up tables with the data
    print("fill the table on both nodes")

    for node in nodes:
        insert(node, 100, 0)
        insert(node, 100, 0)

    for node in nodes:
        print("NODE ({}): stop fetches".format(node.name))
        node.query("SYSTEM STOP FETCHES t")

    print("add more data to both nodes")

    # generated data for streamed inserts
    streamed_data = generate_data(1000000)

    for node in nodes:
        insert(node, 100, 0)
        insert(node, 100, 0)
        insert(node, 100, 0)
        insert(node, 100, 0)

    for node in nodes:
        parts_total = node.query("SELECT count() FROM system.parts WHERE table = 't'").strip()
        print('NODE ({}): parts total - {}'.format(node.name, parts_total))
        print()

    with PartitionManager() as pm:
        # Make node1 very slow, node2 should replicate from node2 instead.
        pm.add_network_delay(node1, 6)
        pm.add_network_delay(node2, 1000)
        pm.add_network_delay(node3, 700)

        print("starting background threads on both nodes")

        foreground_threads = []
        threads = []
        slow_insert_threads = []
        for node in nodes:
            foreground_threads.append(threading.Thread(target=select_from_table, args=(node, 5, 1)))
            # send delayed insert with X b/s rate
            slow_insert_threads.append(threading.Thread(target=streamed_insert, daemon=True, args=(node, 1000000, 1000, 1, streamed_data)))
            slow_insert_threads.append(threading.Thread(target=streamed_insert, daemon=True, args=(node, 1000000, 2100, 2, streamed_data)))
            slow_insert_threads.append(threading.Thread(target=streamed_insert, daemon=True, args=(node, 1000000, 5100, 3, streamed_data)))
            # send concurrent inserts
            threads.append(threading.Thread(target=insert, daemon=True, args=(node, 20, 1, 1)))
            threads.append(threading.Thread(target=insert, daemon=True, args=(node, 20, 1.1, 2)))
            # send concurrent alters
            threads.append(threading.Thread(target=alter_table, daemon=True, args=(node, 1, 1)))
            threads.append(threading.Thread(target=alter_table, daemon=True, args=(node, 1.4, 2)))
            threads.append(threading.Thread(target=alter_table, daemon=True, args=(node, 1.7, 3)))

        # start fetches to load the network
        print("starting merges and fetches")
        for node in nodes:
            # insert_into_table(node, 100, 0)
            print("NODE ({}): start fetches".format(node.name))
            node.query("SYSTEM START FETCHES t")

        for node in nodes:
            print("NODE ({}): start merges".format(node.name))
            node.query("SYSTEM START MERGES")

        time.sleep(1)

        for t in foreground_threads:
            t.start()

        for t in slow_insert_threads:
            t.start()

        print("waiting for streamed inserters to start")
        time.sleep(20)

        for t in threads:
            t.start()

        print("waiting for background threads")
        time.sleep(10)
        print("disabling network delay on all nodes")
        pm.heal_all()

        for t in foreground_threads:
            t.join(60)

            assert not t.is_alive(), "waiting time for alter exceeded the expectations"

        print("cancelling the background threads")

        # since inserts are finished, we can stop inserts
        for t in slow_insert_threads+threads:
            t.join(1.0)

        for node in nodes:
            value_type = node.query("SELECT type FROM system.columns WHERE table = 't' and name = 'value'").strip()
            assert value_type == "UInt64", "got unexpected value type, alter was not applied on a node {} within the expected time".format(node.name)
