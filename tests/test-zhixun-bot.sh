#!/usr/bin/env bash
# Static tests only: this script never starts containers.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

pass() {
  echo "✅ $1"
}

cd "${REPO_ROOT}"

bash -n scripts/start-zhixun-bot.sh
sh -n docker/zhixun-bot/entrypoint.sh
node --check docker/zhixun-bot/render-config.mjs
node --check docker/zhixun-bot/sanitize-forecast-session-images.mjs
node --check docker/zhixun-bot/plugins/forecast-media-hygiene/index.js
grep -q 'Every successful reservoir, river-station, rainfall-station, or basin query' openclaw-zhixun/workspace/AGENTS.md
grep -q 'related_page.url' openclaw-zhixun/workspace/AGENTS.md
grep -q "never construct or guess a URL" openclaw-zhixun/workspace/AGENTS.md
grep -q 'Always reply in Simplified Chinese' openclaw-zhixun/workspace/AGENTS.md
grep -q 'Always answer users only in Simplified Chinese' openclaw-zhixun/workspace/SOUL.md
grep -q '所有发送到飞书的用户可见文字必须使用简体中文' openclaw-zhixun/workspace/AGENTS.md
grep -q 'cp "${source_file}" "${target_file}"' docker/zhixun-bot/entrypoint.sh
grep -q 'sanitize-forecast-session-images.mjs' docker/zhixun-bot/entrypoint.sh
grep -q 'MCP 容器模型配置与 .env.zhixun-bot 不一致' scripts/start-zhixun-bot.sh
pass "shell and Node syntax"

node --input-type=module - <<'JS'
import assert from "node:assert/strict";
import { mkdtemp, readdir, rm } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import plugin, {
  IMAGE_PLACEHOLDER,
  createForecastImageTool,
  extractMediaAttachments,
  isForecastTool,
  parseTrustedPlotUrl,
  sanitizeForecastMediaMessage,
  stripEnglishReasoningPreamble,
  stripForecastMediaLinks,
} from "./docker/zhixun-bot/plugins/forecast-media-hygiene/index.js";
import { sanitizeTranscriptText } from "./docker/zhixun-bot/sanitize-forecast-session-images.mjs";

let beforeMessageWrite;
let messageSending;
let messageReceived;
let afterToolCall;
plugin.register({
  on(name, handler) {
    if (name === "before_message_write") {
      beforeMessageWrite = handler;
    }
    if (name === "message_sending") {
      messageSending = handler;
    }
    if (name === "message_received") messageReceived = handler;
    if (name === "after_tool_call") afterToolCall = handler;
  },
});
assert.equal(typeof beforeMessageWrite, "function");
assert.equal(typeof messageSending, "function");
assert.equal(typeof messageReceived, "function");
assert.equal(typeof afterToolCall, "function");
assert.equal(isForecastTool("mcp__water_unified__run_all_realtime_forecasts"), true);
assert.equal(isForecastTool("get_station_timeseries"), false);

const imageMessage = {
  role: "toolResult",
  content: [
    { type: "text", text: "sent" },
    { type: "image", data: "a".repeat(100_000), mimeType: "image/png" },
    { type: "image_url", image_url: { url: "data:image/png;base64,AAAA" } },
  ],
  media: [{ url: "http://forecast/plot.png" }],
  images: ["raw"],
  __openclaw: {
    media: [{ kind: "image", url: "http://forecast/plot.png" }],
    mediaImageBlockFactIndexes: [0],
    mediaImageLayout: [0],
    keep: "value",
  },
};
const sanitized = sanitizeForecastMediaMessage(imageMessage);
assert.equal(sanitized.changed, true);
assert.deepEqual(
  sanitized.message.content,
  [{ type: "text", text: "sent" }, { type: "text", text: IMAGE_PLACEHOLDER }],
);
assert.equal("media" in sanitized.message, false);
assert.equal("images" in sanitized.message, false);
assert.deepEqual(sanitized.message.__openclaw, {
  keep: "value",
  mediaImagePruned: true,
});
assert.deepEqual(beforeMessageWrite({ message: imageMessage }).message, sanitized.message);

const textMessage = { role: "assistant", content: [{ type: "text", text: "中文结果" }] };
assert.equal(sanitizeForecastMediaMessage(textMessage).changed, false);
assert.equal(beforeMessageWrite({ message: textMessage }), undefined);

const transcript = `${JSON.stringify({ type: "message", message: imageMessage })}\n${JSON.stringify({ type: "message", message: textMessage })}\n`;
const migrated = sanitizeTranscriptText(transcript);
assert.equal(migrated.changedMessages, 1);
assert.equal(migrated.text.includes("data:image"), false);
assert.equal(migrated.text.includes('"type":"image"'), false);
assert.equal(migrated.text.includes(IMAGE_PLACEHOLDER), true);

assert.equal(
  parseTrustedPlotUrl(
    "http://10.48.0.81:8097/plots/21401550_simplelstm_run.png",
    "http://10.48.0.81:8097",
  ).pathname,
  "/plots/21401550_simplelstm_run.png",
);
const leakedReasoning = "I need to re-query both parts in this current turn.\nLet me report the data verbatim.\n\n碧流河水库本轮预报如下。";
assert.deepEqual(stripEnglishReasoningPreamble(leakedReasoning), {
  content: "碧流河水库本轮预报如下。",
  changed: true,
});
assert.deepEqual(messageSending({ content: leakedReasoning }), {
  content: "碧流河水库本轮预报如下。",
});
assert.throws(
  () => parseTrustedPlotUrl("http://127.0.0.1:8097/plots/private.png", "http://10.48.0.81:8097"),
  /拒绝下载非实时预报服务同源/,
);
const visibleForecastText = [
  "数值预报结果仍然保留。",
  "[http://10.48.0.81:8097/plots/21401550_simplelstm_run.png](http://10.48.0.81:8097/plots/21401550_simplelstm_run.png)",
].join("\n");
const stripped = stripForecastMediaLinks(
  visibleForecastText,
  "http://10.48.0.81:8097",
);
assert.equal(stripped.changed, true);
assert.equal(stripped.content, "数值预报结果仍然保留。");
process.env.ZHIXUN_REALTIME_FORECAST_BASE_URL = "http://10.48.0.81:8097";
assert.deepEqual(messageSending({ content: visibleForecastText }), {
  content: "数值预报结果仍然保留。",
});
assert.equal(
  messageSending({ content: "普通链接：https://example.com/report" }),
  undefined,
);
assert.equal(
  messageSending({
    content: "http://10.48.0.81:8097/plots/21401550_simplelstm_run.png",
  }).cancel,
  true,
);

const png = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10, 0, 0, 0, 0]);
const mediaDir = await mkdtemp(path.join(os.tmpdir(), "forecast-native-media-test-"));
const sendCalls = [];
const mockApi = {
  config: { channels: { feishu: { enabled: true } } },
  logger: { info() {} },
  runtime: {
    channel: {
      outbound: {
        async loadAdapter(channel) {
          assert.equal(channel, "feishu");
          return {
            async sendMedia(params) {
              sendCalls.push(params);
              assert.equal(params.mediaUrl.startsWith(mediaDir), true);
              assert.equal(params.mediaUrl.startsWith("http"), false);
              assert.deepEqual(params.mediaLocalRoots, [mediaDir]);
              assert.equal(params.to, "oc_current_chat");
              assert.equal(params.text, "");
              assert.equal((await readdir(mediaDir)).length > 0, true);
              return { channel: "feishu", messageId: `msg-${sendCalls.length}` };
            },
          };
        },
      },
    },
  },
};
const toolContext = {
  deliveryContext: {
    channel: "feishu",
    to: "oc_current_chat",
    accountId: "default",
    threadId: "thread-current",
  },
  runtimeConfig: mockApi.config,
};
const tool = createForecastImageTool(mockApi, toolContext, {
  baseUrl: "http://10.48.0.81:8097",
  mediaDir,
  async fetchImpl(url, options) {
    assert.equal(url.origin, "http://10.48.0.81:8097");
    assert.equal(options.redirect, "manual");
    return new Response(png, { status: 200, headers: { "content-type": "image/png" } });
  },
});
assert.equal(tool.name, "send_forecast_images");
const attachments = ["simplelstm", "sms3-lag3", "sms3-uhb"].map((model) => ({
  model_name: model,
  media_url: `http://10.48.0.81:8097/plots/21401550_${model}_run.png`,
}));
assert.deepEqual(extractMediaAttachments({ content: [{ type: "text", text: JSON.stringify({ media_delivery: { attachments } }) }] }), attachments);
const sendResult = await tool.execute("call-1", { attachments });
assert.equal(sendCalls.length, 3);
assert.deepEqual(sendResult.details.sent_models, ["simplelstm", "sms3-lag3", "sms3-uhb"]);
assert.equal(sendResult.details.sent_count, 3);
assert.equal(sendResult.details.delivery, "feishu_native_image");
assert.equal(sendResult.content[0].text.includes("http://"), false);
assert.deepEqual(await readdir(mediaDir), []);

const unsafeTool = createForecastImageTool(mockApi, toolContext, {
  baseUrl: "http://10.48.0.81:8097",
  mediaDir,
  async fetchImpl() {
    throw new Error("unsafe URL must be rejected before fetch");
  },
});
await assert.rejects(
  unsafeTool.execute("call-2", {
    attachments: [{ model_name: "bad", media_url: "http://127.0.0.1/plots/bad.png" }],
  }),
  /拒绝下载非实时预报服务同源/,
);
assert.equal(sendCalls.length, 3);
const unavailableChannelTool = createForecastImageTool(mockApi, { deliveryContext: { channel: "telegram" } });
assert.equal(unavailableChannelTool.name, "send_forecast_images");
await assert.rejects(unavailableChannelTool.execute("call-telegram", { attachments }), /飞书投递目标/);
const contextFromFeishuRuntime = createForecastImageTool(mockApi, {
  messageChannel: "feishu",
  nativeChannelId: "oc_runtime_chat",
});
assert.equal(contextFromFeishuRuntime.name, "send_forecast_images");

const automaticHooks = {};
const automaticApi = {
  ...mockApi,
  logger: { info() {}, error(message) { throw new Error(message); } },
  on(name, handler) { automaticHooks[name] = handler; },
};
plugin.register(automaticApi);
process.env.ZHIXUN_FORECAST_MEDIA_DIR = mediaDir;
const originalFetch = globalThis.fetch;
globalThis.fetch = async () => new Response(png, {
  status: 200,
  headers: { "content-type": "image/png" },
});
automaticHooks.message_received(
  { from: "ou_sender", sessionKey: "session-1" },
  { channelId: "feishu", conversationId: "oc_current_chat", sessionKey: "session-1" },
);
await automaticHooks.after_tool_call(
  {
    toolName: "mcp__water_unified__run_all_realtime_forecasts",
    toolCallId: "forecast-call-1",
    result: { details: { media_delivery: { attachments } } },
  },
  { sessionKey: "session-1" },
);
globalThis.fetch = originalFetch;
assert.equal(sendCalls.length, 6);
await rm(mediaDir, { recursive: true, force: true });
JS
pass "forecast images use trusted local bytes and stay out of model context"

docker compose \
  --env-file .env.zhixun-bot.example \
  -f docker-compose.zhixun-bot.yml \
  config --format json > "${TMP_DIR}/compose.json"

python3 - "${TMP_DIR}/compose.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    config = json.load(stream)

services = config["services"]
assert set(services) == {"openclaw-zhixun", "zhixun-water-mcp"}
assert set(config["networks"]) == {"zhixun-bot-net"}

mcp = services["zhixun-water-mcp"]
build = mcp["build"]
assert build["context"].endswith("/docker/zhixun-bot")
assert build["dockerfile"] == "Dockerfile.mcp"
assert build["additional_contexts"]["zhixun_src"].endswith("/zhixun-agent")
assert build["args"]["PYTHON_BASE_IMAGE"] == "docker.m.daocloud.io/library/python:3.12-slim"
assert build["args"]["PIP_INDEX_URL"] == "https://pypi.tuna.tsinghua.edu.cn/simple"
assert mcp["working_dir"] == "/app/mcp_servers/water"
assert mcp["command"][:2] == ["python", "mcp_entrypoint.py"]
assert mcp["environment"]["ZHIXUN_CORE_BASE_URL"] == "https://ws.waterism.tech:8090/api/v2"
assert mcp["environment"]["ZHIXUN_REALTIME_FORECAST_BASE_URL"] == "http://10.48.0.81:8097"
assert mcp["environment"]["ZHIXUN_REALTIME_FORECAST_TIMEOUT"] == "120"
assert mcp["environment"]["ZHIXUN_REALTIME_FORECAST_MODELS"] == "simplelstm,sms3-lag3,sms3-uhb"
assert mcp["environment"]["ZHIXUN_MCP_STATION_INDEX_PATH"] == "/var/lib/zhixun-water-mcp/station-index.json"
assert mcp["environment"]["ZHIXUN_MCP_STATION_INDEX_TTL_SECONDS"] == "86400"
assert mcp["environment"]["ZHIXUN_MCP_STATION_INDEX_WORKERS"] == "12"
assert mcp["volumes"][0]["target"] == "/var/lib/zhixun-water-mcp"

for service in services.values():
    assert "ports" not in service
    assert set(service["networks"]) == {"zhixun-bot-net"}

bot = services["openclaw-zhixun"]
assert bot["environment"]["ZHIXUN_REALTIME_FORECAST_BASE_URL"] == "http://10.48.0.81:8097"
assert bot["environment"]["ZHIXUN_REALTIME_FORECAST_IMAGE_TIMEOUT_MS"] == "30000"

mounts = services["openclaw-zhixun"]["volumes"]
sources = {mount["source"] for mount in mounts}
assert any(source.endswith(".openclaw-zhixun") for source in sources)
assert all(not source.endswith("/.openclaw") for source in sources)
assert all("docker.sock" not in source for source in sources)
PY
pass "Compose build source and service isolation"

python3 - <<'PY'
import importlib.util
import os
import tempfile
from pathlib import Path
from types import SimpleNamespace

module_path = Path("docker/zhixun-bot/zhixun_core_v2_compat.py")
spec = importlib.util.spec_from_file_location("zhixun_core_v2_compat", module_path)
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)

reservoir_payload = {
    "_embedded": {
        "reservoirs": [
            {"data": {"stcd": "21100150", "stnm": "大伙房水库"}},
            {"data": {"stcd": "10310500", "stnm": "红花尔基"}},
        ]
    }
}
assert compat.extract_collection_items(reservoir_payload, "/reservoirs") == [
    {"stcd": "21100150", "stnm": "大伙房水库"},
    {"stcd": "10310500", "stnm": "红花尔基"},
]

calls = []
basin_payloads = {
    "/basins/21100150/stations": {
        "_embedded": {
            "stations": [
                {"data": {"stcd": "21103500", "stnm": "占贝", "sttype": "ZQ"}},
                {"data": {"stcd": "21120032", "stnm": "石庙子", "sttype": "PP"}},
                {"data": {"stcd": "21103250", "stnm": "四道河子", "sttype": "ZQ"}},
            ]
        }
    },
    "/basins/10310500/stations": {
        "_embedded": {
            "stations": [
                {"data": {"stcd": "21103257", "stnm": "四道河子", "sttype": "ZQ"}},
            ]
        }
    },
}

def fake_api_get(endpoint, params=None):
    calls.append((endpoint, params))
    if endpoint == "/reservoirs":
        query = str((params or {}).get("q") or "")
        if query:
            matches = [
                item
                for item in reservoir_payload["_embedded"]["reservoirs"]
                if query in item["data"]["stnm"]
            ]
            return {"_embedded": {"reservoirs": matches}}
        return reservoir_payload
    return basin_payloads[endpoint]

utils = SimpleNamespace(
    _CACHED_BY_TYPE={},
    _CACHED_NAME_TO_ID={},
    _CACHED_IDS_BY_NAME={},
    _CACHED_INFO_BY_ID={},
    _CACHE_INIT_ATTEMPTED=False,
    _STATION_TYPE_APIS={
        "水库站": "/reservoirs",
        "河道站": "/rivers",
        "雨量站": "/rainstations",
    },
    _api_get=fake_api_get,
    _require_non_empty=lambda name, value: str(value),
    get_station_id=lambda name, station_type=None: "21100150",
    logger=SimpleNamespace(
        info=lambda message: None,
        warning=lambda message: None,
    ),
)
with tempfile.TemporaryDirectory() as cache_dir:
    os.environ["ZHIXUN_MCP_STATION_INDEX_PATH"] = str(Path(cache_dir) / "stations.json")
    os.environ["ZHIXUN_MCP_STATION_INDEX_WORKERS"] = "2"
    compat.install(utils)
    utils._init_station_caches()
    assert calls == [("/reservoirs", {"page": 1, "size": 100})]
    assert utils._CACHED_BY_TYPE["水库站"]["大伙房水库"] == "21100150"

    assert utils.get_station_id("占贝", "河道站") == "21103500"
    assert utils.get_station_id("占贝河道站", "河道站") == "21103500"
    assert utils.get_station_id("占贝") == "21103500"
    assert utils.get_station_id("石庙子", "雨量站") == "21120032"
    assert utils.get_station_id("21103500", "河道站") == "21103500"
    assert Path(os.environ["ZHIXUN_MCP_STATION_INDEX_PATH"]).is_file()

    try:
        utils.get_station_id("四道河子", "河道站")
    except ValueError as exc:
        assert "匹配到多个站点" in str(exc)
        assert "21103250" in str(exc)
        assert "21103257" in str(exc)
    else:
        raise AssertionError("duplicate river name must be rejected")
PY
pass "zhixun-core v2 station-name index compatibility"

python3 - <<'PY'
import importlib.util
import sys
from pathlib import Path
from types import SimpleNamespace

module_path = Path("docker/zhixun-bot/briefing_compat.py")
spec = importlib.util.spec_from_file_location("briefing_compat", module_path)
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)

payload = {
    "_embedded": {
        "hydromodels": [
            {
                "model_id": "2e4f2084-1d9e-4c25-8a67-80f3c55c42a3",
                "model_name": "DHF",
                "model_type": "DHF",
                "plcd": "DHF方案180",
                "calibrated": True,
            }
        ]
    }
}
assert compat.extract_hydromodels(payload)[0]["model_name"] == "DHF"

async def hydromodel_list(stcd):
    """legacy briefing model list"""
    return stcd

briefing_module = SimpleNamespace(
    get_entry=lambda stcd: None,
    hydromodel_list=hydromodel_list,
)
bridge = SimpleNamespace(get_module=lambda: briefing_module)
registry = SimpleNamespace(
    _get_reservoir=lambda stcd: {"stcd": stcd, "stnm": "大伙房水库"},
    _api_get=lambda path: payload,
    _get_basin_models=lambda basin_id: [],
    get_entry=lambda stcd: None,
)
previous_registry = sys.modules.get("forecast_registry")
sys.modules["forecast_registry"] = registry
try:
    compat.install(bridge)
    entry = briefing_module.get_entry("21100150")
    assert entry["model_names"] == ["DHF"]
    assert entry["model_names_norm"] == {"DHF"}
    assert entry["plcd_list"] == ["DHF方案180"]
    assert entry["model_count"] == 1
    assert registry._get_basin_models("21100150")[0]["model_name"] == "DHF"
    assert "get_basin_hydromodel" in briefing_module.hydromodel_list.__doc__
finally:
    if previous_registry is None:
        del sys.modules["forecast_registry"]
    else:
        sys.modules["forecast_registry"] = previous_registry
PY
grep -q 'briefing_compat.py' docker/zhixun-bot/Dockerfile.mcp
grep -q 'install_briefing_compat' docker/zhixun-bot/mcp_entrypoint.py
grep -q 'realtime_forecast_compat.py' docker/zhixun-bot/Dockerfile.mcp
grep -q 'install_realtime_forecast_compat' docker/zhixun-bot/mcp_entrypoint.py
grep -q 'install_all_points_contract' docker/zhixun-bot/mcp_entrypoint.py
pass "briefing hydromodel v2 compatibility and routing guidance"

grep -q 'mcp_server_realtime_forecast.py' scripts/start-zhixun-bot.sh
grep -q 'run_realtime_forecast' openclaw-zhixun/workspace/AGENTS.md
grep -q 'run_all_realtime_forecasts' openclaw-zhixun/workspace/AGENTS.md
grep -q 'get_latest_realtime_forecast' openclaw-zhixun/workspace/AGENTS.md
grep -q 'get_combined_forecast_timeseries' openclaw-zhixun/workspace/AGENTS.md
grep -q 'sms3-uhb' openclaw-zhixun/workspace/AGENTS.md
grep -q 'Never claim that a model succeeded' openclaw-zhixun/workspace/AGENTS.md
grep -q 'delivered automatically by the channel plugin' openclaw-zhixun/workspace/AGENTS.md
grep -q "Never emit English progress narration" openclaw-zhixun/workspace/AGENTS.md
grep -q 'never invent an image URL' openclaw-zhixun/workspace/AGENTS.md
grep -q 'intentionally has no' openclaw-zhixun/workspace/AGENTS.md
grep -q 'Do not call or mention' openclaw-zhixun/workspace/AGENTS.md
grep -q 'attempted_models' openclaw-zhixun/workspace/AGENTS.md
grep -q '不得使用此前轮次' openclaw-zhixun/workspace/AGENTS.md
grep -q '逐个时间点' openclaw-zhixun/workspace/AGENTS.md
grep -q '超出返回的预报时段' openclaw-zhixun/workspace/AGENTS.md
grep -q '计划句' openclaw-zhixun/workspace/AGENTS.md
grep -q 'mode="full"' openclaw-zhixun/workspace/AGENTS.md
grep -q 'The model does not invoke this handler' openclaw-zhixun/workspace/SOUL.md
pass "realtime forecast deployment contract and agent routing"

python3 - <<'PY'
import asyncio
from datetime import datetime, timedelta
import importlib.util
import json
import os
from pathlib import Path
from types import SimpleNamespace

module_path = Path("docker/zhixun-bot/realtime_forecast_compat.py")
spec = importlib.util.spec_from_file_location("realtime_forecast_compat", module_path)
compat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(compat)

try:
    compat._validate_run_reference_time(
        {"data": {"reference_time": "2026-08-06 02:00:00"}},
        "2026-08-05 00:00",
        "2026-08-05 02:00",
    )
except RuntimeError as exc:
    assert "相差 24 小时" in str(exc)
else:
    raise AssertionError("跨日错误起报时间必须被拒绝")
valid_time = compat._validate_run_reference_time(
    {"data": {"reference_time": "2026-08-05 02:00:00"}},
    "2026-08-05 00:00",
    "2026-08-05 02:00",
)
assert valid_time["reference_time_validation"]["valid"] is True
assert compat._align_run_reference_time("2026-08-05 00:00") == "2026-08-05 02:00"
assert compat._align_run_reference_time("2026-08-05 23:01") == "2026-08-06 02:00"

calls = []
reference_calls = []

async def run_realtime_forecast(
    station_id, reference_time=None, model_name=None, source="api"
):
    calls.append(model_name)
    reference_calls.append(reference_time)
    return {
        "data": {
            "reference_time": reference_time,
            "results": [
                {
                    "station_id": station_id,
                    "model_name": model_name,
                    "peak_m3s": 1.0,
                    "forecast": [
                        {
                            "time": (
                                datetime(2026, 8, 4, 20) + timedelta(hours=index * 3)
                            ).strftime("%Y-%m-%d %H:%M:%S"),
                            "lead_hours": index * 3,
                            "pred_m3s": float(index),
                        }
                        for index in range(16)
                    ],
                    "plot": {
                        "file_path": f"/tmp/{model_name}.png",
                        "url": f"/plots/{station_id}_{model_name}_run.png",
                    },
                }
            ],
            "errors": [],
        },
        "_links": {"self": {"href": "/api/v2/realtime-forecasts/runs"}},
    }

async def get_latest_realtime_forecast(
    station_id, reference_time=None, model_name=None
):
    return await run_realtime_forecast(station_id, reference_time, model_name)

async def get_observed_flow_timeseries(start_time, end_time, station_id="21401550"):
    return {
        "station_id": station_id,
        "start_time": start_time,
        "end_time": end_time,
        "count": 3,
        "data": [
            {"time": "2026-08-01 00:00:00", "inq": 1.1},
            {"time": "2026-08-01 03:00:00", "inq": 1.2},
            {"time": "2026-08-01 06:00:00", "inq": 1.3},
        ],
    }

bridge = SimpleNamespace(
    _validate_model_name=lambda value: value,
    run_realtime_forecast=run_realtime_forecast,
    get_latest_realtime_forecast=get_latest_realtime_forecast,
    get_observed_flow_timeseries=get_observed_flow_timeseries,
)

os.environ["ZHIXUN_REALTIME_FORECAST_MODELS"] = (
    "simplelstm,dhf,sms3-lag3,sms3-uhb"
)
compat.install(bridge, "http://10.48.0.81:8097")

assert bridge._validate_model_name("all") == "all"
assert bridge._validate_model_name("sms3-uhb") == "sms3-uhb"
assert "model_name='all'" in bridge.run_realtime_forecast.__doc__
assert "model_name" not in str(
    __import__("inspect").signature(bridge.run_all_realtime_forecasts)
)

async def main():
    result = await bridge.run_realtime_forecast(
        station_id="21401550",
        reference_time="2026-08-04 20:00",
        model_name="all",
    )
    assert calls == ["simplelstm", "dhf", "sms3-lag3", "sms3-uhb"]
    assert result["data"]["attempted_models"] == calls
    assert [row["model_name"] for row in result["data"]["results"]] == calls
    summary = result["data"]["execution_summary"]
    assert summary["attempted_count"] == 4
    assert summary["successful_count"] == 4
    assert summary["failed_count"] == 0
    assert summary["successful_models"] == calls
    delivery = result["media_delivery"]
    runtime = result["realtime_forecast_mcp_runtime"]
    assert runtime["compat_version"] == "2026-08-05-aligned-native-image-v4"
    assert runtime["configured_models"] == calls
    assert runtime["requested_model_name"] == "all"
    assert delivery["method"] == "automatic_feishu_image"
    assert delivery["attachment_count"] == 4
    attachments = delivery["attachments"]
    assert [item["model_name"] for item in attachments] == calls
    assert all(
        item["media_url"].startswith("http://10.48.0.81:8097/plots/")
        for item in attachments
    )
    assert all(set(item) == {"model_name", "media_url"} for item in attachments)
    assert all("url" not in row["plot"] for row in result["data"]["results"])
    assert all(row["plot"]["media_attachment"] == "available" for row in result["data"]["results"])
    point_contract = result["time_series_response_contract"]
    assert point_contract["must_list_every_point"] is True
    assert [item["point_count"] for item in point_contract["returned_series"]] == [16, 16, 16, 16]
    json.dumps(result, ensure_ascii=False)

asyncio.run(main())

async def midnight_alignment_main():
    calls.clear()
    reference_calls.clear()
    result = await bridge.run_all_realtime_forecasts(
        station_id="21401550",
        reference_time="2026-08-05 00:00",
    )
    assert reference_calls == ["2026-08-05 02:00"] * 4
    assert result["data"]["reference_time"] == "2026-08-05 02:00"
    validation = result["reference_time_validation"]
    assert validation["requested_reference_time"] == "2026-08-05 00:00"
    assert validation["effective_reference_time"] == "2026-08-05 02:00"
    assert validation["valid"] is True
    assert result["media_delivery"]["attachment_count"] == 4

asyncio.run(midnight_alignment_main())

async def dedicated_all_main():
    calls.clear()
    result = await bridge.run_all_realtime_forecasts(
        station_id="21401550",
        reference_time="2026-08-04 20:00",
    )
    assert calls == ["simplelstm", "dhf", "sms3-lag3", "sms3-uhb"]
    assert result["realtime_forecast_mcp_runtime"]["requested_model_name"] == "all"

asyncio.run(dedicated_all_main())

async def observed_points_main():
    result = await bridge.get_observed_flow_timeseries(
        start_time="2026-08-01",
        end_time="2026-08-04",
        station_id="21401550",
    )
    contract = result["time_series_response_contract"]
    assert contract["version"] == "all-points-v1"
    assert contract["tool_name"] == "get_observed_flow_timeseries"
    assert contract["returned_series"] == [
        {
            "path": "data",
            "point_count": 3,
            "time_fields": ["time"],
            "value_fields": ["inq"],
        }
    ]
    assert "逐点完整列出" in bridge.get_observed_flow_timeseries.__doc__

asyncio.run(observed_points_main())

partial_calls = []

async def run_with_dhf_failure(
    station_id, reference_time=None, model_name=None, source="api"
):
    partial_calls.append(model_name)
    if model_name == "dhf":
        raise RuntimeError(
            "实时预报服务返回 HTTP 404: '模型 dhf 未在站点 21401550 注册'"
        )
    return await run_realtime_forecast(
        station_id, reference_time, model_name, source
    )

partial_bridge = SimpleNamespace(
    _validate_model_name=lambda value: value,
    run_realtime_forecast=run_with_dhf_failure,
)
compat.install(partial_bridge, "http://10.48.0.81:8097")

async def partial_main():
    result = await partial_bridge.run_realtime_forecast(
        station_id="21401550",
        reference_time="2026-08-04 20:00",
        model_name="all",
    )
    summary = result["data"]["execution_summary"]
    assert partial_calls == ["simplelstm", "dhf", "sms3-lag3", "sms3-uhb"]
    assert summary["attempted_count"] == 4
    assert summary["successful_models"] == [
        "simplelstm", "sms3-lag3", "sms3-uhb"
    ]
    assert summary["failed_models"] == ["dhf"]
    assert result["media_delivery"]["attachment_count"] == 3
    assert [
        item["model_name"]
        for item in result["media_delivery"]["attachments"]
    ] == ["simplelstm", "sms3-lag3", "sms3-uhb"]

asyncio.run(partial_main())
PY
pass "all-model expansion and per-model Feishu media attachments"

python3 - <<'PY'
import asyncio
import importlib.util
from pathlib import Path
from types import SimpleNamespace

module_path = Path("docker/zhixun-bot/related_page_compat.py")
spec = importlib.util.spec_from_file_location("related_page_compat", module_path)
related = importlib.util.module_from_spec(spec)
spec.loader.exec_module(related)

async def get_reservoir_profile(
    include, stcd="", reservoir_name="", storage_curve_info_only=False,
    warning_start_time="", warning_stop_time=""
):
    return {"stcd": stcd or "21100150", "stnm": reservoir_name or "大伙房水库"}

async def list_reservoirs(
    page=1, size=20, keyword="", region="", warning_type="",
    start_time="", stop_time=""
):
    return {
        "reservoirs": (
            [{"stcd": "21100150", "stnm": "大伙房水库"}] if keyword else []
        )
    }

async def get_river_station_detail(station_name):
    return {"stcd": "21103500", "stnm": station_name}

async def get_river_warning_status(station_name, start_time, stop_time, mode="both"):
    return {"stcd": "21103500", "station_name": station_name}

async def get_river_historical_comparison(
    station_name, year1, year2, start_date, stop_date, metric
):
    return {"stcd": "21103500", "station_name": station_name}

async def get_rainstation_detail(station_name):
    return {"stcd": "21120032", "stnm": station_name}

async def get_rainfall_statistics(
    scope, name, period_type, year, compare_year=None, include_average=True, months=None
):
    if scope == "basin":
        return {"scope": scope, "basin_id": "21100150", "basin_name": name}
    return {"scope": scope, "stcd": "21120032", "station_name": name}

async def get_basin_stations(basin_name, relation="all"):
    return {"basin_id": "21100150", "basin_name": basin_name}

async def get_basin_rainfall_summary(basin_name, start_time="", stop_time=""):
    return {"basin_id": "21100150", "basin_name": basin_name}

async def get_basin_rainfall_forecast(
    basin_name, start_time="", model="gfs", forecast_hours=120
):
    return {"basin_id": "21100150", "basin_name": basin_name}

async def get_basin_rainfall_complete(
    basin_name, start_time="", warmup_days=30, forecast_days=5,
    model="gfs", interval="3h"
):
    return {"basin_id": "21100150", "basin_name": basin_name}

async def get_basin_warning_status(basin_name, start_time, stop_time):
    return {"basin_id": "21100150", "basin_name": basin_name}

async def get_basin_rainfall_isoline(basin_name, analysis_date, force=False):
    return {"basin_id": "21100150", "basin_name": basin_name}

async def get_basin_rainfall_file(
    basin_name, file_format="nc", start_time="", model="gfs"
):
    return {"basin_id": "21100150", "basin_name": basin_name}

async def get_station_timeseries(
    station_type, station_name, start_time, stop_time, parameters="", mode="full",
    threshold=None, exceed_parameter="water_level"
):
    return {
        "station_type": station_type,
        "summary": {"stcd": "21103500", "station_name": station_name},
    }

async def get_station_latest_data(station_type, station_name):
    return {
        "station_type": station_type,
        "summary": {"stcd": "21120032", "station_name": station_name},
    }

mcp = SimpleNamespace(
    list_reservoirs=list_reservoirs,
    get_reservoir_profile=get_reservoir_profile,
    get_river_station_detail=get_river_station_detail,
    get_river_warning_status=get_river_warning_status,
    get_river_historical_comparison=get_river_historical_comparison,
    get_rainstation_detail=get_rainstation_detail,
    get_rainfall_statistics=get_rainfall_statistics,
    get_basin_stations=get_basin_stations,
    get_basin_rainfall_summary=get_basin_rainfall_summary,
    get_basin_rainfall_forecast=get_basin_rainfall_forecast,
    get_basin_rainfall_complete=get_basin_rainfall_complete,
    get_basin_warning_status=get_basin_warning_status,
    get_basin_rainfall_isoline=get_basin_rainfall_isoline,
    get_basin_rainfall_file=get_basin_rainfall_file,
    get_station_timeseries=get_station_timeseries,
    get_station_latest_data=get_station_latest_data,
)
url_calls = []

async def reservoir_url(**kwargs):
    url_calls.append(("reservoir", kwargs))
    return {"URL": f"https://frontend.test/reservoir/{kwargs['page']}"}

async def river_url(**kwargs):
    url_calls.append(("river", kwargs))
    return {"URL": f"https://frontend.test/river/{kwargs['page']}"}

async def rain_url(**kwargs):
    url_calls.append(("rainfall", kwargs))
    return {"URL": "https://frontend.test/rainfall"}

async def basin_rain_url(**kwargs):
    url_calls.append(("basin-rain", kwargs))
    return {"URL": f"https://frontend.test/basin/{kwargs['page']}"}

async def basin_warning_url(**kwargs):
    url_calls.append(("basin-warning", kwargs))
    return {"URL": "https://frontend.test/basin/warning"}

urls = SimpleNamespace(
    get_reservoir_page_url=reservoir_url,
    get_river_page_url=river_url,
    get_rainstation_url=rain_url,
    get_basin_rain_page_url=basin_rain_url,
    get_basin_warning_status_url=basin_warning_url,
)
related.install(mcp, urls)

async def main():
    reservoir_search = await mcp.list_reservoirs(keyword="大伙房")
    assert reservoir_search["related_page"]["url"].endswith("/reservoir/detail")

    reservoir = await mcp.get_reservoir_profile(
        include="extra_info", reservoir_name="大伙房水库"
    )
    assert reservoir["related_page"]["url"].endswith("/reservoir/detail")

    river = await mcp.get_river_station_detail("占贝")
    assert river["related_page"]["url"].endswith("/river/monitor")

    comparison = await mcp.get_river_historical_comparison(
        "占贝", 2024, 2025, "07-01", "07-31", "水位"
    )
    assert comparison["related_page"]["url"].endswith("/river/comparison")
    assert url_calls[-1][1]["metric"] == "water_level"

    rainfall = await mcp.get_rainfall_statistics(
        "station", "石庙子", "month", 2025
    )
    assert rainfall["related_page"]["url"].endswith("/rainfall")
    assert url_calls[-1][1]["start_time"] == "2025-01-01T00:00:00+08:00"

    basin_overview = await mcp.get_basin_stations("大伙房水库")
    assert [page["label"] for page in basin_overview["related_pages"]] == [
        "流域雨情监测页面", "流域风险研判页面"
    ]
    assert "流域雨情监测页面" in basin_overview["response_requirement"]
    assert "流域风险研判页面" in basin_overview["response_requirement"]

    basin_summary = await mcp.get_basin_rainfall_summary(
        "大伙房水库", "2025-07-01T00:00:00Z", "2025-07-31T00:00:00Z"
    )
    assert basin_summary["related_page"]["url"].endswith("/basin/monitor")
    assert url_calls[-1][1]["start_time"] == "2025-07-01T08:00:00+08:00"

    basin_forecast = await mcp.get_basin_rainfall_forecast("大伙房水库")
    assert basin_forecast["related_page"]["url"].endswith("/basin/forecast")

    basin_rain_stats = await mcp.get_rainfall_statistics(
        "basin", "大伙房水库", "month", 2025, compare_year=2024
    )
    assert basin_rain_stats["related_page"]["url"].endswith("/basin/statistics")
    assert url_calls[-1][1]["compare_year"] == 2024

    basin_isoline = await mcp.get_basin_rainfall_isoline("大伙房水库", "2025-07-01")
    assert basin_isoline["related_page"]["url"].endswith("/basin/isoline")

    timeseries = await mcp.get_station_timeseries(
        "river", "占贝", "2025-07-01T00:00:00Z", "2025-07-31T00:00:00Z"
    )
    assert timeseries["related_page"]["url"].endswith("/river/monitor")
    assert url_calls[-1][1]["start_time"] == "2025-07-01T08:00:00+08:00"

    latest = await mcp.get_station_latest_data("rainfall", "石庙子")
    assert latest["related_page"]["url"].endswith("/rainfall")

    for result in (
        reservoir_search, reservoir, river, comparison, rainfall, basin_overview,
        basin_summary, basin_forecast, basin_rain_stats, basin_isoline, timeseries, latest
    ):
        assert "最终回复必须在正文末尾" in result["response_requirement"]

asyncio.run(main())
PY
grep -q 'related_page_compat.py' docker/zhixun-bot/Dockerfile.mcp
grep -q 'install_related_pages' docker/zhixun-bot/mcp_entrypoint.py
pass "station and basin queries include verified related pages"

render() {
  local write_tools="$1"
  local output="$2"
  env \
    ZHIXUN_BOT_FEISHU_APP_ID=cli_test \
    ZHIXUN_BOT_FEISHU_APP_SECRET=test_secret \
    ZHIXUN_BOT_FEISHU_STREAMING=false \
    ZHIXUN_BOT_MODEL_API_KEY=model_secret \
    ZHIXUN_BOT_MODEL_ID=deepseek-chat \
    ZHIXUN_BOT_MODEL_BASE_URL=https://api.deepseek.com \
    ZHIXUN_BOT_ENABLE_WRITE_TOOLS="${write_tools}" \
    node docker/zhixun-bot/render-config.mjs \
      docker/zhixun-bot/openclaw.json.template \
      "${output}"
}

render false "${TMP_DIR}/read-only.json"
render true "${TMP_DIR}/write-enabled.json"

python3 - "${TMP_DIR}/read-only.json" "${TMP_DIR}/write-enabled.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    read_only = json.load(stream)
with open(sys.argv[2], encoding="utf-8") as stream:
    write_enabled = json.load(stream)

agent = read_only["agents"]["list"][0]
assert agent["id"] == "zhixun-water"
assert agent["tools"]["allow"] == ["bundle-mcp"]
assert read_only["tools"]["profile"] == "messaging"
assert read_only["messages"]["visibleReplies"] == "automatic"
assert read_only["messages"]["groupChat"]["visibleReplies"] == "automatic"
assert read_only["agents"]["defaults"]["imageMaxDimensionPx"] == 512
assert read_only["agents"]["defaults"]["contextPruning"] == {
    "mode": "cache-ttl",
    "ttl": "1m",
}
assert read_only["session"]["resetTriggers"] == ["/new", "/reset"]

plugins = read_only["plugins"]
assert plugins["allow"] == ["deepseek", "feishu", "forecast-media-hygiene"]
assert plugins["load"]["paths"] == [
    "/opt/zhixun-bot/plugins/forecast-media-hygiene"
]
assert plugins["entries"]["forecast-media-hygiene"]["enabled"] is True
assert read_only["channels"]["feishu"]["enabled"] is True

feishu = read_only["channels"]["feishu"]
assert feishu["dmPolicy"] == "open"
assert feishu["groupPolicy"] == "open"
assert feishu["allowFrom"] == ["*"]
assert "groups" not in feishu
assert feishu["requireMention"] is True
assert feishu["streaming"] is False
assert all(enabled is False for enabled in feishu["tools"].values())

binding = read_only["bindings"][0]
assert binding["agentId"] == "zhixun-water"
assert binding["match"] == {"channel": "feishu"}

server = read_only["mcp"]["servers"]["water_unified"]
assert server["url"] == "http://zhixun-water-mcp:18201/sse"
assert "dispatch_task_execute" in server["toolFilter"]["exclude"]
assert "hydromodel_list" in server["toolFilter"]["exclude"]
realtime_tools = {
    "realtime_forecast_health",
    "run_all_realtime_forecasts",
    "run_realtime_forecast",
    "get_latest_realtime_forecast",
    "run_realtime_forecast_compat",
    "get_latest_realtime_forecast_compat",
    "get_combined_forecast_timeseries",
    "get_observed_flow_timeseries",
    "get_gfs_forecast_timeseries",
    "get_ifs_forecast_timeseries",
    "get_actual_precip_compatible_timeseries",
    "get_mswep_precip_timeseries",
}
assert realtime_tools.isdisjoint(server["toolFilter"]["exclude"])
assert "toolFilter" not in write_enabled["mcp"]["servers"]["water_unified"]

serialized = json.dumps(read_only)
assert "__FEISHU_" not in serialized
assert "__MODEL_" not in serialized
assert read_only["agents"]["defaults"]["model"]["primary"] == "deepseek/deepseek-chat"
assert read_only["models"]["providers"]["deepseek"]["apiKey"] == "model_secret"
PY
pass "rendered group binding and MCP tool policy"

echo "✅ zhixun bot static tests passed"
