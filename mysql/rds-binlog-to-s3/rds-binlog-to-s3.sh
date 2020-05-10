#!/bin/bash
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

mysql_binlog_filename=$(mysql -u $master -h $RDS -e "show master logs"|grep "mysql-bin"|awk '{print $1}')

for file in $mysql_binlog_filename
do
        if ! test -d $Backup_dir
        then
                mkdir $Backup_dir
        fi
        #remote read binlog
        `mysqlbinlog -u $master -h $RDS --read-from-remote-server $file --result-file=$Backup_dir/$file`
done

# Upload to S3 bucket:
aws s3 sync $Backup_dir s3://$Bucket/binlog

# Clean binlog on disk 1 day ago
`find /home/ec2-user/backup/binlog -mtime +1 -name "mysql-bin-changelog.*" -exec rm -rf {} \;`
