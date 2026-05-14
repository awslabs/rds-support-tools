# Aurora/RDS PostgreSQL Major Version Upgrade Precheck Tool (SQL)

Run this tool before performing a Major Version Upgrade on RDS/Aurora PostgreSQL to detect common issues that may cause the upgrade to fail.

Supported target versions: PostgreSQL 11 – 17

> **Note:** These SQL scripts must be executed against each database individually. If you need automated execution across all databases in a cluster, use the [shell script version](https://github.com/awslabs/rds-support-tools/tree/main/postgres/diag/shell/pg-major-version-upgrade-precheck-tool) which iterates all user databases automatically.

## SQL Version Provided

| File | Type | How to Run |
|------|------|------------|
| `pg-major-version-upgrade-precheck-sql.sql` | SQL (psql meta-commands) | Execute via `psql` |

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

## Note on Internal Schemas

This tool is designed for Amazon RDS/Aurora PostgreSQL and excludes `rdsadmin` from database/schema lists. For self-managed PostgreSQL or other managed services, update the internal-schema list accordingly.

## License

Apache License 2.0
