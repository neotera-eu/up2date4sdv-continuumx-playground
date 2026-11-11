import { createHash, randomUUID } from "crypto";
import { mkdir, readFile, rename, writeFile, unlink } from "fs/promises";
import path from "path";

const DATA_DIR = process.env.FIRMWARE_DATA_DIR || "/data/firmwares";
const FILES_DIR = path.join(DATA_DIR, "files");
const META_PATH = path.join(DATA_DIR, "meta.json");

function sanitizeToken(value, label) {
  const s = String(value || "")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9._-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (!s) throw new Error(`${label} is required`);
  if (s.length > 64) throw new Error(`${label} is too long`);
  return s;
}

async function ensureDirs() {
  await mkdir(FILES_DIR, { recursive: true });
}

async function readMeta() {
  await ensureDirs();
  try {
    const raw = await readFile(META_PATH, "utf8");
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed.items) ? parsed : { items: [] };
  } catch {
    return { items: [] };
  }
}

async function writeMeta(meta) {
  await ensureDirs();
  const tmp = `${META_PATH}.${process.pid}.tmp`;
  await writeFile(tmp, JSON.stringify(meta, null, 2));
  await rename(tmp, META_PATH);
}

export function downloadPath(name, version) {
  const q = new URLSearchParams({ name, version });
  return `/api/download?${q.toString()}`;
}

export function withDownloadUrl(item) {
  return {
    ...item,
    downloadUrl: downloadPath(item.name, item.version),
  };
}

export async function listFirmwares() {
  const meta = await readMeta();
  return meta.items
    .slice()
    .sort((a, b) => String(b.uploadedAt).localeCompare(String(a.uploadedAt)))
    .map(withDownloadUrl);
}

export async function findFirmware(name, version) {
  const n = sanitizeToken(name, "name");
  const v = sanitizeToken(version, "version");
  const meta = await readMeta();
  const item = meta.items.find((x) => x.name === n && x.version === v);
  if (!item) return null;
  return {
    item: withDownloadUrl(item),
    filePath: path.join(FILES_DIR, item.storedAs),
  };
}

export async function saveFirmware({
  name,
  version,
  description,
  deviceModel,
  originalName,
  buffer,
}) {
  const n = sanitizeToken(name, "name");
  const v = sanitizeToken(version, "version");
  const desc = String(description || "").trim().slice(0, 500);
  const model = String(deviceModel || "").trim().slice(0, 128);
  if (!buffer || !buffer.length) throw new Error("file is empty");
  if (buffer.length > 256 * 1024 * 1024) {
    throw new Error("file too large (max 256 MiB)");
  }

  const meta = await readMeta();
  if (meta.items.some((x) => x.name === n && x.version === v)) {
    throw new Error(`firmware ${n}@${v} already exists`);
  }

  const sha256 = createHash("sha256").update(buffer).digest("hex");
  const storedAs = `${n}__${v}.bin`;
  const dest = path.join(FILES_DIR, storedAs);
  await writeFile(dest, buffer);

  const item = {
    id: randomUUID(),
    name: n,
    version: v,
    description: desc,
    deviceModel: model,
    originalName: String(originalName || storedAs).slice(0, 256),
    storedAs,
    size: buffer.length,
    sha256,
    uploadedAt: new Date().toISOString(),
  };

  meta.items.push(item);
  await writeMeta(meta);
  return withDownloadUrl(item);
}

export async function deleteFirmware(name, version) {
  const found = await findFirmware(name, version);
  if (!found) return false;
  const meta = await readMeta();
  meta.items = meta.items.filter(
    (x) => !(x.name === found.item.name && x.version === found.item.version),
  );
  await writeMeta(meta);
  try {
    await unlink(found.filePath);
  } catch {
    // ignore missing file
  }
  return true;
}
