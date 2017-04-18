#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

# Data directory where MongoDB database files live. The data subdirectory is here
# because mongodb.conf lives in /var/lib/mongodb/ and we don't want a volume to
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

  local mongo_cmd="mongo admin --host ${2:-localhost} "

  local i
  for i in $(seq $MAX_ATTEMPTS); do
    echo "=> ${2:-} Waiting for MongoDB daemon ${message}"
    if ([[ ${operation} -eq 1 ]] && ${mongo_cmd} --eval "quit()" &>/dev/null) || ([[ ${operation} -eq 0 ]] && ! ${mongo_cmd} --eval "quit()" &>/dev/null); then
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
# NOTE: This won't work with standalone Docker container.
function endpoints() {
  service_name=${MONGODB_SERVICE_NAME:-mongodb}
  dig ${service_name} A +search +short 2>/dev/null
}

# replset_addr return the address of the current replSet
function replset_addr() {
  local current_endpoints
  current_endpoints="$(endpoints)"
  if [ -z "${current_endpoints}" ]; then
    info "Cannot get address of replica set: no nodes are listed in service!"
    info "CAUSE: DNS lookup for '${MONGODB_SERVICE_NAME:-mongodb}' returned no results."
    return 1
  fi
  echo "${MONGODB_REPLICA_NAME}/${current_endpoints//[[:space:]]/,}"
}

# mongo_create_admin creates the MongoDB admin user with password: MONGODB_ADMIN_PASSWORD
# $1 - login parameters for mongo (optional)
# $2 - host where to connect (localhost by default)
function mongo_create_admin() {
  if [[ -z "${MONGODB_ADMIN_PASSWORD:-}" ]]; then
    echo >&2 "=> MONGODB_ADMIN_PASSWORD is not set. Authentication can not be set up."
    exit 1
  fi

  # Set admin password
  local js_command="db.createUser({user: 'admin', pwd: '${MONGODB_ADMIN_PASSWORD}', roles: ['dbAdminAnyDatabase', 'userAdminAnyDatabase' , 'readWriteAnyDatabase','clusterAdmin' ]});"
  if ! mongo admin ${1:-} --host ${2:-"localhost"} --eval "${js_command}"; then
    echo >&2 "=> Failed to create MongoDB admin user."
    exit 1
  fi
}

# mongo_create_user creates the MongoDB database user: MONGODB_USER,
# with password: MONGDOB_PASSWORD, inside database: MONGODB_DATABASE
# $1 - login parameters for mongo (optional)
# $2 - host where to connect (localhost by default)
function mongo_create_user() {
  # Ensure input variables exists
  if [[ -z "${MONGODB_USER:-}" ]]; then
    echo >&2 "=> MONGODB_USER is not set. Failed to create MongoDB user"
    exit 1
  fi
  if [[ -z "${MONGODB_PASSWORD:-}" ]]; then
    echo "=> MONGODB_PASSWORD is not set. Failed to create MongoDB user: ${MONGODB_USER}"
    exit >&2 1
  fi
  if [[ -z "${MONGODB_DATABASE:-}" ]]; then
    echo >&2 "=> MONGODB_DATABASE is not set. Failed to create MongoDB user: ${MONGODB_USER}"
    exit 1
  fi

  # Create database user
  local js_command="db.getSiblingDB('${MONGODB_DATABASE}').createUser({user: '${MONGODB_USER}', pwd: '${MONGODB_PASSWORD}', roles: [ 'readWrite' ]});"
  if ! mongo admin ${1:-} --host ${2:-"localhost"} --eval "${js_command}"; then
    echo >&2 "=> Failed to create MongoDB user: ${MONGODB_USER}"
    exit 1
  fi
}

# mongo_reset_user sets the MongoDB MONGODB_USER's password to match MONGODB_PASSWORD
function mongo_reset_user() {
  if [[ -n "${MONGODB_USER:-}" && -n "${MONGODB_PASSWORD:-}" && -n "${MONGODB_DATABASE:-}" ]]; then
    local js_command="db.changeUserPassword('${MONGODB_USER}', '${MONGODB_PASSWORD}')"
    if ! mongo ${MONGODB_DATABASE} --eval "${js_command}"; then
      echo >&2 "=> Failed to reset password of MongoDB user: ${MONGODB_USER}"
      exit 1
    fi
  fi
}

# mongo_reset_admin sets the MongoDB admin password to match MONGODB_ADMIN_PASSWORD
function mongo_reset_admin() {
  if [[ -n "${MONGODB_ADMIN_PASSWORD:-}" ]]; then
    local js_command="db.changeUserPassword('admin', '${MONGODB_ADMIN_PASSWORD}')"
    if ! mongo admin --eval "${js_command}"; then
      echo >&2 "=> Failed to reset password of MongoDB user: ${MONGODB_USER}"
      exit 1
    fi
  fi
}

# usage prints info about required enviromental variables
# if $1 is passed, prints error message containing $1
# if REPLICATION variable is set, prints also info about replication variables
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

  if [[ -v REPLICATION ]]; then
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
within the container or visit https://github.com/sclorgk/mongodb-container/."

  exit 1
}

# process_files process extending files in $1 and $2 directories
# - source all *.sh files
#   (if there are files with same name source only file from $1)
function process_files() {
  local custom_dir default_dir
  custom_dir=$1
  default_dir=$2

  shopt -s nullglob
  for filename in $(echo $custom_dir/*.sh $default_dir/*.sh | xargs -r basename -a | sort | uniq); do
    # Custom file is prefered
    if [ -f $custom_dir/$filename ]; then
      source $custom_dir/$filename
    else
      source $default_dir/$filename
    fi
  done
  shopt -u nullglob
}

# info prints a message prefixed by date and time.
function info() {
  printf "=> [%s] %s\n" "$(date +'%a %b %d %T')" "$*"
}
