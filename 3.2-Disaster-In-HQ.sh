# ------------------------ What Do You Do in Detail When the HQ Comes Back Online? (Avoiding Split-Brain) ------------------------


**HQ goes down → we switch to DR → we remove `standby_cluster` → DR becomes the Primary → applications start working on DR.**

# Now, let's talk about the biggest possible problem: **Split-Brain**.

Imagine that the power comes back at HQ and all the servers start working again. The HQ servers do not know what happened while they were down. The `etcd` inside HQ still thinks that **HQ is the Primary**.

The servers may start the database and try to accept new data. If any application accidentally connects to HQ, we could end up with **two different databases receiving different data**: one in DR and one in HQ.

This can seriously damage data consistency.

So, when the HQ servers come back, follow these steps:

---

#### Step 1: Stop Patroni Immediately on HQ

# As soon as the HQ servers come back online, log in to all three HQ servers and stop Patroni **before doing anything else**:

sudo systemctl stop patroni

# This ensures that PostgreSQL is not running under Patroni and cannot start accepting application connections.

---

#### Step 2: Remove the Old Cluster State from etcd

# We do not want HQ to think that it is still the Primary.

# So, we need to remove the old cluster information and Leader Lock from the HQ `etcd`.

# Run this command on **only one server** in HQ:

patronictl -c /path/to/patroni_hq.yml remove pg_cluster_hq

# Patroni will ask you to type the cluster name to confirm.

**Important:** This does **not** delete your PostgreSQL data. Your actual database files are still there.

It only removes the old **cluster state and Leader Lock** from `etcd`.

---

#### Step 3: Convert HQ into a Standby

# Now we need to tell HQ:

# > "You are no longer the Primary. The DR is the Primary, and you should follow it."

# On all three HQ servers, edit the `patroni_hq.yml` file and add the `standby_cluster` configuration.

# This time, the `standby_cluster` should point to the current DR Leader:

# Add this under bootstrap -> dcs:
standby_cluster:
  host: 10.1.0.100 # IP or VIP of the current DR Leader
  port: 5432
  primary_slot_name: hq_standby_slot

The important part is that HQ now knows that **DR is the source of truth**.

---

#### Step 4: Start Patroni on HQ

# Now start Patroni on the HQ servers:

sudo systemctl start patroni

### What happens now?

# Patroni reads the new configuration and sees that HQ is configured as a **Standby**.

# It connects to the DR and checks the database state.

# If the HQ database has diverged from the DR, Patroni can use **`pg_rewind`** to bring HQ back to the correct state.

# `pg_rewind` removes the conflicting changes on HQ and brings HQ back in line with the current Primary in DR.

# After this process:

**DR = Primary**
**HQ = Replica / Standby**

# The system is now safe and stable again.

---

#### Step 5: Failback to the Original Setup

# You probably do not want DR to remain the Primary forever.

# During a planned **maintenance window**, you can move the Primary role back to HQ.

# The general process is:

1. **Stop the applications temporarily.**
2. On the **DR**, use `patronictl edit-config` and configure `standby_cluster` to point to HQ. DR will step down and become the Standby.
3. On the **HQ**, use `patronictl edit-config` and remove the `standby_cluster` configuration. HQ can then become the Primary.
4. **Point the applications back to HQ.**

The final state will be:

**HQ = Primary**
**DR = Standby**

This is the original setup, and the system is ready for normal operation again.
