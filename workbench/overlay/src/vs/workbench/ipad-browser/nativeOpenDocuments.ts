/*---------------------------------------------------------------------------------------------
 * Restore picker authority before editor layout, then track the files actually open in this scene.
 *--------------------------------------------------------------------------------------------*/
import { Disposable, DisposableStore } from '../../base/common/lifecycle.js';
import { autorun, IReader } from '../../base/common/observable.js';
import { URI } from '../../base/common/uri.js';
import { IUriIdentityService } from '../../platform/uriIdentity/common/uriIdentity.js';
import { ILifecycleService } from '../services/lifecycle/common/lifecycle.js';
import { IWorkingCopyService } from '../services/workingCopy/common/workingCopyService.js';
import { EditorResourceAccessor, EditorsOrder, isSideBySideEditorInput } from '../common/editor.js';
import { EditorInput } from '../common/editor/editorInput.js';
import { IEditorGroupsService } from '../services/editor/common/editorGroupsService.js';
import { IEditorService } from '../services/editor/common/editorService.js';
import { callNative } from './nativeBridge.js';
import { bootWarn } from './boot.js';

export async function restoreOpenDocumentAuthorities(layout: string): Promise<boolean> {
	try {
		await callNative('documents.restoreOpen', { layout });
		return true;
	} catch {
		bootWarn('document-restore', 'Some saved document access could not be restored. Select the files again to reopen them.');
		return false;
	}
}

/** Native only accepts previously picker-authorized resources; this is a snapshot, not a grant. */
export class NativeOpenDocuments extends Disposable {
	private layout: string;
	private allowed: boolean;
	private ready = false;
	private paused = false;
	private stopped = false;
	private timer: ReturnType<typeof setTimeout> | undefined;
	private pending: Promise<void> = Promise.resolve();
	private lastSnapshot: string | undefined;
	private readonly compositeObservers = this._register(new DisposableStore());

	constructor(layout: string, allowed: boolean, private readonly editors: IEditorService,
		groups: IEditorGroupsService, copies: IWorkingCopyService, lifecycle: ILifecycleService,
		private readonly identity: IUriIdentityService) {
		super();
		this.layout = layout;
		this.allowed = allowed;
		this._register(editors.onDidEditorsChange(() => { if (this.ready && !this.paused) { this.observeComposites(); } this.schedule(); }));
		this._register(copies.onDidSave(() => this.schedule()));
		this._register(lifecycle.onWillShutdown(() => this.stop()));
		void groups.whenRestored.then(() => {
			if (this.stopped) { return; }
			this.ready = true;
			if (!this.paused) { this.observeComposites(); }
			this.schedule();
		}).catch(() => { /* Keep the prior record if editor restoration failed. */ });
	}

	private snapshot(): string[] | undefined {
		const found = new Map<string, string>();
		let complete = true;
		const add = (value: unknown) => {
			if (!URI.isUri(value) || value.scheme !== 'file' || value.authority || !value.path.startsWith('/')) { return; }
			const resource = value.with({ query: '', fragment: '' });
			found.set(this.identity.extUri.getComparisonKey(resource), resource.toString());
		};
		const visit = (editor: EditorInput) => {
			if (isSideBySideEditorInput(editor)) { visit(editor.primary); visit(editor.secondary); return; }
			add(EditorResourceAccessor.getCanonicalUri(editor));
			if (editor.typeId === 'mergeEditor.Input') {
				const merge = editor as EditorInput & { base?: URI; result?: URI; input1?: { uri?: URI }; input2?: { uri?: URI } };
				add(merge.base); add(merge.result); add(merge.input1?.uri); add(merge.input2?.uri);
			}
			if (editor.typeId === 'workbench.input.multiDiffEditor') {
				const multi = editor as EditorInput & { resources?: { get(): readonly { originalUri?: URI; modifiedUri?: URI; goToFileUri?: URI }[] | undefined } };
				const resources = multi.resources?.get();
				if (!resources) { complete = false; return; }
				for (const item of resources) { add(item.originalUri); add(item.modifiedUri); add(item.goToFileUri); }
			}
		};
		for (const { editor } of this.editors.getEditors(EditorsOrder.SEQUENTIAL)) { visit(editor); }
		return complete ? [...found.values()].sort() : undefined;
	}

	private observeComposites(): void {
		this.compositeObservers.clear();
		const observe = (editor: EditorInput) => {
			if (isSideBySideEditorInput(editor)) { observe(editor.primary); observe(editor.secondary); return; }
			if (editor.typeId !== 'workbench.input.multiDiffEditor') { return; }
			const multi = editor as EditorInput & { resources?: { read(reader: IReader | undefined): unknown } };
			if (multi.resources) {
				this.compositeObservers.add(autorun(reader => { multi.resources!.read(reader); this.schedule(); }));
			}
		};
		for (const { editor } of this.editors.getEditors(EditorsOrder.SEQUENTIAL)) { observe(editor); }
	}

	private schedule(delay = 100): void {
		if (this.stopped || this.paused || !this.ready || !this.allowed || this.timer !== undefined) { return; }
		this.timer = setTimeout(() => {
			this.timer = undefined;
			this.enqueue();
		}, delay);
	}

	private enqueue(): void {
		this.pending = this.pending.then(async () => {
			if (this.stopped || this.paused || !this.ready || !this.allowed) { return; }
			const uris = this.snapshot();
			if (!uris) { return; }
			const layout = this.layout;
			const snapshot = JSON.stringify([layout, uris]);
			if (snapshot === this.lastSnapshot) { return; }
			await callNative('documents.syncOpen', { layout, uris });
			this.lastSnapshot = snapshot;
		}).catch(() => {
			bootWarn('document-sync', 'Open document access could not be saved for the next launch.');
		});
	}

	/** Settle the old layout before storage switches and suppress intermediate empty editor sets. */
	async pause(): Promise<void> {
		if (this.paused) { await this.pending; return; }
		this.paused = true;
		if (this.timer !== undefined) { clearTimeout(this.timer); this.timer = undefined; }
		await this.pending;
		if (this.stopped || !this.ready || !this.allowed) { return; }
		let uris: string[] | undefined;
		try { uris = this.snapshot(); }
		catch {
			bootWarn('document-sync', 'Open document access could not be saved for the next launch.');
			return;
		}
		if (!uris) { return; }
		const snapshot = JSON.stringify([this.layout, uris]);
		if (snapshot === this.lastSnapshot) { return; }
		try {
			await callNative('documents.syncOpen', { layout: this.layout, uris });
			this.lastSnapshot = snapshot;
		} catch {
			bootWarn('document-sync', 'Open document access could not be saved for the next launch.');
		}
	}

	resume(layout: string, allowed: boolean): void {
		if (this.stopped) { return; }
		if (this.layout !== layout) { this.lastSnapshot = undefined; }
		this.layout = layout;
		this.allowed = allowed;
		this.paused = false;
		if (this.ready) { this.observeComposites(); }
		this.schedule();
	}

	private stop(): void {
		this.stopped = true;
		if (this.timer !== undefined) { clearTimeout(this.timer); this.timer = undefined; }
	}

	override dispose(): void { this.stop(); super.dispose(); }
}
