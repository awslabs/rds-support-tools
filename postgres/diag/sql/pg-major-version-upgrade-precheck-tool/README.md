# Aurora/RDS PostgreSQL Major Version Upgrade Precheck Tool (SQL)

Run this tool before performing a Major Version Upgrade on Aurora PostgreSQL or RDS PostgreSQL to detect common issues that may cause the upgrade to fail.

Supported target versions: PostgreSQL 11 – 17

> **Note:** These SQL scripts must be executed against each database individually. If you need automated execution across all databases in a cluster, use the [shell script version](https://github.com/awslabs/rds-support-tools/tree/main/postgres/diag/shell/pg-major-version-upgrade-precheck-tool) which iterates all user databases automatically.

## Two Versions Provided

| File | Type | How to Run |
|------|------|------------|
| `pg-major-version-upgrade-precheck-sql.sql` | SQL (psql meta-commands) | Execute via `psql` |
| `pg-major-version-upgrade-precheck-plpgsql.sql` | PL/pgSQL function | Call with `SELECT` from any PostgreSQL client |

## Check Overview

Checks are organized into three categories:

- **Standard Checks (1–23)**: Database health, performance, and compatibility analysis
- **Blue/Green Deployment Checks (24–35c)**: Logical replication requirements for Blue/Green upgrades (can be ignored if not using Blue/Green deployments)
- **Critical Upgrade Blocker Checks (36–46)**: Issues that will cause `pg_upgrade` to fail

Each check falls into one of two scopes:

- **[global]**: Run once against the `postgres` database
- **[per-database]**: Must be run against each user database

## Usage

### SQL Version (psql)

Pass the target version using the `-v` flag:

```bash
# Global + per-database checks (run against each database)
psql "host=<HOST> port=<PORT> user=<USER> dbname=postgres sslmode=verify-full sslrootcert=global-bundle.pem" \
     -v target_version=16 -f pg-major-version-upgrade-precheck-sql.sql

# Per-database checks (run against each user database)
psql "host=<HOST> port=<PORT> user=<USER> dbname=<DBNAME> sslmode=verify-full sslrootcert=global-bundle.pem" \
     -v target_version=16 -f pg-major-version-upgrade-precheck-sql.sql
```

### PL/pgSQL Version

Execute the SQL file once to create the function, then call it with `SELECT`:

```bash
# Step 1: Load the function
psql "host=<HOST> port=<PORT> user=<USER> dbname=postgres sslmode=verify-full sslrootcert=global-bundle.pem" \
     -f pg-major-version-upgrade-precheck-plpgsql.sql
```

```sql
-- Step 2: Run the precheck (e.g. upgrading to PG 16)
SELECT * FROM public.pg_major_version_upgrade_precheck(16);

-- Or for a compact summary view:
SELECT check_id, check_scope, status FROM public.pg_major_version_upgrade_precheck(16);

-- Step 3: Clean up (recommended - remove the function after use)
DROP FUNCTION IF EXISTS public.pg_major_version_upgrade_precheck(integer);
```

Return columns:

| Column | Description |
|--------|-------------|
| `check_id` | Check identifier (e.g. 2, 13, 39b) |
| `check_scope` | `global` or `per-database` |
| `status` | `✓ PASSED`, `✓ INFO`, `❌ FAILED`, `⚠️ WARNING`, or `- SKIP` |
| `message` | Explanation of the result |
| `detail` | Specific objects or values that triggered the finding |

## Output Interpretation

| Status | Meaning | Action |
|--------|---------|--------|
| ✓ PASSED | Check passed, no issues found | None required |
| ✓ INFO | Informational only | Review for awareness |
| ⚠️ WARNING | Issues found that need attention | Evaluate and plan remediation |
| ❌ FAILED | Critical upgrade blocker detected | Must fix before upgrade |
| - SKIP | Check not applicable for this upgrade path | None required |

A summary is displayed at the end listing all FAILED and WARNING items.

## Required Privileges

### SQL Version

The executing user needs `SELECT` permission on these system catalogs:

```
pg_database, pg_prepared_xacts, pg_replication_slots, pg_settings,
pg_extension, pg_available_extensions, pg_type, pg_class, pg_namespace,
pg_attribute, pg_range, pg_conversion, pg_operator, pg_proc,
pg_aggregate, pg_subscription, pg_constraint, pg_event_trigger,
pg_roles, pg_stat_user_indexes, pg_stat_user_tables, pg_stat_activity,
pg_largeobject_metadata, pg_foreign_table, pg_foreign_server,
pg_foreign_data_wrapper, pg_publication, pg_index, pg_rewrite, pg_depend
```

### PL/pgSQL Version

- **Step 1 & 3** (CREATE/DROP function): `CREATE` privilege on the `public` schema
- **Step 2** (execution): Same `SELECT` permissions as the SQL version

## Note on Internal Schemas

This tool is designed for Amazon RDS/Aurora PostgreSQL and excludes `rdsadmin` from database/schema lists. For self-managed PostgreSQL or other managed services, update the internal-schema list accordingly.

## License

Apache License 2.0
