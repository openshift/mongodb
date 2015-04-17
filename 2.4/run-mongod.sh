#!/bin/bash

# For SCL enablement
source /var/lib/mongodb/common.sh
source /var/lib/mongodb/.bashrc

set -eu

# Data directory where MongoDB database files live. The data subdirectory is here
# because .bashrc and mongodb.conf both live in /var/lib/mongodb/ and we don't want a
# volume to override it.
export MONGODB_DATADIR=/var/lib/mongodb/data

# Configuration settings.
export MONGODB_NOPREALLOC=${MONGODB_NOPREALLOC:-true}
export MONGODB_SMALLFILES=${MONGODB_SMALLFILES:-true}
export MONGODB_QUIET=${MONGODB_QUIET:-true}


export MONGODB_KEYFILE_SOURCE_PATH="/var/run/secrets/mongo/keyfile"
export MONGODB_KEYFILE_PATH="/var/lib/mongodb/keyfile"

function usage() {
  echo "You must specify following environment variables:"
  echo "  MONGODB_USER"
  echo "  MONGODB_PASSWORD"
  echo "Optional variables:"
  echo "  MONGODB_DATABASE (default: \$MONGODB_USER)"
  echo "  MONGODB_ADMIN_PASSWORD"
  echo "  MONGODB_REPLICA_NAME"
  echo "MongoDB settings:"
  echo "  MONGODB_NOPREALLOC (default: true)"
  echo "  MONGODB_SMALLFILES (default: true)"
  echo "  MONGODB_QUIET (default: false)"
  exit 1
}

# Make sure env variables don't propagate to mongod process.
function unset_env_vars() {
  unset MONGODB_USER MONGODB_PASSWORD MONGODB_DATABASE MONGODB_ADMIN_PASSWORD
}

function cleanup() {
  if [ ! -z "${MONGODB_REPLICA_NAME-}" ]; then
    mongo_remove
  fi
  echo "=> Shutting down MongoDB server ..."
  if [ -f "${MONGODB_PID_FILE}" ]; then
    kill -2 $(cat ${MONGODB_PID_FILE})
  else
    pkill -2 mongod
  fi
  wait_for_mongo_down
  exit 0
}

if [ "$1" == "initiate" ]; then
  if ! [[ -v MONGODB_USER && -v MONGODB_PASSWORD ]]; then
    usage
  fi
  setup_keyfile
  exec /var/lib/mongodb/initiate_replica.sh
fi

# Generate config file for MongoDB
envsubst < ${MONGODB_CONFIG_PATH}.template > $MONGODB_CONFIG_PATH

if [ "$1" = "mongod" ]; then
  # Need to cache the container address for the cleanup
  cache_container_addr
  mongo_common_args="-f $MONGODB_CONFIG_PATH --oplogSize 64"
  if [ -z "${MONGODB_REPLICA_NAME-}" ]; then
    if ! [[ -v MONGODB_USER && -v MONGODB_PASSWORD ]]; then
      usage
    fi
    export MONGODB_DATABASE=${MONGODB_DATABASE:-"${MONGODB_USER}"}
    # Run the MongoDB in 'standalone' mode
    if [ ! -f /var/lib/mongodb/data/.mongodb_users_created ]; then
      # Create MongoDB users and restart MongoDB with authentication enabled
      # At this time the MongoDB does not accept the incoming connections.
      mongod $mongo_common_args & #--bind_ip 127.0.0.1 --quiet >/dev/null &
      wait_for_mongo_up
      mongo_create_users
      # Restart the MongoDB daemon to bind on all interfaces
      mongod $mongo_common_args --shutdown
      wait_for_mongo_down
    fi
    unset_env_vars
    exec mongod $mongo_common_args --auth
  else
    setup_keyfile
    # Run the MongoDB in 'clustered' mode with --replSet
    if [ ! -v MONGODB_NO_SUPERVISOR ]; then
      run_mongod_supervisor
      trap 'cleanup' SIGINT SIGTERM
    fi
    unset_env_vars
    mongod $mongo_common_args --replSet ${MONGODB_REPLICA_NAME} \
      --keyFile ${MONGODB_KEYFILE_PATH} --auth & mongo_pid=$!
    wait $mongo_pid
  fi
else
  exec $@
fi
