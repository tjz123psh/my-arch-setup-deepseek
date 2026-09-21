# Kafka 本地开发栈配置说明

本机用 Docker Compose 跑了一个本地 Kafka 开发环境：一个 Kafka broker（KRaft 单节点）+ 一个 Kafbat UI 图形界面。所有配置都在一个 compose 文件里，改配置后重启即可。

## 1. 整体结构

| 组件 | 镜像 | 作用 | 对外端口 |
|---|---|---|---|
| Kafka broker | `apache/kafka:latest` | 消息存储（KRaft 模式，无需 Zookeeper） | `9092` |
| Kafbat UI | `ghcr.io/kafbat/kafka-ui:latest` | 网页管理界面：看 topic、翻消息、consumer group、Schema Registry、ACL 等 | `18080` |

- 配置文件：`/home/pang/kafka-stack/docker-compose.yml`
- 数据目录：`/home/pang/kafka-stack/kafka-data/`（绑定挂载，重建容器数据不丢）
- Web 界面：<http://localhost:18080>

## 2. 完整配置

```yaml
services:
  kafka:
    image: apache/kafka:latest
    ports:
      - "9092:9092"
    volumes:
      - ./kafka-data:/tmp/kraft-combined-logs

  kafbat:
    image: ghcr.io/kafbat/kafka-ui:latest
    network_mode: host
    environment:
      KAFKA_CLUSTERS_0_NAME: local
      KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS: localhost:9092
      SERVER_PORT: 18080
    depends_on:
      - kafka
```

### 逐项说明

- **`kafka.volumes: ./kafka-data:/tmp/kraft-combined-logs`**：broker 数据持久化。`/tmp/kraft-combined-logs` 是官方镜像默认的 `log.dirs`（KRaft 元数据 + 主题数据都在这）。挂载后，容器怎么重建数据都在。
- **`kafbat.network_mode: host`**：UI 直接使用宿主机网络。原因见第 3 节「为什么这样配」。
- **`KAFKA_CLUSTERS_0_NAME` / `KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS`**：给 UI 配置要连接的集群，`local` 是集群显示名，`localhost:9092` 是 broker 地址。
- **`SERVER_PORT: 18080`**：Kafbat UI 是 Spring Boot 应用，这个环境变量改它的监听端口。默认 8080 太容易被其他东西占用，换成了不常用的 18080。

## 3. 为什么这样配（踩坑记录）

这些是配置成现在这样的原因，改之前先读：

1. **UI 必须用 host 网络，不能走普通端口映射。** 官方 `apache/kafka` 镜像默认把 broker 地址宣告（advertised listener）为 `localhost:9092`。如果 UI 容器跑在 compose 的桥接网络里，它连上 broker 后会被指引去连"自己容器内的 localhost"，永远连不上。
2. **不要试图改 broker 的监听器配置来绕开上面这个问题。** 给 kafka 服务设置 `KAFKA_LISTENERS` / `KAFKA_ADVERTISED_LISTENERS` 会触发镜像启动脚本的另一个分支：它不再注入单节点 KRaft 的默认参数，直接报 `Missing required configuration "process.roles"` 崩溃。这也是很多人在这镜像上翻车的点。
3. **数据目录不能直接用命名卷（named volume）。** Docker 初始化命名卷时根目录归 root，而镜像内 broker 以 `appuser`（uid 1000）运行，写入时 `AccessDenied`。所以改用宿主绑定挂载 `./kafka-data`（宿主机上该目录属主是你的用户，uid 1000，正好对上）。
4. **镜像 tag 用 `latest`。** GHCR 上 `kafbat/kafka-ui` 没有 `1.5.0` 这类版本 tag（releases 有版本号但镜像没同步），`latest` 一直有更新。

## 4. 常用操作

```fish
cd ~/kafka-stack

docker compose up -d             # 启动（或改配置后应用）
docker compose down              # 停止（数据保留在 ./kafka-data）
docker compose down -v           # 停止并清空数据（慎用）
docker compose logs -f kafbat    # 看 UI 日志
docker compose logs -f kafka     # 看 broker 日志
docker compose ps                # 看状态
```

## 5. 连接方式

### Web 界面

浏览器打开 <http://localhost:18080>，集群名 `local`，状态应为 Online。

### 程序 / CLI

任何客户端连 `localhost:9092` 即可。命令行示例：

```fish
# 建 topic
docker exec kafka-stack-kafka-1 /opt/kafka/bin/kafka-topics.sh \
  --bootstrap-server localhost:9092 --create --topic my-topic \
  --partitions 1 --replication-factor 1

# 生产消息
echo 'hello' | docker exec -i kafka-stack-kafka-1 /opt/kafka/bin/kafka-console-producer.sh \
  --bootstrap-server localhost:9092 --topic my-topic

# 消费消息
docker exec kafka-stack-kafka-1 /opt/kafka/bin/kafka-console-consumer.sh \
  --bootstrap-server localhost:9092 --topic my-topic --from-beginning
```

装了 `kcat-cli` / `kafkactl` 的话可以直接连 `localhost:9092`：

```fish
kcat -L -b localhost:9092
kafkactl get topics
```

## 6. 数据持久化说明

- 所有数据（主题、消息、KRaft 元数据）在 `/home/pang/kafka-stack/kafka-data/`，对应容器内 `/tmp/kraft-combined-logs`。
- `docker compose down` / `up` / `--force-recreate` 都不会丢数据；只有 `docker compose down -v` 或手动删除目录才会清空。
- 备份：直接打包 `kafka-data` 目录即可（停 broker 后再打包更稳）。

## 7. 故障排查

| 现象 | 原因 / 处理 |
|---|---|
| 页面顶部提示 "Your app version is outdated. Latest version is UNKNOWN" | 无害。UI 检查 GitHub 新版本的显示 bug，忽略。 |
| UI 能打开但集群显示 Offline / INITIALIZING | UI 容器连不上 broker。检查 `docker compose ps` 里 kafka 是否 Up，以及 `docker compose logs kafbat` 里有无 `Connection to node ... could not be established`。 |
| broker 起不来，日志里有 `AccessDeniedException` | 数据目录属主不对。确保 `./kafka-data` 属主是 uid 1000（`sudo chown -R 1000:1000 kafka-data`）。 |
| broker 起不来，日志里有 `Missing required configuration "process.roles"` | 给 kafka 服务加了自定义监听器环境变量导致的，删掉即可，别绕（见第 3 节第 2 条）。 |
| 端口冲突 | UI 端口在 compose 里改 `SERVER_PORT`；broker 端口改 `ports` 里的 `9092:9092`（注意：同时要改 `KAFKA_CLUSTERS_0_BOOTSTRAPSERVERS`，且宿主客户端也要用新端口）。 |
