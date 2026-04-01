# RDS MySQL Binary Log Backup to S3

Download binary log files from an Amazon RDS MySQL instance and upload them to Amazon S3 on a scheduled basis.

## Overview

This script automates the process of:

1. Connecting to an RDS MySQL instance and listing available binary logs
2. Downloading each binary log using `mysqlbinlog --read-from-remote-server`
3. Uploading the downloaded files to an S3 bucket using `aws s3 sync`
4. Cleaning up local binlog files older than 1 day

Binary log backups are useful for point-in-time recovery beyond the RDS automated backup retention period, compliance and audit requirements, and disaster recovery to a different region or account.

> **Note:** The script excludes the last (most recent) binary log from the download because it may still be actively written to by the MySQL server, which would result in an incomplete file. See [issue #84](https://github.com/awslabs/rds-support-tools/issues/84).

For more details, see [How can I schedule uploads of Amazon RDS MySQL binary logs to Amazon S3?](https://repost.aws/knowledge-center/rds-mysql-schedule-binlog-uploads)

## Prerequisites

- An EC2 instance (or similar host) with network access to the RDS MySQL instance
- MySQL client (`mysql` and `mysqlbinlog` commands)
- AWS CLI configured with permissions to write to the target S3 bucket (`aws configure`)
- An RDS MySQL user with `REPLICATION SLAVE` privilege

## Setup

1. Edit the script variables to match your environment:

```bash
Backup_dir=/home/ec2-user/backup/binlog/$(date "+%Y-%m-%d")
Bucket='rds-binlogs'                                          # S3 bucket name
RDS='mysql57.xxxxxxxxxx.us-west-2.rds.amazonaws.com'          # RDS endpoint
master='admin'                                                 # MySQL username
export MYSQL_PWD='your_password'                               # MySQL password
```

> **Security:** Avoid hardcoding passwords in the script. Consider using AWS Secrets Manager, a `.my.cnf` file with restricted permissions, or environment variables instead.

2. Make the script executable:

```bash
chmod +x rds-binlog-to-s3.sh
```

3. Test manually:

```bash
./rds-binlog-to-s3.sh
```

4. Schedule with cron (e.g., every hour):

```bash
crontab -e
# Add:
0 * * * * /path/to/rds-binlog-to-s3.sh >> /var/log/binlog-backup.log 2>&1
```

## How It Works

```
RDS MySQL Instance
       │
       │  SHOW MASTER LOGS
       ▼
  List binary log files
  (exclude last — may be incomplete)
       │
       │  mysqlbinlog --read-from-remote-server
       ▼
  Local backup directory
  /home/ec2-user/backup/binlog/YYYY-MM-DD/
       │
       │  aws s3 sync
       ▼
  s3://rds-binlogs/binlog/
       │
       │  find -mtime +1 -exec rm
       ▼
  Clean up local files older than 1 day
```

## Additional Resources

- [Working with MySQL Binary Logs on RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_LogAccess.MySQL.BinaryFormat.html)
- [mysqlbinlog — Utility for Processing Binary Log Files](https://dev.mysql.com/doc/refman/8.0/en/mysqlbinlog.html)
- [AWS CLI S3 sync](https://docs.aws.amazon.com/cli/latest/reference/s3/sync.html)
