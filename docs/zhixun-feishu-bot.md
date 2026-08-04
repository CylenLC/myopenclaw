# zhixun 独立飞书机器人

该部署只运行一个 OpenClaw 飞书机器人和 zhixun 的统一水文 MCP。它不连接
myopenclaw 的 Hermes、Claude Code、TDAI Memory、aisecretary、repo-scanner
或现有 OpenClaw 实例。

## 服务边界

```text
飞书任意群或私聊
    │ WebSocket
    ▼
openclaw-zhixun
    │ SSE: http://zhixun-water-mcp:18201/sse
    ▼
zhixun-water-mcp
    │ HTTPS
    ▼
Waterism API
```

两个容器只加入独立的 `zhixun-bot-net`。OpenClaw 数据存放在
`~/.openclaw-zhixun`，不能与现有 `~/.openclaw` 共用。

## 服务器准备

服务器上将两个仓库放在同一个父目录：

```bash
mkdir -p /srv/agents
cd /srv/agents
git clone git@github.com:CylenLC/myopenclaw.git
git clone git@gitcode.com:dlut-water/zhixun-agent.git
cd myopenclaw
git switch feat/realtime-forecast-mcp
git -C ../zhixun-agent switch feat/realtime-forecast-mcp
```

要求：

- Docker Engine（启用 BuildKit）和 Docker Compose plugin 2.17+
- OpenClaw 镜像版本不低于 `2026.5.29`
- 服务器能够访问飞书、模型 API、Waterism API 和容器镜像/插件仓库
- 一个独立的飞书自建应用

默认构建会访问 Docker Hub 的 `python:3.12-slim` 和 PyPI。网络受限时，在
`.env.zhixun-bot` 中替换：

```dotenv
ZHIXUN_BOT_PYTHON_BASE_IMAGE=docker.m.daocloud.io/library/python:3.12-slim
ZHIXUN_BOT_PIP_INDEX_URL=https://pypi.tuna.tsinghua.edu.cn/simple
ZHIXUN_BOT_OPENCLAW_IMAGE=docker.m.daocloud.io/openclaw/openclaw:2026.7.1
```

zhixun-agent 使用纯 MCP 目录结构，必须包含：

```text
mcp_servers/water/mcp_server_unified.py
mcp_servers/water/mcp_server_realtime_forecast.py
```

MCP 镜像由 myopenclaw 中的 `docker/zhixun-bot/Dockerfile.mcp` 构建，通过
Compose 的附加构建上下文读取 zhixun-agent 源码，不依赖 zhixun-agent
仓库中的 `docker/` 目录或 Dockerfile。

镜像启动时会加载 myopenclaw 提供的 v2 兼容层，将
`/api/v2/reservoirs` 返回的 `_embedded.reservoirs[].data` 转成 MCP
需要的扁平记录，并按照接口限制使用每页 100 条。这样可以直接按水库名称
查询，不需要修改 zhixun-core 或 zhixun-agent。

新版 Core 没有河道站和雨量站的全局列表搜索接口。兼容层会在首次按这两类
站点名称查询时，遍历现有 `/api/v2/basins/{basin_id}/stations` 资源，建立
并持久化名称索引。名称唯一时自动解析成站码；同名站点不会静默选取，而是
返回候选站码与所属流域供用户确认。默认缓存 24 小时：

```dotenv
ZHIXUN_CORE_BASE_URL=https://ws.waterism.tech:8090/api/v2
ZHIXUN_REALTIME_FORECAST_BASE_URL=http://10.48.0.81:8097
ZHIXUN_REALTIME_FORECAST_TIMEOUT=120
ZHIXUN_REALTIME_FORECAST_IMAGE_TIMEOUT_MS=30000
ZHIXUN_BOT_MCP_DATA_DIR=/srv/myopenclaw-data/zhixun-water-mcp
ZHIXUN_MCP_STATION_INDEX_TTL_SECONDS=86400
ZHIXUN_MCP_STATION_INDEX_WORKERS=12
```

兼容层还会把 URL 工具与水文数据查询组合起来。查询水库、河道站、雨量站或流域
时，相应数据工具会直接返回经过 MCP URL 工具验证的 `related_page.url`，并要求
模型把它作为回复的最后一行；用户不需要在问题中另外要求“给出链接”。泛流域
概况或流域测站查询会返回 `related_pages`，按“雨情监测、风险研判”的顺序附两个
链接；有明确业务意图的流域查询只附最匹配的一个链接。

当前自动覆盖：

- 唯一命中的水库名称搜索、水库档案、库容曲线和 GeoJSON：水库详情页；
- 水库告警及时序/最新数据：对应告警页或监测页；
- 河道站详情、告警及时序/最新数据：河道监测页；
- 河道历史对比：河道历史对比页，并保留年份、日期范围和指标；
- 雨量站详情、单站旬月统计、时序和最新数据：雨量站分析页，并尽量保留
  查询时段。
- 流域概况或测站清单：雨情监测页和风险研判页；流域雨情、统计、预报、等雨量线
  或风险研判：分别对应监测、统计、预报、等雨量线或风险研判页。

`AGENTS.md` 和 `SOUL.md` 是这个专用机器人的受管策略文件。容器每次启动都会
用镜像中的版本同步到独立工作区，因此升级后不需要手工复制规则文件。

飞书应用需要启用机器人能力，并通过 WebSocket 订阅
`im.message.receive_v1`。将应用发布后，可将机器人加入任意目标群。

## 配置

```bash
cp .env.zhixun-bot.example .env.zhixun-bot
chmod 600 .env.zhixun-bot
vi .env.zhixun-bot
```

必须填写：

```dotenv
ZHIXUN_AGENT_PATH=../zhixun-agent
ZHIXUN_BOT_FEISHU_APP_ID=cli_xxx
ZHIXUN_BOT_FEISHU_APP_SECRET=xxx
ZHIXUN_BOT_MODEL_API_KEY=xxx
```

### 模型：DeepSeek V4 Pro

将 DeepSeek 平台 API Key 填入 `.env.zhixun-bot` 的
`ZHIXUN_BOT_MODEL_API_KEY`，并配置模型 ID 和 API 地址：

```dotenv
ZHIXUN_BOT_MODEL_API_KEY=你的 DeepSeek API Key
ZHIXUN_BOT_MODEL_ID=deepseek-v4-pro
ZHIXUN_BOT_MODEL_BASE_URL=https://api.deepseek.com
```

默认使用普通文本回复，不展示流式卡片底部的 `Agent`、`Model`、`Provider`
运行元信息。如需逐字流式卡片，可设置：

```dotenv
ZHIXUN_BOT_FEISHU_STREAMING=true
```

生产服务器建议设置绝对数据路径：

```dotenv
ZHIXUN_BOT_DATA_DIR=/srv/myopenclaw-data/openclaw-zhixun
```

默认只开放查询类工具。需要允许会商、调度和条目写操作时，显式设置：

```dotenv
ZHIXUN_BOT_ENABLE_WRITE_TOOLS=true
```

即使开放写工具，工作区规则仍要求机器人在执行创建、更新、删除或调度操作前
进行确认。

水文模型有两个容易混淆的入口：

- `get_basin_hydromodel`：只读查询流域已有模型，回答“某流域有哪些模型”；
- `hydromodel_list`：简报写入流程的辅助工具，为后续 `item_add` 获取
  `model_param_id`。

只读模式会隐藏 `hydromodel_list`。开启写工具后它才可见，但机器人规则仍要求
普通模型查询使用 `get_basin_hydromodel`。MCP 兼容层还修复了新版接口
`_embedded.hydromodels` 的解析，并在水库详情没有单独 `basin_id` 时使用水库站码
作为流域编码。

## 实时预报

实时预报已通过 zhixun-agent 的统一 Water MCP 注册，不需要再运行
18202 独立 MCP 端口。`zhixun-water-mcp` 容器会直接请求模型运行时：

```text
openclaw-zhixun
  └─ water_unified (SSE, container port 18201)
       └─ realtime forecast runtime (HTTP, default 10.48.0.81:8097)
```

可配置：

```dotenv
ZHIXUN_REALTIME_FORECAST_BASE_URL=http://10.48.0.81:8097
ZHIXUN_REALTIME_FORECAST_TIMEOUT=120
```

后端地址必须能从 Docker 容器内访问；如服务只监听在 Docker 宿主机，
可根据服务器网络改为 `http://host.docker.internal:8097`，Linux 上则需同时
配置 host-gateway，或直接使用宿主机在 Docker 网桥上可达的 IP。

机器人优先使用 HAL v2 工具：

- `run_all_realtime_forecasts`：严格按容器环境变量运行全部配置模型；
- `run_realtime_forecast`：运行未来 48 小时实时流量预报；
- `get_latest_realtime_forecast`：按测站、起报时间或模型查询最新结果。

兼容工具只在专门验证旧 RealTimeForecast 客户端时使用。针对碧流河水库的默认
配置为 `simplelstm`、`sms3-lag3` 和 `sms3-uhb`；`dhf` 当前未在 21401550 注册，
因此不放入默认候选集合。其他站点确已注册 `dhf` 时可通过环境变量加入。请求
全部模型时，机器人显式
调用无 `model_name` 参数的 `run_all_realtime_forecasts`，MCP 按
`ZHIXUN_REALTIME_FORECAST_MODELS` 逐个调用后端，
并返回 `attempted_models`、成功结果和逐模型错误。起报时间按北京时间传入
`YYYY-MM-DD HH:MM`。

如后端开启 `FORECAST_PLOT_ENABLED=true`，每个成功预报结果会包含
`plot.url`，例如 `/plots/21401550_simplelstm_<run_id>.png`。MCP 兼容层会自动补全为
`ZHIXUN_REALTIME_FORECAST_BASE_URL` 的完整 URL，并在工具结果的
`media_delivery.attachments` 中为每张图片返回 `media_url`。由于示例地址是
内网 HTTP，不能直接交给 OpenClaw 通用媒体加载器：其 SSRF 防护会拒绝私网地址，
飞书适配器随后会降级成 Markdown 链接。机器人改用本地
`send_forecast_images` 工具，将完整附件列表一次传入：

```json
{
  "attachments": [
    {
      "model_name": "simplelstm",
      "media_url": "http://10.48.0.81:8097/plots/21401550_simplelstm_<run_id>.png"
    }
  ]
}
```

插件只接受与 `ZHIXUN_REALTIME_FORECAST_BASE_URL` 完全同源、路径位于 `/plots/`
的图片。它先下载并校验全部图片，将字节写入权限受限的临时文件，再交给飞书
适配器逐张上传为原生 `image` 消息，最后立即删除文件。传给飞书适配器的不再是
内网 URL，所以不会触发 SSRF 链接降级。多模型结果一次传入完整列表，工具内部会
逐张发送，不会只取第一张；工具返回值不含图片、Base64、URL 或本地路径。

预报图只用于飞书出站投递，不需要再次交给模型理解。专用的
`forecast-media-hygiene` 插件会在会话落盘前删除原始 `image`/`image_url`
内容块和媒体重放元数据，只保留简短文字占位符。容器启动时还会清理旧 JSONL
会话中的图片块，并在原文件旁保留 `.pre-image-sanitize.bak` 备份。因此后续提问
不会再次把已经发送的三张预报图编码进模型上下文。配置同时启用短周期工具结果
裁剪，并把图片缩放上限设为 512 像素，作为插件未命中未知媒体格式时的安全兜底。

如果 `plot.url` 不存在，只返回数值结果，不猜测或构造图片地址。
在 zhixun-core 中需确认：

```dotenv
FORECAST_PLOT_ENABLED=true
```

## 启动

首次部署或 zhixun 代码更新后：

```bash
./scripts/start-zhixun-bot.sh --build
```

普通重启：

```bash
./scripts/start-zhixun-bot.sh
```

脚本只操作 `docker-compose.zhixun-bot.yml` 中的两个独立服务，不会启动或
重建主 `docker-compose.yml` 中的任何服务。OpenClaw 首次启动时会把官方
`@openclaw/feishu` 插件安装到独立数据目录。

## 验证

```bash
docker compose \
  --env-file .env.zhixun-bot \
  -f docker-compose.zhixun-bot.yml \
  ps
```

验证 MCP 工具发现：

```bash
docker compose \
  --env-file .env.zhixun-bot \
  -f docker-compose.zhixun-bot.yml \
  exec openclaw-zhixun \
  node /app/openclaw.mjs mcp probe water_unified --json
```

输出中应包含以下 12 个工具：

```text
realtime_forecast_health
run_all_realtime_forecasts
run_realtime_forecast
get_latest_realtime_forecast
run_realtime_forecast_compat
get_latest_realtime_forecast_compat
get_combined_forecast_timeseries
get_observed_flow_timeseries
get_gfs_forecast_timeseries
get_ifs_forecast_timeseries
get_actual_precip_compatible_timeseries
get_mswep_precip_timeseries
```

统一 MCP 共注册 70 个工具。默认只读配置过滤 15 个会商/调度/条目写工具后，
OpenClaw probe 应看到 55 个；上述 12 个实时预报工具均保留。

从 MCP 容器内验证后端健康状态：

```bash
docker compose \
  --env-file .env.zhixun-bot \
  -f docker-compose.zhixun-bot.yml \
  exec zhixun-water-mcp \
  python -c 'import asyncio, json; from mcp_server_realtime_forecast import realtime_forecast_health; print(json.dumps(asyncio.run(realtime_forecast_health()), ensure_ascii=False, indent=2))'
```

查看日志：

```bash
docker compose \
  --env-file .env.zhixun-bot \
  -f docker-compose.zhixun-bot.yml \
  logs -f openclaw-zhixun zhixun-water-mcp
```

启动日志应出现类似下面的行；数字为首次清理的历史消息数，后续正常重启应为 0：

```text
[forecast-media-hygiene] sanitized 3 image-bearing message(s) in 1 session file(s)
```

只检查当前会话目录是否仍有原始图片块（不打印图片内容）：

```bash
docker compose \
  --env-file .env.zhixun-bot \
  -f docker-compose.zhixun-bot.yml \
  exec openclaw-zhixun sh -lc \
  'grep -R -l '"'"'"type":"image"'"'"' /home/node/.openclaw/agents/zhixun-water/sessions --include="*.jsonl" 2>/dev/null | wc -l'
```

期望输出 `0`。`/reset` 仍可用于开始新会话，但清除预报图片上下文不再依赖它。

在任意已加入机器人的群中 `@机器人` 并发送：

```text
列出当前可查询的流域和站点类型。
```

机器人会响应任意私聊，也会响应任意已加入机器人的群；为避免群内每条消息都
触发，群聊仍必须 `@机器人`。

### 飞书端测试问题

以下问题从基础连通、单模型、多模型、历史结果到输入时序逐层覆盖。
群聊时在每句前加 `@知汛助手`：

1. `请检查实时预报服务是否健康，列出已注册测站和模型状态。`
2. `请对测站 21401550 运行起报时间为 2026-04-17 14:00 的 simplelstm 实时预报，汇报洪峰流量、洪峰时间、预报时段和 run_id。`
3. `请对碧流河水库（21401550）以 2026-08-04 20:00 为起报时间运行全部可用模型。必须调用 run_all_realtime_forecasts，列出 attempted_models，并逐一给出 simplelstm、sms3-lag3、sms3-uhb 的成功结果或失败原因；比较洪峰流量和洪峰时间，不要取平均；每个成功模型都发送一张原生降雨径流过程图，不要输出 Markdown 图片或网址。`
4. `查询测站 21401550 最新的 dhf 实时预报结果，说明它的起报时间、洪峰和数据来源。`
5. `查询测站 21401550 在 2026-04-17 14:00 起报的最新预报，将各模型结果分开列出，并单独列出 errors。`
6. `获取流域 21401550 从 2026-04-01 到 2026-04-11 的 48 小时合并时序，说明 obs、GFS、IFS、MSWEP 和实测流量各有多少个时次。`
7. `查询测站 21401550 从 2026-04-01 到 2026-04-11 的实测入库流量 inq 时序，给出时间范围、最小值、最大值及对应时间。`
8. `分别查询流域 21401550 在 2026-04-01 到 2026-04-11 的 GFS 和 IFS 48 小时降雨预报时序，对比同一时次的差异。`
9. `查询测站 21401550 在 2026-04-17 14:00 这一时次的 MSWEP 3 小时面均降雨。`
10. `查询测站 21401550 从 2026-04-01 到 2026-04-11 的 MSWEP 面均降雨区间时序，汇总累计降雨量和最大 3 小时降雨。`
11. `请尝试用不支持的模型 xgboost 对测站 21401550 运行实时预报，不要自动替换模型，说明参数错误。`
12. `请用旧 RealTimeForecast 兼容接口查询测站 21401550 的最新 simplelstm 结果，并说明返回结构与 HAL v2 的差别。`

第 2–10 题应使用 HAL 或时序工具；第 12 题因明确要求旧接口，才应调用
`get_latest_realtime_forecast_compat`。第 11 题应返回支持的模型范围，不应静默改成
`simplelstm` 或 `dhf`。

## 停止与更新

停止：

```bash
docker compose \
  --env-file .env.zhixun-bot \
  -f docker-compose.zhixun-bot.yml \
  down
```

更新：

```bash
git -C ../zhixun-agent fetch origin
git -C ../zhixun-agent switch feat/realtime-forecast-mcp
git -C ../zhixun-agent pull --ff-only origin feat/realtime-forecast-mcp
git fetch origin
git switch feat/realtime-forecast-mcp
git pull --ff-only origin feat/realtime-forecast-mcp
./scripts/start-zhixun-bot.sh --build
```

## 安全说明

- `.env.zhixun-bot` 已被 `.gitignore` 排除，不要提交真实凭据。
- OpenClaw 容器不挂载 Docker socket、宿主机代码目录或现有 Agent 数据。
- MCP 端口和 OpenClaw Gateway 端口均不发布到宿主机。
- 飞书机器人可被加入任意群，并接受所有私聊；群内仍要求 `@机器人`。这会让
  所有可联系或拉入机器人的飞书用户调用 zhixun MCP，请仅向信任的组织成员发布。
- OpenClaw 工具策略只允许 `bundle-mcp` 和只能向当前可信会话发送预报图的
  `send_forecast_images`；通用 `message` 不开放，防止模型再次把内网 URL 交给
  会降级为链接的旧链路。飞书
  文档、云盘、知识库、群管理等原生工具全部关闭。
- 如果服务器需要跨主机访问 MCP，应增加 TLS 和认证；当前配置只支持同一
  Docker 网络内访问。
