// Bundles CodiPad's custom iPad workbench, agents window, workers, and headless terminal state.
import { verifyPublicBundleInputs } from './public-bundle.mjs';
import * as esbuild from './node_modules/esbuild/lib/main.js';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { buildWorkers } from './workers.mjs';
import { createTerminalStateBuildPlugin } from './terminal-state-build.mjs';

const rawArgs = process.argv.slice(2);
const minify = rawArgs.includes('--minify');
const positional = rawArgs.filter(arg => arg !== '--minify');
const [stage, output, dependencies] = positional;
if (!stage || !output || !dependencies) {
  throw new Error('Usage: bundle.mjs <staged-source> <output-dir> <dependencies-dir> [--minify]');
}

const shared = {
  absWorkingDir: stage,
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: ['safari17'],
  nodePaths: [path.join(dependencies, 'node_modules')],
  tsconfigRaw: { compilerOptions: { experimentalDecorators: true, useDefineForClassFields: false } },
  loader: {
    '.ttf': 'file',
    '.woff': 'file',
    '.woff2': 'file',
    '.svg': 'file',
    '.png': 'file',
    '.gif': 'file',
    '.wasm': 'file',
  },
  assetNames: 'assets/[name]-[hash]',
  logLevel: 'info',
};

function codiconFontPlugin() {
  const fallback = path.join(dependencies, 'node_modules/@vscode/codicons/dist/codicon.ttf');
  return {
    name: 'pinned-codicon-font',
    setup(build) {
      build.onResolve({ filter: /codicon\.ttf$/ }, args => {
        const relative = path.resolve(args.resolveDir, args.path);
        return { path: fs.existsSync(relative) ? relative : fallback };
      });
    },
  };
}

await buildWorkers(stage, output, dependencies, esbuild, { minify });

// The pinned language model loads its CPU backend with a relative CommonJS require.
// Bundle its two scripts together for the workbench's AMD loader in a module worker.
const modelLibrary = 'node_modules/@vscode/vscode-languagedetection/dist/lib';
const modelSource = path.join(stage, 'language-detection');
fs.mkdirSync(modelSource, { recursive: true });
for (const name of ['index.js', '979.js']) {
  const source = path.join(dependencies, modelLibrary, name);
  if (!fs.lstatSync(source).isFile()) throw new Error(`Missing language model script: ${source}`);
  fs.copyFileSync(source, path.join(modelSource, name));
}
await esbuild.build({
  ...shared,
  stdin: { contents: "define([], () => require('./index.js'));", resolveDir: modelSource },
  outfile: path.join(output, modelLibrary, 'index.js'),
  packages: 'external',
  legalComments: 'eof',
  minify,
});

const workbench = await esbuild.build({
  ...shared,
  entryPoints: ['src/vs/workbench/workbench.ipad.main.ts'],
  outfile: path.join(output, 'workbench.js'),
  define: { 'import.meta.url': 'globalThis._CODIPAD_WORKBENCH_SCRIPT_URL' },
  minify,
  sourcemap: !minify,
  metafile: true,
  legalComments: 'linked',
  plugins: [codiconFontPlugin()],
});

const agents = await esbuild.build({
  ...shared,
  entryPoints: ['src/vs/sessions/sessions.ipad.main.ts'],
  outfile: path.join(output, 'agents.js'),
  define: { 'import.meta.url': 'globalThis._CODIPAD_WORKBENCH_SCRIPT_URL' },
  minify,
  sourcemap: !minify,
  metafile: true,
  legalComments: 'linked',
  plugins: [codiconFontPlugin()],
});

const terminalState = await esbuild.build({
  ...shared,
  entryPoints: [fileURLToPath(new URL('./terminal-state.ts', import.meta.url))],
  outfile: path.join(output, 'terminal-state.js'),
  minify,
  metafile: true,
  legalComments: 'linked',
  plugins: [createTerminalStateBuildPlugin(dependencies)],
});

for (const artifact of [workbench, agents, terminalState]) {
  verifyPublicBundleInputs(artifact.metafile);
  for (const meta of Object.values(artifact.metafile.outputs)) {
    for (const imported of meta.imports) {
      if (imported.external && !(imported.kind === 'dynamic-import' && imported.path === 'module') && !/^(data:|#)/.test(imported.path)) {
        throw new Error(`Unresolved external in browser artifact: ${imported.path}`);
      }
    }
  }
}

if (!minify) {
  fs.writeFileSync(path.join(output, 'metafile.json'), JSON.stringify(workbench.metafile, null, 2) + '\n');
  fs.writeFileSync(path.join(output, 'agents-metafile.json'), JSON.stringify(agents.metafile, null, 2) + '\n');
  fs.writeFileSync(path.join(output, 'terminal-state-metafile.json'), JSON.stringify(terminalState.metafile, null, 2) + '\n');
}
