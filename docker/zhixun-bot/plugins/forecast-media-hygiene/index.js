import { randomUUID } from "node:crypto";
import { mkdir, unlink, writeFile } from "node:fs/promises";
import path from "node:path";

const IMAGE_PLACEHOLDER = "[已发送的预报图片不再载入模型上下文]";
const DEFAULT_MEDIA_DIR = "/home/node/.openclaw/media/forecast-outbound";
const DEFAULT_MAX_IMAGE_BYTES = 10 * 1024 * 1024;
const MAX_ATTACHMENTS = 10;
const FORECAST_TOOL_NAMES = new Set([
  "run_all_realtime_forecasts",
  "run_realtime_forecast",
  "run_realtime_forecast_compat",
  "get_latest_realtime_forecast",
  "get_latest_realtime_forecast_compat",
]);

const FORECAST_IMAGE_TOOL_SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["attachments"],
  properties: {
    attachments: {
      type: "array",
      minItems: 1,
      maxItems: MAX_ATTACHMENTS,
      description: "必须逐项复制实时预报结果 media_delivery.attachments 的完整列表。",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["model_name", "media_url"],
        properties: {
          model_name: { type: "string", minLength: 1 },
          media_url: { type: "string", minLength: 1 },
        },
      },
    },
  },
};

function isImageBlock(value) {
  return (
    value &&
    typeof value === "object" &&
    (value.type === "image" || value.type === "image_url")
  );
}

function sanitizeContent(content) {
  if (!Array.isArray(content)) {
    return { content, changed: false };
  }

  let changed = false;
  let insertedPlaceholder = false;
  const sanitized = [];
  for (const block of content) {
    if (!isImageBlock(block)) {
      sanitized.push(block);
      continue;
    }
    changed = true;
    if (!insertedPlaceholder) {
      sanitized.push({ type: "text", text: IMAGE_PLACEHOLDER });
      insertedPlaceholder = true;
    }
  }

  return { content: sanitized, changed };
}

function sanitizeForecastMediaMessage(message) {
  if (!message || typeof message !== "object" || Array.isArray(message)) {
    return { message, changed: false };
  }

  const next = { ...message };
  const contentResult = sanitizeContent(next.content);
  let changed = contentResult.changed;
  if (contentResult.changed) {
    next.content = contentResult.content;
  }

  for (const field of ["media", "images", "image"]) {
    if (field in next) {
      delete next[field];
      changed = true;
    }
  }

  const metadata = next.__openclaw;
  if (metadata && typeof metadata === "object" && !Array.isArray(metadata)) {
    const cleanMetadata = { ...metadata };
    for (const field of ["media", "mediaImageBlockFactIndexes", "mediaImageLayout"]) {
      if (field in cleanMetadata) {
        delete cleanMetadata[field];
        changed = true;
      }
    }
    if (changed) {
      cleanMetadata.mediaImagePruned = true;
      next.__openclaw = cleanMetadata;
    }
  }

  return { message: changed ? next : message, changed };
}

function parseTrustedPlotUrl(rawUrl, rawBaseUrl) {
  let baseUrl;
  let mediaUrl;
  try {
    baseUrl = new URL(rawBaseUrl);
    mediaUrl = new URL(rawUrl);
  } catch {
    throw new Error("预报图片地址不是有效 URL");
  }
  if (!["http:", "https:"].includes(baseUrl.protocol)) {
    throw new Error("实时预报服务地址只支持 HTTP 或 HTTPS");
  }
  if (mediaUrl.origin !== baseUrl.origin) {
    throw new Error(`拒绝下载非实时预报服务同源的图片: ${mediaUrl.origin}`);
  }
  if (mediaUrl.username || mediaUrl.password || mediaUrl.hash || mediaUrl.search) {
    throw new Error("预报图片地址不得包含凭据、查询参数或片段");
  }
  if (!/^\/plots\/[A-Za-z0-9._-]+$/.test(mediaUrl.pathname)) {
    throw new Error("预报图片地址必须位于实时预报服务的 /plots/ 目录");
  }
  return mediaUrl;
}

function stripForecastMediaLinks(content, rawBaseUrl, mediaDir = DEFAULT_MEDIA_DIR) {
  if (typeof content !== "string" || !content) {
    return { content, changed: false };
  }
  const isTrustedUrl = (candidate) => {
    try {
      parseTrustedPlotUrl(candidate, rawBaseUrl);
      return true;
    } catch {
      return false;
    }
  };
  let changed = false;
  let sanitized = content.replace(/!?\[[^\]\r\n]*\]\((https?:\/\/[^\s)]+)\)/giu, (match, url) => {
    if (!isTrustedUrl(url)) {
      return match;
    }
    changed = true;
    return "";
  });
  sanitized = sanitized.replace(/https?:\/\/[^\s<>()\]]+/giu, (url) => {
    if (!isTrustedUrl(url)) {
      return url;
    }
    changed = true;
    return "";
  });
  if (sanitized.includes(mediaDir)) {
    changed = true;
    sanitized = sanitized
      .split(/\r?\n/)
      .filter((line) => !line.includes(mediaDir))
      .join("\n");
  }
  sanitized = sanitized
    .replace(/^\s*MEDIA:\s*$/gimu, "")
    .replace(/\n{3,}/g, "\n\n")
    .trim();
  return { content: sanitized, changed };
}

function stripEnglishReasoningPreamble(content) {
  if (typeof content !== "string" || !content) return { content, changed: false };
  const lines = content.split(/\r?\n/);
  const first = lines.findIndex((line) => line.trim());
  if (first < 0 || !/^(?:I\s+(?:need|should|will|have|can|cannot)|Let me|Actually\b|Current time\b|The\s+(?:forecast|backend|tool|result)\b)/i.test(lines[first].trim())) {
    return { content, changed: false };
  }
  const chineseStart = lines.findIndex((line, index) => index > first && /[\u3400-\u9fff]/u.test(line));
  if (chineseStart < 0) return { content: "", changed: true };
  return { content: lines.slice(chineseStart).join("\n").trim(), changed: true };
}

function stripUnverifiedPlatformEntry(content) {
  if (typeof content !== "string" || !content) return { content, changed: false };
  const lines = content.split(/\r?\n/);
  const filtered = lines.filter((line) => {
    const barePlatform = /https?:\/\/ws\.waterism\.tech:8446\/?(?:\s|$)/iu.test(line)
      && !/https?:\/\/ws\.waterism\.tech:8446\/[^\s)\]]+/iu.test(line);
    return !barePlatform;
  });
  const next = filtered.join("\n").replace(/\n{3,}/g, "\n\n").trim();
  return { content: next, changed: next !== content };
}

function detectImageType(buffer) {
  if (
    buffer.length >= 8 &&
    buffer.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]))
  ) {
    return { extension: "png", mimeType: "image/png" };
  }
  if (buffer.length >= 3 && buffer[0] === 0xff && buffer[1] === 0xd8 && buffer[2] === 0xff) {
    return { extension: "jpg", mimeType: "image/jpeg" };
  }
  const prefix = buffer.subarray(0, 6).toString("ascii");
  if (prefix === "GIF87a" || prefix === "GIF89a") {
    return { extension: "gif", mimeType: "image/gif" };
  }
  if (
    buffer.length >= 12 &&
    buffer.subarray(0, 4).toString("ascii") === "RIFF" &&
    buffer.subarray(8, 12).toString("ascii") === "WEBP"
  ) {
    return { extension: "webp", mimeType: "image/webp" };
  }
  throw new Error("实时预报服务返回的内容不是受支持的图片格式");
}

async function readBoundedResponse(response, maxBytes) {
  const contentLength = Number(response.headers.get("content-length"));
  if (Number.isFinite(contentLength) && contentLength > maxBytes) {
    throw new Error(`预报图片超过 ${maxBytes} 字节限制`);
  }
  if (!response.body) {
    throw new Error("实时预报服务返回了空图片响应");
  }

  const chunks = [];
  let total = 0;
  const reader = response.body.getReader();
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) {
        break;
      }
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel();
        throw new Error(`预报图片超过 ${maxBytes} 字节限制`);
      }
      chunks.push(Buffer.from(value));
    }
  } finally {
    reader.releaseLock();
  }
  if (total === 0) {
    throw new Error("实时预报服务返回了空图片");
  }
  return Buffer.concat(chunks, total);
}

async function downloadTrustedPlot(rawUrl, options) {
  const mediaUrl = parseTrustedPlotUrl(rawUrl, options.baseUrl);
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), options.timeoutMs);
  let response;
  try {
    response = await options.fetchImpl(mediaUrl, {
      method: "GET",
      redirect: "manual",
      signal: controller.signal,
      headers: { Accept: "image/png,image/jpeg,image/gif,image/webp" },
    });
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error(`下载预报图片超时（${options.timeoutMs}ms）`);
    }
    throw new Error(`下载预报图片失败: ${error instanceof Error ? error.message : String(error)}`);
  } finally {
    clearTimeout(timeout);
  }
  if (!response.ok) {
    throw new Error(`下载预报图片失败: HTTP ${response.status}`);
  }
  const buffer = await readBoundedResponse(response, options.maxImageBytes);
  return { buffer, ...detectImageType(buffer) };
}

function normalizeAttachments(value) {
  if (!Array.isArray(value) || value.length === 0 || value.length > MAX_ATTACHMENTS) {
    throw new Error(`attachments 必须包含 1 到 ${MAX_ATTACHMENTS} 张预报图片`);
  }
  return value.map((item) => {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new Error("attachments 中每一项都必须是对象");
    }
    const modelName = typeof item.model_name === "string" ? item.model_name.trim() : "";
    const mediaUrl = typeof item.media_url === "string" ? item.media_url.trim() : "";
    if (!modelName || !mediaUrl) {
      throw new Error("每张预报图片都必须包含 model_name 和 media_url");
    }
    return { modelName, mediaUrl };
  });
}

function toolJsonResult(payload) {
  return {
    content: [{ type: "text", text: JSON.stringify(payload, null, 2) }],
    details: payload,
  };
}

function isForecastTool(toolName) {
  const leaf = String(toolName ?? "").split("__").at(-1);
  return FORECAST_TOOL_NAMES.has(leaf);
}

function extractMediaAttachments(value, seen = new Set()) {
  if (typeof value === "string") {
    try {
      return extractMediaAttachments(JSON.parse(value), seen);
    } catch {
      return [];
    }
  }
  if (!value || typeof value !== "object" || seen.has(value)) {
    return [];
  }
  seen.add(value);
  if (Array.isArray(value)) {
    for (const item of value) {
      const found = extractMediaAttachments(item, seen);
      if (found.length) return found;
    }
    return [];
  }
  if (Array.isArray(value.media_delivery?.attachments)) {
    return value.media_delivery.attachments;
  }
  for (const key of ["details", "structuredContent", "content", "data", "result"]) {
    const found = extractMediaAttachments(value[key], seen);
    if (found.length) return found;
  }
  if (value.type === "text" && typeof value.text === "string") {
    return extractMediaAttachments(value.text, seen);
  }
  return [];
}

function createForecastImageTool(api, toolContext, overrides = {}) {
  const delivery = toolContext.deliveryContext ?? {};
  const channel = String(delivery.channel ?? toolContext.messageChannel ?? "").split(":")[0].toLowerCase();
  const target = delivery.to ?? toolContext.nativeChannelId;

  return {
    name: "send_forecast_images",
    label: "发送实时预报图片",
    description: (
      "把实时预报结果 media_delivery.attachments 的完整列表作为飞书原生图片发送到当前会话。" +
      "每次成功的预报查询都必须调用一次；禁止改用 message 工具、Markdown、MEDIA: 或普通链接。"
    ),
    parameters: FORECAST_IMAGE_TOOL_SCHEMA,
    async execute(_toolCallId, params) {
      if (channel !== "feishu" || typeof target !== "string" || !target.trim()) {
        throw new Error("当前会话未提供可用的飞书投递目标，无法发送原生图片");
      }
      const attachments = normalizeAttachments(params?.attachments);
      const baseUrl = overrides.baseUrl ?? process.env.ZHIXUN_REALTIME_FORECAST_BASE_URL;
      if (!baseUrl) {
        throw new Error("未配置 ZHIXUN_REALTIME_FORECAST_BASE_URL，无法发送预报图片");
      }
      const mediaDir = path.resolve(
        overrides.mediaDir ?? process.env.ZHIXUN_FORECAST_MEDIA_DIR ?? DEFAULT_MEDIA_DIR,
      );
      const timeoutMs = Number(
        overrides.timeoutMs ?? process.env.ZHIXUN_REALTIME_FORECAST_IMAGE_TIMEOUT_MS ?? 30000,
      );
      const maxImageBytes = Number(overrides.maxImageBytes ?? DEFAULT_MAX_IMAGE_BYTES);
      if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) {
        throw new Error("预报图片下载超时必须是大于 0 的毫秒数");
      }
      if (!Number.isFinite(maxImageBytes) || maxImageBytes <= 0) {
        throw new Error("预报图片大小限制必须大于 0");
      }
      const fetchImpl = overrides.fetchImpl ?? globalThis.fetch;
      if (typeof fetchImpl !== "function") {
        throw new Error("当前 Node.js 运行时不支持下载预报图片");
      }

      const adapter = await api.runtime.channel.outbound.loadAdapter("feishu");
      if (!adapter?.sendMedia) {
        throw new Error("飞书适配器不支持原生图片发送");
      }
      await mkdir(mediaDir, { recursive: true, mode: 0o700 });

      const localFiles = [];
      try {
        // Download and validate the complete set before the first visible send.
        for (const attachment of attachments) {
          const image = await downloadTrustedPlot(attachment.mediaUrl, {
            baseUrl,
            fetchImpl,
            timeoutMs,
            maxImageBytes,
          });
          const safeModel = attachment.modelName.replace(/[^A-Za-z0-9._-]+/g, "_").slice(0, 80);
          const filePath = path.join(
            mediaDir,
            `${Date.now()}-${randomUUID()}-${safeModel || "forecast"}.${image.extension}`,
          );
          await writeFile(filePath, image.buffer, { mode: 0o600, flag: "wx" });
          localFiles.push({ ...attachment, filePath, mimeType: image.mimeType });
        }

        const sentModels = [];
        for (const item of localFiles) {
          await adapter.sendMedia({
            cfg: toolContext.runtimeConfig ?? toolContext.config ?? api.config,
            to: target.trim(),
            text: "",
            mediaUrl: item.filePath,
            mediaLocalRoots: [mediaDir],
            accountId: delivery.accountId ?? toolContext.agentAccountId,
            threadId: delivery.threadId,
          });
          sentModels.push(item.modelName);
        }

        const payload = {
          success: true,
          delivery: "feishu_native_image",
          sent_count: sentModels.length,
          sent_models: sentModels,
          response_rule: "图片已经发送；最终回答不得再次输出图片 URL、Markdown、MEDIA: 或本地路径。",
        };
        api.logger?.info?.(`[forecast-media] 已发送 ${sentModels.length} 张飞书原生预报图片`);
        return toolJsonResult(payload);
      } finally {
        await Promise.all(localFiles.map((item) => unlink(item.filePath).catch(() => undefined)));
      }
    },
  };
}

const plugin = {
  id: "forecast-media-hygiene",
  name: "Forecast Native Media",
  description: "Uploads trusted forecast plots as native Feishu images without model-context replay.",
  register(api) {
    const routes = new Map();
    const delivered = new Set();
    api.on("message_received", (event, context) => {
      const sessionKey = context.sessionKey ?? event.sessionKey;
      const channel = String(context.channelId ?? "").split(":")[0].toLowerCase();
      const target = context.conversationId ?? event.from;
      if (sessionKey && channel === "feishu" && typeof target === "string" && target.trim()) {
        routes.set(sessionKey, {
          channel: "feishu",
          to: target.trim(),
          accountId: context.accountId,
          threadId: event.threadId,
        });
      }
    });
    api.on("after_tool_call", async (event, context) => {
      if (event.error || !isForecastTool(event.toolName)) return;
      const route = routes.get(context.sessionKey);
      const attachments = extractMediaAttachments(event.result);
      if (!route || !attachments.length) return;
      const deliveryKey = `${context.sessionKey}:${event.toolCallId ?? attachments.map((item) => item.media_url).join("|")}`;
      if (delivered.has(deliveryKey)) return;
      delivered.add(deliveryKey);
      if (delivered.size > 1000) delivered.clear();
      const tool = createForecastImageTool(api, {
        deliveryContext: route,
        messageChannel: "feishu",
        nativeChannelId: route.to,
        runtimeConfig: api.config,
      });
      try {
        await tool.execute(event.toolCallId ?? "automatic-forecast-media", { attachments });
      } catch (error) {
        delivered.delete(deliveryKey);
        api.logger?.error?.(`[forecast-media] 自动发送预报图片失败: ${error instanceof Error ? error.message : String(error)}`);
      }
    }, { timeoutMs: 180000 });
    api.on("before_message_write", (event) => {
      const sanitized = sanitizeForecastMediaMessage(event.message);
      return sanitized.changed ? { message: sanitized.message } : undefined;
    });
    api.on("message_sending", (event) => {
      const withoutReasoning = stripEnglishReasoningPreamble(event.content);
      if (withoutReasoning.changed && !withoutReasoning.content) {
        return { cancel: true, cancelReason: "已阻止英文内部规划文本发送给用户" };
      }
      const withoutPlatform = stripUnverifiedPlatformEntry(withoutReasoning.content);
      const cleanedContent = withoutPlatform.content;
      const changed = withoutReasoning.changed || withoutPlatform.changed;
      if (changed && !cleanedContent) {
        return { cancel: true, cancelReason: "已阻止未验证的平台入口链接" };
      }
      const baseUrl = process.env.ZHIXUN_REALTIME_FORECAST_BASE_URL;
      if (!baseUrl) {
        return changed ? { content: cleanedContent } : undefined;
      }
      const sanitized = stripForecastMediaLinks(
        cleanedContent,
        baseUrl,
        process.env.ZHIXUN_FORECAST_MEDIA_DIR ?? DEFAULT_MEDIA_DIR,
      );
      if (!sanitized.changed) {
        return changed ? { content: cleanedContent } : undefined;
      }
      if (!sanitized.content) {
        return {
          cancel: true,
          cancelReason: "已阻止将预报图片 URL 或本地路径降级为文字链接",
        };
      }
      return { content: sanitized.content };
    });
  },
};

export {
  FORECAST_IMAGE_TOOL_SCHEMA,
  IMAGE_PLACEHOLDER,
  createForecastImageTool,
  detectImageType,
  extractMediaAttachments,
  isForecastTool,
  parseTrustedPlotUrl,
  sanitizeForecastMediaMessage,
  stripForecastMediaLinks,
  stripEnglishReasoningPreamble,
  stripUnverifiedPlatformEntry,
};
export default plugin;
