#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Data directory where MongoDB database files live. The data subdirectory is here
# because mongod.conf lives in /var/lib/mongodb/ and we don't want a volume to
# override it.
export MONGODB_DATADIR=/var/lib/mongodb/data
export CONTAINER_PORT=27017
# Configuration settings.
export MONGODB_QUIET=${MONGODB_QUIET:-true}

MONGODB_CONFIG_PATH=/etc/mongod.conf
MONGODB_KEYFILE_PATH="${HOME}/keyfile"

# Constants used for waiting
readonly MAX_ATTEMPTS=60
readonly SLEEP_TIME=1

# function to use by extension scripts instead of mongo shell binary
# - to be able to change shell params in all scripts
# for example to use SSL certificate
function mongo_cmd() {
  mongo ${shell_args:-} $@;
}

# wait_for_mongo_up waits until the mongo server accepts incomming connections
function wait_for_mongo_up() {
  _wait_for_mongo 1 "$@"
}

# wait_for_mongo_down waits until the mongo server is down
function wait_for_mongo_down() {
  _wait_for_mongo 0 "$@"
}

# wait_for_mongo waits until the mongo server is up/down
# $1 - 0 or 1 - to specify for what to wait (0 - down, 1 - up)
# $2 - host where to connect (localhost by default)
function _wait_for_mongo() {
  local operation=${1:-1}
  local message="up"
  if [[ ${operation} -eq 0 ]]; then
    message="down"
  fi

  local i
  for i in $(seq $MAX_ATTEMPTS); do
    echo "=> ${2:-} Waiting for MongoDB daemon ${message}"
    if ([[ ${operation} -eq 1 ]] && mongo_cmd ${2:-localhost} <<<"quit()") || ([[ ${operation} -eq 0 ]] && ! mongo_cmd ${2:-localhost} <<<"quit()"); then
      echo "=> MongoDB daemon is ${message}"
      return 0
    fi
    sleep ${SLEEP_TIME}
  done
  echo "=> Giving up: MongoDB daemon is not ${message}!"
  return 1
}

# endpoints returns list of IP addresses with other instances of MongoDB
# To get list of endpoints, you need to have headless Service named 'mongodb'.
# NOTE: This won't work with standalone container.
function endpoints() {
  service_name=${MONGODB_SERVICE_NAME:-mongodb}
  dig ${service_name} A +search +short 2>/dev/null
}

function count_endpoints() {
  service_name=${MONGODB_SERVICE_NAME:-mongodb}
  dig ${service_name} A +search +short 2>/dev/null | wc -w
}

# replset_addr return the address of the current replSet
function replset_addr() {
  local current_endpoints db
  db="${1:-}"
  current_endpoints="$(endpoints)"
  if [ -z "${current_endpoints}" ]; then
    info "Cannot get address of replica set: no nodes are listed in service!"
    info "CAUSE: DNS lookup for '${MONGODB_SERVICE_NAME:-mongodb}' returned no results."
    return 1
  fi
  echo "mongodb://${current_endpoints//[[:space:]]/,}/${db}?replicaSet=${MONGODB_REPLICA_NAME}"
}

# usage prints info about required enviromental variables
# if $1 is passed, prints error message containing $1
# if MEMBER_ID variable is set, prints also info about replication variables
function usage() {
  if [ $# == 1 ]; then
    echo >&2 "error: $1"
  fi

  echo "
You must specify the following environment variables:
  MONGODB_ADMIN_PASSWORD
Optionally you can provide settings for a user with 'readWrite' role:
(Note you MUST specify all three of these settings)
  MONGODB_USER
  MONGODB_PASSWORD
  MONGODB_DATABASE
Optional settings:
  MONGODB_QUIET (default: true)"

  if [[ -v MEMBER_ID ]]; then
    echo "
For replication you must also specify the following environment variables:
  MONGODB_KEYFILE_VALUE
  MONGODB_REPLICA_NAME
Optional settings:
  MONGODB_SERVICE_NAME (default: mongodb)
"
  fi
  echo "
For more information see /usr/share/container-scripts/mongodb/README.md
within the container or visit https://github.com/sclorg/mongodb-container/."

  exit 1
}

# log_info MESSAGE
# ---------------------------------------
# System log information message.
function log_info() {
  printf "\xE2\x9E\xA1 [%s INFO] %s\n" "$(date +'%a %b %d %T')" "${1:-}"
}

# log_fail MESSAGE
# ---------------------------------------
# System log failure message.
function log_fail() {
  printf "\xe2\x9c\x98 [%s FAIL] %s\n" "$(date +'%a %b %d %T')" "${1:-}"
}

# log_pass MESSAGE
# ---------------------------------------
# System log success message.
function log_pass() {
  printf "\xE2\x9C\x94 [%s PASS] %s\n" "$(date +'%a %b %d %T')" "${1:-}"
}

# get_matched_files PATTERN DIR [DIR ...]
# ---------------------------------------
# Print all basenames for files matching PATTERN in DIRs.
get_matched_files ()
{
  local pattern=$1 dir
  shift
  for dir; do
    test -d "$dir" || continue
    find "$dir" -maxdepth 1 -type f -name "$pattern" -printf "%f\n"
  done
}

# process_extending_files DIR [DIR ...]
# -------------------------------------
# Source all *.sh files in DIRs in alphabetical order, but if the file exists in
# more then one DIR, source only the first occurrence (first found wins).
process_extending_files()
{
  local filename dir
  while read filename ; do
    for dir in "$@"; do
      local file="$dir/$filename"
      if test -f "$file"; then
        echo "=> sourcing $file ..."
        source "$file"
        break
      fi
    done
done <<<"$(get_matched_files '*.sh' "$@" | sort -u)"
}

# info prints a message prefixed by date and time.
function info() {
  printf "=> [%s] %s\n" "$(date +'%a %b %d %T')" "$*"
}
