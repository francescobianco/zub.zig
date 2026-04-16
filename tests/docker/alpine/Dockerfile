FROM alpine:3.19

RUN apk add --no-cache \
    curl \
    tar \
    git \
    bash

RUN adduser -D -s /bin/bash testuser
USER testuser
WORKDIR /home/testuser

ENV HOME=/home/testuser
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
