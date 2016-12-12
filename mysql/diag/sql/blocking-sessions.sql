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

/* InnoDB Print All Deadlock setting information*/
SELECT '' AS 
' 
* Check innodb_print_all_deadlocks setting 
* Enable this option to print information about all InnoDB user transaction deadlocks in the error log.
* Otherwise information about only the last deadlock is available in SHOW ENGINE INNODB STATUS.
'\G
SELECT IF(@@GLOBAL.innodb_print_all_deadlocks=0,'Parameter innodb_print_all_deadlocks is disabled.','Parameter innodb_print_all_deadlocks is enabled.') AS 'INNODB_PRINT_ALL_DEADLOCKS_STATUS';

/* InnoDB Transaction and Loking Information*/
SELECT '' AS '
* InnoDB Transaction and Locking Information
'\G

SELECT
  r.trx_id waiting_trx_id,
  r.trx_mysql_thread_id waiting_thread,
  r.trx_query waiting_query,
  b.trx_id blocking_trx_id,
  b.trx_mysql_thread_id blocking_thread,
  b.trx_query blocking_query
FROM       information_schema.innodb_lock_waits w
INNER JOIN information_schema.innodb_trx b
  ON b.trx_id = w.blocking_trx_id
INNER JOIN information_schema.innodb_trx r
  ON r.trx_id = w.requesting_trx_id;

SHOW ENGINE INNODB STATUS\G


/* InnoDB Transaction and Loking Information*/
SELECT '' AS '
* Show Process list
'\G
SHOW PROCESSLIST;


