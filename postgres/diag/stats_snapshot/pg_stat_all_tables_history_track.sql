WITH stat_history AS (
          SELECT  PSATH.*
            FROM   pg_stat_all_tables_history PSATH
            WHERE  1=1
              AND  ( PSATH.relname NOT like 'pg_%' AND  PSATH.schemaname NOT like 'information_schema' ) -- let system objects out of this
              --AND  ( PSATH.relname like '%mitsta%' OR    PSATH.relname IN ('') -- replace tablename by the actual name of the table
               /*
              AND  EXISTS 
                (      -- primary filter
                       SELECT filter_tables_with.relid
                         FROM pg_stat_all_tables_history filter_tables_with
                        WHERE filter_tables_with.relid = PSATH.relid -- (for exists to work)
                          AND (      filter_tables_with.seq_scan > 2000  
                                  OR filter_tables_with.autovacuum_count > 100
                                  OR filter_tables_with.n_dead_tup > 2000
                                  OR filter_tables_with.idx_scan = 0
                              )
                ) -- */
  ),  stat_window AS (
          SELECT  
                  row_number() OVER w as row_pos
                 ,relid
                 ,schemaname
                 ,relname 
                 ,inserted_at
                 ,CASE WHEN (row_number() OVER w =1 )
                      THEN seq_scan
                      ELSE coalesce((seq_scan - lag(seq_scan) OVER w),0) 
                  END AS seq_scan_df
                 ,seq_scan 
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN seq_tup_read
                      ELSE coalesce((seq_tup_read - lag(seq_tup_read) OVER w),0) 
                  END AS seq_tup_read_df
                ,seq_tup_read
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN idx_scan
                      ELSE coalesce((idx_scan - lag(idx_scan) OVER w),0) 
                  END AS idx_scan_df                   
                ,idx_scan
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN idx_scan
                      ELSE coalesce((idx_tup_fetch - lag(idx_tup_fetch) OVER w),0) 
                  END AS idx_tup_fetch_df
                ,idx_tup_fetch
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_tup_ins
                      ELSE coalesce((n_tup_ins - lag(n_tup_ins) OVER w),0) 
                  END AS n_tup_ins_df
                ,n_tup_ins
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_tup_del
                      ELSE coalesce((n_tup_del - lag(n_tup_del) OVER w),0) 
                  END AS n_tup_del_df
                ,n_tup_del
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_tup_upd
                      ELSE coalesce((n_tup_upd - lag(n_tup_upd) OVER w),0) 
                  END AS n_tup_upd_df
                ,n_tup_upd
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_tup_hot_upd
                      ELSE coalesce((n_tup_hot_upd - lag(n_tup_hot_upd) OVER w),0) 
                  END AS n_tup_hot_upd_df
                ,n_tup_hot_upd
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_live_tup
                      ELSE coalesce((n_live_tup - lag(n_live_tup) OVER w),0) 
                  END AS n_live_tup_df
                ,n_live_tup
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_dead_tup
                      ELSE coalesce((n_dead_tup - lag(n_dead_tup) OVER w),0) 
                  END AS n_dead_tup_df
                ,n_dead_tup
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_mod_since_analyze
                      ELSE coalesce((n_mod_since_analyze - lag(n_mod_since_analyze) OVER w),0) -- because this number might decrease over time/inside same window
                  END AS n_mod_since_analyze_df                                                -- I would say that we should use avg()  or stddev() [?]
                ,n_mod_since_analyze
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN vacuum_count
                      ELSE coalesce((vacuum_count - lag(vacuum_count) OVER w),0) 
                  END AS vacuum_count_df
                ,vacuum_count
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN autovacuum_count
                      ELSE coalesce((autovacuum_count - lag(autovacuum_count) OVER w),0) 
                  END AS autovacuum_count_df
                ,autovacuum_count
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN analyze_count
                      ELSE coalesce((analyze_count - lag(analyze_count) OVER w),0) 
                  END AS analyze_count_df
                ,analyze_count
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN autoanalyze_count
                      ELSE coalesce((autoanalyze_count - lag(autoanalyze_count) OVER w),0) 
                  END AS autoanalyze_count_df
                ,autoanalyze_count
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN (n_tup_del + n_tup_upd + n_tup_ins)
                      ELSE coalesce(((n_tup_del + n_tup_upd + n_tup_ins) - lag((n_tup_del + n_tup_upd + n_tup_ins)) OVER w),0) 
                  END AS dml_sum_df
                ,n_tup_del + n_tup_upd + n_tup_ins AS dml_sum
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN (n_tup_del + n_tup_upd )
                      ELSE coalesce(((n_tup_del + n_tup_upd ) - lag((n_tup_del + n_tup_upd )) OVER w),0) 
                  END AS upd_del_sum_df
                ,n_tup_del + n_tup_upd  AS upd_del_sum
                ,last_vacuum
                ,last_autovacuum
                ,last_analyze
                ,last_autoanalyze
            FROM stat_history
            window w AS (PARTITION BY relid ORDER BY inserted_at )        
  ),  stat_final AS (
     SELECT *
           ,upd_del_sum/greatest(1,n_live_tup) as  change_ratio
           ,upd_del_sum/greatest(1,autovacuum_count) as average_change_per_vacuum
           ,upd_del_sum_df/greatest(1,n_live_tup_df) as  change_ratio_df
           ,upd_del_sum_df/greatest(1,autovacuum_count_df) as average_change_per_vacuum_df
       FROM stat_window
  )
   -- SELECT  distinct on (relid)  * FROM  stat_final sf   order by relid, row_pos desc  -- show only one last result per "encarnation" of the table
   SELECT distinct on(schemaname, relname) * FROM  stat_final sf WHERE change_ratio > 100 order by schemaname, relname asc, inserted_at desc -- show only one result (the last) per table
   -- SELECT * FROM stat_final  -- show all results (all tables and its encarnations)
    ;






WITH stat_history AS (
          SELECT  PSATH.*
            FROM   pg_stat_all_tables_history PSATH
            WHERE  1=1
              AND  ( PSATH.relname NOT like 'pg_%' AND  PSATH.schemaname NOT like 'information_schema' ) -- let system objects out of this
              --AND  ( PSATH.relname like '%mitsta%' OR    PSATH.relname IN ('') -- replace tablename by the actual name of the table
               /*
              AND  EXISTS 
                (      -- primary filter
                       SELECT filter_tables_with.relid
                         FROM pg_stat_all_tables_history filter_tables_with
                        WHERE filter_tables_with.relid = PSATH.relid -- (for exists to work)
                          AND (      filter_tables_with.seq_scan > 2000  
                                  OR filter_tables_with.autovacuum_count > 100
                                  OR filter_tables_with.n_dead_tup > 2000
                                  OR filter_tables_with.idx_scan = 0
                              )
                ) -- */
  ),  stat_window AS (
          SELECT  
                  row_number() OVER w as row_pos
                 ,relid
                 ,schemaname
                 ,relname 
                 ,inserted_at
                 ,CASE WHEN (row_number() OVER w =1 )
                      THEN seq_scan
                      ELSE coalesce((seq_scan - lag(seq_scan) OVER w),0) 
                  END AS seq_scan_df
                 ,seq_scan 
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN seq_tup_read
                      ELSE coalesce((seq_tup_read - lag(seq_tup_read) OVER w),0) 
                  END AS seq_tup_read_df
                ,seq_tup_read
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN idx_scan
                      ELSE coalesce((idx_scan - lag(idx_scan) OVER w),0) 
                  END AS idx_scan_df                   
                ,idx_scan
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN idx_scan
                      ELSE coalesce((idx_tup_fetch - lag(idx_tup_fetch) OVER w),0) 
                  END AS idx_tup_fetch_df
                ,idx_tup_fetch
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_tup_ins
                      ELSE coalesce((n_tup_ins - lag(n_tup_ins) OVER w),0) 
                  END AS n_tup_ins_df
                ,n_tup_ins
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_tup_del
                      ELSE coalesce((n_tup_del - lag(n_tup_del) OVER w),0) 
                  END AS n_tup_del_df
                ,n_tup_del
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_tup_upd
                      ELSE coalesce((n_tup_upd - lag(n_tup_upd) OVER w),0) 
                  END AS n_tup_upd_df
                ,n_tup_upd
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_tup_hot_upd
                      ELSE coalesce((n_tup_hot_upd - lag(n_tup_hot_upd) OVER w),0) 
                  END AS n_tup_hot_upd_df
                ,n_tup_hot_upd
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_live_tup
                      ELSE coalesce((n_live_tup - lag(n_live_tup) OVER w),0) 
                  END AS n_live_tup_df
                ,n_live_tup
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_dead_tup
                      ELSE coalesce((n_dead_tup - lag(n_dead_tup) OVER w),0) 
                  END AS n_dead_tup_df
                ,n_dead_tup
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN n_mod_since_analyze
                      ELSE coalesce((n_mod_since_analyze - lag(n_mod_since_analyze) OVER w),0) -- because this number might decrease over time/inside same window
                  END AS n_mod_since_analyze_df                                                -- I would say that we should use avg()  or stddev() [?]
                ,n_mod_since_analyze
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN vacuum_count
                      ELSE coalesce((vacuum_count - lag(vacuum_count) OVER w),0) 
                  END AS vacuum_count_df
                ,vacuum_count
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN autovacuum_count
                      ELSE coalesce((autovacuum_count - lag(autovacuum_count) OVER w),0) 
                  END AS autovacuum_count_df
                ,autovacuum_count
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN analyze_count
                      ELSE coalesce((analyze_count - lag(analyze_count) OVER w),0) 
                  END AS analyze_count_df
                ,analyze_count
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN autoanalyze_count
                      ELSE coalesce((autoanalyze_count - lag(autoanalyze_count) OVER w),0) 
                  END AS autoanalyze_count_df
                ,autoanalyze_count
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN (n_tup_del + n_tup_upd + n_tup_ins)
                      ELSE coalesce(((n_tup_del + n_tup_upd + n_tup_ins) - lag((n_tup_del + n_tup_upd + n_tup_ins)) OVER w),0) 
                  END AS dml_sum_df
                ,n_tup_del + n_tup_upd + n_tup_ins AS dml_sum
                ,CASE WHEN (row_number() OVER w =1 )
                      THEN (n_tup_del + n_tup_upd )
                      ELSE coalesce(((n_tup_del + n_tup_upd ) - lag((n_tup_del + n_tup_upd )) OVER w),0) 
                  END AS upd_del_sum_df
                ,n_tup_del + n_tup_upd  AS upd_del_sum
                ,last_vacuum
                ,last_autovacuum
                ,last_analyze
                ,last_autoanalyze
            FROM stat_history
            window w AS (PARTITION BY relid ORDER BY inserted_at )        
  ),  stat_final AS (
     SELECT *
           ,upd_del_sum/greatest(1,n_live_tup) as  change_ratio
           ,upd_del_sum/greatest(1,autovacuum_count) as average_change_per_vacuum
           ,upd_del_sum_df/greatest(1,n_live_tup_df) as  change_ratio_df
           ,upd_del_sum_df/greatest(1,autovacuum_count_df) as average_change_per_vacuum_df
       FROM stat_window
  )
   -- SELECT  distinct on (relid)  * FROM  stat_final sf   order by relid, row_pos desc  -- show only one last result per "encarnation" of the table
   SELECT distinct on(schemaname, relname) * FROM  stat_final sf WHERE change_ratio > 100 order by schemaname, relname asc, inserted_at desc -- show only one result (the last) per table
   -- SELECT * FROM stat_final  -- show all results (all tables and its encarnations)
    
    ;


