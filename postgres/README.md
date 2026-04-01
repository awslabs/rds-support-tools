# RDS PostgreSQL Support Scripts


[<img src="https://wiki.postgresql.org/images/a/a4/PostgreSQL_logo.3colors.svg" align="right"  width="100">](https://www.postgresql.org/)


## SQL Scripts: 

* [List ROLES (i.e. users and groups)](https://raw.githubusercontent.com/awslabs/rds-support-tools/main/postgres/diag/sql/list-roles.sql) 
* [List pg_stat_actitivy roles / showing the status of each connection](https://raw.githubusercontent.com/awslabs/rds-support-tools/main/postgres/diag/sql/list-sessions.sql)
* [List tables with dead tuples](https://raw.githubusercontent.com/awslabs/rds-support-tools/main/postgres/diag/sql/list-tables-with-dead-tuples.sql)
* [List tables and its ages](https://raw.githubusercontent.com/awslabs/rds-support-tools/main/postgres/diag/sql/list-tables-age.sql)
* [List sessions that are blocking others](https://raw.githubusercontent.com/awslabs/rds-support-tools/main/postgres/diag/sql/list-sessions-blocking-others.sql) 
* [List tables and its bloat ratio](https://raw.githubusercontent.com/awslabs/rds-support-tools/main/postgres/diag/sql/list-tables-bloated.sql)
* [List indexes and its bloat ratio](https://raw.githubusercontent.com/awslabs/rds-support-tools/main/postgres/diag/sql/list-btree-bloat.sql) 
* [Top30 tables with low HOT updates ](https://raw.githubusercontent.com/awslabs/rds-support-tools/main/postgres/diag/sql/top30-tables-with-low-hotupdates.sql)
* [Set of scripts for periodically collecting activities (queries and objects stats)](https://github.com/awslabs/rds-support-tools/tree/main/postgres/diag/stats_snapshot)

## PostgreSQL Happiness hints:

* [https://ardentperf.com/happiness-hints/](https://ardentperf.com/happiness-hints/)


## More tools:

* [pgBadger / Postgres log parser and report generator](https://github.com/darold/pgbadger)
* [pg-collector](https://github.com/awslabs/pg-collector)
* [AWS PostgreSQL JDBC](https://github.com/awslabs/aws-postgresql-jdbc/)
* [Stats Analyzer](https://github.com/samimseih/statsanalyzer/)
* [ora2pg](https://github.com/darold/ora2pg)
* [pg_partman](https://github.com/pgpartman/pg_partman)
* [pg_cron](https://github.com/citusdata/pg_cron)

## RDS PostgreSQL public docs:

* [PostgreSQL on Amazon RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html)
* [Common DBA Tasks for PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.html)

## Connection poolers:

* [pgBouncer](http://www.pgbouncer.org/)
* [RDS Proxy](https://aws.amazon.com/rds/proxy/)

## Other scripts:

* [Catalog tables diagnostic script](https://github.com/awslabs/rds-support-tools/blob/main/postgres/diag/shell/postgresql-diagnostics.sh)
