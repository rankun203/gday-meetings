FROM rust:1.86-slim AS builder

WORKDIR /app
RUN apt-get update && apt-get install -y pkg-config && rm -rf /var/lib/apt/lists/*

COPY Cargo.toml Cargo.lock* ./
COPY src/ src/

RUN cargo build --release

FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

COPY --from=builder /app/target/release/file-drop /usr/local/bin/file-drop

ENV STORAGE_DIR=/data/storage

RUN mkdir -p /data/storage

EXPOSE 8199

ENTRYPOINT ["file-drop"]
CMD ["--storage-dir", "/data/storage"]
