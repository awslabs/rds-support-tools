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
 *
 *
 * Blocking script - finds blockers; uncomment det/sys.dm_exec_sql_text lines to find text of statements
 * Notes: 
 * sys.dm_exec_sessions is used because a non-executing head blocker will not show in dm_exec_requests.
 * sys.dm_os_waiting_tasks is used because it has the most descriptive wait resource. 
 * This does not find head blockers per se - you must visually examine blocking session id. However, 
 * output is sorted by blocking session id, and 0 means it's unblocked. 
 */
SELECT des.session_id, des.database_id, DB_NAME(des.database_id)AS DB_Name, ISNULL(dot.task_state,'awaiting command') AS Status, 
ISNULL(owt.wait_duration_ms,0) AS WaitTime_ms, ISNULL(owt.wait_type, 'not waiting') AS WaitType, 
ISNULL(owt.resource_description, 'n/a') AS Wait_Resource,
der.command AS Command, ISNULL(der.blocking_session_id, 0) AS BlockingSpid
--,ISNULL(det.text,'<no command - use DBCC INPUTBUFFER>') AS StatementText
FROM sys.dm_exec_sessions des 
LEFT OUTER JOIN sys.dm_os_waiting_tasks owt ON des.session_id = owt.session_id
LEFT OUTER JOIN sys.dm_exec_requests der ON des.session_id = der.session_id
LEFT OUTER JOIN sys.dm_os_tasks dot ON dot.session_id = des.session_id
--OUTER APPLY sys.dm_exec_sql_text(der.sql_handle) det 
WHERE 
des.session_id IN (SELECT d1.session_id FROM sys.dm_exec_requests d1 WHERE d1.blocking_session_id > 0) OR 
des.session_id IN (SELECT d2.blocking_session_id FROM sys.dm_exec_requests d2) 
ORDER BY der.blocking_session_id ASC, des.session_id ASC

