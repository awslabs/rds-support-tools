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

SELECT
    trx_id,
    trx_state,
    trx_wait_started,
    trx_requested_lock_id,
    time_to_sec(timediff(now(),trx_started)) AS cq,
    lock_type,
    lock_table,
    lock_index,
    lock_data 
FROM
    information_schema.innodb_trx LEFT JOIN information_schema.innodb_locks ON trx_requested_lock_id=lock_id
;
