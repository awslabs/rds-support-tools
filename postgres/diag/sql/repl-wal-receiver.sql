-- https://www.postgresql.org/docs/current/monitoring-stats.html#PG-STAT-WAL-RECEIVER-VIEW
SELECT now(),* FROM pg_catalog.pg_stat_wal_receiver;
