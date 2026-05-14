# RDS/Aurora PostgreSQL Major Version Upgrade Precheck Tool

## Overview

Validates RDS/Aurora PostgreSQL databases before a major version upgrade. Identifies configuration issues, compatibility blockers, and Blue/Green deployment requirements.

## Prerequisites

- **bash** 4.0+
- **psql** (PostgreSQL client)
- **aws** CLI (for RDS mode)
- **jq** (JSON processor)

## Usage

### Interactive Mode

```bash
./pg-major-version-upgrade-precheck.sh
```

Prompts for run mode, connection details, password, report format, and optional Blue/Green checks.

### Non-Interactive Mode

```bash
# SQL checks only
./pg-major-version-upgrade-precheck.sh --non-interactive -m sql \
  -h mydb.rds.amazonaws.com -P 5432 -d postgres -u admin -w mypassword

# RDS configuration only
./pg-major-version-upgrade-precheck.sh --non-interactive -m rds \
  -r us-east-1 -i my-db-instance -p default

# Both RDS + SQL
./pg-major-version-upgrade-precheck.sh --non-interactive -m both \
  -r us-east-1 -i my-db-instance -p default \
  -h mydb.rds.amazonaws.com -P 5432 -d postgres -u admin -w mypassword

# With Blue/Green checks
./pg-major-version-upgrade-precheck.sh --non-interactive --blue-green -m sql \
  -h mydb.rds.amazonaws.com -d postgres -u admin -w mypassword

# Text report instead of HTML
./pg-major-version-upgrade-precheck.sh --non-interactive -m sql \
  -h mydb.rds.amazonaws.com -d postgres -u admin -w mypassword --format text
```

### Using AWS Secrets Manager

```bash
# By secret name
./pg-major-version-upgrade-precheck.sh --non-interactive -m sql \
  -h mydb.rds.amazonaws.com -d postgres -u admin -s my-db-secret

# By ARN with custom JSON key
./pg-major-version-upgrade-precheck.sh --non-interactive -m sql \
  -h mydb.rds.amazonaws.com -d postgres -u admin \
  -s arn:aws:secretsmanager:us-east-1:123456789:secret:my-secret \
  --secret-key db_password
```

Secret must be stored as JSON: `{"password": "your-password"}`

## Options

| Option | Description | Default |
|--------|-------------|---------|
| `-m, --mode` | `sql`, `rds`, or `both` | required |
| `-h, --host` | Database endpoint | required for sql/both |
| `-P, --port` | Database port | `5432` |
| `-d, --database` | Database name | required for sql/both |
| `-u, --user` | Database username | required for sql/both |
| `-w, --password` | Database password | required for sql/both* |
| `-s, --secret-arn` | Secrets Manager ARN or name | alternative to password |
| `--secret-key` | JSON key for password in secret | `password` |
| `-r, --region` | AWS region | required for rds/both |
| `-i, --identifier` | RDS DB/Cluster identifier | required for rds/both |
| `-p, --profile` | AWS CLI profile | `default` |
| `-b, --baseline` | Create baseline stats (`yes`/`no`) | `no` |
| `--blue-green` | Enable Blue/Green deployment checks | `false` |
| `--format` | Report format: `html` or `text` | `html` |
| `--non-interactive` | Skip all prompts | `false` |

## Report Format

The script generates a report named `rds_precheck_report_<identifier>_<timestamp>.<ext>`.

- `--format html` (default) — Interactive HTML report with expandable sections. Open in a browser.
- `--format text` — Plain text report. Suitable for CI/CD pipelines, logging, or terminal review.

In interactive mode, the script prompts you to choose the format.

## Checks Performed

### Standard Checks (always run)
- PostgreSQL version, database size, object counts
- Invalid databases, template database verification
- Table/index health, bloat, unused indexes
- Replication slots, prepared transactions
- Extension compatibility and outdated versions
- Critical upgrade blockers (deprecated types, removed features)

### Blue/Green Checks (`--blue-green`)
- Logical replication parameter configuration
- `max_locks_per_transaction` validation for shared memory
- Table replica identity (primary keys required)
- DDL event triggers and DTS trigger detection
- Publications, subscriptions, foreign tables
- Extension compatibility for Blue/Green

## Environment Variables

```bash
export RUN_MODE="sql"
export DB_HOST="mydb.rds.amazonaws.com"
export DB_PORT="5432"
export DB_NAME="postgres"
export DB_USER="admin"
export DB_PASS="mypassword"
export REPORT_FORMAT="text"
export BLUE_GREEN_MODE="true"

./pg-major-version-upgrade-precheck.sh --non-interactive
```

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `Permission denied` | `chmod +x pg-major-version-upgrade-precheck.sh` |
| Connection failed | Verify endpoint, port, credentials, and security group rules |
| AWS CLI error | Run `aws configure --profile <profile>` |
| `jq: command not found` | Install jq: `brew install jq` or `apt-get install jq` |
| `Unknown option: --format` | Update to the latest version of the script |

## Batch Execution

Use `wrapper.sh` to run checks against multiple databases from a CSV file. See `WRAPPER-README.md`.
