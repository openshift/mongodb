#!/bin/bash

set -o errexit
set -o nounset
set -o pipefail

source "${CONTAINER_SCRIPTS_PATH}/common.sh"

# This is a full hostname that will be added to replica set
# (for example, "replica-2.mongodb.myproject.svc.cluster.local")
readonly MEMBER_HOST="$(hostname -f)"

# Start the replica set configuration.
function start_replicaset()
{
  if [ $(count_endpoints) -gt 1 ]; then
    info "Found more than one endpoint. add node to existing replica set"
    add_member "${MEMBER_HOST}"
  else
    # Initialize only if Memberid=0
    if [ "${MEMBER_ID}" = '0' ]; then
        info "Replica set not existing. initiate replica set"
        initiate "${MEMBER_HOST}"
    fi
  fi
}

# Initializes the replica set configuration.
#
# Arguments:
# - $1: host address[:port]
#
# Uses the following global variables:
# - MONGODB_REPLICA_NAME
# - MONGODB_ADMIN_PASSWORD
function initiate() {
  local host="$1"

  local config="{_id: '${MONGODB_REPLICA_NAME}', members: [{_id: 0, host: '${host}'}]}"

  info "Initiating MongoDB replica using: ${config}"
  mongo_cmd --host localhost --quiet <<<"quit(rs.initiate(${config}).ok ? 0 : 1)"

  info "Waiting for PRIMARY status ..."
  mongo_cmd --host localhost --quiet <<<"while (!rs.isMaster().ismaster) { sleep(100); }"

  info "Successfully initialized replica set"
}

# Adds a host to the replica set configuration.
#
# Arguments:
# - $1: host address[:port]
#
# Global variables:
# - MONGODB_REPLICA_NAME
# - MONGODB_ADMIN_PASSWORD
function add_member() {
  local host="$1"
  info "Adding ${host} to replica set ..."

  if ! mongo_cmd "$(replset_addr admin)" -u admin -p"${MONGODB_ADMIN_PASSWORD}" --quiet <<<"while (!rs.add('${host}').ok) { sleep(100); }"; then
    info "ERROR: couldn't add host to replica set!"
    return 1
  fi

  info "Waiting for PRIMARY/SECONDARY status ..."
  mongo_cmd --host localhost --quiet <<<"while (!rs.isMaster().ismaster && !rs.isMaster().secondary) { sleep(100); }"

  info "Successfully joined replica set"
}


info "Waiting for local MongoDB to accept connections  ..."
wait_for_mongo_up &>/dev/null

if [[ $(mongo_cmd --host localhost --quiet <<<'db.isMaster().setName') == "${MONGODB_REPLICA_NAME}" ]]; then
  info "Replica set '${MONGODB_REPLICA_NAME}' already exists, skipping initialization"
  >/tmp/initialized
  exit 0
fi

start_replicaset