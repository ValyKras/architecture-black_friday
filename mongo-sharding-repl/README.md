## Последовательность шагов

## Запуск контейнеров

```shell
docker compose up --pull always -d
docker compose ps -a
```

## Необходимо убедиться, что шарды зарегистрированы
```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval \
'db.adminCommand({listShards: 1})'
```
Результат должен включать shard1 и shard2


## Инициализация реплика-сет
```shell
docker compose exec -T shard1_1 mongosh --quiet --port 27018 --eval 'rs.initiate({_id:"shard1", members:[{_id:0,host:"shard1_1:27018"},{_id:1,host:"shard1_2:27028"},{_id:2,host:"shard1_3:27038"}]})' && docker compose exec -T shard2_1 mongosh --quiet --port 27019 --eval 'rs.initiate({_id:"shard2", members:[{_id:0,host:"shard2_1:27019"},{_id:1,host:"shard2_2:27029"},{_id:2,host:"shard2_3:27039"}]})'
```
## Проверка статуса шарда 1 и 2
```shell
docker compose exec -T shard1_1 mongosh --port 27018 --quiet --eval 'rs.status()'

docker compose exec -T shard2_1 mongosh --port 27019 --quiet --eval 'rs.status()'
```

## Настройка шардирования кластера и добавление тестовых данных
```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet <<'EOF'
try {
  const admin = db.getSiblingDB("admin");
  const existing = admin.runCommand({ listShards: 1 }).shards.map(s => s._id);

  if (!existing.includes("shard1")) {
    const result = sh.addShard("shard1/shard1_1:27018");
    assert(result.ok === 1, "Failed to add shard1");
  }
  if (!existing.includes("shard2")) {
    const result = sh.addShard("shard2/shard2_1:27019");
    assert(result.ok === 1, "Failed to add shard2");
  }

  let result = sh.enableSharding("somedb");
  assert(result.ok === 1, "Failed to enable sharding");

  const somedb = db.getSiblingDB("somedb");
  somedb.helloDoc.createIndex({ name: "hashed" });

  const collectionInfo = db.getSiblingDB("config").collections.findOne({ _id: "somedb.helloDoc" });
  if (!collectionInfo || collectionInfo.unsplittable) {
    result = sh.shardCollection("somedb.helloDoc", { name: "hashed" });
    assert(result.ok === 1, "Failed to shard collection");
  }

  const count = somedb.helloDoc.countDocuments({});
  if (count < 1000) {
    const docs = [];
    for (let i = count; i < 1000; i++) docs.push({ age: i, name: "ly" + i });
    if (docs.length) somedb.helloDoc.insertMany(docs);
  }

  printjson(admin.runCommand({ listShards: 1 }));
  printjson(db.getSiblingDB("config").collections.findOne({ _id: "somedb.helloDoc" }));
  print("documents=" + somedb.helloDoc.countDocuments({}));
} catch (error) {
  print("Exception: " + error.message);
  quit(1);
}
EOF
```

## Проверка заполнения данными
```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()'
```

## Проверить количество документов для шарда 1:
```shell
docker compose exec -T shard1_1 mongosh --port 27018 --quiet <<'EOF'
use somedb;
db.helloDoc.countDocuments();
exit();
EOF

docker compose exec -T shard1_2 mongosh --port 27028 --quiet <<EOF
use somedb;
db.helloDoc.countDocuments();
exit();
EOF

docker compose exec -T shard1_3 mongosh --port 27038 --quiet <<EOF
use somedb;
db.helloDoc.countDocuments();
exit();
EOF
```

## Проверить количество документов для шарда 2:
```shell
docker compose exec -T shard2_1 mongosh --port 27019 --quiet <<EOF
use somedb;
db.helloDoc.countDocuments();
exit();
EOF

docker compose exec -T shard2_2 mongosh --port 27029 --quiet <<EOF
use somedb;
db.helloDoc.countDocuments();
exit();
EOF

docker compose exec -T shard2_3 mongosh --port 27039 --quiet <<EOF
use somedb;
db.helloDoc.countDocuments();
exit();
EOF
```


## Проверьте принадлежность фрагментов и распределение документов:
 ```shell
docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.getShardDistribution()'

docker compose exec -T mongos_router mongosh --port 27020 --quiet --eval 'sh.status()'
```