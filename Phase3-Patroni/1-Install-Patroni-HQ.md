# Patroni Installation & PostgreSQL HA Setup

This guide installs **Patroni** in a Python virtual environment and configures it to manage a **PostgreSQL 18 High Availability cluster**.

The cluster consists of **5 PostgreSQL nodes**, with **etcd** used as the Distributed Configuration Store (DCS).

---

## Cluster Nodes

| Node         | IP Address | Role            |
| ------------ | ---------- | --------------- |
| `hq-node-01` | `10.0.0.4` | Initial Primary |
| `hq-node-02` | `10.0.0.5` | Replica         |
| `hq-node-03` | `10.0.0.6` | Replica         |
| `hq-node-04` | `10.0.0.7` | Replica         |
| `hq-node-05` | `10.0.0.8` | Replica         |

> **Important:** `hq-node-01` is only the **initial Primary**. Patroni is responsible for automatic failover, so another node can become Primary if `hq-node-01` fails.

---

## Directory Structure

The Patroni configuration is maintained as a separate file.

For example:

```text
.
├── patroni-install.sh
└── patroni.yml
```

The `patroni.yml` file currently contains the configuration example for:

```text
hq-node-01
```

Each node will need its own configuration file with the appropriate **node name and IP address**.

---

# 1. Install Patroni Dependencies

Install the required Python and PostgreSQL development packages:

```bash
sudo apt install -y \
  python3-pip \
  python3-venv \
  python3-dev \
  gcc \
  libpq-dev \
  python3-psycopg2
```

These packages provide the dependencies required to install and run Patroni and PostgreSQL's Python client libraries.

---

# 2. Create a Python Virtual Environment

Create a dedicated directory for Patroni:

```bash
sudo mkdir /opt/patroni
```

Create the Python virtual environment:

```bash
sudo python3 -m venv /opt/patroni
```

The Patroni virtual environment will be located at:

```text
/opt/patroni
```

---

# 3. Upgrade pip

Upgrade `pip` inside the Patroni virtual environment:

```bash
sudo /opt/patroni/bin/pip install --upgrade pip
```

---

# 4. Install Patroni

Install Patroni with the **etcd3** support:

```bash
sudo /opt/patroni/bin/pip install "patroni[etcd3]" psycopg2
```

The `etcd3` extra is required because Patroni will use **etcd** as its Distributed Configuration Store.

---

# 5. Verify Patroni Installation

Check the installed Patroni version:

```bash
/opt/patroni/bin/patroni --version
```

Example:

```text
Patroni X.Y.Z
```

You can also list all installed Python packages:

```bash
/opt/patroni/bin/pip list
```

---

## Optional: Upgrade Patroni

If Patroni needs to be upgraded:

```bash
sudo /opt/patroni/bin/pip install --upgrade patroni
```

Then verify the version again:

```bash
/opt/patroni/bin/patroni --version
```

---

## Optional: Remove the Virtual Environment

If you need to completely remove the Patroni virtual environment:

```bash
sudo rm -rf /opt/patroni
```

> **Warning:** This removes the Patroni installation and all Python packages inside the virtual environment.

---

# 6. Create an Alias for `patronictl`

To avoid typing the full Patroni configuration path every time, add the following alias to `~/.bashrc`:

```bash
echo "alias patronictl='/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml'" >> ~/.bashrc
```

Reload the shell configuration:

```bash
source ~/.bashrc
```

After that, instead of:

```bash
/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list
```

you can use:

```bash
patronictl list
```

> **Note:** The alias is shell-specific. If you execute `patronictl` as another user, configure the alias for that user's shell as well.

---

# 7. Create the Patroni Configuration Directory

Create the configuration directory:

```bash
sudo mkdir -p /etc/patroni
```

The Patroni configuration file will be located at:

```text
/etc/patroni/patroni.yml
```

---

# 8. Patroni Configuration

The `patroni.yml` file should be created separately for each PostgreSQL node.

The configuration follows the same general structure across all nodes, but the following values must be changed per node:

* `name`
* `restapi.listen`
* `restapi.connect_address`
* `postgresql.listen`
* `postgresql.connect_address`

For example:

### `hq-node-01`

```yaml
name: hq-node-01

restapi:
  listen: 10.0.0.4:8008
  connect_address: 10.0.0.4:8008

postgresql:
  listen: 10.0.0.4:5432
  connect_address: 10.0.0.4:5432
```

### `hq-node-02`

```yaml
name: hq-node-02

restapi:
  listen: 10.0.0.5:8008
  connect_address: 10.0.0.5:8008

postgresql:
  listen: 10.0.0.5:5432
  connect_address: 10.0.0.5:5432
```

### `hq-node-03`

```yaml
name: hq-node-03

restapi:
  listen: 10.0.0.6:8008
  connect_address: 10.0.0.6:8008

postgresql:
  listen: 10.0.0.6:5432
  connect_address: 10.0.0.6:5432
```

### `hq-node-04`

```yaml
name: hq-node-04

restapi:
  listen: 10.0.0.7:8008
  connect_address: 10.0.0.7:8008

postgresql:
  listen: 10.0.0.7:5432
  connect_address: 10.0.0.7:5432
```

### `hq-node-05`

```yaml
name: hq-node-05

restapi:
  listen: 10.0.0.8:8008
  connect_address: 10.0.0.8:8008

postgresql:
  listen: 10.0.0.8:5432
  connect_address: 10.0.0.8:5432
```

> **Important:** Do not create five identical configuration files. Each node must have its own `name` and IP addresses.

---

# 9. Values That Must Be Identical Across All Nodes

The following cluster-level configuration values should be consistent across all five Patroni configuration files:

* `scope`
* `namespace`
* `etcd3.hosts`
* PostgreSQL replication credentials
* PostgreSQL superuser credentials
* `pg_hba` rules
* DCS configuration
* PostgreSQL cluster parameters

For example:

```yaml
scope: pg_cluster_hq

namespace: /db/

etcd3:
  hosts: 10.0.0.4:2379,10.0.0.5:2379,10.0.0.6:2379,10.0.0.7:2379,10.0.0.8:2379
```

---

# 10. Important Patroni Settings

The example configuration enables:

### Synchronous Replication

```yaml
synchronous_mode: true
```

This enables synchronous replication.

The configuration also uses:

```yaml
synchronous_mode_strict: false
```

This means the Primary can continue operating if a synchronous replica is temporarily unavailable.

> With `synchronous_mode_strict: true`, Patroni can prevent commits when a synchronous standby is unavailable. The current configuration intentionally uses `false`.

---

### PostgreSQL Replication Settings

The configuration uses:

```yaml
wal_level: replica
hot_standby: "on"
max_wal_senders: 10
max_replication_slots: 10
wal_keep_size: 128MB
```

These settings support PostgreSQL streaming replication and allow replicas to receive WAL from the Primary.

---

### PostgreSQL Data Directory

The PostgreSQL data directory is:

```text
/var/lib/postgresql/18/main
```

The PostgreSQL binaries are located at:

```text
/usr/lib/postgresql/18/bin
```

---

# 11. Create the Patroni systemd Service

Create the systemd service on **all five VMs**:

```bash
sudo tee /etc/systemd/system/patroni.service <<EOF
[Unit]
Description=Patroni PostgreSQL HA
After=network.target etcd.service

[Service]
Type=simple
User=postgres
ExecStart=/opt/patroni/bin/patroni /etc/patroni/patroni.yml
ExecReload=/bin/kill -s HUP $MAINPID
KillMode=process
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
```

Reload the systemd configuration:

```bash
sudo systemctl daemon-reload
```

---

# 12. Set Correct Ownership

The Patroni service runs as the `postgres` user:

```ini
User=postgres
```

Therefore, make sure PostgreSQL's data directory is owned by `postgres`:

```bash
sudo chown -R postgres:postgres /var/lib/postgresql/18/main
```

Also make sure the Patroni configuration file is owned by `postgres`:

```bash
sudo chown postgres:postgres /etc/patroni/patroni.yml
```

You can verify the ownership with:

```bash
ls -ld /var/lib/postgresql/18/main
ls -l /etc/patroni/patroni.yml
```

---

# 13. Start Patroni

The nodes should **not** all be started at the same time.

Start with:

```text
hq-node-01
```

On `hq-node-01`:

```bash
sudo systemctl enable --now patroni
```

Check the service status:

```bash
sudo systemctl status patroni
```

---

# 14. Monitor Patroni Logs

Monitor the Patroni logs:

```bash
sudo journalctl -u patroni -f
```

On `hq-node-01`, Patroni should initialize the cluster and start PostgreSQL.

You may see messages similar to:

```text
INFO: Selected new etcd server
```

and either:

```text
INFO: initialized a new cluster
```

or:

```text
INFO: doing crash recovery
```

followed by messages indicating that PostgreSQL has started.

You should also see something similar to:

```text
INFO: postmaster pid=...
```

---

# 15. Verify the Initial Primary

Before starting the other nodes, make sure that:

```text
hq-node-01
```

has successfully become the Primary.

Check the cluster:

```bash
/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list
```

Or, if the alias was configured:

```bash
patronictl list
```

At this stage, you should have something conceptually similar to:

```text
+ Cluster: pg_cluster_hq +----------------+
| Member      | Role    | State     |
+-------------+---------+-----------+
| hq-node-01  | Leader  | running   |
+-------------+---------+-----------+
```

---

# 16. Start `hq-node-02`

Once `hq-node-01` is confirmed as the Primary, move to:

```text
hq-node-02
```

Start Patroni:

```bash
sudo systemctl enable --now patroni
```

Monitor the logs:

```bash
sudo journalctl -u patroni -f
```

Patroni should detect the existing cluster and initialize `hq-node-02` as a Replica.

It will normally clone the PostgreSQL data from the Primary using PostgreSQL's base backup mechanism.

---

# 17. Start `hq-node-03`

After confirming that `hq-node-02` is working correctly:

```bash
sudo systemctl enable --now patroni
```

Monitor the logs:

```bash
sudo journalctl -u patroni -f
```

The expected result is that:

```text
hq-node-03
```

joins the cluster as a Replica.

---

# 18. Start `hq-node-04`

Repeat the same process:

```bash
sudo systemctl enable --now patroni
```

Monitor:

```bash
sudo journalctl -u patroni -f
```

Expected role:

```text
Replica
```

---

# 19. Start `hq-node-05`

Finally, start the fifth node:

```bash
sudo systemctl enable --now patroni
```

Monitor:

```bash
sudo journalctl -u patroni -f
```

Expected role:

```text
Replica
```

---

# 20. Verify the Complete Cluster

From any node, run:

```bash
/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list
```

Or:

```bash
patronictl list
```

The final cluster should look conceptually similar to:

```text
+ Cluster: pg_cluster_hq +-----------------------------+
| Member      | Role    | State     | TL | Lag in MB |
+-------------+---------+-----------+----+-----------+
| hq-node-01  | Leader  | running   | .. |           |
| hq-node-02  | Replica | streaming | .. |         0 |
| hq-node-03  | Replica | streaming | .. |         0 |
| hq-node-04  | Replica | streaming | .. |         0 |
| hq-node-05  | Replica | streaming | .. |         0 |
+-------------+---------+-----------+----+-----------+
```

> The exact output and columns may vary depending on the installed Patroni version and cluster state.

---

# 21. Continuously Monitor the Cluster

To continuously monitor the cluster:

```bash
watch -n 1 '/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list'
```

If the alias is configured, you can also use:

```bash
watch -n 1 'patronictl list'
```

---

# 22. Test Automatic Failover

The goal of this test is to verify that Patroni can automatically promote a Replica when the current Primary becomes unavailable.

## Step 1 — Monitor the Cluster

On another terminal:

```bash
watch -n 1 '/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list'
```

---

## Step 2 — Stop Patroni on the Current Primary

On:

```text
hq-node-01
```

run:

```bash
sudo systemctl stop patroni
```

This simulates a failure of the Patroni/PostgreSQL node.

---

## Step 3 — Observe the Cluster

Watch the other terminal.

One of the available replicas should be promoted to:

```text
Leader
```

For example:

```text
hq-node-03
```

may become the new Primary.

The exact node selected depends on Patroni's failover logic and the current state of the replicas.

---

# 23. Test Patroni REST API

Patroni exposes a REST API on port:

```text
8008
```

The `/primary` endpoint can be used to determine whether a node currently considers itself the Primary.

---

## Test `hq-node-01`

Run:

```bash
curl -i http://10.0.0.4:8008/primary
```

If `hq-node-01` is the Primary, the expected response is:

```text
HTTP/1.1 200 OK
```

---

## Test `hq-node-02`

```bash
curl -i http://10.0.0.5:8008/primary
```

If it is currently a Replica, the expected response is:

```text
HTTP/1.1 503 Service Unavailable
```

---

## Test `hq-node-03`

```bash
curl -i http://10.0.0.6:8008/primary
```

A Replica should return:

```text
HTTP/1.1 503 Service Unavailable
```

---

# 24. Expected HA Behavior

Before the failure:

```text
                    ┌─────────────────┐
                    │   hq-node-01    │
                    │     Primary     │
                    │   10.0.0.4      │
                    └────────┬────────┘
                             │
             ┌───────────────┼───────────────┐
             │               │               │
             ▼               ▼               ▼
       hq-node-02      hq-node-03      hq-node-04
         Replica         Replica         Replica
       10.0.0.5         10.0.0.6        10.0.0.7
                             │
                             ▼
                       hq-node-05
                         Replica
                       10.0.0.8
```

After `hq-node-01` fails:

```text
                    ┌─────────────────┐
                    │   hq-node-01    │
                    │     FAILED      │
                    └─────────────────┘

                             ↓

              Patroni + etcd perform failover

                             ↓

                    ┌─────────────────┐
                    │   hq-node-XX    │
                    │     Primary     │
                    └─────────────────┘
```

One of the healthy replicas should be promoted automatically.

---

# 25. Final Cluster Checklist

Before considering the cluster ready, verify the following:

### PostgreSQL

* [ ] PostgreSQL 18 is installed on all nodes.
* [ ] PostgreSQL is not being managed directly by `systemd`.
* [ ] `/var/lib/postgresql/18/main` exists and is owned by `postgres`.
* [ ] PostgreSQL binaries exist under `/usr/lib/postgresql/18/bin/`.

### Patroni

* [ ] Patroni is installed under `/opt/patroni`.
* [ ] Patroni starts successfully on all nodes.
* [ ] `/etc/patroni/patroni.yml` exists on all nodes.
* [ ] Each node has a unique Patroni `name`.
* [ ] Each node uses its own IP address for REST API and PostgreSQL listeners.

### etcd

* [ ] All Patroni nodes can reach the configured etcd servers.
* [ ] The same etcd endpoints are configured on all Patroni nodes.

### Cluster

* [ ] `hq-node-01` successfully becomes the initial Primary.
* [ ] `hq-node-02` joins as a Replica.
* [ ] `hq-node-03` joins as a Replica.
* [ ] `hq-node-04` joins as a Replica.
* [ ] `hq-node-05` joins as a Replica.
* [ ] `patronictl list` shows the expected cluster state.
* [ ] Replication is streaming correctly.
* [ ] Automatic failover has been tested successfully.
* [ ] Patroni REST API returns `200 OK` for the current Primary.
* [ ] Patroni REST API returns `503 Service Unavailable` for Replicas.

---

# 26. Configuration Files Summary

The final setup should look approximately like this on every PostgreSQL node:

```text
/etc/patroni/
└── patroni.yml

/etc/systemd/system/
└── patroni.service

/opt/patroni/
└── bin/
    ├── patroni
    ├── patronictl
    └── ...
```

The PostgreSQL data directory:

```text
/var/lib/postgresql/18/main
```

The PostgreSQL binaries:

```text
/usr/lib/postgresql/18/bin/
```

The Patroni service:

```text
/etc/systemd/system/patroni.service
```

The Patroni configuration:

```text
/etc/patroni/patroni.yml
```

---

# Node Configuration Reference

| Node   | Hostname     | IP         | REST API        | PostgreSQL      |
| ------ | ------------ | ---------- | --------------- | --------------- |
| Node 1 | `hq-node-01` | `10.0.0.4` | `10.0.0.4:8008` | `10.0.0.4:5432` |
| Node 2 | `hq-node-02` | `10.0.0.5` | `10.0.0.5:8008` | `10.0.0.5:5432` |
| Node 3 | `hq-node-03` | `10.0.0.6` | `10.0.0.6:8008` | `10.0.0.6:5432` |
| Node 4 | `hq-node-04` | `10.0.0.7` | `10.0.0.7:8008` | `10.0.0.7:5432` |
| Node 5 | `hq-node-05` | `10.0.0.8` | `10.0.0.8:8008` | `10.0.0.8:5432` |

---

# Important Notes

> **1. Start nodes sequentially.**
> Start `hq-node-01` first, verify that it becomes Primary, then start the remaining nodes one by one.

> **2. Patroni manages PostgreSQL.**
> Do not manually start PostgreSQL using `systemctl start postgresql` after Patroni is configured.

> **3. Keep cluster configuration consistent.**
> Values such as `scope`, `namespace`, etcd endpoints, replication credentials, and cluster-wide PostgreSQL settings should be consistent across nodes.

> **4. Keep node-specific values unique.**
> Each node must have a unique Patroni `name` and must use its own IP address for `restapi` and `postgresql`.

> **5. Test failover before production.**
> A successful `patronictl list` is not enough to prove that HA works. Always perform an actual failover test in a controlled environment before considering the cluster production-ready.