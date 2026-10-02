import { open, readdir, stat } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

const DEFAULT_DIAGNOSTIC_DIRECTORY = path.join(
  os.homedir(),
  "Library",
  "Logs",
  "DiagnosticReports",
);
const DEFAULT_MAXIMUM_BYTES = 1024 * 1024;
const MAXIMUM_FRAMES = 12;

export type CrashFrame = {
  symbol: string;
  sourceFile?: string;
  sourceLine?: number;
};

export type CrashDiagnosis = {
  found: true;
  file: string;
  timestamp?: string;
  incidentId?: string;
  exceptionType?: string;
  signal?: string;
  terminationNamespace?: string;
  terminationCode?: number;
  faultingThread?: number;
  frames: CrashFrame[];
} | {
  found: false;
};

type DiagnoseOptions = {
  directory?: string;
  maximumBytes?: number;
};

export async function diagnoseLatestCrash(
  options: DiagnoseOptions = {},
): Promise<CrashDiagnosis> {
  const directory = options.directory ?? DEFAULT_DIAGNOSTIC_DIRECTORY;
  const maximumBytes = options.maximumBytes ?? DEFAULT_MAXIMUM_BYTES;
  let entries;
  try {
    entries = await readdir(directory, { withFileTypes: true });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") return { found: false };
    throw error;
  }
  const candidates = await Promise.all(
    entries
      .filter((entry) => entry.isFile() && /^Overlook.*\.ips$/.test(entry.name))
      .map(async (entry) => {
        const filePath = path.join(directory, entry.name);
        return { filePath, name: entry.name, metadata: await stat(filePath) };
      }),
  );
  candidates.sort((left, right) => right.metadata.mtimeMs - left.metadata.mtimeMs);
  const latest = candidates[0];
  if (!latest) return { found: false };

  const rawReport = await readBoundedFile(latest.filePath, maximumBytes);
  const newline = rawReport.indexOf("\n");
  const headerRaw = newline >= 0 ? rawReport.slice(0, newline) : rawReport;
  const reportRaw = newline >= 0 ? rawReport.slice(newline + 1) : "{}";
  const header = parseObject(headerRaw);
  const report = parseObject(reportRaw);
  const frames = extractFrames(report);
  const exception = asObject(report.exception);
  const termination = asObject(report.termination);

  const diagnosis: CrashDiagnosis = {
    found: true,
    file: latest.name,
    frames,
  };
  const timestamp = safeString(header.timestamp);
  const incidentId = safeString(header.incident_id);
  const exceptionType = safeString(exception.type);
  const signal = safeString(exception.signal);
  const terminationNamespace = safeString(termination.namespace);
  const terminationCode = safeNumber(termination.code);
  const faultingThread = safeNumber(report.faultingThread);
  if (timestamp !== undefined) diagnosis.timestamp = timestamp;
  if (incidentId !== undefined) diagnosis.incidentId = incidentId;
  if (exceptionType !== undefined) diagnosis.exceptionType = exceptionType;
  if (signal !== undefined) diagnosis.signal = signal;
  if (terminationNamespace !== undefined) diagnosis.terminationNamespace = terminationNamespace;
  if (terminationCode !== undefined) diagnosis.terminationCode = terminationCode;
  if (faultingThread !== undefined) diagnosis.faultingThread = faultingThread;
  return diagnosis;
}

async function readBoundedFile(filePath: string, maximumBytes: number): Promise<string> {
  if (!Number.isSafeInteger(maximumBytes) || maximumBytes <= 0) {
    throw new Error("Diagnostic size limit is invalid");
  }
  const file = await open(filePath, "r");
  try {
    const buffer = Buffer.alloc(maximumBytes + 1);
    const { bytesRead } = await file.read(buffer, 0, buffer.length, 0);
    if (bytesRead > maximumBytes) {
      throw new Error("Overlook crash report exceeds the diagnostic size limit");
    }
    return buffer.subarray(0, bytesRead).toString("utf8");
  } finally {
    await file.close();
  }
}

function extractFrames(report: Record<string, unknown>): CrashFrame[] {
  const threads = Array.isArray(report.threads) ? report.threads : [];
  const faultingIndex = safeNumber(report.faultingThread);
  const selected = faultingIndex === undefined
    ? threads.find((thread) => asObject(thread).triggered === true)
    : threads[faultingIndex];
  const rawFrames = asObject(selected).frames;
  if (!Array.isArray(rawFrames)) return [];

  return rawFrames.slice(0, MAXIMUM_FRAMES).flatMap((rawFrame) => {
    const frame = asObject(rawFrame);
    const symbol = safeString(frame.symbol) ?? safeString(frame.symbolLocation);
    if (!symbol) return [];
    const result: CrashFrame = { symbol };
    const sourceFile = safeString(frame.sourceFile, true);
    const sourceLine = safeNumber(frame.sourceLine);
    if (sourceFile !== undefined) result.sourceFile = sourceFile;
    if (sourceLine !== undefined) result.sourceLine = sourceLine;
    return [result];
  });
}

function parseObject(value: string): Record<string, unknown> {
  try {
    return asObject(JSON.parse(value));
  } catch {
    throw new Error("Overlook crash report is not valid JSON");
  }
}

function asObject(value: unknown): Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value)
    ? value as Record<string, unknown>
    : {};
}

function safeString(value: unknown, basenameOnly = false): string | undefined {
  if (typeof value !== "string" || value.length === 0) return undefined;
  const shortened = (basenameOnly ? path.basename(value) : value).slice(0, 300);
  return shortened
    .replace(/\b(?:\d{1,3}\.){3}\d{1,3}\b/g, "[redacted-ip]")
    .replace(/\/(?:Users|home)\/[^\s]+/g, "[redacted-path]");
}

function safeNumber(value: unknown): number | undefined {
  return typeof value === "number" && Number.isFinite(value) ? value : undefined;
}
