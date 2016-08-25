
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


ttitle left 'Summary History of SQL_IDs and Wait Events With Blocking Sessions' skip left -
ttitle left '=================================================================' 
clear breaks
set lines 110
undef blocking_session_id
col wait_event format a30

select * from (
	select 	sql_id, 
   		substr(event,1,30) wait_event, 
		blocking_session blocking_session_id, 
		count(*) 
	from v$active_session_history 
	where blocking_session is not null
	and sample_time > sysdate-1/24 
	group by sql_id, 
		substr(event,1,30), 
		blocking_session 
	order by count(*) desc 
) where rownum <= 50; 

ttitle left 'Detail History on a Specific Blocking Session ID' skip left -
ttitle left '================================================================='
set lines 125
col username format a30 
col client_machine form a30
col module form a30  
col client_program form a40 

select * from (
	select  session_id,
  		substr(module,1,30) module,
  		substr(machine,1,30) client_machine, 
		substr(program,1,40) client_program, 
  		nvl(sql_id,0) sql_id, 
  		event wait_event, 
  		nvl(blocking_session,0) blocking_session_id, 
		count(*) 
	from v$active_session_history 
	where session_id = &blocking_session_id
	and sample_time > sysdate-1/24 
	group by 
		session_id,
        	substr(module,1,30),
        	substr(machine,1,30),
        	substr(program,1,40),
        	nvl(sql_id,0),
        	event ,
        	nvl(blocking_session,0)
		order by count(*) desc 
) where rownum <=50 ; 

ttitle off 
