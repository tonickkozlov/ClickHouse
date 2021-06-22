#!/bin/bash

set -euxo pipefail

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

docker build -t yandex/clickhouse-integration-test ./cf-build/tests/integration/shell

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

# Action!
cd /clickhouse/tests/integration
pytest test_adaptive_granularity* test_part_moves_between_shards --maxfail=10 | tee /clickhouse/artifacts/test_result.txt
