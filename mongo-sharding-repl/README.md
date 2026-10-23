## Последовательность шагов

## Запуск контейнеров

```shell
docker compose up --pull always -d
docker compose ps -a
```

## Необходимо убедиться, что шарды зарегистрированы
```shell
docker compose exec -T mongos mongosh --port 27020 --quiet --eval \
'db.adminCommand({listShards: 1})'
```
Результат должен включать shard1 и shard2


## При необходимости выполните инициализацию шардирования один раз
```shell
docker compose exec -T mongos mongosh --port 27020 --quiet <<'EOF'
sh.enableSharding("somedb")
db.getSiblingDB("somedb").helloDoc.createIndex({ name: "hashed" })
sh.shardCollection("somedb.helloDoc", { name: "hashed" })
EOF
```


## Инициализация replica set сервера shard1:
```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
rs.initiate({
  _id: "shard1",
  members: [{ _id: 0, host: "shard1:27018" }]
})
EOF
```

## Инициализация replica set shard2:
```shell
docker compose exec -T shard2 mongosh --port 27019 --quiet <<'EOF'
rs.initiate({
  _id: "shard2",
  members: [{ _id: 0, host: "shard2:27019" }]
})
EOF
```

## Заполняем данными: 1,000 документов в somedb.helloDoc

```shell
docker compose exec -T mongos mongosh --port 27020 --quiet <<'EOF'
use somedb
for (var i = 0; i < 1000; i++) db.helloDoc.insert({ age: i, name: "ly" + i }) EOF
```

## Проверка заполнения данными
```shell
docker compose exec -T mongos mongosh --port 27020 --quiet --eval 'db.getSiblingDB("somedb").helloDoc.countDocuments()'
```

## Проверить количество документов на каждом шарде:
```shell
docker compose exec -T shard1 mongosh --port 27018 --quiet <<'EOF'
use somedb
db.helloDoc.countDocuments()
EOF
```
```shell
docker compose exec -T shard2 mongosh --port 27019 --quiet <<'EOF'
use somedb
db.helloDoc.countDocuments()
EOF
```
## Если все данные находятся на одном шарде, то чтобы разделить и переместить фрагмент данных, используйте команду:
 ```shell
 docker compose exec -T mongos mongosh --port 27020 --quiet <<'EOF'
sh.splitAt("somedb.helloDoc", { name: NumberLong("0") })
sh.moveChunk("somedb.helloDoc", { name: NumberLong("0") }, "shard1")
EOF
```
## Проверьте количество и распределение:
 ```shell
docker compose exec -T mongos mongosh --port 27020 --quiet --eval \
'db.getSiblingDB("somedb").helloDoc.countDocuments()'
```

## Проверьте принадлежность фрагментов и распределение документов:
 ```shell
 docker compose exec -T mongos mongosh --port 27020 --quiet --eval \
'db.getSiblingDB("somedb").helloDoc.getShardDistribution()'

docker compose exec -T mongos mongosh --port 27020 --quiet --eval 'sh.status()'
```