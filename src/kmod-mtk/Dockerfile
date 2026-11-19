FROM ubuntu:20.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq && apt-get install -y -qq gcc-arm-linux-gnueabi binutils-arm-linux-gnueabi make bc flex bison perl python3 libssl-dev zstd curl ca-certificates file kmod >/dev/null && rm -rf /var/lib/apt/lists/*
