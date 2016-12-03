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

set pages 1000 lines 20000

with a as (select SYS.dbms_qopatch.get_opatch_lsinventory patch_output from dual)
select x.patch_id, x.patch_uid, x.description
from a,
xmltable('InventoryInstance/patches/*'
    passing a.patch_output
    columns
    patch_id number path 'patchID',
    patch_uid number path 'uniquePatchID',
    description varchar2(80) path 'patchDescription') x;
