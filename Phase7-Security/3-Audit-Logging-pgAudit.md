# Audit Logging with pgAudit

Closes the Scope of Work requirement:

```text
"Administrative logging, audit trail recommendations, and retention guidance."
```

and the proposal commitment in section 4.5:

```text
"pgAudit enabled for DDL, role, and write-statement auditing, with CSV-formatted logs."
```

Nothing in the platform logs *who did what* today.

---

# 1. Why the Built-in Logging Is Not Enough

PostgreSQL has `log_statement = 'ddl' | 'mod' | 'all'`, and people often assume that is an audit trail. It is not:

```text
* It logs the statement text as submitted, not what was actually executed.
  A call to a function that drops a table logs only the function call.

* It cannot filter by object or by role. log_statement='all' on a busy database
  produces gigabytes an hour and is useless.

* It does not record which specific table a statement touched, so you cannot
  answer "who read the salaries table" — the question auditors actually ask.
```

pgAudit hooks the executor instead of the parser, so it logs what the database really did.

---

# 2. Install pgAudit

On **every** PostgreSQL node, HQ and DR:

```bash
sudo apt install -y postgresql-18-pgaudit
```

Confirm the library is present:

```bash
ls /usr/lib/postgresql/18/lib/pgaudit.so
```

> The package must be installed on every node before you change the
> configuration. A node without the library will refuse to start once
> `shared_preload_libraries` references it — that is a failed node, not a
> failed reload.

---

# 3. Load the Library — This Requires a Restart

`shared_preload_libraries` can only change at startup. Via `patronictl edit-config`:

```yaml
postgresql:
  parameters:
    shared_preload_libraries: 'pgaudit'
```

> **If you later add `pg_stat_statements`, list both**, comma-separated, and put
> `pgaudit` first so it sees statements before other hooks:
>
> ```yaml
> shared_preload_libraries: 'pgaudit,pg_stat_statements'
> ```

Patroni marks every node `pending_restart`. Roll the restart, replicas first, switchover last — the procedure is the same one used for `archive_mode` in `Phase5-PgBackRest`:

```bash
sudo /opt/patroni/bin/patronictl -c /etc/patroni/patroni.yml restart pg_cluster_hq hq-node-02
# confirm streaming, then the next replica
# then: patronictl switchover, and restart the former leader
```

Verify on each node:

```sql
SHOW shared_preload_libraries;
SELECT * FROM pg_available_extensions WHERE name = 'pgaudit';
```

---

# 4. Configure What Gets Audited

The rest of pgAudit is reloadable. Via `edit-config`:

```yaml
postgresql:
  parameters:
    # WHAT to audit.
    #   ddl    CREATE / ALTER / DROP
    #   role   GRANT / REVOKE / CREATE ROLE / ALTER ROLE
    #   write  INSERT / UPDATE / DELETE / TRUNCATE / COPY into a table
    # This is exactly the set the proposal commits to.
    pgaudit.log: 'ddl,role,write'

    # Do not audit reads of the system catalogs — pure noise.
    pgaudit.log_catalog: 'off'

    # Log the actual parameter values, not just the prepared statement text.
    # Without this an audit entry reads "DELETE FROM orders WHERE id = $1"
    # and you never learn which row was deleted.
    pgaudit.log_parameter: 'on'

    # Record the specific relation each statement touched — one log line per
    # table. This is what makes "who touched this table" answerable.
    pgaudit.log_relation: 'on'

    # Log the full statement text on every entry, not only the first of a group.
    pgaudit.log_statement_once: 'off'

    # Prefix audit entries so they are easy to grep and easy to ship.
    pgaudit.role: ''
```

Apply:

```bash
sudo -u postgres psql -c "SELECT pg_reload_conf();"
sudo -u postgres psql -c "SHOW pgaudit.log;"
```

> **`read` is deliberately not included.**
>
> Auditing SELECT on a busy OLTP database produces enormous volume. Turn it on
> only for specific sensitive tables, using object-level auditing in section 8.
> Confirm with the client whether their compliance regime requires read auditing
> — if it does, it changes the disk sizing significantly.

---

# 5. Configure the Log Destination

pgAudit writes into the normal PostgreSQL log, so the logging setup matters as much as pgAudit itself.

```yaml
postgresql:
  parameters:
    logging_collector: 'on'
    log_destination: 'csvlog'
    log_directory: '/var/log/postgresql'
    log_filename: 'postgresql-%Y-%m-%d_%H%M%S.log'
    log_file_mode: '0600'
    log_rotation_age: '1d'
    log_rotation_size: '100MB'
    log_truncate_on_rotation: 'off'

    # Who, from where, on which database — needed for any audit entry to be useful
    log_line_prefix: '%m [%p] %q%u@%d from %h '

    log_connections: 'on'
    log_disconnections: 'on'
    log_checkpoints: 'on'
    log_lock_waits: 'on'
    log_temp_files: '0'
    log_autovacuum_min_duration: '0'
    log_min_duration_statement: '1000'
```

`logging_collector` requires a restart — set it in the same window as section 3.

CSV format is chosen because it is machine-readable: it can be loaded straight into a table for querying, or shipped to Loki or a SIEM without parsing a free-text format.

```text
log_connections / log_disconnections   who connected and when
log_lock_waits                         blocking, for operational triage
log_min_duration_statement = 1000      slow queries over 1 second
log_line_prefix with %u@%d and %h      user, database and client address
```

---

# 6. Verify pgAudit Is Working

Generate an auditable event:

```sql
CREATE TABLE audit_probe (id int);
INSERT INTO audit_probe VALUES (1);
DROP TABLE audit_probe;
```

Then look at the log:

```bash
sudo tail -f /var/log/postgresql/postgresql-*.csv | grep AUDIT
```

You should see entries like:

```text
AUDIT: SESSION,1,1,DDL,CREATE TABLE,TABLE,public.audit_probe,"CREATE TABLE audit_probe (id int);",<none>
AUDIT: SESSION,2,1,WRITE,INSERT,TABLE,public.audit_probe,"INSERT INTO audit_probe VALUES (1);",<none>
AUDIT: SESSION,3,1,DDL,DROP TABLE,TABLE,public.audit_probe,"DROP TABLE audit_probe;",<none>
```

The fields are: audit type, statement id, substatement id, class, command, object type, object name, statement, parameters.

---

# 7. Log Rotation and Retention

PostgreSQL's own rotation only cycles filenames — it does not delete anything. Without a retention policy the log directory grows until the disk fills, which stops the database.

Add logrotate on every node:

```bash
sudo tee /etc/logrotate.d/postgresql-audit > /dev/null <<'ROT'
/var/log/postgresql/*.csv /var/log/postgresql/*.log {
    daily
    rotate 90
    compress
    delaycompress
    missingok
    notifempty
    create 0600 postgres postgres
    su postgres postgres
}
ROT
```

Test without waiting a day:

```bash
sudo logrotate -d /etc/logrotate.d/postgresql-audit
```

> **`rotate 90` is a placeholder.**
>
> Retention is a compliance decision, not a technical one. The Scope of Work asks
> for "retention guidance" — bring a recommendation to the meeting and get the
> actual number in writing. Common regimes are 90 days, 1 year, or 7 years, and
> the difference is enormous for disk sizing.

Also monitor the log filesystem — the node_exporter dashboard already covers `/var/log` if it is a separate mount. If it is not, consider making it one so a runaway audit log cannot take down PostgreSQL.

---

# 8. Object-Level Auditing for Sensitive Tables

Session auditing (`pgaudit.log`) applies to everything. To audit reads on a small set of sensitive tables without the volume of `pgaudit.log = 'read'`, use object auditing.

```sql
-- A role that exists only to carry audit grants. It never logs in.
CREATE ROLE auditor NOLOGIN;

-- Auditing SELECT on this table specifically
GRANT SELECT ON public.employees_salary TO auditor;
```

Then tell pgAudit to use it:

```yaml
postgresql:
  parameters:
    pgaudit.role: 'auditor'
```

Every SELECT on `employees_salary` is now logged, and nothing else is. Grant more privileges to `auditor` to widen the scope, table by table.

---

# 9. Protect the Audit Trail

An audit log the audited user can delete is not an audit log.

```bash
sudo chown -R postgres:postgres /var/log/postgresql
sudo chmod 700 /var/log/postgresql
```

For a real compliance requirement the logs must leave the node:

```text
* Ship to a central log store — Loki on the monitoring VM is the cheapest option
  and reuses the Grafana already deployed.

* Or forward to the client's existing SIEM if they have one. Ask.

* The receiving system must be one that database administrators cannot write to,
  otherwise the separation of duties the audit exists to prove does not hold.
```

This also closes the Scope of Work "log visibility" requirement, which metrics alone do not satisfy.

---

# 10. What This Costs

Be honest with the client about the overhead:

```text
* pgaudit.log = 'ddl,role,write' on a write-heavy database roughly doubles
  log volume compared to default logging.

* pgaudit.log_relation = 'on' emits one entry per table per statement. A
  statement touching five tables produces five entries.

* CPU overhead is small — single-digit percent — but log write I/O is not.
  On a busy system put /var/log on a separate volume from the data directory.

* Adding 'read' can multiply volume by ten or more. Do not enable it globally.
```

Measure it on the demo cluster before quoting a disk size.

---

# 11. Checklist

```text
* [ ] postgresql-18-pgaudit installed on every node, HQ and DR
* [ ] shared_preload_libraries includes pgaudit
* [ ] Rolling restart completed, all nodes streaming, no pending_restart
* [ ] pgaudit.log = 'ddl,role,write'
* [ ] pgaudit.log_parameter and log_relation are on
* [ ] logging_collector on, log_destination csvlog
* [ ] log_line_prefix includes user, database and client address
* [ ] log_connections and log_disconnections on
* [ ] Test DDL/INSERT/DROP produced AUDIT entries in the log
* [ ] logrotate installed and tested
* [ ] Retention period confirmed in writing by the client
* [ ] /var/log/postgresql is 700 and owned by postgres
* [ ] Log shipping destination agreed (Loki, SIEM, or documented as out of scope)
* [ ] Log volume measured on the demo cluster and factored into sizing
```
