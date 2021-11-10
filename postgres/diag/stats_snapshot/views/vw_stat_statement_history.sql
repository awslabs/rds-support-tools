CREATE OR REPLACE VIEW vw_stat_statements_history AS
WITH stat_history AS (
          SELECT  PSSH.*
                 ,PR.rolname as user_name
            FROM   pg_stat_statements_history PSSH
      inner join   pg_roles pr on (PSSH.userid = pr.OID )
            WHERE  1=1
              AND  ( pr.rolname != 'rdsadmin'  AND  PSSH.dbid  != 16384 and query not like '%history%' and query not like '%snapshot%') -- let system objects out of this
  ),  stat_window AS (
		select  row_number() OVER w as row_pos
               ,dbid
		       ,user_name
		       ,queryid
		       ,query
		       ,inserted_at
		      -- ,total_time
		      -- ,min_time
		      -- ,max_time
		      -- ,mean_time
		      -- ,stddev_time
		       ,CASE WHEN (row_number() OVER w =1 )
                      THEN calls
                      ELSE coalesce((calls - lag(calls) OVER w),0)
                  END AS calls_df
               ,calls
       		   ,CASE WHEN (row_number() OVER w =1 )
                      THEN rows
                      ELSE coalesce((rows - lag(rows) OVER w),0)
                  END AS rows_df
               ,rows
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN shared_blks_hit
                      ELSE coalesce((shared_blks_hit - lag(shared_blks_hit) OVER w),0)
                  END AS shared_blks_hit_df
               ,shared_blks_hit
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN shared_blks_read
                      ELSE coalesce((shared_blks_read - lag(shared_blks_read) OVER w),0)
                  END AS shared_blks_read_df
               ,shared_blks_read
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN shared_blks_dirtied
                      ELSE coalesce((shared_blks_dirtied - lag(shared_blks_dirtied) OVER w),0)
                  END AS shared_blks_dirtied_df
               ,shared_blks_dirtied
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN shared_blks_written
                      ELSE coalesce((shared_blks_written - lag(shared_blks_written) OVER w),0)
                  END AS shared_blks_written_df
               ,shared_blks_written
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN local_blks_hit
                      ELSE coalesce((local_blks_hit - lag(local_blks_hit) OVER w),0)
                  END AS local_blks_hit_df
               ,local_blks_hit
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN local_blks_read
                      ELSE coalesce((local_blks_read - lag(local_blks_read) OVER w),0)
                  END AS local_blks_read_df
               ,local_blks_read
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN local_blks_dirtied
                      ELSE coalesce((local_blks_dirtied - lag(local_blks_dirtied) OVER w),0)
                  END AS local_blks_dirtied_df
               ,local_blks_dirtied
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN local_blks_written
                      ELSE coalesce((local_blks_written - lag(local_blks_written) OVER w),0)
                  END AS local_blks_written_df
               ,local_blks_written
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN temp_blks_read
                      ELSE coalesce((temp_blks_read - lag(temp_blks_read) OVER w),0)
                  END AS temp_blks_read_df
               ,temp_blks_read
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN temp_blks_written
                      ELSE coalesce((temp_blks_written - lag(temp_blks_written) OVER w),0)
                  END AS temp_blks_written_df
               ,temp_blks_written
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN blk_read_time
                      ELSE coalesce((blk_read_time - lag(blk_read_time) OVER w),0)
                  END AS blk_read_time_df
               ,blk_read_time
               ,CASE WHEN (row_number() OVER w =1 )
                      THEN blk_write_time
                      ELSE coalesce((blk_write_time - lag(blk_write_time) OVER w),0)
                  END AS blk_write_time_df
               ,blk_write_time
		  from stat_history
		 WINDOW w AS (PARTITION BY queryid  ORDER BY date_trunc('minute', inserted_at))
 )
   select *
     from stat_window
     where 1=1
      -- and queryid = -2950157672037395628
     order by inserted_at asc, queryid asc;
