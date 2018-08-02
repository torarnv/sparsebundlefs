FROM ubuntu:16.04

ARG arch

RUN dpkg --add-architecture $arch && \
	apt-get update && \
	apt-get install -y \
		build-essential \
		g++-multilib \
		pkg-config:$arch \
		libfuse-dev:$arch \
		fuse:$arch
