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

/* Run as: psql -f list-sessions.sql */



select  sa.datid
       ,sa.datname
       ,sa.pid
       ,sa.usesysid
       ,sa.usename
       ,substring(sa.query from 1 for 50) current_query
       ,sa.state
       ,sa.wait_event_type
       ,sa.wait_event
       ,age(clock_timestamp(),sa.xact_start) age_xact_start
       ,age(clock_timestamp(),sa.query_start) age_query_start
       ,age(clock_timestamp(),sa.backend_start) age_backend_start
       ,sa.client_addr
       ,sa.client_port
  from  pg_stat_activity sa
 order by  sa.backend_start DESC
          ,sa.xact_start DESC
,sa.query_start DESC ;
