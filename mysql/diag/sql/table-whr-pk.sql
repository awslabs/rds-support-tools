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

/* Tables having PK defined */
SELECT '' AS 
' 
* Tables having PK defined 
**************************************************************
'\G
SELECT 
    t2.TABLE_SCHEMA,
    t2.TABLE_NAME,
    t2.ENGINE
FROM    
    information_schema.TABLES t2,
    (
    SELECT 
        t.TABLE_SCHEMA,
        t.TABLE_NAME
    FROM
        information_schema.COLUMNS c,
        information_schema.TABLES t
    WHERE t.TABLE_SCHEMA not in ('mysql','sys')
    AND c.TABLE_NAME=t.TABLE_NAME
    AND c.TABLE_SCHEMA=t.TABLE_SCHEMA
    AND c.COLUMN_KEY='PRI'
    GROUP BY
        t.TABLE_SCHEMA,
        t.TABLE_NAME
    ) pkt
WHERE t2.TABLE_SCHEMA not in ('mysql','sys','INFORMATION_SCHEMA','PERFORMANCE_SCHEMA')
AND (t2.TABLE_SCHEMA=pkt.TABLE_SCHEMA AND t2.TABLE_NAME=pkt.TABLE_NAME)
;

