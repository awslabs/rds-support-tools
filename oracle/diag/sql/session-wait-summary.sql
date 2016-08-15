/*
Copyright [first edit year]-[latest edit year] Amazon.com, Inc. or its affiliates. All Rights Reserved.

    Licensed under the Apache License, Version 2.0 (the "License"). You may not use this file except in compliance with the License. A copy of the License is located at

        http://aws.amazon.com/apache2.0/

    or in the "license" file accompanying this file. This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the License for the specific language governing permissions and limitations under the License.
*/ 


COL event FORM a40
COL seq# FORM 999999
SET WRAP OFF
SET LINESIZE 110
SET PAGES 80

SELECT
  event,
  count(*)
FROM v$session_wait
GROUP BY event
ORDER BY count(*) DESC
; 

