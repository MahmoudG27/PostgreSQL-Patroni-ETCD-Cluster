# HQ / DR Disaster Recovery, Split-Brain Prevention & Planned Failback

This document defines the operational procedure for a two-site PostgreSQL HA/DR architecture using **Patroni 4.1.4**, PostgreSQL 18, and etcd.

The environment consists of:

* **HQ Site:** 5 PostgreSQL + Patroni nodes and a 5-node etcd cluster.
* **DR Site:** 5 PostgreSQL + Patroni nodes and a 5-node etcd cluster.
* **Within each site:** PostgreSQL replication is synchronous.
* **Between HQ and DR:** PostgreSQL replication is asynchronous.
* **Normal state:** HQ is the Primary site and DR is the Standby Cluster.
* **Disaster state:** HQ is unavailable and DR is manually promoted to Primary.
* **Recovery state:** HQ is rebuilt/rejoined as a Standby Cluster following DR.
* **Failback:** DR is manually switched back to HQ during a controlled maintenance window.

The primary objectives are:

1. Prevent Split-Brain.
2. Ensure only one site is writable at any time.
3. Make DR promotion an explicit manual operation.
4. Safely recover HQ after DR has become Primary.
5. Preserve the synchronous HA behavior inside each site.
6. Maintain asynchronous replication between sites.
7. Provide a controlled and auditable failback procedure.

---

# 1. Architecture

## 1.1 Normal Operation

The normal architecture is:

```text
                         APPLICATION
                              │
                              ▼
                         HQ VIP / LB
                              │
                              ▼
                    ┌───────────────────┐
                    │    HQ PRIMARY     │
                    │   PostgreSQL      │
                    └─────────┬─────────┘
                              │
                     Synchronous replication
                              │
             ┌────────────────┼────────────────┐
             ▼                ▼                ▼
          HQ Node 2        HQ Node 3        HQ Node 4
             │
             ▼
          HQ Node 5

                 ASYNCHRONOUS SITE REPLICATION
                              │
                              ▼

                    ┌───────────────────┐
                    │   DR STANDBY      │
                    │   PostgreSQL      │
                    └─────────┬─────────┘
                              │
                     Synchronous replication
                              │
             ┌────────────────┼────────────────┐
             ▼                ▼                ▼
          DR Node 2         DR Node 3        DR Node 4
             │
             ▼
          DR Node 5
```

The important distinction is:

```text
Inside HQ:
PostgreSQL replication = Synchronous

Inside DR:
PostgreSQL replication = Synchronous

HQ → DR:
PostgreSQL replication = Asynchronous
```

The asynchronous link between the sites is intentional.

Therefore, in a disaster, some transactions that were committed on HQ may not yet exist on DR.

This must be reflected in the documented RPO.

---

# 2. DCS / etcd Architecture

Each site has its own independent etcd cluster.

```text
                 HQ SITE
       ┌─────────────────────────┐
       │       HQ etcd            │
       │                           │
       │  etcd-01                 │
       │  etcd-02                 │
       │  etcd-03                 │
       │  etcd-04                 │
       │  etcd-05                 │
       └────────────┬──────────────┘
                    │
                    │
              HQ Patroni
                    │
             HQ PostgreSQL


                 DR SITE
       ┌─────────────────────────┐
       │       DR etcd            │
       │                           │
       │  etcd-01                 │
       │  etcd-02                 │
       │  etcd-03                 │
       │  etcd-04                 │
       │  etcd-05                 │
       └────────────┬──────────────┘
                    │
                    │
              DR Patroni
                    │
             DR PostgreSQL
```

The HQ and DR Patroni clusters must use independent DCS scopes.

The HQ and DR clusters must not share the same Patroni cluster scope.

The DR Standby Cluster has its own Patroni leader lock in the DR DCS.

Patroni documentation explicitly describes a Standby Cluster as an independent cluster that follows a remote PostgreSQL source and maintains its own leader lock in its own DCS.

---

# 3. Critical Split-Brain Rule

At all times, only one site may be the writable Primary.

Valid states are:

```text
NORMAL:

HQ = Primary
DR = Standby
```

or:

```text
DISASTER:

HQ = Down / Fenced
DR = Primary
```

or:

```text
HQ RECOVERY:

HQ = Standby
DR = Primary
```

or:

```text
FAILBACK COMPLETE:

HQ = Primary
DR = Standby
```

The following state is never acceptable:

```text
❌ HQ = Primary
❌ DR = Primary
```

Because replication between sites is asynchronous, the DR promotion must always be treated as a controlled manual disaster operation.

---

# 4. Disaster Scenario

During normal operation:

```text
HQ = Primary
DR = Standby
```

If HQ experiences a major failure:

```text
                  HQ FAILURE

              HQ SITE
       ┌───────────────────┐
       │   HQ PostgreSQL   │
       │       DOWN        │
       └───────────────────┘

                  ↓

          Manual verification

                  ↓

             HQ FENCED

                  ↓

            DR Promotion

                  ↓

              DR PRIMARY

                  ↓

             Application
```

The DR promotion must not happen simply because the HQ site is temporarily unreachable from one monitoring point.

A manual operator must verify that HQ is actually unavailable or isolated before promoting DR.

---

# 5. Manual Verification Before DR Promotion

Before promoting DR, verify that HQ is genuinely down or has been fenced from the application and database network.

The operator must establish that HQ cannot continue accepting writes.

Examples of verification include:

* Confirming the HQ site is physically unavailable.
* Confirming the HQ network is isolated.
* Confirming all HQ PostgreSQL nodes are unavailable.
* Confirming the HQ application VIP/LB is unavailable or disabled.
* Confirming application traffic cannot reach HQ.
* Confirming the HQ Patroni nodes cannot continue operating as a writable cluster.
* Using an approved infrastructure-level fencing mechanism where available.

The objective is:

```text
HQ cannot accept writes
        +
HQ cannot become Primary
        +
DR is the only site allowed to become writable
```

Only after this verification should DR promotion begin.

---

# 6. Verify the DR Cluster Before Promotion

From a DR node:

```bash
patronictl -c /etc/patroni/patroni.yml list
```

Verify that the DR cluster is healthy.

Conceptually:

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

The exact node selected as Leader may be different.

The important requirement is that DR has a healthy candidate that can become the writable Primary.

Because HQ → DR replication is asynchronous, verify the latest available replication position and understand the potential RPO before promotion.

---

# 7. DR Promotion — Remove `standby_cluster`

In Patroni 4.1.4, the DR cluster is operating as a Standby Cluster while the following dynamic configuration exists:

```yaml
standby_cluster:
  host: <HQ-VIP>
  port: 5432
```

To detach DR from the remote HQ Primary and make DR an independent Primary cluster, modify the Patroni dynamic configuration in the DR DCS.

Run:

```bash
patronictl -c /etc/patroni/patroni.yml edit-config
```

Remove the entire:

```yaml
standby_cluster:
```

section.

Save and exit.

Patroni 4.1.4 recognizes `standby_cluster` from the global dynamic configuration and determines whether the cluster is operating in Standby Cluster mode from that configuration.

After the configuration change, verify:

```bash
patronictl -c /etc/patroni/patroni.yml list
```

The target state is:

```text
DR = Primary
```

Do not send application traffic to DR until the DR Primary has been explicitly verified.

---

# 8. DR Synchronous Replication

The DR site contains five PostgreSQL/Patroni nodes.

The synchronous replication configuration applies to the nodes inside the DR cluster.

For example:

```text
DR Primary
    │
    ├── synchronous → DR Node 2
    ├── synchronous → DR Node 3
    ├── synchronous → DR Node 4
    └── synchronous → DR Node 5
```

The cross-site HQ → DR replication is asynchronous and must not be included as a synchronous standby for the DR Primary.

Patroni's `synchronous_mode` and `synchronous_node_count` operate on members of the Patroni cluster and manage PostgreSQL's `synchronous_standby_names`.

The DR configuration must therefore ensure that remote HQ members are never selected as DR synchronous standbys.

If strict synchronous durability is required inside the site, evaluate:

```yaml
synchronous_mode: on
synchronous_mode_strict: true
```

with the required:

```yaml
synchronous_node_count: <required-count>
```

However, `synchronous_mode_strict` can block application writes when no eligible synchronous standby is available. This must be an explicit business/availability decision.

---

# 9. Verify DR Is the Only Writable Site

After DR promotion:

```text
DR = Primary
HQ = Down / Fenced
```

Verify the DR Patroni REST endpoint:

```bash
curl -i http://<DR_PRIMARY_IP>:8008/primary
```

Expected:

```text
HTTP/1.1 200 OK
```

Patroni documents `/primary` and `/read-write` as endpoints that return HTTP 200 only when the node is operating as the Primary with the leader lock.

Then switch application traffic to:

```text
DR HAProxy / VIP
```

Only after the DR Primary has been verified should application writes be enabled.

---

# 10. DR Primary Is Now the Source of Truth

After promotion:

```text
DR = Primary
HQ = Down
```

Applications must write only to DR.

The data flow becomes:

```text
                    DR SITE

              ┌───────────────┐
              │  DR PRIMARY   │
              └───────┬───────┘
                      │
                Synchronous
                      │
          ┌───────────┼───────────┐
          ▼           ▼           ▼
       DR Node 2   DR Node 3   DR Node 4
                      │
                      ▼
                   DR Node 5

                      │
                      │
                 Async WAL
                      │
                      ▼

                    HQ SITE
```

HQ must not be allowed to become writable.

---

# 11. HQ Returns After the Disaster

When HQ servers return:

> **Do not immediately start Patroni normally.**

The first action on every HQ PostgreSQL node is:

```bash
sudo systemctl stop patroni
```

Verify:

```bash
sudo systemctl status patroni
```

Also verify that PostgreSQL is not running independently:

```bash
pgrep -a postgres
```

If PostgreSQL is running outside Patroni control, stop it before continuing.

Perform this operation on all five HQ nodes.

---

# 12. Verify HQ etcd Before Cleaning Its Patroni State

The HQ etcd cluster may return with its old Patroni state.

The five etcd nodes must have quorum before using the HQ DCS for cleanup.

Verify etcd health using the actual HQ etcd endpoints.

For example:

```bash
etcdctl endpoint health \
  --endpoints=https://<HQ-ETCD-01>:2379,https://<HQ-ETCD-02>:2379,https://<HQ-ETCD-03>:2379,https://<HQ-ETCD-04>:2379,https://<HQ-ETCD-05>:2379
```

If TLS is enabled, provide the appropriate certificate, key, and CA options.

The expected result is that the required etcd endpoints are healthy and the cluster has quorum.

Do not run Patroni DCS cleanup if the HQ etcd cluster is not healthy.

---

# 13. Remove the Old HQ Patroni Cluster State

The recovered HQ DCS may still contain the old Patroni cluster state and leader information.

After verifying:

```text
HQ = Fenced / Not Writable
DR = Primary
HQ etcd = Healthy
```

run the cleanup from one HQ node only:

```bash
patronictl -c /etc/patroni/patroni.yml remove pg_cluster_hq
```

Confirm the removal.

This operation affects the Patroni cluster state stored in the configured HQ DCS.

It does not mean that the PostgreSQL data directory has been deleted.

The important point is:

```text
HQ etcd state
        ↓
old HQ Patroni state removed
        ↓
HQ can be rebuilt/rejoined safely
```

The HQ and DR DCS are independent. Removing the HQ cluster state does not remove the DR Patroni state.

---

# 14. Do Not Assume Existing HQ Data Is Safe

After a disaster, HQ's old PostgreSQL data may represent an older timeline.

For example:

```text
Before disaster:

HQ:
A B C D

DR:
A B C D
```

After DR becomes Primary:

```text
HQ:
A B C D

DR:
A B C D E F G H
```

When HQ returns:

```text
HQ:
A B C D

DR:
A B C D E F G H
```

DR is now the source of truth.

HQ must therefore be reconciled with the current DR timeline before it is used as a Standby.

---

# 15. Configure HQ as a Standby Cluster

The HQ cluster must follow the DR Primary.

For an already initialized Patroni cluster, do not rely on changing only:

```text
bootstrap.dcs
```

in `patroni.yml`.

Patroni documentation states that `bootstrap.dcs` options are applied only during cluster bootstrap; changes after bootstrap must be made through the DCS.

Because the previous HQ cluster state has been removed, the HQ cluster can be rebuilt using its standby-cluster bootstrap configuration.

The configuration should conceptually contain:

```yaml
bootstrap:
  dcs:

    standby_cluster:
      host: <DR-VIP>
      port: 5432
```

The `<DR-VIP>` should preferably represent a stable endpoint that always routes to the current DR Primary.

---

# 16. DR Endpoint

Prefer:

```text
DR HAProxy / VIP
```

instead of:

```text
dr-node-01
```

This prevents HQ from depending on one specific DR server.

If a single stable VIP is not available, Patroni 4.1.4 also supports specifying multiple source hosts in `standby_cluster.host`.

Example:

```yaml
standby_cluster:
  host: dr-node-01,dr-node-02,dr-node-03,dr-node-04,dr-node-05
  port: 5432
```

Patroni can use multiple hosts to identify a writable source and handle the source-node selection.

A DR HAProxy/VIP is generally easier to operate if it is already part of the DR architecture.

---

# 17. Cross-Site Replication Must Remain Asynchronous

The HQ Standby Cluster follows the DR Primary asynchronously.

The architecture is:

```text
DR Site
========

DR Primary
    │
    │ synchronous
    ▼
DR local replicas


    │
    │ asynchronous
    ▼


HQ Site
========

HQ Standby Leader
    │
    │ synchronous
    ▼
HQ local replicas
```

The remote link must not become part of the local synchronous replication quorum.

This preserves write availability at the active site when the remote site is unavailable.

---

# 18. Replication Slot Considerations

If:

```yaml
primary_slot_name: hq_standby_slot
```

is used in the HQ `standby_cluster` configuration, the corresponding physical replication slot must exist on the DR Primary.

Patroni 4.1.4 does **not** automatically create the corresponding remote-primary slot for the Standby Cluster. The Patroni documentation recommends creating the slot on the primary cluster or maintaining it using Patroni's permanent replication slots feature.

The slot can be created manually on DR:

```sql
SELECT pg_create_physical_replication_slot('hq_standby_slot');
```

Or managed using Patroni's permanent replication slot mechanism where appropriate.

However, there is an important Patroni 4.1.4 limitation:

> When replication slots are used by a Standby Cluster, `pg_rewind` may fail on that Standby Cluster.

Therefore, do not design the recovery procedure around the assumption that:

```text
primary_slot_name
+
pg_rewind
```

will always work together.

This must be tested explicitly in the target production topology.

---

# 19. WAL Retention and RPO

Because HQ → DR replication is asynchronous, DR may receive WAL later than HQ generates it.

After HQ is down:

```text
HQ
│
│ X
│
└── no replication

DR
│
├── new WAL
├── new WAL
└── new WAL
```

When HQ returns, the required WAL history may or may not still be available on DR.

Therefore, the recovery strategy must not depend only on:

```yaml
wal_keep_size
```

or on local `pg_wal`.

For production recovery, WAL retention should be integrated with the backup/archive strategy, such as pgBackRest.

The goal is:

```text
DR Primary
   │
   ├── Streaming WAL
   │
   └── WAL Archive / pgBackRest
             │
             ▼
        Recovery / Rebuild
```

The actual retention period must be sized according to the maximum expected HQ outage and the required RPO/RTO.

---

# 20. `pg_rewind` Requirements

Patroni can use:

```yaml
postgresql:
  use_pg_rewind: true
```

to rewind a diverged PostgreSQL data directory when the required conditions are met.

For `pg_rewind` to operate correctly, PostgreSQL must have been initialized with data page checksums or have:

```yaml
wal_log_hints: on
```

Patroni 4.1.4 explicitly documents the requirement for either data checksums or `wal_log_hints=on`.

For PostgreSQL 18, verify the actual running configuration:

```sql
SHOW wal_log_hints;
```

and:

```sql
SHOW data_checksums;
```

The preferred production approach should be to initialize the clusters with data checksums enabled where operationally appropriate.

---

# 21. `pg_rewind` Is Not Guaranteed

The recovery sequence should be:

```text
HQ returns
    │
    ▼
Attempt safe reconciliation
    │
    ├── pg_rewind succeeds
    │        │
    │        ▼
    │     Continue
    │
    └── pg_rewind cannot be used
             │
             ▼
        Rebuild / Re-seed
             │
             ▼
        pgBackRest / basebackup
```

Do not assume that `pg_rewind` will always be available.

It can fail when the required WAL/timeline history is unavailable.

Additionally, Patroni 4.1.4 documents a limitation involving replication slots on Standby Clusters and `pg_rewind`.

---

# 22. Replica Creation Methods

For production environments, define explicit replica creation methods.

Example:

```yaml
postgresql:
  create_replica_methods:
    - pgbackrest
    - basebackup
```

The exact `pgbackrest` method must be defined in the Patroni configuration according to the installed pgBackRest integration.

For example:

```yaml
postgresql:
  create_replica_methods:
    - pgbackrest
    - basebackup

  use_pg_rewind: true
```

The purpose is:

```text
Preferred:
pgBackRest

Fallback:
pg_basebackup
```

The exact command, repository, stanza, credentials, and retention policy must be validated separately in the production environment.

---

# 23. Important: Do Not Confuse Replica Creation With Rewind

These are different recovery mechanisms.

### `pg_rewind`

Used when:

```text
Old HQ data
     ↓
Timeline divergence
     ↓
Required WAL/history available
     ↓
Rewind to current timeline
```

### Replica rebuild

Used when:

```text
pg_rewind unavailable
        OR
required WAL/history unavailable
        OR
data cannot safely be rewound
```

Then:

```text
Current DR Primary
        │
        ▼
pgBackRest / pg_basebackup
        │
        ▼
New HQ Standby
```

A production runbook must support both paths.

---

# 24. Start HQ Patroni

After the HQ DCS has been cleaned and the Standby Cluster configuration is ready, start Patroni one node at a time.

First node:

```bash
sudo systemctl start patroni
```

Monitor:

```bash
sudo systemctl status patroni
```

And:

```bash
sudo journalctl -u patroni -f
```

Verify that the node is connecting to DR.

Do not start all five nodes simultaneously without monitoring the first node.

---

# 25. HQ Standby Cluster Behavior

Patroni Standby Cluster consists of:

* A Standby Leader.
* Local replicas following the Standby Leader.
* A remote Primary/source in the other site.

The Standby Leader replicates from the remote Primary while local HQ replicas can cascade from it.

Conceptually:

```text
                  DR SITE

              DR PRIMARY
                   │
                   │ Async
                   ▼

                  HQ SITE

             HQ Standby Leader
                   │
          ┌────────┼────────┐
          ▼        ▼        ▼
       HQ Node 2 HQ Node 3 HQ Node 4
                   │
                   ▼
                HQ Node 5
```

The exact node selected as Standby Leader is managed by Patroni.

---

# 26. Verify HQ Is Not Primary

From HQ:

```bash
patronictl -c /etc/patroni/patroni.yml list
```

Verify that HQ is operating as a Standby Cluster.

Also verify the Patroni REST API:

```bash
curl -i http://<HQ_NODE_IP>:8008/standby-leader
```

A Standby Leader should return HTTP 200 from:

```text
/standby-leader
```

Patroni documents this endpoint specifically for Standby Cluster leaders.

The target state is:

```text
DR = Primary
HQ = Standby Cluster
```

---

# 27. Verify Replication

On the DR Primary:

```sql
SELECT
    application_name,
    client_addr,
    state,
    sync_state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn
FROM pg_stat_replication;
```

The HQ Standby connection should be asynchronous.

It must not appear as one of the synchronous DR standbys.

The local DR synchronous replicas should be the members selected by Patroni for:

```text
synchronous_standby_names
```

---

# 28. Verify Local Synchronous Replication

On the DR Primary:

```sql
SHOW synchronous_standby_names;
```

Verify that only the intended DR members participate.

The HQ remote standby must not be part of the DR synchronous set.

Likewise, after failback, the DR members must not become synchronous members of the HQ cluster across the WAN.

---

# 29. Application Routing During HQ Recovery

While DR is Primary:

```text
Application
     │
     ▼
DR VIP / HAProxy
     │
     ▼
DR Primary
```

Do not route application writes to:

```text
HQ VIP
```

HQ remains a recovery/standby site.

---

# 30. Safe Temporary State

After HQ has been successfully recovered:

```text
                 DR SITE

          ┌───────────────────┐
          │   DR PRIMARY      │
          │   PostgreSQL      │
          └─────────┬─────────┘
                    │
                    │ Async
                    ▼

                 HQ SITE

          ┌───────────────────┐
          │ HQ STANDBY        │
          │ PostgreSQL        │
          └───────────────────┘

Application
     │
     ▼
DR VIP
```

This is the preferred temporary state.

There is no requirement to immediately fail back to HQ.

---

# 31. Do Not Immediately Fail Back

Keep:

```text
DR = Primary
HQ = Standby
```

until all of the following are verified:

* All HQ nodes are healthy.
* HQ local synchronous replication is healthy.
* DR → HQ asynchronous replication is healthy.
* Replication lag is within the accepted threshold.
* Required WAL history is available.
* HAProxy/VIPs are healthy.
* etcd clusters are healthy.
* Patroni health checks are healthy.
* Monitoring is healthy.
* Backup/pgBackRest status is healthy.
* The application team is ready for a maintenance window.

---

# 32. Planned Failback

Failback is a controlled operation.

The target is:

```text
Current:

DR = Primary
HQ = Standby

        ↓

Controlled failback

        ↓

Final:

HQ = Primary
DR = Standby
```

Because the cross-site replication is asynchronous, failback must include an explicit replication synchronization check.

---

# 33. Stop Application Writes

Before failback:

```text
Application
     │
     X
     │
     ▼
DR Primary
```

Stop or pause application writes.

The exact method depends on the application architecture.

The objective is:

```text
No new application writes
```

while the Primary role is transferred.

---

# 34. Verify HQ Synchronization

Before making HQ Primary, verify that HQ has received all required data from DR.

On the DR Primary:

```sql
SELECT
    application_name,
    client_addr,
    state,
    sent_lsn,
    write_lsn,
    flush_lsn,
    replay_lsn
FROM pg_stat_replication;
```

Also check Patroni:

```bash
patronictl -c /etc/patroni/patroni.yml list
```

The exact definition of "fully synchronized" should be based on the organization's RPO.

Do not simply assume:

```text
streaming = zero lag
```

Measure the actual replay position.

---

# 35. Important RPO Consideration

Because:

```text
DR → HQ = Asynchronous
```

the following condition must be verified before failback:

```text
Required DR WAL
       ↓
Received by HQ
       ↓
Replayed by HQ
```

Only then should HQ be considered ready to become the new Primary.

If the business requires zero data loss for failback, the application must remain stopped until the required LSN synchronization condition is verified.

---

# 36. Planned Failback — Promote HQ

Once:

```text
Application writes = stopped
HQ = fully synchronized
DR = current Primary
```

the role transition can begin.

The Patroni 4.1.4 dynamic configuration must be changed through the DCS.

On the HQ cluster:

```bash
patronictl -c /etc/patroni/patroni.yml edit-config
```

Remove:

```yaml
standby_cluster:
```

Save and exit.

Removing the `standby_cluster` configuration detaches the HQ cluster from Standby Cluster mode.

Verify the resulting state:

```bash
patronictl -c /etc/patroni/patroni.yml list
```

The target state is:

```text
HQ = Primary
```

Do not enable application writes until HQ Primary has been explicitly verified.

---

# 37. Demote DR to Standby

Once HQ is confirmed as the new Primary, configure DR to follow HQ.

On the DR cluster:

```bash
patronictl -c /etc/patroni/patroni.yml edit-config
```

Add:

```yaml
standby_cluster:
  host: <HQ-VIP>
  port: 5432
```

The HQ VIP should route to the current HQ Primary.

Save and exit.

Patroni will then operate the DR cluster as a Standby Cluster following HQ.

Patroni 4.1.4 supports Standby Cluster configuration through dynamic configuration in the DCS.

---

# 38. DR Replication Slot After Failback

If a replication slot is used for the DR Standby Cluster, the corresponding physical slot must exist on the new HQ Primary.

For example:

```sql
SELECT pg_create_physical_replication_slot('dr_standby_slot');
```

Alternatively, configure and manage it through Patroni's permanent replication slot functionality.

Do not assume that adding:

```yaml
primary_slot_name: dr_standby_slot
```

automatically creates the slot on HQ.

Patroni 4.1.4 explicitly states that the corresponding slot must be created on the primary cluster.

---

# 39. Verify the New Topology

The target topology is:

```text
                    HQ SITE

              ┌───────────────┐
              │  HQ PRIMARY   │
              └───────┬───────┘
                      │
                      │ Synchronous
                      ▼
                 HQ Replicas


                      │
                      │ Async
                      ▼


                    DR SITE

              ┌───────────────┐
              │ DR STANDBY    │
              └───────┬───────┘
                      │
                      │ Synchronous
                      ▼
                 DR Replicas
```

Verify:

```text
HQ = Primary
DR = Standby
```

---

# 40. Resume Application Traffic

Only after verifying:

```text
HQ = Primary
DR = Standby
```

switch application traffic to:

```text
HQ VIP / HAProxy
```

Then resume application writes.

Final traffic path:

```text
Application
     │
     ▼
HQ VIP
     │
     ▼
HQ Primary
```

---

# 41. Final Verification

## HQ

Verify:

```text
HQ = Primary
```

Use:

```bash
patronictl -c /etc/patroni/patroni.yml list
```

And:

```bash
curl -i http://<HQ_PRIMARY_IP>:8008/primary
```

Expected:

```text
HTTP/1.1 200 OK
```

---

## DR

Verify:

```text
DR = Standby Cluster
```

Use:

```bash
patronictl -c /etc/patroni/patroni.yml list
```

And on the DR Standby Leader:

```bash
curl -i http://<DR_STANDBY_LEADER_IP>:8008/standby-leader
```

Expected:

```text
HTTP/1.1 200 OK
```

---

# 42. Verify Application Routing

Final traffic must be:

```text
Application
     │
     ▼
HQ VIP / HAProxy
     │
     ▼
HQ Primary
```

The DR VIP must not be the active application write endpoint.

---

# 43. Verify Replication Direction

Final replication direction:

```text
HQ
 │
 │ Asynchronous
 ▼
DR
```

Inside HQ:

```text
HQ Primary
    │
    ├── Synchronous → HQ Replica
    ├── Synchronous → HQ Replica
    └── Synchronous → HQ Replica
```

Inside DR:

```text
DR Standby Leader
    │
    ├── Synchronous → DR Replica
    ├── Synchronous → DR Replica
    └── Synchronous → DR Replica
```

The WAN link must remain asynchronous.

---

# 44. Split-Brain Prevention Checklist

## During HQ Disaster

* [ ] Verify HQ failure manually.
* [ ] Confirm HQ is isolated/fenced.
* [ ] Confirm HQ cannot accept application writes.
* [ ] Confirm DR cluster is healthy.
* [ ] Verify DR replication status and understand potential RPO.
* [ ] Remove `standby_cluster` from DR dynamic configuration.
* [ ] Verify DR becomes Primary.
* [ ] Verify `/primary`.
* [ ] Switch application traffic to DR.
* [ ] Enable application writes only after DR Primary is confirmed.

---

## When HQ Returns

* [ ] Stop Patroni on all five HQ nodes.
* [ ] Verify PostgreSQL is not running independently.
* [ ] Verify HQ etcd has quorum.
* [ ] Remove old HQ Patroni/DCS state.
* [ ] Do not allow HQ to become Primary.
* [ ] Configure HQ as a Standby Cluster following DR.
* [ ] Verify the DR endpoint/VIP.
* [ ] Verify replication credentials.
* [ ] Verify the replica creation method.
* [ ] Verify `use_pg_rewind`.
* [ ] Verify `wal_log_hints` or data checksums.
* [ ] Verify WAL/archive availability.
* [ ] Verify replication-slot strategy.
* [ ] Start HQ Patroni one node at a time.
* [ ] Verify HQ Standby Leader.
* [ ] Verify HQ replicas.
* [ ] Verify HQ is not writable.
* [ ] Verify DR remains the only Primary.

---

## Before Failback

* [ ] HQ is healthy.
* [ ] HQ local synchronous replication is healthy.
* [ ] DR → HQ asynchronous replication is healthy.
* [ ] Replication lag is within the approved threshold.
* [ ] Required WAL has reached HQ.
* [ ] Application writes are stopped.
* [ ] HQ is confirmed synchronized.
* [ ] Remove `standby_cluster` from HQ DCS.
* [ ] Verify HQ Primary.
* [ ] Configure DR `standby_cluster` to follow HQ.
* [ ] Verify DR Standby Leader.
* [ ] Verify DR replicas.
* [ ] Verify HQ → DR asynchronous replication.
* [ ] Switch application traffic to HQ.
* [ ] Resume application writes.
* [ ] Perform final health and replication checks.

---

# 45. Critical Operational Rules

## Rule 1 — Never rely on connectivity alone

The fact that HQ is unreachable does not automatically mean that HQ is down.

Always verify the failure and perform fencing/isolation where possible.

---

## Rule 2 — Never promote DR while HQ may still write

The promotion sequence is:

```text
Verify HQ failure
       ↓
Fence / isolate HQ
       ↓
Promote DR
       ↓
Enable application writes
```

---

## Rule 3 — Never make both sites Primary

Never reach:

```text
HQ = Primary
DR = Primary
```

---

## Rule 4 — WAN replication is asynchronous

Do not treat:

```text
HQ → DR
```

as synchronous replication.

There can be data loss during a catastrophic HQ failure depending on replication lag at the moment of promotion.

---

## Rule 5 — Local synchronous replication is independent

The five PostgreSQL nodes inside each site are managed by Patroni's local synchronous replication configuration.

The remote site must not become part of the local synchronous quorum.

Patroni manages synchronous standby selection using the members of the local cluster and the configured synchronous replication settings.

---

## Rule 6 — `standby_cluster` is dynamic configuration

Do not assume that changing only:

```text
bootstrap.dcs
```

in an already initialized Patroni cluster changes the live cluster.

After bootstrap, the effective configuration is stored in the DCS and should be changed using:

```bash
patronictl edit-config
```

Patroni documents that `bootstrap.dcs` settings are applied only once during bootstrap.

---

## Rule 7 — Replication slots are not automatically created

If using:

```yaml
primary_slot_name: hq_standby_slot
```

the corresponding slot must exist on the remote Primary.

Patroni 4.1.4 does not automatically create the corresponding remote Primary slot for a Standby Cluster.

---

## Rule 8 — Test `pg_rewind`

Do not assume `pg_rewind` will always work.

Verify:

```text
data checksums
OR
wal_log_hints = on
```

and verify that the required WAL/timeline history is available.

Also test the interaction with the selected replication-slot strategy because Patroni 4.1.4 documents that using replication slots in the Standby Cluster can cause `pg_rewind` to fail.

---

## Rule 9 — Always have a rebuild path

If `pg_rewind` cannot be used:

```text
pgBackRest
     OR
pg_basebackup
```

must be available to rebuild the affected HQ/DR replica.

---

# 46. Complete Disaster Recovery Lifecycle

```text
┌──────────────────────────────────────────────┐
│              NORMAL OPERATION                │
│                                              │
│          HQ = Primary                        │
│          DR = Standby                        │
│                                              │
│          HQ local = Sync                     │
│          DR local = Sync                     │
│          HQ → DR = Async                     │
└──────────────────────┬───────────────────────┘
                       │
                       │ HQ Disaster
                       ▼
┌──────────────────────────────────────────────┐
│          MANUAL FAILURE VERIFICATION         │
│                                              │
│          Verify HQ failure                   │
│          Fence / isolate HQ                  │
│          Confirm HQ cannot write             │
└──────────────────────┬───────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────┐
│               DR PROMOTION                   │
│                                              │
│          Remove standby_cluster              │
│          from DR DCS                         │
│                                              │
│          DR = Primary                        │
│          Application → DR                    │
└──────────────────────┬───────────────────────┘
                       │
                       │ HQ Returns
                       ▼
┌──────────────────────────────────────────────┐
│              HQ SAFE RECOVERY                │
│                                              │
│          Stop HQ Patroni                    │
│          Verify HQ etcd quorum               │
│          Remove old HQ DCS state             │
│          Configure HQ as Standby             │
│          Start HQ Patroni                    │
└──────────────────────┬───────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────┐
│             TEMPORARY SAFE STATE             │
│                                              │
│          DR = Primary                        │
│          HQ = Standby                        │
│          Application → DR                    │
│                                              │
│          DR local = Sync                     │
│          DR → HQ = Async                     │
└──────────────────────┬───────────────────────┘
                       │
                       │ Planned Failback
                       ▼
┌──────────────────────────────────────────────┐
│             CONTROLLED FAILBACK              │
│                                              │
│          Stop application writes             │
│          Verify HQ synchronization           │
│          Remove standby_cluster from HQ      │
│          HQ = Primary                        │
│          Configure DR as Standby             │
│          Verify DR replication               │
└──────────────────────┬───────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────┐
│              NORMAL RESTORED                 │
│                                              │
│          HQ = Primary                        │
│          DR = Standby                        │
│          Application → HQ                    │
│                                              │
│          HQ local = Sync                     │
│          DR local = Sync                     │
│          HQ → DR = Async                     │
└──────────────────────────────────────────────┘
```

---

# 47. Final Architecture

```text
                         APPLICATION
                              │
                              ▼
                         HQ VIP / LB
                              │
                              ▼
                    ┌───────────────────┐
                    │    HQ PRIMARY     │
                    │   PostgreSQL      │
                    └─────────┬─────────┘
                              │
                    Synchronous replication
                              │
                ┌─────────────┼─────────────┐
                ▼             ▼             ▼
             HQ Node 2     HQ Node 3     HQ Node 4
                              │
                              ▼
                           HQ Node 5

                              │
                              │
                              │ ASYNCHRONOUS
                              │
                              ▼

                    ┌───────────────────┐
                    │    DR STANDBY     │
                    │   PostgreSQL      │
                    └─────────┬─────────┘
                              │
                    Synchronous replication
                              │
                ┌─────────────┼─────────────┐
                ▼             ▼             ▼
             DR Node 2     DR Node 3     DR Node 4
                              │
                              ▼
                           DR Node 5
```

The final normal operating state is:

```text
HQ = Primary
DR = Standby

Within HQ:
Synchronous

Within DR:
Synchronous

Between HQ and DR:
Asynchronous
```

The environment is ready to repeat the same disaster-recovery lifecycle when required.