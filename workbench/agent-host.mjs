// Packages the pinned VS Code agent host and its Linux ARM64 native dependencies.
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import fs from 'node:fs';
import { isBuiltin } from 'node:module';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const ENTRY = 'vs/platform/agentHost/node/agentHostMain';
const ROOTS = [
  'bootstrap-fork',
  ENTRY,
  'vs/platform/agentHost/node/diffWorkerMain',
  'vs/platform/files/node/watcher/watcherMain',
  'vs/platform/agentHost/common/agentService',
];
const SQLITE_KEY = 'node_modules/@vscode/sqlite3';
const PARCEL_KEY = 'node_modules/@parcel/watcher-linux-arm64-glibc';

const readJson = file => JSON.parse(fs.readFileSync(file, 'utf8'));
const fail = message => { throw new Error(`Agent host packaging: ${message}`); };

function confined(root, relative) {
  root = path.resolve(root);
  if (fs.lstatSync(root).isSymbolicLink()) fail(`symlink root: ${root}`);
  if (!relative || path.isAbsolute(relative) || relative.split(/[\\/]/).some(p => p === '..' || !p)) {
    fail(`unsafe relative path: ${relative}`);
  }
  const target = path.join(root, relative);
  for (let cursor = target; cursor !== root; cursor = path.dirname(cursor)) {
    if (fs.existsSync(cursor) && fs.lstatSync(cursor).isSymbolicLink()) {
      fail(`symlink input: ${cursor}`);
    }
  }
  return target;
}

async function sha256(file) {
  const digest = createHash('sha256');
  for await (const chunk of fs.createReadStream(file)) digest.update(chunk);
  return digest.digest('hex');
}

async function assertSha256(file, expected) {
  if (!/^[a-f0-9]{64}$/.test(expected ?? '') || await sha256(file) !== expected) {
    fail(`SHA-256 mismatch: ${file}`);
  }
}

function assertLinuxArm64Elf(file) {
  const bytes = fs.readFileSync(file);
  if (bytes.length < 64 || bytes.subarray(0, 6).toString('hex') !== '7f454c460201' ||
      bytes.readUInt16LE(16) !== 3 || bytes.readUInt16LE(18) !== 183) {
    fail(`not a Linux ARM64 ELF ET_DYN: ${file}`);
  }
}

function copyTree(source, destination, omit = new Set()) {
  fs.mkdirSync(destination, { recursive: true });
  for (const item of fs.readdirSync(source, { withFileTypes: true })) {
    if (omit.has(item.name)) continue;
    const from = path.join(source, item.name);
    const to = path.join(destination, item.name);
    if (item.isDirectory()) {
      copyTree(from, to);
    } else if (item.isFile()) {
      fs.copyFileSync(from, to);
      fs.chmodSync(to, fs.statSync(from).mode & 0o777);
    } else {
      fail(`unsupported package entry: ${from}`);
    }
  }
}

export async function verifySQLite({ sqliteBuild, upstreamLock }) {
  const receiptPath = path.join(sqliteBuild, 'receipt.json');
  const receipt = readJson(receiptPath);
  assert.equal(receipt.schemaVersion, 1);
  assert.equal(receipt.completionState, 'passed', 'SQLite build did not pass');
  assert.equal(receipt.target, 'linux-aarch64');
  assert.equal(receipt.sqlitePin?.integrity, upstreamLock.packages[SQLITE_KEY]?.integrity);
  assert.equal(receipt.artifact?.path, 'package/build/Release/vscode-sqlite3.node');
  assert.equal(receipt.artifact?.export, 'napi_register_module_v1');

  const binary = confined(sqliteBuild, receipt.artifact.path);
  assert.equal(fs.statSync(binary).size, receipt.artifact.bytes);
  await assertSha256(binary, receipt.artifact.sha256);
  assertLinuxArm64Elf(binary);
  return { receiptSha256: await sha256(receiptPath), binarySha256: receipt.artifact.sha256 };
}

export const launcherSource = `const raw = process.env.CODIPAD_AGENT_HOST_LAUNCH_CONFIG;
delete process.env.CODIPAD_AGENT_HOST_LAUNCH_CONFIG;
function reject() { throw new Error('Invalid native agent host launch configuration'); }
if (typeof raw !== 'string' || Buffer.byteLength(raw, 'utf8') > 65536) reject();
const config = JSON.parse(raw);
const isObj = v => v !== null && typeof v === 'object' && !Array.isArray(v);
const isText = v => typeof v === 'string' && !v.includes('\\0') && v.length <= 8192;
function validateSettings(value, types) {
  if (!isObj(value)) reject();
  for (const [key, item] of Object.entries(value)) {
    const type = types[key];
    const invalid =
      type === 'boolean' ? typeof item !== 'boolean'
      : type === 'string' ? !isText(item)
      : type === 'array' ? !Array.isArray(item) || item.length > 128 || !item.every(isText)
      : type === 'map' ? !isObj(item) || Object.keys(item).length > 128 || !Object.entries(item).every(([k, v]) => isText(k) && isText(v))
      : true;
    if (invalid) reject();
  }
}
if (!isObj(config) || Object.keys(config).some(k => !['schemaVersion','sdk','otel','otelPolicy','telemetryLevel'].includes(k)) ||
    config.schemaVersion !== 1 || !['off','crash','error','all'].includes(config.telemetryLevel)) reject();
validateSettings(config.sdk, { codexSdkRoot: 'string', codexHome: 'string', codexBinaryArgs: 'array', claudeAgentEnabled: 'boolean', codexAgentEnabled: 'boolean' });
const otelTypes = { enabled: 'boolean', exporterType: 'string', otlpProtocol: 'string', otlpEndpoint: 'string', captureContent: 'boolean', captureIdentity: 'boolean', outfile: 'string', serviceName: 'string', resourceAttributes: 'map', dbSpanExporterEnabled: 'boolean' };
validateSettings(config.otel, otelTypes);
validateSettings(config.otelPolicy, otelTypes);
const parentEnv = { ...process.env };
if (parentEnv.VSCODE_AGENT_HOST_HOST !== '127.0.0.1' || parentEnv.VSCODE_AGENT_HOST_PORT !== '0' ||
    !parentEnv.VSCODE_AGENT_HOST_CONNECTION_TOKEN || parentEnv.VSCODE_AGENT_HOST_SOCKET_PATH !== undefined) reject();
await import('./out/bootstrap-esm.js');
const { buildAgentSdkEnv, buildAgentHostOTelEnv } = await import('./out/vs/platform/agentHost/common/agentService.js');
Object.assign(process.env, buildAgentSdkEnv(config.sdk, parentEnv), buildAgentHostOTelEnv(config.otel, parentEnv, config.otelPolicy, parentEnv));
for (const key of ['VSCODE_AGENT_HOST_HOST', 'VSCODE_AGENT_HOST_PORT', 'VSCODE_AGENT_HOST_CONNECTION_TOKEN', 'VSCODE_AGENT_HOST_SOCKET_PATH']) {
  if (process.env[key] !== parentEnv[key]) reject();
}
process.env.VSCODE_ESM_ENTRYPOINT = '${ENTRY}';
await import('./out/bootstrap-fork.js');
`;

export async function packageAgentHost({ source, output, dependencies, repository, sqliteBuild, parcelPackage }) {
  for (const value of [source, output, dependencies, repository, sqliteBuild, parcelPackage]) {
    if (!path.isAbsolute(value ?? '')) fail('all input paths must be absolute');
  }

  const manifest = readJson(path.join(repository, 'build/source-manifest.json'));
  const pin = manifest.upstream;
  assert.equal(execFileSync('git', ['-C', source, 'rev-parse', 'HEAD'], { encoding: 'utf8' }).trim(), pin.revision);

  const upstreamLock = readJson(path.join(source, 'package-lock.json'));
  const dependencyLock = readJson(path.join(dependencies, 'package-lock.json'));
  const sqlite = await verifySQLite({ sqliteBuild, upstreamLock });

  const parcelPin = upstreamLock.packages[PARCEL_KEY];
  if (!fs.existsSync(path.join(parcelPackage, 'package.json'))) {
    fail(`missing ${PARCEL_KEY}; run scripts/build_rootfs.py --addons-only`);
  }
  const parcelManifest = readJson(path.join(parcelPackage, 'package.json'));
  assert.equal(parcelManifest.version, parcelPin.version);
  assertLinuxArm64Elf(path.join(parcelPackage, 'watcher.node'));

  const nativeOverrides = new Map([
    [SQLITE_KEY, path.join(sqliteBuild, 'package')],
    [PARCEL_KEY, parcelPackage],
  ]);

  const target = path.join(output, 'agent-host');
  if (fs.existsSync(target)) fail(`output already exists: ${target}`);

  const esbuild = await import(pathToFileURL(path.join(repository, 'workbench/node_modules/esbuild/lib/main.js')).href);
  const compileOptions = {
    absWorkingDir: source,
    platform: 'node',
    format: 'esm',
    target: 'node24',
    tsconfigRaw: { compilerOptions: { experimentalDecorators: true, useDefineForClassFields: false } },
    logLevel: 'silent',
  };

  const graph = await esbuild.build({
    ...compileOptions,
    entryPoints: ROOTS.map(r => `src/${r}.ts`),
    bundle: true,
    packages: 'external',
    metafile: true,
    write: false,
    outdir: path.join(target, '.graph'),
  });
  const sourceFiles = Object.keys(graph.metafile.inputs);
  if (sourceFiles.some(file => !file.startsWith('src/') || !file.endsWith('.ts'))) {
    fail('unexpected graph input');
  }

  const requests = [...new Set(
    Object.values(graph.metafile.outputs).flatMap(o =>
      o.imports.filter(i => i.external && !isBuiltin(i.path)).map(i => i.path),
    ),
  )];
  const packageName = name => (name.startsWith('@') ? name.split('/').slice(0, 2).join('/') : name.split('/')[0]);
  const packages = new Map();

  function locate(name, parentKey = '') {
    let cursor = parentKey;
    for (;;) {
      const key = cursor ? `${cursor}/node_modules/${name}` : `node_modules/${name}`;
      if (nativeOverrides.has(key) || fs.existsSync(path.join(dependencies, key, 'package.json'))) return key;
      if (!cursor) return undefined;
      const idx = cursor.lastIndexOf('/node_modules/');
      cursor = idx < 0 ? '' : cursor.slice(0, idx);
    }
  }

  function addPackage(name, parentKey = '', optional = false) {
    const key = locate(name, parentKey);
    if (!key) {
      if (optional) return;
      fail(`required dependency absent: ${name} from ${parentKey || 'entry'}`);
    }
    if (packages.has(key)) return;
    const location = nativeOverrides.get(key) ?? path.join(dependencies, key);
    const pkg = readJson(path.join(location, 'package.json'));
    const pinned = upstreamLock.packages[key];
    const installed = dependencyLock.packages[key];
    if (!pinned?.integrity || pkg.version !== pinned.version || pkg.name !== name ||
        (!nativeOverrides.has(key) && (installed?.version !== pinned.version || installed?.integrity !== pinned.integrity))) {
      fail(`dependency pin differs: ${key}`);
    }
    if ((pkg.os && !pkg.os.includes('linux')) || (pkg.cpu && !pkg.cpu.includes('arm64'))) {
      if (!optional) fail(`required dependency is not Linux ARM64: ${name}`);
      return;
    }
    packages.set(key, { location, manifest: pkg, version: pinned.version, integrity: pinned.integrity });
    const optionalNames = new Set(Object.keys(pkg.optionalDependencies ?? {}));
    for (const dep of Object.keys(pkg.dependencies ?? {})) addPackage(dep, key, optionalNames.has(dep));
    for (const dep of optionalNames) addPackage(dep, key, true);
  }

  for (const request of requests) {
    if (request.startsWith('.') || request.startsWith('/')) continue;
    addPackage(packageName(request), '', packageName(request) === '@anthropic-ai/claude-agent-sdk');
  }
  addPackage('@parcel/watcher-linux-arm64-glibc');

  const noticeLock = manifest.agentHost.noticeInputs;
  const supplementaryNotices = {};
  for (const [key, notice] of Object.entries(noticeLock.notices)) {
    const pinned = packages.get(key);
    assert(pinned, `notice package missing from runtime: ${key}`);
    await assertSha256(confined(repository, notice.path), notice.sha256);
    supplementaryNotices[key] = { ...notice, path: 'Notices/' + path.basename(notice.path) };
  }

  fs.mkdirSync(path.join(target, 'out'), { recursive: true });
  for (const name of ['product.json', 'package.json']) {
    fs.copyFileSync(path.join(output, name), path.join(target, name));
  }
  fs.writeFileSync(path.join(target, 'out/package.json'), '{"type":"module"}\n');

  await esbuild.build({
    ...compileOptions,
    entryPoints: sourceFiles,
    bundle: false,
    outbase: 'src',
    outdir: path.join(target, 'out'),
    legalComments: 'inline',
  });

  for (const [key, value] of packages) {
    copyTree(value.location, path.join(target, key), new Set(['node_modules', '.git', '.codipad-parcel.json']));
  }
  for (const resource of ['vs/base/node/terminateProcess.sh', 'vs/workbench/contrib/terminal/common/scripts']) {
    const from = path.join(source, 'src', resource);
    const to = path.join(target, 'out', resource);
    if (fs.statSync(from).isDirectory()) {
      copyTree(from, to);
    } else {
      fs.mkdirSync(path.dirname(to), { recursive: true });
      fs.copyFileSync(from, to);
      fs.chmodSync(to, fs.statSync(from).mode & 0o777);
    }
  }
  for (const name of ['LICENSE.txt', 'ThirdPartyNotices.txt']) {
    fs.copyFileSync(path.join(source, name), path.join(target, name));
  }
  for (const [key, notice] of Object.entries(supplementaryNotices)) {
    fs.mkdirSync(path.join(target, 'Notices'), { recursive: true });
    fs.copyFileSync(confined(repository, noticeLock.notices[key].path), confined(target, notice.path));
  }
  fs.writeFileSync(path.join(target, 'launch.mjs'), launcherSource);

  const files = {};
  const executableFiles = [];
  async function inventory(directory, prefix = '') {
    for (const item of fs.readdirSync(directory, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
      const name = prefix + item.name;
      const file = path.join(directory, item.name);
      if (item.isDirectory()) {
        await inventory(file, name + '/');
      } else {
        files[name] = await sha256(file);
        if (fs.statSync(file).mode & 0o111) executableFiles.push(name);
      }
    }
  }
  await inventory(target);

  for (const elfFile of [
    'node_modules/@vscode/sqlite3/build/Release/vscode-sqlite3.node',
    'node_modules/node-pty/prebuilds/linux-arm64/pty.node',
    'node_modules/@parcel/watcher-linux-arm64-glibc/watcher.node',
  ]) {
    assertLinuxArm64Elf(path.join(target, elfFile));
  }
  for (const required of [
    'node_modules/@vscode/proxy-agent/out/systemCertificatesWorker.js',
    'node_modules/@vscode/tree-sitter-wasm/wasm/tree-sitter.wasm',
    'node_modules/@vscode/tree-sitter-wasm/wasm/tree-sitter-bash.wasm',
    'node_modules/@vscode/tree-sitter-wasm/wasm/tree-sitter-powershell.wasm',
    'node_modules/@vscode/ripgrep-universal/bin/linux-arm64/rg',
  ]) {
    if (!files[required]) fail(`required runtime resource missing: ${required}`);
  }

  const receipt = {
    schemaVersion: 1,
    completionState: 'passed',
    target: 'linux-arm64',
    upstreamRevision: pin.revision,
    launcher: { path: 'agent-host/launch.mjs', sha256: files['launch.mjs'] },
    sqlite,
    files,
    executableFiles,
  };
  fs.writeFileSync(path.join(target, 'receipt.json'), JSON.stringify(receipt, null, 2) + '\n');
  return receipt;
}
