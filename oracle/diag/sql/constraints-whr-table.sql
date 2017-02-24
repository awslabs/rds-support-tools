
set head on
set lines 250 
set pages 80
set feed on
set wrap off
clear breaks
col constraint_name form a30 
col constr_type form a10
col table_name form a30 
col fk_owner form a30
col fk_table_name form a30 
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
order by constraint_name, constraint_type, index_owner, index_name, col.position; 



ttitle left 'All Foreign Key Constraints on a Table' skip left -
'=============================================================='

break on table_name on fk_constraint_name on pk_constraint_name on pk_table_owner on pk_table_name
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
order by fk.table_name, fk.constraint_name, pk.owner, pk.table_name, fkcol.position 
;



ttitle left 'Indexed Foreign Key Constraints on a Table' skip left -
'=============================================================='

 break on fk_owner on fk_table_name on fk_constraint_name on fk_index_owner on fk_index_name
with indexes_on_col_pos_1 as
        (
        select distinct
        c.owner fk_owner,
        c.table_name fk_table_name,
        c.constraint_name fk_constraint_name,
        ic.index_owner as fk_index_owner,
        ic.index_name as fk_index_name
        from dba_constraints c, dba_cons_columns cc, dba_ind_columns ic
        where c.owner =upper('&&table_owner')
        and c.table_name=upper('&&table_name')
        and c.constraint_type='R'
        and c.owner=cc.owner
        and c.table_name=cc.table_name
        and c.constraint_name=cc.constraint_name
        and cc.owner=ic.table_owner
        and cc.table_name=ic.table_name
        and cc.column_name=ic.column_name
        and cc.position=ic.column_position
        and cc.position=1
        )
select  iocp1.fk_owner,
        iocp1.fk_table_name,
        iocp1.fk_constraint_name,
        iocp1.fk_index_owner,
        iocp1.fk_index_name,
        ic2.column_name fk_indexed_column_name,	 -- secondary index column only shows if it is also part of the constraint 
        cc2.column_name fk_column_name,
	cc2.position fk_col_position 
from indexes_on_col_pos_1 iocp1,dba_cons_columns cc2,dba_ind_columns ic2
where cc2.owner=iocp1.fk_owner
        and cc2.table_name=iocp1.fk_table_name
        and cc2.constraint_name=iocp1.fk_constraint_name
        and cc2.owner =ic2.table_owner
        and cc2.table_name=ic2.table_name
        and ic2.index_owner=iocp1.fk_index_owner
        and ic2.index_name=iocp1.fk_index_name
        and cc2.column_name = ic2.column_name (+)
        and cc2.position = ic2.column_position (+)
order by fk_owner, fk_table_name , fk_constraint_name , fk_index_owner , fk_index_name, cc2.position
;




ttitle left 'Check Constraints on a Table' skip left -
'=============================================================='
break on table_name

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

