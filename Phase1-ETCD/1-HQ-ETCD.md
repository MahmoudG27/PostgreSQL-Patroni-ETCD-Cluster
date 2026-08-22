# PostgreSQL Cluster — VM & etcd Setup Guide

This guide describes how to prepare the VMs and configure a **5-node etcd cluster** that will be used by the PostgreSQL cluster.

> **Important:**
> The configuration below assumes that there are **5 VMs** with the following hostnames and IP addresses:
>
> | Node   | Hostname     | IP Address |
> | ------ | ------------ | ---------- |
> | Node 1 | `hq-node-01` | `10.0.0.4` |
> | Node 2 | `hq-node-02` | `10.0.0.5` |
> | Node 3 | `hq-node-03` | `10.0.0.6` |
> | Node 4 | `hq-node-04` | `10.0.0.7` |
> | Node 5 | `hq-node-05` | `10.0.0.8` |

---

## 1. System Preparation

Run the following commands on **all VMs**.

### Update and upgrade the system

```bash
sudo apt-get update
sudo apt-get upgrade -y
```

### Install required packages

```bash
sudo apt-get install -y git curl wget build-essential vim net-tools
```

---

## 2. Configure `/etc/hosts`

Each VM needs to be able to resolve the other nodes by hostname.

Add the following entries to `/etc/hosts` on **all VMs**:

```text
10.0.0.4 hq-node-01
10.0.0.5 hq-node-02
10.0.0.6 hq-node-03
10.0.0.7 hq-node-04
10.0.0.8 hq-node-05
```

You can add them using:

```bash
sudo tee -a /etc/hosts <<EOF
10.0.0.4 hq-node-01
10.0.0.5 hq-node-02
10.0.0.6 hq-node-03
10.0.0.7 hq-node-04
10.0.0.8 hq-node-05
EOF
```

### Verify hostname resolution

Run:

```bash
getent hosts hq-node-01
getent hosts hq-node-02
getent hosts hq-node-03
getent hosts hq-node-04
getent hosts hq-node-05
```

You should see the corresponding IP address for each hostname.

---

# 3. Install etcd

> **Important:** Make sure the etcd version is compatible with the rest of your project before installation.

For this setup, we use:

```bash
ETCD_VER=v3.7.1
```

Download the etcd release:

```bash
wget https://github.com/etcd-io/etcd/releases/download/${ETCD_VER}/etcd-${ETCD_VER}-linux-amd64.tar.gz
```

Extract the archive:

```bash
tar xzvf etcd-${ETCD_VER}-linux-amd64.tar.gz
```

Install `etcd` and `etcdctl`:

```bash
sudo mv etcd-${ETCD_VER}-linux-amd64/etcd /usr/local/bin/
sudo mv etcd-${ETCD_VER}-linux-amd64/etcdctl /usr/local/bin/
```

Create the etcd data directory:

```bash
sudo mkdir -p /var/lib/etcd
```

### Verify the installation

```bash
etcd --version
etcdctl version
```

### Run ETCD as User

```bash
sudo useradd -r -s /usr/sbin/nologin etcd
```

---

# 4. Create the etcd Configuration Directory

Run:

```bash
sudo mkdir -p /etc/etcd
```

The etcd configuration file will be:

```text
/etc/etcd/etcd.conf.yml
```

---

# 5. Configure the etcd Cluster

The cluster contains **5 etcd members**:

```text
hq-node-01 = 10.0.0.4
hq-node-02 = 10.0.0.5
hq-node-03 = 10.0.0.6
hq-node-04 = 10.0.0.7
hq-node-05 = 10.0.0.8
```

## Important Configuration Rules

### `initial-cluster`

The `initial-cluster` value must be **exactly the same on all five VMs**.

It defines all members that belong to the cluster:

```text
hq-node-01=http://10.0.0.4:2380
hq-node-02=http://10.0.0.5:2380
hq-node-03=http://10.0.0.6:2380
hq-node-04=http://10.0.0.7:2380
hq-node-05=http://10.0.0.8:2380
```

### Node-specific values

The following values must be changed according to the VM:

* `name`
* `initial-advertise-peer-urls`
* `listen-peer-urls`
* `listen-client-urls`
* `advertise-client-urls`

---

# 6. Configure etcd on All Nodes

On **each VM**, create the configuration file:

```bash
sudo vim /etc/etcd/etcd.conf.yml
```

Paste the following template, but ensure you change <NODE_NAME> and <NODE_IP> to match the specific VM you are configuring:

```yaml
name: <NODE_NAME>

data-dir: /var/lib/etcd

initial-advertise-peer-urls: http://<NODE_IP>:2380
listen-peer-urls: http://<NODE_IP>:2380

listen-client-urls: http://<NODE_IP>:2379,http://127.0.0.1:2379
advertise-client-urls: http://<NODE_IP>:2379

# This line remains EXACTLY the same on all 5 nodes
initial-cluster: hq-node-01=http://10.0.0.4:2380,hq-node-02=http://10.0.0.5:2380,hq-node-03=http://10.0.0.6:2380,hq-node-04=http://10.0.0.7:2380,hq-node-05=http://10.0.0.8:2380

initial-cluster-token: pg-etcd-hq-cluster
initial-cluster-state: new
```

Example for Node 1: Replace <NODE_NAME> with hq-node-01 and <NODE_IP> with 10.0.0.4.

Set the right permissions to directory and conf etcd file

```bash
sudo chown -R root:etcd /etc/etcd
sudo chmod 750 /etc/etcd
sudo chmod 640 /etc/etcd/etcd.conf.yml
sudo chown -R etcd:etcd /var/lib/etcd
sudo chmod 700 /var/lib/etcd
```
---

# 7. Create the systemd Service

Create the service file on **all VMs**:

```text
/etc/systemd/system/etcd.service
```

Use:

```ini
[Unit]
Description=etcd key-value store
After=network.target

[Service]
Type=notify
User=etcd
Group=etcd
ExecStart=/usr/local/bin/etcd --config-file /etc/etcd/etcd.conf.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
```

Create it with:

```bash
sudo tee /etc/systemd/system/etcd.service <<EOF
[Unit]
Description=etcd key-value store
After=network.target

[Service]
Type=notify
User=etcd
Group=etcd
ExecStart=/usr/local/bin/etcd --config-file /etc/etcd/etcd.conf.yml
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
```

---

# 8. Start etcd

Reload systemd:

```bash
sudo systemctl daemon-reload
```

Enable etcd to start automatically at boot and start it now:

```bash
sudo systemctl enable --now etcd
```

Check the service status:

```bash
sudo systemctl status etcd
```

You should see:

```text
Active: active (running)
```

---

# 9. Important: Start All Nodes Together

Start all five members using the same initial-cluster configuration. They may be started sequentially or in parallel, provided network connectivity between all members is available.

The five nodes are:

```text
hq-node-01 → 10.0.0.4
hq-node-02 → 10.0.0.5
hq-node-03 → 10.0.0.6
hq-node-04 → 10.0.0.7
hq-node-05 → 10.0.0.8
```

This helps avoid initial cluster formation and connection issues.

---

# 10. Verify the etcd Cluster

From any node, run:

```bash
etcdctl --endpoints=http://10.0.0.4:2379,http://10.0.0.5:2379,http://10.0.0.6:2379,http://10.0.0.7:2379,http://10.0.0.8:2379 endpoint status --write-out=table
etcdctl --endpoints=http://10.0.0.4:2379,http://10.0.0.5:2379,http://10.0.0.6:2379,http://10.0.0.7:2379,http://10.0.0.8:2379 endpoint status --cluster --write-out=table
```

A healthy cluster should show **5 members**.

One of the members should have:

```text
IS LEADER = true
```

Example:

```text
+-------------------------+------------------+---------+---------+-----------+
|        ENDPOINT         |        ID        | VERSION | DB SIZE | IS LEADER |
+-------------------------+------------------+---------+---------+-----------+
| 10.0.0.4:2379           | ...              | 3.7.1   | ...     | false     |
| 10.0.0.5:2379           | ...              | 3.7.1   | ...     | true      |
| 10.0.0.6:2379           | ...              | 3.7.1   | ...     | false     |
| 10.0.0.7:2379           | ...              | 3.7.1   | ...     | false     |
| 10.0.0.8:2379           | ...              | 3.7.1   | ...     | false     |
+-------------------------+------------------+---------+---------+-----------+
```

> The actual IDs, database size, and leader node will be different.

---

# 11. Verify Cluster Membership

You can also check the members using:

```bash
etcdctl --endpoints=http://10.0.0.4:2379,http://10.0.0.5:2379,http://10.0.0.6:2379,http://10.0.0.7:2379,http://10.0.0.8:2379 member list --write-out=table
```

You should see all five members:

```text
hq-node-01
hq-node-02
hq-node-03
hq-node-04
hq-node-05
```

---

# 12. Troubleshooting

## Check etcd service

```bash
sudo systemctl status etcd
```

## Check etcd logs

```bash
sudo journalctl -u etcd -f
```

Or show recent logs:

```bash
sudo journalctl -u etcd --no-pager -n 100
```

## Check listening ports

etcd uses:

| Port   | Purpose                    |
| ------ | -------------------------- |
| `2379` | Client communication       |
| `2380` | Peer-to-peer communication |

Check them with:

```bash
sudo ss -lntp | grep -E '2379|2380'
```

## Test network connectivity

From one VM, test the other nodes:

```bash
ping -c 3 hq-node-01
ping -c 3 hq-node-02
ping -c 3 hq-node-03
ping -c 3 hq-node-04
ping -c 3 hq-node-05
```

You can also test the etcd ports:

```bash
nc -zv 10.0.0.4 2379
nc -zv 10.0.0.4 2380
```

Repeat for the other nodes if necessary.

---

# 13. Final Checklist

Before moving to the next stage of the PostgreSQL cluster setup, verify:

* [ ] All 5 VMs can resolve each other using `/etc/hosts`.
* [ ] `etcd` is installed on all VMs.
* [ ] `etcdctl` is installed and working.
* [ ] `/etc/etcd/etcd.conf.yml` exists on every VM.
* [ ] Each node has the correct `name`.
* [ ] Each node has the correct IP address.
* [ ] `initial-cluster` is identical on all 5 nodes.
* [ ] `initial-cluster-token` is identical on all 5 nodes.
* [ ] `initial-cluster-state` is set to `new` for the initial cluster creation.
* [ ] `etcd.service` exists on all VMs.
* [ ] The etcd service is running on all 5 VMs.
* [ ] Port `2379` is reachable between the required clients and etcd nodes.
* [ ] Port `2380` is reachable between all etcd peers.
* [ ] `etcdctl endpoint status` shows all 5 members.
* [ ] Exactly one member is reported as the leader.

---

# 14. Quick Verification Command

The main command to verify the cluster is:

```bash
etcdctl --endpoints=http://10.0.0.4:2379,http://10.0.0.5:2379,http://10.0.0.6:2379,http://10.0.0.7:2379,http://10.0.0.8:2379 endpoint status --write-out=table
```

If all five endpoints are healthy and one node is the leader, the etcd cluster is successfully configured.
