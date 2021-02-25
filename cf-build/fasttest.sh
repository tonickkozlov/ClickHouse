#!/bin/bash
set -xeu
set -o pipefail
trap "exit" INT TERM
trap 'kill $(jobs -pr) ||:' EXIT

# This script is separated into two stages, cloning and everything else, so
# that we can run the "everything else" stage from the cloned source.
stage=${stage:-}

# A variable to pass additional flags to CMake.
# Here we explicitly default it to nothing so that bash doesn't complain about
# it being undefined. Also read it as array so that we can pass an empty list
# of additional variable to cmake properly, and it doesn't generate an extra
# empty parameter.
read -ra FASTTEST_CMAKE_FLAGS <<< "${FASTTEST_CMAKE_FLAGS:-}"



FASTTEST_WORKSPACE="/cfsetup_build/clickhouse/build_fasttest"
FASTTEST_SOURCE="/cfsetup_build/clickhouse"
FASTTEST_BUILD="$FASTTEST_WORKSPACE/build"
FASTTEST_DATA="$FASTTEST_WORKSPACE/db"
FASTTEST_OUTPUT="$FASTTEST_WORKSPACE/out"

CCACHE_ACCESS_KEY=${CCACHE_ACCESS_KEY:-}

# Cleanup previous run
rm -rf "$FASTTEST_DATA" "$FASTTEST_OUTPUT"
mkdir -p "$FASTTEST_BUILD" "$FASTTEST_DATA" "$FASTTEST_OUTPUT"

# Export these variables, so that all subsequent invocations of the script
# use them, and not try to guess them anew, which leads to weird effects.
export FASTTEST_WORKSPACE
export FASTTEST_SOURCE
export FASTTEST_BUILD
export FASTTEST_DATA
export FASTTEST_OUT

server_pid=none

function stop_server
{
    for _ in {1..60}
    do
        # Kill the binary, otherwise it matches the cfsetup command
        #   where we run `chown ... /var/lib/clickhouse`...
        if ! pkill -f "programs/clickhouse-server" && ! kill -- "$server_pid" ; then break ; fi
        sleep 1
    done

    if kill -0 -- "$server_pid"
    then
        pstree -apgT
        jobs
        echo "Failed to kill the ClickHouse server pid '$server_pid'"
        return 1
    fi

    server_pid=none
}

function start_server
{
    set -m # Spawn server in its own process groups
    clickhouse-server --config-file="$FASTTEST_DATA/config.xml" -- --path "$FASTTEST_DATA" --user_files_path "$FASTTEST_DATA/user_files" &>> "$FASTTEST_OUTPUT/server.log" &
    server_pid=$!
    set +m

    if [ "$server_pid" == "0" ]
    then
        echo "Failed to start ClickHouse server"
        # Avoid zero PID because `kill` treats it as our process group PID.
        server_pid="none"
        return 1
    fi

    for _ in {1..60}
    do
        if clickhouse-client --query "select 1" || ! kill -0 -- "$server_pid"
        then
            break
        fi
        sleep 1
    done

    if ! clickhouse-client --query "select 1"
    then
        echo "Failed to wait until ClickHouse server starts."
        server_pid="none"
        return 1
    fi

    if ! kill -0 -- "$server_pid"
    then
        echo "Wrong clickhouse server started: PID '$server_pid' we started is not running, but '$(pgrep -f clickhouse-server)' is running"
        server_pid="none"
        return 1
    fi

    echo "ClickHouse server pid '$server_pid' started and responded"
}

function run_cmake
{
CMAKE_LIBS_CONFIG=("-DENABLE_LIBRARIES=0" "-DENABLE_TESTS=0" "-DENABLE_UTILS=0" "-DENABLE_EMBEDDED_COMPILER=0" "-DENABLE_THINLTO=0" "-DUSE_UNWIND=1")

export CCACHE_BASEDIR="$FASTTEST_SOURCE"
export CCACHE_NOHASHDIR=true
export CCACHE_COMPILERCHECK=content
export CCACHE_MAXSIZE=25G

# cfsetup --ccache mounts a global ccache there
#   use it if exists
if [ -d "/.ccache" ]; then
  export CCACHE_DIR="/.ccache"
elif [[ -n "$CCACHE_ACCESS_KEY" ]]; then
  mkdir -p "$HOME/.ccache"
  export CCACHE_DIR="$HOME/.ccache"
  export CCACHE_MAXSIZE=10G

  export S3_CCACHE_KEY_SUFFIX="fasttest"
  mkdir -p $HOME/.aws
  python3 $FASTTEST_SOURCE/cf-build/ccache_utils.py download
else
  export CCACHE_DIR="$FASTTEST_WORKSPACE/ccache"
fi

ccache --show-stats ||:
ccache --zero-stats ||:

(
cd "$FASTTEST_BUILD"
cmake "$FASTTEST_SOURCE" -DCMAKE_CXX_COMPILER=clang++-10 -DCMAKE_C_COMPILER=clang-10 "${CMAKE_LIBS_CONFIG[@]}" "${FASTTEST_CMAKE_FLAGS[@]}" | ts '%Y-%m-%d %H:%M:%S' | tee "$FASTTEST_OUTPUT/cmake_log.txt"
)
}

function upload_ccache
{
  if [[ -n "$CCACHE_ACCESS_KEY" ]]; then
    python3 $FASTTEST_SOURCE/cf-build/ccache_utils.py upload
  fi
}

function build
{
(
cd "$FASTTEST_BUILD"

# Always try to upload ccache, even on failures
trap upload_ccache ERR EXIT

time ninja clickhouse-bundle | ts '%Y-%m-%d %H:%M:%S' | tee "$FASTTEST_OUTPUT/build_log.txt"
ccache --show-stats ||:
)
}

function configure
{
clickhouse-client --version
clickhouse-test --help

mkdir -p "$FASTTEST_DATA"{,/client-config}
cp -a "$FASTTEST_SOURCE/programs/server/"{config,users}.xml "$FASTTEST_DATA"
cp -a "$FASTTEST_SOURCE/programs/server/"{config,users}.xml "$FASTTEST_DATA"
"$FASTTEST_SOURCE/tests/config/install.sh" "$FASTTEST_DATA" "$FASTTEST_DATA/client-config"
# doesn't support SSL
rm -f "$FASTTEST_DATA/config.d/secure_ports.xml"

# teamcity agents resolve a host which they can't connect to
cat > "$FASTTEST_DATA/config.d/local_interserver.xml" << EOF
<yandex>
  <interserver_http_host>localhost</interserver_http_host>
</yandex>
EOF
}

function run_tests
{
clickhouse-server --version
clickhouse-test --help

# Kill the server in case we are running locally and not in docker
stop_server ||:

start_server

TESTS_TO_SKIP=(
    parquet
    avro
    h3
    odbc
    mysql
    sha256
    _orc_
    arrow
    01098_temporary_and_external_tables
    01083_expressions_in_engine_arguments
    hdfs
    00911_tautological_compare
    protobuf
    capnproto
    java_hash
    hashing
    secure
    00490_special_line_separators_and_characters_outside_of_bmp
    00436_convert_charset
    00105_shard_collations
    01354_order_by_tuple_collate_const
    01292_create_user
    01098_msgpack_format
    00929_multi_match_edit_distance
    00926_multimatch
    00834_cancel_http_readonly_queries_on_client_close
    brotli
    parallel_alter
    00302_http_compression
    00417_kill_query
    01294_lazy_database_concurrent
    01193_metadata_loading
    base64
    01031_mutations_interpreter_and_context
    json
    client
    01305_replica_create_drop_zookeeper
    01092_memory_profiler
    01355_ilike
    01281_unsucceeded_insert_select_queries_counter
    live_view
    limit_memory
    memory_limit
    memory_leak
    00110_external_sort
    00682_empty_parts_merge
    00701_rollup
    00109_shard_totals_after_having
    ddl_dictionaries
    01251_dict_is_in_infinite_loop
    01259_dictionary_custom_settings_ddl
    01268_dictionary_direct_layout
    01280_ssd_complex_key_dictionary
    00652_replicated_mutations_zookeeper
    01411_bayesian_ab_testing
    01238_http_memory_tracking              # max_memory_usage_for_user can interfere another queries running concurrently
    01281_group_by_limit_memory_tracking    # max_memory_usage_for_user can interfere another queries running concurrently

    # Not sure why these two fail even in sequential mode. Disabled for now
    # to make some progress.
    00646_url_engine
    00974_query_profiler

    # Look at DistributedFilesToInsert, so cannot run in parallel.
    01460_DistributedFilesToInsert
)

# to run only tests with the name pattern:
#
# time clickhouse-test -j 8 --no-long --testname --shard --zookeeper --skip "${TESTS_TO_SKIP[@]}" -- <pattern>
time clickhouse-test -j 8 --no-long --testname --shard --zookeeper --skip "${TESTS_TO_SKIP[@]}" 2>&1 | ts '%Y-%m-%d %H:%M:%S' | tee "$FASTTEST_OUTPUT/test_log.txt"

# substr is to remove semicolon after test name
readarray -t FAILED_TESTS < <(awk '/FAIL|TIMEOUT|ERROR/ { print substr($3, 1, length($3)-1) }' "$FASTTEST_OUTPUT/test_log.txt" | tee "$FASTTEST_OUTPUT/failed-parallel-tests.txt")

# We will rerun sequentially any tests that have failed during parallel run.
# They might have failed because there was some interference from other tests
# running concurrently. If they fail even in seqential mode, we will report them.
# FIXME All tests that require exclusive access to the server must be
# explicitly marked as `sequential`, and `clickhouse-test` must detect them and
# run them in a separate group after all other tests. This is faster and also
# explicit instead of guessing.
if [[ -n "${FAILED_TESTS[*]}" ]]
then
    stop_server ||:

    # Clean the data so that there is no interference from the previous test run.
    rm -rf "$FASTTEST_DATA"/{meta,}data ||:

    start_server

    echo "Going to run again: ${FAILED_TESTS[*]}"

    clickhouse-test --no-long --testname --shard --zookeeper "${FAILED_TESTS[@]}" 2>&1 | ts '%Y-%m-%d %H:%M:%S' | tee -a "$FASTTEST_OUTPUT/test_log.txt"
else
    echo "No failed tests"
fi
}

case "$stage" in
"")
    ls -la
    ;&
"run_cmake")
    run_cmake
    ;&
"build")
    build
    ;&
"configure")
    PATH="$FASTTEST_BUILD/programs:$FASTTEST_SOURCE/tests:$PATH"
    export PATH
    # The `install_log.txt` is also needed for compatibility with old CI task --
    # if there is no log, it will decide that build failed.
    configure | ts '%Y-%m-%d %H:%M:%S' | tee "$FASTTEST_OUTPUT/install_log.txt"
    ;&
"run_tests")
    run_tests
    ;&
esac

pstree -apgT
jobs