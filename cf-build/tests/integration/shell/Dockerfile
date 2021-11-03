# Do not want to allow access to Cloudflare registry from the DinD.
FROM debian:buster

ENV DEBIAN_FRONTEND=noninteractive LLVM_VERSION=12

RUN apt-get update && apt-get install --yes wget gnupg && \
    wget -nv -O /tmp/llvm-snapshot.gpg.key https://apt.llvm.org/llvm-snapshot.gpg.key && \
    echo "bda960a8da687a275a2078d43c111d66b1c6a893a3275271beedf266c1ff4a0cdecb429c7a5cccf9f486ea7aa43fd27f /tmp/llvm-snapshot.gpg.key" | sha384sum -c && \
    apt-key add --armor /tmp/llvm-snapshot.gpg.key && \
    echo "deb [trusted=yes] https://apt.llvm.org/buster/ llvm-toolchain-buster-12 main" >> /etc/apt/sources.list && \
    apt-get update && \
    apt-get install --yes --no-install-recommends \
        llvm-$LLVM_VERSION \
        lsof \
        procps \
        python3 \
        iptables && \
    rm -rf \
        /var/lib/apt/lists/* \
        /var/cache/debconf \
        /tmp/* && \
    apt-get clean


# Sanitizer options for services (clickhouse-server)
RUN echo "TSAN_OPTIONS='verbosity=1000 halt_on_error=1 history_size=7 suppressions=/clickhouse/cf-build/tests/tsan_suppressions.txt''" >> /etc/environment; \
  echo "UBSAN_OPTIONS='print_stacktrace=1'" >> /etc/environment; \
  echo "MSAN_OPTIONS='abort_on_error=1 poison_in_dtor=1'" >> /etc/environment; \
  ln -s /usr/lib/llvm-${LLVM_VERSION}/bin/llvm-symbolizer /usr/bin/llvm-symbolizer;

# Sanitizer options for current shell (not current, but the one that will be spawned on "docker run")
# (but w/o verbosity for TSAN, otherwise test.reference will not match)
ENV TSAN_OPTIONS='halt_on_error=1 history_size=7'
ENV UBSAN_OPTIONS='print_stacktrace=1'
ENV MSAN_OPTIONS='abort_on_error=1 poison_in_dtor=1'
