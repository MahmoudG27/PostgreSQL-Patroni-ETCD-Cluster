# PostgreSQL Restore & Point-in-Time Recovery — pgBackRest + Patroni

A backup that has never been restored is not a backup.

The Scope of Work asks for a **validated restore workflow**, and the proposal makes restore testing a formal review gate. This document is the artifact that satisfies both.

---

# 1. Why Restore Inside a Patroni Cluster Is Different

On a standalone PostgreSQL server a restore is simple:

```text
stop postgres  →  restore files  →  start postgres
```

Inside a Patroni cluster it is not, because **Patroni — not you — decides which node is the primary**, and it stores that decision in etcd, not on disk.

If you restore the data directory while Patroni is still running, one of three things happens:

```text
1. Patroni sees PostgreSQL stopped and starts it again in the middle of your restore.

2. Patroni sees the data directory changed underneath it and reinitializes the
   node from the current leader, silently undoing the entire restore.

3. Another node still holds the leader lock in etcd, so your restored node comes
   back as a replica and immediately overwrites itself from that leader.
```

All three end the same way: the restore is destroyed by the cluster's own self-healing. The procedure in Part C exists to prevent that.

---

# 2. The Two Restore Procedures

There are two completely different reasons to restore, and they need different procedures. Do not mix them.

| | Purpose | Where | Frequency | Touches production |
|---|---|---|---|---|
| **Part A / B** | Prove the backup works, measure RTO | Isolated scratch VM | Monthly, and before any client review | No |
| **Part C** | Real disaster — corruption or data loss | The live cluster | Only in an incident | Yes |

**Do the drill in Part A regularly.** It is the only way to know the emergency procedure in Part C will work when you actually need it, and it is the evidence the client will ask to see.

---

# 3. Prerequisites

Before any restore:

```text
* The stanza is healthy       → pgbackrest --stanza=pg_cluster_hq check
* At least one backup exists  → pgbackrest --stanza=pg_cluster_hq info
* You know the repository cipher passphrase, if encryption is enabled
* You know which backup or point in time you are targeting
```

Confirm what is available:

```bash
sudo -u postgres pgbackrest --stanza=pg_cluster_hq info
```

Read the output carefully. It tells you which full, differential and incremental backups exist, the WAL range each one covers, and the earliest and latest point in time you can recover to.

You cannot recover to a moment outside that WAL range.

---

# PART A — Restore Validation Drill (Scratch Node)

---

# 4. Why a Scratch Node

Restore testing on a separate VM is the right default because it:

```text
* proves the backup is actually restorable
* measures the real RTO against real data volumes
* never touches the production cluster
* can be repeated as often as you like
* produces a written record for the client
```

The alternative — testing on a cluster node — means taking a node out of the cluster, and a failed test leaves you with less redundancy than you started with.

**Recommendation: one small, permanently available restore-test VM per site.** It costs almost nothing and turns restore testing from a project into a routine.

---

# 5. Build the Restore-Test VM

Requirements:

```text
* Same OS and PostgreSQL major version as the cluster (Ubuntu + PostgreSQL 18)
* Disk at least as large as the database, plus room for WAL replay
* Network access to the Backup Server (10.0.0.30 for HQ, 10.1.0.30 for DR)
* NOT registered in Patroni, NOT in HAProxy, NOT in etcd
```

Suggested addresses:

```text
10.0.0.40    HQ restore-test VM
10.1.0.40    DR restore-test VM
```

Install PostgreSQL exactly as in `Phase2-PostgreSQL/1-Install-PostgreSQL.md`, including dropping the default cluster and creating an empty data directory.

---

# 6. Install pgBackRest on the Restore-Test VM

Add the PGDG repository first — the version must match the cluster:

```bash
sudo apt-get install -y curl ca-certificates lsb-release

sudo install -d /usr/share/postgresql-common/pgdg
sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc --fail https://www.postgresql.org/media/keys/ACCC4CF8.asc

sudo sh -c 'echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" > /etc/apt/sources.list.d/pgdg.list'

sudo apt update
sudo apt install -y pgbackrest
```

Verify the version matches the Backup Server:

```bash
pgbackrest version
```

---

# 7. Configure pgBackRest on the Restore-Test VM

The test VM reads from the same repository, so it points at the Backup Server exactly like a cluster node:

```bash
sudo tee /etc/pgbackrest.conf > /dev/null <<'PGBR'
[global]
repo1-host=10.0.0.30
repo1-host-user=postgres

[pg_cluster_hq]
pg1-path=/var/lib/postgresql/18/main
PGBR
```

---

# 8. Grant SSH Access

pgBackRest pulls the backup over SSH, so the test VM needs the same key trust the cluster nodes have.

On the test VM:

```bash
sudo -u postgres mkdir -p /var/lib/postgresql/.ssh
sudo -u postgres chmod 700 /var/lib/postgresql/.ssh

sudo -u postgres ssh-keygen \
  -t ed25519 \
  -N "" \
  -f /var/lib/postgresql/.ssh/id_ed25519

sudo -u postgres cat /var/lib/postgresql/.ssh/id_ed25519.pub
```

Add that public key to the Backup Server's `authorized_keys`, and add the Backup Server's public key to the test VM. Then verify:

```bash
sudo -u postgres ssh postgres@10.0.0.30 hostname
```

---

# 9. Restore the Latest Backup

Make sure PostgreSQL is stopped and the data directory is empty:

```bash
sudo systemctl stop postgresql
sudo rm -rf /var/lib/postgresql/18/main/*
```

Start the clock — you are measuring RTO from here:

```bash
date +%s
```

Restore:

```bash
sudo -u postgres pgbackrest \
  --stanza=pg_cluster_hq \
  --log-level-console=detail \
  restore
```

Useful flags:

```text
--set=<backup label>    restore a specific backup instead of the latest
--process-max=4         parallel restore, much faster on large databases
--delta                 only restore files that differ, needs an existing PGDATA
```

For a first drill leave the defaults, then add `--process-max` once you know how long a serial restore takes.

---

# 10. Start PostgreSQL Standalone

pgBackRest writes `recovery.signal` and a `restore_command` into `postgresql.auto.conf`. PostgreSQL will replay WAL from the repository on start.

Because Patroni is not installed here, start PostgreSQL directly:

```bash
sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl \
  -D /var/lib/postgresql/18/main \
  -l /var/lib/postgresql/18/main/recovery.log \
  start
```

Watch recovery progress:

```bash
sudo tail -f /var/lib/postgresql/18/main/recovery.log
```

Wait for:

```text
database system is ready to accept read only connections
```

---

# 11. Validate the Restored Data

Recovery finishing is not the same as the data being correct.

```bash
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
sudo -u postgres psql -c "\l+"
sudo -u postgres psql -c "SELECT now(), pg_last_wal_replay_lsn();"
```

Then run checks that mean something for the actual application:

```sql
-- row counts on the largest tables
SELECT schemaname, relname, n_live_tup
FROM pg_stat_user_tables
ORDER BY n_live_tup DESC
LIMIT 20;

-- the newest row in a table that is written continuously
SELECT max(created_at) FROM <busiest_table>;
```

That last query is the one that matters: it tells you **how much data the restore actually recovered**, which is your real RPO.

---

# 12. Record the RTO

Stop the clock:

```bash
date +%s
```

Record, every drill:

```text
Date of drill
Backup label restored
Database size
Restore duration           (pgbackrest restore)
WAL replay duration        (pg_ctl start until ready)
Total RTO
Newest data timestamp recovered
Result: PASS / FAIL
Notes
```

Keep this table in the repository. It is the most persuasive document you can put in front of the client, and the proposal already commits to producing it.

---

# 13. Clean Up

```bash
sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl \
  -D /var/lib/postgresql/18/main stop

sudo rm -rf /var/lib/postgresql/18/main/*
```

Leave the VM in place for the next drill.

---

# PART B — Point-in-Time Recovery

---

# 14. Choose the Recovery Target

PITR answers: *put the database back exactly as it was at 14:30, just before someone ran that DELETE.*

pgBackRest supports these target types:

```text
--type=default     recover to the end of all available WAL (the default)
--type=immediate   stop as soon as the database is consistent (fastest)
--type=time        recover to a specific timestamp
--type=lsn         recover to a specific WAL position
--type=xid         recover to a specific transaction ID
--type=name        recover to a named restore point
```

`--type=time` is what you will use in practice.

Find the valid range first:

```bash
sudo -u postgres pgbackrest --stanza=pg_cluster_hq info
```

---

# 15. Restore With a Time Target

On the restore-test VM, with an empty data directory:

```bash
sudo -u postgres pgbackrest \
  --stanza=pg_cluster_hq \
  --type=time \
  --target="2026-08-23 14:30:00+03" \
  --log-level-console=detail \
  restore
```

Important details:

```text
* Always include the timezone offset. Without it PostgreSQL uses the server's
  timezone, which may not be the one you meant.

* pgBackRest automatically picks the newest backup taken BEFORE the target
  and replays WAL forward from there.

* The target must fall inside the WAL range shown by `pgbackrest info`.
```

---

# 16. Why Recovery Pauses at the Target

By default pgBackRest writes:

```ini
recovery_target_action = pause
```

PostgreSQL replays WAL up to the target and then **stops and waits** instead of finishing recovery. This is deliberate, and it is the most important safety feature in PITR.

Start PostgreSQL:

```bash
sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl \
  -D /var/lib/postgresql/18/main \
  -l /var/lib/postgresql/18/main/recovery.log \
  start
```

The log will show:

```text
recovery stopping before commit of transaction ...
recovery has paused
```

The database is now open **read-only**, positioned exactly at your target.

---

# 17. Inspect Before Promoting

This is the whole point of pausing:

```sql
SELECT pg_is_in_recovery();          -- t
SELECT pg_last_wal_replay_lsn();

-- Is the deleted data back?
SELECT count(*) FROM orders WHERE created_at > '2026-08-23';

-- Is the bad change gone?
SELECT * FROM orders WHERE id = 12345;
```

If the target was wrong, **do not promote**. Stop PostgreSQL, wipe the data directory, and restore again with a different `--target`. You can repeat this as many times as you like — the repository is untouched.

---

# 18. Promote

Once the data is confirmed correct:

```bash
sudo -u postgres psql -c "SELECT pg_wal_replay_resume();"
```

Or promote directly:

```bash
sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl \
  -D /var/lib/postgresql/18/main promote
```

Verify:

```sql
SELECT pg_is_in_recovery();   -- f, the database is now writable
```

**Promotion creates a new timeline.** Everything after the recovery target is now unreachable on this timeline. This is exactly why Part C is more complicated than Part A.

---

# 19. Restoring a Single Database

If only one database was damaged:

```bash
sudo -u postgres pgbackrest \
  --stanza=pg_cluster_hq \
  --db-include=appdb \
  --type=time \
  --target="2026-08-23 14:30:00+03" \
  restore
```

Databases not listed are restored as empty shells and are unusable. You then dump the recovered database out:

```bash
sudo -u postgres pg_dump -d appdb -Fc -f /tmp/appdb.dump
```

and load it into the live cluster.

> **This is usually the right answer for an application-level mistake.**
>
> Restore on the scratch node, dump the affected table, load it into production.
> No cluster downtime at all, and none of Part C is needed.

---

# PART C — Emergency Restore Into the Live Cluster

---

# 20. When to Use This

Only when the whole cluster must go back in time:

```text
* Data corruption that replicated to every node
* A destructive migration that ran on the primary and replicated everywhere
* Loss of the entire data directory on all nodes
```

If only **one node** is broken, use section 32 instead.

If only **one table or database** is affected, use the dump approach in section 19 instead — it is faster and costs no downtime.

---

# 21. What Patroni Keeps in etcd

Before touching anything, understand what you are about to delete. Under the namespace and scope from `patroni.yml` (`/db` + `pg_cluster_hq`):

```text
/db/pg_cluster_hq/config       cluster-wide dynamic configuration
/db/pg_cluster_hq/initialize   the database system identifier of this cluster
/db/pg_cluster_hq/leader       the leader lock, has a TTL, renewed constantly
/db/pg_cluster_hq/members/*    one key per node with its state and LSN
/db/pg_cluster_hq/history      the timeline history
/db/pg_cluster_hq/status       last known leader position
```

Inspect them:

```bash
etcdctl --endpoints=10.0.0.4:2379 get --prefix /db/pg_cluster_hq/ --keys-only
```

The two that matter for a restore are `initialize` and `leader`:

```text
initialize   Patroni compares this to the system identifier inside PGDATA. It is
             how Patroni knows "this data directory belongs to this cluster".

leader       Whoever holds this lock is the primary. Any node that does NOT hold
             it will make itself a replica of whoever does — which is exactly how
             a restore gets silently overwritten.
```

---

# 22. Step 1 — Stop Patroni Everywhere

Pause first, so Patroni stops managing PostgreSQL:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml pause pg_cluster_hq
```

Confirm `Maintenance mode: on`:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list
```

Then stop the Patroni service on **every node**:

```bash
sudo systemctl stop patroni
```

> **This must be done on all nodes before you continue.**
>
> A single running Patroni will re-create the etcd keys you are about to delete,
> and will start PostgreSQL underneath your restore.

---

# 23. Step 2 — Stop PostgreSQL Everywhere

Patroni normally stops PostgreSQL when it stops, but confirm on every node:

```bash
sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl \
  -D /var/lib/postgresql/18/main status
```

If anything is still running:

```bash
sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl \
  -D /var/lib/postgresql/18/main -m fast stop
```

---

# 24. Step 3 — Choose One Node and Restore

Pick **one** node to become the new primary. Everything else will be rebuilt from it.

Keep the old data directory if there is any chance you will need it — a corrupted directory still holds evidence of what went wrong:

```bash
sudo mv /var/lib/postgresql/18/main /var/lib/postgresql/18/main.broken
sudo -u postgres mkdir -p /var/lib/postgresql/18/main
sudo chmod 700 /var/lib/postgresql/18/main
```

Restore:

```bash
sudo -u postgres pgbackrest \
  --stanza=pg_cluster_hq \
  --type=time \
  --target="2026-08-23 14:30:00+03" \
  --log-level-console=detail \
  restore
```

---

# 25. Step 4 — Recover Manually, Not Through Patroni

Start PostgreSQL directly with `pg_ctl`, **not** with Patroni:

```bash
sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl \
  -D /var/lib/postgresql/18/main \
  -l /var/lib/postgresql/18/main/recovery.log \
  start
```

Recovery pauses at the target, as in section 16. Verify the data now, exactly as in section 17. This is your last chance to change the target cheaply.

---

# 26. Step 5 — Promote, Then Stop Again

Once the data is confirmed:

```bash
sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl \
  -D /var/lib/postgresql/18/main promote

sudo -u postgres psql -c "SELECT pg_is_in_recovery();"   # must return f
```

Then stop it again so Patroni can take ownership cleanly:

```bash
sudo -u postgres /usr/lib/postgresql/18/bin/pg_ctl \
  -D /var/lib/postgresql/18/main -m fast stop
```

---

# 27. Step 6 — Remove the Patroni Cluster State From etcd

The etcd state still describes the **old** cluster: old leader, old timeline, old member positions. If you start Patroni now it will compare the restored data directory against that stale state and reinitialize your restore away.

With Patroni stopped everywhere:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml remove pg_cluster_hq
```

It prompts for:

```text
1. the cluster name          → pg_cluster_hq
2. the confirmation phrase   → Yes I am aware
3. the current master name   → only if the cluster still looks healthy
```

Or remove the keys directly:

```bash
etcdctl --endpoints=10.0.0.4:2379 del --prefix /db/pg_cluster_hq/
```

Verify nothing is left:

```bash
etcdctl --endpoints=10.0.0.4:2379 get --prefix /db/pg_cluster_hq/ --keys-only
```

> **Note**
>
> This deletes Patroni's *metadata*, not your data. The restored data directory is
> untouched. You are telling Patroni "forget everything you knew about this
> cluster" so that it re-learns from the node you just restored.

---

# 28. Step 7 — Start Patroni on the Restored Node Only

Start Patroni on **that one node**, and nothing else:

```bash
sudo systemctl start patroni
sudo journalctl -u patroni -f
```

What Patroni does:

```text
1. Finds no `initialize` key in etcd.
2. Finds a valid, initialized data directory on disk.
3. Adopts it — writes the system identifier from PGDATA into `initialize`.
4. Takes the leader lock.
5. Starts PostgreSQL as the primary.
```

Confirm — you should see exactly one node, with role `Leader`:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list
```

> **This is why all other nodes must stay stopped.**
>
> If another node's Patroni starts first, it adopts *its own* stale data directory
> and becomes the leader — and your restored node is then rebuilt from the
> corrupted data you were trying to escape.

---

# 29. Step 8 — Rebuild the Replicas

The other nodes still hold data from the old timeline — data that is now *ahead* of the new leader. Bring them back **one at a time**.

The simple way, letting Patroni do the work:

```bash
sudo systemctl start patroni

sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml reinit pg_cluster_hq hq-node-02
```

`patroni.yml` sets `use_pg_rewind: true`, so Patroni first tries `pg_rewind`, which is much faster than a full clone because it only copies the blocks that actually diverged. `pg_rewind` works here because the cluster was initialised with `data-checksums`.

If `pg_rewind` fails, Patroni falls back to a full clone. Either way the result is correct — only the duration differs.

To force a clean full clone instead:

```bash
sudo systemctl stop patroni
sudo mv /var/lib/postgresql/18/main /var/lib/postgresql/18/main.old
sudo -u postgres mkdir -p /var/lib/postgresql/18/main
sudo chmod 700 /var/lib/postgresql/18/main
sudo systemctl start patroni
```

**Wait for each replica to reach `streaming` before starting the next one.** Rebuilding several at once will saturate the leader's disk and network.

```bash
watch -n 2 'sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml list'
```

---

# 30. Step 9 — Resume Normal Operation

Once every node shows `running` / `streaming`:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml resume pg_cluster_hq
```

Confirm:

```text
Maintenance mode is gone
One Leader, the rest Replica
Lag in MB is 0 on all replicas
```

Then verify the connectivity layer picked up the new leader:

```bash
curl -s http://10.0.0.100:8404/stats
psql -h 10.0.0.100 -p 5432 -U postgres -c "SELECT pg_is_in_recovery();"
```

---

# 31. What Happens to the DR Site

**The DR cluster is now on a dead timeline.** It was replicating the old HQ timeline, which no longer exists after the promotion in section 26.

DR must be rebuilt from the new HQ primary:

```bash
# On every DR node
sudo systemctl stop patroni

# Remove the DR cluster state
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml remove pg_cluster_dr

# Wipe the DR data directories
sudo mv /var/lib/postgresql/18/main /var/lib/postgresql/18/main.old
sudo -u postgres mkdir -p /var/lib/postgresql/18/main
sudo chmod 700 /var/lib/postgresql/18/main

# Start the DR leader first, let it clone from HQ, then start the rest
sudo systemctl start patroni
```

Also confirm the replication slot exists on the new HQ primary:

```sql
SELECT * FROM pg_replication_slots WHERE slot_name = 'dr_standby_slot';
```

> **Plan for this.**
>
> A full-cluster PITR at HQ always costs a DR rebuild. On a large database that
> rebuild is the longest part of the whole incident, and it must appear in the
> RTO estimate you give the client.

---

# PART D — Cases That Are Not a Full Restore

---

# 32. A Single Corrupted Replica

By far the most common real case, and it needs none of Part C:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml reinit pg_cluster_hq hq-node-03
```

Patroni rebuilds that node from the current leader. The cluster stays online, no etcd state is touched, and no backup is involved.

---

# 33. Rebuilding a Replica From Backup Instead of From the Leader

On a large database a full clone from the leader hurts production performance. pgBackRest can be used as the replica creation method instead, so the clone is read from the Backup Server rather than from the primary.

Add to `patroni.yml` under `postgresql:`:

```yaml
postgresql:
  create_replica_methods:
    - pgbackrest
    - basebackup
  pgbackrest:
    command: /usr/bin/pgbackrest --stanza=pg_cluster_hq --delta restore
    keep_data: True
    no_params: True
```

Patroni tries `pgbackrest` first and falls back to `basebackup` if it fails.

---

# 34. Restore Checklist

Before you call the restore workflow "validated":

```text
* [ ] A restore-test VM exists in each site.
* [ ] A full restore to the latest backup completed successfully.
* [ ] A PITR to a chosen timestamp completed successfully.
* [ ] The recovered data was verified against a known row, not just row counts.
* [ ] Restore duration and total RTO were measured and written down.
* [ ] A single-database restore plus dump/load was tested.
* [ ] `patronictl reinit` of one replica was tested on the live cluster.
* [ ] The in-cluster procedure (Part C) was walked through on the demo cluster.
* [ ] The DR rebuild cost after an HQ PITR was measured.
* [ ] The repository cipher passphrase is stored somewhere outside the backup.
```

---

# 35. Drill Record

Keep one row per drill:

| Date | Site | Backup label | DB size | Restore time | WAL replay | Total RTO | Result |
|------|------|--------------|---------|--------------|------------|-----------|--------|
|      |      |              |         |              |            |           |        |

This table is the deliverable that closes the Scope of Work requirement for a *validated* restore workflow.
