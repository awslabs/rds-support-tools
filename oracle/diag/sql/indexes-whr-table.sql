set head on 
set lines 200 
set pages 80 
set feed on 
set wrap off 
clear breaks
col degree form 999 head DEG 
col uniqueness form a10 
col ixtype form a10
col locality form a5 
col constraint_type form a10 head 'CONSTR_TYP' 
alter session set nls_date_format = 'dd-mon-rrrr'; 
ttitle on

ttitle left 'All Indexes on a Table' skip left -
'=============================================================='

break on index_owner on index_name on status on visibility on ixtype on locality on degree on compression on clustering_factor on last_analyzed on uniqueness 
select 	i.owner index_owner, 
	i.index_name,
	i.status, 				-- index will become invalid if ddl is run on table
	i.visibility, 				-- if index is visible to the optimizer
	substr(i.index_type,1,10) ixtype, 	-- if it is a normal b*tree or else function, bitmap, etc.
	l.locality, 				-- if a partitioned table whether index is local or global 
	to_number(degree) degree,		-- parallel degree should always be 1 or 0
	compression, 			
	clustering_factor, 			-- most important optimizer metric. The smaller the more optimizer will like it.
	i.last_analyzed, 		
	i.uniqueness , 				-- whether index is unique or not.  This is different from unique constraint. 
	ic.column_name 
FROM sys.dba_ind_columns ic, dba_indexes i, dba_part_indexes l
where i.table_owner=upper('&table_owner')
and i.table_name = upper('&table_name')
and i.owner=ic.index_owner
and i.index_name=ic.index_name
and i.owner=l.owner (+) 
and i.index_name=l.index_name (+) 
ORDER BY i.table_name,i.index_name, last_analyzed, ic.column_position
;                   

clear breaks 
undef table_owner
undef table_name 
ttitle off 

