#!/bin/bash

set -e

# Update and upgrade the system
sudo apt update
sudo apt upgrade -y

# Install HAProxy
sudo apt install haproxy -y
haproxy -v

# Enable and start the HAProxy service
sudo systemctl enable --now haproxy

# Backup the original HAProxy configuration file
sudo cp /etc/haproxy/haproxy.cfg /etc/haproxy/haproxy.cfg.backup

sudo tee /etc/haproxy/haproxy.cfg > /dev/null <<EOF
global
    log /dev/log local0
    log /dev/log local1 notice
    daemon

    maxconn 4096


defaults
    log global
    mode tcp

    timeout connect 5s
    timeout client 30m
    timeout server 30m

    option tcplog


frontend postgres_write
    bind *:5432

    default_backend postgres_primary


backend postgres_primary
    mode tcp

    option httpchk GET /primary
    http-check expect status 200

    server pg01 10.0.0.4:5432 check port 8008
    server pg02 10.0.0.5:5432 check port 8008
    server pg03 10.0.0.6:5432 check port 8008


# ---------------------------------------------------------------------
# Added: Stats page (used by haproxy_exporter / Prometheus monitoring)
# Exposes connection counts and per-backend-server health on port 8404.
# ---------------------------------------------------------------------
frontend stats
    bind *:8404
    mode http
    stats enable
    stats uri /stats
    stats refresh 10s
EOF

# Validate the HAProxy configuration
sudo haproxy -c -f /etc/haproxy/haproxy.cfg

# Restart the HAProxy service to apply the new configuration
sudo systemctl restart haproxy


# ---------------------------------------------------------------------
# Added: enable HAProxy logging via rsyslog
# Ubuntu does not route the "local0" facility to a file by default,
# so without this, the "log /dev/log local0" line above produces
# nothing visible. This writes HAProxy logs to /var/log/haproxy.log.
# ---------------------------------------------------------------------
sudo tee /etc/rsyslog.d/49-haproxy.conf > /dev/null <<EOF
local0.*    /var/log/haproxy.log
EOF

sudo systemctl restart rsyslog

# Check the logs after that with:
# sudo tail -f /var/log/haproxy.log