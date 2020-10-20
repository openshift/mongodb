# MongoDB Replication Example Using a StatefulSet (ex-PetSet)

This [MongoDB replication](https://docs.mongodb.com/manual/replication/) example
uses a [StatefulSet](https://kubernetes.io/docs/concepts/abstractions/controllers/statefulsets/)
to manage replica set members.

It is supported by an example [OpenShift
template](https://docs.okd.io/latest/dev_guide/templates.html) and
scripts that automate replica set initiation, baked in the
[centos/mongodb-32-centos7](https://hub.docker.com/r/centos/mongodb-32-centos7/)
image (and its RHEL variant) built from this source repository.

## Getting Started

You will need an OpenShift cluster where you can deploy a template. If you don't
have an existing OpenShift installation yet, the easiest way to get started and
try out this example is using the
[`oc cluster up`](https://github.com/openshift/origin/blob/master/docs/cluster_up_down.md)
command.

This tutorial assumes you have the `oc` tool, are logged in and have 3
pre-created persistent volumes (or configured [persistent volume
provisioning](https://docs.okd.io/latest/install_config/persistent_storage/dynamically_provisioning_pvs.html)).

In the context of a project where you want to create a MongoDB cluster, run
`oc new-app` passing the template file as an argument:

```bash
oc new-app https://raw.githubusercontent.com/sclorg/mongodb-container/master/examples/statefulset/mongodb-statefulset-persistent.yaml
```

The command above will create a MongoDB cluster with 3 replica set members.

To list all pods:

```console
$ oc get pods -l name=mongodb
NAME        READY     STATUS    RESTARTS   AGE
mongodb-0   1/1       Running   0          50m
mongodb-1   1/1       Running   0          50m
mongodb-2   1/1       Running   0          49m
```

To see logs from the particular pod:

```console
$ oc logs mongodb-0
```

To log in to the pod:

```console
$ oc rsh mongodb-0
sh-4.2$
```

And later from one of the pods you can also login into MongoDB:

```console
sh-4.2$ mongo $MONGODB_DATABASE -u $MONGODB_USER -p$MONGODB_PASSWORD
MongoDB shell version: 3.2.6
connecting to: sampledb
rs0:PRIMARY>
```

## Example Working Scenarios

This section describes how this example is designed to work.

### Initial Deployment: 3-member Replica Set

After creating a cluster with the example template, we have a replica set with 3
members. That should be enough for most cases, as described in the
[official MongoDB documentation](https://docs.mongodb.com/manual/tutorial/deploy-replica-set/#overview).

During the lifetime of your OpenShift project, one or more of those members
might crash or fail. OpenShift automatically restarts unhealthy pods
(containers), and so will restart replica set members as necessary.

While a replica set member is down or being restarted, you may be in one of
these scenarios:

1. PRIMARY member is down

    In this case, the other two members shall elect a new PRIMARY. Until then,
    reads should NOT be affected, while writes will fail. After a successful
    election, writes and reads will succeed normally.

2. One SECONDARY member is down

    Reads and writes should be unaffected. Depending on the `oplogSize`
    configuration and the write rate, the third member might fail to join back
    the replica set, requiring manual intervention to re-sync its copy of the
    database.

3. Any two members are down

    When a three-member replica set member cannot reach any other member, it
    will step down from the PRIMARY role if it had it. In this case, reads might
    be served by a SECONDARY, and writes will fail. As soon as one more member
    is back up, an election will pick a new PRIMARY and reads and writes will
    succeed normally.

4. All members are down

    In this extreme case, obviously reads and writes will fail. Once two or more
    members are back up, an election will reestablish the replica set to have a
    PRIMARY and a SECONDARY, such that reads and writes will succeed normally.

**Note**: for production usage, you should maintain as much separation between
members as possible. It is recommended to use one or more of the
[node selection features](http://kubernetes.io/docs/user-guide/node-selection/)
to schedule StatefulSet pods into different nodes, and to provide them storage backed
by independent volumes.

### Scaling Up

MongoDB recommends an odd number of members in a replica set. An admin may
decide to have, for instance, 5 members in the replica set. Given that there are
sufficient available persistent volumes, or a dynamic storage provisioner is
present, scaling up is done with the `oc scale` command:

```bash
oc scale --replicas=5 statefulset.app/mongodb
```

New pods (containers) are created and they connect to the replica set, updating
its configuration.

With five members, the scenarios described in the previous section should work
similarly, though now there is an added resilience to tolerate up to 2 members
being simultaneously unavailable.

**Note**: scaling up an existing database might require manual intervention. If
the database size is greater than the `oplogSize` configuration, a manual
initial sync of the new members will be required. Please consult the MongoDB
replication manual for more information.

### Scaling Down

An admin may decide to scale down a replica set to save resources or for any
other reason. For instance, it is possible to go from 5 to 3 members, or from 3
to 1 member.

While scaling up might be done without manual intervention when the
preconditions are met (storage availability, size of existing database and
`oplogSize`), scaling down always require manual intervention.

To scaling down, start with setting the new number of replicas, e.g.:

```bash
oc scale --replicas=3 statefulset.app/mongodb
```

Note that if the new number of replicas still constitutes a majority of the
previous number, it is guaranteed that the replica set may elect a new PRIMARY
in case one of the pods that was deleted had that role. For example, that is the
case when going from 5 to 3 members.

On the other hand, scaling down to a lower number will temporarily render the
replica set to have only SECONDARY members and be in read-only mode. That would
be the case when scaling from 5 down to 1 member.

The next step is to update the mongodb replica set configuration to
[remove members](https://docs.mongodb.com/manual/tutorial/remove-replica-set-member/)
that no longer exist. This may be improved in the future, a possible
implementation being setting a PreStop pod hook that inspects the number of
replicas (exposed via the downward API) and determines that the pod is being
removed from the StatefulSet, and not being restarted for some other reason.

Finally, the volumes used by the decommissioned pods may be manually purged.
Follow the [StatefulSet documentation](https://kubernetes.io/docs/tasks/manage-stateful-set/deleting-a-statefulset/)
for more details on how to clean up after scaling down.

### Known Limitations

* Only MongoDB 3.2 is supported.
* You have to manually update replica set configuration in case of scaling down.
* Changing a user's and admin's password is a manual process: it requires
  updating values of environment variables in the StatefulSet configuration,
  changing password in the database and restarting all the pods one by one.

See also [StatefulSet limitations](https://kubernetes.io/docs/concepts/abstractions/controllers/statefulsets/#limitations).
