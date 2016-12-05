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

/* Note. 
 *      The query return an estimation of space allocated for enlisted structures only.
 *      Structures as CSV tables, binary logs and log files are not accounted.
 *      Query will show proper values only when statistics are up to date.
 */
select 
    sum(data_length)/1024/1024 as data_lenght_mb,
    sum(data_free)/1024/1024 as data_free_mb,
    sum(index_length)/1024/1024 as index_lenght_mb,
    (select (@@innodb_log_files_in_group * @@innodb_log_file_size)/1024/1024) as innodb_log_size_mb,
    (sum(data_length)+sum(data_free)+sum(index_length)+(select (@@innodb_log_files_in_group * @@innodb_log_file_size)))/1024/1024 as tot_mb
from 
    information_schema.tables
;
