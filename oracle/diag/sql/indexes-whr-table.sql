set lines 180
set pages 80
set feed on

col table_name form a30 
col owner form a10 
col uniq form a4 
col index_name form a30
col column_name form a30 

undef table_name 
undef owner 
col ixtype form a10
break on owner on table_name on index_name on visibility on uniq on ixtype on locality 
select i.owner, i.table_name, c.index_name, i.visibility, substr(i.uniqueness,1,3) uniq, substr(i.index_type,1,10) ixtype, l.locality, c.column_name
from dba_ind_columns c, dba_indexes i, dba_part_indexes l
where i.table_owner=upper('&&owner')
and  i.table_name = upper('&table_name')
and i.owner=c.index_owner
and i.index_name=c.index_name
and i.owner=l.owner (+)
and i.index_name=l.index_name (+)
order by i.table_name,c.index_name, c.column_position
;

clear breaks 

