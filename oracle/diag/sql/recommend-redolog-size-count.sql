
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

rem recommend-redolog-size-count.sql    Ref rds-support-tools/oracle/oracle.README

clear breaks 
ttitle off 
set lines 80
set feed off 
set head on 
col redolog_size_recommendation form a35 
col redolog_count_recommendation form a35 

select * from 
    (
    	with mpl as (select (20/greatest(count(*),1)) min_per_log from v$archived_log where first_time >=  sysdate-20/1440),
   	ls as ( select trunc(min(bytes/1024/1024)) log_size from v$log )
    	select (case when min_per_log < 5 then 'Increase Redolog Size to '  
    	|| ceil(5/greatest(min_per_log,1))*log_size || 'M.'  else 'Redolog Size Ok.' end) redolog_size_recommendation
    	from mpl, ls
    ) rsr, 
    (  
        with nal as (select count(*) num_active from v$log where status in ('ACTIVE','CURRENT')) ,
        ttl as  (select count(*) ttl_logs from v$log) 
   	select (case when trunc(num_active*100/ttl_logs) >= 50 then 'Increase Redolog Count to ' 
   	|| (ttl_logs+num_active) || '.'  else 'Redolog Count Ok.' end) redolog_count_recommendation
   	from nal, ttl 
    ) rcr 
; 

