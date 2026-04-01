CREATE OR REPLACE VIEW vw_statio_all_tables_history AS
WITH stat_history AS (
          SELECT  PSATH.*
            FROM   pg_statio_all_tables_history PSATH
             -- WHERE  1=1
             --  AND  ( PSATH.relname NOT like 'pg_%' AND  PSATH.schemaname NOT like 'information_schema' ) -- let system objects out of this
             -- AND  ( PSATH.relname like '%mitsta%' OR PSATH.relname IN ('') -- replace tablename by the actual name of the table
               /*
              AND  EXISTS
                (      -- primary filter
                       SELECT filter_tables_with.relid
                         FROM pg_statio_all_tables_history filter_tables_with
                        WHERE filter_tables_with.relid = PSATH.relid -- (for exists to work)
                          AND (      filter_tables_with.heap_blks_read > 2000
                                  OR filter_tables_with.idx_blks_read > 100
                                  OR filter_tables_with.toast_blks_read > 2000
                                  OR filter_tables_with.tidx_blks_read = 0
                              )
                ) -- */
  ),  stat_window AS (
		select  row_number() OVER w as row_pos
               ,relid
		       ,schemaname
		       ,relname
		       ,inserted_at
		       ,CASE WHEN (row_number() OVER w =1 )
                      THEN heap_blks_read
                      ELSE coalesce((heap_blks_read - lag(heap_blks_read) OVER w),0)
                  END AS heap_blks_read_df
               ,heap_blks_read
       		   ,CASE WHEN (row_number() OVER w =1 )
                      THEN idx_blks_read
                      ELSE coalesce((idx_blks_read - lag(idx_blks_read) OVER w),0)
                  END AS idx_blks_read_df
               ,idx_blks_read        
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN toast_blks_read
                      ELSE coalesce((toast_blks_read - lag(toast_blks_read) OVER w),0)
                  END AS toast_blks_read_df
               ,toast_blks_read                 
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN tidx_blks_read
                      ELSE coalesce((tidx_blks_read - lag(tidx_blks_read) OVER w),0)
                  END AS tidx_blks_read_df
               ,tidx_blks_read
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN heap_blks_hit
                      ELSE coalesce((heap_blks_hit - lag(heap_blks_hit) OVER w),0)
                  END AS heap_blks_hit_df
               ,heap_blks_hit
       		   ,CASE WHEN (row_number() OVER w =1 )
                      THEN idx_blks_hit
                      ELSE coalesce((idx_blks_hit - lag(idx_blks_hit) OVER w),0)
                  END AS idx_blks_hit_df
               ,idx_blks_hit       
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN toast_blks_hit
                      ELSE coalesce((toast_blks_hit - lag(toast_blks_hit) OVER w),0)
                  END AS toast_blks_hit_df
               ,toast_blks_hit               
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN tidx_blks_hit
                      ELSE coalesce((tidx_blks_hit - lag(tidx_blks_hit) OVER w),0)
                  END AS tidx_blks_hit_df
               ,tidx_blks_hit
		  from stat_history
		 WINDOW w AS (PARTITION BY relid  ORDER BY date_trunc('minute', inserted_at))	  
 )
   select * 
     from stat_window 
    where not (heap_blks_read_df = 0  and heap_blks_read = 0 and idx_blks_read_df = 0 and idx_blks_read = 0   
               and toast_blks_read = 0 and toast_blks_read_df = 0 and tidx_blks_read_df = 0 and tidx_blks_read = 0   
               and heap_blks_hit_df = 0 and heap_blks_hit = 0 and idx_blks_hit_df = 0 and idx_blks_hit = 0 and toast_blks_hit_df = 0
               and toast_blks_hit = 0 and tidx_blks_hit_df = 0 and tidx_blks_hit = 0) 
     order by inserted_at asc, schemaname asc, relname asc;
  
