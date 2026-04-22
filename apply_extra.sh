#!/usr/bin/sh

set -e

bsdtar -Oxf edge.deb 'data.tar*' |
  bsdtar -xf - \
    --strip-components=4 \
    --exclude='./opt/microsoft/msedge-canary/nacl*' \
    ./opt/microsoft/msedge-canary
rm edge.deb

install -Dm755 /app/bin/stub_sandbox msedge-sandbox
