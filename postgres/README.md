# RDS PostgreSQL Support Scripts


[<img src="https://wiki.postgresql.org/images/a/a4/PostgreSQL_logo.3colors.svg" align="right"  width="100">](https://www.postgresql.org/)


## SQL Scripts: 

* [List ROLES (i.e. users and groups)](https://raw.githubusercontent.com/awslabs/rds-support-tools/master/postgres/diag/sql/list-roles.sql) 
* [List pg_stat_actitivy roles / showing the status of each connection](https://raw.githubusercontent.com/awslabs/rds-support-tools/master/postgres/diag/sql/list-sessions.sql)
* [List tables with dead tuples](https://raw.githubusercontent.com/awslabs/rds-support-tools/master/postgres/diag/sql/list-tables-with-dead-tuples.sql)
* [List tables and its ages](https://raw.githubusercontent.com/awslabs/rds-support-tools/master/postgres/diag/sql/list-tables-age.sql)
* [List sessions that are blocking others](https://raw.githubusercontent.com/awslabs/rds-support-tools/master/postgres/diag/sql/list-sessions-blocking-others.sql) 
* [List tables and its bloat ratio](https://raw.githubusercontent.com/awslabs/rds-support-tools/master/postgres/diag/sql/list-tables-bloated.sql)
* [List indexes and its bloat ratio](https://raw.githubusercontent.com/awslabs/rds-support-tools/master/postgres/diag/sql/list-btree-bloat.sql) 

## Shell scripts:

* [Catalog tables diagnostic script](https://github.com/awslabs/rds-support-tools/blob/master/postgres/diag/shell/postgresql-diagnostics.sh)

## RDS PostgreSQL public docs:

* [PostgreSQL on Amazon RDS](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/CHAP_PostgreSQL.html)
* [Common DBA Tasks for PostgreSQL](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Appendix.PostgreSQL.CommonDBATasks.html)

