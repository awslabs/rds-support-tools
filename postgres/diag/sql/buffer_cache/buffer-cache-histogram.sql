-- buffer cache histogram
--select usagecount as usagecount , count (*) from  pg_buffercache   group by  usagecount  order by 2 desc ;

select
          CURRENT_TIMESTAMP
        , count(*) buffer_count
        , count(a.usagecount) filter (where a.usagecount is not null) used_buffer_count
        , count(*) filter (where a.usagecount is null )   unused_buffer_count
        , count(a.usagecount) filter (where a.usagecount=5) usage_count_5
        , count(a.usagecount) filter (where a.usagecount=4) usage_count_4
        , count(a.usagecount) filter (where a.usagecount=3) usage_count_3
        , count(a.usagecount) filter (where a.usagecount=2) usage_count_2
        , count(a.usagecount) filter (where a.usagecount=1) usage_count_1
        , count(a.usagecount) filter (where a.usagecount=0) usage_count_0
        , count(*) filter (where a.usagecount is null ) usage_count_unused
  from
        pg_buffercache a ;
