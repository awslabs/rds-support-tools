CREATE OR REPLACE VIEW vw_statio_all_indexes_history AS
WITH stat_history AS (
          SELECT  PSAIH.*
            FROM  pg_statio_all_indexes_history PSAIH
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
                      THEN idx_blks_read
                      ELSE coalesce((idx_blks_read - lag(idx_blks_read) OVER w),0)
                END AS idx_blks_read_df
               ,idx_blks_read
       		   ,CASE WHEN (row_number() OVER w =1 )
                      THEN idx_blks_hit
                      ELSE coalesce((idx_blks_hit - lag(idx_blks_hit) OVER w),0)
                  END AS idx_blks_hit_df
               ,idx_blks_hit
		  from stat_history
		 WINDOW w AS (PARTITION BY indexrelid  ORDER BY date_trunc('minute', inserted_at))	  
 )
   select * 
     from stat_window
     order by inserted_at asc, schemaname asc, relname asc, indexrelname asc;
