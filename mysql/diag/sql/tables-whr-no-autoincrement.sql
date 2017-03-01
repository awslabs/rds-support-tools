
select
  t.table_catalog,
  t.table_schema,
  t.table_name,
  c.column_name,
  c.data_type,
  c.column_type,
(case c.data_type
   when 'tinyint' THEN 255
   when 'smallint' THEN 65535
   when 'mediumint' THEN 16777215
   when 'int' THEN 4294967295
   when 'bigint' THEN 18446744073709551615
end >> if(LOCATE('unsigned', c.column_type) > 0, 0, 1)) as max_value
from
  information_schema.tables t inner join information_schema.columns c
    on t.table_name = c.table_name and c.table_catalog = t.table_catalog and c.table_schema = t.table_schema
where c.extra != 'auto_increment' AND
t.table_schema NOT IN  ('mysql', 'information_schema', 'performance_schema','sys') AND
c.data_type in ('tinyint', 'int', 'mediumint', 'bigint')
; 
 

