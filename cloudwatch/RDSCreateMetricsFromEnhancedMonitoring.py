# coding=utf-8
from __future__ import print_function
from builtins import input
from builtins import str
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
# or in the "license" file accompanying this file. 
# This file is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, 
# either express or implied. See the License for the specific language governing permissions 
# and limitations under the License.
#

#!/usr/bin/python
import boto3        
import json
import argparse
import sys





# Function to create the filter on the log which creates the metric
def create_filter_and_metric(metric_name, filter_group_name, instance_name):
    print(' - metric: ' + metric_name)
    client = (boto3.client('logs', region_name=region) if region else boto3.client('logs'))
    client.put_metric_filter(
        logGroupName=filter_group_name,
        filterName=instance_name + '_' + metric_name,
        filterPattern=return_filter_pattern(),
        metricTransformations=[
            {
                'metricName': rds_instance_name + '_' + metric_name[2:],
                'metricNamespace': metric_namespace,
                'metricValue': metric_name
            },
        ]
    )


# This function gets the log group name from the RDS instance-
def get_log_group_name(instance_name):
    client = (boto3.client('rds', region_name=region) if region else boto3.client('rds'))
    rds_instances = client.describe_db_instances()
    for rds_instance in rds_instances['DBInstances']:
        if rds_instance['DBInstanceIdentifier'] == instance_name:
            log_group = rds_instance['EnhancedMonitoringResourceArn']
            return log_group.split(':')[6]


# This function returns a filter pattern based on the RDS instance id
def return_filter_pattern():
    return '{($.instanceID=\"' + rds_instance_name + '\")}'


# This function returns a line of the log to retrieve the fields
def return_event_log_example():
    client = (boto3.client('rds', region_name=region) if region else boto3.client('rds'))
    rds_instance = client.describe_db_instances()
    client = (boto3.client('logs', region_name=region) if region else boto3.client('logs'))
    event_log_example = client.get_log_events(
        logGroupName=get_log_group_name(rds_instance_name),
        logStreamName=rds_instance['DBInstances'][0]['DbiResourceId'],
        limit=1,
        startFromHead=True
    )
    return event_log_example


# ensures that the instance exists.
def does_this_rds_instance_exists(instance_name):
    client = (boto3.client('rds', region_name=region) if region else boto3.client('rds'))
    rds_instances = client.describe_db_instances()
    for rds_instance in rds_instances['DBInstances']:
        if rds_instance['DBInstanceIdentifier'] == instance_name:
            return True
    return False


# Read a sample of the event log and selects which metrics are going to be populated with data
# (some of them are string values and we don't populate them)
def populate_metrics():
    if not metrics_to_filter:
        json_data = json.loads(return_event_log_example()['events'][0]['message'])
        for item in json_data:
            if item not in ['engine', 'instanceID', 'instanceResourceID', 'timestamp', 'version', 'uptime', 'numVCPUs',
                            'processList']:
                if isinstance(json_data[item], dict):
                    subitem_list = json_data[item]
                else:
                    subitem_list = json_data[item][0]
                for subitem in subitem_list:
                    if not isinstance(subitem_list[subitem], str):
                        create_filter_and_metric('$.' + item + '.' + subitem, get_log_group_name(rds_instance_name),
                                                 rds_instance_name)
    else:
        for metric_to_filter in metrics_to_filter:
            create_filter_and_metric('$.' + metric_to_filter, get_log_group_name(rds_instance_name), rds_instance_name)


# Main
try:
    input = raw_input
except NameError:
    pass

print('WARNING: This script will create additional resources in your AWS account such as custom metrics, which may result in additional charges. Do you wish to continue? Y/N')
warning_choice = input('Do you understand and accept the above warning? yes/no: ').lower()
if warning_choice != 'yes':
    print('To accept, you must type \"yes\". Please run the script again if you wish to proceed.')
    sys.exit()

print
parser = argparse.ArgumentParser(
    description='Create metrics filters based on the Enhanced Monitoring of RDS instances.')
parser.add_argument('-i', '--rds_instance', help='RDS instance name (DBInstanceIdentifier)', required=True)
parser.add_argument('-n', '--namespace', help='Namespace where the metric will be stored', required=True)
parser.add_argument('-r', '--region', help='Region where the metric will be created and the RDS instance is placed.',
                    required=False)
parser.add_argument('-m', '--metrics_to_filter',
                    help='Metric glossary: http://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_Monitoring.html'
                         '#d0e90666',
                    nargs='*', required=False)

args = parser.parse_args()

rds_instance_name = args.rds_instance
metric_namespace = args.namespace
region = args.region
metrics_to_filter = args.metrics_to_filter

if does_this_rds_instance_exists(rds_instance_name):
    print
    print('Creating metrics')
    print(' for RDS instance: ' + rds_instance_name)
    print(' in this namespace: ' + metric_namespace)
    try:
        client = (boto3.client('rds', region_name=region) if region else boto3.client('rds'))
        rds_instances = client.describe_db_instances()
        for rds_instance in rds_instances['DBInstances']:
            if rds_instance_name == rds_instance['DBInstanceIdentifier']:
                log_group = rds_instance['EnhancedMonitoringResourceArn']
    except Exception as e:
        print('Error: ' + str(e))
        print('The instance you selected doesn''t have Enhanced Monitoring activated.')
        sys.exit(1)
    populate_metrics()
    print
    print('All metrics  populated under:  > _<metric_name>')
else:
    print('Error: The RDS instance you selected doesn''t exist on this region')
    sys.exit(1)
