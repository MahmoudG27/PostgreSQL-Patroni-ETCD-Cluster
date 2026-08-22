# pgBackRest Backup Configuration — DR PostgreSQL Cluster

This document describes how to configure **pgBackRest** for the DR PostgreSQL cluster.

The backup architecture uses a dedicated **Backup Server** to store PostgreSQL backups.

The PostgreSQL nodes send WAL archives to the Backup Server, while pgBackRest is configured to prefer taking the actual backup workload from an available PostgreSQL Standby.

---

# 1. Backup Architecture

The DR PostgreSQL cluster consists of multiple Patroni-managed PostgreSQL nodes.

Example:

```text
DR PostgreSQL Cluster

┌──────────────────┐
│   dr-node-01     │
│   10.1.0.4       │
│   PostgreSQL     │
└────────┬─────────┘
         │
         │
┌────────▼─────────┐
│   dr-node-02     │
│   10.1.0.5       │
│   PostgreSQL     │
└────────┬─────────┘
         │
         │
┌────────▼─────────┐
│   dr-node-03     │
│   10.1.0.6       │
│   PostgreSQL     │
└──────────────────┘
```

The backups are stored on a dedicated Backup Server:

```text
┌──────────────────────────────┐
│       Backup Server          │
│       10.1.0.30              │
│                              │
│ /var/lib/pgbackrest           │
└──────────────┬───────────────┘
               │
               │ SSH
               │
      ┌────────┼────────┐
      │        │        │
      ▼        ▼        ▼
   Node 01  Node 02  Node 03
```

The Backup Server is responsible for storing the backup repository.

---

# 2. Important Design

The configuration uses:

```ini
backup-standby=y
```

This tells pgBackRest to prefer performing the backup from an available PostgreSQL Standby instead of putting the heavy backup workload on the Primary.

Conceptually:

```text
                 PostgreSQL Cluster

                 ┌─────────────┐
                 │   Primary   │
                 └──────┬──────┘
                        │
                 WAL Replication
                        │
             ┌──────────┴──────────┐
             ▼                     ▼
       ┌───────────┐         ┌───────────┐
       │  Standby  │         │  Standby  │
       └─────┬─────┘         └───────────┘
             │
             │ Backup
             ▼
      ┌───────────────┐
      │ Backup Server │
      └───────────────┘
```

This helps reduce the backup impact on the Primary PostgreSQL node.

---

# 3. Install pgBackRest

## 3.1 Add the PGDG Repository

pgBackRest must be the **same version** on the PostgreSQL nodes and on the Backup Server.

If one machine installs pgBackRest from the default Ubuntu repository and another installs it from PGDG, the versions will differ and pgBackRest will refuse to communicate between them.

To avoid this, add the official PostgreSQL (PGDG) APT repository on **every PostgreSQL node and on the Backup Server** before installing anything.

Install the prerequisites:

```bash
sudo apt-get install -y curl ca-certificates lsb-release
```

Import the PGDG signing key:

```bash
sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc
```

Add the repository:

```bash
sudo sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'
```

Update the package index:

```bash
sudo apt update
```

Confirm that pgBackRest will be installed from PGDG:

```bash
apt-cache policy pgbackrest
```

---

## 3.2 PostgreSQL Nodes

Install pgBackRest on all PostgreSQL nodes.

Run on every PostgreSQL node:

```bash
sudo apt install -y pgbackrest
```

For a five-node cluster:

```text
dr-node-01
dr-node-02
dr-node-03
dr-node-04
dr-node-05
```

---

# 4. Install pgBackRest on the Backup Server

Make sure the PGDG repository from **3.1** has already been added on this machine, otherwise the Backup Server will install a different pgBackRest version than the PostgreSQL nodes.

On the dedicated Backup Server:

```bash
sudo apt install -y pgbackrest jq
```

Verify that the version matches the PostgreSQL nodes:

```bash
pgbackrest version
```

The same version must be reported on the Backup Server and on every PostgreSQL node.

Create the backup repository directory:

```bash
sudo mkdir -p /var/lib/pgbackrest
```

The backup repository will be:

```text
/var/lib/pgbackrest
```

---

# 5. Create the `postgres` User on the Backup Server

The Backup Server needs a `postgres` user because pgBackRest will use this account to communicate with the PostgreSQL nodes.

If the user does not already exist:

```bash
sudo useradd -r -m -d /var/lib/postgresql postgres
```

Create the SSH directory:

```bash
sudo -u postgres mkdir -p /var/lib/postgresql/.ssh
```

Set the correct permissions:

```bash
sudo -u postgres chmod 700 /var/lib/postgresql/.ssh
```

---

# 6. SSH Authentication

pgBackRest uses SSH to communicate between the Backup Server and PostgreSQL nodes.

The setup uses SSH keys instead of passwords.

The required communication is:

```text
Backup Server
10.1.0.30
    │
    ├──── SSH ────► dr-node-01
    │
    ├──── SSH ────► dr-node-02
    │
    ├──── SSH ────► dr-node-03
    │
    ├──── SSH ────► dr-node-04
    │
    └──── SSH ────► dr-node-05
```

---

# 7. Generate SSH Key on PostgreSQL Nodes

On each PostgreSQL node, generate an SSH key for the `postgres` user.

Run:

```bash
sudo -u postgres ssh-keygen \
  -t ed25519 \
  -N "" \
  -f /var/lib/postgresql/.ssh/id_ed25519
```

Display the public key:

```bash
sudo -u postgres cat /var/lib/postgresql/.ssh/id_ed25519.pub
```

Copy the generated public key.

Repeat this on all PostgreSQL nodes.

---

# 8. Generate SSH Key on the Backup Server

On the Backup Server:

```bash
sudo -u postgres ssh-keygen \
  -t ed25519 \
  -N "" \
  -f /var/lib/postgresql/.ssh/id_ed25519
```

Display the public key:

```bash
sudo -u postgres cat /var/lib/postgresql/.ssh/id_ed25519.pub
```

Copy this public key.

---

# 9. Allow Backup Server to Connect to PostgreSQL Nodes

On the Backup Server, add the Backup Server's SSH public key to the `authorized_keys` file on every PostgreSQL node.

On each PostgreSQL node:

```bash
sudo -u postgres mkdir -p /var/lib/postgresql/.ssh
sudo -u postgres chmod 700 /var/lib/postgresql/.ssh
```

Then add the Backup Server public key:

```bash
sudo -u postgres tee -a /var/lib/postgresql/.ssh/authorized_keys
```

Paste the Backup Server public key and press:

```text
CTRL+D
```

Repeat for:

```text
dr-node-01
dr-node-02
dr-node-03
dr-node-04
dr-node-05
```

---

# 10. Optional Reverse SSH Access

If the PostgreSQL nodes also need to connect back to the Backup Server, add the public keys generated on the PostgreSQL nodes to the Backup Server's:

```text
/var/lib/postgresql/.ssh/authorized_keys
```

On the Backup Server:

```bash
sudo -u postgres tee -a /var/lib/postgresql/.ssh/authorized_keys
```

Add the public keys from the PostgreSQL nodes.

Repeat for all PostgreSQL nodes.

---

# 11. Test SSH Connectivity

From the Backup Server, test connectivity to every PostgreSQL node.

For example:

```bash
sudo -u postgres ssh postgres@10.1.0.4 "echo Connected successfully"
```

```bash
sudo -u postgres ssh postgres@10.1.0.5 "echo Connected successfully"
```

```bash
sudo -u postgres ssh postgres@10.1.0.6 "echo Connected successfully"
```

For the complete five-node cluster:

```bash
sudo -u postgres ssh postgres@10.1.0.4 "echo Connected successfully"
sudo -u postgres ssh postgres@10.1.0.5 "echo Connected successfully"
sudo -u postgres ssh postgres@10.1.0.6 "echo Connected successfully"
```

Expected output:

```text
Connected successfully
```

---

# 12. Test Reverse SSH Connectivity

If reverse SSH is configured, test from a PostgreSQL node:

```bash
sudo -u postgres ssh postgres@10.1.0.30 "echo Connected successfully"
```

Expected:

```text
Connected successfully
```

---

# 13. Backup Repository Permissions

On the Backup Server:

```bash
sudo mkdir -p /var/lib/pgbackrest
sudo chown postgres:postgres /var/lib/pgbackrest
```

Verify:

```bash
ls -ld /var/lib/pgbackrest
```

The directory should be owned by:

```text
postgres:postgres
```

---

# 14. pgBackRest Configuration — Backup Server

The Backup Server needs the main pgBackRest configuration:

```text
/etc/pgbackrest.conf
```

Create it:

```bash
sudo tee /etc/pgbackrest.conf > /dev/null <<'EOF'
[global]
repo1-path=/var/lib/pgbackrest
backup-standby=y
repo1-retention-full=4
repo1-retention-full-type=count
repo1-retention-archive-type=full
repo1-retention-archive=1

[pg_cluster_dr]
pg1-host=10.1.0.4
pg1-path=/var/lib/postgresql/18/main

pg2-host=10.1.0.5
pg2-path=/var/lib/postgresql/18/main

pg3-host=10.1.0.6
pg3-path=/var/lib/postgresql/18/main

pg4-host=10.0.0.4
pg4-path=/var/lib/postgresql/18/main

pg5-host=10.0.0.5
pg5-path=/var/lib/postgresql/18/main

pg6-host=10.0.0.6
pg6-path=/var/lib/postgresql/18/main
EOF
```

> **Note — why the HQ nodes are listed here**
>
> The stanza lists the five DR nodes (`pg1`–`pg5`) **and** the three HQ nodes (`pg6`–`pg8`).
>
> The DR cluster is a standby cluster: every DR node is a replica, and none of them is a real primary. A replica cannot start or stop a backup by itself.
>
> pgBackRest must connect to the **real primary in HQ** to start the backup and verify that the data is consistent. Only after that does it take the actual full backup from one of the replicas.
>
> If the HQ nodes are not listed, pgBackRest finds no primary in the stanza and the backup fails.
>
> Each `pgN-host` number must be unique. Because DR already uses `pg1`–`pg5`, the HQ nodes continue from `pg6`.

---

# 15. Configuration Explanation

The repository is:

```ini
repo1-path=/var/lib/pgbackrest
```

Therefore all backups are stored under:

```text
/var/lib/pgbackrest
```

The stanza is:

```text
pg_cluster_dr
```

The PostgreSQL nodes are:

```text
DR nodes
pg1 → 10.1.0.4
pg2 → 10.1.0.5
pg3 → 10.1.0.6

HQ nodes
pg4 → 10.0.0.4
pg5 → 10.0.0.5
pg6 → 10.0.0.6
```

The HQ nodes are included so that pgBackRest can reach the real primary. See the note in section 14.

All nodes use:

```text
/var/lib/postgresql/18/main
```

as their PostgreSQL data directory.

## Retention

The retention settings control how many backups are kept before pgBackRest expires the old ones:

```ini
repo1-retention-full=4
repo1-retention-full-type=count
repo1-retention-archive-type=full
repo1-retention-archive=1
```

These mean:

```text
repo1-retention-full=4            keep the last 4 full backups
repo1-retention-full-type=count   count backups, not days
repo1-retention-archive-type=full retain WAL relative to full backups
repo1-retention-archive=1         keep WAL for the most recent full backup
```

With a weekly full backup, keeping 4 full backups gives roughly one month of backup history.

Without retention settings, pgBackRest never expires anything and the repository grows until the Backup Server runs out of disk.

Expiration runs automatically at the end of each `backup` command.

---

# 16. pgBackRest Configuration — PostgreSQL Nodes

The PostgreSQL nodes need their own pgBackRest configuration.

Create:

```text
/etc/pgbackrest.conf
```

with:

```bash
sudo tee /etc/pgbackrest.conf > /dev/null <<'EOF'
[global]
repo1-host=10.1.0.30
repo1-host-user=postgres

[pg_cluster_dr]
pg1-path=/var/lib/postgresql/18/main
EOF
```

The important settings are:

```ini
repo1-host=10.1.0.30
repo1-host-user=postgres
```

This tells pgBackRest that the backup repository is located on:

```text
Backup Server
10.1.0.30
```

and that SSH communication should use:

```text
postgres
```

---

# 17. Configure PostgreSQL WAL Archiving

WAL archiving must be enabled **before** the stanza is created.

`stanza-create` and `check` both validate the PostgreSQL archive settings and push a test WAL segment. If `archive_mode` and `archive_command` are not configured yet, these commands fail.

pgBackRest needs PostgreSQL WAL files to support:

* Point-in-time recovery
* Continuous archiving
* Backup consistency
* Recovery after failures

Configure Patroni/PostgreSQL to enable WAL archiving.

In:

```text
/etc/patroni/patroni.yml
```

add:

```yaml
postgresql:
  parameters:
    archive_mode: "always"
    archive_command: "pgbackrest --stanza=pg_cluster_dr archive-push %p"
```

Because Patroni manages PostgreSQL, these parameters should be configured through the Patroni configuration rather than manually modifying the generated PostgreSQL configuration.

> **Note — why `always` and not `on`**
>
> The DR cluster uses `archive_mode: "always"` instead of `archive_mode: "on"`.
>
> With `archive_mode: "on"`, only the Leader archives WAL. A replica keeps the setting but never runs the `archive_command`, so nothing is archived from it.
>
> Every node in the DR cluster is a replica, so `on` would archive nothing at all.
>
> With `archive_mode: "always"`, a node also archives the WAL it receives through replication. This lets pgBackRest pull WAL from the DR replicas instead of depending on the HQ Leader.

> **Note**
>
> After editing `/etc/patroni/patroni.yml`, the cluster must be restarted for the pgBackRest changes to be applied.
>
> `archive_mode` is a restart-only parameter, so a reload is not enough.

Restart the cluster:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml restart pg_cluster_dr
```

Confirm that archiving is active before continuing:

```bash
sudo -u postgres psql -c "SHOW archive_mode;"
sudo -u postgres psql -c "SHOW archive_command;"
```

---

# 18. WAL Archiving Flow

The WAL flow becomes:

```text
PostgreSQL
     │
     │ WAL
     ▼
archive_command
     │
     ▼
pgBackRest
     │
     │ SSH / repository
     ▼
Backup Server
     │
     ▼
/var/lib/pgbackrest
```

This gives the backup infrastructure a continuous stream of archived WAL files.

---

# 19. Create the pgBackRest Stanza

The stanza identifies the PostgreSQL cluster to pgBackRest.

Run this command **on the Backup Server**:

```bash
sudo -u postgres pgbackrest \
  --stanza=pg_cluster_dr \
  stanza-create
```

The stanza is:

```text
pg_cluster_dr
```

---

# 20. Verify the Stanza

After creating the stanza:

```bash
sudo -u postgres pgbackrest \
  --stanza=pg_cluster_dr \
  check
```

The `check` command verifies the pgBackRest configuration and connectivity.

If there are SSH, PostgreSQL, or configuration problems, fix them before scheduling backups.

---

# 21. Weekly Full Backup

A weekly full backup can be scheduled on the Backup Server.

The desired schedule is:

```text
Every Sunday
02:00 AM
```

Cron expression:

```cron
0 2 * * 5
```

---

# 22. Create the Backup Cron Job

Edit the `postgres` user's crontab on the Backup Server:

```bash
sudo -u postgres crontab -e
```

Add:

```cron
0 2 * * 5 pgbackrest --stanza=pg_cluster_dr --type=full backup
```

This means:

```text
Minute:       0
Hour:         2
Day:          *
Month:        *
Day of week:  Sunday
```

Therefore:

```text
Every Sunday at 02:00
```

---

# 23. Test the Backup Manually

Before relying on cron, run a full backup manually.

On the Backup Server:

```bash
sudo -u postgres pgbackrest --stanza=pg_cluster_hq --type=full --log-level-console=info backup 
```

This may take some time depending on:

* Database size
* Network bandwidth
* Disk performance
* Number of PostgreSQL nodes
* Current system load

---

# 24. Check Backup Information

After the backup completes:

```bash
sudo -u postgres pgbackrest \
  --stanza=pg_cluster_dr \
  info
```

You should see information about the backup such as:

```text
Backup
├── Type
├── Timestamp
├── Database size
├── Backup size
├── WAL range
└── Backup status
```

The exact output depends on the pgBackRest version.

---

# 25. Expected Backup Flow

The complete backup process is:

```text
                    DR PostgreSQL Cluster

              ┌──────────────────────┐
              │      Primary         │
              └──────────┬───────────┘
                         │
                         │ Streaming Replication
                         ▼
              ┌──────────────────────┐
              │      Standby         │
              │                      │
              │  Backup Source       │
              └──────────┬───────────┘
                         │
                         │ pgBackRest
                         ▼
              ┌──────────────────────┐
              │    Backup Server     │
              │      10.1.0.30       │
              └──────────┬───────────┘
                         │
                         ▼
                  /var/lib/pgbackrest
```

The actual standby selected by pgBackRest depends on the cluster state and configuration.

---

# 26. Important: Patroni + pgBackRest

The responsibilities are separated:

```text
Patroni
   │
   ├── PostgreSQL HA
   ├── Leader election
   ├── Failover
   └── Replica management
```

while:

```text
pgBackRest
   │
   ├── Full backups
   ├── Incremental backups
   ├── Differential backups
   ├── WAL archiving
   └── Restore / recovery
```

And:

```text
HAProxy
   │
   └── Application traffic routing
```

So the architecture becomes:

```text
Patroni  → PostgreSQL HA
HAProxy  → PostgreSQL traffic routing
pgBackRest → Backup & Recovery
etcd      → Patroni DCS
```

---

# 27. Backup Architecture Overview

The complete DR environment:

```text
                         APPLICATION
                              │
                              ▼
                         HAProxy VIP
                              │
                              ▼
                    ┌──────────────────┐
                    │  Patroni Cluster │
                    └────────┬─────────┘
                             │
             ┌───────────────┼───────────────┐
             │               │               │
             ▼               ▼               ▼
        dr-node-01      dr-node-02      dr-node-03
        PostgreSQL      PostgreSQL      PostgreSQL
          Primary         Standby         Standby
             │               │               │
             └───────────────┼───────────────┘
                             │
                             │ WAL / Backup
                             ▼
                    ┌──────────────────┐
                    │  Backup Server   │
                    │    10.1.0.30     │
                    └────────┬─────────┘
                             │
                             ▼
                     /var/lib/pgbackrest
```

---

# 28. Backup Verification Checklist

After configuring pgBackRest:

* [ ] PGDG repository added on all PostgreSQL nodes and on the Backup Server.
* [ ] pgBackRest installed on all PostgreSQL nodes.
* [ ] pgBackRest installed on Backup Server.
* [ ] `pgbackrest version` reports the same version on all machines.
* [ ] `/var/lib/pgbackrest` exists.
* [ ] Backup repository is owned by `postgres`.
* [ ] `postgres` user exists on Backup Server.
* [ ] SSH keys are configured.
* [ ] Backup Server can SSH to every PostgreSQL node.
* [ ] PostgreSQL nodes can SSH to Backup Server if reverse access is required.
* [ ] `/etc/pgbackrest.conf` exists on Backup Server.
* [ ] Retention settings are configured in the `[global]` section.
* [ ] PostgreSQL node pgBackRest configuration points to `10.1.0.30`.
* [ ] `archive_mode` is enabled.
* [ ] `archive_command` uses `pgbackrest archive-push`.
* [ ] PostgreSQL has been restarted so `archive_mode` is active.
* [ ] `pg_cluster_dr` stanza has been created.
* [ ] `pgbackrest check` succeeds.
* [ ] WAL archiving is working.
* [ ] Manual full backup succeeds.
* [ ] `pgbackrest info` shows the backup.
* [ ] Weekly cron job is configured.
* [ ] Backup logs/monitoring are configured.

---

# 29. Manual Backup Commands

### Create a full backup

```bash
sudo -u postgres pgbackrest \
  --stanza=pg_cluster_dr \
  --type=full \
  backup
```

### Show backup information

```bash
sudo -u postgres pgbackrest \
  --stanza=pg_cluster_dr \
  info
```

### Validate the configuration

```bash
sudo -u postgres pgbackrest \
  --stanza=pg_cluster_dr \
  check
```

---

# 30. Final Backup State

The final backup architecture should look like:

```text
                         DR PostgreSQL

                    ┌─────────────────┐
                    │     Patroni     │
                    │     Cluster     │
                    └────────┬────────┘
                             │
                  ┌──────────┴──────────┐
                  │                     │
                  ▼                     ▼
             PostgreSQL             PostgreSQL
              Primary                Standby
                  │                     │
                  │                     │
                  └──────────┬──────────┘
                             │
                             │ WAL Archive
                             │
                             ▼
                    ┌──────────────────┐
                    │  Backup Server   │
                    │    10.1.0.30     │
                    └────────┬─────────┘
                             │
                             ▼
                      pgBackRest Repo
                    /var/lib/pgbackrest
```

The key operational principle is:

```text
PostgreSQL
    │
    ├── Patroni → HA / Failover
    │
    ├── HAProxy → Application Routing
    │
    └── pgBackRest → Backup / WAL Archive / Recovery
```

This provides the DR PostgreSQL cluster with a dedicated backup repository and a repeatable backup process that is independent from the application traffic path.
