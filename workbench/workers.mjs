import { verifyPublicBundleInputs } from './public-bundle.mjs';
import fs from 'node:fs';
import path from 'node:path';
import { createHash } from 'node:crypto';

// Preserve the upstream module layout used by FileAccess and WebWorkerDescriptor.
export async function buildWorkers(stage, output, dependencies, esbuild, { minify = false } = {}) {
  const sourceRoot = path.join(stage, 'src');
  const entries = fs.readdirSync(sourceRoot, { recursive: true })
    .filter(name => /(?:\.workerMain|WebWorkerMain)\.ts$/.test(name)).sort();
  entries.push('vs/workbench/api/worker/extensionHostWorkerMain.ts');
  if (!entries.length) throw new Error('Pinned source has no worker entrypoints');
  const result = await esbuild.build({
    absWorkingDir: stage,
    entryPoints: entries.map(name => path.join(sourceRoot, name)),
    outbase: sourceRoot, outdir: path.join(output, 'out'),
    bundle: true, format: 'esm', platform: 'browser', target: ['safari17'],
    nodePaths: [path.join(dependencies, 'node_modules')],
    tsconfigRaw: { compilerOptions: { experimentalDecorators: true, useDefineForClassFields: false } },
    loader: { '.ttf': 'file', '.woff': 'file', '.woff2': 'file', '.svg': 'file', '.png': 'file', '.gif': 'file', '.wasm': 'file' },
    assetNames: 'assets/[name]-[hash]',
    minify, sourcemap: !minify, metafile: true, legalComments: 'linked',
    logLevel: 'info',
  });
  verifyPublicBundleInputs(result.metafile);
  for (const artifact of Object.values(result.metafile.outputs)) {
    for (const imported of artifact.imports) {
      if (imported.external && !(imported.kind === 'dynamic-import' && imported.path === 'module') && !/^(data:|#)/.test(imported.path)) {
        throw new Error(`Unresolved external in worker artifact: ${imported.path}`);
      }
    }
  }
  const iframe = 'vs/workbench/services/extensions/worker/webWorkerExtensionHostIframe.html';
  fs.mkdirSync(path.dirname(path.join(output, 'out', iframe)), { recursive: true });
  fs.copyFileSync(path.join(sourceRoot, iframe), path.join(output, 'out', iframe));
  const sha = file => createHash('sha256').update(fs.readFileSync(file)).digest('hex');
  const receipt = {
    schemaVersion: 1,
    entries: entries.map(source => {
      const artifact = 'out/' + source.replace(/\.ts$/, '.js').split(path.sep).join('/');
      return { source: 'src/' + source.split(path.sep).join('/'), output: artifact, sha256: sha(path.join(output, artifact)) };
    }),
    // import.meta.url remains the actual ESM worker URL, not the top-level bundle URL.
    moduleFormat: 'esm',
    inputs: Object.fromEntries(Object.keys(result.metafile.inputs).sort().map(name => [name, sha(path.resolve(stage, name))])),
  };
  fs.writeFileSync(path.join(output, 'WorkerReceipt.json'), JSON.stringify(receipt, null, 2) + '\n');
  return receipt;
}
