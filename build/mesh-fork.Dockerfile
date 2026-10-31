FROM rust:1.95.0-bookworm@sha256:6258907abe69656e41cd992e0b705cdcfabcbbe3db374f92ed2d47121282d4a1
RUN sed -i 's|http://deb.debian.org|https://mirrors.cloud.tencent.com|g' /etc/apt/sources.list.d/debian.sources \
    && apt-get update && apt-get install -y --no-install-recommends \
    clang lld llvm cmake pkg-config protobuf-compiler python3-pip \
    && rm -rf /var/lib/apt/lists/*
RUN printf '%s\n' 'ziglang==0.15.2 --hash=sha256:edc0aa60ec964a4cf462d40f68d7de242ddf37fd9a80f2afaee6397059463230 --hash=sha256:806316453d1ede7174ed3fefb8e5348154629089c3bb5fe812dfd0e172fac130' > /tmp/zig-requirements.txt \
    && pip3 install --break-system-packages --no-cache-dir --require-hashes \
       --index-url https://mirrors.cloud.tencent.com/pypi/simple -r /tmp/zig-requirements.txt
RUN printf '%s\n' '[source.crates-io]' 'replace-with = "rsproxy"' '[source.rsproxy]' 'registry = "sparse+https://rsproxy.cn/index/"' > /usr/local/cargo/config.toml \
    && cargo install --locked cargo-zigbuild --version 0.24.0 \
    && cargo install --locked cargo-xwin --version 0.23.1
RUN RUSTUP_DIST_SERVER=https://rsproxy.cn rustup target add x86_64-unknown-linux-musl x86_64-pc-windows-msvc
RUN apt-get update -qq && apt-get install -y --no-install-recommends libprotobuf-dev ninja-build \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
