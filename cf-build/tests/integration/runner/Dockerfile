ARG CLOUDFLARE_DOCKER_REGISTRY_HOST=registry.cfdata.org
FROM ${CLOUDFLARE_DOCKER_REGISTRY_HOST}/stash/cf/debian-images/buster/main:2021.4.0

# python3-dev build-essential libkrb5-dev are for requests-kerberos

COPY docker_mirror.txt /etc/apt/
RUN echo "deb [trusted=yes] mirror+file:/etc/apt/docker_mirror.txt buster stable" >> /etc/apt/sources.list

RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get -y install \
        python3-dev build-essential libkrb5-dev \
        docker-ce \
        iproute2 \
        iptables \
        kmod \
        python3 \
        python3-pip \
        python3-setuptools \
        python3-wheel && \
    /build/cleanup.sh

RUN pip3 install --upgrade pip

RUN pip3 install install \
        avro \
        PyMySQL==0.10.1 \
        cassandra-driver \
        confluent-kafka==1.5.0 \
        dict2xml \
        dicttoxml \
        docker \
        docker-compose==1.28.2 \
        kafka-python \
        kazoo \
        minio==6.0.2 \
        psycopg2==2.7.5 \
        pymongo \
        pytest \
        pytest-timeout \
        requests-kerberos \
        tzlocal \
        urllib3

COPY misc/ /misc/
