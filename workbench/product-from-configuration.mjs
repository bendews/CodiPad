/** Read the exact product identity embedded in the receipt-verified workbench. */
export function productFromConfiguration(configuration) {
  const prefix = 'globalThis._VSCODE_PRODUCT_JSON = ';
  const lines = configuration.split('\n').filter(line => line.startsWith(prefix));
  if (lines.length !== 1 || !lines[0].endsWith(';')) {
    throw new Error('Workbench configuration has no unique product identity');
  }
  const value = JSON.parse(lines[0].slice(prefix.length, -1));
  if (!value || Array.isArray(value) || typeof value !== 'object') {
    throw new Error('Workbench product identity is invalid');
  }
  return value;
}
