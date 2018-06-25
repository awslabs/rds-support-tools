#!/bin/sh

#/
 #  Copyright 2016 Amazon.com, Inc. or its affiliates. 
 #  All Rights Reserved.
 #
 #  Licensed under the Apache License, Version 2.0 (the "License"). 
 #  You may not use this file except in compliance with the License. 
 #  A copy of the License is located at
 # 
 #      http://aws.amazon.com/apache2.0/
 # 
 # or in the "license" file accompanying this file. 
 # This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
 # either express or implied. See the License for the specific language governing permissions 
 # and limitations under the License.
#/


##################
#
# SETTINGS
# 1. PLEASE SET VARIABLES BELOW
# 2. .pgpass is set accordingly and properly as per https://www.postgresql.org/docs/current/static/libpq-pgpass.htmly
# 3. this script is better set as a cron job in a recurring fashion for collecting stats. The frequency is up to the user
# 4. storage consumption will be observed on the executing host in the $HOME folder
# 5. some scripts are commented out because of their extended output. You can enable them as required


# EXECUTION
# bash> <path_to_script>/./postgresql-diagnostics.sh <endpoint> <user> <database>
# 
# to add it to cron run:
# bash> crontab -e
# Syntax of crontab to add at the end of the file
# 1 2 3 4 5 /path/to/command arg1 arg2 arg3
# where: 
# 1 2 3 4 5 command_to_be_executed
# - - - - -
# | | | | |
# | | | | ----- Day of week (0 - 7) (Sunday=0 or 7)
# | | | ------- Month (1 - 12)
# | | --------- Day of month (1 - 31)
# | ----------- Hour (0 - 23)
# ------------- Minute (0 - 59)
# command to be executed <path_to_script>/./postgresql-diagnostics.sh <endpoint> <user> <database>
# eg: * * * * * /home/user1/postgres_stats/./postgresql-diagnostics.sh db-psql-1.c18pllkhniya.eu-west-1.rds.amazonaws.com root test_vacuum (add this in your last line of cron file to run the script every minute of every hour of every day)

#
#
#
# It's advised to call this script as unprivileged user from cron. Please set proper permissions for STAT_DIR to allow that user to write files in that directory
#################

# This script is intended to be a proof of concept and is provided as is without any support.
# 

### INITIALIZATION OF VARIABLES
RDSHOST=''
RDSUSER=''
RDSDB=''


### SETTING VARIABLES FROM CLI
RDSHOST=$1 # to pass host's endpoint during call - for schedule
RDSUSER=$2 # to pass host's role during call - for schedule
RDSDB=$3 # to pass host's database during call - for schedule
STAT_DIR="${HOME}/postgres_stats/" # set export directory
mkdir -p ${STAT_DIR} # create export directory if it does not exist
DATE=`date -u '+%Y-%m-%d-%H%M%S'` # set export file



##################
# SCRIPT
#################
if [ $? -eq 0 ]; then

	echo "==============TIMESTAMP OF EXECUTION==============" >> ${STAT_DIR}/${DATE}.output
	date >> ${STAT_DIR}/${DATE}.output
	echo "==================================================" >> ${STAT_DIR}/${DATE}.output
	echo "==================================================" >> ${STAT_DIR}/${DATE}.output
	echo "==================================================" >> ${STAT_DIR}/${DATE}.output

	echo "================ACTIVE SESSION USE================" >> ${STAT_DIR}/${DATE}.output
	psql -h ${RDSHOST} -U ${RDSUSER} ${RDSDB} -c 'SELECT * FROM PG_STAT_ACTIVITY;' >> ${STAT_DIR}/${DATE}.output

#	echo "================LOCKS=============================" >> ${STAT_DIR}/${DATE}.output
#	psql -h ${RDSHOST} -U ${RDSUSER} ${RDSDB} -c 'SELECT blocked_locks.pid AS blocked_pid, blocked_activity.usename  AS blocked_user, blocking_locks.pid     AS blocking_pid, blocking_activity.usename AS blocking_user, blocked_activity.query AS blocked_statement, blocking_activity.query AS blocking_statement FROM  pg_catalog.pg_locks         blocked_locks JOIN pg_catalog.pg_stat_activity blocked_activity  ON blocked_activity.pid = blocked_locks.pid JOIN pg_catalog.pg_locks         blocking_locks ON blocking_locks.locktype = blocked_locks.locktype AND blocking_locks.DATABASE IS NOT DISTINCT FROM blocked_locks.DATABASE AND blocking_locks.relation IS NOT DISTINCT FROM blocked_locks.relation AND blocking_locks.page IS NOT DISTINCT FROM blocked_locks.page AND blocking_locks.tuple IS NOT DISTINCT FROM blocked_locks.tuple AND blocking_locks.virtualxid IS NOT DISTINCT FROM blocked_locks.virtualxid AND blocking_locks.transactionid IS NOT DISTINCT FROM blocked_locks.transactionid AND blocking_locks.classid IS NOT DISTINCT FROM blocked_locks.classid AND blocking_locks.objid IS NOT DISTINCT FROM blocked_locks.objid AND blocking_locks.objsubid IS NOT DISTINCT FROM blocked_locks.objsubid AND blocking_locks.pid != blocked_locks.pid JOIN pg_catalog.pg_stat_activity blocking_activity ON blocking_activity.pid = blocking_locks.pid WHERE NOT blocked_locks.GRANTED;' >> ${STAT_DIR}/${DATE}.output

	echo "================LOCKS - 2 ====================" >> ${STAT_DIR}/${DATE}.output
	psql -h ${RDSHOST} -U ${RDSUSER} ${RDSDB} -c 'SELECT * FROM pg_locks;' >> ${STAT_DIR}/${DATE}.output

	echo "================DATABASES INFO====================" >> ${STAT_DIR}/${DATE}.output
	psql -h ${RDSHOST} -U ${RDSUSER} ${RDSDB} -c 'SELECT * FROM pg_stat_database;' >> ${STAT_DIR}/${DATE}.output

#	echo "================INDEXES===========================" >> ${STAT_DIR}/${DATE}.output
#	psql -h ${RDSHOST} -U ${RDSUSER} ${RDSDB} -c 'SELECT * FROM pg_stat_all_indexes;' >> ${STAT_DIR}/${DATE}.output

	echo "================USER'S INDEX STATISTICS===========" >> ${STAT_DIR}/${DATE}.output
	psql -h ${RDSHOST} -U ${RDSUSER} ${RDSDB} -c 'SELECT * FROM pg_stat_user_indexes;' >> ${STAT_DIR}/${DATE}.output

#	ATTN: This might perform a vacuum on system databases so its commented out since this is a diagnostic scripts. It is added here for convenience
#	echo "================ANALYSE VACUUM NEED===============" >> ${STAT_DIR}/${DATE}.output
#	psql -h ${RDSHOST} -U ${RDSUSER} ${RDSDB} -c 'VACUUM VERBOSE ANALYSE;' >> ${STAT_DIR}/${DATE}.output

	echo "================ALL PARAMETERS====================" >> ${STAT_DIR}/${DATE}.output
	psql -h ${RDSHOST} -U ${RDSUSER} ${RDSDB} -c 'SELECT name,setting FROM pg_settings;' >> ${STAT_DIR}/${DATE}.output

#	ATTN: might not be needed - generates too much noise
#	echo "================ALL TABLE STATISTICS====================" >> ${STAT_DIR}/${DATE}.output
#	psql -h ${RDSHOST} -U ${RDSUSER} ${RDSDB} -c 'SELECT * FROM pg_stat_all_tables;' >> ${STAT_DIR}/${DATE}.output

	echo "================USER'S TABLE STATISTICS===========" >> ${STAT_DIR}/${DATE}.output
	psql -h ${RDSHOST} -U ${RDSUSER} ${RDSDB} -c 'SELECT * FROM pg_stat_user_tables;' >> ${STAT_DIR}/${DATE}.output


else
	echo "DIRECTORY CREATING ERROR"
fi

