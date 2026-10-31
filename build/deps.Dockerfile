FROM alpine:3.21@sha256:ee16d92f96db08d9d2d07da48555a27f3a69d8f0759021dbc601195ed0d2b5bd AS tools
RUN apk add --no-cache build-base linux-headers
WORKDIR /src
COPY wireguard-tools/ ./
RUN make -C src -j2 LDFLAGS=-static wg && mkdir -p /out/licenses \
    && cp src/wg /out/wg && cp COPYING /out/licenses/wireguard-tools.txt

FROM scratch
COPY --from=tools /out/ /
