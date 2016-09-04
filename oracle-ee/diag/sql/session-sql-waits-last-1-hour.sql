
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

rem session-sql-waits-last-1-hour.sql      Ref rds-support-tools/oracle/oracle.README 

clear breaks 
set head on 
col event form a40 
set lines 120 
set pages 80 

ttitle left 'Count of Recent Sessions by Sql ID and Wait Event' skip left -
ttitle left '================================================================='

select * from (
   select
  	sql_id,
	event, 
  	count(*)
   from v$active_session_history  
   where sample_time > sysdate-1/24
   group by sql_id, event
   order by count(*) desc 
) where rownum < 50 
; 

ttitle off

