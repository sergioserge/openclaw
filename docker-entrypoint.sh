#!/bin/sh
set -e

# Fix ownership of the bind-mounted config dir so the 'node' user (uid 1000)
# can read and write it. This handles the case where files were written on the
# host as root, which silently resets ownership to uid 0.
chown -R node:node /home/node/.openclaw 2>/dev/null || true

# Drop from root to node and exec the gateway (or whatever CMD was given).
exec runuser -u node -- "$@"
