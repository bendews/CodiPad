// Bundles the Node extension host, built-in extensions, ripgrep, and optional agent host from pinned VS Code source.
import { verifyPublicBundleInputs } from './public-bundle.mjs';
import * as esbuild from './node_modules/esbuild/lib/main.js';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { fileURLToPath } from 'node:url';
import { packageAgentHost } from './agent-host.mjs';
import { productFromConfiguration } from './product-from-configuration.mjs';

const rawArgs = process.argv.slice(2);
const minify = rawArgs.includes('--minify');
const includeAgentHost = rawArgs.includes('--with-vscode-extras');
const positional = rawArgs.filter(arg => arg !== '--minify' && arg !== '--with-vscode-extras');
if (positional.length < 4) {
  throw new Error('Usage: extension-host.mjs <vscode-src> <output-dir> <deps-dir> <configuration.js> [sqlite-dir] [parcel-dir] [--minify] [--with-vscode-extras]');
}

const scriptRoot = path.dirname(fileURLToPath(import.meta.url));
const repo = path.resolve(scriptRoot, '..');
const [source, output, dependencies, configuration] = positional.slice(0, 4).map(v => path.resolve(v));
const sqliteBuild = path.resolve(positional[4] ?? path.join(repo, '.build/agent-host/sqlite'));
const parcelPackage = path.resolve(positional[5] ?? path.join(repo, '.build/agent-host/parcel-watcher'));

fs.mkdirSync(output, { recursive: true });

const product = productFromConfiguration(fs.readFileSync(configuration, 'utf8'));
const pinnedRevision = JSON.parse(fs.readFileSync(path.join(repo, 'build/source-manifest.json'), 'utf8')).upstream.revision;
if (product.commit !== pinnedRevision) {
  throw new Error('Workbench product commit does not match the pinned VS Code revision');
}
const packageData = JSON.parse(fs.readFileSync(path.join(source, 'package.json'), 'utf8'));
// The packaged extension host and adjacent certificate worker are emitted as CommonJS.
packageData.type = 'commonjs';
fs.writeFileSync(path.join(output, 'product.json'), JSON.stringify(product, null, 2) + '\n');
fs.writeFileSync(path.join(output, 'package.json'), JSON.stringify(packageData, null, 2) + '\n');

const upstreamLock = JSON.parse(fs.readFileSync(path.join(source, 'package-lock.json'), 'utf8'));
const dependencyLock = JSON.parse(fs.readFileSync(path.join(dependencies, 'package-lock.json'), 'utf8'));

const banner =
  'const __codipadMetaUrl=require("node:url").pathToFileURL(__filename).href,' +
  ' __codipadMetaDir=require("node:path").dirname(__filename);' +
  `globalThis._VSCODE_PRODUCT_JSON=${JSON.stringify(product)};` +
  `globalThis._VSCODE_PACKAGE_JSON=${JSON.stringify(packageData)};`;

const result = await esbuild.build({
  absWorkingDir: source,
  entryPoints: ['src/vs/workbench/api/node/extensionHostProcess.ts'],
  bundle: true,
  platform: 'node',
  format: 'cjs',
  target: 'node24',
  minify,
  keepNames: minify,
  outfile: path.join(output, 'extensionHostProcess.js'),
  metafile: true,
  nodePaths: [path.join(dependencies, 'node_modules')],
  tsconfigRaw: { compilerOptions: { experimentalDecorators: true, useDefineForClassFields: false } },
  external: [
    '@vscode/windows-process-tree',
    '@vscode/native-watchdog',
    '@vscode/windows-ca-certs',
    '@vscode/spdlog',
    '@vscode/vsce-sign',
    '@vscode/deviceid',
  ],
  define: {
    'import.meta.url': '__codipadMetaUrl',
    'import.meta.dirname': '__codipadMetaDir',
  },
  banner: { js: banner },
  legalComments: 'linked',
  logLevel: 'info',
});
verifyPublicBundleInputs(result.metafile);
if (!minify) {
  fs.writeFileSync(path.join(output, 'metafile.json'), JSON.stringify(result.metafile, null, 2) + '\n');
} else {
  fs.rmSync(path.join(output, 'metafile.json'), { force: true });
}

function pinnedPackage(name) {
  const key = `node_modules/${name}`;
  const directory = path.join(dependencies, key);
  const manifest = JSON.parse(fs.readFileSync(path.join(directory, 'package.json'), 'utf8'));
  const pin = upstreamLock.packages[key];
  const installed = dependencyLock.packages[key];
  if (!pin?.integrity || manifest.name !== name || manifest.version !== pin.version ||
      installed?.version !== pin.version || installed.integrity !== pin.integrity) {
    throw new Error(`${name} does not match the pinned VS Code lockfile`);
  }
  return { directory, pin };
}

// Stage @vscode/proxy-agent's adjacent certificate worker.
const { directory: proxyPackage, pin: proxyPin } = pinnedPackage('@vscode/proxy-agent');
const certWorkerPath = path.join(proxyPackage, 'out/systemCertificatesWorker.js');
const certWorkerBytes = fs.readFileSync(certWorkerPath);
fs.writeFileSync(path.join(output, 'systemCertificatesWorker.js'), certWorkerBytes);
fs.writeFileSync(path.join(output, 'systemCertificatesWorker.json'), JSON.stringify({
  package: '@vscode/proxy-agent',
  version: proxyPin.version,
  integrity: proxyPin.integrity,
  sha256: createHash('sha256').update(certWorkerBytes).digest('hex'),
}, null, 2) + '\n');

// Package built-in extensions from the pinned VS Code tree.
fs.rmSync(path.join(output, 'extensions'), { recursive: true, force: true });
const node = process.execPath;
const npm = path.join(path.dirname(path.dirname(node)), 'lib/node_modules/npm/bin/npm-cli.js');
const packaging = spawnSync(
  node,
  [path.join(scriptRoot, 'package-extensions.mjs'), source, output, dependencies, node, npm],
  { stdio: 'inherit' },
);
if (packaging.status !== 0) {
  throw new Error(`Built-in extension packaging failed (${packaging.status ?? packaging.signal})`);
}

// Stage the Linux ARM64 ripgrep binary from @vscode/ripgrep-universal.
const { directory: searchPackage } = pinnedPackage('@vscode/ripgrep-universal');
const searchBytes = fs.readFileSync(path.join(searchPackage, 'bin/linux-arm64/rg'));
if (searchBytes.subarray(0, 6).toString('hex') !== '7f454c460201' || searchBytes.readUInt16LE(18) !== 183) {
  throw new Error('ripgrep binary is not a little-endian ARM64 ELF');
}
for (const rel of ['bin/rg', 'node_modules/@vscode/ripgrep/bin/rg']) {
  const dest = path.join(output, rel);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  fs.writeFileSync(dest, searchBytes, { mode: 0o755 });
  fs.chmodSync(dest, 0o755);
}

// The Linux binding is loaded by extensions independently of the stock agent host.
const { directory: ptyPackage } = pinnedPackage('node-pty');
const ptyBinding = 'prebuilds/linux-arm64/pty.node';
const ptyBytes = fs.readFileSync(path.join(ptyPackage, ptyBinding));
if (ptyBytes.length < 64 || ptyBytes.subarray(0, 6).toString('hex') !== '7f454c460201' ||
    ptyBytes.readUInt16LE(16) !== 3 || ptyBytes.readUInt16LE(18) !== 183) {
  throw new Error('node-pty prebuild is not a Linux ARM64 shared library');
}
const ptyDest = path.join(output, 'node_modules/node-pty', ptyBinding);
fs.mkdirSync(path.dirname(ptyDest), { recursive: true });
fs.writeFileSync(ptyDest, ptyBytes, { mode: 0o644 });

// Stage third-party notices.
const notices = path.join(output, 'Notices');
fs.mkdirSync(notices, { recursive: true });
for (const [src, name] of [
  [path.join(searchPackage, 'LICENSE'), 'VSCODE-RIPGREP-LICENSE.txt'],
  [path.join(ptyPackage, 'LICENSE'), 'NODE-PTY-LICENSE.txt'],
  [path.join(proxyPackage, 'LICENSE.md'), 'VSCODE-PROXY-AGENT-LICENSE.txt'],
  [path.join(source, 'LICENSE.txt'), 'VSCODE-LICENSE.txt'],
  [path.join(repo, 'patches/node/NODE-LICENSE'), 'NODE-LICENSE.txt'],
  [path.join(repo, 'patches/node/A-SHELL-LICENSE.txt'), 'A-SHELL-LICENSE.txt'],
  [path.join(repo, 'native/CodiPadNode/NOTICE'), 'CodiPadNode-NOTICE.txt'],
]) {
  fs.copyFileSync(src, path.join(notices, name));
}

// The native terminal resolves its shell scripts relative to the extension host root.
fs.cpSync(path.join(source, 'src/vs/workbench/contrib/terminal/common/scripts'),
  path.join(output, 'terminal-scripts'), { recursive: true });

const agentOutput = path.join(output, 'agent-host');
if (includeAgentHost) {
  const agentStage = fs.mkdtempSync(path.join(repo, '.build/workbench/agent-host-package-'));
  try {
    for (const name of ['product.json', 'package.json']) {
      fs.copyFileSync(path.join(output, name), path.join(agentStage, name));
    }
    await packageAgentHost({ source, output: agentStage, dependencies, repository: repo, sqliteBuild, parcelPackage });
    fs.rmSync(agentOutput, { recursive: true, force: true });
    fs.renameSync(path.join(agentStage, 'agent-host'), agentOutput);
  } finally {
    fs.rmSync(agentStage, { recursive: true, force: true });
  }
} else {
  fs.rmSync(agentOutput, { recursive: true, force: true });
}

// Record executable file modes separately because iOS bundle copying may normalize permissions.
const executableModes = [];
function collectExecutableModes(directory, relative = '') {
  for (const name of fs.readdirSync(directory).sort()) {
    const file = path.join(directory, name);
    const childRelative = path.posix.join(relative, name);
    const stat = fs.lstatSync(file);
    if (stat.isSymbolicLink()) {
      throw new Error(`Exthost must not contain symlinks: ${childRelative}`);
    }
    if (stat.isDirectory()) {
      collectExecutableModes(file, childRelative);
    } else if (stat.isFile() && (stat.mode & 0o111) !== 0) {
      executableModes.push({ path: childRelative, mode: stat.mode & 0o777 });
    }
  }
}
collectExecutableModes(output);
fs.writeFileSync(
  path.join(output, 'executable-modes.json'),
  JSON.stringify({ schemaVersion: 1, entries: executableModes }, null, 2) + '\n',
);
