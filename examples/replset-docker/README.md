# MongoDB Replication Example Using a Docker

This [MongoDB replication](https://docs.mongodb.com/manual/replication/) example
uses a [Docker engine](http://docker.com) to run replica set members.

**This platform is mainly for developing and testing.**

## Getting Started

You will need an Docker engine where you can run containers. If you want to avoid running all replset members on one host, you can also use [Docker Swarm](https://docs.docker.com/swarm/).

## Example Working Scenarios

This section describes how this example is designed to work.

**All practices for [MongoDB replication](https://docs.mongodb.com/manual/replication/) applies also to this example**

### Initial Deployment: 3-member Replica Set

To create replica set with three members you can use this script:

```bash
cat > variables <<EOF
MONGODB_DATABASE=db
MONGODB_USER=user
MONGODB_PASSWORD=password
MONGODB_ADMIN_PASSWORD=adminPassword
MONGODB_REPLICA_NAME=rs0
MONGODB_KEYFILE_VALUE=xxxxxxxxxxxx
MONGODB_SMALLFILES=true
MONGODB_SERVICE_NAME=mongodb"
EOF
source variables

IMAGE_NAME=centos/mongodb-32-centos7

network_name="mongodb-replset"
docker network create ${network_name}

docker run -d --cidfile $CIDFILE_DIR/replset0 --name=replset-0 --hostname=replset-0 --network ${network_name} --network-alias mongodb --env-file=variables $IMAGE_NAME run-mongod-replication
docker exec replset-0 bash -c "while ! [ -f /tmp/initialized ]; do sleep 1; done"
docker run -d --cidfile $CIDFILE_DIR/replset1 --name=replset-1 --hostname=replset-1 --network ${network_name} --network-alias mongodb --env-file=variables $IMAGE_NAME run-mongod-replication
docker exec replset-1 bash -c "while ! [ -f /tmp/initialized ]; do sleep 1; done"
docker run -d --cidfile $CIDFILE_DIR/replset2 --name=replset-2 --hostname=replset-2 --network ${network_name} --network-alias mongodb --env-file=variables $IMAGE_NAME run-mongod-replication
docker exec replset-2 bash -c "while ! [ -f /tmp/initialized ]; do sleep 1; done"
```

`run-mongod-replication` command have to be run in container (same script as for [OpenShift StatefulSet replication example](https://github.com/sclorg/mongodb-container/tree/master/examples/statefulset).

Parameters for `docker run` command:
- `--name` and `--hostname` have to be set to the same value for each container to proper inter-container addressing
- same `--network-alias` has to be added to all containers to be able to automatically connect containers together (alias has to be equal to `$MONGODB_SERVICE_NAME`). This allows dynamic adding of members to replicaset.
- all environmental variables required for replication have to be set - see help of the image (**TODO** write it somewhere - [deprecated](https://github.com/sclorg/mongodb-container/tree/master/2.4/examples/replica))

To be able to select a container, which initialize the ReplicaSet, `HOSTNAME` of one container has to match this regular expression: `.*-0`. If this container does not use persistent storage (mounted directory into container) it can't be restarted.

And later from one of the containers you can easilly connect to MongoDB:

```console
sh-4.2$ mongo $MONGODB_DATABASE -u $MONGODB_USER -p$MONGODB_PASSWORD --host $MONGODB_REPLICA_NAME/localhost
MongoDB shell version: 3.2.6
connecting to: sampledb
rs0:PRIMARY>
```

Note: You can also use host version of mongo shell, but you have to substitute values of environmental variables and IP address instead of `localhost` by yourself.

During the lifetime of your deployment, one or more of those members might crash or fail. It is possible to configure container to get restarted automatically (see [docker run reference](https://docs.docker.com/engine/reference/run/#restart-policies---restart).

**Note**: for production usage, you should maintain as much separation between
members as possible. It is recommended to run containers on different hosts.

### Adding member

To add a new member into replicaset run:

```bash
docker run -d --cidfile $CIDFILE_DIR/replset3 --name=replset-3 --hostname=replset-3 --network ${network_name} --network-alias mongodb --env-file=variables $IMAGE_NAME run-mongod-replication
docker exec replset-3 bash -c "while ! [ -f /tmp/initialized ]; do sleep 1; done"
```

New container is created and it automatically connects to the replica set.

### Removing member

To prevent possible data lost, automatic removing of members from replicaset is not supported.

To do it:

1. stop the container (for example `docker stop replset-2`)
2. connect to replica set and [remove the member](https://docs.mongodb.com/manual/tutorial/remove-replica-set-member/)

### Known Limitations

* Adding or removing new member to replica set takes some time (elections, syncing,...), so after your command finished it may take some time until replica set is ready
