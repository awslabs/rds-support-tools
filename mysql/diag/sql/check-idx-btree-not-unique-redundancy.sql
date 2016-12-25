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

/* Tables having PK not defined */
SELECT 
' 
**************************************************************
* Find single column B-Tree NOT UNIQUE indexes that are 
* defined as prefix of another composed index too.
**************************************************************
*
* Note.
*
* 1. Sigle B-Tree and NOT UNIQUE indexes are compared wich each
*    composed index per table.
* 2. Cases where the prefix index is unique are not considered
*    as the uniqueness of the prefix index in this case enforce
*    a constraint not enforced by the longer index.
**************************************************************
' AS ''\G
SELECT
    CONCAT('The B-Tree NOT UNIQUE index ', IDX_PREFIX, ' is prefix of the composed index ', IDX_COMPOSED) AS Message,
    CONCAT(TABLE_SCHEMA, '.', TABLE_NAME) AS FULL_TABLE_NAME,
    IDX_PREFIX,
    C_IDX_PREFIX,
    IDX_COMPOSED,
    C_IDX_COMPOSED
FROM
    (
    SELECT
        TABLE_SCHEMA,
        TABLE_NAME,
        INDEX_NAME AS 'IDX_PREFIX',
        GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS C_IDX_PREFIX
    FROM
        information_schema.STATISTICS
    WHERE TABLE_SCHEMA NOT IN ('mysql', 'sys', 'INFORMATION_SCHEMA', 'PERFORMANCE_SCHEMA')
    AND INDEX_TYPE='BTREE'
    AND NON_UNIQUE=1
    GROUP BY
        TABLE_SCHEMA,
        TABLE_NAME,
        INDEX_NAME
    ) AS idx1
    INNER JOIN
    (
    SELECT
        TABLE_SCHEMA,
        TABLE_NAME,
        INDEX_NAME AS 'IDX_COMPOSED',
        GROUP_CONCAT(COLUMN_NAME ORDER BY SEQ_IN_INDEX) AS C_IDX_COMPOSED
    FROM
        information_schema.STATISTICS
    WHERE INDEX_TYPE='BTREE' 
    GROUP BY
        TABLE_SCHEMA,
        TABLE_NAME,
        INDEX_NAME
    ) AS idx2
    USING (TABLE_SCHEMA, TABLE_NAME)
    WHERE idx1.C_IDX_PREFIX != idx2.C_IDX_COMPOSED AND LOCATE(CONCAT(idx1.C_IDX_PREFIX, ','), idx2.C_IDX_COMPOSED) = 1
;    
