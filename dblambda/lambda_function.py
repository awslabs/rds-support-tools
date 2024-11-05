# DB probe lambda, rough as ...
# call needs event json containing { "DB_SECRET_ARN": "arn:....", "DB_HOST": "rds.host", "DB_NAME": "db" }

import json
import os
import logging
import boto3
import pymysql

from botocore.exceptions import ClientError

logger = logging.getLogger()

def lambda_handler(event, context):
    secret_name=event["DB_SECRET_ARN"]
    host_name=event["DB_HOST"]
    db_name=event["DB_NAME"]

    try:
        #Extract secret from DB_SECRET_ARN
        session = boto3.session.Session()
        client = session.client(
            service_name = 'secretsmanager'
        )
        secret_value_response = client.get_secret_value(
            SecretId = secret_name
        )        

    except ClientError as e:
        # For a list of exceptions thrown, see
        # https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_GetSecretValue.html
        logger.error(f"Boto3Client Error: {e}")
        raise e

    if 'SecretString' in secret_value_response:
        secret_dict = json.loads(secret_value_response['SecretString'])
        username = secret_dict.get("username")
        password = secret_dict.get("password")
        print (f" connect to db {db_name} on {host_name} as {username}")
    
    try:
        # Connect to MySQL database
        connection = pymysql.connect(
            host = host_name,
            database = db_name,
            user = username,
            password = password,
            connect_timeout = 2
        )

    except Exception as e:
        logger.error(f"DB Connect Error: {e}")
        raise e
    
    try:
        with connection:
            print("DB Connect okay ")    
            with connection.cursor() as cursor:
                cursor.execute("SELECT VERSION()")
                db_info = cursor.fetchone()
                print(f"DB Version: {db_info}")
                cursor.execute("SELECT * FROM performance_schema.processlist WHERE HOST != 'localhost' and DB is not NULL ") 
                processes = cursor.fetchall()
                print(f"Processes: {processes}")
                cursor.execute("SELECT * FROM performance_schema.global_status WHERE VARIABLE_NAME regexp 'Aborted|bytes|error|que|perf|slow|uptime|threads|temp|table'")
                status = cursor.fetchall()
                print(f"Status: {status}")
                cursor.execute("SHOW ENGINES")
                engines = cursor.fetchall()
                print(f"Engines: {engines}")
                cursor.execute("SHOW SLAVE STATUS")
                slave_status = cursor.fetchall()
                print(f"Slave Status: {slave_status}")
                cursor.execute("SHOW MASTER STATUS")
                master_status = cursor.fetchall()
                print(f"Master Status: {master_status}")
                cursor.execute("SHOW GRANTS")
                grants = cursor.fetchall()
                print(f"Grants: {grants}")
                cursor.execute("SHOW PRIVILEGES")
                privileges = cursor.fetchall()
                print(f"Privileges: {privileges}")
                cursor.execute("SELECT * FROM performance_schema.global_status WHERE VARIABLE_NAME regexp 'Aborted|bytes|error|que|perf|slow|uptime|threads|temp|table'")
                functions = cursor.fetchall()
                print(f"Functions: {functions}")
                cursor.execute("SELECT * from performance_schema.hosts")
                hosts = cursor.fetchall()
                print(f"Hosts: {hosts}")
                cursor.execute("SELECT * from performance_schema.users")
                users = cursor.fetchall()
                print(f"Users: {users}")
                cursor.execute("Select schema_name as 'Database' from information_schema.SCHEMATA where schema_name not in ('mysql','information_schema','performance_schema','sys')")
                databases = cursor.fetchall()
                db_list = [db[0] for db in databases]
                print(f"DB List: {db_list}")
                for db in db_list:
                    print(f"DB: {db}")
                    cursor.execute(f"SELECT * from information_schema.tables where table_schema = '{db}'")
                    tables = cursor.fetchall()
                    table_list = [table[2] for table in tables]
                    print(f"Table Info: {tables}")    
            cursor.close()
    
    except Exception as e:
        logger.error(f"DB Error:  {e}")

    return {
        'statusCode': 200,
        'body': json.dumps("That's all Folks!")
    }

