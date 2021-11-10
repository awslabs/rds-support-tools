CREATE OR REPLACE VIEW vw_stat_all_indexes_history AS
WITH stat_history AS (
          SELECT  PSAIH.*
            FROM  pg_stat_all_indexes_history PSAIH
           where PSAIH.schemaname !~  'pg_catalog'  
  ),  stat_window AS (
		select  row_number() OVER w as row_pos
               ,relid
               ,indexrelid
		       ,schemaname
		       ,relname
		       ,indexrelname
		       ,inserted_at
		       ,tags
		       ,CASE WHEN (row_number() OVER w =1 )
                      THEN idx_scan
                      ELSE coalesce((idx_scan - lag(idx_scan) OVER w),0)
                END AS idx_scan_df
               ,idx_scan
       		   ,CASE WHEN (row_number() OVER w =1 )
                      THEN idx_tup_read
                      ELSE coalesce((idx_tup_read - lag(idx_tup_read) OVER w),0)
                  END AS idx_tup_read_df
               ,idx_tup_read        
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN idx_tup_fetch
                      ELSE coalesce((idx_tup_fetch - lag(idx_tup_fetch) OVER w),0)
                  END AS idx_tup_fetch_df
               ,idx_tup_fetch                 
		  from stat_history
		 WINDOW w AS (PARTITION BY indexrelid  ORDER BY date_trunc('minute', inserted_at))	  
 )
   select * 
     from stat_window
    --where not (idx_scan_df = 0 and idx_scan = 0 and idx_tup_read_df = 0 and idx_tup_read = 0 and idx_tup_fetch_df = 0 and idx_tup_fetch = 0 )
     order by inserted_at asc, schemaname asc, relname asc, indexrelname asc;
  
