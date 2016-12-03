---The following query can be used in RDS Oracle 12c engine versions to list all patches installed
set pages 1000 lines 20000

with a as (select SYS.dbms_qopatch.get_opatch_lsinventory patch_output from dual)
select x.patch_id, x.patch_uid, x.description
from a,
xmltable('InventoryInstance/patches/*'
    passing a.patch_output
    columns
    patch_id number path 'patchID',
    patch_uid number path 'uniquePatchID',
    description varchar2(80) path 'patchDescription') x;
