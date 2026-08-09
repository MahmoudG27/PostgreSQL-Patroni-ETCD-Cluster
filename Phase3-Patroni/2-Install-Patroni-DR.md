# Patroni DR Cluster Installation & Setup

This guide installs and configures **Patroni** for a PostgreSQL 18 **Disaster Recovery (DR) cluster**.

The DR environment consists of **5 PostgreSQL nodes** managed by Patroni, with **etcd** used as the Distributed Configuration Store (DCS).

The DR cluster initially runs as a **Standby Cluster** and continuously receives WAL from the **HQ PostgreSQL cluster**.

If the entire HQ cluster becomes unavailable, the DR cluster can be promoted to become the new **Primary PostgreSQL cluster** and start accepting writes from the application.

---

# DR Architecture

The environment consists of two PostgreSQL clusters:

```text
                    HQ SITE
              PostgreSQL Cluster
                 pg_cluster_hq
                       │
                       │ WAL Streaming
                       │
                       ▼
                 DR SITE
              PostgreSQL Cluster
                 pg_cluster_dr
```

The DR cluster is initially read-only and follows the HQ Primary.

---

# DR Nodes

| Node   | Hostname     | IP Address | REST API        | PostgreSQL      |
| ------ | ------------ | ---------- | --------------- | --------------- |
| Node 1 | `dr-node-01` | `10.1.0.4` | `10.1.0.4:8008` | `10.1.0.4:5432` |
| Node 2 | `dr-node-02` | `10.1.0.5` | `10.1.0.5:8008` | `10.1.0.5:5432` |
| Node 3 | `dr-node-03` | `10.1.0.6` | `10.1.0.6:8008` | `10.1.0.6:5432` |
| Node 4 | `dr-node-04` | `10.1.0.7` | `10.1.0.7:8008` | `10.1.0.7:5432` |
| Node 5 | `dr-node-05` | `10.1.0.8` | `10.1.0.8:8008` | `10.1.0.8:5432` |

---

# HQ Primary / VIP

The DR cluster connects to the HQ cluster using the HQ Primary endpoint.

Recommended:

```text
HQ HAProxy / VIP
10.0.0.100:5432
```

The `standby_cluster.host` should point to this endpoint:

```yaml
standby_cluster:
  host: 10.0.0.100
  port: 5432
  primary_slot_name: dr_standby_slot
```

> **Important:** The `host` should preferably be an **HAProxy/VIP endpoint that always routes to the current HQ Primary**, not directly to a specific Replica.
>
> A Replica cannot be used as the WAL source for the DR standby cluster in this architecture.

---

# Directory Structure

The Patroni configuration is maintained as a separate file.

For example:

```text
.
├── patroni-dr-install.sh
└── patroni.yml
```

The `patroni.yml` file contains the Patroni configuration.

The example configuration is initially written for:

```text
dr-node-01
```

Each DR node needs its own configuration with the appropriate:

* `name`
* `restapi.listen`
* `restapi.connect_address`
* `postgresql.listen`
* `postgresql.connect_address`

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

---

# 2. Create Patroni Virtual Environment

Create the Patroni directory:

```bash
sudo mkdir /opt/patroni
```

Create the Python virtual environment:

```bash
sudo python3 -m venv /opt/patroni
```

The virtual environment will be located at:

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

Install Patroni with etcd3 support:

```bash
sudo /opt/patroni/bin/pip install "patroni[etcd3]" psycopg2
```

The `etcd3` extra is required because Patroni uses **etcd** as its DCS.

---

# 5. Verify Patroni Installation

Check the installed Patroni version:

```bash
/opt/patroni/bin/patroni --version
```

List installed Python packages:

```bash
/opt/patroni/bin/pip list
```

---

## Optional: Upgrade Patroni

If Patroni needs to be upgraded:

```bash
sudo /opt/patroni/bin/pip install --upgrade patroni
```

Verify the version:

```bash
/opt/patroni/bin/patroni --version
```

---

## Optional: Remove the Virtual Environment

To completely remove the Patroni virtual environment:

```bash
sudo rm -rf /opt/patroni
```

> **Warning:** This removes Patroni and all Python packages installed inside the virtual environment.

---

# 6. Create `patronictl` Alias

Add the following alias:

```bash
echo "alias patronictl='/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml'" >> ~/.bashrc
```

Reload the shell:

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

---

# 7. Create Patroni Configuration Directory

Create the configuration directory:

```bash
sudo mkdir -p /etc/patroni
```

The configuration file should be:

```text
/etc/patroni/patroni.yml
```

---

# 8. Patroni DR Configuration

The DR cluster uses a different Patroni scope from the HQ cluster:

```yaml
scope: pg_cluster_dr
namespace: /db/
```

Each DR node must have a unique Patroni name.

For example:

```yaml
name: dr-node-01
```

---

# 9. Standby Cluster Configuration

The most important part of the DR configuration is:

```yaml
standby_cluster:
  host: 10.0.0.100
  port: 5432
  primary_slot_name: dr_standby_slot
```

### `host`

```yaml
host: 10.0.0.100
```

This should preferably point to the **HQ HAProxy/VIP** that always routes connections to the current HQ Primary.

### `port`

```yaml
port: 5432
```

This is the PostgreSQL port exposed by the HQ Primary endpoint.

### `primary_slot_name`

```yaml
primary_slot_name: dr_standby_slot
```

This replication slot is important because it allows the HQ cluster to retain WAL required by the DR cluster.

> **Important:** The replication slot must be configured correctly on the HQ side as part of the DR replication design. Do not assume that simply specifying the name in `standby_cluster` creates the required slot on the HQ cluster.

---

# 10. DR etcd Configuration

The DR Patroni nodes use the DR etcd cluster:

```yaml
etcd3:
  hosts: 10.1.0.4:2379,10.1.0.5:2379,10.1.0.6:2379,10.1.0.7:2379,10.1.0.8:2379
```

All five DR nodes should use the same etcd endpoints.

---

# 11. Synchronous Replication

The DR Patroni configuration enables synchronous mode:

```yaml
synchronous_mode: true
```

And:

```yaml
synchronous_mode_strict: false
```

Using:

```yaml
synchronous_mode_strict: false
```

allows the Primary to continue operating if a synchronous Replica becomes temporarily unavailable.

> **Note:** This synchronous replication setting applies to the Patroni cluster behavior. The DR cluster's initial relationship with HQ is based on the `standby_cluster` configuration and WAL streaming.

---

# 12. PostgreSQL Replication Settings

The DR nodes use:

```yaml
postgresql:
  use_pg_rewind: true
  use_slots: true
  parameters:
    wal_level: replica
    hot_standby: "on"
    max_wal_senders: 10
    max_replication_slots: 10
    wal_keep_size: 128MB
```

These settings support PostgreSQL replication and allow the DR nodes to receive WAL.

---

# 13. PostgreSQL Data Directory

The PostgreSQL data directory is:

```text
/var/lib/postgresql/18/main
```

The PostgreSQL binaries are located at:

```text
/usr/lib/postgresql/18/bin
```

---

# 14. Initialize PostgreSQL

The Patroni configuration uses:

```yaml
initdb:
  - encoding: UTF8
  - data-checksums
```

This allows Patroni to initialize the PostgreSQL cluster with:

* UTF-8 encoding
* Data checksums enabled

---

# 15. PostgreSQL Access Rules

The DR configuration allows replication and PostgreSQL connections from the DR network:

```yaml
pg_hba:
  - host replication replicator 10.1.0.0/24 md5
  - host all all 10.1.0.0/24 md5
  - host all all 127.0.0.1/32 trust
```

The replication user and password must be configured consistently with the replication design.

---

# 16. Node-Specific Configuration

Each DR node uses the same cluster-level configuration but has different node-specific values.

## `dr-node-01`

```yaml
name: dr-node-01

restapi:
  listen: 10.1.0.4:8008
  connect_address: 10.1.0.4:8008

postgresql:
  listen: 10.1.0.4:5432
  connect_address: 10.1.0.4:5432
```

---

## `dr-node-02`

```yaml
name: dr-node-02

restapi:
  listen: 10.1.0.5:8008
  connect_address: 10.1.0.5:8008

postgresql:
  listen: 10.1.0.5:5432
  connect_address: 10.1.0.5:5432
```

---

## `dr-node-03`

```yaml
name: dr-node-03

restapi:
  listen: 10.1.0.6:8008
  connect_address: 10.1.0.6:8008

postgresql:
  listen: 10.1.0.6:5432
  connect_address: 10.1.0.6:5432
```

---

## `dr-node-04`

```yaml
name: dr-node-04

restapi:
  listen: 10.1.0.7:8008
  connect_address: 10.1.0.7:8008

postgresql:
  listen: 10.1.0.7:5432
  connect_address: 10.1.0.7:5432
```

---

## `dr-node-05`

```yaml
name: dr-node-05

restapi:
  listen: 10.1.0.8:8008
  connect_address: 10.1.0.8:8008

postgresql:
  listen: 10.1.0.8:5432
  connect_address: 10.1.0.8:5432
```

---

# 17. Configuration Values That Must Match

The following values should be consistent across all five DR configuration files:

* `scope`
* `namespace`
* `etcd3.hosts`
* `standby_cluster.host`
* `standby_cluster.port`
* `standby_cluster.primary_slot_name`
* `pg_hba`
* replication credentials
* PostgreSQL superuser credentials
* PostgreSQL cluster parameters

The following values must be unique per node:

* `name`
* `restapi.listen`
* `restapi.connect_address`
* `postgresql.listen`
* `postgresql.connect_address`

---

# 18. Create Patroni systemd Service

Create the service on **all five DR VMs**:

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

Reload systemd:

```bash
sudo systemctl daemon-reload
```

---

# 19. Set Correct Ownership

The Patroni service runs as:

```ini
User=postgres
```

Therefore, ensure that PostgreSQL's data directory is owned by `postgres`:

```bash
sudo chown -R postgres:postgres /var/lib/postgresql/18/main
```

Set the Patroni configuration ownership:

```bash
sudo chown postgres:postgres /etc/patroni/patroni.yml
```

Verify:

```bash
ls -ld /var/lib/postgresql/18/main
ls -l /etc/patroni/patroni.yml
```

---

# 20. Start the DR Cluster

The DR nodes should be started **one by one**.

Start with:

```text
dr-node-01
```

On `dr-node-01`:

```bash
sudo systemctl enable --now patroni
```

Check the service:

```bash
sudo systemctl status patroni
```

Monitor the logs:

```bash
sudo journalctl -u patroni -f
```

---

# 21. Expected Patroni Logs

On the first DR node, Patroni should connect to etcd and initialize the DR standby cluster.

You may see messages similar to:

```text
INFO: Selected new etcd server
```

and:

```text
INFO: initialized a new cluster
```

or:

```text
INFO: doing crash recovery
```

followed by:

```text
INFO: postmaster pid=...
```

The exact log messages depend on the current Patroni and PostgreSQL state.

---

# 22. Start `dr-node-02`

After confirming that `dr-node-01` is running correctly:

```bash
sudo systemctl enable --now patroni
```

Monitor:

```bash
sudo journalctl -u patroni -f
```

The node should join the DR cluster.

---

# 23. Start `dr-node-03`

Once `dr-node-02` is healthy:

```bash
sudo systemctl enable --now patroni
```

Monitor:

```bash
sudo journalctl -u patroni -f
```

---

# 24. Start `dr-node-04`

Start the fourth node:

```bash
sudo systemctl enable --now patroni
```

Monitor:

```bash
sudo journalctl -u patroni -f
```

---

# 25. Start `dr-node-05`

Finally, start the fifth node:

```bash
sudo systemctl enable --now patroni
```

Monitor:

```bash
sudo journalctl -u patroni -f
```

---

# 26. Check DR Cluster Status

From any DR node:

```bash
/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list
```

Or:

```bash
patronictl list
```

The DR cluster should show the nodes and their current state.

In a healthy standby cluster, you should expect a **Standby Leader** rather than a normal writable Primary.

Conceptually:

```text
+ Cluster: pg_cluster_dr +------------------------------+
| Member      | Role          | State                   |
+-------------+---------------+-------------------------+
| dr-node-01  | Standby Leader| running                 |
| dr-node-02  | Replica       | streaming               |
| dr-node-03  | Replica       | streaming               |
| dr-node-04  | Replica       | streaming               |
| dr-node-05  | Replica       | streaming               |
+-------------+---------------+-------------------------+
```

> The exact output depends on the Patroni version and the current cluster state.

---

# 27. Continuously Monitor the DR Cluster

Use:

```bash
watch -n 1 '/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list'
```

Or, if the alias is configured:

```bash
watch -n 1 'patronictl list'
```

---

# 28. Verify WAL Replication From HQ

The most important test for the DR environment is verifying that WAL is being received from the HQ cluster.

The DR cluster should continuously follow the HQ Primary through:

```yaml
standby_cluster:
  host: 10.0.0.100
  port: 5432
  primary_slot_name: dr_standby_slot
```

Verify that:

* The HQ endpoint is reachable.
* The endpoint routes to the current HQ Primary.
* The replication user can connect.
* The `dr_standby_slot` exists and is functioning correctly.
* WAL is being received by the DR cluster.
* The DR nodes remain in sync with the HQ cluster within the expected RPO.

---

# 29. Test Patroni REST API

Patroni exposes its REST API on port:

```text
8008
```

For example:

```bash
curl -i http://10.1.0.4:8008/primary
```

Because the DR cluster is initially a **standby cluster**, do not interpret the `/primary` endpoint exactly like the HQ cluster.

The DR cluster is intentionally not a writable Primary while `standby_cluster` is active.

The important checks at this stage are the cluster status and replication state.

---

# 30. DR Cluster Internal Failover

The DR cluster should also be able to tolerate the failure of its current Standby Leader.

Monitor:

```bash
watch -n 1 '/opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list'
```

Then stop Patroni on the current Standby Leader:

```bash
sudo systemctl stop patroni
```

Patroni should select another healthy DR node as the new Standby Leader.

> This is an **internal DR cluster failover**. It does not promote the DR cluster to a writable Primary. The cluster remains a standby cluster while `standby_cluster` is configured.

---

# 31. Full HQ Disaster Scenario

The DR promotion procedure is required when:

```text
HQ Cluster
    ↓
Completely unavailable
```

and the application must start using the DR environment.

The expected flow is:

```text
              NORMAL OPERATION

       HQ PostgreSQL Cluster
              PRIMARY
                 │
                 │ WAL
                 ▼
          DR Standby Cluster
        ┌─────────────────────┐
        │ Standby Leader      │
        │ Replica             │
        │ Replica             │
        │ Replica             │
        │ Replica             │
        └─────────────────────┘
```

If HQ is completely lost:

```text
              HQ FAILURE

       HQ PostgreSQL Cluster
             ❌ DOWN

                 ↓

        DR Promotion Procedure

                 ↓

          DR PostgreSQL Cluster
                PRIMARY

                 ↓

             Application
```

---

# 32. Promote DR to Primary

> **Important:** Only perform this procedure when the HQ cluster is genuinely unavailable and you have decided to perform a DR disaster-recovery failover.

The DR cluster currently contains:

```yaml
standby_cluster:
  host: 10.0.0.100
  port: 5432
  primary_slot_name: dr_standby_slot
```

As long as this configuration remains active, the DR cluster behaves as a standby cluster.

To promote the DR cluster, remove the `standby_cluster` configuration from the **Patroni DCS configuration**.

---

# 33. Edit the Patroni DCS Configuration

Run this from any DR node:

```bash
patronictl -c /etc/patroni/patroni.yml edit-config
```

This opens the dynamic Patroni configuration in the default editor.

Find:

```yaml
standby_cluster:
  host: 10.0.0.100
  port: 5432
  primary_slot_name: dr_standby_slot
```

Remove the entire block.

After removal, the configuration should no longer contain:

```yaml
standby_cluster:
```

Save and exit the editor.

---

# 34. What Happens After Removing `standby_cluster`?

Once the change is committed to the Patroni DCS, Patroni detects that the cluster is no longer configured as a standby cluster.

The DR **Standby Leader** can then be promoted to a normal writable PostgreSQL Primary.

Conceptually:

```text
Before:

DR Cluster
│
├── Standby Leader
├── Replica
├── Replica
├── Replica
└── Replica

        ↓

Remove standby_cluster

        ↓

After:

DR Cluster
│
├── Primary
├── Replica
├── Replica
├── Replica
└── Replica
```

The DR Primary can now accept writes.

---

# 35. Verify DR Promotion

Check the cluster:

```bash
patronictl list
```

You should now see a normal writable Leader/Primary:

```text
+ Cluster: pg_cluster_dr +------------------------------+
| Member      | Role    | State     |
+-------------+---------+-----------+
| dr-node-01  | Leader  | running   |
| dr-node-02  | Replica | streaming |
| dr-node-03  | Replica | streaming |
| dr-node-04  | Replica | streaming |
| dr-node-05  | Replica | streaming |
+-------------+---------+-----------+
```

The exact node that becomes Leader depends on the current Patroni state.

---

# 36. Verify PostgreSQL Is Writable

After promotion, connect to the DR Primary and verify that it accepts writes.

For example:

```bash
psql -h <DR_PRIMARY_IP> -U postgres -d postgres
```

Then:

```sql
CREATE TABLE dr_failover_test (
    id integer PRIMARY KEY,
    created_at timestamp DEFAULT now()
);
```

Insert a test record:

```sql
INSERT INTO dr_failover_test (id)
VALUES (1);
```

Verify:

```sql
SELECT * FROM dr_failover_test;
```

> Use a controlled test in a non-production environment first. In a real DR event, confirm the application connection endpoint and DNS/VIP routing before allowing application writes.

---

# 37. Application Traffic After DR Promotion

After the DR cluster becomes the new Primary, the application must connect to the DR Primary endpoint.

Ideally, use a DR HAProxy/VIP instead of a hardcoded PostgreSQL node IP.

For example:

```text
Application
     │
     ▼
DR HAProxy / VIP
     │
     ▼
DR Primary
```

This allows the application connection endpoint to remain stable if the DR Primary changes later.

---

# 38. Important DR Failover Warning

Promoting DR is a **disaster recovery decision**, not a normal Patroni failover.

Do **not** promote DR while HQ is still healthy and writable.

Otherwise, you can create a **split-brain** situation:

```text
             ❌ DANGEROUS

        HQ Primary
          Writable
             │
             │
             │
        DR Primary
          Writable

     Two independent
       Primaries
```

This can lead to divergent data sets and data loss/conflicts.

Before promoting DR, make sure:

* HQ is genuinely unavailable.
* The application is no longer writing to HQ.
* The HQ Primary cannot continue accepting writes.
* The DR cluster has received as much WAL as possible.
* The decision to promote DR has been made according to the organization's DR procedure.

---

# 39. Rebuilding HQ After DR Promotion

After DR has been promoted and becomes the new Primary, the old HQ cluster should **not** simply be started again as if nothing happened.

The old HQ environment must be treated as an old/failed site and carefully reintroduced into the replication topology.

The typical high-level process is:

```text
HQ Failure
    ↓
Promote DR
    ↓
DR becomes Primary
    ↓
Application writes to DR
    ↓
Repair / rebuild HQ
    ↓
Re-seed HQ from the new DR Primary
    ↓
Configure reverse replication
    ↓
Verify replication
```

> The exact rejoin procedure depends on the final architecture, replication slots, Patroni configuration, HAProxy/VIP setup, and whether the old HQ nodes can safely be rewound or must be rebuilt from a fresh base backup.

---

# 40. Final DR Checklist

## PostgreSQL

* [ ] PostgreSQL 18 is installed on all DR nodes.
* [ ] PostgreSQL is managed by Patroni.
* [ ] `/var/lib/postgresql/18/main` is owned by `postgres`.
* [ ] PostgreSQL binaries exist under `/usr/lib/postgresql/18/bin`.

## Patroni

* [ ] Patroni is installed under `/opt/patroni`.
* [ ] Patroni service starts successfully.
* [ ] `/etc/patroni/patroni.yml` exists on all nodes.
* [ ] Each node has a unique name.
* [ ] Each node uses its correct IP address.

## etcd

* [ ] All DR nodes can communicate with the DR etcd cluster.
* [ ] The same etcd endpoints are configured on all DR nodes.
* [ ] The etcd cluster is healthy.

## HQ → DR Replication

* [ ] HQ HAProxy/VIP is reachable from DR.
* [ ] HQ HAProxy/VIP routes to the current HQ Primary.
* [ ] The DR replication user can connect to HQ.
* [ ] `dr_standby_slot` is configured correctly.
* [ ] WAL is being received by DR.
* [ ] DR lag is within the expected RPO.

## DR Cluster

* [ ] `dr-node-01` is healthy.
* [ ] `dr-node-02` is healthy.
* [ ] `dr-node-03` is healthy.
* [ ] `dr-node-04` is healthy.
* [ ] `dr-node-05` is healthy.
* [ ] A Standby Leader exists.
* [ ] DR replicas are streaming correctly.
* [ ] Internal DR failover has been tested.

## DR Promotion

* [ ] HQ outage scenario has been tested.
* [ ] Application traffic to HQ has been stopped before promotion.
* [ ] `standby_cluster` is removed from the Patroni DCS only during an approved DR promotion.
* [ ] DR successfully becomes a writable Primary.
* [ ] Application can connect to the DR endpoint.
* [ ] Application writes successfully.
* [ ] DR HAProxy/VIP points to the correct Primary.

---

# 41. DR Node Reference

| Node   | Hostname     | IP         | REST API        | PostgreSQL      |
| ------ | ------------ | ---------- | --------------- | --------------- |
| Node 1 | `dr-node-01` | `10.1.0.4` | `10.1.0.4:8008` | `10.1.0.4:5432` |
| Node 2 | `dr-node-02` | `10.1.0.5` | `10.1.0.5:8008` | `10.1.0.5:5432` |
| Node 3 | `dr-node-03` | `10.1.0.6` | `10.1.0.6:8008` | `10.1.0.6:5432` |
| Node 4 | `dr-node-04` | `10.1.0.7` | `10.1.0.7:8008` | `10.1.0.7:5432` |
| Node 5 | `dr-node-05` | `10.1.0.8` | `10.1.0.8:8008` | `10.1.0.8:5432` |

---

# 42. Important Files

The final DR setup should look approximately like:

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

/var/lib/postgresql/18/main/
└── PostgreSQL data directory
```

---

# DR Architecture Summary

```text
                         HQ SITE
                  ┌───────────────────┐
                  │ PostgreSQL Cluster │
                  │   pg_cluster_hq    │
                  └─────────┬─────────┘
                            │
                            │ WAL
                            │
                            ▼
                    HQ HAProxy / VIP
                      10.0.0.100:5432
                            │
                            │
                            ▼
                         DR SITE
                  ┌───────────────────┐
                  │ PostgreSQL Cluster │
                  │   pg_cluster_dr    │
                  │ Standby Cluster    │
                  └───────────────────┘
                            │
            ┌───────────────┼───────────────┐
            │               │               │
            ▼               ▼               ▼
       dr-node-01      dr-node-02      dr-node-03
       10.1.0.4        10.1.0.5        10.1.0.6
            │
            ├───────────────┬───────────────┐
            │               │
            ▼               ▼
       dr-node-04      dr-node-05
       10.1.0.7        10.1.0.8
```

During normal operation:

```text
HQ Primary
    │
    │ WAL
    ▼
DR Standby Cluster
    │
    ├── Standby Leader
    ├── Replica
    ├── Replica
    ├── Replica
    └── Replica
```

During a complete HQ disaster:

```text
HQ
❌ DOWN

    ↓

Remove standby_cluster
from Patroni DCS

    ↓

DR Standby Leader
        │
        ▼
    DR Primary
        │
        ▼
   Application
```
