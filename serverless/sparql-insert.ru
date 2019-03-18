
# Neptune-SPARQL Load script

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


# load

curl -X POST -H "Accept: text/csv" --data-urlencode "update=
        INSERT DATA
        {
           GRAPH  <amzn://serverless_test>
           {
                <amzn://data/result1> <amzn://data/hello1> <amzn://data/world1> .
                <amzn://data/result2> <amzn://data/hello2> <amzn://data/world2> .
           }
        }
" http://$ENDPOINT:$PORT/sparql

# verify

curl -X POST -H "Accept: text/csv" --data-urlencode "query=
        SELECT ?hello ?world
        WHERE { GRAPH  <amzn://serverless_test>  {?s ?hello ?world } }
        LIMIT 2
" http://$ENDPOINT:$PORT/sparql

