# Phase 2 — PostgreSQL Installation & Node Preparation

**Project:** PostgreSQL High Availability (Patroni) — HQ + DR
**Phase:** 2 of 7
**Scope of this document:** Operating system preparation, storage layout, PostgreSQL installation, and node hardening prerequisites for every cluster node at both sites.
**Applies to:** All PostgreSQL cluster nodes at HQ (`hq-node-01` … `hq-node-05`) and DR (`dr-node-01` … `dr-node-05`).

---

## 0. How to Read This Document

Every item in this phase is marked with one of three labels:

| Label | Meaning |
| --- | --- |
| **[PoC]** | Applies to the Azure proof-of-concept environment as built. |
| **[PROD]** | Production recommendation. Carried into the target architecture. |
| **[CONFIRM]** | Requires a client decision or client-supplied data before the production build. Tracked in §12. |
| **[DECISION]** | An open architectural decision. Must not be resolved silently — see §12. |

Where **[PoC]** and **[PROD]** differ, both are stated. The PoC is deliberately built to the production storage layout so that performance results are representative rather than indicative.

---

## 1. Architecture Context

This phase assumes the topology established in Phase 1 and does not change it.

- Each site runs a **5-node PostgreSQL cluster** managed by Patroni.
- Each site runs its **own independent etcd cluster** (5 members). HQ and DR do **not** share a distributed configuration store, and quorum is never stretched across the WAN.
- **etcd, Patroni, and PostgreSQL are co-located on the same VM.** No dedicated etcd nodes are introduced in the base design.
- DR operates as a **Patroni standby cluster**: automatic failover is local to HQ; DR activation is a controlled, approved operation.

The co-location decision has one direct consequence for this phase: etcd's write path and PostgreSQL's WAL write path compete for the same I/O subsystem unless they are separated at the storage layer. §3 addresses this.

---

## 2. Locale and Collation Consistency

> This is the highest-severity correctness item in Phase 2. It is placed first deliberately.

### 2.1 The Risk

PostgreSQL streaming replication is **physical**. The standby receives byte-level copies of the primary's data files, including B-tree index pages. The *ordering* encoded in those index pages was produced by the collation library on the primary at the time each entry was written.

If a standby node's collation library produces a different sort order than the primary's, the index pages it has received are internally inconsistent with its own comparison behaviour. The database will not report an error. Instead:

- Index scans may fail to return rows that exist.
- `UNIQUE` constraints may fail to detect duplicates.
- Range queries may silently return incomplete results.
- `ORDER BY` results may differ between nodes.

The failure is **silent, and it surfaces after promotion** — which means it surfaces during a failover or a DR activation, at the worst possible moment.

### 2.2 Why This Architecture Is Especially Exposed

The risk is not theoretical here, for three compounding reasons:

1. **Ten nodes across two sites.** HQ and DR are separate physical environments with separate patching windows. Divergence between them is the default outcome unless actively controlled.
2. **`glibc` collation changes across OS updates.** Ubuntu 24.04 security and maintenance updates can change `libc6`'s collation data. A DR site patched three weeks after HQ is, at that moment, running a different collation than the primary whose index pages it is replaying.
3. **DR is a standby cluster built via `pg_basebackup`** — a physical copy. It inherits the primary's index files wholesale. It cannot "rebuild" its way out of a collation mismatch without a full reindex.

### 2.3 Selected Approach — ICU Locale Provider

**[PROD] [PoC]** The cluster will be initialised with the **ICU locale provider** with an explicitly specified locale, rather than relying on the operating system's `glibc` locale.

Rationale:

| | `glibc` provider | ICU provider |
| --- | --- | --- |
| Collation source | OS `libc6` package | `libicu` library, versioned independently |
| Behaviour on OS patch | Can change with `libc6` updates | Unaffected by `libc6` |
| Version visibility | Coarse | Explicit ICU version recorded per collation |
| Drift detection | Limited | PostgreSQL records `collversion` and warns on mismatch |
| Cross-node reproducibility | Depends on OS patch parity | Depends on one pinned package |

The decisive advantage is **detectability**. PostgreSQL stores the collation version in `pg_database.datcollversion` and `pg_collation.collversion`, and raises a warning when the library's actual version no longer matches what was recorded. This converts a silent corruption risk into a visible, monitorable condition.

ICU is not automatically immune to change — a major `libicu` upgrade can also alter collation. The difference is that with ICU the version is explicit, pinnable, and checkable, which is what makes a control possible.

### 2.4 Implementation

**The `initdb` flags are applied by Patroni, not manually.** Patroni performs the `initdb` when it bootstraps the cluster in Phase 3. Phase 2's responsibility is to ensure the *environment* is correct and identical on every node; Phase 3's `patroni.yml` carries the flags.

Environment preparation in this phase:

```bash
# Install ICU support and record the version in the build log
sudo apt install -y libicu-dev
dpkg-query -W -f='${Package} ${Version}\n' 'libicu*' | tee /var/log/pg-build-icu-version.txt
```

The values to be carried into `patroni.yml` (Phase 3):

```yaml
bootstrap:
  initdb:
    - encoding: UTF8
    - data-checksums
    - locale-provider: icu
    - icu-locale: <ICU_LOCALE>        # see [DECISION] below
    - lc-messages: C
    - lc-monetary: C
    - lc-numeric: C
    - lc-time: C
```

`data-checksums` is included here because it can only be set at `initdb` time and enabling it later requires downtime. It provides early detection of storage-level corruption, which supports the SOW's backup-integrity and DR requirements.

> **[CONFIRM]** The exact `initdb` flag syntax for the ICU provider will be validated against the selected PostgreSQL major version during the PoC before it is committed to the proposal. Flag names in this area have changed across recent major versions.

> **[DECISION] — ICU locale value.** The locale determines linguistic sort order for text columns. For a deployment in the Kingdom of Saudi Arabia, the correct value depends on whether application data includes Arabic text requiring linguistically correct ordering:
> - `ar-SA` — correct Arabic collation. Required if Arabic text is sorted or indexed for user-facing display.
> - `en-US` — appropriate if application text is predominantly Latin script.
> - `und-x-icu` (root) — locale-neutral, predictable, minimal linguistic assumptions.
>
> This cannot be changed after `initdb` without a full dump/restore or a reindex of every affected index. **It must be confirmed with the client before the production build.**

### 2.5 Version Pinning of the Collation Library

**[PROD]** `libicu` is pinned on every node and upgraded only as a planned, cluster-wide, simultaneous maintenance activity:

```bash
sudo apt-mark hold libicu74
sudo apt-mark showhold | grep -E 'icu|postgresql'
```

> Confirm the exact `libicu` package name on the target release before applying the hold; it is version-suffixed.

### 2.6 Validation Control

**[PROD]** The following control runs (a) after every node build, (b) before every DR activation, and (c) monthly as a scheduled check. It is a formal gate, not an ad-hoc query.

**Control A — collation version recorded vs. actual, per node:**

```sql
SELECT datname,
       datcollate,
       datctype,
       datlocprovider,
       daticulocale,
       datcollversion
FROM pg_database
WHERE datname NOT IN ('template0');
```

**Control B — drift detection within a node:**

```sql
SELECT collname,
       collversion            AS recorded_version,
       pg_collation_actual_version(oid) AS actual_version
FROM pg_collation
WHERE collversion IS DISTINCT FROM pg_collation_actual_version(oid);
```

Any row returned by Control B is a **P1 finding**. It means the collation library changed under a running cluster and affected indexes must be rebuilt.

**Control C — cross-node and cross-site parity:**

```bash
# Run on every HQ and DR node; all outputs must be byte-identical
dpkg-query -W -f='${Version}' libicu74; echo
psql -Atc "SELECT datlocprovider||'|'||coalesce(daticulocale,'')||'|'||coalesce(datcollversion,'') \
           FROM pg_database WHERE datname='postgres'"
```

**[PROD]** Control C is added to the monitoring stack in Phase 6 as an alerting check, so that HQ/DR collation divergence raises an alert rather than waiting for the next manual review.

### 2.7 Patching Control

**[PROD]** A change-control rule is added to the operational runbook:

> `libc6` and `libicu*` are upgraded across **all ten nodes at both sites within the same maintenance window**. Partial-site upgrades of these two packages are prohibited. Any upgrade of either package is followed by Control B on every node before the window is closed.

This maps directly to the SOW requirement for *change control and approval process for privileged actions*.

---

## 3. Storage Layout

### 3.1 Design Principle

Three write paths on each VM have different characteristics and must not contend:

| Write path | Pattern | Sensitivity |
| --- | --- | --- |
| PostgreSQL WAL (`pg_wal`) | Sequential, `fsync` on commit | Commit latency — directly visible to applications |
| PostgreSQL data (`$PGDATA`) | Random, buffered, checkpoint bursts | Throughput and checkpoint smoothing |
| etcd (`/var/lib/etcd`) | Small, frequent, `fsync` per Raft commit | **Leader election stability** — a slow fsync here can cause a false failover |

The third row is why co-location requires separation. If etcd's `fsync` queues behind a PostgreSQL checkpoint flush, etcd's heartbeat can be delayed past its election timeout, Patroni loses its leader lock, and the cluster demotes a perfectly healthy primary. This is a real and well-documented failure mode in co-located deployments.

### 3.2 Recommended Per-VM Layout

**[PROD] [PoC]** — the PoC is built to this same layout.

| Mount point | Purpose | Filesystem | Mount options | PoC size | Production sizing |
| --- | --- | --- | --- | --- | --- |
| `/` | OS, binaries, Patroni | ext4 | defaults | 64 GB | 100 GB |
| `/pgdata` | `$PGDATA` (`/pgdata/18/main`) | XFS | `noatime,nodiratime` | 128 GB | **[CONFIRM]** — see §9.2 |
| `/pgwal` | `pg_wal` (`/pgwal/18/main`) | XFS | `noatime,nodiratime` | 64 GB | **[CONFIRM]** |
| `/var/lib/etcd` | etcd data directory | XFS | `noatime` | 16 GB | 32 GB |
| `/var/log/postgresql` | PostgreSQL logs | ext4 | `noatime` | 32 GB | 64 GB |
| `/pgbackrest` | Local backup staging (Phase 5) | XFS | `noatime` | 256 GB | **[CONFIRM]** |

Each mount is a **separate block device**, not a directory on a shared volume. Separation at the directory level provides no I/O isolation and does not address the contention described in §3.1.

### 3.3 Filesystem and Mount Guidance

**[PROD]**

- **XFS** for all database and etcd volumes. Better behaviour under parallel write workloads and large-file allocation than ext4. ext4 is acceptable if a client standard mandates it.
- **`noatime`** on all data volumes — eliminates a metadata write on every read.
- **Do not** use `nobarrier`, `data=writeback`, or any mount option that defers write barriers. These trade durability for throughput and invalidate PostgreSQL's crash-safety guarantees.
- **No LVM snapshots** as a backup mechanism for `$PGDATA`. pgBackRest (Phase 5) is the backup mechanism.
- Filesystem block size 4 KB (default). Do not tune below PostgreSQL's 8 KB page size.

### 3.4 Azure PoC Storage Configuration

**[PoC]** The following corrections apply to the current Terraform and must be made before performance results are recorded:

| Setting | Current PoC value | Required value | Reason |
| --- | --- | --- | --- |
| Data disk | *(none — OS disk only)* | Premium SSD (P-series) or Premium SSD v2 | Standard HDD invalidates any latency measurement |
| `storage_account_type` | `Standard_LRS` | `Premium_LRS` | As above |
| Host caching — `$PGDATA` | `ReadWrite` | `ReadOnly` | `ReadWrite` caching is not safe for database volumes |
| Host caching — `pg_wal` | `ReadWrite` | `None` | Write-through required for commit durability |
| Host caching — etcd | `ReadWrite` | `None` | Raft `fsync` must not be cached |
| Private IP allocation | Dynamic | Static | Node IPs are referenced in etcd, Patroni, and HAProxy configuration |

> **Note:** `ReadWrite` host caching on a volume carrying `pg_wal` or the etcd data directory can result in acknowledged writes that are not durable across a host-level failure. This must be corrected in the PoC and must never appear in the production build.

### 3.5 On-Premises Storage Requirements

**[CONFIRM]** For the production on-premises deployment the following must be supplied by the client:

- Storage platform and presentation method (SAN LUN, local NVMe, vSAN).
- Sustained IOPS and latency capability per volume class.
- Whether HQ and DR storage tiers are equivalent. **If DR storage is slower than HQ, the DR site cannot meet HQ's performance profile after activation, and the RTO commitment must be adjusted accordingly.** This is a proposal-level assumption that must be stated explicitly.

### 3.6 etcd Latency Target

**[PROD]** The etcd volume must sustain `wal_fsync_duration_seconds` p99 below **10 ms**. This threshold is monitored in Phase 6 and is a PoC acceptance criterion (§11). Exceeding it is the leading cause of spurious Patroni failovers.

---

## 4. Time Synchronisation

**[PROD] [PoC]** Every node synchronises to the approved time source using `chrony`. **No dedicated NTP server is introduced** — nodes use the environment's existing approved sources.

```bash
sudo apt install -y chrony
sudo systemctl enable --now chrony
```

**[PoC]** Azure VMs use the host-provided precision time source, which chrony detects automatically on Ubuntu 24.04. No additional configuration is required for the PoC.

**[CONFIRM]** For production, the client must supply the approved internal NTP source addresses. These are configured in `/etc/chrony/chrony.conf` and both sites must use the same source hierarchy.

Verification:

```bash
chronyc tracking     # 'Leap status' must be 'Normal'; 'System time' offset < 50 ms
chronyc sources -v   # at least one source marked '^*'
timedatectl          # 'System clock synchronized: yes'; timezone identical on all nodes
```

**Why this matters in this architecture:**

- **PITR accuracy (Phase 5):** recovery to a wall-clock target is only as accurate as the clock that wrote the WAL records.
- **Log correlation:** diagnosing a failover across ten nodes and two sites requires a common timeline.
- **Backup scheduling and retention windows** depend on consistent time across the pgBackRest repository and the database nodes.

**[PROD]** Clock offset is monitored in Phase 6 with an alert threshold of 100 ms and a critical threshold of 1 second.

---

## 5. Operating System Tuning

**[PROD] [PoC]** Applied identically on all ten nodes.

### 5.1 Transparent Huge Pages — Disable

THP causes unpredictable latency spikes when the kernel compacts memory under pressure, and interacts poorly with PostgreSQL's shared buffer access pattern. Latency spikes on a primary can delay Patroni's leader-key refresh and trigger an unnecessary failover.

```bash
cat <<'EOF' | sudo tee /etc/systemd/system/disable-thp.service
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now disable-thp
```

Verify: `cat /sys/kernel/mm/transparent_hugepage/enabled` → `always madvise [never]`

### 5.2 Explicit HugePages — Enable

Static 2 MB HugePages reduce page-table overhead for large shared buffers and cannot be swapped, which keeps the shared buffer pool resident. Sizing is derived from `shared_buffers` and is therefore finalised in Phase 3.

Reserve HugePages for `shared_buffers` plus approximately 10% overhead:

```bash
# Example for shared_buffers = 8GB → (8192 / 2) * 1.1 ≈ 4506 pages
echo 'vm.nr_hugepages = 4506' | sudo tee /etc/sysctl.d/60-postgresql-hugepages.conf
```

PostgreSQL is configured with `huge_pages = try` in Phase 3. `try` rather than `on` so that a HugePages misconfiguration degrades performance instead of preventing startup — which matters on a node being recovered under time pressure.

### 5.3 Memory Overcommit

```bash
cat <<'EOF' | sudo tee /etc/sysctl.d/60-postgresql-memory.conf
vm.overcommit_memory = 2
vm.overcommit_ratio = 90
vm.swappiness = 1
EOF
```

`vm.overcommit_memory = 2` prevents the kernel from over-promising memory it does not have. Without it, the OOM killer can terminate the postmaster process — which takes down the entire instance, not just one backend. On a primary this causes an unplanned failover.

### 5.4 Dirty Page Writeback

```bash
cat <<'EOF' | sudo tee /etc/sysctl.d/60-postgresql-dirty.conf
vm.dirty_background_bytes = 67108864
vm.dirty_bytes = 536870912
EOF
```

The kernel defaults are expressed as a percentage of RAM, which on a large-memory database server permits gigabytes of dirty pages to accumulate and then flush in a single burst. That burst stalls commits and, in a co-located design, stalls etcd's `fsync` — the exact condition described in §3.1. Byte-based limits produce smaller, more frequent, more predictable writeback.

### 5.5 Network and Connection Limits

```bash
cat <<'EOF' | sudo tee /etc/sysctl.d/60-postgresql-net.conf
net.core.somaxconn = 4096
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
EOF

sudo sysctl --system
```

Aggressive TCP keepalives allow the cluster to detect a dead peer in roughly two minutes rather than the default two hours. This directly affects failover detection time — a value the SOW requires to be quantified in the DR response table.

### 5.6 File Descriptor Limits

```bash
cat <<'EOF' | sudo tee /etc/security/limits.d/60-postgresql.conf
postgres soft nofile 65536
postgres hard nofile 65536
postgres soft nproc  16384
postgres hard nproc  16384
EOF
```

`limits.conf` is not applied to systemd-managed services. `LimitNOFILE=65536` must also be set in the Patroni unit file — this is a Phase 3 deliverable and is listed as a cross-phase dependency in §10.

---

## 6. PostgreSQL Installation

### 6.1 Version

**[PoC]** PostgreSQL 18.

> **[CONFIRM] — PostgreSQL major version.** The Scope of Work does not specify a PostgreSQL version. PostgreSQL 18 is used for the PoC as the current major release. **The final production major version must be confirmed with the client and validated against:**
> - all application connection drivers in use;
> - any third-party or contributed extensions currently in production;
> - any ISV or vendor certification requirements for the applications concerned;
> - the client's existing PostgreSQL estate, if a migration path is in scope.
>
> If the client's current estate is on an older major version, migration becomes part of the delivery scope and affects the man-day estimate. This is recorded as a proposal assumption.

### 6.2 Prevent Creation of the Default Cluster

Debian and Ubuntu packaging creates and starts a default cluster named `main` during installation. Patroni must own cluster creation. Rather than creating that cluster and then dropping it, it is prevented from being created — this is both cleaner and idempotent.

```bash
sudo mkdir -p /etc/postgresql-common
sudo touch /etc/postgresql-common/createcluster.conf

if grep -q '^create_main_cluster' /etc/postgresql-common/createcluster.conf; then
  sudo sed -i 's/^create_main_cluster.*/create_main_cluster = false/' \
    /etc/postgresql-common/createcluster.conf
else
  echo 'create_main_cluster = false' | sudo tee -a /etc/postgresql-common/createcluster.conf
fi
```

This file **must exist before** `apt install postgresql-18`.

### 6.3 Repository and Installation

```bash
sudo apt update
sudo apt install -y curl ca-certificates gnupg lsb-release

curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/postgresql.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list

sudo apt update
sudo apt install -y postgresql-18 postgresql-client-18 postgresql-contrib-18
```

### 6.4 Disable systemd Management of PostgreSQL

**PostgreSQL must be started, stopped, promoted, and restarted exclusively by Patroni.**

```bash
sudo systemctl disable --now postgresql
sudo systemctl disable --now postgresql@18-main 2>/dev/null || true
```

Verification:

```bash
systemctl is-enabled postgresql        # expected: disabled
systemctl is-active  postgresql        # expected: inactive
```

> **Operational rule — to be reproduced in the runbooks and in operator training:**
>
> On a Patroni-managed cluster, the following commands **must never be used**:
> - `systemctl start|stop|restart postgresql`
> - `pg_ctlcluster`
> - `pg_ctl` invoked directly
>
> Patroni continuously reconciles the actual state of PostgreSQL against the desired state held in etcd. A manual start or stop is either reverted, or — worse — creates a split-brain condition in which two nodes believe they are primary. All lifecycle operations go through `patronictl` or the Patroni REST API.
>
> Note also that a Patroni-managed cluster is **not visible** to `pg_lsclusters`. Operators familiar with standard Debian PostgreSQL packaging will reach for these tools by habit; this must be covered explicitly in the knowledge-transfer sessions.

### 6.5 Directory Preparation

```bash
sudo mkdir -p /pgdata/18/main /pgwal/18/main /var/log/postgresql
sudo chown -R postgres:postgres /pgdata /pgwal /var/log/postgresql
sudo chmod 700 /pgdata/18/main /pgwal/18/main
sudo chmod 750 /var/log/postgresql
```

The `$PGDATA` directory must be **empty** — Patroni performs `initdb` (on the bootstrap node) or `pg_basebackup` (on replicas) in Phase 3.

### 6.6 Version Pinning

```bash
sudo apt-mark hold postgresql-18 postgresql-client-18 postgresql-contrib-18 postgresql-common
sudo apt-mark showhold
```

Additionally, exclude PostgreSQL from unattended upgrades:

```bash
cat <<'EOF' | sudo tee /etc/apt/apt.conf.d/51-postgresql-blacklist
Unattended-Upgrade::Package-Blacklist {
    "postgresql-.*";
    "libicu.*";
    "etcd.*";
};
EOF
```

**Why:** all members of a Patroni cluster must run the same PostgreSQL minor version. An unattended upgrade that changes the minor version on one node — or restarts PostgreSQL outside Patroni's control — produces either a replication failure or an unplanned failover.

**[PROD] Controlled rolling minor-version upgrade procedure** (detailed in the Maintenance runbook, referenced here to satisfy the SOW's *"controlled patching, rolling restart planning, and minor version maintenance"* requirement):

1. Verify cluster health and zero replication lag (`patronictl list`).
2. Release the hold and upgrade **replicas only**, one at a time, allowing each to rejoin and catch up fully before proceeding.
3. Perform a controlled `patronictl switchover` to an upgraded replica.
4. Upgrade the former primary.
5. Optionally switch back to restore the intended primary placement.
6. Re-apply holds on all nodes.
7. Run the collation control (§2.6, Control B) before closing the maintenance window.
8. Repeat the sequence at DR.

---

## 7. Phase Dependencies — Package Installation

All packages required by later phases are installed here, so that later phases are configuration activities rather than installation activities.

```bash
sudo apt install -y \
  python3-psycopg2 \
  python3-pip \
  python3-venv \
  postgresql-18-pgaudit \
  pgbackrest \
  chrony \
  libicu-dev \
  jq \
  net-tools
```

| Package | Consumed by | Purpose |
| --- | --- | --- |
| `python3-psycopg2` | Phase 3 | Patroni's PostgreSQL driver |
| `postgresql-18-pgaudit` | Phase 7 | Audit logging (installed now, enabled via `shared_preload_libraries` in Phase 3) |
| `pgbackrest` | Phase 5 | Backup, restore, WAL archiving, PITR |
| `chrony` | Phase 2 | Time synchronisation |
| `libicu-dev` | Phase 2/3 | ICU collation provider |
| `jq` | Phases 3–6 | Parsing Patroni REST API responses in scripts and health checks |

> **Note for Phase 3:** `pgaudit` must be present in `shared_preload_libraries` at cluster bootstrap. Adding it later requires a restart of every node. Phase 3 must include it in the initial Patroni configuration even though Phase 7 performs the functional configuration.

> **[CONFIRM] — Patroni etcd v3 client.** Patroni connects to etcd v3 through the `etcd3` configuration block, which requires the `etcd3gw` Python library. This is not available as a Debian package and is installed via `pip` in Phase 3. **The Patroni-to-etcd v3.7.1 connection must be explicitly validated in the PoC and the evidence retained**, as etcd v3.7 removed the legacy v2 store entirely and Patroni's packaging has historically pulled in the v2 client library.

---

## 8. Firewall and Network Access Control

**[PoC]** Enforced at the Azure Network Security Group layer.
**[PROD]** Enforced at both the network layer (client firewall) and the host layer (`ufw`/`nftables`), on the principle that a host-level control survives a network misconfiguration.

### 8.1 Required Access Matrix

| Port | Protocol | Service | Permitted source | Destination |
| --- | --- | --- | --- | --- |
| 5432 | TCP | PostgreSQL | HAProxy nodes (same site) | All PG nodes, same site |
| 5432 | TCP | PostgreSQL — replication | PG cluster peers, same site | All PG nodes, same site |
| 5432 | TCP | PostgreSQL — cross-site replication | DR PG nodes | HQ PG nodes |
| 5432 | TCP | PostgreSQL — applications | Approved application subnets **[CONFIRM]** | HAProxy VIP **only** |
| 8008 | TCP | Patroni REST API | HAProxy, PG peers, monitoring | All PG nodes |
| 2379 | TCP | etcd client | PG nodes, same site only | etcd members, same site |
| 2380 | TCP | etcd peer | etcd members, same site only | etcd members, same site |
| 9100 | TCP | node_exporter | Monitoring node, same site | All nodes |
| 9187 | TCP | postgres_exporter | Monitoring node, same site | All PG nodes |
| 22 | TCP | SSH | Bastion / jump host **[CONFIRM]** | All nodes |

### 8.2 Explicit Denials

- **Applications must not connect to PostgreSQL nodes directly.** Application access terminates at the HAProxy VIP. Direct node access defeats the connection-redirection layer and produces stale connections after a failover.
- **etcd ports (2379/2380) must not cross the WAN.** HQ and DR run independent etcd clusters. Any cross-site etcd traffic indicates a misconfiguration and should be blocked at the network layer as a safeguard, not merely left unused.
- **5432 must not be open to the general corporate network.**

### 8.3 Cross-Site Traffic

The only required cross-site flow in normal operation is **PostgreSQL streaming replication from the HQ primary to the DR standby leader on TCP/5432**. Phase 5 adds the pgBackRest repository flow; that is specified in Phase 5.

**[CONFIRM]** The client must confirm the HQ↔DR link bandwidth, measured round-trip latency, and whether the link is dedicated or shared. These values determine the replication mode (synchronous vs. asynchronous) and are direct inputs to the RPO commitment in the proposal.

> **[PoC] Note:** The PoC uses Azure VNet peering between East US and West US, which exhibits a round-trip latency in the region of 60–70 ms. This is a **deliberate** choice — it validates the design under realistic WAN conditions and confirms that asynchronous cross-site replication is the correct pattern. It is not representative of the client's actual HQ↔DR latency, which must be measured.

---

## 9. Prerequisites and Infrastructure Sizing

### 9.1 Compute

**[PoC]** `Standard_B2as_v2` (2 vCPU, 8 GB RAM). This is a **burstable** instance class and is suitable only for functional validation. It must not be cited as a sizing recommendation.

**[PROD] [CONFIRM]** Production sizing requires client-supplied workload data. The Scope of Work does not contain it. The following are required inputs:

| Input required from client | Determines |
| --- | --- |
| Current and projected database size | Storage volume sizing, backup repository sizing |
| Annual data growth rate | Storage headroom, retention planning |
| Peak concurrent connections | `max_connections`, PgBouncer requirement, RAM |
| Peak transactions per second | CPU count, WAL volume, I/O profile |
| Read/write ratio | Replica count and read-routing design |
| Largest single table / index | Maintenance window duration, `maintenance_work_mem` |
| Required query response times | CPU class, storage class |

Pending that data, the proposal will present sizing as a set of tiers with stated assumptions rather than a single figure. Committing to a specific configuration without workload data would be unsound and is flagged as an assumption in the commercial response.

Baseline production guidance once inputs are available:

- **CPU:** minimum 8 vCPU per node; non-burstable instance class.
- **RAM:** minimum 32 GB. `shared_buffers` at approximately 25% of RAM; `effective_cache_size` at approximately 75%.
- **Uniformity:** every node in the cluster — at both sites — must be identically specified. A DR node with lower specification cannot sustain production load after activation, and the RTO/RPO commitment would be invalid.

### 9.2 Storage

Final volume sizes derive from the client inputs in §9.1. The **layout** in §3.2 is fixed; only the sizes are open.

### 9.3 Operating System

| Item | Value |
| --- | --- |
| Distribution | Ubuntu Server 24.04 LTS |
| Kernel | Distribution default; identical across all nodes |
| Locale | See §2 — ICU provider; OS locale not relied upon for collation |
| Timezone | Identical on all nodes **[CONFIRM]** — recommend UTC on servers, with application-layer presentation in local time |
| SELinux/AppArmor | AppArmor enabled; PostgreSQL profile validated |
| Swap | Present but minimally used (`vm.swappiness = 1`) |

### 9.4 Networking

| Item | Requirement |
| --- | --- |
| Node IP addressing | Static. Referenced in etcd, Patroni, and HAProxy configuration |
| Name resolution | DNS preferred for production; `/etc/hosts` acceptable for PoC. **[DECISION]** — see §12 |
| HQ↔DR connectivity | Routed, with 5432 permitted DR→HQ **[CONFIRM]** bandwidth and latency |
| VIP | Required at each site for the HAProxy layer (Phase 4) |

---

## 10. Cross-Phase Dependencies Created by This Phase

| Item | Owning phase | Note |
| --- | --- | --- |
| ICU locale value in `bootstrap.initdb` | Phase 3 | Must match §2.4; unchangeable after bootstrap |
| `data-checksums` in `bootstrap.initdb` | Phase 3 | Unchangeable after bootstrap without downtime |
| `pgaudit` in `shared_preload_libraries` | Phase 3 | Must be present at bootstrap; Phase 7 configures it |
| `LimitNOFILE=65536` in Patroni unit | Phase 3 | `limits.conf` does not apply to systemd services |
| `huge_pages = try` and `shared_buffers` | Phase 3 | HugePages reservation (§5.2) sized from `shared_buffers` |
| `etcd3gw` installation and connectivity proof | Phase 3 | See §7 |
| `failsafe_mode: true` | Phase 3 | Mitigates DCS-outage-induced demotion |
| pgBackRest repository configuration | Phase 5 | Binary installed here; `/pgbackrest` mount provisioned here |
| Collation parity alerting (§2.6 Control C) | Phase 6 | Cross-site drift must raise an alert |
| etcd `fsync` p99 alerting (§3.6) | Phase 6 | Threshold 10 ms |
| Clock offset alerting (§4) | Phase 6 | Warning 100 ms, critical 1 s |
| TLS certificates | Phase 7 | No TLS is configured in this phase |

---

## 11. Idempotent Preparation Script

Safe to re-run on an already-prepared node.

```bash
#!/usr/bin/env bash
set -euo pipefail

PG_VERSION=18
PGDATA_MOUNT=/pgdata
PGWAL_MOUNT=/pgwal

log() { echo "[$(date -Is)] $*"; }

# ---------------------------------------------------------------
# 1. Prevent creation of the default cluster (must precede install)
# ---------------------------------------------------------------
log "Configuring createcluster.conf"
sudo mkdir -p /etc/postgresql-common
sudo touch /etc/postgresql-common/createcluster.conf
if grep -q '^create_main_cluster' /etc/postgresql-common/createcluster.conf; then
  sudo sed -i 's/^create_main_cluster.*/create_main_cluster = false/' \
    /etc/postgresql-common/createcluster.conf
else
  echo 'create_main_cluster = false' | sudo tee -a /etc/postgresql-common/createcluster.conf >/dev/null
fi

# ---------------------------------------------------------------
# 2. Base packages and PGDG repository
# ---------------------------------------------------------------
log "Configuring PGDG repository"
sudo apt-get update -qq
sudo apt-get install -y curl ca-certificates gnupg lsb-release

curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
  | sudo gpg --dearmor --yes -o /usr/share/keyrings/postgresql.gpg

echo "deb [signed-by=/usr/share/keyrings/postgresql.gpg] http://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
  | sudo tee /etc/apt/sources.list.d/pgdg.list >/dev/null

sudo apt-get update -qq

# ---------------------------------------------------------------
# 3. Release holds so the script can re-run, then install
# ---------------------------------------------------------------
log "Installing PostgreSQL ${PG_VERSION} and phase dependencies"
sudo apt-mark unhold postgresql-${PG_VERSION} postgresql-client-${PG_VERSION} \
  postgresql-contrib-${PG_VERSION} postgresql-common 2>/dev/null || true

sudo apt-get install -y \
  postgresql-${PG_VERSION} \
  postgresql-client-${PG_VERSION} \
  postgresql-contrib-${PG_VERSION} \
  postgresql-${PG_VERSION}-pgaudit \
  python3-psycopg2 python3-pip python3-venv \
  pgbackrest chrony libicu-dev jq net-tools

# ---------------------------------------------------------------
# 4. Disable systemd management of PostgreSQL
# ---------------------------------------------------------------
log "Disabling systemd management of PostgreSQL"
sudo systemctl disable --now postgresql >/dev/null 2>&1 || true
sudo systemctl disable --now "postgresql@${PG_VERSION}-main" >/dev/null 2>&1 || true

# ---------------------------------------------------------------
# 5. Directories (idempotent)
# ---------------------------------------------------------------
log "Preparing directories"
sudo mkdir -p "${PGDATA_MOUNT}/${PG_VERSION}/main" \
             "${PGWAL_MOUNT}/${PG_VERSION}/main" \
             /var/log/postgresql
sudo chown -R postgres:postgres "${PGDATA_MOUNT}" "${PGWAL_MOUNT}" /var/log/postgresql
sudo chmod 700 "${PGDATA_MOUNT}/${PG_VERSION}/main" "${PGWAL_MOUNT}/${PG_VERSION}/main"
sudo chmod 750 /var/log/postgresql

# ---------------------------------------------------------------
# 6. Time synchronisation
# ---------------------------------------------------------------
log "Enabling chrony"
sudo systemctl enable --now chrony

# ---------------------------------------------------------------
# 7. Kernel tuning
# ---------------------------------------------------------------
log "Applying kernel tuning"
cat <<'EOF' | sudo tee /etc/sysctl.d/60-postgresql.conf >/dev/null
vm.overcommit_memory = 2
vm.overcommit_ratio = 90
vm.swappiness = 1
vm.dirty_background_bytes = 67108864
vm.dirty_bytes = 536870912
net.core.somaxconn = 4096
net.ipv4.tcp_keepalive_time = 60
net.ipv4.tcp_keepalive_intvl = 10
net.ipv4.tcp_keepalive_probes = 6
EOF
sudo sysctl --system >/dev/null

cat <<'EOF' | sudo tee /etc/security/limits.d/60-postgresql.conf >/dev/null
postgres soft nofile 65536
postgres hard nofile 65536
postgres soft nproc  16384
postgres hard nproc  16384
EOF

# ---------------------------------------------------------------
# 8. Disable Transparent Huge Pages
# ---------------------------------------------------------------
log "Disabling Transparent Huge Pages"
cat <<'EOF' | sudo tee /etc/systemd/system/disable-thp.service >/dev/null
[Unit]
Description=Disable Transparent Huge Pages
DefaultDependencies=no
After=sysinit.target local-fs.target

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/enabled'
ExecStart=/bin/sh -c 'echo never > /sys/kernel/mm/transparent_hugepage/defrag'
RemainAfterExit=yes

[Install]
WantedBy=basic.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now disable-thp

# ---------------------------------------------------------------
# 9. Record ICU version and re-apply package holds
# ---------------------------------------------------------------
log "Recording ICU version"
dpkg-query -W -f='${Package} ${Version}\n' 'libicu*' \
  | sudo tee /var/log/pg-build-icu-version.txt

log "Applying package holds"
sudo apt-mark hold postgresql-${PG_VERSION} postgresql-client-${PG_VERSION} \
  postgresql-contrib-${PG_VERSION} postgresql-common

cat <<'EOF' | sudo tee /etc/apt/apt.conf.d/51-postgresql-blacklist >/dev/null
Unattended-Upgrade::Package-Blacklist {
    "postgresql-.*";
    "libicu.*";
    "etcd.*";
};
EOF

log "Phase 2 preparation complete. Node is ready for Phase 3 (Patroni)."
```

> The `libicu` hold is applied separately once the exact version-suffixed package name is confirmed on the target OS release (§2.5).

---

## 12. Open Items Requiring Client Decision

Nothing in this list has been resolved silently. Each requires a client response before the production build.

| # | Item | Type | Impact if unresolved |
| --- | --- | --- | --- |
| 1 | ICU locale value (`ar-SA` / `en-US` / `und-x-icu`) | **[DECISION]** | Cannot be changed after `initdb` without full reindex or dump/restore |
| 2 | PostgreSQL major version | **[CONFIRM]** | Driver, extension, and ISV certification risk; affects migration scope and man-days |
| 3 | Node count — 5 total vs. 5 per site | **[DECISION]** | The SOW states five servers; the design assumes five per site. Directly affects BOM, man-days, and price |
| 4 | Workload sizing inputs (§9.1) | **[CONFIRM]** | CPU, RAM, and storage cannot be committed without them |
| 5 | HQ↔DR bandwidth and measured latency | **[CONFIRM]** | Determines synchronous vs. asynchronous replication, and therefore the RPO commitment |
| 6 | Whether DR storage and compute match HQ | **[CONFIRM]** | If not, post-activation performance and the RTO commitment must be qualified |
| 7 | Approved internal NTP sources | **[CONFIRM]** | PITR accuracy and log correlation |
| 8 | Approved application subnets and bastion source | **[CONFIRM]** | Firewall matrix (§8.1) cannot be finalised |
| 9 | DNS vs. `/etc/hosts` for node resolution | **[DECISION]** | DNS is preferred for production; `/etc/hosts` avoids a DNS dependency in the failover path. Recommend `/etc/hosts` for cluster-internal names with DNS for client-facing endpoints |
| 10 | On-premises storage platform and IOPS capability | **[CONFIRM]** | Storage design (§3.5) and etcd `fsync` target (§3.6) |
| 11 | Timezone standard for servers | **[CONFIRM]** | Recommend UTC; must be identical across all nodes |

---

## 13. Validation Checklist

Each item is verified on **every node at both sites** during the PoC, and the evidence is retained for the proposal's compliance response.

### 13.1 Locale and Collation

| # | Check | Command | Expected result |
| --- | --- | --- | --- |
| L1 | ICU provider in use | `psql -Atc "SELECT datlocprovider FROM pg_database WHERE datname='postgres'"` | `i` |
| L2 | ICU locale as specified | `psql -Atc "SELECT daticulocale FROM pg_database WHERE datname='postgres'"` | Matches §2.4 decision |
| L3 | No collation drift | Control B (§2.6) | Zero rows |
| L4 | `libicu` version identical, all 10 nodes | `dpkg-query -W -f='${Version}' libicu74` | Byte-identical across all nodes |
| L5 | `libicu` held | `apt-mark showhold \| grep icu` | Package listed |
| L6 | HQ/DR collation parity | Control C (§2.6) | Identical output at both sites |
| L7 | Data checksums enabled | `psql -Atc "SHOW data_checksums"` | `on` |

### 13.2 Storage

| # | Check | Command | Expected result |
| --- | --- | --- | --- |
| S1 | Separate block devices | `lsblk` | `/pgdata`, `/pgwal`, `/var/lib/etcd` on distinct devices |
| S2 | Filesystem type | `findmnt -no FSTYPE /pgdata /pgwal /var/lib/etcd` | `xfs` |
| S3 | Mount options | `findmnt -no OPTIONS /pgdata /pgwal` | Includes `noatime` |
| S4 | No unsafe options | `mount \| grep -E 'nobarrier\|writeback'` | No output |
| S5 | Azure caching (PoC) | `az vm show` / Terraform plan | `ReadOnly` for data; `None` for WAL and etcd |
| S6 | etcd fsync latency | Prometheus `etcd_disk_wal_fsync_duration_seconds` p99 | < 10 ms under load |
| S7 | Storage latency under load | `pgbench` with `pg_stat_io` observation | Recorded and included in the proposal |

### 13.3 Version Control and Maintenance

| # | Check | Command | Expected result |
| --- | --- | --- | --- |
| V1 | PostgreSQL held | `apt-mark showhold` | All `postgresql-*` packages listed |
| V2 | Unattended upgrades excluded | `cat /etc/apt/apt.conf.d/51-postgresql-blacklist` | File present with all three patterns |
| V3 | Identical minor version, all nodes | `psql -Atc "SHOW server_version"` | Identical across all 10 nodes |
| V4 | Rolling upgrade rehearsed | Execute §6.6 procedure in PoC | Completed with zero unplanned failovers; timing recorded |

### 13.4 Time Synchronisation

| # | Check | Command | Expected result |
| --- | --- | --- | --- |
| T1 | chrony running | `systemctl is-active chrony` | `active` |
| T2 | Clock synchronised | `timedatectl` | `System clock synchronized: yes` |
| T3 | Offset within tolerance | `chronyc tracking` | System time offset < 50 ms |
| T4 | Source reachable | `chronyc sources -v` | At least one source marked `^*` |
| T5 | Timezone consistent | `timedatectl \| grep "Time zone"` | Identical across all 10 nodes |

### 13.5 OS Tuning

| # | Check | Command | Expected result |
| --- | --- | --- | --- |
| O1 | THP disabled | `cat /sys/kernel/mm/transparent_hugepage/enabled` | `[never]` selected |
| O2 | THP disabled after reboot | Reboot, then repeat O1 | `[never]` selected |
| O3 | Overcommit | `sysctl vm.overcommit_memory` | `2` |
| O4 | Dirty limits | `sysctl vm.dirty_bytes vm.dirty_background_bytes` | Values from §5.4 |
| O5 | Keepalives | `sysctl net.ipv4.tcp_keepalive_time` | `60` |
| O6 | File descriptors (Phase 3) | `cat /proc/$(pgrep -f "postgres -D" \| head -1)/limits` | Max open files 65536 |
| O7 | HugePages in use (Phase 3) | `psql -Atc "SHOW huge_pages"` and `grep HugePages_Free /proc/meminfo` | Reserved pages consumed by PostgreSQL |

### 13.6 PostgreSQL Installation

| # | Check | Command | Expected result |
| --- | --- | --- | --- |
| P1 | Default cluster never created | `pg_lsclusters` | No `main` cluster |
| P2 | systemd disabled | `systemctl is-enabled postgresql` | `disabled` |
| P3 | systemd inactive | `systemctl is-active postgresql` | `inactive` |
| P4 | `$PGDATA` empty and correct ownership | `ls -la /pgdata/18/main` | Empty; `postgres:postgres`; mode 700 |
| P5 | Binaries present | `ls /usr/lib/postgresql/18/bin/` | `initdb`, `pg_ctl`, `pg_basebackup`, `postgres` |
| P6 | Script idempotency | Run §11 twice consecutively | Second run completes with exit code 0 |
| P7 | Reboot survival | Reboot; repeat P1–P5 | All results unchanged |

### 13.7 Dependencies

| # | Check | Command | Expected result |
| --- | --- | --- | --- |
| D1 | psycopg2 | `python3 -c "import psycopg2; print(psycopg2.__version__)"` | Version printed |
| D2 | pgaudit available | `ls /usr/lib/postgresql/18/lib/pgaudit.so` | File present |
| D3 | pgBackRest | `pgbackrest version` | Version printed |
| D4 | Patroni ↔ etcd v3 (Phase 3) | Patroni startup log + `patronictl list` | Connection established against etcd v3.7.1; evidence retained |

### 13.8 Firewall

| # | Check | Command | Expected result |
| --- | --- | --- | --- |
| F1 | 5432 reachable from HAProxy | `nc -zv <pg-node> 5432` from HAProxy | Succeeds |
| F2 | 5432 blocked from unauthorised source | `nc -zv <pg-node> 5432` from an untrusted host | Refused or timed out |
| F3 | 2379/2380 blocked cross-site | `nc -zv <dr-node> 2379` from HQ | Refused or timed out |
| F4 | 8008 reachable from monitoring | `curl -s http://<pg-node>:8008/health` | HTTP 200 with cluster state |
| F5 | Cross-site replication permitted | `nc -zv <hq-node> 5432` from DR | Succeeds |

---

## 14. Phase 2 Exit Criteria

Phase 2 is complete when, on all ten nodes:

1. Every check in §13 passes and the evidence is recorded.
2. All items in §12 have either a client response or an explicitly documented assumption carried into the proposal.
3. The preparation script (§11) has been executed twice on at least one node to demonstrate idempotency.
4. At least one node has been rebooted and re-validated.
5. The ICU version has been recorded on every node and confirmed identical.
6. No PostgreSQL instance is running or enabled under systemd on any node.

The nodes are then ready for **Phase 3 — Patroni installation and cluster bootstrap**.