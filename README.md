# SelfserviceGreenhouse Backend（智能温室后端服务）

基于 **Elixir (`~> 1.18`) / Erlang OTP** 构建的温室物联网后端服务（使用 [`Bandit`](https://github.com/mtrudel/bandit) + [`Plug`](https://github.com/elixir-plug/plug) 提供 HTTP 服务，使用 [`emqx/emqtt`](https://github.com/emqx/emqtt) 作为 MQTT 客户端，结合 Elixir 内置 `JSON` 及 Erlang/OTP 标准库 `:ets`、`:dets`、`:logger`、`:inets`）。

实现设备端通信协议 [PROTOCOL.md](PROTOCOL.md)（MQTT 3.1.1 数据通道 v1），并向客户端/前端提供统一的 **HTTP/1.1 REST API**。

---

## 1. 系统架构 / Architecture

### 1.1 OTP 监督树（Supervision Tree）

`Greenhouse.Application` 启动 `Greenhouse.Supervisor`（`:one_for_one` 策略），按顺序管理以下子进程：

1. `Greenhouse.Storage` (`GenServer` + `:ets` / `:dets`)：内存高速缓存 + 可选 DETS 持久化，存储设备在线状态、最新遥测、历史遥测、告警及配置缓存；由 `Storage.Codec`、`Storage.Query`、`Storage.Retention` 提供编解码、分页统计与容量淘汰支持。
2. `Greenhouse.AccountStore` (`GenServer` + `:ets` / `:dets`)：账号认证（加盐 SHA-256）、会话管理（自动过期清理）、用户设备独占绑定、`GH-0001` 本地模拟及演示数据重置；内部拆分自 `AccountStore.Auth`、`AccountStore.Bindings` 与 `AccountStore.Simulator`。
3. `Greenhouse.ConfigManager` (`GenServer`)：协调配置校验（`Greenhouse.ConfigValidator`）、MQTT 下发（`gh/<deviceId>/config`）与 `config/ack` 回执等待及超时离线判定。
4. `Greenhouse.MQTT.Client` (`GenServer` + `:emqtt`)：基于 `emqx/emqtt` 的 MQTT 3.1.1 明文 TCP 客户端包装层（`proto_ver: :v4`、`low_mem: true`），支持断线指数退避重连、自动 QoS 1 订阅、心跳保活与自动 QoS 1 `PUBACK`，并将报文安全分发至 `Greenhouse.MQTT.Handler`。
5. `Greenhouse.Web.Server` (`Bandit` + `ThousandIsland` 监督树)：基于 `Bandit` 的 HTTP 服务端，交由基于 `Plug.Router` 构建的 `Greenhouse.Web.Router` 调度至 `Web.Handlers.*`。

### 1.2 项目目录结构

```text
config/
  config.exs                # 基础默认配置
  dev.exs                   # 开发环境配置（默认端口 4000，开启 Storage/AccountStore DETS 持久化）
  test.exs                  # 测试环境配置（随机端口 0，禁用 MQTT 自动连接与 DETS）
  runtime.exs               # 运行时环境变量注入
lib/
  greenhouse.ex
  greenhouse/
    application.ex          # OTP 监督树入口
    support.ex              # 二进制分离、时间戳、通用字段解析与存储适配辅助
    support/
      dets.ex               # ETS/DETS 公共生命周期管理辅助
    config_validator.ex     # PROTOCOL.md 4.1 / 4.3 / 4.4 配置校验与单位换算
    config_manager.ex       # 配置下发与 config/ack 事务协调
    storage.ex              # 存储 GenServer 与对外 Facade
    storage/
      codec.ex              # 紧凑 ETS/DETS 记录编解码与旧格式迁移
      query.ex              # 历史遥测分页查询与流式统计
      retention.ex          # 设备历史容量扫描与 LRU 淘汰
    account_store.ex        # 账号与设备绑定 GenServer 与对外 Facade
    account_store/
      auth.ex               # 注册、密码哈希校验与会话生命周期管理
      bindings.ex           # 用户设备独占绑定与快照聚合
      simulator.ex          # GH-0001 演示数据初始化与场景模拟
    mqtt/
      client.ex             # 基于 :emqtt 的 MQTT 连接管理、自动订阅与重连状态机
      handler.ex            # 主题解析与版本过滤（v > 1 丢弃）
    web/
      params.ex             # 查询参数、路径参数、时间区间与单位选项解析
      respond.ex            # Plug JSON 响应编码、请求头读取与 JSON 对象解码
      server.ex             # 基于 Bandit / ThousandIsland 的 HTTP 服务端封装
      router.ex             # 基于 Plug.Router 的 REST API 路由、CORS 与请求解析管道
      handlers/
        auth.ex             # 登录、注册、注销、当前用户及 Token 提取
        user_devices.ex     # 租户隔离下的用户设备绑定 CRUD
        devices.ex          # 健康检查、设备遥测、告警、配置下发与模拟控制
test/
  support/
    helpers.ex              # 测试进程清理、轮询等待与遥测样例辅助
    http_helpers.ex         # HTTP 测试请求与 CORS 断言辅助
    mqtt_mock_broker.ex     # 基于 :emqtt_frame 的本地 TCP Mock MQTT Broker
  greenhouse/
    account_store_test.exs
    config_manager_test.exs
    config_validator_test.exs
    storage_test.exs
    storage/
      query_and_retention_test.exs
    mqtt/
      handler_test.exs
      integration_test.exs
    web/
      auth_and_tenant_routes_test.exs
      conn_test.exs
      router_test.exs
      server_test.exs
```

---

## 2. 协议映射说明（PROTOCOL.md v1 Mapping）

| PROTOCOL.md 章节 | 协议规则 | 后端实现位置与行为 |
|---|---|---|
| **§1 连接** | MQTT 3.1.1 明文 TCP，username/password 认证，唯一 `clientId` | `Greenhouse.MQTT.Client` + `runtime.exs` (`greenhouse-backend-<pid>`) |
| **§2 主题订阅** | 订阅 `gh/+/telemetry`、`gh/+/alarm/#`、`gh/+/status`、`gh/+/config/ack` (QoS 1) | `MQTT.Client` 收到 `CONNACK(0)` 后立即发起 QoS 1 `SUBSCRIBE` |
| **§3.1 遥测** | `t` / `ah` / `sh` 为 `0.01` 整数倍；客户端采用接收时刻；按 `(deviceId, seq)` 结合 `up` 重启回退去重 | `Storage.record_telemetry/3` 除以 `100.0` 还原为 `temperature`、`air_humidity`、`soil_humidity`，保留 `raw` 与 `received_at` |
| **§3.2 告警** | `retain=1`；固件不发解除包，需由后续正常遥测（`water: 1`）自动解除 `water_lack` | `Storage.record_alarm/4`、`Storage.record_telemetry/3` 自动将 `water_lack` 置为 `active: false` (`telemetry_water_normal`) |
| **§3.3 状态** | `gh/<deviceId>/status`（含 LWT `online: false`）决定在线状态 | `Storage.record_status/3` 与 `Storage.mark_device_offline/2` |
| **§4.1-4.4 配置** | `gh/<deviceId>/config` 仅下发变更字段（QoS 1, `retain=false`）；等待 `config/ack`，默认 10s 超时标记离线且不盲目重发 | `ConfigValidator.validate_patch/2` 执行整份合并校验；`ConfigManager.apply_config/3` 等待回执或超时调用 `Storage.mark_device_offline/2` |
| **§5 版本兼容** | `v > 1` 丢弃并记录日志，不崩溃 | `MQTT.Handler` 记录 `Logger.warning` 并返回 `{:error, :unsupported_version}` |

---

## 3. 环境变量（Environment Variables）

所有运行时环境变量均在 `config/runtime.exs` 中读取：

| 变量名 | 默认值 | 说明 |
|---|---|---|
| `PORT` / `HTTP_PORT` | `4000`（`:test` 环境为 `0`） | HTTP REST API 监听端口（`PORT` 优先于 `HTTP_PORT`） |
| `MQTT_ENABLED` | `:prod` 为 `true`，其他环境为 `false` | 是否启用 MQTT 客户端连接（支持 `true`/`1`/`false`/`0`） |
| `MQTT_HOST` | `"mqtt.example.com"` | MQTT Broker 主机名或 IP |
| `MQTT_PORT` | `1883` | MQTT Broker TCP 端口 |
| `MQTT_USERNAME` | `"customer-01"` | MQTT 认证用户名 |
| `MQTT_PASSWORD` | `""` | MQTT 认证密码 |
| `MQTT_CLIENT_ID` | `"greenhouse-backend-<pid>"` | 唯一 MQTT Client ID |
| `DATA_DIR` | `"priv/data"` | DETS 持久化数据目录 |
| `CONFIG_ACK_TIMEOUT_MS` | `10000`（`:test` 环境为 `500`） | 配置下发等待 `config/ack` 的超时时间（毫秒） |

---

## 4. 编译、启动与测试（Build, Run & Test）

> 首次编译需拉取并编译 `:emqtt` 及其依赖（Windows 下会自动跳过 QUIC 原生依赖 `quicer`；无 C 编译环境的 Linux/macOS 可设置 `BUILD_WITHOUT_QUIC=1`）：
>
> ```bash
> mix deps.get
> ```

### 4.1 严格编译检查

```bash
mix compile --warnings-as-errors
```

### 4.2 本地开发启动（不连接真实 Broker）

```bash
mix run --no-halt
```

### 4.3 连接指定 MQTT Broker 启动

Linux / macOS:

```bash
MQTT_ENABLED=true \
MQTT_HOST=mqtt.example.com \
MQTT_PORT=1883 \
MQTT_USERNAME=customer-01 \
MQTT_PASSWORD=secret \
PORT=4000 \
mix run --no-halt
```

Windows PowerShell:

```powershell
$env:MQTT_ENABLED = "true"
$env:MQTT_HOST = "mqtt.example.com"
$env:MQTT_PORT = "1883"
$env:MQTT_USERNAME = "customer-01"
$env:MQTT_PASSWORD = "secret"
$env:PORT = "4000"
mix run --no-halt
```

### 4.4 生产模式启动

```bash
MIX_ENV=prod PORT=4000 MQTT_HOST=mqtt.example.com MQTT_USERNAME=customer-01 MQTT_PASSWORD=secret mix run --no-halt
```

### 4.5 运行测试与代码格式化检查

```bash
mix test --trace
mix format --check-formatted
```

---

## 5. REST API 文档

### 5.1 通用约定（CORS 与响应格式）

- **CORS 响应头**（所有响应包括错误响应与 `OPTIONS` 预检均附带）：
  - `access-control-allow-origin: *`
  - `access-control-allow-methods: GET, POST, PUT, PATCH, DELETE, OPTIONS`
  - `access-control-allow-headers: Content-Type, Authorization`
- **预检请求**：`OPTIONS *` 或任意路径的 `OPTIONS` 请求返回 `204 No Content`（空响应体）。
- **成功响应格式**：`{"ok": true, "data": ...}`（`/health` 直接在顶层返回 `status`、`mqtt`、`device_count`、`timestamp`）。
- **错误响应格式**：`{"ok": false, "error": "<error_code>", ...}`。
- **JSON 解析错误**：当 `POST`/`PUT`/`PATCH` 携带非法 JSON 或非 JSON 对象体时，返回 `400 Bad Request`：
  ```json
  {"ok": false, "error": "invalid_json"}
  ```
- **未知路由**：返回 `404 Not Found`：
  ```json
  {"ok": false, "error": "route_not_found"}
  ```

---

### 5.2 接口一览

| 方法 | 路径 | 说明 |
|---|---|---|
| `OPTIONS` | `*` / 任意路径 | CORS 预检，返回 `204 No Content` |
| `GET` | `/health` 或 `/api/v1/health` | 服务健康检查、MQTT 连接状态与设备数 |
| `POST` | `/api/v1/auth/login` | 用户名密码登录，签发会话 Token |
| `POST` | `/api/v1/auth/register` | 注册新用户并自动创建会话 |
| `POST` | `/api/v1/auth/logout` | 注销当前会话 Token |
| `GET` | `/api/v1/auth/me` | 获取当前登录用户信息（需 Bearer / `X-Session-Token`） |
| `GET` | `/api/v1/user/devices` | 获取当前用户绑定的设备快照列表（需鉴权） |
| `POST` | `/api/v1/user/devices` | 为当前用户独占绑定设备（已绑定返回 `409`） |
| `GET` | `/api/v1/user/devices/:device_id` | 获取当前用户绑定设备详情（非本人绑定返回 `403`） |
| `PATCH` | `/api/v1/user/devices/:device_id`（支持 `PUT`） | 更新当前用户设备绑定名称或备注（需鉴权） |
| `DELETE` | `/api/v1/user/devices/:device_id` | 解除当前用户的设备绑定（需鉴权） |
| `POST` | `/api/v1/dev/reset` | 重置本地演示账号与 `GH-0001` 模拟数据 |
| `GET` | `/api/v1/devices` | 获取所有已知设备概览列表 |
| `GET` | `/api/v1/devices/:device_id` | 获取单个设备完整快照（状态、最新遥测、活动告警、配置） |
| `GET` | `/api/v1/devices/:device_id/status` | 获取设备在线状态（来自 `gh/<id>/status` 或超时离线标记） |
| `GET` | `/api/v1/devices/:device_id/telemetry/latest`（别名 `.../current`） | 获取设备最新一条遥测数据 |
| `GET` | `/api/v1/devices/:device_id/telemetry/history`（别名 `.../telemetry`） | 分页查询历史遥测与区间统计 |
| `GET` | `/api/v1/devices/:device_id/telemetry/stats` | 查询指定时间范围内的遥测极值与均值统计 |
| `GET` | `/api/v1/devices/:device_id/alarms` | 查询设备告警列表（支持 `active_only=true`） |
| `POST` | `/api/v1/devices/:device_id/alarms/:code/clear`（别名 `DELETE .../alarms/:code`） | 手动解除指定告警 |
| `GET` | `/api/v1/devices/:device_id/config` | 读取设备本地缓存配置（含 `raw` 协议原值与 `human` 人类可读值） |
| `PATCH` | `/api/v1/devices/:device_id/config`（支持 `PUT`、`POST`） | 校验并通过 MQTT 下发局部配置，等待 `config/ack`（离线测试可选 `?cache_fallback=true`） |
| `POST` | `/api/v1/devices/:device_id/simulate` | 为模拟设备 `GH-0001` 触发预设场景（`normal`/`hot`/`water_lack` 等） |

---

### 5.3 接口详情与 cURL 示例

#### 1) 健康检查 `GET /health` / `GET /api/v1/health`

```bash
curl -i http://localhost:4000/api/v1/health
```

响应 `200 OK`：

```json
{
  "ok": true,
  "status": "healthy",
  "mqtt": {
    "connected": true,
    "host": "mqtt.example.com",
    "port": 1883,
    "client_id": "greenhouse-backend-1234",
    "reconnect_attempts": 0
  },
  "device_count": 2,
  "timestamp": "2026-11-14T02:45:00.123456Z"
}
```

---

#### 2) 设备列表 `GET /api/v1/devices`

```bash
curl http://localhost:4000/api/v1/devices
```

响应 `200 OK`：

```json
{
  "ok": true,
  "data": [
    {
      "device_id": "GH-0001",
      "online": true,
      "status": {
        "device_id": "GH-0001",
        "online": true,
        "up": 86400,
        "offline_reason": null,
        "updated_at": "2026-11-14T02:40:00.000Z",
        "updated_at_ms": 1794624000000
      },
      "latest_telemetry": { "...": "..." },
      "active_alarms": [],
      "active_alarm_count": 0,
      "last_seen_at": "2026-11-14T02:41:00.000Z",
      "last_seen_at_ms": 1794624060000
    }
  ]
}
```

---

#### 3) 设备详情快照 `GET /api/v1/devices/:device_id`

```bash
curl http://localhost:4000/api/v1/devices/GH-0001
```

- 成功 `200 OK`：`{"ok": true, "data": {"device_id": "GH-0001", "status": ..., "latest_telemetry": ..., "active_alarms": [...], "config": ..., "last_seen_at": ..., "last_seen_at_ms": ...}}`
- 未找到 `404 Not Found`：`{"ok": false, "error": "not_found", "message": "Device not found"}`

---

#### 4) 设备在线状态 `GET /api/v1/devices/:device_id/status`

```bash
curl http://localhost:4000/api/v1/devices/GH-0001/status
```

- 成功 `200 OK`：`{"ok": true, "data": {"device_id": "GH-0001", "online": true, "up": 86400, "offline_reason": null, ...}}`
- 未找到 `404 Not Found`：`{"ok": false, "error": "not_found", "message": "Device status not found"}`

---

#### 5) 最新遥测 `GET /api/v1/devices/:device_id/telemetry/latest`（或 `/current`）

温度 `temperature`、空气湿度 `air_humidity`、土壤湿度 `soil_humidity` 已按 PROTOCOL.md §3.1 规则除以 `100.0` 还原，并同时保留 `raw` 原始报文整数值：

```bash
curl http://localhost:4000/api/v1/devices/GH-0001/telemetry/latest
```

响应 `200 OK`：

```json
{
  "ok": true,
  "data": {
    "device_id": "GH-0001",
    "v": 1,
    "seq": 1024,
    "up": 86400,
    "temperature": 23.5,
    "air_humidity": 56.8,
    "soil_humidity": 31.2,
    "lux": 812,
    "water": 1,
    "water_sufficient": true,
    "fan": 0,
    "fan_on": false,
    "light": 1,
    "light_on": true,
    "heat": 0,
    "heat_on": false,
    "received_at": "2026-11-14T02:41:00.000Z",
    "received_at_ms": 1794624060000,
    "raw": {
      "v": 1, "seq": 1024, "up": 86400,
      "t": 2350, "ah": 5680, "sh": 3120,
      "lux": 812, "water": 1, "fan": 0, "light": 1, "heat": 0
    }
  }
}
```

- 未找到 `404 Not Found`：`{"ok": false, "error": "not_found", "message": "Telemetry not found"}`

---

#### 6) 历史遥测查询 `GET /api/v1/devices/:device_id/telemetry/history`（或 `/telemetry`）

查询参数（均为可选）：
- `from`：起始时间戳（毫秒整数或 ISO8601 字符串，如 `2026-11-14T00:00:00Z`）
- `to`：结束时间戳（毫秒整数或 ISO8601 字符串）
- `limit`：返回条数（正整数，默认 `100`，最大 `5000`；非法参数自动回退默认值）
- `offset`：偏移量（非负整数，默认 `0`；非法参数自动回退默认值）
- `order`：排序方式（`"asc"` 或 `"desc"`，默认 `"desc"`）

```bash
curl "http://localhost:4000/api/v1/devices/GH-0001/telemetry/history?from=2026-11-14T00:00:00Z&limit=50&offset=0&order=asc"
```

响应 `200 OK`：

```json
{
  "ok": true,
  "data": {
    "device_id": "GH-0001",
    "total": 120,
    "limit": 50,
    "offset": 0,
    "order": "asc",
    "items": [ "..." ],
    "stats": {
      "device_id": "GH-0001",
      "count": 120,
      "temperature": {"min": 21.0, "max": 26.5, "avg": 23.4},
      "air_humidity": {"min": 50.0, "max": 65.0, "avg": 57.2},
      "soil_humidity": {"min": 28.0, "max": 42.0, "avg": 34.1},
      "lux": {"min": 100, "max": 1200, "avg": 640.5}
    }
  }
}
```

---

#### 7) 遥测统计 `GET /api/v1/devices/:device_id/telemetry/stats`

支持可选查询参数 `from`、`to`：

```bash
curl "http://localhost:4000/api/v1/devices/GH-0001/telemetry/stats?from=1794600000000"
```

---

#### 8) 设备告警列表 `GET /api/v1/devices/:device_id/alarms`

支持可选查询参数 `active_only=true`（仅返回当前激活告警）：

```bash
curl "http://localhost:4000/api/v1/devices/GH-0001/alarms?active_only=true"
```

---

#### 9) 手动解除告警 `POST /api/v1/devices/:device_id/alarms/:code/clear`（或 `DELETE .../alarms/:code`）

```bash
curl -X POST http://localhost:4000/api/v1/devices/GH-0001/alarms/turntable_failed/clear
# 或
curl -X DELETE http://localhost:4000/api/v1/devices/GH-0001/alarms/turntable_failed
```

- 成功 `200 OK`：返回更新后的告警对象（`active: false`, `clear_reason: "manual_api"`）
- 未找到 `404 Not Found`：`{"ok": false, "error": "not_found", "message": "Alarm not found"}`

---

#### 10) 读取设备配置 `GET /api/v1/devices/:device_id/config`

```bash
curl http://localhost:4000/api/v1/devices/GH-0001/config
```

响应 `200 OK`：

```json
{
  "ok": true,
  "data": {
    "device_id": "GH-0001",
    "raw": {"tMin": 1000, "tMax": 3000, "tHys": 150},
    "human": {"tMin": 10.0, "tMax": 30.0, "tHys": 1.5},
    "updated_at": "2026-11-14T02:42:00.000Z",
    "updated_at_ms": 1794624120000
  }
}
```

---

#### 11) 修改/下发设备配置 `PATCH /api/v1/devices/:device_id/config`（支持 `PUT`、`POST`）

支持两种单位传入方式：
1. **协议原始整数单位（默认）**：温度/湿度为 `0.01` 倍整数，直接对应 PROTOCOL.md 4.3。
2. **人类可读单位（`unit=human`）**：在 URL Query 中传 `?unit=human` 或在 JSON Body 中传 `"unit": "human"`（服务端会在下发前剥离 `"unit"` 元字段，并将温度/湿度字段 `round(val * 100)` 后校验并下发协议整数）。

```bash
# 方式 1：协议原始单位（20.00℃ ~ 30.00℃，回滞 1.50℃）
curl -X PATCH http://localhost:4000/api/v1/devices/GH-0001/config \
  -H "Content-Type: application/json" \
  -d '{"tMin":2000,"tMax":3000,"tHys":150}'

# 方式 2：人类可读单位（query 参数）
curl -X PATCH "http://localhost:4000/api/v1/devices/GH-0001/config?unit=human" \
  -H "Content-Type: application/json" \
  -d '{"tMin":20.0,"tMax":30.0,"tHys":1.5}'
```

**配置下发错误码映射：**

| 场景 | HTTP 状态码 | 响应 JSON |
|---|---|---|
| 配置校验失败（范围、自洽、回滞、非整数等） | `422 Unprocessable Entity` | `{"ok":false,"error":"validation_failed","details":[...]}` |
| 设备返回 `{"ok":false,"reason":"syntax"}` | `400 Bad Request` | `{"ok":false,"error":"device_syntax_error","reason":"syntax"}` |
| 设备返回 `{"ok":false,"reason":"rejected"}` | `422 Unprocessable Entity` | `{"ok":false,"error":"device_rejected","reason":"rejected"}` |
| 等待 `config/ack` 超时（设备被标记离线） | `504 Gateway Timeout` | `{"ok":false,"error":"ack_timeout","message":"Device did not respond within timeout and was marked offline"}` |
| MQTT Broker 未连接（未开启 `cache_fallback=true`） | `503 Service Unavailable` | `{"ok":false,"error":"mqtt_disconnected","message":"MQTT broker connection is currently unavailable"}` |
| MQTT Broker 未连接且传 `?cache_fallback=true` | `200 OK` | `{"ok":true,"data":{...},"simulated_ack":true}` |
| 同设备已有配置请求正在等待回执 | `409 Conflict` | `{"ok":false,"error":"config_in_progress","message":"A configuration update is already in progress for this device"}` |
| 请求体非合法 JSON | `400 Bad Request` | `{"ok":false,"error":"invalid_json"}` |

**支持的配置字段与校验规则（PROTOCOL.md §4.3 & §4.4）：**

| 键 | 含义 | 协议单位 | 校验约束 |
|---|---|---|---|
| `tMin`, `tMax` | 温度下限 / 上限 | `0.01 ℃` | `-1000..5000`（`-10..50 ℃`），且 `tMin < tMax` |
| `tHys` | 控温回滞带宽 | `0.01 ℃` | `> 0`，且 `tHys < (tMax - tMin)` |
| `ahMin`, `ahMax` | 空气湿度下限 / 上限 | `0.01 %RH` | `0..10000`（`0..100 %RH`），且 `ahMin < ahMax` |
| `ahHys` | 空气湿度回滞带宽 | `0.01 %RH` | `> 0`，且 `ahHys < (ahMax - ahMin)` |
| `shMin`, `shMax` | 土壤湿度下限 / 上限 | `0.01 %RH` | `0..10000`，且 `shMin < shMax` |
| `luxMin`, `luxMax` | 光照下限 / 上限 | `lx` | `0..200000`，且 `luxMin < luxMax` |
| `luxOnMs` | 补光最短点亮时间 | `ms` | `0..86400000`（`<= 24 h`） |
| `dayStartMs` | 昼夜窗口起点 | `ms` | `0..86399999`（`< 24 h`） |
| `dayLenMs` | 昼夜窗口长度 | `ms` | `60000..86400000`（`1 min..24 h`） |
| `pumpMs` | 单次浇水时长 | `ms` | `1..600000`（`1 ms..10 min`） |
| `pumpIntervalMs` | 两次浇水最小间隔 | `ms` | `>= 1` 且 `>= pumpMs` |
| `pumpMaxPerDay` | 每日浇水次数上限 | 次 | `1..12` |
| `sampleMs` | 采样周期 | `ms` | `10..60000`（`10 ms..1 min`） |
| `turnPerDay` | 每日转动角度 | 度 | `> 0` 且为 `180` 的因数（`rem(180, turnPerDay) == 0`） |
| `turnMax` | 转盘最大角度 | 度 | `0..180` |
| `turnStep` | 转盘单步角度 | 度 | `1..180` 且 `<= turnMax` |
| `turnIntervalMs` | 转盘转动间隔 | `ms` | `>= 1000` |
