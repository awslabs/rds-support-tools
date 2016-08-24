#!/bin/bash 

# Copyright 2016 Amazon.com, Inc. or its affiliates.
# All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License").
# You may not use this file except in compliance with the License.
# A copy of the License is located at
#
#    http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file.
# This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
# either express or implied. See the License for the specific language governing permissions
# and limitations under the License.



export SQLPATH=

if [[ ${3:-0} = 0 ]] ;  then
   clear 
   echo
   echo
   echo
   echo
   echo
   echo Usage: oracle-sql-driver.sh tns_list_file oracle_user sql_script 
   echo
   echo Example:
   echo oracle-sql-driver.sh tns-connect-list.sample master_user hello-world.sql 
   echo
   exit 1
fi


tns_connect_list=$1 
oracle_name=$2 
sql_script=$3 

echo 
echo Tns connect list file is $tns_connect_list
echo Oracle username is  $oracle_name  
echo Sql script name is $sql_script
echo 

echo Enter $oracle_name password:***************
stty -echo 2>/dev/null
read -s oracle_pwd
stty echo 2>/dev/null


for constr in `cat ${tns_connect_list} | grep -v '#'` ; do 
	echo >> /tmp/all-dbout
	echo $constr: 
	dbout=`sqlplus -S /nolog  << EOF
        	connect ${oracle_name}/${oracle_pwd}@${constr}
        	set feed off
        	set verify off
        	set head off
		@${sql_script}
        	exit;
EOF`
	echo $dbout
done 



