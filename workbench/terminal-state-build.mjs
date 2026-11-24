import fs from 'node:fs';
import crypto from 'node:crypto';
import nodePath from 'node:path';

// Exact published CommonJS artifact selected by the pinned VS Code lockfile.
// Also guards the runtime's private decoder/transition-table seam against drift.
export function createTerminalStateBuildPlugin(dependencies) {
  return {
    name: 'codipad-terminal-state-pinned-xterm',
    setup(build) {
      const headless = nodePath.resolve(dependencies, 'node_modules/@xterm/headless/lib-headless/xterm-headless.js');
      build.onResolve({filter: /^@xterm\/headless$/}, () => ({path: headless}));
      build.onLoad({filter: /[/\\]@xterm[/\\]headless[/\\]lib-headless[/\\]xterm-headless\.js$/}, async ({path}) => {
        if (path !== headless) throw new Error('Unexpected headless module path');
        let contents = await fs.promises.readFile(path, 'utf8');
        const digest = crypto.createHash('sha256').update(contents).digest('hex');
        if (digest !== '2e8e567454b499b052198fa2fa93efbcdb2ca404feeb4710a023f74c9b267bca') throw new Error('Unreviewed xterm headless parser artifact');
        // xterm's common Platform module assumes either Node or navigator.
        // JSC has neither. Guard package-local reads; do not supply global shims.
        for (const field of ['userAgent', 'platform']) {
          const before = `:navigator.${field}`;
          if (contents.split(before).length !== 2) throw new Error(`Unexpected xterm ${field} seam`);
          contents = contents.replace(before, `:(typeof navigator==='undefined'?'':navigator.${field})`);
        }
        // CoreService clones flat boolean mode defaults. A local object copy
        // avoids requiring the browser structuredClone global in JavaScriptCore.
        for (const name of ['h', 'c']) {
          const before = `structuredClone(${name})`;
          if (contents.split(before).length !== 3) throw new Error('Unexpected xterm mode clone seam');
          contents = contents.replaceAll(before, `({...${name}})`);
        }
        return {contents, loader:'js'};
      });
    }
  };
}
