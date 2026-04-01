-- per object 
-- SELECT c.relname,b.usagecount ,count(*) AS buffers
--           FROM pg_buffercache b INNER JOIN pg_class c
--           ON b.relfilenode = pg_relation_filenode(c.oid) AND
--              b.reldatabase IN (0, (SELECT oid FROM pg_database
--                                    WHERE datname = current_database()))
--           GROUP BY c.relname,b.usagecount
--           ORDER BY 3 DESC ;

select 
         count(a.usagecount) buffer_count
       , count(a.usagecount) filter (where a.usagecount=5) usage_count_5
       , count(a.usagecount) filter (where a.usagecount=4) usage_count_4
       , count(a.usagecount) filter (where a.usagecount=3) usage_count_3
       , count(a.usagecount) filter (where a.usagecount=2) usage_count_2
       , count(a.usagecount) filter (where a.usagecount=1) usage_count_1
       , count(a.usagecount) filter (where a.usagecount=0) usage_count_0
       , sum(a.pinning_backends) total_pinning_backends
       , a.reldatabase
       , a.relfilenode
       , b.relname
  from
       pg_buffercache a,
       pg_class b
 where a.relfilenode = b.relfilenode
 group by 
           a.reldatabase
         , a.relfilenode
         , b.relname
order by
         8 desc 
        ,1 desc
limit 50;
