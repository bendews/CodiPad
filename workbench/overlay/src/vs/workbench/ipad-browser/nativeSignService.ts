import { SignService } from '../../platform/sign/browser/signService.js';

// The optional Microsoft development signer must never inherit the upstream
// missing-VSDA fallback that accepts a server without validating it.
export class RequiredMicrosoftSignService extends SignService {
	private readonly codipadValidators = new Map<string, { validator: { createNewMessage(value: string): string; validate(value: string): 'ok' | 'error'; dispose?(): void }; timer: ReturnType<typeof setTimeout> }>();
	private nextValidator = 0;

	override async createNewMessage(value: string) {
		const validator = await this.getValidator();
		try {
			const data = validator.createNewMessage(value);
			const id = String(++this.nextValidator);
			const timer = setTimeout(() => {
				const entry = this.codipadValidators.get(id);
				if (entry) { this.codipadValidators.delete(id); entry.validator.dispose?.(); }
			}, 30000);
			this.codipadValidators.set(id, { validator, timer });
			return { id, data };
		} catch (error) {
			validator.dispose?.();
			throw error;
		}
	}
	override async validate(message: Parameters<SignService['validate']>[0], value: string): Promise<boolean> {
		const entry = this.codipadValidators.get(message.id);
		if (!entry) { return false; }
		this.codipadValidators.delete(message.id);
		clearTimeout(entry.timer);
		try { return entry.validator.validate(value) === 'ok'; }
		catch { return false; }
		finally { entry.validator.dispose?.(); }
	}
	override async sign(value: string): Promise<string> {
		return this.signValue(value);
	}
}

