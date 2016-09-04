
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

rem  session-whr-sid.sql Ref rds-support-tools/oracle/oracle.README

undef sid
ttitle left 'Detail on a Specific Session ID (SID)' skip left -
ttitle left '===========================================================' 
col username format a30
col client_program format a30
col client_machine form a30 
col client_pid 9999999999
col obj_waiting_on form 999999
set lines 150 

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
where sid = &sid
;
ttitle off 
undef sid 
