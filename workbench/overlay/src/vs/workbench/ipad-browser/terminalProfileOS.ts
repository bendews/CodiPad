import { posix } from '../../base/common/path.js';

/** Use the guest platform for local native terminals; remote terminals keep their reported OS. */
export function nativeTerminalPlatformKey(remoteAuthority: string | undefined, reportedPlatformKey: string): string {
	return remoteAuthority ? reportedPlatformKey : 'linux';
}

export function withGuestTerminalOS<T extends { os: unknown; remoteAuthority?: string }, U>(options: T, useNativeLocal: boolean, os: U): T | (Omit<T, 'os'> & { os: U }) {
	return useNativeLocal ? { ...options, os } : options;
}

export function resolveConfiguredTerminalDefault<T>(
	defaultProfileName: unknown,
	profiles: unknown,
	resolve: () => T,
	higherPriorityProfileSelected = false
): T | undefined {
	if (!higherPriorityProfileSelected && typeof defaultProfileName === 'string' && profiles && typeof profiles === 'object' && !Array.isArray(profiles)) {
		const profile = (profiles as Record<string, unknown>)[defaultProfileName];
		if (profile && typeof profile === 'object' && !Array.isArray(profile) && Array.isArray((profile as Record<string, unknown>).path)) {
			// The synchronous UI lookup must defer arrays to the asynchronous resolver.
			return undefined;
		}
	}
	return resolve();
}

export async function guestDetectedShells(contents: string, existsFile: (path: string) => Promise<boolean>): Promise<Array<{ name: string; path: string }>> {
	const shells = contents.split('\n').map(line => line.split('#', 1)[0].trim()).filter(path => path.startsWith('/') && !path.includes('\0'));
	const counts = new Map<string, number>();
	const result: Array<{ name: string; path: string }> = [];
	for (const path of shells) {
		if (!await existsFile(path)) { continue; }
		const base = posix.basename(path);
		const count = (counts.get(base) ?? 0) + 1;
		counts.set(base, count);
		result.push({ name: count === 1 ? base : `${base} (${count})`, path });
	}
	if (!result.length) {
		for (const path of ['/bin/bash', '/bin/sh']) {
			if (await existsFile(path)) { result.push({ name: posix.basename(path), path }); }
		}
	}
	return result;
}

/** POSIX candidate lookup uses the guest PATH and regular-file semantics, never the host cwd. */
export async function resolveGuestProfilePath(paths: unknown[], environment: { [key: string]: string | undefined }, existsFile: (path: string) => Promise<boolean>, cwd?: string): Promise<string | undefined> {
	for (const candidate of paths) {
		if (typeof candidate !== 'string' || candidate.includes('\0')) {
			throw new Error('[codipad-terminal] invalid profile path alternative');
		}
		if (!candidate) { continue; }
		if (posix.isAbsolute(candidate)) {
			if (await existsFile(posix.normalize(candidate))) { return candidate; }
			continue;
		}
		if (!cwd || !posix.isAbsolute(cwd)) { throw new Error('[codipad-terminal] profile lookup requires an authorized guest cwd'); }
		if (posix.basename(candidate) !== candidate) {
			const path = posix.resolve(cwd, candidate);
			if (await existsFile(path)) { return path; }
			continue;
		}
		for (const directory of environment.PATH?.split(':') ?? []) {
			const path = posix.resolve(cwd, directory || '.', candidate);
			if (await existsFile(path)) { return path; }
		}
		const path = posix.resolve(cwd, candidate);
		if (await existsFile(path)) { return path; }
	}
	return undefined;
}
