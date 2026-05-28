#!/bin/sh
echo "Config saver starting on :8888"
exec httpd -f -p 8888 -h /app
