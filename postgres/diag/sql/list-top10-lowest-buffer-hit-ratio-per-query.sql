

-- this query requires the extesion pg_stat_statements. 
-- please make sure it is created before executing.
-- create extension pg_stat_statements; 

SELECT query
      ,calls
      ,total_exec_time
      ,rows
      ,100.0*shared_blks_hit/nullif(shared_blks_hit + shared_blks_read,0) AS hit_percent
  FROM pg_stat_statements 
ORDER BY hit_percent 
LIMIT 10;


