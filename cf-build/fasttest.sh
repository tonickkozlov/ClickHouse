#!/bin/bash

# Adapted from docker/test/stateless
# Changes:
#   * Remove repo/submodule cloning as this runs in TeamCity after repository
#     is cloned.
#   * pkill `programs/clickhouse-server` instead of `clickhouse-server` to avoid
#     killing cfsetup runner.
#   * ccache integration + s3 storage

set -xeu
set -o pipefail
trap "exit" INT TERM
trap 'kill $(jobs -pr) ||:' EXIT

# This script is separated into two stages, cloning and everything else, so
# that we can run the "everything else" stage from the cloned source.
stage=${stage:-}

# Compiler version, normally set by Dockerfile
export LLVM_VERSION=${LLVM_VERSION:-11}

# A variable to pass additional flags to CMake.
# Here we explicitly default it to nothing so that bash doesn't complain about
# it being undefined. Also read it as array so that we can pass an empty list
# of additional variable to cmake properly, and it doesn't generate an extra
# empty parameter.
read -ra FASTTEST_CMAKE_FLAGS <<< "${FASTTEST_CMAKE_FLAGS:-}"

# Run only matching tests.
FASTTEST_FOCUS=${FASTTEST_FOCUS:-""}

FASTTEST_WORKSPACE="/cfsetup_build/clickhouse/build_fasttest"
FASTTEST_SOURCE="/cfsetup_build/clickhouse"
FASTTEST_BUILD="$FASTTEST_WORKSPACE/build"
FASTTEST_DATA="$FASTTEST_WORKSPACE/db"
FASTTEST_OUTPUT="$FASTTEST_WORKSPACE/out"
PATH="$FASTTEST_BUILD/programs:$FASTTEST_SOURCE/tests:$PATH"

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
export PATH

server_pid=none

function stop_server
{
    if ! kill -0 -- "$server_pid"
    then
        echo "ClickHouse server pid '$server_pid' is not running"
        return 0
    fi

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
    local opts=(
        --config-file "$FASTTEST_DATA/config.xml"
        --
        --path "$FASTTEST_DATA"
        --user_files_path "$FASTTEST_DATA/user_files"
        --top_level_domains_path "$FASTTEST_DATA/top_level_domains"
        --keeper_server.storage_path "$FASTTEST_DATA/coordination"
    )
    clickhouse-server "${opts[@]}" &>> "$FASTTEST_OUTPUT/server.log" &
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

    echo "
set follow-fork-mode child
handle all noprint
handle SIGSEGV stop print
handle SIGBUS stop print
handle SIGABRT stop print
continue
thread apply all backtrace
continue
" > script.gdb

    gdb -batch -command script.gdb -p "$server_pid" &
}

function run_cmake
{
    CMAKE_LIBS_CONFIG=(
        "-DENABLE_LIBRARIES=0"
        "-DENABLE_TESTS=0"
        "-DENABLE_UTILS=0"
        "-DENABLE_EMBEDDED_COMPILER=0"
        "-DENABLE_THINLTO=0"
        "-DUSE_UNWIND=1"
        "-DENABLE_NURAFT=1"
    )

    export CCACHE_BASEDIR="$FASTTEST_SOURCE"
    export CCACHE_NOHASHDIR=true
    export CCACHE_COMPILERCHECK=content
    export CCACHE_MAXSIZE=25G

    if [[ -n "$CCACHE_ACCESS_KEY" ]]; then
      mkdir -p "$HOME/.ccache"
      export CCACHE_DIR="$HOME/.ccache"

      export S3_CCACHE_KEY_SUFFIX="fasttest"
      mkdir -p $HOME/.aws
      python3 $FASTTEST_SOURCE/cf-build/ccache_utils.py download
    else
      export CCACHE_DIR="$FASTTEST_WORKSPACE/ccache"
    fi

    ccache --show-stats ||:
    ccache --zero-stats ||:

    mkdir "$FASTTEST_BUILD" ||:

    (
        cd "$FASTTEST_BUILD"
        cmake "$FASTTEST_SOURCE" -DCMAKE_CXX_COMPILER="clang++-${LLVM_VERSION}" -DCMAKE_C_COMPILER="clang-${LLVM_VERSION}" "${CMAKE_LIBS_CONFIG[@]}" "${FASTTEST_CMAKE_FLAGS[@]}" 2>&1 | ts '%Y-%m-%d %H:%M:%S' | tee "$FASTTEST_OUTPUT/cmake_log.txt"
    )
}

build_start_time=$(date +%s)
upload_ccache_done=0

function upload_ccache
{
  build_duration=$(date +%s)-$build_start_time
  if [[ -n "$CCACHE_ACCESS_KEY" && "$upload_ccache_done" -ne "1" ]]; then
    # Upload updated cache only if we spent a considerable amount of time building it.
    # Otherwise we'll just spend 10 minutes uploading 10-15GB of cache without any
    # benefit for subsequent builds.
    if [[ $build_duration -gt 600 ]]; then
      # Trim the cache before uploading.
      # https://ccache.dev/manual/4.2.html#_manual_cleanup
      export CCACHE_MAXSIZE=6G
      ccache --cleanup && ccache --show-stats
      python3 $FASTTEST_SOURCE/cf-build/ccache_utils.py upload
    fi
  fi

  upload_ccache_done=1
}

function build
{
    # Always try to upload ccache, even on failures
    trap upload_ccache ERR EXIT RETURN

    (
        cd "$FASTTEST_BUILD"
        time ninja clickhouse-bundle 2>&1 | ts '%Y-%m-%d %H:%M:%S' | tee "$FASTTEST_OUTPUT/build_log.txt"
        ccache --show-stats ||:
    )
}

function configure
{
    clickhouse-client --version
    clickhouse-test --help

    mkdir -p "$FASTTEST_DATA"{,/client-config}
    cp -a "$FASTTEST_SOURCE/programs/server/"{config,users}.xml "$FASTTEST_DATA"
    "$FASTTEST_SOURCE/tests/config/install.sh" "$FASTTEST_DATA" "$FASTTEST_DATA/client-config"
    cp -a "$FASTTEST_SOURCE/programs/server/config.d/log_to_console.xml" "$FASTTEST_DATA/config.d"
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
      "_cf_no_tests_to_skip"
    )

    set +e
    time clickhouse-test --hung-check -j 8 --order=random \
            --fast-tests-only --no-long --testname --shard --zookeeper --check-zookeeper-session \
            --skip "${TESTS_TO_SKIP[@]}" \
            -- "$FASTTEST_FOCUS" 2>&1 \
        | ts '%Y-%m-%d %H:%M:%S' \
        | tee "$FASTTEST_OUTPUT/test_result.txt"
    set -e
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
    # The `install_log.txt` is also needed for compatibility with old CI task --
    # if there is no log, it will decide that build failed.
    configure 2>&1 | ts '%Y-%m-%d %H:%M:%S' | tee "$FASTTEST_OUTPUT/install_log.txt"
    ;&
"run_tests")
    run_tests
    ;;
*)
    echo "Unknown test stage '$stage'"
    exit 1
esac

pstree -apgT
jobs
