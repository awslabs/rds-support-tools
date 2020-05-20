
# Copyright 2018 Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Permission is hereby granted, free of charge, to any person obtaining a copy of this
# software and associated documentation files (the "Software"), to deal in the Software
# without restriction, including without limitation the rights to use, copy, modify,
# merge, publish, distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
# INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
# PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
# SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

from __future__ import print_function
import boto3, botocore, sys, os
from datetime import datetime
from time import sleep

def print_usage():
	print ("Usage:\n<script_name>\n" + \
				"\t--bucketname <S3 Buket Name>\n" + \
				"\t--rdsinstancename <RDS Instance Name>\n" + \
				"\t[--lognameprefix <Log Name Prefix>]\n" + \
				"\t--region <Region>")

def parse_args(args):
	global config
	i = 1
	while i < len(args):
		arg = args[i]

		if arg == "--bucketname" and i + 1 < len(args):
			config['BucketName'] = args[i + 1]
			i += 1
		elif arg == "--rdsinstancename" and i + 1 < len(args):
			config['RDSInstanceName'] = args[i + 1]
			i += 1
		elif arg == "--lognameprefix" and i + 1 < len(args):
			config['LogNamePrefix'] = args[i + 1]
			i += 1
		elif arg == "--region" and i + 1 < len(args):
			config['Region'] = args[i + 1]
			i += 1
		else:
			print ("ERROR: Invalid command line argument " +arg + "/ No value specified")
			print_usage()
			return False
		i += 1

	return True


def copy_logs_from_RDS_to_S3():

	global config

	# get settings from the config
	if {'BucketName', 'RDSInstanceName','Region'}.issubset(config):
		S3BucketName = config['BucketName']
		RDSInstanceName = config['RDSInstanceName']
		region = config['Region']
		if "LogNamePrefix" in config:
			logNamePrefix = config['LogNamePrefix']
		else:
			logNamePrefix = ""
		configFileName = RDSInstanceName + "/" + "backup_config"
	else:
		print ("ERROR: Values for the required field not specified")
		print_usage()
		return 

	# initialize
	RDSclient = boto3.client('rds',region_name=region)
	S3client = boto3.client('s3',region_name=region)
	lastWrittenTime = 0
	lastWrittenThisRun = 0
	backupStartTime = datetime.now()
	datetime_str=backupStartTime.strftime("%Y-%m-%d-%H-%M-%S")
	activityLogFileName = datetime_str + '_activity'
	activityLogData = ''
	activityLogDelimiter = '*'*40
	# set activityLog = False if no activity log file is needed for auditing/tracking purposes
	activityLog = True

	# check if the S3 bucket exists and is accessible
	try:
		S3response = S3client.head_bucket(Bucket=S3BucketName)
	except botocore.exceptions.ClientError as e:
		error_code = int(e.response['ResponseMetadata']['HTTPStatusCode'])
		if error_code == 404:
			print ("Error: Bucket name provided not found")
			if activityLog == True:
				activityLogData += (activityLogDelimiter + '\n' + "Error: Bucket name provided not found" + '\n')
			return
		else:
			print ("Error: Unable to access bucket name, error: " + e.response['Error']['Message'])
			if activityLog == True:
				activityLogData += (activityLogDelimiter + '\n' + "Error: Unable to access bucket name, error: " + str(e.response['Error']['Message']) + '\n')
			return

    # get the config file, if the config isn't present this is the first run
	try:
		S3response = S3client.get_object(Bucket=S3BucketName, Key=configFileName)
		lastWrittenTime = int(S3response['Body'].read(S3response['ContentLength']))
		print("Found marker from last log download, retrieving log files with lastWritten time after %s" % str(lastWrittenTime))
		if activityLog == True:
			activityLogData += (activityLogDelimiter + '\n' + "Found marker from last log download, retrieving log files with lastWritten time after %s" % str(lastWrittenTime) + '\n')		
	except botocore.exceptions.ClientError as e:
		error_code = int(e.response['ResponseMetadata']['HTTPStatusCode'])
		if error_code == 404:
			print ("It appears this is the first log import, all files will be retrieved from RDS")
			if activityLog == True:
				activityLogData += (activityLogDelimiter + '\n' + "It appears this is the first log import, all files will be retrieved from RDS" + '\n')
		else:
			print ("Error: Unable to access config file, error: " + e.response['Error']['Message'])
			if activityLog == True:
				activityLogData += (activityLogDelimiter + '\n' + "Error: Unable to access config file, error: " + str(e.response['Error']['Message']) + '\n')
			return
		
	# copy the logs in batches to s3
	copiedFileCount = 0
	logMarker = ""
	moreLogsRemaining = True
	while moreLogsRemaining:
		dbLogs = RDSclient.describe_db_log_files(DBInstanceIdentifier=RDSInstanceName, FilenameContains=logNamePrefix, FileLastWritten=lastWrittenTime, Marker=logMarker)
		if 'Marker' in dbLogs and dbLogs['Marker'] != "":
			logMarker = dbLogs['Marker']
		else:
			moreLogsRemaining = False

		# copy the logs in this batch
		for dbLog in dbLogs['DescribeDBLogFiles']:
			print ("FileNumber: ", copiedFileCount + 1)
			print("Downloading log file: %s found and with LastWritten value of: %s " % (dbLog['LogFileName'],dbLog['LastWritten']))
			if activityLog == True:
				activityLogData += (activityLogDelimiter + '\n' + "FileNumber: " + str(copiedFileCount + 1) + '\n')
				activityLogData += ("Downloading log file: %s found and with LastWritten value of: %s " % (dbLog['LogFileName'],dbLog['LastWritten']) + '\n')
			if int(dbLog['LastWritten']) > lastWrittenThisRun:
				lastWrittenThisRun = int(dbLog['LastWritten'])
			
			# download the log file
			addtlDataPending = True
			partialData = False
			lastFoundMarker='0'
			logFileData = ""			
			Marker='0'
			previousMarker='0'
			#numlines (NumberOfLines) w default/marker = 0 is 10000.  Have to set this variable to reduce lines if data returned is > 1 MB
			numLines=9500
			#retryWait - geometric backoff if throttling occurs
			retryWait=0
			retryCount=1
			simpleCount=0			
			while addtlDataPending:
				try:
					logFile = RDSclient.download_db_log_file_portion(DBInstanceIdentifier=RDSInstanceName, LogFileName=dbLog['LogFileName'],Marker=lastFoundMarker,NumberOfLines=numLines)
					#++++for display during very large file downloads++++
					sys.stdout.write('-')
					if simpleCount % 50 == 0:
						print('>')
					if simpleCount % 1000 == 0:
						os.system('clear')
					simpleCount += 1
					#----for display during very large file downloads----
					#++++Handling db_log_file_portion of greater than 1 MB++++
					if numLines == 1: #numlines set as low as possible
						pass
					elif (sys.getsizeof(logFile['LogFileData']) >= 1e+6):
						numLines = int(numLines/2)
						if numLines < 1:
							numLines = 1
						if activityLog == True:
							print('')
							print("Returned logFileData is greater than 1 MB")
							print("numlines: ",numLines)
							print("retrying previous marker with one half the lines. Line(s): " + str(numLines))
							activityLogData += (activityLogDelimiter + '\n')
							activityLogData += ("Returned logFileData is greater than 1 MB" + '\n')
							activityLogData += ("numlines: "+str(numLines) + '\n')
							activityLogData += ("retrying previous marker with one half the lines. Line(s): " + str(numLines) + '\n')
						Marker=previousMarker
						continue
					#----Handling db_log_file_portion of greater than 1 MB----
					logFileData += logFile['LogFileData']
					previousMarker=Marker
					lastFoundMarker=logFile['Marker']
					addtlDataPending=logFile['AdditionalDataPending']
					sleep(retryWait)
				except Exception as e:
					print('')
					print ("File download failed: ", e)
					if activityLog == True:
						activityLogData += (activityLogDelimiter + '\n' + "File download failed: " + str(e) + '\n')
					if 'Throttling' in e.message:
						retryWait += 0.005*retryCount
						retryCount += 1
						print("Now waiting for ", retryWait, " seconds")
						if activityLog == True:
							activityLogData += (activityLogDelimiter + '\n' + "Throttling detected: Now waiting for " + str(retryWait) + " seconds" + '\n')
					#++++Edge case where DBlogFile rotates while being downloaded++++		
					if "DBLogFileNotFoundFault" in e.message:
						print("DB Log file not found - log rotation likely - please check previous download/backup")
						partialData = True #flag for appending error to file name
						addtlDataPending = False
						if activityLog == True:
							activityLogData += (activityLogDelimiter + '\n')
							activityLogData += ("DB Log file not found.  DB Log File NOT written!!!! - log rotation likely - please check previous download/backup" + '\n')
					#----Edge case where DBlogFile rotates while being downloaded----
					continue

			logFileDataCleaned = logFileData.encode(errors='ignore')
			logFileAsBytes = str(logFileDataCleaned).encode()

			# upload the log file to S3
			if partialData == True:
				# Edge case where DBlogFile rotates while being downloaded
				objectName = RDSInstanceName + "/" + "backup_" + backupStartTime.isoformat() + "/" + dbLog['LogFileName'] + "error"
			else:
				objectName = RDSInstanceName + "/" + "backup_" + backupStartTime.isoformat() + "/" + dbLog['LogFileName']
			try:
				S3response = S3client.put_object(Bucket=S3BucketName, Key=objectName,Body=logFileAsBytes)
				copiedFileCount += 1
			except botocore.exceptions.ClientError as e:
				print ("Error writting object to S3 bucket, S3 ClientError: " + e.response['Error']['Message'])
				if activityLog == True:
					activityLogData += (activityLogDelimiter + '\n'+ "Error writting object to S3 bucket, S3 ClientError: " + str(e.response['Error']['Message']) + '\n')
				return
			print("Uploaded log file %s to S3 bucket %s" % (objectName,S3BucketName))
			if activityLog == True:
				activityLogData += (activityLogDelimiter + '\n' + "Uploaded log file %s to S3 bucket %s" % (objectName,S3BucketName) + '\n')

	print ("Copied ", copiedFileCount, "file(s) to s3")
	if activityLog == True:
		activityLogData += (activityLogDelimiter + '\n' + "Copied " + str(copiedFileCount) + " file(s) to s3" + '\n')
		
	# Update the last written time in the config
	if lastWrittenThisRun > 0:
		try:
			S3response = S3client.put_object(Bucket=S3BucketName, Key=configFileName, Body=str.encode(str(lastWrittenThisRun)))			
		except botocore.exceptions.ClientError as e:
			print ("Error writting the config to S3 bucket, S3 ClientError: " + e.response['Error']['Message'])
			if activityLog == True:
				activityLogData += (activityLogDelimiter + '\n' + "Error writting the config to S3 bucket, S3 ClientError: " + str(e.response['Error']['Message']) +'\n')
			return
		print("Wrote new Last Written file to %s in Bucket %s" % (configFileName,S3BucketName))
		if activityLog == True:
			activityLogData += (activityLogDelimiter + '\n' + "Wrote new Last Written file to %s in Bucket %s" % (configFileName,S3BucketName) + '\n')
	print ("Log file export complete")
	if activityLog == True:
		activityLogData += (activityLogDelimiter + '\n' + "Log file export complete" +'\n')

	#++++write activity log to s3++++
	activityLogDataCleaned = activityLogData.encode(errors='ignore')
	activityLogAsBytes = str(activityLogDataCleaned).encode()
	objectName = RDSInstanceName + "/" + "backup_" + backupStartTime.isoformat() + "/" + activityLogFileName
	print ("running log File name is: ", activityLogFileName)
	try:
		S3response = S3client.put_object(Bucket=S3BucketName, Key=objectName,Body=activityLogAsBytes)
	except botocore.exceptions.ClientError as e:
		print ("Error writting the log file to S3 bucket, S3 ClientError: " + str(e.response['Error']['Message']))
		if activityLog == True:
			activityLogData += ("Error writting the log file to S3 bucket, S3 ClientError: " + str(e.response['Error']['Message']))
	return
	#----write activity log to s3----
	
###### START OF SCRIPT ####

config = {}

#config = {'BucketName': "<bucket-name>", 'RDSInstanceName': "<instance-name>", 'LogNamePrefix': "", 'Region': "<>region-name"}

if(parse_args(sys.argv)):
	copy_logs_from_RDS_to_S3();
