FROM docker-registry.cfdata.org/stash/plat/dockerfiles/debian-buster/master:2020.3.0

ARG version

# * jq is needed for some dictionaries
# * odbc is needed for some postgresql dictionaries like cf_zone
RUN apt-get update && \
    apt-get -y install \
        clickhouse-server=${version} \
        clickhouse-common-static=${version} \
        clickhouse-client=${version} \
        jq \
        python-requests \
        unixodbc \
        odbcinst \
        odbc-postgresql \
        unzip && \
    # workaround to bind odbc config by using directory https://jira.cfops.it/browse/COREPLAT-1159
    mkdir -p /etc/odbc/ && \
    mv /etc/odbc.ini /etc/odbc/odbc.ini && \
    ln -fs /etc/odbc/odbc.ini /etc/odbc.ini && \
    /build/cleanup.sh

ENTRYPOINT ["/usr/bin/clickhouse-server", "--config=/etc/clickhouse-server/config.xml"]
