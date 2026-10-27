import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { pathToFileURL } from "node:url";

const workspace = path.resolve(import.meta.dirname, "..");
const candidate = path.join(workspace, "vendor", "openclaw-weixin-stopfix");

function read(relative) {
  return fs.readFileSync(path.join(candidate, relative), "utf8");
}

for (const monitorPath of ["src/monitor/monitor.ts", "dist/src/monitor/monitor.js"]) {
  const source = read(monitorPath);
  const processAt = source.indexOf("await processOneMessage(full");
  const saveAt = source.indexOf("saveGetUpdatesBuf(syncFilePath, resp.get_updates_buf)");
  assert.ok(processAt >= 0, `${monitorPath}: message processing call missing`);
  assert.ok(saveAt > processAt, `${monitorPath}: cursor must commit after message processing`);
  assert.equal(
    source.indexOf("saveGetUpdatesBuf(syncFilePath, resp.get_updates_buf)", saveAt + 1),
    -1,
    `${monitorPath}: more than one cursor commit found`,
  );
}

for (const channelPath of ["src/channel.ts", "dist/src/channel.js"]) {
  const source = read(channelPath);
  assert.match(source, /stripTargetKindPrefix/);
  assert.match(source, /const to = normalizeWeixinTarget\(ctx\.to\)/);
  assert.doesNotMatch(source, /getContextToken\([^\n]+ctx\.to\)/);
  assert.doesNotMatch(source, /to:\s*ctx\.to/);
}

const packageJson = JSON.parse(read("package.json"));
assert.equal(packageJson.version, "2.4.10-stopfix.1");

const openClawCorePath = path.join(
  process.env.APPDATA,
  "npm",
  "node_modules",
  "openclaw",
  "dist",
  "plugin-sdk",
  "core.js",
);
const { stripTargetKindPrefix } = await import(pathToFileURL(openClawCorePath));
assert.equal(stripTargetKindPrefix("user:demo@im.wechat"), "demo@im.wechat");
assert.equal(stripTargetKindPrefix("demo@im.wechat"), "demo@im.wechat");

console.log(
  JSON.stringify({
    status: "passed",
    cursorCommitAfterProcessing: true,
    recoveryTargetNormalized: true,
    candidateVersion: packageJson.version,
  }),
);
