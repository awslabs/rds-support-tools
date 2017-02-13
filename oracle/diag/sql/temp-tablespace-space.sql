
select f.tablespace_name temp_tablespace_name, ttlmegs, freemegs, trunc(freemegs*100/ttlmegs) pct_free
from
(
select tablespace_name, sum(bytes_free)/(1024*1024) freemegs
from v$temp_space_header
group by tablespace_name
) f,
(
select tablespace_name, sum(bytes)/(1024*1024) ttlmegs
from v$temp_space_header , v$tempfile
where file_id=file#
group by tablespace_name
) s
where f.tablespace_name=s.tablespace_name;

