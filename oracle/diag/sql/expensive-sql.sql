
/*
 *  Copyright 2016 Amazon.com, Inc. or its affiliates. 
 *  All Rights Reserved.
 *
 *  Licensed under the Apache License, Version 2.0 (the "License"). 
 *  You may not use this file except in compliance with the License. 
 *  A copy of the License is located at
 * 
 *      http://aws.amazon.com/apache2.0/
 * 
 * or in the "license" file accompanying this file. 
 * This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
 * either express or implied. See the License for the specific language governing permissions 
 * and limitations under the License.
*/

rem expensive-sql.sql     Ref rds-support-tools/oracle/oracle.README

clear breaks
ttitle off 
set linesize 1000
set pages 80 
set feed on 
set head on 
set wrap on 
column sqltext form a1000 head "SqlText"
column executions form 999,999,999,999 head "Executions"
column BufsPerExec FORMAT 999,999,999,999 head "BufsPerExec"
column DiskRdsPerExec FORMAT 999,999,999,999 head "DiskRdsPerExec"
column RowsPerExec FORMAT 999,999,999,999 head "RowsPerExec"
column CpuPerExec format  999,999,999,999 head "CPUPerExec"
column ElapsedTimePerExec format 999,999,999,999 head "ElapsedTimePerExec"
column ParsesPerExec form 999,999,999,999 head "ParsesPerExec" 
column sql_id form a20 head "Sql_ID" 

select * from 
(
	select sql_id
	--, substr(sql_text,1,1000) SqlText 
	, executions
	, buffer_gets/executions BufsPerExec
	, parse_calls/executions ParsesPerExec
	, disk_reads/executions DiskRdsPerExec
	, rows_processed/executions RowsPerExec 
	, cpu_time/executions CpuPerExec 
	, elapsed_time/executions ElapsedTimePerExec
	from v$sqlarea 
	where executions > 0
	order by buffer_gets/executions desc 
	--order by elapsed_time/executions desc
	--order by cpu_time/executions desc
	--order by disk_reads/executions desc 
	--order by rows_processed/executions desc
	--order by parse_calls/executions desc
	--order by executions desc
)
where rownum <= 20
; 


