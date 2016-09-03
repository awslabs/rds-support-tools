
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

ttitle left 'Summary of SQL_IDs and Wait Events With Blocking Sessions' skip left -
ttitle left '==========================================================='
clear breaks
set lines 120
undef blocking_session_id
col wait_event format a30

select * from (
	select 	sql_id, 
   		substr(event,1,30) wait_event, 
		blocking_session blocking_session_id, 
		count(*) 
	from v$session 
	where blocking_session is not null
	group by sql_id, 
		substr(event,1,30), 
		blocking_session 
	order by count(*) desc 
     ) 
where rownum <=50 ;

ttitle off 
ttitle left 'Detail on a Specific Blocking Session ID' skip left -
ttitle left '===========================================================' 
col username format a10
col client_program format a30
col client_machine form a30 
col obj_waiting_on form 999999

select  sid,
        serial#,
        username,
  	process client_pid,
  	substr(machine,1,30) client_machine,
	substr(program,1,30) client_program, 
  	nvl(sql_id,0) sql_id, 
  	event wait_event, 
  	decode(row_wait_obj#,-1,0) obj_waiting_on,
  	nvl(blocking_session,0) blocking_session
from v$session 
where sid = &blocking_session_id
;

ttitle off 
