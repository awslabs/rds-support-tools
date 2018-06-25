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

/* Run as: psql -f list-tables-with-dead-tuples.sql */


select                         
       sat.relname
      ,sat.n_dead_tup
      ,sat.n_live_tup  
      ,to_char(sat.last_autovacuum, 'YYYY-MM-DD HH24:MI:SS') last_autovacuum
      ,sat.autovacuum_count
      ,to_char(sat.last_vacuum, 'YYYY-MM-DD HH24:MI:SS') last_vacuum
      ,sat.vacuum_count
      ,sat.seq_scan
      ,sat.idx_scan
  from pg_stat_all_tables sat
 where sat.n_dead_tup != 0
order by sat.n_dead_tup desc;
