// Optional Microsoft components are staged separately from the Code - OSS bundles.
export function verifyPublicBundleInputs(metafile) {
  const restrictedPackage = /(?:^|\/)node_modules\/(?:@vscode\/(?:copilot-api|vsce-sign(?:-[^/]+)?)|@github\/copilot(?:-(?:linux|darwin|win32)-[^/]+)?|vsda)(?:\/|$)/;
  const input = Object.keys(metafile.inputs).find(name => restrictedPackage.test(name));
  if (input) {
    throw new Error(`Restricted package in a core bundle: ${input}`);
  }
}
