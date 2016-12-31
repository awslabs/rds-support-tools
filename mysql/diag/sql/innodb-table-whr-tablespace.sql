/*
Reference
https://dev.mysql.com/doc/refman/5.6/en/innodb-multiple-tablespaces.html
*/

select
    TABLE_ID,
    NAME,
    case SPACE
        when 0 then 'system'
        else 'file per table'
    end as TABLESPACE
from 
    INNODB_SYS_TABLES
;
