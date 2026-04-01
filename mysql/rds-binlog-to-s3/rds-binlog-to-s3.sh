#!/bin/bash
#
#  Copyright 2016 Amazon.com, Inc. or its affiliates.
#  All Rights Reserved.
#
#  Licensed under the Apache License, Version 2.0 (the "License").
#  You may not use this file except in compliance with the License.
#  A copy of the License is located at
#
#      http://aws.amazon.com/apache2.0/
#
#  or in the "license" file accompanying this file.
#  This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
#  CONDITIONS OF ANY KIND, either express or implied. See the License
#  for the specific language governing permissions and limitations
#  under the License.
#
#Script to download RDS MySQL binlog files using mysqlbinlog command and the AWS CLI tools to upload them to S3.
#Install AWS CLI tools see: "http://docs.aws.amazon.com/cli/latest/userguide/installing.html"
#Config your AWS config File (aws configure)
AWS_PATH=/opt/aws
Backup_dir=/home/ec2-user/backup/binlog/$(date "+%Y-%m-%d")
Bucket='rds-binlogs'
RDS='mysql57.xxxxxxxxxx.us-west-2.rds.amazonaws.com'
master='admin'
export MYSQL_PWD='test1234'

# Converting to array — the last binary log may still be actively written
# to by the master, so we exclude it to avoid downloading incomplete data.
# See: https://github.com/awslabs/rds-support-tools/issues/84
mysql_binlog_filename=($(mysql -u $master -h $RDS -e "show master logs"|grep "mysql-bin"|awk '{print $1}'))

for file in ${mysql_binlog_filename[@]::${#mysql_binlog_filename[@]}-1}
do
        if ! test -d $Backup_dir
        then
                mkdir $Backup_dir
        fi
        #remote read binlog
        `mysqlbinlog -u $master -h $RDS --read-from-remote-server $file --result-file=$Backup_dir/$file`
done

# Upload to S3 bucket
aws s3 sync $Backup_dir s3://$Bucket/binlog

# Clean binlog on disk 1 day ago
`find /home/ec2-user/backup/binlog -mtime +1 -name "mysql-bin-changelog.*" -exec rm -rf {} \;`
