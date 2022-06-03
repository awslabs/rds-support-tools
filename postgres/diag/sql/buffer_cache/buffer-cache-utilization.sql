\x
WITH unused_buffers AS (
      select  count(*) count_unused_buffers 
            , (count (*) * 8)/1024 as unused_buffercache_size_MB 
        from pg_buffercache 
       where relfilenode is null
),
used_buffers AS (
       select  count(*) count_used_buffers
             , (count (*) * 8)/1024 as used_buffercache_size_MB 
         from pg_buffercache 
         where relfilenode is not null
), total_buffercache as (
        select count(*) count_buffercache from pg_buffercache
) select  tb.count_buffercache 
         ,unb.count_unused_buffers
         ,ub.count_used_buffers
         ,unb.unused_buffercache_size_MB
         ,ub.used_buffercache_size_MB
         ,round(((unb.count_unused_buffers::float / tb.count_buffercache::float) * 100)::numeric,2) as unused_buffers_pct 
         ,round(((ub.count_used_buffers::float / tb.count_buffercache::float) * 100)::numeric,2) as used_buffers_pct
   from total_buffercache tb 
       ,used_buffers ub 
       ,unused_buffers unb  ;
\x off
