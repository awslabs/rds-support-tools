select  count (*) count_buffercache 
      ,(count (*) * 8)/1024 as total_buffercache_size_MB 
      ,(count (*) * 8)/1024/1024 as total_buffercache_size_GB 
  from pg_buffercache;
