#!/usr/bin/env bash
set -Eeuo pipefail

readonly MONGOS_HOST="${MONGOS_HOST:-mongos_router}"
readonly MONGOS_PORT="${MONGOS_PORT:-27020}"
readonly DATABASE="${DATABASE:-somedb}"
readonly COLLECTION="${COLLECTION:-helloDoc}"
readonly DOCUMENT_COUNT="${DOCUMENT_COUNT:-1000}"

wait_for_ping() {
  local host="$1" port="$2" label="$3"
  for attempt in $(seq 1 90); do
    if mongosh --quiet --host "$host" --port "$port" --eval 'db.adminCommand({ping:1}).ok' 2>/dev/null | grep -qx '1'; then
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for ${label} at ${host}:${port}" >&2
  return 1
}

run_mongosh() {
  local host="$1" port="$2" js="$3"
  mongosh --quiet --host "$host" --port "$port" --eval "$js"
}

initiate_replica_set() {
  local host="$1" port="$2" replica_set="$3" config="$4"
  wait_for_ping "$host" "$port" "$replica_set"

  run_mongosh "$host" "$port" "
    try {
      const status = rs.status();
      if (status.ok === 1) {
        print('Replica set ' + status.set + ' already initialized.');
        quit(0);
      }
    } catch (error) {
      if (error.code !== 94) throw error;
    }
    const result = rs.initiate(${config});
    printjson(result);
    if (result.ok !== 1) quit(1);
  "
}

wait_for_primary() {
  local host="$1" port="$2" replica_set="$3"
  for attempt in $(seq 1 90); do
    if run_mongosh "$host" "$port" 'rs.status().members.some(member => member.stateStr === "PRIMARY")' 2>/dev/null | grep -qx 'true'; then
      echo "${replica_set}: primary elected."
      return 0
    fi
    sleep 2
  done
  echo "Timed out waiting for a primary in ${replica_set}" >&2
  return 1
}

check_replica_set() {
  local host="$1" port="$2" replica_set="$3"
  echo "--- Replica set: ${replica_set} ---"
  run_mongosh "$host" "$port" '
    const status = rs.status();
    printjson({set: status.set, myState: status.myState, members: status.members.map(member => ({host: member.name, state: member.stateStr, health: member.health}))});
    if (status.members.some(member => member.health !== 1 || !["PRIMARY", "SECONDARY"].includes(member.stateStr))) quit(1);
  '
}

initialize_replica_sets() {
  initiate_replica_set configSrv 27017 config_server '{_id:"config_server",configsvr:true,members:[{_id:0,host:"configSrv:27017"}]}'
  initiate_replica_set shard1_1 27018 shard1 '{_id:"shard1",members:[{_id:0,host:"shard1_1:27018"},{_id:1,host:"shard1_2:27028"},{_id:2,host:"shard1_3:27038"}]}'
  initiate_replica_set shard2_1 27019 shard2 '{_id:"shard2",members:[{_id:0,host:"shard2_1:27019"},{_id:1,host:"shard2_2:27029"},{_id:2,host:"shard2_3:27039"}]}'

  wait_for_primary configSrv 27017 config_server
  wait_for_primary shard1_1 27018 shard1
  wait_for_primary shard2_1 27019 shard2
  check_replica_set configSrv 27017 config_server
  check_replica_set shard1_1 27018 shard1
  check_replica_set shard2_1 27019 shard2
}

initialize_sharding() {
  wait_for_ping "$MONGOS_HOST" "$MONGOS_PORT" mongos

  mongosh --quiet --host "$MONGOS_HOST" --port "$MONGOS_PORT" --eval "
    const admin = db.getSiblingDB('admin');
    let result = admin.runCommand({listShards: 1});
    if (result.ok !== 1) throw new Error('Cannot list shards: ' + tojson(result));
    let registered = result.shards.map(shard => shard._id);

    if (!registered.includes('shard1')) {
      result = sh.addShard('shard1/shard1_1:27018,shard1_2:27028,shard1_3:27038');
      if (result.ok !== 1) throw new Error('Failed to register shard1: ' + tojson(result));
      printjson(result);
    }
    if (!registered.includes('shard2')) {
      result = sh.addShard('shard2/shard2_1:27019,shard2_2:27029,shard2_3:27039');
      if (result.ok !== 1) throw new Error('Failed to register shard2: ' + tojson(result));
      printjson(result);
    }

    result = sh.enableSharding('${DATABASE}');
    if (result.ok !== 1) throw new Error('Failed to enable sharding: ' + tojson(result));

    const target = db.getSiblingDB('${DATABASE}');
    const collection = target.getCollection('${COLLECTION}');
    collection.createIndex({name: 'hashed'});
    const namespace = '${DATABASE}.${COLLECTION}';
    const collectionInfo = db.getSiblingDB('config').collections.findOne({_id: namespace});
    if (!collectionInfo || collectionInfo.unsplittable) {
      result = sh.shardCollection(namespace, {name: 'hashed'});
      if (result.ok !== 1) throw new Error('Failed to shard collection: ' + tojson(result));
      printjson(result);
    }

    const count = collection.countDocuments({});
    if (count < ${DOCUMENT_COUNT}) {
      const documents = [];
      for (let i = count; i < ${DOCUMENT_COUNT}; i++) documents.push({age: i, name: 'ly' + i});
      if (documents.length) collection.insertMany(documents);
    }
    print('Sharding initialized; document count=' + collection.countDocuments({}));
  "

  check_cluster
}

check_cluster() {
  wait_for_ping "$MONGOS_HOST" "$MONGOS_PORT" mongos
  echo '--- Registered shards ---'
  mongosh --quiet --host "$MONGOS_HOST" --port "$MONGOS_PORT" --eval '
    const result = db.adminCommand({listShards: 1});
    printjson(result);
    if (result.ok !== 1 || result.shards.length < 1) quit(1);
  '

  check_replica_set configSrv 27017 config_server
  check_replica_set shard1_1 27018 shard1
  check_replica_set shard2_1 27019 shard2

  echo "--- ${DATABASE}.${COLLECTION} shard distribution ---"
  mongosh --quiet --host "$MONGOS_HOST" --port "$MONGOS_PORT" --eval "
    const collection = db.getSiblingDB('${DATABASE}').getCollection('${COLLECTION}');
    printjson(collection.getShardDistribution());
    print('Total documents=' + collection.countDocuments({}));
  "
}

usage() {
  echo "Usage: $0 {replica-sets|sharding|check}" >&2
  exit 2
}

case "${1:-}" in
  replica-sets) initialize_replica_sets ;;
  sharding) initialize_sharding ;;
  check) check_cluster ;;
  *) usage ;;
esac
