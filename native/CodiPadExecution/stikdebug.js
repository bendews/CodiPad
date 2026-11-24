// CodiPad's debugger page protocol for StikDebug's JavaScript command API
// (https://github.com/StikDebug/StikDebug). The app validates the mappings and
// considers them usable only after the debugger detaches.
(function () {
    const page = 16384n;
    const max = 1280n * 1024n * 1024n;
    const fallback = 512n * 1024n * 1024n;
    const deadlineMs = 120000;
    const handshakeAddress = '__CODIPAD_HANDSHAKE_ADDRESS__';
    const handshakeToken = '__CODIPAD_HANDSHAKE_TOKEN__';
    let supplied = 0n;
    let responded = false;

    function command(packet) {
        const response = send_command(packet);
        if (typeof response !== 'string' || !response.length) throw Error('empty debugger response');
        return response;
    }
    function ok(packet) {
        if (command(packet) !== 'OK') throw Error('debugger command failed');
    }
    function decode(hex) {
        if (!/^[0-9a-fA-F]{16}$/.test(hex)) throw Error('invalid register');
        let value = 0n;
        for (let i = 14; i >= 0; i -= 2) value = (value << 8n) | BigInt('0x' + hex.slice(i, i + 2));
        return value;
    }
    function encode(value) {
        let result = '';
        for (let i = 0; i < 8; i++) {
            result += Number(value & 255n).toString(16).padStart(2, '0');
            value >>= 8n;
        }
        return result;
    }
    function register(stop, number) {
        const match = new RegExp('(?:^|;)' + number + ':([0-9a-fA-F]{16});').exec(stop);
        if (!match) throw Error('missing register ' + number);
        return decode(match[1]);
    }
    function put(thread, number, value) {
        ok('P' + number + '=' + encode(value) + ';thread:' + thread + ';');
    }
    function prepare(address, size) {
        const capabilities = command('qSupported').split(';');
        const packetSizes = capabilities.filter(s => s.startsWith('PacketSize='));
        if (!capabilities.includes('jMultiBreakpoint+') || packetSizes.length !== 1 ||
            !/^PacketSize=[0-9a-fA-F]+$/.test(packetSizes[0])) throw Error('missing debugger batch capability');
        const limit = Math.min(parseInt(packetSizes[0].slice(11), 16) - 128, 8192);
        if (limit < 1024) throw Error('debugger packet too small');
        const deadline = Date.now() + deadlineMs;
        let requests = [];
        function packet(items) { return 'jMultiBreakpoint:' + JSON.stringify({breakpoint_requests: items}); }
        function flush() {
            if (Date.now() > deadline) throw Error('debugger preparation timed out; restart required');
            let results;
            try { results = JSON.parse(command(packet(requests))).results; }
            catch (_) { throw Error('invalid debugger batch response; restart required'); }
            if (!Array.isArray(results) || results.length !== requests.length || results.some(x => x !== 'OK'))
                throw Error('incomplete debugger preparation; restart required');
            requests = [];
        }
        for (let offset = 0n; offset < size; offset += page) {
            const at = (address + offset).toString(16);
            const pair = ['Z0,' + at + ',4', 'z0,' + at + ',4'];
            if (packet(requests.concat(pair)).length + 8 > limit) {
                if (!requests.length) throw Error('debugger packet too small');
                flush();
            }
            requests.push(...pair);
        }
        if (requests.length) flush();
    }
    function allocate(size) {
        const sizes = size > fallback ? [size, fallback] : [size];
        for (const requested of sizes) {
            const response = command('_M' + requested.toString(16) + ',rx');
            if (/^E[0-9a-fA-F]{2}$/.test(response)) continue;
            if (!/^[0-9a-fA-F]+$/.test(response)) throw Error('ambiguous allocation response; restart required');
            const address = BigInt('0x' + response);
            if (!address || address % page || address + requested > (1n << 64n))
                throw Error('invalid allocation address; restart required');
            // Never retry after a page operation: a partial batch can leave breakpoints behind.
            prepare(address, requested);
            return [address, requested];
        }
        return [0n, 0n];
    }

    const pid = get_pid();
    if (!Number.isSafeInteger(pid) || pid <= 0) throw Error('invalid target PID');
    const attached = command('vAttach;' + pid.toString(16));
    if (!/^[TS][0-9a-fA-F]{2}/.test(attached)) throw Error('debugger attach failed');
    if (!/^[0-9a-fA-F]{1,16}$/.test(handshakeAddress) ||
        !/^[0-9a-fA-F]{32}$/.test(handshakeToken) || /^0+$/.test(handshakeToken))
        throw Error('invalid debugger handshake');
    if (command('m' + handshakeAddress + ',10').toLowerCase() !== handshakeToken.toLowerCase()) {
        ok('D');
        throw Error('debugger target identity mismatch');
    }
    const readyToken = handshakeToken.match(/../g)
        .map(byte => (255 - parseInt(byte, 16)).toString(16).padStart(2, '0')).join('');
    ok('M' + handshakeAddress + ',10:' + readyToken);
    for (;;) {
        const stop = command('c');
        const match = /(?:^T[0-9a-fA-F]{2}|;)thread:([0-9a-fA-F]+);/.exec(stop);
        if (!match) throw Error('unexpected debugger stop');
        const thread = match[1];
        const pc = register(stop, '20');
        const operation = register(stop, '10');
        if (command('m' + pc.toString(16) + ',4').toLowerCase() !== 'a0013ed4')
            throw Error('unexpected debugger instruction');
        if (operation === 2n && !responded) {
            put(thread, '20', pc + 4n);
            ok('D');
            return;
        } else if (operation === 1n && !responded) {
            const address = register(stop, '00');
            const size = register(stop, '01');
            if (address !== 0n || !size || size > max || size % page) throw Error('invalid allocation request');
            const allocation = allocate(size);
            supplied = allocation[1];
            put(thread, '0', allocation[0]);
            put(thread, '1', allocation[1]);
            put(thread, '20', pc + 4n);
            responded = true;
        } else if (operation === 0n && responded) {
            const success = register(stop, '00');
            const capacity = register(stop, '02');
            if (success !== 0n && (success !== 1n || !supplied ||
                (capacity !== supplied && !(supplied > fallback && capacity === fallback))))
                throw Error('invalid app preparation result');
            put(thread, '20', pc + 4n);
            ok('D');
            return;
        } else {
            throw Error('unexpected debugger operation');
        }
    }
})();
