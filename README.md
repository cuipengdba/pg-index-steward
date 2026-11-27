<img src="assets/steward.svg" alt="PG Index Steward" width="96" />

# PG Index Steward

[![版本](https://img.shields.io/github/v/release/cuipengdba/pg-index-steward?include_prereleases&label=release)](https://github.com/cuipengdba/pg-index-steward/releases)
![PG14–19](https://img.shields.io/badge/PostgreSQL-14%E2%80%9319-336791)
![Linux amd64 / arm64](https://img.shields.io/badge/Linux-x86__64%20%2F%20ARM64-168075)

PG Index Steward 根据 `pg_stat_statements` 的自然流量统计生成索引建议，在维护窗口内用独立连接执行并发 DDL，并记录索引用量和变更后的查询耗时。应用可以继续使用原 SQL。项目包含 PGXS C 扩展和同包安装的 Python 3 执行器，使用本机 PostgreSQL 的 `libpq`，无需安装 Python 第三方库。

## 一键安装到源码构建的 PostgreSQL

从 [GitHub Releases](https://github.com/cuipengdba/pg-index-steward/releases) 下载本机架构的 `.tar.gz`。两个架构包各自包含 PG14、15、16、17、18、19 对应的动态库。Linux 预编译包面向 glibc 环境。自定义 PostgreSQL 二进制 ABI、不同 C 库或系统装载失败时，使用目标实例的 `pg_config` 源码编译。PG14 上游维护已结束。

```bash
tar -xzf pg-index-steward-0.1.0-linux-x86_64.tar.gz
cd pg-index-steward-0.1.0-linux-x86_64
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

任务进入队列后等待维护窗口。执行前再次校验对象、索引重叠、磁盘空间、长事务、复制状态和窗口剩余时间。每实例用本机锁串行维护，一轮最多执行一个 `CREATE INDEX CONCURRENTLY` 或 `DROP INDEX CONCURRENTLY`，并记录失败。当前规则自动建索引限默认表空间中 1 MiB 至 5 GiB 的永久普通表。分区、继承、RLS、扩展对象、TimescaleDB 和 Citus 管理的表排除出自动执行。

新索引在自然流量下进入复核。`verdicts` 保留建前及建后的调用次数、总耗时和块指标，输出 `observing`、`improved`、`mixed` 或 `regression_review`。这些是均值趋势，归因需要结合流量和计划。显著回退由 DBA 结合执行计划决定撤销。首版以原生 PostgreSQL 的索引维护为范围，复合连接、排序、SQL 重写和按查询调参不在自动变更范围内。

## 清理规则

插件和已有索引都需要满足连续观察至少 60 天且扫描计数未增长。在采样间隔超过 24 小时、计数变化、重启、统计重置或索引定义改变时，重新计时。执行前再次检查索引的 OID、定义、物理文件标识、表及依赖关系。约束、唯一、主键、复制身份、表达式、部分索引和非 B-tree 索引排除出自动删除。存在复制连接或复制槽时保留删除建议。使用无槽的离线备用节点或仅由外部路由维护的读副本时，应在相应实例关闭自动删除或确保这些索引的使用已纳入运维决策。并发运维应使用独立维护窗口，避免同时改变同一对象。

```sql
SELECT * FROM index_steward.recommendations ORDER BY id DESC LIMIT 30;
SELECT * FROM index_steward.verdicts ORDER BY job_id DESC LIMIT 20;
SELECT id, detail->>'ddl' AS recreate_ddl, message
FROM index_steward.jobs WHERE action = 'drop' ORDER BY id DESC;
```

清理前保存重建语句。需要撤销建索引时，从 `managed_indexes` 获取索引信息并在窗口内并发删除。恢复已清理索引时按保存的定义并发重建。长时间落后或异常中断后，`jobs` 会标记失败供运维检查，主键和管理数据都保留在目标数据库。

## 测试、打包与发布

`tests/integration.sh` 创建独立临时 PGDATA 和私有 Unix socket，验证安装、配置、建索引和两个删除开关。`scripts/package.sh` 生成每架构自包含的安装包。GitHub Actions 在 x86_64 与 ARM64 runner 上分别验证全部主版本，打 `v0.1.0` 类版本标签时汇总包和校验文件。查看发布页的实际验证范围。
