
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

rem sessions-whr-sql_id.sql Ref rds-support-tools/oracle/oracle.README 

set wrap on
set pages 80 
set linesize 200
set head on
ttitle off
clear breaks 
undef wait_event
column username form a30 
column server form a10
column module form a30
column client_machine form a50
column program form a30 
column wait_event form a30 
column client_pid form 99999999
select * from 
(
	select sid 
  	, serial#
  	, substr(username,1,30) username
  	, decode(server,'NONE','SHARED',server) server 
  	, substr(module,1,30) module
  	, substr(machine,1,50) client_machine
  	, process client_pid
  	, substr(program,1,30) program 
	, sql_id
	, substr(event, 1,30) wait_event 
  	, p1
  	, p2
  	, logon_time
	from v$session 
	where sql_id='&sql_id'
	order by seconds_in_wait desc 
) where rownum < 50   
;

