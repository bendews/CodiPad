/*---------------------------------------------------------------------------------------------
 *  CodiPad iPad workbench — service overrides that must survive `Workbench.initServices`.
 *
 *  Verified mechanism (1.143.1, e646868): `Workbench.initServices`
 *  (`src/vs/workbench/browser/workbench.ts` L172-192) does
 *
 *      const contributedServices = getSingletonServiceDescriptors();
 *      for (const [id, descriptor] of contributedServices) {
 *          serviceCollection.set(id, descriptor);      // unconditional overwrite
 *      }
 *      const instantiationService = new InstantiationService(serviceCollection, true);
 *
 *  and `getSingletonServiceDescriptors()` returns `_registry`, a plain **array** that
 *  `registerSingleton()` appends to (`src/vs/platform/instantiation/common/extensions.ts`). So:
 *
 *   1. anything we put into the ServiceCollection is replaced by a contributed descriptor;
 *   2. duplicate ids are allowed and the *last* appended entry wins, because the loop sets in order;
 *   3. overrides must therefore be registered after the contribution graph has evaluated — i.e. at
 *      the bottom of the entrypoint, after `import './workbench.common.main.js'` side effects.
 *
 *  `registerSingleton()` also treats a non-descriptor argument as a *constructor*, so a concrete
 *  instance cannot be passed: it rides in a descriptor whose ctor returns it. Prefer a real class
 *  where the service does not need eager async setup; the instance form is what this slice needs
 *  because storage/workspace initialization is awaited before the workbench is constructed.
 *--------------------------------------------------------------------------------------------*/

import { SyncDescriptor } from '../../platform/instantiation/common/descriptors.js';
import { registerSingleton } from '../../platform/instantiation/common/extensions.js';
import { ServiceIdentifier } from '../../platform/instantiation/common/instantiation.js';
import { bootStep } from './boot.js';

export type OwnedService = readonly [ServiceIdentifier<unknown>, unknown];

export function overrideServiceInstance<T>(id: ServiceIdentifier<T>, instance: T): void {
	if (instance === null || (typeof instance !== 'object' && typeof instance !== 'function')) {
		throw new Error(`Service ${String(id)} requires an object instance`);
	}
	const serviceInstance = instance;
	class FixedInstance {
		constructor() {
			return serviceInstance;
		}
	}

	// The instance is already constructed. A delayed descriptor adds a proxy that
	// hides prototype hooks from upstream's `in` checks (including configuration
	// startup's acquireInstantiationService), and changes the instance's identity.
	registerSingleton(id, new SyncDescriptor(FixedInstance as unknown as new () => T, [], false));
}

/**
 * Re-registers every service this overlay owns, last, so `initServices()` cannot replace it.
 * Cheap and idempotent per page load; a reload is the only restart path we support today.
 */
export function registerIpadOverrides(owned: readonly OwnedService[]): void {
	for (const [id, instance] of owned) {
		overrideServiceInstance(id, instance);
	}

	bootStep('service-overrides', `${owned.length} registrations re-applied after the contribution graph`);
}
