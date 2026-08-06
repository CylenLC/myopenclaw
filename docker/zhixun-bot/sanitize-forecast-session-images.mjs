#!/usr/bin/env node

import { copyFile, readFile, readdir, writeFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";
import { pathToFileURL } from "node:url";
import { sanitizeForecastMediaMessage } from "./plugins/forecast-media-hygiene/index.js";

async function listJsonlFiles(root) {
  let entries;
  try {
    entries = await readdir(root, { withFileTypes: true });
  } catch (error) {
    if (error && error.code === "ENOENT") {
      return [];
    }
    throw error;
  }
  return entries
    .filter((entry) => entry.isFile() && entry.name.endsWith(".jsonl"))
    .map((entry) => path.join(root, entry.name));
}

function sanitizeTranscriptText(source) {
  let changedMessages = 0;
  const lines = source.split("\n");
  const output = lines.map((line) => {
    if (!line.trim()) {
      return line;
    }
    let record;
    try {
      record = JSON.parse(line);
    } catch {
      return line;
    }
    if (!record.message) {
      return line;
    }
    const sanitized = sanitizeForecastMediaMessage(record.message);
    if (!sanitized.changed) {
      return line;
    }
    changedMessages += 1;
    return JSON.stringify({ ...record, message: sanitized.message });
  });
  return { text: output.join("\n"), changedMessages };
}

async function sanitizeFile(file) {
  const source = await readFile(file, "utf8");
  const sanitized = sanitizeTranscriptText(source);
  if (sanitized.changedMessages === 0) {
    return 0;
  }
  await copyFile(file, `${file}.pre-image-sanitize.bak`);
  await writeFile(file, sanitized.text, "utf8");
  return sanitized.changedMessages;
}

async function main() {
  const root = process.argv[2];
  if (!root) {
    throw new Error("usage: sanitize-forecast-session-images.mjs <sessions-directory>");
  }
  const files = await listJsonlFiles(root);
  let changedFiles = 0;
  let changedMessages = 0;
  for (const file of files) {
    const count = await sanitizeFile(file);
    if (count > 0) {
      changedFiles += 1;
      changedMessages += count;
    }
  }
  console.log(
    `[forecast-media-hygiene] sanitized ${changedMessages} image-bearing message(s) in ${changedFiles} session file(s)`,
  );
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch((error) => {
    console.error(`[forecast-media-hygiene] ${error instanceof Error ? error.message : String(error)}`);
    process.exitCode = 1;
  });
}

export { sanitizeTranscriptText };
