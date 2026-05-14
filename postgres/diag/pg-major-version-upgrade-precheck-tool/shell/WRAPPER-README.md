# Wrapper Script for Batch Pre-Upgrade Checks

## Overview

`wrapper.sh` runs pre-upgrade checks against multiple RDS/Aurora PostgreSQL Instances/Clusters using a CSV file. It calls `pg-major-version-upgrade-precheck.sh` for each entry and produces a summary of results.

## Prerequisites

- `pg-major-version-upgrade-precheck.sh` in the same directory
- **bash** 4.0+, **psql**, **aws** CLI, **jq**
- Database credentials and AWS access for all instances

## Quick Start

```bash
./wrapper.sh
```

**Option 1** — Discover RDS/Aurora instances and generate a CSV template.  
**Option 2** — Run pre-upgrade checks for all entries in the CSV.

## CSV Format

```
mode,region,identifier,profile,host,port,database,username,password,secret_arn,secret_key,baseline,engine,blue_green,format
```

### Column Reference

| Column | Description | Example |
|--------|-------------|---------|
| `mode` | `rds`, `sql`, or `both` | `both` |
| `region` | AWS region | `us-east-1` |
| `identifier` | RDS DB/Cluster identifier | `my-cluster` |
| `profile` | AWS CLI profile | `default` |
| `host` | Database endpoint | `mydb.cluster-xxx.rds.amazonaws.com` |
| `port` | Database port | `5432` |
| `database` | Database name | `postgres` |
| `username` | Database username | `admin` |
| `password` | Password (leave empty if using `secret_arn`) | `MyPassword` |
| `secret_arn` | Secrets Manager ARN or name (alternative to password) | `my-db-secret` |
| `secret_key` | JSON key for password in secret | `password` |
| `baseline` | Create baseline stats: `yes` or `no` | `no` |
| `engine` | `aurora-postgresql` or `postgres` | `aurora-postgresql` |
| `blue_green` | Enable Blue/Green checks: `Y` or `N` | `Y` |
| `format` | Report format: `html` or `text` | `html` |

### Example CSV

```csv
mode,region,identifier,profile,host,port,database,username,password,secret_arn,secret_key,baseline,engine,blue_green,format
both,us-east-1,prod-cluster,default,prod.cluster-xxx.rds.amazonaws.com,5432,postgres,admin,SecurePass,,,yes,aurora-postgresql,Y,html
both,us-east-1,staging-cluster,default,staging.cluster-xxx.rds.amazonaws.com,5432,postgres,admin,,my-secret,password,no,aurora-postgresql,N,html
sql,us-west-2,dev-instance,default,dev.xxx.rds.amazonaws.com,5432,mydb,dbuser,DevPass,,,no,postgres,N,text
```

## Report Format

The `format` column controls the output for each instance:

- `html` (default) — Interactive HTML report. Open in a browser.
- `text` — Plain text report. Useful for CI/CD pipelines or logging.

When `html` is specified (or the column is empty), the `--format` flag is omitted for backward compatibility with older versions of the script.

## Password Options

Use either `password` or `secret_arn` per row — not both.

```csv
# Direct password
...,MyPassword,,,no,...

# Secrets Manager by name
...,,my-db-secret,password,no,...

# Secrets Manager by ARN with custom key
...,,arn:aws:secretsmanager:us-east-1:123:secret:my-db,db_password,no,...
```

## Security

- Passwords and secret ARNs are masked in console output
- Store the CSV with restricted permissions: `chmod 600 rds_instances.csv`
- Never commit the CSV to version control
- Use AWS Secrets Manager for production credentials

## Troubleshooting

| Problem | Solution |
|---------|----------|
| `CSV file not found` | Run option 1 to generate it, or create manually |
| `Missing SQL connection parameters` | Ensure host, port, database, username are filled in |
| `Unknown option: --format` | Update `pg-major-version-upgrade-precheck.sh` to the latest version |
| `pg-major-version-upgrade-precheck.sh not found` | Ensure both scripts are in the same directory |
| Empty password warning | Fill in `password` or `secret_arn` column, or confirm to continue |
