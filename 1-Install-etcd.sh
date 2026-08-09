#!/bin/bash

# This script is used to set up the general settings and install packages for the project.

set -e

# Update and upgrade the system
sudo apt-get update
sudo apt-get upgrade -y

# Install necessary packages
curl wget vim net-tools
sudo apt-get install -y git curl wget build-essential vim net-tools


# change the /etc/hosts file on evry VM on the single site for example:
sudo tee -a /etc/hosts <<EOF
10.0.0.4 pg-node1
10.0.0.5 pg-node2
10.0.0.6 pg-node3
10.0.0.7 pg-node4
10.0.0.8 pg-node5
EOF

# --------------- Please make sure to change the version of ETCD to suitable version  -----------------
ETCD_VER=v3.7.1
wget https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
tar xzvf etcd-${ETCD_VER}-linux-amd64.tar.gz
sudo mv etcd-${ETCD_VER}-linux-amd64/etcd /usr/local/bin/
sudo mv etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
sudo mkdir -p /var/lib/etcd


# ----------------- the config file for etcd (different values for each VM) -----------------
# Create the directory for the etcd configuration file
sudo mkdir -p /etc/etcd

# ⚠️ The initial-cluster line must be the same in all files (defines the 5 members).
# Create the file at /etc/etcd/etcd.conf.yml — change the name and IP for each node:
sudo tee /etc/etcd/etcd.conf.yml <<EOF
name: pg-node1
data-dir: /var/lib/etcd
initial-advertise-peer-urls: http://10.0.0.4:2380
listen-peer-urls: http://10.0.0.4:2380
listen-client-urls: http://10.0.0.4:2379,http://127.0.0.1:2379
advertise-client-urls: http://10.0.0.4:2379
initial-cluster: pg-node1=http://10.0.0.4:2380,pg-node2=http://10.0.0.5:2380,pg-node3=http://10.0.0.6:2380,pg-node4=http://10.0.0.7:2380,pg-node5=http://10.0.0.8:2380
initial-cluster-token: pg-etcd-cluster
initial-cluster-state: new
EOF

# on other nodes: same file with the same content, but change the first 4 lines to the IP of the respective node and the name.



#  Create systemd service 

sudo tee /etc/systemd/system/etcd.service <<EOF
[Unit]
Description=etcd key-value store
After=network.target

[Service]
Type=notify
ExecStart=/usr/local/bin/etcd --config-file /etc/etcd/etcd.conf.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF


# ⚠️ Start the 5 services in all VMs in same time (or as close as possible) to avoid connection issues between nodes.
sudo systemctl daemon-reload
sudo systemctl enable --now etcd


# Make sure that cluster configure correctly from any node:
# You should see 5 members, and one of them should have isLeader=true.
etcdctl --endpoints=http://10.0.0.4:2379,http://10.0.0.5:2379,http://10.0.0.6:2379,http://10.0.0.7:2379,http://10.0.0.8:2379 endpoint status --write-out=table