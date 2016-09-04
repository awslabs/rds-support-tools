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
#
# oracle-sql-driver.sh    Ref rds-support-tools/oracle/oracle.README


export SQLPATH=

if [[ ${3:-0} = 0 ]] ;  then
   clear 
   echo
   echo
   echo
   echo
   echo
   echo "Usage: oracle-sql-driver.sh <tns_list_file> <oracle_username> <sql_script>"
   echo
   echo Example:
   echo oracle-sql-driver.sh tns-connect-list.sample master_user hello-world.sql 
   echo
   exit 1
fi

typeset -i ndelete
typeset -i ninsert
typeset -i nupdate
typeset -i nwrite 
typeset -i nmerge 
typeset -i nalter
typeset -i ntruncate
typeset -i ndrop 


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


ndelete=`grep -i delete $sql_script | wc -l`
ninsert=`grep -i insert $sql_script | wc -l`
nupdate=`grep -i update $sql_script | wc -l`
nwrite=`grep -i write $sql_script | wc -l`
nmerge=`grep -i merge $sql_script | wc -l`
nalter=`grep -i alter $sql_script | grep -iv 'alter session' | wc -l`
ntruncate=`grep -i truncate $sql_script | wc -l`
ndrop=`grep -i drop $sql_script | wc -l`

echo 
echo 
if [[ $ndelete -ne 0 || $ninsert -ne 0 || $nupdate -ne 0 || $nwrite -ne 0 || $nmerge -ne 0 || $nalter -ne 0 || $ntruncate -ne 0 || $ndrop -ne 0 ]] ; then 
	echo 'Found one of (DELETE, INSERT, UPDATE, WRITE, MERGE, ALTER, TRUNCATE, DROP) in' $sql_script
	echo Aborting 
	exit 1 
fi

 


for constr in `cat ${tns_connect_list} | grep -v '#'` ; do 
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



