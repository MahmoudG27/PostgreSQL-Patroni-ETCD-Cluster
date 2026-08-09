# HQ Recovery After Disaster & Split-Brain Prevention

This document describes what to do when the **HQ PostgreSQL cluster comes back online after a disaster**, while the **DR cluster has already been promoted to Primary**.

The main objective is to:

1. Prevent **Split-Brain**.
2. Make sure HQ does **not** start accepting writes.
3. Remove the old HQ Patroni cluster state.
4. Rebuild/rejoin HQ as a **Standby** following the DR Primary.
5. Optionally perform a controlled **failback** from DR back to HQ.

---

# 1. Disaster Scenario

The normal architecture is:

```text
                    NORMAL OPERATION

                 HQ SITE
          ┌───────────────────┐
          │   HQ PostgreSQL   │
          │      PRIMARY      │
          └─────────┬─────────┘
                    │
                    │ WAL
                    ▼
                 DR SITE
          ┌───────────────────┐
          │  DR PostgreSQL    │
          │     STANDBY       │
          └───────────────────┘
```

During a disaster:

```text
                    HQ FAILURE

                 HQ SITE
          ┌───────────────────┐
          │   HQ PostgreSQL   │
          │      ❌ DOWN      │
          └───────────────────┘

                    ↓

              DR Promotion

                    ↓

                 DR SITE
          ┌───────────────────┐
          │  DR PostgreSQL    │
          │      PRIMARY      │
          └─────────┬─────────┘
                    │
                    ▼
               Application
```

The DR cluster is promoted by removing the `standby_cluster` configuration from the DR Patroni DCS.

After promotion:

```text
DR = Primary
HQ = Down
```

Applications should now be connected to the DR Primary.

---

# 2. The Problem When HQ Comes Back

When the HQ servers come back online, they do **not automatically know** that DR has already been promoted.

The old HQ cluster may still contain its previous Patroni state.

For example:

```text
HQ etcd
   │
   └── Old cluster state
          │
          └── Old Leader Lock
```

If HQ is allowed to start normally, it may attempt to start PostgreSQL and potentially become writable again.

At the same time:

```text
DR = Primary
```

This creates the possibility of:

```text
             ❌ SPLIT-BRAIN

        HQ Primary
        Writable
            │
            │
            │
        DR Primary
        Writable

       Two databases
       accepting writes
```

This can result in:

* Data divergence
* Conflicting transactions
* Data loss
* Difficult reconciliation
* Replication problems
* Application inconsistencies

Therefore:

> **Never allow the recovered HQ cluster to start normally before it has been safely converted into a Standby of the DR cluster.**

---

# 3. Recovery Procedure Overview

The recovery process is:

```text
HQ comes back online
        │
        ▼
STOP Patroni immediately
        │
        ▼
Remove old HQ Patroni/DCS state
        │
        ▼
Configure HQ as DR Standby
        │
        ▼
Start Patroni on HQ
        │
        ▼
HQ follows DR Primary
        │
        ▼
HQ becomes Standby/Replica
        │
        ▼
Optional planned failback
        │
        ▼
HQ = Primary
DR = Standby
```

---

# 4. Step 1 — Stop Patroni Immediately on HQ

As soon as the HQ servers come back online, **do not start PostgreSQL manually**.

Log in to all HQ PostgreSQL nodes and stop Patroni immediately:

```bash
sudo systemctl stop patroni
```

Verify that Patroni is stopped:

```bash
sudo systemctl status patroni
```

You should see that the service is inactive.

You can also verify that PostgreSQL is not running:

```bash
pgrep -a postgres
```

If PostgreSQL is running independently, stop it before continuing.

---

## Important

Do this on **every HQ PostgreSQL node**.

For example:

```text
hq-node-01
hq-node-02
hq-node-03
hq-node-04
hq-node-05
```

Do not assume that stopping Patroni on one node is enough.

---

# 5. Step 2 — Verify That DR Is the Current Primary

Before changing HQ, verify that the DR cluster is currently the source of truth.

From a DR node:

```bash
patronictl -c /etc/patroni/patroni.yml list
```

You should see a writable Primary/Leader in DR.

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

The exact node that is the Leader may be different.

The important point is:

```text
DR = PRIMARY
```

---

# 6. Step 3 — Remove the Old HQ Patroni Cluster State

The recovered HQ cluster may still have its old Patroni state and Leader Lock in the HQ etcd/DCS.

We need to remove the old cluster state before rebuilding HQ as a Standby of DR.

Run the command from **one HQ node only**:

```bash
patronictl -c /etc/patroni/patroni.yml remove pg_cluster_hq
```

If your configuration file has a different name/path, use that path instead.

For example:

```bash
patronictl -c /etc/patroni/patroni_hq.yml remove pg_cluster_hq
```

Patroni will ask for confirmation.

Confirm the removal when you are certain that:

```text
DR = Primary
```

and HQ is no longer supposed to be the Primary.

---

# 7. What Does `patronictl remove` Do?

This command removes the Patroni cluster information from the configured DCS.

It removes information such as:

* Cluster state
* Leader information
* Leader lock
* Patroni dynamic configuration associated with the old cluster

It does **not** directly delete the PostgreSQL data directory:

```text
/var/lib/postgresql/18/main
```

However:

> **Do not interpret this as a guarantee that the existing PostgreSQL data is safe to reuse.**

The old HQ data may have diverged from the current DR Primary.

The next step is specifically designed to make HQ follow DR and reconcile the PostgreSQL state.

---

# 8. Step 4 — Configure HQ as a Standby of DR

Now HQ must be told:

> **"DR is the current source of truth. HQ must follow DR."**

On **all HQ nodes**, update:

```text
/etc/patroni/patroni.yml
```

or the corresponding HQ configuration file.

Add the `standby_cluster` configuration under the Patroni DCS bootstrap configuration.

Example:

```yaml
bootstrap:
  dcs:

    standby_cluster:
      host: 10.1.0.100
      port: 5432
      primary_slot_name: hq_standby_slot
```

Where:

```text
10.1.0.100
```

should preferably be the **DR HAProxy/VIP** that always points to the current DR Primary.

---

# 9. DR Endpoint

Do not ideally point HQ directly to:

```text
dr-node-01
```

Instead, use a stable DR endpoint:

```text
DR HAProxy / VIP
        │
        ▼
Current DR Primary
```

For example:

```yaml
standby_cluster:
  host: 10.1.0.100
  port: 5432
  primary_slot_name: hq_standby_slot
```

This prevents the HQ configuration from depending on a specific DR node.

---

# 10. Replication Slot

The configuration uses:

```yaml
primary_slot_name: hq_standby_slot
```

This slot is intended to ensure that WAL required by the HQ Standby is retained on the DR Primary.

The replication slot must exist and be correctly managed on the DR side.

Verify the slot as part of the DR replication setup before starting HQ.

---

# 11. Step 5 — Verify HQ Configuration Before Starting

Before starting Patroni on HQ, verify that every HQ node has:

* Correct hostname/node name
* Correct HQ IP
* Correct PostgreSQL listener
* Correct REST API listener
* Correct DR HAProxy/VIP
* Correct `standby_cluster`
* Correct replication credentials
* Correct PostgreSQL binary path
* Correct PostgreSQL data directory

For example:

```yaml
standby_cluster:
  host: 10.1.0.100
  port: 5432
  primary_slot_name: hq_standby_slot
```

---

# 12. Step 6 — Start Patroni on HQ

Start Patroni on the HQ nodes.

It is recommended to start them **one by one** and monitor the logs.

Start the first HQ node:

```bash
sudo systemctl start patroni
```

Check:

```bash
sudo systemctl status patroni
```

Monitor:

```bash
sudo journalctl -u patroni -f
```

---

# 13. What Should Happen?

Patroni should now see that HQ is configured as a **Standby Cluster**.

It should connect to the DR Primary and determine the correct PostgreSQL state.

The important goal is:

```text
DR = Primary
HQ = Standby
```

HQ must **not** become writable.

---

# 14. PostgreSQL Reconciliation

The old HQ PostgreSQL data may be different from the current DR data.

For example:

```text
Before disaster:

HQ:
A B C D

DR:
A B C D
```

During the disaster, DR receives new writes:

```text
HQ:
A B C D

DR:
A B C D E F G
```

When HQ comes back:

```text
HQ:
A B C D

DR:
A B C D E F G
```

The DR database is now the source of truth.

---

# 15. `pg_rewind`

If the old HQ PostgreSQL timeline has diverged from DR, `pg_rewind` may be used to bring the old HQ instance back onto the current timeline.

The Patroni configuration already enables:

```yaml
postgresql:
  use_pg_rewind: true
```

The goal is:

```text
Old HQ Timeline
       │
       │ pg_rewind / re-sync
       ▼
Current DR Timeline
```

After reconciliation:

```text
DR = Primary
HQ = Replica
```

> `pg_rewind` is not a substitute for a backup or a universal recovery mechanism. If the old HQ data cannot safely be rewound or the required WAL/history is unavailable, the safer approach is to rebuild/re-seed HQ from the current DR Primary.

---

# 16. Verify HQ Is Now a Standby

From the HQ cluster:

```bash
patronictl -c /etc/patroni/patroni.yml list
```

The expected state is conceptually:

```text
+ Cluster: pg_cluster_hq +------------------------------+
| Member      | Role    | State     |
+-------------+---------+-----------+
| hq-node-01  | Replica | streaming |
| hq-node-02  | Replica | streaming |
| hq-node-03  | Replica | streaming |
| hq-node-04  | Replica | streaming |
| hq-node-05  | Replica | streaming |
+-------------+---------+-----------+
```

The exact role/state shown depends on the final Patroni topology.

The important requirement is:

```text
HQ = NOT Primary
DR = Primary
```

---

# 17. Verify the Data Flow

The expected replication direction is now:

```text
                 DR SITE
             ┌─────────────┐
             │ DR Primary  │
             └──────┬──────┘
                    │
                    │ WAL
                    ▼
                 HQ SITE
             ┌─────────────┐
             │ HQ Standby  │
             └─────────────┘
```

DR is now the source of truth.

Do not allow application writes directly to HQ.

---

# 18. Verify the DR Primary

From DR:

```bash
patronictl list
```

Confirm:

```text
DR = Leader / Primary
```

Then verify the REST API of the current DR Primary:

```bash
curl -i http://<DR_PRIMARY_IP>:8008/primary
```

Expected:

```text
HTTP/1.1 200 OK
```

---

# 19. Verify HQ Is Not Writable

Do not rely only on Patroni status.

Verify the application routing and PostgreSQL behavior.

The application must continue using:

```text
DR HAProxy / VIP
```

and not:

```text
HQ HAProxy / VIP
```

The HQ endpoint should not be exposed as the application write endpoint while DR is Primary.

---

# 20. Current Safe State

After successfully recovering HQ:

```text
                    CURRENT STATE

                  DR SITE
          ┌───────────────────┐
          │   DR PostgreSQL   │
          │      PRIMARY      │
          └─────────┬─────────┘
                    │
                    │ WAL
                    ▼
                  HQ SITE
          ┌───────────────────┐
          │   HQ PostgreSQL   │
          │      STANDBY      │
          └───────────────────┘

                 Application
                      │
                      ▼
                 DR Primary
```

This is a safe state.

---

# 21. Do Not Immediately Fail Back

At this point, there is **no requirement to immediately return the Primary role to HQ**.

It is usually safer to keep:

```text
DR = Primary
HQ = Standby
```

until:

* HQ is fully healthy.
* Replication from DR → HQ is stable.
* All HQ nodes are synchronized.
* Network connectivity is stable.
* HAProxy/VIP is working correctly.
* Monitoring is healthy.
* The team is ready for a controlled failback.

---

# 22. Optional Step 7 — Planned Failback to HQ

If the organization wants to restore the original topology:

```text
HQ = Primary
DR = Standby
```

perform a **planned failback** during a maintenance window.

Do not treat failback as an automatic process.

---

# 23. Failback Overview

The general flow is:

```text
Current:

DR = Primary
HQ = Standby

        │
        ▼
Wait for HQ to fully synchronize
        │
        ▼
Stop application writes
        │
        ▼
Make HQ the new Primary
        │
        ▼
Configure DR as Standby
        │
        ▼
Start application writes on HQ
        │
        ▼
Final:

HQ = Primary
DR = Standby
```

---

# 24. Step 1 — Stop Application Writes

Before failback, stop or pause application writes.

For example:

```text
Application
     │
     X
     │
     ▼
DR Primary
```

The exact procedure depends on the application architecture.

The goal is to ensure that no new writes occur while the Primary role is being moved.

---

# 25. Step 2 — Confirm HQ Is Fully Synchronized

Before promoting HQ, verify that HQ has caught up with DR.

Check the Patroni cluster:

```bash
patronictl list
```

Check PostgreSQL replication state as appropriate for the configured topology.

Do not proceed until HQ is sufficiently synchronized for the planned RPO/RTO requirements.

---

# 26. Step 3 — Promote HQ

The exact promotion method should follow the Patroni topology and the approved operational procedure.

The key principle is:

```text
DR Primary
     ↓
Controlled switchover
     ↓
HQ Primary
```

Do **not** simply remove random configuration blocks while both clusters are writable.

The old Primary must be safely stepped down before the new Primary accepts writes.

---

# 27. Step 4 — Configure DR as Standby of HQ

Once HQ is the new source of truth, configure the DR cluster to follow HQ.

The DR configuration should contain:

```yaml
standby_cluster:
  host: 10.0.0.100
  port: 5432
  primary_slot_name: dr_standby_slot
```

Where:

```text
10.0.0.100
```

represents the **HQ HAProxy/VIP** pointing to the current HQ Primary.

---

# 28. Step 5 — Verify the New Topology

The desired final state is:

```text
                    NORMAL OPERATION

                 HQ SITE
          ┌───────────────────┐
          │   HQ PostgreSQL   │
          │      PRIMARY      │
          └─────────┬─────────┘
                    │
                    │ WAL
                    ▼
                 DR SITE
          ┌───────────────────┐
          │   DR PostgreSQL   │
          │      STANDBY      │
          └───────────────────┘
```

Application traffic should now point back to:

```text
HQ HAProxy / VIP
```

---

# 29. Step 6 — Resume Application Traffic

Only after verifying that:

```text
HQ = Primary
DR = Standby
```

should application traffic be switched back to HQ.

Verify:

```text
Application
     │
     ▼
HQ HAProxy / VIP
     │
     ▼
HQ Primary
```

Then resume application writes.

---

# 30. Final Verification

After failback, verify:

### HQ

```text
HQ = Primary
```

### DR

```text
DR = Standby
```

### Replication

```text
HQ
 │
 │ WAL
 ▼
DR
```

### Application

```text
Application
     │
     ▼
HQ VIP
```

---

# 31. Split-Brain Prevention Checklist

When HQ comes back after a DR disaster:

* [ ] Do **not** allow HQ Patroni to start normally.
* [ ] Stop Patroni immediately on all HQ nodes.
* [ ] Verify that DR is the current Primary.
* [ ] Verify that application traffic is going to DR.
* [ ] Remove the old HQ Patroni/DCS state.
* [ ] Configure HQ as a Standby of DR.
* [ ] Configure the DR HAProxy/VIP as the HQ replication source.
* [ ] Verify the replication slot.
* [ ] Start Patroni on HQ one node at a time.
* [ ] Monitor Patroni logs.
* [ ] Verify that HQ is following DR.
* [ ] Verify that HQ is not accepting application writes.
* [ ] Verify that DR remains the only writable Primary.
* [ ] Wait for HQ to fully synchronize.
* [ ] Perform failback only during a controlled maintenance window.

---

# 32. Critical Rule

> **Never allow both HQ and DR to be writable Primaries at the same time.**

The only acceptable states are:

```text
Normal:

HQ = Primary
DR = Standby
```

or:

```text
Disaster:

HQ = Down
DR = Primary
```

or:

```text
HQ Recovery:

HQ = Standby
DR = Primary
```

or, after a controlled failback:

```text
Normal Restored:

HQ = Primary
DR = Standby
```

Never:

```text
❌ HQ = Primary
❌ DR = Primary
```

---

# 33. Complete Disaster Recovery Lifecycle

The complete lifecycle is:

```text
┌──────────────────────────────────────────────┐
│              NORMAL OPERATION                │
│                                              │
│          HQ = Primary                        │
│          DR = Standby                        │
└──────────────────────┬───────────────────────┘
                       │
                       │ HQ Disaster
                       ▼
┌──────────────────────────────────────────────┐
│               DR PROMOTION                   │
│                                              │
│          HQ = Down                           │
│          DR = Primary                        │
│          Application → DR                    │
└──────────────────────┬───────────────────────┘
                       │
                       │ HQ Returns
                       ▼
┌──────────────────────────────────────────────┐
│             HQ SAFE RECOVERY                 │
│                                              │
│          Stop HQ Patroni                     │
│          Remove old HQ DCS state             │
│          Configure HQ → DR Standby           │
│          Start HQ Patroni                    │
└──────────────────────┬───────────────────────┘
                       │
                       ▼
┌──────────────────────────────────────────────┐
│              TEMPORARY STATE                 │
│                                              │
│          DR = Primary                        │
│          HQ = Standby                        │
│          Application → DR                    │
└──────────────────────┬───────────────────────┘
                       │
                       │ Planned Failback
                       ▼
┌──────────────────────────────────────────────┐
│              NORMAL RESTORED                 │
│                                              │
│          HQ = Primary                        │
│          DR = Standby                        │
│          Application → HQ                    │
└──────────────────────────────────────────────┘
```

---

# 34. Final Architecture

After the complete recovery and failback process:

```text
                         ┌─────────────────┐
                         │   APPLICATION   │
                         └────────┬────────┘
                                  │
                                  ▼
                         ┌─────────────────┐
                         │   HQ VIP/LB     │
                         └────────┬────────┘
                                  │
                                  ▼
                         ┌─────────────────┐
                         │   HQ PRIMARY    │
                         │   PostgreSQL    │
                         └────────┬────────┘
                                  │
                                  │ WAL
                                  ▼
                         ┌─────────────────┐
                         │   DR STANDBY    │
                         │   PostgreSQL    │
                         └─────────────────┘
```

The environment is now back to its original operating model:

```text
HQ = Primary
DR = Standby
```

while maintaining the ability to perform the same DR promotion procedure again if another major HQ disaster occurs.
