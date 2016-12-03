---The following query can be used in RDS Oracle 12c engine versions to list all patches installed with verbose output

set long 200000 pages 0 lines 200
select xmltransform(SYS.DBMS_QOPATCH.GET_OPATCH_LSINVENTORY, SYS.DBMS_QOPATCH.GET_OPATCH_XSLT) from dual;

