#!/bin/zsh
set -euo pipefail
if [[ $# != 1 || ! -x "$1/adb" || ! -f "$1/NOTICE.txt" || ! -f "$1/source.properties" ]]; then
  print -u2 'Usage: Scripts/bundle-adb.sh /path/to/official/platform-tools'
  exit 1
fi
project_root="${0:A:h:h}"
mkdir -p "$project_root/Vendor/platform-tools"
/usr/bin/ditto "$1" "$project_root/Vendor/platform-tools"
print 'Official Platform Tools copied. Xcode will include the executable, notices, and accompanying files.'
