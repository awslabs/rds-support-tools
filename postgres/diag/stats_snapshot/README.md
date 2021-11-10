

# Collecting database statistics and creating snapshots

## Goals: 
  * Self-contained
  * Track objects and queries that might be causing more performance degradation;
  * Track objects and queries that are consuming more I/O

## Requirements:
  * [pg_stat_statements](https://www.postgresql.org/docs/current/pgstatstatements.html) extension must be installed and created 
    by default Aurora Postgres has pg_stat_statements in the `shared_preload_libraries` parameter, so you just need to run `CREATE EXTENSION pg_stat_statements` in the database you want to monitor
  * [track_activities](https://www.postgresql.org/docs/current/runtime-config-statistics.html#GUC-TRACK-ACTIVITIES) parameters must be on (already default)

### Optionally:
  * pg_cron (available on RDS/Aurora PostgreSQL 12.4 onwards) for triggering the collection function without external agents. 
  <!-- https://www.postgresql.org/docs/current/runtime-config-statistics.html#GUC-TRACK-IO-TIMING not recommeded. It will repeatedly query the operating system for the current time, which may cause significant overhead on some platforms.  -->

## Installing:
```
  export PGHOST="<RDS DB instance endpoint>"
  export PGDATABASE="<the database you want to track>"
  export PGUSER="<RDS DB instance master user>"
  export PGPASSWORD="<master user password>"
  export PGPORT="5432"
  psql -f setup.sql
  psql -f views/vw_stat_all_tables_history.sql
  psql -f views/vw_statio_all_tables_history.sql
  psql -f views/vw_stat_statement_history.sql
```

## Testing the gather and collecting the first snapshot stats:
```
  SELECT snapshot_stats('00_project_label_001_initial-gather-stats');
```

## Automating the history statistics collection using pg_cron

You can [learn more](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL_pg_cron.html) about pg_cron on Aurora in our [public docs](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/PostgreSQL_pg_cron.html).
```
-- by default the pg_cron extension must be installed in the database defined by the parameter `cron.database_name`
CREATE EXTENSION pg_cron;
-- SELECT cron.schedule('@hourly', $$SELECT snapshot_stats('01_project_label_001_gather-stats');$$);
SELECT cron.schedule('*/5 * * * *', $$SELECT snapshot_stats('01_every_05min_gather-stats');$$);
```

## Reports

Reporting through views:
   * All tables general (`pg_stat_all_tables`):  `vw_stat_all_tables_history`
   * I/O (`pg_statio_all_tables`): `vw_statio_all_tables_history`
   * Statements (`pg_stat_statements`): `vw_stat_statement_history`

   Notes:
   *  1. Columns that ends with `_df` is the difference between the time the collection was done (showed by the column `inserted_at` and the previous collection)
   *  2. Columns that does not end with `_df` are the cumulative counters as they were at the moment when the collection was done.


## Reseting cumulative postgres counters
    
  * Cumulative values for `pg_stat_statements` can be reset using executiong: `SELECT pg_stat_statements_reset();`. Read more details about this function and its variations ![here](https://www.postgresql.org/docs/current/pgstatstatements.html#id-1.11.7.39.8.2.1.1.2).
  * For views such `pg_stat_all_tables`, `pg_statio_all_tables`, etc. the cumulative counters can be reset by calling: `SELECT pg_stat_reset();`. Variations also in Postgres docs ![here](https://www.postgresql.org/docs/current/monitoring-stats.html#id-1.6.15.7.26.4.2.2.5.1.1.1).

