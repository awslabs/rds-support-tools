

col autoextensible format a14 head 'AUTO_EXTEND_ON'
select t.tablespace_name, autoextensible, ttlmegs, freemegs, trunc(freemegs*100/ttlmegs) pct_free
from
(
select
  tablespace_name,
  autoextensible ,
  trunc(sum(bytes)/(1024*1024)) ttlmegs
from sys.dba_data_files
group by tablespace_name, autoextensible
) t,
(
select
  tablespace_name ,
  trunc(sum(bytes)/(1024*1024)) freemegs
from sys.dba_free_space
group by tablespace_name
) f
where t.tablespace_name=f.tablespace_name
order by t.tablespace_name ;




