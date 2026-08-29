#!/bin/bash
set -eou pipefail

# This script creates a local package that you can use for testing from another
# CDK application.  After running this script, go to your application folder
# and npm link dist/js/package
#
# For example
# $ cd ~/my-test-app
# $ npm link ../pg-upgrade-construct/dist/js/package
#
# This will overwrite node_modules/pg-upgrade-construct installed from npm.
# Keep in mind that an npm install will remove the local link

npm run build
npm run package
cd dist/js
rm -rf package
tar xzvf pg-upgrade-construct@0.1.0.jsii.tgz

