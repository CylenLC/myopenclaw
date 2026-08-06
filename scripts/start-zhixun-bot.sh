#!/usr/bin/env bash
# =============================================================
# start-zhixun-bot.sh — 在服务器启动独立 zhixun 飞书机器人
# 用法: ./scripts/start-zhixun-bot.sh [--build]
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${REPO_ROOT}/.env.zhixun-bot"
COMPOSE_FILE="${REPO_ROOT}/docker-compose.zhixun-bot.yml"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "❌ 缺少 ${ENV_FILE}"
  echo "   cp .env.zhixun-bot.example .env.zhixun-bot"
  echo "   然后填写飞书、模型和服务器路径配置。"
  exit 1
fi

required_vars=(
  ZHIXUN_BOT_FEISHU_APP_ID
  ZHIXUN_BOT_FEISHU_APP_SECRET
  ZHIXUN_BOT_MODEL_API_KEY
)

for name in "${required_vars[@]}"; do
  value="$(grep -E "^${name}=" "${ENV_FILE}" | tail -1 | cut -d= -f2- || true)"
  if [[ -z "${value}" || "${value}" == "replace_me" || "${value}" == *"xxxx"* ]]; then
    echo "❌ ${name} 未在 .env.zhixun-bot 中正确设置"
    exit 1
  fi
done

zhixun_path="$(grep -E '^ZHIXUN_AGENT_PATH=' "${ENV_FILE}" | tail -1 | cut -d= -f2- || true)"
zhixun_path="${zhixun_path:-../zhixun-agent}"
if [[ "${zhixun_path}" != /* ]]; then
  zhixun_path="${REPO_ROOT}/${zhixun_path}"
fi

required_zhixun_files=(
  mcp_servers/water/mcp_server_unified.py
  mcp_servers/water/mcp_server_realtime_forecast.py
)

missing_zhixun_files=()
for relative_path in "${required_zhixun_files[@]}"; do
  if [[ ! -f "${zhixun_path}/${relative_path}" ]]; then
    missing_zhixun_files+=("${relative_path}")
  fi
done

if (( ${#missing_zhixun_files[@]} > 0 )); then
  echo "❌ ZHIXUN_AGENT_PATH 无效: ${zhixun_path}"
  echo "   请切换 zhixun-agent 到 feat/realtime-forecast-mcp，缺少文件："
  printf '   - %s\n' "${missing_zhixun_files[@]}"
  exit 1
fi

data_dir="$(grep -E '^ZHIXUN_BOT_DATA_DIR=' "${ENV_FILE}" | tail -1 | cut -d= -f2- || true)"
data_dir="${data_dir:-${HOME}/.openclaw-zhixun}"
data_dir="${data_dir/#\~/${HOME}}"
if [[ "${data_dir}" != /* ]]; then
  data_dir="${REPO_ROOT}/${data_dir}"
fi
mkdir -p "${data_dir}"
data_dir="$(cd "${data_dir}" && pwd -P)"

main_openclaw_dir="${HOME}/.openclaw"
if [[ -d "${main_openclaw_dir}" ]]; then
  main_openclaw_dir="$(cd "${main_openclaw_dir}" && pwd -P)"
fi
if [[ "${data_dir}" == "${main_openclaw_dir}" ]] \
  || [[ "${data_dir}" == "${main_openclaw_dir}/"* ]]; then
  echo "❌ ZHIXUN_BOT_DATA_DIR 不能位于现有 ~/.openclaw 内: ${data_dir}"
  exit 1
fi

build_requested=false
if [[ "${1:-}" == "--build" ]]; then
  build_requested=true
elif [[ -n "${1:-}" ]]; then
  echo "❌ 未知参数: $1"
  echo "用法: ./scripts/start-zhixun-bot.sh [--build]"
  exit 1
fi

echo "🔍 校验 zhixun 机器人 Compose 配置..."
docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" config --quiet

echo "🚀 启动独立 zhixun 飞书机器人..."
if [[ "${build_requested}" == "true" ]]; then
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" \
    up -d --force-recreate --build
else
  docker compose --env-file "${ENV_FILE}" -f "${COMPOSE_FILE}" \
    up -d --force-recreate
fi

expected_models="$(grep -E '^ZHIXUN_REALTIME_FORECAST_MODELS=' "${ENV_FILE}" | tail -1 | cut -d= -f2- || true)"
expected_models="${expected_models:-simplelstm,sms3-lag3,sms3-uhb}"
container_models="$(
  docker inspect zhixun-water-mcp \
    --format '{{range .Config.Env}}{{println .}}{{end}}' \
    | grep -E '^ZHIXUN_REALTIME_FORECAST_MODELS=' \
    | tail -1 \
    | cut -d= -f2-
)"
if [[ "${container_models}" != "${expected_models}" ]]; then
  echo "❌ MCP 容器模型配置与 .env.zhixun-bot 不一致"
  echo "   .env:     ${expected_models}"
  echo "   container: ${container_models:-<empty>}"
  exit 1
fi

echo "✅ 启动命令已提交"
echo "   实时预报模型: ${container_models}"
echo "   状态: docker compose --env-file .env.zhixun-bot -f docker-compose.zhixun-bot.yml ps"
echo "   日志: docker compose --env-file .env.zhixun-bot -f docker-compose.zhixun-bot.yml logs -f openclaw-zhixun"
echo "   MCP:  docker compose --env-file .env.zhixun-bot -f docker-compose.zhixun-bot.yml exec openclaw-zhixun node /app/openclaw.mjs mcp probe water_unified --json"
