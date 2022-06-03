-- the relations buffered in database share buffer, ordered by relation percentage taken in shared buffer. It also shows that how much of the whole relation is buffered.

select 
        c.relname,pg_size_pretty(count(*) * 8192) as buffered
       ,round(100.0 * count(*) / 
                                  ( select setting from pg_settings where name='shared_buffers')::integer,1) as buffer_percent 
       ,round(100.0*count(*)*8192 / pg_table_size(c.oid),1) as percent_of_relation 
  from pg_class c 
 inner join pg_buffercache b on b.relfilenode = c.relfilenode 
 inner join pg_database d on ( b.reldatabase =d.oid and d.datname =current_database()) 
 group by 
         c.oid
        ,c.relname 
 order by 3 desc 
  limit 10;  
