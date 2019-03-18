RDS allows you to view, download and watch the db log files through the RDS console. However, there is a retention period for the log files and when the retention is reached, the logs are purged. There are situations where one might want to archive the logs, so that they can access it in the future for compliance. In order to acheive that we can move the RDS logs to S3 and keep it permanently in or you can download it to your local from S3. You can use this script to incrementally move the log files to S3. 

For eg: 

When you execute the script for the first time, all the logs will be moved to a new folder in S3 with the folder name being the instance name. And a sub-folder named "backup-<timestamp>" will contain the log files. When you execute the script for the next time, then the log files since the last timestamp the script was executed will be copied to a new folder named "backup-<new timestamp>". So you will have incremental backup.

How to execute the script?

Download the script to your local or ec2. And make sure to do aws --configure and provide the access keys and secret keys. 

https://docs.aws.amazon.com/cli/latest/reference/configure/

Install python and boto3.

Once you have set the keys using aws configure and downloaded python and boto3, you can shift to the folder where you have the downloaded python file and you can execute the below:

python <python-file-name> --bucketname (<bucket-name>) --rdsinstancename (<instance-name-of-the-logs-to-be-moved>) --region (<region-name-of-the-instance>) > backup_status.$(date "+%Y.%m.%d-%H.%M.%S").log

Here's an example:

python rdslogstos3.py --bucketname name --rdsinstancename instancename --region us-east-1 > backup_status.$(date "+%Y.%m.%d-%H.%M.%S").log

backup_status.<timestamp> will have the progress of the execution. Please note that for RDS sql Server, .xel and .trc files contain binaries, they will not be moved to S3. Need you read the .trc and .xel files, please use appropriate tools to view the files. 

NOTE: PLEASE MAKE SURE TO USE A PRIVATE BUCKET. DO NOT USE A PUBLIC BUCKET.