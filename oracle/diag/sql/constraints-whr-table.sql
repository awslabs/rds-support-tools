
set head on
set lines 250 
set pages 80
set feed on
set wrap off
clear breaks
col constraint_name form a30 
col constr_type form a10
col table_name form a30 
col fk_constraint_name form a30
col pk_constraint_name form a30 
col pk_table_owner form a20 
col pk_table_name form a30 
col fk_index_owner form a20
col fk_index_name form a30
col fk_column_name form a30 
col fk_indexed_column_name form a30 
ttitle on

ttitle left 'Primary Key and Unique Constraints on a Table' skip left -
'=============================================================='

break on constraint_name on constraint_type on index_owner on index_name 
select 
	constr.table_name, 
	substr(constr.constraint_name, 1,30) constraint_name, 
	case constr.constraint_type  when 'P' then 'Primary Key' when 'U' then 'Unique' end as constr_type, 
	constr.index_owner, 
	constr.index_name, 
	col.column_name
from 	dba_constraints constr, dba_cons_columns col 
where  	constr.owner=upper('&&table_owner')  
and 	constr.table_name = upper('&&table_name')  
and	constraint_type in ('P','U') 
and 	constr.owner=col.owner
and 	constr.table_name=col.table_name
and 	constr.constraint_name=col.constraint_name 
order by constraint_name, col.position; 



ttitle left 'All Foreign Key Constraints on a Table' skip left -
'=============================================================='

select
	fk.table_name, 
        fk.constraint_name fk_constraint_name,
        pk.constraint_name pk_constraint_name,
        pk.owner pk_table_owner,
        pk.table_name pk_table_name,
        fkcol.column_name  fk_column_name
from dba_constraints fk, dba_constraints pk,  dba_cons_columns fkcol
where fk.owner=upper('&&table_owner')
and fk.table_name=upper('&&table_name')
and fk.constraint_type='R'
and fk.r_constraint_name =pk.constraint_name 
and fk.constraint_name=fkcol.constraint_name 
and fk.owner=fkcol.owner
and fk.table_name=fkcol.table_name
order by fk.constraint_name, fkcol.position 
;


ttitle left 'Indexed Foreign Key Constraints on a Table' skip left -
'=============================================================='
select
	fk.table_name ,
        fk.constraint_name fk_constraint_name,
        fkindcol.index_owner fk_index_owner,
        fkindcol.index_name fk_index_name,
        fkindcol.column_name fk_indexed_column_name,
        fkcol.column_name  fk_column_name
from dba_constraints fk, dba_cons_columns fkcol, dba_ind_columns fkindcol
where fk.owner=upper('&&table_owner')
and fk.table_name=upper('&&table_name')
and fk.constraint_type='R'
and fk.constraint_name=fkcol.constraint_name
and fk.owner=fkcol.owner
and fk.table_name=fkcol.table_name
and fkcol.owner=fkindcol.table_owner  (+)  
and fkcol.table_name=fkindcol.table_name (+) 
and fkcol.column_name= fkindcol.column_name (+) 
and fkcol.position=fkindcol.column_position (+) 
and exists 					-- index only counts if leading keys match
(       select 1 from dba_ind_columns
        where table_owner=fkcol.owner
        and table_name=fkcol.table_name
        and column_name = fkcol.column_name
        and column_position=fkcol.position
        and position=1
)
order by fk.constraint_name, fkcol.position
;
 


ttitle left 'Check Constraints on a Table' skip left -
'=============================================================='
set lines 180
set wrap off
col status format a10
select  table_name, 
	constraint_name,
        status,
        search_condition_vc
from    sys.dba_constraints
where  	owner = upper('&&table_owner')
and table_name = upper('&&table_name')
and constraint_type = 'C'
and search_condition_vc not like '%IS NOT NULL%'
;

clear breaks
undef table_owner
undef table_name
ttitle off

