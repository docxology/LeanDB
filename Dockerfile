# A LeanDB base as a container: build the base's executable, ship only it.
#
#   docker build --build-arg BASE=tickets -t leandb-tickets .
#   docker run -p 7411:7411 -v tickets-data:/data -e LEANDB_TOKEN=s3cret leandb-tickets
#
# Every example under examples/<BASE> works (kernels requires gpumarket by
# path, so the whole examples tree is copied). The instance lives in the
# /data volume (LEANDB_DB); the server binds 0.0.0.0 inside the container,
# so set LEANDB_TOKEN (or pass --auth-token) before publishing the port.

FROM ubuntu:24.04 AS build
ARG BASE=tickets
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
      curl git ca-certificates build-essential \
    && rm -rf /var/lib/apt/lists/*
RUN curl -sSf https://raw.githubusercontent.com/leanprover/elan/master/elan-init.sh \
    | sh -s -- -y --default-toolchain none
ENV PATH=/root/.elan/bin:$PATH
WORKDIR /src
# the engine (a path dependency of every example) and the examples
COPY lean-toolchain lakefile.toml lake-manifest.json LeanDb.lean Main.lean ./
COPY LeanDb ./LeanDb
COPY examples ./examples
RUN cd examples/${BASE} && lake build ${BASE}

FROM ubuntu:24.04
ARG BASE=tickets
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates libgmp10 curl tzdata \
    && rm -rf /var/lib/apt/lists/*
COPY --from=build /src/examples/${BASE}/.lake/build/bin/${BASE} /usr/local/bin/base
VOLUME /data
ENV LEANDB_DB=/data/base.sqlite
EXPOSE 7411
HEALTHCHECK --interval=30s --timeout=3s CMD curl -sf http://127.0.0.1:7411/healthz || exit 1
ENTRYPOINT ["/usr/local/bin/base"]
CMD ["serve", "--http", "7411", "--bind", "0.0.0.0"]
