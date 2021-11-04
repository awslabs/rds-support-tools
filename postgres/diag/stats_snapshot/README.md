

Collecting database statistics and creating snapshots
---

Goals: 
  * Self-contained
  * Track objects and queries that might be causing more performance degradation;
  * Track objects and queries that are consuming more I/O

Requirements:
  * pg_stat_statements extension 

Optionally:
  * pg_cron (available on RDS/Aurora PostgreSQL 12.4 onwards) for triggering the collection function without external agents

Installing:
```
  export PGHOST="<RDS DB instance endpoint>"
  export PGDATABASE="<the database you want to track>"
  export PGUSER="<RDS DB instance master user>"
  export PGPASSWORD="<master user password>"
  export PGPORT="5432"
  psql -f setup
```

Snapshotting stats (at any time):
```
  SELECT snapshot_stats('00_project_label_001_initial-gather-stats');
```


Using pg_cron to snapshot the statistics;
```
CREATE EXTENSION pg_cron;
SELECT cron.schedule('@hourly', $$SELECT snapshot_stats('01_project_label_001_gather-stats');$$);
```

Reporting:
   * I/O Reports:
   * pg_stat_all_tables_history_track.sql
