
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

rem session-sql-waits-now.sql Ref rds-support-tools/oracle/oracle.README 

clear breaks 
set head on 
COL event FORM a40 HEAD "WAIT_EVENT"
COL seq# FORM 999999
SET WRAP OFF
SET LINESIZE 110
SET PAGES 80

ttitle left 'Count of Current Sessions by Sql ID and Wait Event' skip left -
ttitle left '================================================================='

select * from (
   SELECT
  	sql_id,
	event, 
  	count(*)
   FROM v$session
   GROUP BY sql_id, event
   ORDER BY count(*) DESC
) where rownum < 50 
; 
ttitle off

