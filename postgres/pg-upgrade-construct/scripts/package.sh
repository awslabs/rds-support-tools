#!/bin/bash
set -eou pipefail

echo "Packaging..."

if [ "$#" -ne 2 ]; then
    echo "Usage: package.sh schemaFolder buildFolder"
    exit 1
fi

if [ ! -d $1 ] 
then
    echo "Schema folder $1 does not exist" 
    exit 1
fi

if [ ! -d $2 ] 
then
    echo "Build folder $2 does not exist" 
    exit 1
fi

# Copy upgrade.sh
cp scripts/upgrade.sh $2/

# Copy schema folder
cp -r $1 $2/ 

# npm install in lambda/
cd lambda
npm i

# Webpack in lambda/
npx webpack

# Copy lambda/dist
cd ..
cp lambda/dist/* $2

# Zip everything
if test -f $2/upgrade.zip; then
    rm $2/upgrade.zip
fi
cd $2
zip -r upgrade.zip *



