-- https://www.postgresql.org/docs/current/monitoring-stats.html#PG-STAT-REPLICATION-VIEW
select now(),* from pg_catalog.pg_stat_replication;
