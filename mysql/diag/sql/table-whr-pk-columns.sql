
/* Columns partecipating in PK definition per schema, per table */
SELECT '' AS  
' 
* Columns partecipating in PK definition per schema, per table
**************************************************************
'\G
SELECT 
    t.TABLE_SCHEMA,
    t.TABLE_NAME,
    t.ENGINE,
    c.COLUMN_NAME as PK
FROM
    information_schema.COLUMNS c,
    information_schema.TABLES t
WHERE t.TABLE_SCHEMA not in ('mysql','sys')
AND c.TABLE_NAME=t.TABLE_NAME
AND c.TABLE_SCHEMA=t.TABLE_SCHEMA
AND c.COLUMN_KEY='PRI'
;
