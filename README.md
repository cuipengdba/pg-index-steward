<img src="assets/steward.svg" alt="PG Index Steward" width="96" />

# PG Index Steward

[![版本](https://img.shields.io/github/v/release/cuipengdba/pg-index-steward?include_prereleases&label=release)](https://github.com/cuipengdba/pg-index-steward/releases)
![PG14–19](https://img.shields.io/badge/PostgreSQL-14%E2%80%9319-336791)
![Linux amd64 / arm64](https://img.shields.io/badge/Linux-x86__64%20%2F%20ARM64-168075)

PG Index Steward 根据 `pg_stat_statements` 的自然流量统计生成索引建议，在维护窗口内用独立连接执行并发 DDL，并记录索引用量和变更后的查询耗时。应用可以继续使用原 SQL。项目包含 PGXS C 扩展和同包安装的 Python 3 执行器，使用本机 PostgreSQL 的 `libpq`，无需安装 Python 第三方库。

## 一键安装到源码构建的 PostgreSQL

从 [GitHub Releases](https://github.com/cuipengdba/pg-index-steward/releases) 下载本机架构的 `.tar.gz`。两个架构包各自包含 PG14、15、16、17、18、19 对应的动态库。Linux 预编译包面向 glibc 环境。自定义 PostgreSQL 二进制 ABI、不同 C 库或系统装载失败时，使用目标实例的 `pg_config` 源码编译。PG14 上游维护已结束。

```bash
tar -xzf pg-index-steward-1.0.0-linux-x86_64.tar.gz
cd pg-index-steward-1.0.0-linux-x86_64
sudo ./install.sh \
  --pg-config /opt/pgsql/bin/pg_config \
  --data-dir /srv/pgsql/data \
  --database clouddb --port 5432 --socket /run/postgresql
```

安装器校验架构、主版本和包内 SHA-256，复制 `.so`、扩展控制文件、SQL 文件和执行器。它通过 `pg_config` 识别路径，备份并更新 `postgresql.conf`，保留原有预加载库和已有 Steward 配置。配置文件在独立目录时传入 `--config-file`。`--files-only` 只复制文件，`--no-service` 跳过 systemd 单元。第一次启用预加载需要按实例原有流程安排重启。请检查 `postgresql.auto.conf` 和启动命令中的 `shared_preload_libraries` 覆盖项。

重启后，用数据库管理员身份在每个目标数据库初始化扩展，再启用安装器打印的 systemd 单元。服务使用本机 Unix socket，由目标实例的 OS 所有者运行。数据库身份还需要读取工作负载和对目标表执行 DDL 的权限，首版安装示例使用实例管理员。PG 安装目录应由受信任的 OS 账号管理。

```sql
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
CREATE EXTENSION IF NOT EXISTS pg_index_steward;
SELECT * FROM index_steward.settings();
```

升级已有实例时，先停止执行器并备份数据库和原安装包，再用新安装包的 `--files-only` 更新文件。安排重启 PostgreSQL 加载新动态库，在各目标数据库执行 `ALTER EXTENSION pg_index_steward UPDATE TO '1.0.0';`，核对配置与 `SELECT * FROM index_steward.status();` 后恢复执行器。升级 SQL 从 0.1.0 起逐级保留现有策略和队列。需要回退整个扩展版本时，通过升级前备份恢复扩展的数据库对象，再恢复原安装包。仅替换旧动态库无法回退 SQL 迁移。

未使用 systemd 时，可以由已有任务管理器执行以下命令，或去掉 `--once` 作为常驻进程。使用 libpq 原有的本机连接参数或认证文件指定目标。

```bash
PGDATABASE=clouddb PGHOST=/run/postgresql PGPORT=5432 \
  /opt/pgsql/bin/pg-index-steward --libpq /opt/pgsql/lib/libpq.so.5 --once
```

源码安装方式需要目标 PostgreSQL 的服务器头文件和 PGXS。

```bash
make PG_CONFIG=/opt/pgsql/bin/pg_config
sudo make PG_CONFIG=/opt/pgsql/bin/pg_config install
sudo install -m 0755 bin/pg-index-steward /opt/pgsql/bin/
sudo ./install.sh --configure-only --pg-config /opt/pgsql/bin/pg_config \
  --data-dir /srv/pgsql/data --database clouddb
```

## 四个 PostgreSQL 配置参数

| 参数 | 代码默认值 | 行为 |
| --- | --- | --- |
| `pg_index_steward.auto_create` | `on` | 在窗口内创建通过筛选的候选索引 |
| `pg_index_steward.maintenance_window` | `23:00-06:00` | 按 PostgreSQL 会话时区，闭开区间，支持跨午夜 |
| `pg_index_steward.auto_drop_existing` | `off` | 现有索引默认只建议，打开后才可进入自动删除 |
| `pg_index_steward.auto_drop_managed` | `on` | 按闲置策略自动清理 Steward 自己创建的索引 |

```conf
pg_index_steward.auto_create = on
pg_index_steward.maintenance_window = '23:00-06:00'
pg_index_steward.auto_drop_existing = off
pg_index_steward.auto_drop_managed = on
```

修改 `postgresql.conf` 后执行 `SELECT pg_reload_conf();`。没有配置项时使用表中的代码默认值。执行器默认每 15 分钟采集一次。使用 `--observe-only` 启动执行器时只记录观察结果和建议。需要紧急停止时关闭服务并用 `pg_stat_activity` 查找 `application_name = 'pg-index-steward'` 的在途 DDL，按实例运维流程处理。

## 创建和验证

执行器比较累计统计的增量，使用 PostgreSQL 原生语法解析器提取带 schema 的单表 `SELECT` 以及可分析的 `UNION` 分支。支持常见的等值、短 `IN` 和单一列范围谓词，根据列统计、缓冲区工作量和已有 B-tree 前缀筛选普通表非唯一索引。候选使用采样期间的累计耗时排序。解析和校验只针对已保存的工作负载文本，执行器只生成自己的 DDL。

任务进入持久化队列并等待维护窗口。执行前重新检查对象、索引重叠、磁盘余量、长事务、复制状态和窗口余额。受阻任务保留 `next_attempt_at`，调度器继续处理下一条符合条件的任务。等待两天的任务优先，锁冲突、超时等可重试错误按退避时间重排。若达到重试上限，可在处理根因后用 `index_steward.retry_job(id)` 重新激活。超过七天没有新证据的普通表建索引候选等待下一次负载采样更新。闲置删除后同一候选有七天重新创建冷却期，回退后有三十天冷却期。

每实例用本机锁串行维护。每轮最多执行一项 DDL。普通表走并发创建和删除，默认候选范围为默认表空间中 1 MiB 至 5 GiB 的永久普通表。连接和排序类候选当前提供建议。单层原生分区表可用 `SELECT index_steward.queue_partition_index('public.events', ARRAY['device_id']::name[]);` 主动排队，并继续受窗口和自动创建开关控制。执行器创建父索引定义、并发创建各子索引并逐个挂接。TimescaleDB 提供 `index_steward.timescale_diagnostics` 视图查看分块 B-tree 覆盖，自动执行仍以原生普通表与显式排队的原生分区表为范围。

HypoPG 1.4.5 的源码随插件编译进 `pg_index_steward.so`。`index_steward.policy.use_hypopg` 默认开启。对部分普通表候选，在执行器连接内以生成的等值模板比较普通 `EXPLAIN` 计划。`detail.plan_evidence` 包含优化器成本与是否使用候选索引。该结果用于理解候选，真实业务效果以建成后的自然流量衡量。

新索引用自然流量复核。`verdicts` 保留建前与建后的调用次数、总耗时和块指标，输出 `observing`、`improved`、`mixed` 或 `regression_review`。这些指标反映均值趋势。DBA 可调用 `index_steward.approve_rollback(job_id)` 将回退排入维护窗口。`policy.auto_rollback` 默认关闭，启用后也要求持续的耗时和读块回退证据，且仍走索引身份、依赖和复制检查。回退完成后暂停该库的自动队列。

## 清理规则

插件和已有索引都需要满足连续观察至少 60 天且扫描计数未增长。`policy.idle_days` 可延长观察期。采样间隔超过 24 小时、计数变化、重启、统计重置或索引定义改变都会重新计时。执行前再次检查索引身份与依赖，保护约束、唯一、主键、外键查找路径、复制身份、表达式、部分索引和非 B-tree 索引。有复制时，只有各承担读流量的直连物理副本均纳入观测并通过证据检查，才进入删除。通过 libpq service 配置连接，服务名与主库 `pg_stat_replication.application_name` 对应，并登记到 `policy.replica_services`。级联、无槽离线备库等无法完整观测的拓扑应关闭自动删除。并发运维使用单独窗口，避免同时改变同一对象。

```sql
SELECT * FROM index_steward.recommendations ORDER BY id DESC LIMIT 30;
SELECT * FROM index_steward.verdicts ORDER BY job_id DESC LIMIT 20;
SELECT id, detail->>'ddl' AS recreate_ddl, message
FROM index_steward.jobs WHERE action = 'drop' ORDER BY id DESC;
```

清理前保存重建语句。恢复时根据保存的定义重建索引。执行器中断后核对目录状态，安全时继续，存在无效或归属不明确的对象时标记待处理。

## 队列和 PostgreSQL 日志

`index_steward.policy` 可设置 `paused`、`allowed_schemas`、`allowed_tables`、`daily_limit`、`min_free_bytes` 与 `ddl_timeout_seconds`。`allowed_tables` 使用带双引号的限定名，例如 `ARRAY['"public"."devices"']`。SQL 指标接口可单独授权 `USAGE ON SCHEMA index_steward` 和 `EXECUTE ON FUNCTION index_steward.status()`，用于跨实例获取只读汇总。

```bash
pg-index-steward --status --service primary_a --service primary_b
pg-index-steward --metrics --service primary_a --service primary_b
```

在 PostgreSQL 的常规日志中搜索 `PG Index Steward`。日志包含结构化事件、数据库名、任务 ID、动作、阻塞原因和重试时间。日志路由遵循 `log_destination` 与 `log_min_messages`，连接失败时执行器在标准错误记录故障。轮询过程中读取 `pg_stat_statements.track=all` 能看到已记录的嵌套语句。规划耗时取自已有的 `track_planning` 统计，未启用时该字段不可用于判断重规划成本。

## 测试、打包与发布

`tests/integration.sh` 使用独立临时 PGDATA，覆盖升级、安装、建索引、日志、受阻任务恢复、清理、回退与分区任务。`scripts/package.sh` 生成每架构自包含的安装包。GitHub Actions 在原生 x86_64 与 ARM64 runner 上分别验证 PG14–19。已发布功能和更早版本路线见 [CHANGELOG](CHANGELOG.md) 与 [ROADMAP](ROADMAP.md)。
