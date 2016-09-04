

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

rem  longops-whr-sid.sql Ref rds-support-tools/oracle/oracle.README

undef sid

set head on
set lines 150 
column opname format a30 
column target format a30 
column hrs_remain format 999.99 
column hrs_elapsed format 999.99 
set wrap off 

select * from (
   	select sql_id
	, opname 
   	, substr(target,1,30) target
   	, start_time
   	, elapsed_seconds/(60*60) hrs_elapsed
   	, time_remaining/(60*60) hrs_remain
	from v$session_longops
	where sid=&sid
	order by start_time desc
) where rownum < 50 
;


