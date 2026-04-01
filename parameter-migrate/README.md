# Migrate Amazon RDS Parameter Group

Automate parameter group migration across engine versions, engine types (RDS ↔ Aurora), and AWS regions using the AWS CLI.

## Overview

Migrating database parameter group settings is one of the most common operational tasks when performing:

- Engine version upgrades (e.g., RDS MySQL 5.7 → 8.0, PostgreSQL 14 → 15)
- Migration to Aurora (e.g., RDS MySQL → Aurora MySQL 3, RDS PostgreSQL → Aurora PostgreSQL)
- Cross-region disaster recovery setup (copy parameter group to another region)

Without automation, engineers must manually identify, compare, and re-apply every modified parameter — a process that is tedious, error-prone, and time-consuming, especially for databases with hundreds of customized parameters.

A missing or misconfigured parameter can cause performance degradation, application errors, or security compliance violations. This is compounded by the fact that:

- Parameters valid in one engine version may not exist in another
- Some parameters behave differently across engines (e.g., RDS MySQL vs Aurora MySQL)
- Aurora cluster parameter groups have a different structure from RDS instance parameter groups
- Certain parameters require prerequisites before they can be applied (e.g., `innodb_flush_log_at_trx_commit` in Aurora MySQL 3)

| | Manual Approach | This Script |
|---|---|---|
| Method | Console UI — one by one | AWS CLI — fully automated |
| Time | Hours for large groups | Minutes |
| Error risk | High — easy to miss parameters | Low — automated validation |
| Compatibility check | Manual — check docs per parameter | Automatic — API-driven |
| Cross-region | Not straightforward | Built-in support |
| Audit trail | None | Full migration report |

> **⚠️ Important: Always Review Parameters Before Applying**
>
> This script automates parameter migration as a starting point — not a final configuration.
> Carrying over parameters as-is when upgrading or changing the engine type is not a best practice.
> Parameters may behave differently depending on the target engine version or type.
>
> Before applying migrated parameters to a production database:
> - Review the migration report (APPLIED, SKIPPED, INCOMPATIBLE, and FAILED sections)
> - Verify each applied parameter is appropriate for the target engine
> - Test in a non-production environment first
> - Consult engine-specific documentation — parameter semantics can differ between RDS and Aurora, or between major versions

## Common Use Cases

| Source | Target |
|---|---|
| RDS PostgreSQL | Aurora PostgreSQL |
| Aurora PostgreSQL | RDS PostgreSQL |
| RDS MySQL | Aurora MySQL |
| Aurora MySQL | RDS MySQL |
| RDS MariaDB | Aurora MySQL |
| Any engine (same version) | Same engine (cross-region copy) |
| Any engine | Same engine (version upgrade) |

> **Note:** The script uses the AWS API `IsModifiable` flag to determine what can be applied.
> Parameters not found in the target engine are reported as INCOMPATIBLE.
> Parameters found but not modifiable are reported as SKIPPED.
> Parameters rejected by the API are reported as FAILED with the error reason.

## How It Works

```
Source Parameter Group                    Target Parameter Group
(user-modified params only)               (new version / new engine)
         │                                          │
         │  export_params()                         │  create_target_group()
         ▼                                          ▼
  source_params.json          ──────►   target_valid_params.json
         │                    filter           │
         │                    _params()        │
         ▼                                     ▼
  ┌─────────────┐   ┌─────────────┐   ┌──────────────────┐
  │  APPLICABLE │   │   SKIPPED   │   │   INCOMPATIBLE   │
  │             │   │             │   │                  │
  │ Found in    │   │ Found in    │   │ Not found in     │
  │ target AND  │   │ target BUT  │   │ target engine    │
  │ modifiable  │   │ not         │   │ at all           │
  └──────┬──────┘   │ modifiable  │   └──────────────────┘
         │          └─────────────┘
         ▼
  apply_params() ── batch apply
         │
         ├── ✅ Success → APPLIED
         │
         └── ❌ Batch fail → retry individually
                   │
                   ├── ✅ Success → APPLIED
                   ├── 🔄 Has prerequisite → apply prereq → retry → APPLIED
                   └── ❌ Still fail → FAILED (with reason)
```

## Prerequisites

- AWS CLI v2 ([install guide](https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html))
- jq ([download](https://jqlang.github.io/jq/download/))
- AWS credentials configured (`aws configure`)

```bash
# Verify
aws --version && jq --version
```

## Usage

```bash
chmod +x migrate_param_group.sh

./migrate_param_group.sh -s <source_group> -t <target_group> -f <target_family> [options]
```

### Options

| Flag | Description | Required | Default |
|------|-------------|----------|---------|
| `-s` | Source parameter group name | Yes | — |
| `-t` | Target parameter group name | Yes | — |
| `-f` | Target parameter group family | Yes | — |
| `-S` | Source AWS region | No | AWS CLI configured region |
| `-T` | Target AWS region | No | AWS CLI configured region |
| `-b` | Batch size for apply operations | No | 20 |
| `-n` | Dry run (no changes applied) | No | — |

### Examples

```bash
# RDS PostgreSQL → Aurora PostgreSQL (same region)
./migrate_param_group.sh \
  -s my-rds-pg15 \
  -t my-aurora-pg15-cluster \
  -f aurora-postgresql15

# RDS MySQL → Aurora MySQL (same region)
./migrate_param_group.sh \
  -s my-rds-mysql80 \
  -t my-aurora-mysql80-cluster \
  -f aurora-mysql8.0

# Cross-region copy (same engine)
./migrate_param_group.sh \
  -s my-rds-pg15 \
  -t my-rds-pg15-copy \
  -f postgres15 \
  -S us-east-1 \
  -T ap-southeast-1

# Cross-region with engine migration
./migrate_param_group.sh \
  -s my-rds-pg15 \
  -t my-aurora-pg15-cluster \
  -f aurora-postgresql15 \
  -S us-east-1 \
  -T ap-southeast-1

# Dry run (preview only, no changes)
./migrate_param_group.sh \
  -s my-rds-pg15 \
  -t my-aurora-pg15-cluster \
  -f aurora-postgresql15 \
  -n
```

## Output

The script creates a timestamped directory with all artifacts:

```
migration_20260331_084920/
├── source_params.json         # Exported source parameters (user-modified only)
├── target_valid_params.json   # All valid parameters in target engine
├── params_applicable.json     # Parameters applied to target
├── params_skipped.json        # Found in target but not modifiable
├── params_incompatible.json   # Not found in target engine
├── params_failed.json         # API rejected — review required
└── migration_report.txt       # Full migration report
```

## Sample Output

### Successful Migration (Aurora MySQL → RDS MySQL, same region)

```
============================================================
  PARAMETER GROUP MIGRATION REPORT
  Date    : Tue Mar 31 08:49:29 UTC 2026
  DryRun  : false
============================================================
  Source  : ams303 [aurora-mysql8.0 | cluster | us-west-2]
  Target  : mysql84 [mysql8.4 | instance | us-west-2]
------------------------------------------------------------
  Total Exported  : 10
  Applied         : 6
  Skipped         : 0
  Incompatible    : 4
  Failed          : 0
============================================================
```

### Cross-Region Copy (Aurora PostgreSQL → RDS PostgreSQL)

```
============================================================
  PARAMETER GROUP MIGRATION REPORT
  Date    : Tue Mar 31 08:46:28 UTC 2026
  DryRun  : false
============================================================
  Source  : apg16 [aurora-postgresql16 | instance | us-west-2]
  Target  : pg17 [postgres17 | instance | us-east-1]
------------------------------------------------------------
  Total Exported  : 1
  Applied         : 1
  Skipped         : 0
  Incompatible    : 0
  Failed          : 0
============================================================
```

### Target Group Already Exists (script stops)

```
=== Step 3: Create Target Parameter Group ===
[ERROR] Failed to create parameter group: mysql84
[ERROR] Reason: An error occurred (DBParameterGroupAlreadyExists) when calling
        the CreateDBParameterGroup operation: Parameter group mysql84 already exists
```

## Parameter Prerequisite Handling

Some parameters require other parameters to be set first. The script handles this automatically.

For example, when migrating `innodb_flush_log_at_trx_commit` from RDS MySQL (which supports values 0, 1, 2) to Aurora MySQL 3 (which only supports 0 or 1):

1. The script detects the source value is not 1 (e.g., value is 2)
2. Applies the prerequisite: `innodb_trx_commit_allow_data_loss = 1`
3. Applies the parameter with an overridden value: `innodb_flush_log_at_trx_commit = 0`

Additional prerequisites can be added to the `PARAM_PREREQUISITES` array in the script.

## Additional Resources

- [Working with DB Parameter Groups](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithParamGroups.html)
- [Aurora PostgreSQL Parameters](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraPostgreSQL.Reference.ParameterFiles.html)
- [Aurora MySQL Parameters](https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraMySQL.Reference.ParameterGroups.html)
- [AWS CLI RDS Reference](https://docs.aws.amazon.com/cli/latest/reference/rds/)
