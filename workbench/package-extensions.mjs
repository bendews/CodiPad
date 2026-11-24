// Assemble the pinned source extensions from their manifests. Generated extension
// entrypoints stay in the ignored build output; source trees and downloaded packages
// in vendor/vscode are never modified.
import * as esbuild from './node_modules/esbuild/lib/main.js';
import {createHash} from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import {builtinModules, createRequire} from 'node:module';
import path from 'node:path';
import {spawnSync} from 'node:child_process';
import {pipeline} from 'node:stream/promises';
import {fileURLToPath} from 'node:url';
import yauzl from './node_modules/yauzl/index.js';
import minimatch from 'minimatch';

const [source, output, dependencies, node, npm] = process.argv.slice(2).map(value => value && path.resolve(value));
if (!source || !output || !dependencies || !node || !npm) {
  throw new Error('Expected source, output, dependencies, node, and npm');
}

const upstreamExtensions = path.join(source, 'extensions');
const builtins = path.join(output, 'extensions');
const builtinVsixCache = process.env.CODIPAD_BUILTIN_VSIX_CACHE || path.join(os.homedir(), 'Library', 'Caches', 'CodiPad', 'builtin-vsix');
fs.mkdirSync(builtins, {recursive:true});
fs.copyFileSync(path.join(upstreamExtensions, 'tsconfig.base.json'), path.join(builtins, 'tsconfig.base.json'));
for (const helper of ['esbuild-common.mts', 'esbuild-extension-common.mts', 'esbuild-webview-common.mts']) {
  fs.copyFileSync(path.join(upstreamExtensions, helper), path.join(builtins, helper));
}
const upstreamEsbuild = path.join(builtins, 'node_modules/esbuild');
fs.mkdirSync(path.dirname(upstreamEsbuild), {recursive:true});
fs.cpSync(path.resolve(path.dirname(fileURLToPath(import.meta.url)), 'node_modules/vscode-esbuild'), upstreamEsbuild, {recursive:true});
const helperModules = path.join(path.dirname(fileURLToPath(import.meta.url)), 'node_modules');
for (const name of ['fs-extra', 'graceful-fs', 'jsonfile', 'universalify']) {
  fs.cpSync(path.join(helperModules, name), path.join(builtins, 'node_modules', name), {recursive:true});
}

// Honor VS Code's own build exclusions (tests, development extensions, and
// separately downloaded extensions) instead of maintaining a CodiPad list.
const buildSource = fs.readFileSync(path.join(source, 'build/lib/extensions.ts'), 'utf8');
const upstreamVsce = JSON.parse(fs.readFileSync(path.join(source, 'build/package.json'), 'utf8')).devDependencies?.['@vscode/vsce'];
if (upstreamVsce !== '3.6.1') throw new Error('Review VSCE file selection for the new upstream version');
const dependencySource = buildSource.match(/const packagedDependenciesByExtension:\s*Record<string, string\[\]>\s*=\s*\{([\s\S]*?)\};/);
if (!dependencySource) throw new Error('Could not read upstream esbuild dependency exceptions');
const packagedDependencies = new Map();
const pairs = /\s*'([^']+)'\s*:\s*\[([^\]]*)\]\s*,?/gy;
let consumed = 0, pair;
while ((pair = pairs.exec(dependencySource[1]))) {
  if (pair.index !== consumed || packagedDependencies.has(pair[1])) throw new Error('Invalid upstream dependency exception');
  const raw = pair[2].trim();
  if (raw && !/^(?:'[^']+'\s*,?\s*)+$/.test(raw)) throw new Error('Unsupported upstream dependency exception');
  packagedDependencies.set(pair[1], [...raw.matchAll(/'([^']+)'/g)].map(match => match[1]));
  consumed = pairs.lastIndex;
}
if (dependencySource[1].slice(consumed).trim()) throw new Error('Unsupported upstream dependency exceptions');
const excludedSource = buildSource.match(/const excludedExtensions = \[([\s\S]*?)\];/);
if (!excludedSource) throw new Error('Could not read upstream excluded extension inventory');
const excluded = new Set([...excludedSource[1].matchAll(/'([^']+)'/g)].map(match => match[1]));
const entries = [];
const sourceManifestInventory = fs.readdirSync(upstreamExtensions).sort().flatMap(directory => {
  const manifestPath = path.join(upstreamExtensions, directory, 'package.json');
  if (!fs.existsSync(manifestPath)) return [];
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const isExcluded = excluded.has(directory);
  return [{directory, id:`${manifest.publisher || 'unknown'}.${manifest.name || directory}`, version:manifest.version,
    classification:manifest.main || manifest.browser ? 'runtime' : 'declarative', hasContributions:Boolean(manifest.contributes),
    packaging:isExcluded ? 'upstream-build-excluded' : 'packaged', reason:isExcluded ? 'build/lib/extensions.ts:excludedExtensions' : null}];
});

function copyTree(from, to, relative = '') {
  for (const item of fs.readdirSync(from, {withFileTypes:true})) {
    const rel = path.join(relative, item.name);
    if (['.git', 'node_modules', 'test', 'tests', 'test-workspace', '.vscode-test', 'fixtures', 'testdata', 'test-data'].includes(item.name)) continue;
    const src = path.join(from, item.name), dest = path.join(to, item.name);
    if (item.isDirectory()) {
      fs.mkdirSync(dest, {recursive:true});
      copyTree(src, dest, rel);
    } else if (item.isFile()) {
      fs.copyFileSync(src, dest);
    } else if (item.isSymbolicLink()) {
      fs.cpSync(src, dest, {verbatimSymlinks:true});
    }
  }
}

// Adapted from VSCE 3.6.1 collectFiles with dependency discovery disabled.
// Copyright Microsoft Corporation. See workbench/notices/VSCE-LICENSE.txt.
function extensionFileFilter(root) {
  const defaults = [
    '.vscodeignore', 'package-lock.json', 'npm-debug.log', 'yarn.lock', 'yarn-error.log',
    'npm-shrinkwrap.json', '.editorconfig', '.npmrc', '.yarnrc', '.gitattributes', '*.todo',
    'tslint.yaml', '.eslintrc*', '.babelrc*', '.prettierrc*', '.cz-config.js', '.commitlintrc*',
    'webpack.config.js', 'ISSUE_TEMPLATE.md', 'CONTRIBUTING.md', 'PULL_REQUEST_TEMPLATE.md',
    'CODE_OF_CONDUCT.md', '.github', '.travis.yml', 'appveyor.yml', '**/.git', '**/.git/**',
    '**/*.vsix', '**/.DS_Store', '**/*.vsixmanifest', '**/.vscode-test/**', '**/.vscode-test-web/**',
  ];
  const ignorePath = path.join(root, '.vscodeignore');
  let patterns;
  if (fs.existsSync(ignorePath)) {
    patterns = fs.readFileSync(ignorePath, 'utf8').split(/[\n\r]/).map(line => line.trim())
      .filter(line => line && !line.startsWith('#'));
  } else {
    const {files} = JSON.parse(fs.readFileSync(path.join(root, 'package.json'), 'utf8'));
    patterns = files ? [...files.map(file => '!' + file), '**'] : [];
  }
  const directories = patterns.filter(pattern => !/(^|\/)[^/]*\*[^/]*$/.test(pattern))
    .map(pattern => pattern.endsWith('/') ? pattern + '**' : pattern + '/**');
  const excludes = [], includes = [];
  for (const pattern of [...defaults, ...patterns, ...directories, '!package.json', '!README.md']) {
    const negate = pattern.startsWith('!');
    const matcher = new minimatch.Minimatch(negate ? pattern.slice(1) : pattern, {dot:true});
    (negate ? includes : excludes).push(matcher);
  }
  return file => !file.startsWith('node_modules/') && !/\r$/m.test(file) &&
    (!excludes.some(rule => rule.match(file)) || includes.some(rule => rule.match(file)));
}

// Match the pinned upstream esbuild packaging contract: VSCE's npm-free file
// selection plus the dependencies explicitly listed in upstream's build script.
async function selectBundledFiles(root, name, nestedScopes) {
  const modulesRoot = path.join(root, 'node_modules');
  if (fs.existsSync(modulesRoot)) {
    removeBinDirectories(modulesRoot);
    materializeLocalLinks(modulesRoot, root);
  }
  for (const scope of nestedScopes) {
    const scopeRoot = path.join(root, scope.path);
    const modules = path.join(scopeRoot, 'node_modules');
    if (fs.existsSync(modules)) {
      removeBinDirectories(modules);
      materializeLocalLinks(modules, scopeRoot);
    }
  }
  materializeLocalLinks(root, root);
  const includeFile = extensionFileFilter(root);
  const selected = new Set();
  function addExceptionFiles(directory, relative) {
    for (const item of fs.readdirSync(directory, {withFileTypes:true})) {
      const rel = path.posix.join(relative, item.name);
      const child = path.join(directory, item.name);
      if (item.isDirectory()) addExceptionFiles(child, rel);
      else if (item.isFile() && (!rel.split('/').includes('build') || rel.endsWith('.node'))) selected.add(rel);
      else if (!item.isFile()) throw new Error(`Unsupported upstream dependency entry: ${rel}`);
    }
  }
  for (const dependency of packagedDependencies.get(name) || []) {
    if (!/^(?:@[a-zA-Z0-9._-]+\/)?[a-zA-Z0-9._-]+$/.test(dependency)) throw new Error('Invalid upstream dependency exception');
    const relative = `node_modules/${dependency}`;
    addExceptionFiles(path.join(root, relative), relative);
  }
  // Nested packages have independently built entrypoints and dependencies.
  // Preserve their complete scope until their own bundling is established.
  function retainScope(directory, relative) {
    for (const item of fs.readdirSync(directory, {withFileTypes:true})) {
      const rel = path.posix.join(relative, item.name), child = path.join(directory, item.name);
      if (item.isDirectory()) retainScope(child, rel);
      else if (item.isFile()) selected.add(rel);
      else throw new Error(`Unsupported nested runtime entry: ${rel}`);
    }
  }
  for (const scope of nestedScopes) {
    const scopeRoot = path.join(root, scope.path);
    if (fs.existsSync(scopeRoot)) retainScope(scopeRoot, scope.path);
  }
  for (const relative of selected) {
    if (typeof relative !== 'string' || path.posix.isAbsolute(relative) || relative.split('/').some(part => !part || part === '.' || part === '..')) {
      throw new Error(`Invalid upstream package asset: ${relative}`);
    }
    const item = path.join(root, relative);
    if (!fs.lstatSync(item).isFile()) throw new Error(`Unsupported upstream package asset: ${relative}`);
  }
  function prune(directory, relative = '') {
    for (const item of fs.readdirSync(directory, {withFileTypes:true})) {
      const rel = path.posix.join(relative, item.name), child = path.join(directory, item.name);
      if (item.isDirectory()) {
        prune(child, rel);
        if (!fs.readdirSync(child).length) fs.rmdirSync(child);
      } else if (includeFile(rel)) selected.add(rel);
      else if (!selected.has(rel)) fs.rmSync(child, {force:true});
    }
  }
  prune(root);
  return selected.size;
}

function sourceEntry(extension, main) {
  const target = main.replace(/^\.\//, '');
  const candidates = [];
  const sourcePath = target.replace(/(^|\/)out\//, '$1src/');
  const stem = sourcePath.replace(/\.(?:js|mjs|cjs)$/, '');
  const suffixes = path.extname(sourcePath) ? ['', '.ts', '.mts', '.cts'] : ['.ts', '.mts', '.cts', '.js', '.mjs', '.cjs'];
  for (const suffix of suffixes) candidates.push(path.join(extension, stem + suffix));
  // A few upstream extensions put Node sources under client/src/node while
  // declaring their emitted path under client/out/node.
  for (const candidate of candidates) if (fs.existsSync(candidate)) return candidate;
  return undefined;
}

function sourceDirectories(root, found = []) {
  for (const item of fs.readdirSync(root, {withFileTypes:true})) {
    if (!item.isDirectory() || ['node_modules', 'test', 'tests', 'test-workspace', 'fixtures', 'testdata', 'test-data'].includes(item.name)) continue;
    const child = path.join(root, item.name);
    if (item.name === 'src' && fs.readdirSync(child).some(name => /\.(?:ts|mts|cts)$/.test(name))) found.push(child);
    sourceDirectories(child, found);
  }
  return found;
}

function packageScopes(root, relative = '', found = []) {
  for (const item of fs.readdirSync(root, {withFileTypes:true})) {
    if (!item.isDirectory() || ['node_modules', 'test', 'tests', 'test-workspace', '.vscode-test', 'fixtures', 'testdata', 'test-data'].includes(item.name)) continue;
    const child = path.join(root, item.name);
    const childRelative = path.join(relative, item.name);
    const manifestPath = path.join(child, 'package.json');
    if (fs.existsSync(manifestPath)) {
      const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
      if (manifest.main || manifest.type || fs.existsSync(path.join(child, 'package-lock.json'))) {
        found.push({root:child, relative:childRelative, manifest, manifestPath,
          lockPath:path.join(child, 'package-lock.json')});
      }
    }
    packageScopes(child, childRelative, found);
  }
  return found;
}

function typescriptFiles(root, found = []) {
  for (const item of fs.readdirSync(root, {withFileTypes:true})) {
    if (item.isDirectory()) {
      if (!['node_modules', 'test', 'tests', 'test-workspace', 'fixtures', 'testdata', 'test-data'].includes(item.name)) typescriptFiles(path.join(root, item.name), found);
    } else if (/\.(?:ts|mts|cts)$/.test(item.name) && !/\.d\.(?:ts|mts|cts)$/.test(item.name)) {
      found.push(path.join(root, item.name));
    }
  }
  return found;
}

function stripSourceTypeScript(root) {
  for (const item of fs.readdirSync(root, {withFileTypes:true})) {
    const child = path.join(root, item.name);
    if (item.isDirectory()) stripSourceTypeScript(child);
    else if (item.isFile() && /\.(?:ts|mts|cts)$/.test(item.name)) fs.rmSync(child, {force:true});
  }
}

function relativeReferences(value, result = new Set()) {
  if (Array.isArray(value)) for (const item of value) relativeReferences(item, result);
  else if (value && typeof value === 'object') for (const item of Object.values(value)) relativeReferences(item, result);
  else if (typeof value === 'string' && value.startsWith('./')) result.add(value);
  return result;
}

function isPackageFile(root, candidate) {
  return candidate.startsWith(root + path.sep) && fs.existsSync(candidate) && fs.statSync(candidate).isFile()
    && fs.realpathSync(candidate).startsWith(fs.realpathSync(root) + path.sep);
}

function runtimeEntrypointFile(root, entrypoint) {
  const target = path.resolve(root, entrypoint);
  if (!target.startsWith(root + path.sep)) return undefined;
  return [target, `${target}.js`, `${target}.cjs`, `${target}.mjs`, path.join(target, 'index.js')]
    .find(candidate => isPackageFile(root, candidate));
}

function entrypointExists(root, entrypoint) {
  return typeof entrypoint !== 'string' || Boolean(runtimeEntrypointFile(root, entrypoint));
}

function validateLanguageAssets(root, manifest, name) {
  const contributes = manifest.contributes || {};
  const assets = [
    ...(contributes.grammars || []).map(item => item.path),
    ...(contributes.snippets || []).map(item => item.path),
    ...(contributes.languages || []).filter(item => item.configuration !== undefined).map(item => item.configuration),
  ];
  for (const asset of assets) {
    if (typeof asset !== 'string' || !isPackageFile(root, path.resolve(root, asset))) {
      throw new Error(`${name} has missing language contribution resource: ${asset}`);
    }
  }
}

function optionalDependenciesFromLock(lockPath) {
  if (!fs.existsSync(lockPath)) return [];
  const lock = JSON.parse(fs.readFileSync(lockPath, 'utf8'));
  const result = new Set(Object.keys(lock.dependencies || {}).filter(name => lock.dependencies[name].optional));
  for (const metadata of Object.values(lock.packages || {})) {
    for (const name of Object.keys(metadata.optionalDependencies || {})) result.add(name);
    for (const [name, declaration] of Object.entries(metadata.peerDependenciesMeta || {})) {
      if (declaration.optional) result.add(name);
    }
  }
  return [...result].sort();
}

function staticRuntimeSpecifiers(source) {
  const tokens = [];
  for (let index = 0; index < source.length;) {
    const char = source[index];
    if (/\s/.test(char)) { index++; continue; }
    if (char === '/' && source[index + 1] === '/') {
      index = source.indexOf('\n', index + 2);
      if (index < 0) break;
      continue;
    }
    if (char === '/' && source[index + 1] === '*') {
      const end = source.indexOf('*/', index + 2);
      index = end < 0 ? source.length : end + 2;
      continue;
    }
    if (char === '/') {
      const previous = tokens.at(-1);
      const regexMayStart = !previous || previous.type === 'punctuation' && '([{=,:;!?&|+-*%^~<>'.includes(previous.value) ||
        previous.type === 'identifier' && ['return', 'throw', 'case', 'delete', 'void', 'typeof', 'yield', 'await', 'in', 'of', 'instanceof'].includes(previous.value);
      if (regexMayStart) {
        index++;
        let inCharacterClass = false;
        while (index < source.length) {
          if (source[index] === '\\') { index += 2; continue; }
          if (source[index] === '[') inCharacterClass = true;
          else if (source[index] === ']') inCharacterClass = false;
          else if (source[index] === '/' && !inCharacterClass) { index++; break; }
          else if (source[index] === '\n') break;
          index++;
        }
        while (/[A-Za-z]/.test(source[index] || '')) index++;
        continue;
      }
    }
    if (char === '`') {
      index++;
      while (index < source.length) {
        if (source[index] === '\\') { index += 2; continue; }
        if (source[index++] === '`') break;
      }
      continue;
    }
    if (char === '"' || char === "'") {
      const quote = char, start = ++index;
      while (index < source.length && source[index] !== quote) {
        if (source[index] === '\\') index++;
        index++;
      }
      tokens.push({type:'string', value:source.slice(start, index)});
      index++;
      continue;
    }
    if (/[A-Za-z_$]/.test(char)) {
      const start = index++;
      while (index < source.length && /[A-Za-z0-9_$]/.test(source[index])) index++;
      tokens.push({type:'identifier', value:source.slice(start, index)});
      continue;
    }
    tokens.push({type:'punctuation', value:char});
    index++;
  }
  const result = new Set();
  for (let index = 0; index < tokens.length; index++) {
    const token = tokens[index];
    if (token.type !== 'identifier') continue;
    if ((token.value === 'require' || token.value === 'import') && tokens[index + 1]?.value === '(' && tokens[index + 2]?.type === 'string' && tokens[index + 3]?.value === ')') {
      result.add(tokens[index + 2].value);
    } else if (token.value === 'import' && tokens[index + 1]?.type === 'string') {
      result.add(tokens[index + 1].value);
    } else if (token.value === 'import' || token.value === 'export') {
      for (let cursor = index + 1; cursor < tokens.length && tokens[cursor].value !== ';'; cursor++) {
        if (tokens[cursor].value === 'from' && tokens[cursor + 1]?.type === 'string') {
          result.add(tokens[cursor + 1].value);
          break;
        }
      }
    }
  }
  return result;
}

function auditRuntimeEntrypoint(root, entrypoint, optionalDependencies = new Set()) {
  const file = runtimeEntrypointFile(root, entrypoint);
  if (!file) return {entrypoint, status:'missing', unresolved:[]};
  const queue = [file];
  const visited = new Set();
  const resolutions = new Map();
  const builtinSet = new Set(builtinModules.flatMap(name => [name, name.replace(/^node:/, '')]));
  while (queue.length) {
    const current = queue.pop();
    if (visited.has(current)) continue;
    visited.add(current);
    const source = fs.readFileSync(current, 'utf8');
    for (const specifier of staticRuntimeSpecifiers(source)) {
      if (resolutions.has(specifier)) continue;
      if (specifier === 'vscode' || specifier.startsWith('vscode/')) {
        resolutions.set(specifier, {specifier, provider:'extension-host-api'});
        continue;
      }
      if (specifier.startsWith('node:') || builtinSet.has(specifier)) {
        resolutions.set(specifier, {specifier, provider:'node-builtin'});
        continue;
      }
      try {
        const resolved = createRequire(current).resolve(specifier);
        const relative = specifier.startsWith('./') || specifier.startsWith('../');
        resolutions.set(specifier, {specifier, provider:relative ? 'packaged-file' : 'locked-package'});
        if (relative && /\.(?:[cm]?js|json)$/.test(resolved)) queue.push(resolved);
      } catch (error) {
        const optional = optionalDependencies.has(specifier);
        resolutions.set(specifier, {specifier, provider:optional ? 'optional-package-not-installed' : 'unresolved', code:error.code || 'ERR_RESOLVE'});
      }
    }
  }
  const unresolved = [...resolutions.values()].filter(item => item.provider === 'unresolved');
  return {entrypoint, status:unresolved.length ? 'unresolved-static-references' : 'static-references-resolved-best-effort',
    filesScanned:visited.size, dependencies:[...resolutions.values()], unresolved};
}

for (const dir of fs.readdirSync(upstreamExtensions).sort()) {
  const extension = path.join(upstreamExtensions, dir);
  const manifestPath = path.join(extension, 'package.json');
  if (!fs.existsSync(manifestPath) || excluded.has(dir)) continue;
  const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
  const contributions = manifest.contributes || {};
  const destination = path.join(builtins, dir);
  fs.rmSync(destination, {recursive:true, force:true});
  fs.mkdirSync(destination, {recursive:true});
  copyTree(extension, destination);

  const declarations = ['languages', 'grammars', 'snippets', 'themes', 'iconThemes', 'productIconThemes']
    .filter(key => Array.isArray(contributions[key]) && contributions[key].length);
  const languageRuntime = Boolean(manifest.main && (
    declarations.length || manifest.categories?.includes('Programming Languages')
  ));
  const runtimeExtension = Boolean(manifest.main || manifest.browser);
  const hasDeclaredAssetBuild = Object.entries(manifest.scripts || {}).some(([name, command]) =>
    /^build/i.test(name) && !/(?:watch|test|lint|install|setup)/i.test(name) &&
    /^node\s+(?:\.\/)?[^\s]+\.mts(?:\s|$)/.test(command));
  const record = {
    directory: dir,
    id: `${manifest.publisher || 'unknown'}.${manifest.name || dir}`,
    version: manifest.version,
    classification: manifest.main || manifest.browser ? 'runtime' : 'declarative',
    hasContributions: Boolean(manifest.contributes),
    languageRuntime,
    declarations,
    provenance: 'pinned-vscode-source',
    main: manifest.main || null,
    dependencyLockSha256: fs.existsSync(path.join(extension, 'package-lock.json'))
      ? createHash('sha256').update(fs.readFileSync(path.join(extension, 'package-lock.json'))).digest('hex') : null,
    optionalRuntimeDependencies:optionalDependenciesFromLock(path.join(extension, 'package-lock.json')),
    builtMain: false,
    missing: [],
  };
  let dependenciesInstalled = false;
  const nestedRuntimePackages = packageScopes(extension);
  record.nestedRuntimePackages = [];

  for (const relative of relativeReferences(manifest.contributes)) {
    const resolved = path.resolve(extension, relative);
    const packaged = path.resolve(destination, relative);
    if (!resolved.startsWith(extension + path.sep) || (!fs.existsSync(resolved) && !fs.existsSync(packaged))) record.missing.push(relative);
  }

  if ((runtimeExtension || hasDeclaredAssetBuild) && fs.existsSync(path.join(destination, 'package-lock.json'))) {
    const install = spawnSync(node, [npm, 'ci', '--ignore-scripts', '--no-audit', '--no-fund'], {cwd:destination, encoding:'utf8'});
    if (install.status !== 0) throw new Error(`Locked extension dependency install failed for ${dir} (${JSON.stringify({status:install.status, signal:install.signal, error:install.error?.message})}):\n${install.stderr || install.stdout}`);
    dependenciesInstalled = true;
  }

  for (const scope of nestedRuntimePackages) {
    if (!scope.manifest.main) continue;
    const packagedScope = path.join(destination, scope.relative);
    const lockPath = path.join(packagedScope, 'package-lock.json');
    const scopeRecord = {
      path:scope.relative.replaceAll(path.sep, '/'),
      name:scope.manifest.name || null,
      type:scope.manifest.type || 'commonjs',
      main:scope.manifest.main,
      dependencyLockSha256:fs.existsSync(scope.lockPath)
        ? createHash('sha256').update(fs.readFileSync(scope.lockPath)).digest('hex') : null,
      optionalDependencies:optionalDependenciesFromLock(scope.lockPath),
      dependencies:scope.manifest.dependencies || {},
      installed: false,
    };
    if (fs.existsSync(lockPath)) {
      const install = spawnSync(node, [npm, 'ci', '--ignore-scripts', '--no-audit', '--no-fund'], {cwd:packagedScope, encoding:'utf8'});
      if (install.status !== 0) throw new Error(`Locked nested runtime dependency install failed for ${dir}/${scope.relative} (${JSON.stringify({status:install.status, signal:install.signal, error:install.error?.message})}):\n${install.stderr || install.stdout}`);
      scopeRecord.installed = true;
    }
    record.nestedRuntimePackages.push(scopeRecord);
  }

  // Use VS Code's declared esbuild recipe when available. The upstream recipe
  // owns output format, bundle boundaries, and source maps; VS Code's extension
  // packaging convention changes emitted main paths from out/ to dist/.
  const upstreamEsbuildRecipe = ['esbuild.mts', '.esbuild.mts', '.esbuild.ts']
    .map(name => path.join(destination, name)).find(fs.existsSync);
  const usesUpstreamEsbuild = Boolean(upstreamEsbuildRecipe);
  if (usesUpstreamEsbuild) {
    const build = spawnSync(node, [upstreamEsbuildRecipe], {cwd:destination, encoding:'utf8'});
    if (build.status !== 0) throw new Error(`Upstream esbuild recipe failed for ${dir}:\n${build.stderr || build.stdout}`);
    if (manifest.main) {
      manifest.main = manifest.main.replace('/out/', '/dist/');
      record.main = manifest.main;
      record.builtMain = entrypointExists(destination, manifest.main);
    }
    fs.writeFileSync(path.join(destination, 'package.json'), JSON.stringify(manifest, null, 2) + '\n');
    for (const scope of nestedRuntimePackages) {
      if (!scope.manifest.main) continue;
      const nestedManifestPath = path.join(destination, scope.relative, 'package.json');
      const nestedManifest = JSON.parse(fs.readFileSync(nestedManifestPath, 'utf8'));
      nestedManifest.main = nestedManifest.main.replace('/out/', '/dist/');
      const scopeRecord = record.nestedRuntimePackages.find(item => item.path === scope.relative.replaceAll(path.sep, '/'));
      if (scopeRecord) scopeRecord.main = nestedManifest.main;
      fs.writeFileSync(nestedManifestPath, JSON.stringify(nestedManifest, null, 2) + '\n');
    }
  }

  if (manifest.main && !usesUpstreamEsbuild) {
    const compiledEntry = path.join(destination, manifest.main.replace(/^\.\//, '') + (path.extname(manifest.main) ? '' : '.js'));
    const existingEntry = path.resolve(destination, manifest.main);
    if (fs.existsSync(existingEntry)) {
      record.builtMain = true;
    } else {
      const entry = sourceEntry(extension, manifest.main);
      if (!entry) {
        record.missing.push(`main:${manifest.main}`);
      } else {
        for (const srcDir of sourceDirectories(extension)) {
          const relative = path.relative(extension, srcDir);
          const outputRelative = relative.replace(/(^|\/)src$/, '$1out');
          await esbuild.build({
            absWorkingDir: srcDir,
            entryPoints: typescriptFiles(srcDir),
            outbase: srcDir,
            outdir: path.join(destination, outputRelative),
            bundle: false,
            platform: 'node',
            format: 'cjs',
            target: 'node24',
            packages: 'external',
            tsconfigRaw: {compilerOptions:{experimentalDecorators:true,useDefineForClassFields:false}},
            define: {
              'import.meta.dirname': '__dirname',
              'import.meta.url': '__codipadMetaUrl',
            },
            banner: {js: 'const __codipadMetaUrl=require("node:url").pathToFileURL(__filename).href;'},
            logLevel: 'warning',
          });
        }
        if (!fs.existsSync(compiledEntry)) record.missing.push(`main:${manifest.main}`);
        record.builtMain = true;
      }
    }
  }

  // Some language extensions generate notebook or webview entrypoints in the
  // exact package before publication. Reuse only their declared direct esbuild
  // scripts; avoid running test, watch, install, or platform/native build hooks.
  if (record.missing.some(value => value.startsWith('./'))) {
    for (const [name, command] of Object.entries(manifest.scripts || {})) {
      if (!/^build/i.test(name) || /(?:watch|test|lint|install|setup)/i.test(name) || !/^node\s+(?:\.\/)?[^\s]+\.mts(?:\s|$)/.test(command)) continue;
      const script = command.match(/^node\s+(?:\.\/)?([^\s]+\.mts)/)?.[1];
      if (!script) continue;
      const build = spawnSync(node, [path.join(destination, script)], {cwd:destination, encoding:'utf8'});
      if (build.status !== 0) throw new Error(`Upstream ${name} build failed for ${dir}:\n${build.stderr || build.stdout}`);
    }
  }

  if (dependenciesInstalled) {
    installRuntimeDependencies(destination, dir);
  }
  for (const scope of record.nestedRuntimePackages) {
    if (!scope.installed) continue;
    const packagedScope = path.join(destination, scope.path);
    installRuntimeDependencies(packagedScope, `${dir}/${scope.path}`);
  }

  // Record missing runtime entrypoints for every built-in, not only language
  // extensions. Some declarative packages intentionally delegate activation to
  // VS Code; declared main/browser files must still resolve in the package.
  for (const key of ['main', 'browser']) {
    const target = manifest[key];
    if (typeof target === 'string' && !entrypointExists(destination, target)) {
      record.missing.push(`${key}:${target}`);
    }
  }

  for (const relative of relativeReferences(manifest.contributes)) {
    const resolved = path.resolve(extension, relative);
    const packaged = path.resolve(destination, relative);
    if (resolved.startsWith(extension + path.sep) && (fs.existsSync(resolved) || fs.existsSync(packaged))) {
      record.missing = record.missing.filter(value => value !== relative);
    }
  }

  record.status = record.languageRuntime
    ? 'language-runtime-entrypoint-built'
    : manifest.main || manifest.browser ? record.builtMain ? 'runtime-entrypoint-built' : 'runtime-entrypoint-outside-language-packaging-scope'
      : 'declarative-contributions-packaged';

  const missingMain = record.missing.filter(value => value.startsWith('main:'));
  if (languageRuntime && missingMain.length) throw new Error(`${dir} has missing language-feature entrypoints: ${missingMain.join(', ')}`);
  const missingLanguageResources = record.missing.filter(value => value.startsWith('./'));
  if (declarations.length && missingLanguageResources.length) {
    throw new Error(`${dir} has missing language contribution resources: ${missingLanguageResources.join(', ')}`);
  }
  // Source TypeScript is build input. Keep adjacent runtime resources that
  // extension code may load relative to itself.
  if (record.builtMain) {
    for (const sourceDir of sourceDirectories(destination)) stripSourceTypeScript(sourceDir);
  }
  if (usesUpstreamEsbuild) {
    const required = [...['main', 'browser'].map(key => manifest[key]).filter(Boolean), ...relativeReferences(manifest.contributes)]
      .filter(relative => {
        const candidate = path.resolve(destination, relative);
        return candidate.startsWith(destination + path.sep) && (fs.existsSync(candidate) || entrypointExists(destination, relative));
      });
    const scopes = nestedRuntimePackages.map(scope => ({path:scope.relative.replaceAll(path.sep, '/')}));
    record.packagedFileCount = await selectBundledFiles(destination, dir, scopes);
    delete manifest.scripts;
    delete manifest.dependencies;
    delete manifest.devDependencies;
    fs.writeFileSync(path.join(destination, 'package.json'), JSON.stringify(manifest, null, 2) + '\n');
    for (const relative of required) {
      const candidate = path.resolve(destination, relative);
      if (!candidate.startsWith(destination + path.sep) || (!fs.existsSync(candidate) && !entrypointExists(destination, relative))) throw new Error(`Upstream packaging omitted ${dir} asset ${relative}`);
    }
  }
  validateLanguageAssets(destination, manifest, dir);
  entries.push(record);
}

const externalBuiltins = JSON.parse(fs.readFileSync(path.join(source, 'product.json'), 'utf8')).builtInExtensions || [];

async function fetchPinnedUrl(url, {headers, sha256, download = false}) {
  for (let attempt = 0; attempt <= 10; attempt++) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), download ? 5 * 60_000 : 30_000);
    try {
      const response = await fetch(url, {headers, signal:controller.signal});
      if (!response.ok || response.status < 200 || response.status >= 300) {
        throw new Error(`Request ${url} failed with status ${response.status}`);
      }
      const bytes = Buffer.from(await response.arrayBuffer());
      if (sha256) {
        const actual = createHash('sha256').update(bytes).digest('hex');
        if (actual !== sha256) throw new Error(`SHA-256 mismatch for ${url}: expected ${sha256}, got ${actual}`);
      }
      return bytes;
    } catch (error) {
      if (attempt === 10) throw error;
      await new Promise(resolve => setTimeout(resolve, 1000));
    } finally {
      clearTimeout(timeout);
    }
  }
  throw new Error(`Unable to fetch ${url}`);
}

function extractVsixExtension(archive, destination, extensionName) {
  return new Promise((resolve, reject) => {
    yauzl.fromBuffer(archive, {lazyEntries:true, validateEntrySizes:true}, (openError, zipFile) => {
      if (openError) return reject(openError);
      let settled = false;
      const fail = error => {
        if (settled) return;
        settled = true;
        zipFile.close();
        reject(error);
      };
      zipFile.on('error', fail);
      zipFile.on('end', () => {
        if (!settled) {
          settled = true;
          resolve();
        }
      });
      zipFile.on('entry', entry => {
        const name = entry.fileName;
        if (path.posix.isAbsolute(name) || name.includes('\\') || name.split('/').includes('..')) {
          return fail(new Error(`Unsafe VSIX path for ${extensionName}: ${name}`));
        }
        if (!name.startsWith('extension/')) return zipFile.readEntry();
        const relative = name.slice('extension/'.length);
        if (!relative) return zipFile.readEntry();
        const target = path.resolve(destination, relative);
        if (!target.startsWith(destination + path.sep)) return fail(new Error(`Unsafe VSIX path for ${extensionName}: ${name}`));
        if (name.endsWith('/')) {
          fs.mkdirSync(target, {recursive:true});
          return zipFile.readEntry();
        }
        fs.mkdirSync(path.dirname(target), {recursive:true});
        zipFile.openReadStream(entry, (streamError, stream) => {
          if (streamError) return fail(streamError);
          const outputStream = fs.createWriteStream(target, {mode:0o644});
          pipeline(stream, outputStream).then(() => {
            const archivedMode = (entry.externalFileAttributes >>> 16) & 0o777;
            if (archivedMode) fs.chmodSync(target, archivedMode);
            zipFile.readEntry();
          }, fail);
        });
      });
      zipFile.readEntry();
    });
  });
}

async function packageDownloadedBuiltin(extension) {
  if (!extension.repo || !extension.name || !extension.version || !extension.sha256 || !extension.metadata) {
    throw new Error(`Pinned downloaded builtin is missing required product.json metadata: ${JSON.stringify(extension)}`);
  }
  const repository = new URL(extension.repo).pathname.replace(/^\/+|\/+$/g, '');
  const assetName = `${extension.name}.${extension.version}.vsix`;
  const assetUrl = `https://github.com/${repository}/releases/download/v${extension.version}/${assetName}`;
  const cachePath = path.join(builtinVsixCache, `${extension.sha256.toLowerCase()}.vsix`);
  let archive;
  let archiveSource;
  if (fs.existsSync(cachePath)) {
    const cached = fs.readFileSync(cachePath);
    const cachedHash = createHash('sha256').update(cached).digest('hex');
    if (cachedHash === extension.sha256.toLowerCase()) {
      archive = cached;
      archiveSource = 'content-addressed-sha256-cache';
    } else {
      fs.rmSync(cachePath, {force:true});
    }
  }
  if (!archive) {
    archive = await fetchPinnedUrl(assetUrl, {sha256:extension.sha256, download:true});
    fs.mkdirSync(builtinVsixCache, {recursive:true});
    const temporaryCachePath = `${cachePath}.${process.pid}.tmp`;
    fs.writeFileSync(temporaryCachePath, archive, {flag:'wx'});
    try {
      fs.renameSync(temporaryCachePath, cachePath);
    } catch (error) {
      fs.rmSync(temporaryCachePath, {force:true});
      if (error.code !== 'EEXIST' && error.code !== 'ENOTEMPTY') throw error;
      const existing = fs.readFileSync(cachePath);
      if (createHash('sha256').update(existing).digest('hex') !== extension.sha256.toLowerCase()) throw error;
    }
    archiveSource = 'pinned-github-release-download';
  }

  const staging = fs.mkdtempSync(path.join(output, '.builtin-vsix-'));
  try {
    const packageRoot = path.join(staging, 'extension');
    fs.mkdirSync(packageRoot);
    await extractVsixExtension(archive, packageRoot, extension.name);
    const manifestPath = path.join(packageRoot, 'package.json');
    if (!fs.existsSync(manifestPath)) throw new Error(`Pinned VSIX for ${extension.name} has no extension/package.json`);
    const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
    const actualId = `${manifest.publisher}.${manifest.name}`;
    if (manifest.version !== extension.version || actualId.toLowerCase() !== extension.name.toLowerCase()) {
      throw new Error(`Pinned VSIX identity mismatch for ${extension.name}: got ${actualId}@${manifest.version}`);
    }
    manifest.__metadata = extension.metadata;
    fs.writeFileSync(manifestPath, JSON.stringify(manifest, null, 2) + '\n');
    const destination = path.join(builtins, extension.name);
    fs.rmSync(destination, {recursive:true, force:true});
    fs.cpSync(packageRoot, destination, {recursive:true, dereference:true});
    stripBuildFiles(destination);

    const packageManifest = JSON.parse(fs.readFileSync(path.join(destination, 'package.json'), 'utf8'));
    validateLanguageAssets(destination, packageManifest, extension.name);
    const missingEntrypoints = ['main', 'browser'].filter(key => typeof packageManifest[key] === 'string' && !entrypointExists(destination, packageManifest[key]))
      .map(key => `${key}:${packageManifest[key]}`);
    return {
      name: extension.name, version: extension.version, sha256: extension.sha256, repo: extension.repo,
      asset: assetName, provenance:'product.json + upstream build/lib/extensions.ts GitHub VSIX contract',
      archiveSource, cacheKey:extension.sha256.toLowerCase(),
      packaging:'included; SHA-256 verified, extension/** extracted, product metadata injected',
      packageMain:packageManifest.main || null, missingEntrypoints,
    };
  } finally {
    fs.rmSync(staging, {recursive:true, force:true});
  }
}

const packagedDownloadedBuiltins = [];
for (const extension of externalBuiltins) packagedDownloadedBuiltins.push(await packageDownloadedBuiltin(extension));

// Build recipes run with host tools first. Reinstall their locked production closure for the
// guest afterwards, so host npm platform filtering cannot omit Linux ARM64 optional packages.
function installRuntimeDependencies(root, label) {
  const install = spawnSync(node, [npm, 'ci', '--omit=dev', '--ignore-scripts', '--no-audit', '--no-fund', '--os=linux', '--cpu=arm64', '--libc=glibc'], {cwd:root, encoding:'utf8'});
  if (install.status !== 0) throw new Error(`Locked Linux ARM64 runtime dependency install failed for ${label}:\n${install.stderr || install.stdout}`);
}

function nativeAssetInventory(root, relative = '', result = []) {
  for (const item of fs.readdirSync(root, {withFileTypes:true}).sort((a, b) => a.name.localeCompare(b.name))) {
    const file = path.join(root, item.name), rel = path.posix.join(relative, item.name);
    if (item.isDirectory()) nativeAssetInventory(file, rel, result);
    else if (item.isFile() && /\.(?:node|so(?:\.[^/]+)*|dylib|dll)$/.test(item.name)) {
      const bytes = fs.readFileSync(file);
      result.push({path:rel, bytes:bytes.length, sha256:createHash('sha256').update(bytes).digest('hex')});
    }
  }
  return result;
}

function removeBinDirectories(root) {
  if (!fs.existsSync(root)) return;
  for (const item of fs.readdirSync(root, {withFileTypes:true})) {
    if (!item.isDirectory()) continue;
    const child = path.join(root, item.name);
    if (item.name === '.bin') fs.rmSync(child, {recursive:true, force:true});
    else removeBinDirectories(child);
  }
}

function removeNpmInstallMetadata(root) {
  if (!fs.existsSync(root)) return;
  removeBinDirectories(root);
  for (const item of fs.readdirSync(root, {withFileTypes:true})) {
    const child = path.join(root, item.name);
    if (item.isDirectory()) removeNpmInstallMetadata(child);
    else if (item.name === '.package-lock.json') fs.rmSync(child, {force:true});
  }
}

function materializeLocalLinks(root, extensionRoot) {
  if (!fs.existsSync(root)) return;
  for (const item of fs.readdirSync(root, {withFileTypes:true})) {
    const child = path.join(root, item.name);
    if (item.isSymbolicLink()) {
      const target = fs.realpathSync(child);
      if (!target.startsWith(extensionRoot + path.sep) || !fs.existsSync(target)) {
        throw new Error(`Extension dependency has an unsupported or dangling symlink: ${path.relative(extensionRoot, child)}`);
      }
      const stat = fs.statSync(target);
      fs.rmSync(child, {force:true});
      if (stat.isDirectory()) fs.cpSync(target, child, {recursive:true, dereference:true});
      else fs.copyFileSync(target, child);
    } else if (item.isDirectory()) materializeLocalLinks(child, extensionRoot);
  }
}

// Upstream's TypeScript extension resolves its bundled server at
// extensionPath/../node_modules/typescript. Keep that shared runtime directory
// directly under the extension catalog and let the native catalog skip only this
// validated structural dependency entry.
const sharedModules = path.join(builtins, 'node_modules');
function stripBuildFiles(root, inNodeModules = false) {
  if (!fs.existsSync(root)) return;
  for (const item of fs.readdirSync(root, {withFileTypes:true})) {
    const child = path.join(root, item.name);
    if (item.isDirectory()) {
      if (item.name === 'node_modules') removeNpmInstallMetadata(child);
      else stripBuildFiles(child, inNodeModules);
    } else if (!inNodeModules && (item.name.endsWith('.mts') || item.name.endsWith('.tsbuildinfo') ||
      /^tsconfig(?:\..+)?\.json$/.test(item.name) || item.name === 'package-lock.json' || item.name === '.npmrc')) {
      fs.rmSync(child, {force:true});
    }
  }
}

for (const entry of entries) {
  const extensionRoot = path.join(builtins, entry.directory);
  const localModules = path.join(extensionRoot, 'node_modules');
  if (fs.existsSync(localModules)) {
    removeBinDirectories(localModules);
    materializeLocalLinks(localModules, extensionRoot);
  }
  for (const scope of entry.nestedRuntimePackages || []) {
    const nestedModules = path.join(extensionRoot, scope.path, 'node_modules');
    if (fs.existsSync(nestedModules)) {
      removeBinDirectories(nestedModules);
      materializeLocalLinks(nestedModules, path.join(extensionRoot, scope.path));
    }
  }
  materializeLocalLinks(extensionRoot, extensionRoot);
  stripBuildFiles(extensionRoot);
  entry.nativeAssets = nativeAssetInventory(extensionRoot);
}

const sharedInstall = path.join(output, '.shared-extension-install');
fs.rmSync(sharedInstall, {recursive:true, force:true});
fs.mkdirSync(sharedInstall, {recursive:true});
for (const file of ['package.json', 'package-lock.json', '.npmrc']) {
  fs.copyFileSync(path.join(upstreamExtensions, file), path.join(sharedInstall, file));
}
installRuntimeDependencies(sharedInstall, 'shared extensions');
fs.rmSync(sharedModules, {recursive:true, force:true});
fs.renameSync(path.join(sharedInstall, 'node_modules'), sharedModules);
fs.rmSync(sharedInstall, {recursive:true, force:true});
removeNpmInstallMetadata(sharedModules);
materializeLocalLinks(sharedModules, builtins);
const sharedTypescript = requireVersion(path.join(sharedModules, 'typescript/package.json'));
const sharedDependencyLockSha256 = createHash('sha256').update(fs.readFileSync(path.join(upstreamExtensions, 'package-lock.json'))).digest('hex');
for (const helper of ['tsconfig.base.json', 'esbuild-common.mts', 'esbuild-extension-common.mts', 'esbuild-webview-common.mts']) {
  fs.rmSync(path.join(builtins, helper), {force:true});
}
const sharedNativeAssets = nativeAssetInventory(sharedModules);
for (const extension of packagedDownloadedBuiltins) {
  const root = path.join(builtins, extension.name);
  materializeLocalLinks(root, root);
  extension.nativeAssets = nativeAssetInventory(root);
}
const runtimeDependencyAudit = [];
for (const entry of entries) {
  const extensionRoot = path.join(builtins, entry.directory);
  if (entry.main) {
    const audit = auditRuntimeEntrypoint(extensionRoot, entry.main, new Set(entry.optionalRuntimeDependencies || []));
    runtimeDependencyAudit.push({extension:entry.directory, scope:'.', ...audit});
  }
  for (const scope of entry.nestedRuntimePackages || []) {
    if (!scope.main) continue;
    const auditRoot = path.join(extensionRoot, scope.path);
    const audit = auditRuntimeEntrypoint(auditRoot, scope.main,
      new Set([...(entry.optionalRuntimeDependencies || []), ...(scope.optionalDependencies || [])]));
    runtimeDependencyAudit.push({extension:entry.directory, scope:scope.path, ...audit});
  }
}
for (const extension of packagedDownloadedBuiltins) {
  if (!extension.packageMain) continue;
  const auditRoot = path.join(builtins, extension.name);
  const audit = auditRuntimeEntrypoint(auditRoot, extension.packageMain);
  runtimeDependencyAudit.push({extension:extension.name, scope:'.', ...audit});
}
fs.writeFileSync(path.join(output, 'extension-inventory.json'), JSON.stringify({
  schemaVersion: 2,
  runtimeDependencyTarget: {platform:'linux', arch:'arm64', libc:'glibc'},
  nativeAssetPolicy: {packaging:'upstream selected assets recorded with SHA-256; no platform filtering of selected assets', runtimeProof:'not established by packaging', embeddedDarwinLoading:'Linux native addons are unsupported'},
  upstreamRevision: spawnSync('git', ['-C', source, 'rev-parse', 'HEAD'], {encoding:'utf8'}).stdout.trim(),
  exclusionSource: 'build/lib/extensions.ts:excludedExtensions',
  buildExcludedExtensions: [...excluded].sort().map(directory => {
    const manifestPath = path.join(upstreamExtensions, directory, 'package.json');
    const manifest = fs.existsSync(manifestPath) ? JSON.parse(fs.readFileSync(manifestPath, 'utf8')) : null;
    return {directory, id: manifest ? `${manifest.publisher || 'unknown'}.${manifest.name || directory}` : null,
      version: manifest?.version || null, classification: 'upstream-build-excluded', packaging: 'not-copied'};
  }),
  sourceManifestInventory,
  omittedFixtureDirectories: ['.git', 'node_modules', 'test', 'tests', 'test-workspace', '.vscode-test', 'fixtures', 'testdata', 'test-data'],
  sharedRuntimeDependencies: {typescript: sharedTypescript, source: 'extensions/package-lock.json', dependencyLockSha256:sharedDependencyLockSha256, nativeAssets: sharedNativeAssets},
  packagedExtensions: entries,
  downloadedBuiltins: packagedDownloadedBuiltins,
  runtimeDependencyAuditMethod: 'best-effort static import/reference scan; unresolved references are not proof of runtime failure',
  runtimeDependencyAudit,
}, null, 2) + '\n');

// Keep the catalog root limited to extension packages and the one structural
// shared-dependency directory required by upstream's bundled TypeScript lookup.
const catalogEntries = fs.readdirSync(builtins, {withFileTypes:true});
for (const entry of catalogEntries) {
  const entryPath = path.join(builtins, entry.name);
  const stat = fs.lstatSync(entryPath);
  if (entry.name === 'node_modules') {
    if (!stat.isDirectory() || stat.isSymbolicLink()) {
      throw new Error('Shared extension dependencies must be a real directory');
    }
  } else if (!stat.isDirectory() || stat.isSymbolicLink()) {
    throw new Error(`Extension catalog contains a non-package entry: ${entry.name}`);
  }
}

function requireVersion(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8')).version;
}
