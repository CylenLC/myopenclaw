const IMAGE_PLACEHOLDER = "[已发送的预报图片不再载入模型上下文]";

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

const plugin = {
  id: "forecast-media-hygiene",
  name: "Forecast Media Hygiene",
  description: "Keeps outbound forecast images out of persisted model context.",
  register(api) {
    api.on("before_message_write", (event) => {
      const sanitized = sanitizeForecastMediaMessage(event.message);
      return sanitized.changed ? { message: sanitized.message } : undefined;
    });
  },
};

export { IMAGE_PLACEHOLDER, sanitizeForecastMediaMessage };
export default plugin;
