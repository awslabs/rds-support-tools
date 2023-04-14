#!/bin/bash
echo "Installing pg-upgrade"
npm i pg-upgrade
echo "Upgrading..."
npx pg-upgrade init -f schema -v
npx pg-upgrade run -f schema -v

