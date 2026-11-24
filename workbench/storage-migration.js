// App upgrade helper. The native coordinator owns its private spool, pending manifest and verification.
// Only the app's upstream IndexedDB families and exact public window preference are read.
(() => {
  'use strict';
  const LIMIT = 1024 * 1024, RECORD_LIMIT = 128;
  const WINDOW_SELECTION_KEY = 'codipad.remoteWorkspace.v1';
  const windowSelection = () => window.localStorage.getItem(WINDOW_SELECTION_KEY);
  const prefix = 'vscode-web-state-db-';
  const owned = name => typeof name === 'string' && (name === 'vscode-web-db' || name.startsWith(prefix) && name.length > prefix.length);
  const fail = code => { throw Object.assign(new Error(`CodiPad storage migration: ${code}`), {code}); };
  const integer = value => Number.isSafeInteger(value) && value >= 0;
  const ascii = value => JSON.stringify(value).replace(/[^\x20-\x7e]/g, char => `\\u${char.charCodeAt(0).toString(16).padStart(4, '0')}`);
  const views = new Map(['Int8Array', 'Uint8Array', 'Uint8ClampedArray', 'Int16Array', 'Uint16Array', 'Int32Array', 'Uint32Array', 'Float32Array', 'Float64Array', 'BigInt64Array', 'BigUint64Array', 'DataView'].map(name => [name, globalThis[name]]));
  let exporting, importing, busy = false;

  function base64(buffer) {
    const bytes = new Uint8Array(buffer), parts = [];
    for (let i = 0; i < bytes.length; i += 32768) parts.push(String.fromCharCode(...bytes.subarray(i, i + 32768)));
    return btoa(parts.join(''));
  }
  function unbase64(text) {
    if (typeof text !== 'string' || text.length % 4) fail('INVALID_VALUE');
    const padding = text.endsWith('==') ? 2 : text.endsWith('=') ? 1 : 0;
    if (/[^A-Za-z0-9+/]/.test(text.slice(0, text.length - padding))) fail('INVALID_VALUE');
    const binary = atob(text), bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes.buffer;
  }
  // Graph references preserve shared buffers, sparse arrays and object identity without interpreting tags in user objects.
  function encode(value) {
    const nodes = [], seen = new Map();
    function visit(item, depth = 0) {
      if (depth > 256) fail('UNSUPPORTED_VALUE');
      if (item === null) return ['null'];
      if (typeof item === 'undefined') return ['undefined'];
      if (typeof item === 'string' || typeof item === 'boolean') return [typeof item, item];
      if (typeof item === 'number') return ['number', Object.is(item, -0) ? '-0' : Number.isFinite(item) ? item : String(item)];
      if (typeof item !== 'object') fail('UNSUPPORTED_VALUE');
      if (seen.has(item)) return ['ref', seen.get(item)];
      const id = nodes.length; seen.set(item, id); nodes.push(null);
      if (item instanceof ArrayBuffer) nodes[id] = ['buffer', base64(item)];
      else if (ArrayBuffer.isView(item)) {
        const name = Object.getPrototypeOf(item).constructor.name;
        if (!views.get(name) || !(item.buffer instanceof ArrayBuffer)) fail('UNSUPPORTED_VALUE');
        nodes[id] = ['view', name, visit(item.buffer, depth + 1), item.byteOffset, name === 'DataView' ? item.byteLength : item.length];
      } else if (item instanceof Date) nodes[id] = ['date', Number.isNaN(item.getTime()) ? 'NaN' : item.getTime()];
      else if (Array.isArray(item)) nodes[id] = ['array', item.length, Object.keys(item).map(key => [key, visit(item[key], depth + 1)])];
      else if (Object.getPrototypeOf(item) === Object.prototype || Object.getPrototypeOf(item) === null) nodes[id] = ['object', Object.keys(item).map(key => [key, visit(item[key], depth + 1)])];
      else fail('UNSUPPORTED_VALUE');
      return ['ref', id];
    }
    return [visit(value), nodes];
  }
  function decode(graph) {
    if (!Array.isArray(graph) || graph.length !== 2 || !Array.isArray(graph[1])) fail('INVALID_VALUE');
    const nodes = graph[1], cache = [], active = new Set();
    function read(item, depth = 0) {
      if (depth > 256 || !Array.isArray(item)) fail('INVALID_VALUE');
      const [tag, value] = item;
      if (tag === 'null' && item.length === 1) return null;
      if (tag === 'undefined' && item.length === 1) return undefined;
      if ((tag === 'string' || tag === 'boolean') && item.length === 2 && typeof value === tag) return value;
      if (tag === 'number' && item.length === 2) {
        if (typeof value === 'number' && Number.isFinite(value)) return value;
        if (['-0', 'NaN', 'Infinity', '-Infinity'].includes(value)) return value === '-0' ? -0 : Number(value);
      }
      if (tag !== 'ref' || item.length !== 2 || !integer(value) || value >= nodes.length) fail('INVALID_VALUE');
      if (Object.hasOwn(cache, value)) return cache[value];
      if (active.has(value)) fail('INVALID_VALUE');
      active.add(value);
      const node = nodes[value];
      if (!Array.isArray(node)) fail('INVALID_VALUE');
      if (node[0] === 'buffer' && node.length === 2) cache[value] = unbase64(node[1]);
      else if (node[0] === 'date' && node.length === 2 && (node[1] === 'NaN' || typeof node[1] === 'number' && Number.isFinite(node[1]))) cache[value] = new Date(node[1] === 'NaN' ? NaN : node[1]);
      else if (node[0] === 'view' && node.length === 5 && views.get(node[1]) && integer(node[3]) && integer(node[4])) {
        const buffer = read(node[2], depth + 1);
        if (!(buffer instanceof ArrayBuffer)) fail('INVALID_VALUE');
        cache[value] = new (views.get(node[1]))(buffer, node[3], node[4]);
      } else if (node[0] === 'object' && node.length === 2 || node[0] === 'array' && node.length === 3 && integer(node[1]) && node[1] <= 0xffffffff) {
        const entries = node[node.length - 1];
        if (!Array.isArray(entries)) fail('INVALID_VALUE');
        const result = cache[value] = node[0] === 'array' ? new Array(node[1]) : {};
        const keys = new Set();
        for (const pair of entries) {
          if (!Array.isArray(pair) || pair.length !== 2 || typeof pair[0] !== 'string' || keys.has(pair[0])) fail('INVALID_VALUE');
          keys.add(pair[0]);
          Object.defineProperty(result, pair[0], {value:read(pair[1], depth + 1), enumerable:true, configurable:true, writable:true});
        }
      } else fail('INVALID_VALUE');
      active.delete(value);
      return cache[value];
    }
    return read(graph[0]);
  }
  const same = (left, right) => ascii(encode(left)) === ascii(encode(right));
  const close = state => state?.databases.forEach(entry => entry.db?.close());
  async function list() {
    if (typeof indexedDB.databases !== 'function') fail('ENUMERATION_UNAVAILABLE');
    return (await indexedDB.databases()).filter(entry => typeof entry.name === 'string' && owned(entry.name)).sort((a, b) => a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  }
  function connect(name, version, schema) {
    return new Promise((resolve, reject) => {
      let rejected = false;
      const request = version === undefined ? indexedDB.open(name) : indexedDB.open(name, version);
      const rejectCode = code => { rejected = true; reject(Object.assign(new Error(code), {code})); };
      request.onblocked = () => rejectCode('DATABASE_BLOCKED');
      request.onerror = () => rejectCode('DATABASE_OPEN_FAILED');
      request.onupgradeneeded = () => {
        if (!schema) { request.transaction.abort(); rejectCode('DATABASE_MISSING'); return; }
        try {
          for (const definition of schema) {
            const store = request.result.createObjectStore(definition.name, {keyPath:definition.keyPath, autoIncrement:definition.autoIncrement});
            for (const index of definition.indexes) store.createIndex(index.name, index.keyPath, {unique:index.unique, multiEntry:index.multiEntry});
          }
        } catch { request.transaction.abort(); rejectCode('SCHEMA_CREATE_FAILED'); }
      };
      request.onsuccess = () => {
        const db = request.result;
        if (rejected) { db.close(); return; }
        db.onversionchange = () => db.close();
        resolve(db);
      };
    });
  }
  function describe(db) {
    const names = Array.from(db.objectStoreNames).sort();
    if (!names.length) return Promise.resolve([]);
    return new Promise((resolve, reject) => {
      const tx = db.transaction(names, 'readonly'), stores = [];
      tx.onabort = () => reject(Object.assign(new Error('READ_FAILED'), {code:'READ_FAILED'}));
      tx.onerror = () => {};
      for (const name of names) {
        const store = tx.objectStore(name);
        const definition = {name, keyPath:store.keyPath, autoIncrement:store.autoIncrement,
          indexes:Array.from(store.indexNames).sort().map(name => {
            const index = store.index(name);
            return {name, keyPath:index.keyPath, unique:index.unique, multiEntry:index.multiEntry};
          }), records:0};
        stores.push(definition);
        store.count().onsuccess = event => { definition.records = event.target.result; };
      }
      tx.oncomplete = () => resolve(stores);
    });
  }
  function metadata(text) {
    if (typeof text !== 'string' || text.length > LIMIT) fail('INVALID_METADATA');
    const input = JSON.parse(text), keyPath = value => value === null || typeof value === 'string' || Array.isArray(value) && value.every(part => typeof part === 'string');
    if (input?.format !== 'CodiPadIndexedDBMigration' || input.version !== 1 || !Array.isArray(input.databases) || !(input.windowSelection === null || typeof input.windowSelection === 'string')) fail('INVALID_METADATA');
    const databases = input.databases.map(database => {
      if (!owned(database.name) || !integer(database.version) || database.version < 1 || !Array.isArray(database.stores)) fail('INVALID_METADATA');
      const stores = database.stores.map(store => {
        if (typeof store.name !== 'string' || !keyPath(store.keyPath) || typeof store.autoIncrement !== 'boolean' || !integer(store.records) || !Array.isArray(store.indexes)) fail('INVALID_METADATA');
        if (store.autoIncrement) fail('UNSUPPORTED_AUTO_INCREMENT');
        const indexes = store.indexes.map(index => {
          if (typeof index.name !== 'string' || index.keyPath === null || !keyPath(index.keyPath) || typeof index.unique !== 'boolean' || typeof index.multiEntry !== 'boolean') fail('INVALID_METADATA');
          return {name:index.name, keyPath:index.keyPath, unique:index.unique, multiEntry:index.multiEntry};
        });
        return {name:store.name, keyPath:store.keyPath, autoIncrement:store.autoIncrement, indexes, records:store.records};
      });
      return {name:database.name, version:database.version, stores};
    });
    for (const entries of [databases, ...databases.map(database => database.stores), ...databases.flatMap(database => database.stores.map(store => store.indexes))]) {
      if (entries.some((entry, index) => index > 0 && entries[index - 1].name >= entry.name)) fail('INVALID_METADATA');
    }
    const result = {format:input.format, version:1, windowSelection:input.windowSelection, databases};
    if (ascii(result) !== text) fail('INVALID_METADATA');
    return result;
  }
  const schema = stores => stores.map(({records, ...definition}) => definition);

  async function exportBegin() {
    close(exporting); exporting = undefined;
    const found = await list();
    const databases = [];
    exporting = {databases, position:0, pending:'', ended:false};
    for (const entry of found) {
      const db = await connect(entry.name);
      const database = {db, name:entry.name, version:db.version, stores:[]};
      databases.push(database);
      database.stores = await describe(db);
      // IndexedDB exposes no readonly API for a deleted-key generator high-water mark.
      if (database.stores.some(store => store.autoIncrement)) fail('UNSUPPORTED_AUTO_INCREMENT');
      if (db.version !== entry.version) fail('SOURCE_CHANGED');
    }
    exporting.stores = databases.flatMap(database => database.stores.map(store => ({database, store, read:0, lastKey:undefined})));
    const text = ascii({format:'CodiPadIndexedDBMigration', version:1, windowSelection:windowSelection(), databases:databases.map(({db, ...entry}) => entry)});
    metadata(text);
    return text;
  }
  function nextRecord(entry) {
    return new Promise((resolve, reject) => {
      const tx = entry.database.db.transaction(entry.store.name, 'readonly');
      let result = null, problem;
      const request = tx.objectStore(entry.store.name).openCursor(entry.read ? IDBKeyRange.lowerBound(entry.lastKey, true) : undefined);
      request.onsuccess = () => {
        const cursor = request.result;
        if (!cursor) return;
        try {
          result = ascii([entry.database.name, entry.store.name, encode(cursor.key), encode(cursor.value)]) + '\n';
          entry.lastKey = cursor.key;
        } catch (error) { problem = error; tx.abort(); }
      };
      tx.oncomplete = () => resolve(result);
      tx.onerror = () => {};
      tx.onabort = () => reject(problem || Object.assign(new Error('READ_FAILED'), {code:'READ_FAILED'}));
    });
  }
  async function exportNextChunk() {
    if (!exporting) fail('EXPORT_NOT_STARTED');
    if (exporting.ended) return null;
    let chunk = '', completed = 0;
    while (chunk.length < LIMIT && completed < RECORD_LIMIT) {
      if (!exporting.pending) {
        const entry = exporting.stores[exporting.position];
        if (!entry) { exporting.ended = true; close(exporting); break; }
        const record = await nextRecord(entry);
        if (record === null) {
          if (entry.read !== entry.store.records) fail('SOURCE_CHANGED');
          exporting.position++;
          continue;
        }
        if (++entry.read > entry.store.records) fail('SOURCE_CHANGED');
        exporting.pending = record;
      }
      const size = Math.min(LIMIT - chunk.length, exporting.pending.length);
      chunk += exporting.pending.slice(0, size);
      exporting.pending = exporting.pending.slice(size);
      if (!exporting.pending) completed++;
    }
    return chunk || null;
  }

  async function importBegin(text) {
    close(importing); importing = undefined;
    const expected = metadata(text), existingSelection = windowSelection();
    if (existingSelection !== null && existingSelection !== expected.windowSelection) fail('WINDOW_SELECTION_CONFLICT');
    const found = await list(), databases = [];
    importing = {databases, expected, pending:'', position:0};
    if (found.some(entry => !expected.databases.some(database => database.name === entry.name))) fail('TARGET_DATABASE_CONFLICT');
    // Validate every existing database before creating any new database or writing any record.
    for (const entry of found) {
      const db = await connect(entry.name), definition = expected.databases.find(database => database.name === entry.name);
      databases.push({db, ...definition});
      const current = await describe(db);
      if (db.version !== definition.version || ascii(schema(current)) !== ascii(schema(definition.stores)) || current.some((store, index) => store.records > definition.stores[index].records)) fail('SCHEMA_CONFLICT');
    }
    for (const definition of expected.databases) {
      if (!databases.some(entry => entry.name === definition.name)) databases.push({db:await connect(definition.name, definition.version, definition.stores), ...definition});
    }
    importing.stores = expected.databases.flatMap(database => database.stores.map(store => ({database:databases.find(entry => entry.name === database.name), store, received:0, lastKey:undefined})));
    return {databases:databases.length, records:importing.stores.reduce((sum, entry) => sum + entry.store.records, 0)};
  }
  function writeRecords(database, records) {
    return new Promise((resolve, reject) => {
      const tx = database.db.transaction([...new Set(records.map(record => record.store.name))], 'readwrite');
      let problem;
      const abort = code => { problem = Object.assign(new Error(code), {code}); tx.abort(); };
      tx.onerror = () => {};
      tx.onabort = () => reject(problem || Object.assign(new Error('WRITE_FAILED'), {code:'WRITE_FAILED'}));
      tx.oncomplete = () => resolve();
      for (const record of records) {
        const store = tx.objectStore(record.store.name), keyRequest = store.getKey(record.key), valueRequest = store.get(record.key);
        let keyReady = false, valueReady = false;
        const check = () => {
          if (!keyReady || !valueReady || problem) return;
          try {
            if (keyRequest.result !== undefined) {
              if (!same(valueRequest.result, record.value)) abort('VALUE_CONFLICT');
            } else {
              const request = store.keyPath === null ? store.put(record.value, record.key) : store.put(record.value);
              request.onsuccess = () => { if (indexedDB.cmp(request.result, record.key) !== 0) abort('KEY_CONFLICT'); };
            }
          } catch { abort('WRITE_FAILED'); }
        };
        keyRequest.onsuccess = () => { keyReady = true; check(); };
        valueRequest.onsuccess = () => { valueReady = true; check(); };
      }
    });
  }
  async function importChunk(text) {
    if (!importing) fail('IMPORT_NOT_STARTED');
    if (typeof text !== 'string' || !text.length || text.length > LIMIT || /[^\x20-\x7e\n]/.test(text)) fail('INVALID_CHUNK');
    importing.pending += text;
    const lines = importing.pending.split('\n');
    importing.pending = lines.pop();
    if (lines.length > RECORD_LIMIT) fail('INVALID_CHUNK');
    const records = [];
    for (const line of lines) {
      const record = JSON.parse(line);
      while (importing.stores[importing.position] && importing.stores[importing.position].received === importing.stores[importing.position].store.records) importing.position++;
      const entry = importing.stores[importing.position];
      if (!Array.isArray(record) || record.length !== 4 || !entry || record[0] !== entry.database.name || record[1] !== entry.store.name) fail('RECORD_ORDER_CONFLICT');
      const key = decode(record[2]), value = decode(record[3]);
      IDBKeyRange.only(key);
      if (entry.received && indexedDB.cmp(entry.lastKey, key) >= 0) fail('RECORD_ORDER_CONFLICT');
      entry.lastKey = key; entry.received++;
      records.push({database:entry.database, store:entry.store, key, value});
    }
    for (const database of importing.databases) {
      const selected = records.filter(record => record.database === database);
      if (selected.length) await writeRecords(database, selected);
    }
    return {records:records.length};
  }
  async function importFinish() {
    if (!importing) fail('IMPORT_NOT_STARTED');
    if (importing.pending || importing.stores.some(entry => entry.received !== entry.store.records)) fail('IMPORT_INCOMPLETE');
    for (const database of importing.databases) {
      if (ascii(await describe(database.db)) !== ascii(database.stores)) fail('VERIFICATION_FAILED');
    }
    const existingSelection = windowSelection(), expectedSelection = importing.expected.windowSelection;
    if (existingSelection !== null && existingSelection !== expectedSelection) fail('WINDOW_SELECTION_CONFLICT');
    if (existingSelection === null && expectedSelection !== null) {
      window.localStorage.setItem(WINDOW_SELECTION_KEY, expectedSelection);
      if (windowSelection() !== expectedSelection) fail('WINDOW_SELECTION_WRITE_FAILED');
    }
    const result = {databases:importing.databases.length, records:importing.stores.reduce((sum, entry) => sum + entry.received, 0)};
    close(importing); importing = undefined;
    return result;
  }
  const guarded = operation => async (...args) => {
    if (busy) fail('BUSY');
    busy = true;
    try { return await operation(...args); }
    catch (error) {
      close(exporting); close(importing); exporting = importing = undefined;
      fail(error?.code && /^[A-Z_]+$/.test(error.code) ? error.code : 'OPERATION_FAILED');
    } finally { busy = false; }
  };
  Object.defineProperty(window, 'codipadStorageMigration', {value:Object.freeze(Object.fromEntries(Object.entries({exportBegin, exportNextChunk, importBegin, importChunk, importFinish}).map(([name, operation]) => [name, guarded(operation)])))});
})();
