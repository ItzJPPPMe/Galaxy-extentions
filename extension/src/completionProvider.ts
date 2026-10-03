import * as vscode from 'vscode';
import * as cp from 'child_process';

export interface EngineCompletionItem {
    label: string;
    text: string;
    detail: string;
    kind: string;
    documentation: string;
    score: number;
    inline: boolean;
}

export interface EngineCompletionPayload {
    trigger: string;
    inlineText: string;
    isIncomplete: boolean;
    items: EngineCompletionItem[];
    source?: string;
    aiQueued?: boolean;
    aiEnabled?: boolean;
    provider?: string;
    model?: string;
}

export interface EngineFinalPayload extends EngineCompletionPayload {
    available?: boolean;
    cached?: boolean;
    aborted?: boolean;
    rejected?: boolean;
    rejectReason?: string;
    acceptedLines?: number;
    overlap?: number;
    finishReason?: string;
    elapsedMs?: number;
    error?: string;
}

export interface StreamHandlers {
    onDelta?: (chunk: string, accumulated: string) => void;
    onFinal?: (payload: EngineFinalPayload) => void;
}

export interface AIPreferences {
    enabled: boolean;
    provider: string;
    model: string;
    maxTokens: number;
    temperature: number;
    stream: boolean;
    chatMode: boolean;
    promptStyle: string;
    prefixLines: number;
    suffixLines: number;
}

export interface EngineRequestContext {
    filePath: string;
    languageId: string;
    line: number;
    character: number;
    prefix: string;
    suffix: string;
    currentLine: string;
    previousLines: string[];
    nextLines: string[];
    ai?: AIPreferences;
}

export type ProvideInlineCompletionItemsResult =
    | vscode.InlineCompletionList
    | vscode.InlineCompletionItem[]
    | null
    | undefined;

export interface EngineEnvelope {
    id: string;
    type: string;
    status: string;
    protocol: string;
    payload: unknown;
}

export interface EngineStartOptions {
    args?: string[];
    env?: NodeJS.ProcessEnv;
    cwd?: string;
}

export type EngineState = 'starting' | 'ready' | 'stopped' | 'crashed' | 'missing' | 'disabled';

const CURSOR_MARKER = '<cursor>';
const IDENTIFIER_PATTERN = /[A-Za-z_$][A-Za-z0-9_$]*$/;
const CONTEXT_LINES = 12;

interface PendingEntry {
    resolve: (payload: unknown) => void;
    reject: (error: Error) => void;
    timer: NodeJS.Timeout;
    subscription: vscode.Disposable;
}

interface StreamEntry {
    handlers: StreamHandlers;
    accumulated: string;
    timer: NodeJS.Timeout;
}

export class GalaxyEngineClient {
    private child: cp.ChildProcessWithoutNullStreams | undefined;
    private readonly pending = new Map<string, PendingEntry>();
    private readonly streams = new Map<string, StreamEntry>();
    private readonly stateEmitter = new vscode.EventEmitter<EngineState>();
    private buffer = '';
    private sequence = 0;
    private stoppedByUser = false;

    public readonly onStateChanged = this.stateEmitter.event;

    constructor(private readonly output: vscode.OutputChannel) {}

    get isRunning(): boolean {
        return this.child !== undefined && this.child.exitCode === null;
    }

    get state(): EngineState {
        if (!this.isRunning) {
            return 'stopped';
        }

        return 'starting';
    }

    get lastRequestId(): string {
        return this.sequence === 0 ? '' : `${Date.now().toString(36)}-${this.sequence}`;
    }

    async start(binary: string, options: EngineStartOptions = {}): Promise<void> {
        if (this.isRunning) {
            return;
        }

        this.buffer = '';
        this.stoppedByUser = false;
        this.stateEmitter.fire('starting');
        this.output.appendLine(`starting engine: ${binary}`);

        const child = cp.spawn(binary, options.args ?? [], {
            cwd: options.cwd,
            env: { ...process.env, ...(options.env ?? {}) },
            stdio: ['pipe', 'pipe', 'pipe'],
            windowsHide: true
        });

        this.child = child;

        child.stdout.setEncoding('utf8');
        child.stdout.on('data', (chunk: string) => this.consume(chunk));
        child.stderr.setEncoding('utf8');
        child.stderr.on('data', (chunk: string) => this.output.appendLine(`engine stderr: ${chunk.trimEnd()}`));

        child.on('error', (error: Error) => {
            this.output.appendLine(`engine error: ${error.message}`);
            this.stateEmitter.fire('missing');
        });

        child.on('exit', (code: number | null, signal: string | null) => {
            const reason = signal !== null ? `signal ${signal}` : `code ${code ?? -1}`;
            this.output.appendLine(`engine exited with ${reason}`);
            this.child = undefined;
            this.rejectAll(new Error(`engine exited with ${reason}`));
            this.stateEmitter.fire(this.stoppedByUser ? 'stopped' : 'crashed');
        });

        try {
            const handshake = await this.request<{ engineVersion?: string; protocol?: string }>(
                'initialize',
                { client: 'vscode', clientVersion: extensionVersion() },
                4000
            );
            this.output.appendLine(`engine ready: ${JSON.stringify(handshake)}`);
            this.stateEmitter.fire('ready');
        } catch (error) {
            this.stop();
            throw error;
        }
    }

    stop(): void {
        const child = this.child;

        if (!child) {
            return;
        }

        this.stoppedByUser = true;

        try {
            child.stdin.write(`${JSON.stringify({ id: 'shutdown', type: 'shutdown' })}\n`);
            child.stdin.end();
        } catch (error) {
            this.output.appendLine(`shutdown write failed: ${String(error)}`);
        }

        this.child = undefined;
        this.rejectAll(new Error('engine stopped'));
        this.stateEmitter.fire('stopped');
    }

    async health(): Promise<Record<string, unknown>> {
        return this.request<Record<string, unknown>>('health', {}, 1500);
    }

    request<T>(
        type: string,
        payload: object,
        timeoutMs: number,
        token?: vscode.CancellationToken,
        handlers?: StreamHandlers
    ): Promise<T> {
        const child = this.child;

        if (!child) {
            return Promise.reject(new Error('engine is not running'));
        }

        const id = `${Date.now().toString(36)}-${++this.sequence}`;

        if (handlers) {
            this.streams.set(id, {
                handlers,
                accumulated: '',
                timer: setTimeout(() => this.dropStream(id), timeoutMs * 3)
            });
        }

        return new Promise<T>((resolve, reject) => {
            const entry: PendingEntry = {
                resolve: (value: unknown) => resolve(value as T),
                reject,
                timer: setTimeout(() => {
                    this.settle(id);
                    reject(new Error(`engine request timed out: ${type}`));
                }, timeoutMs),
                subscription: new vscode.Disposable(() => undefined)
            };

            if (token) {
                entry.subscription = token.onCancellationRequested(() => {
                    this.settle(id);
                    reject(new Error(`engine request cancelled: ${type}`));
                });
            }

            this.pending.set(id, entry);

            try {
                child.stdin.write(`${JSON.stringify({ id, type, payload })}\n`);
            } catch (error) {
                this.settle(id);
                reject(error instanceof Error ? error : new Error(String(error)));
            }
        });
    }

    abort(target: string): void {
        this.dropStream(target);

        const child = this.child;

        if (!child) {
            return;
        }

        try {
            child.stdin.write(`${JSON.stringify({ id: `abort-${target}`, type: 'abort', payload: { target } })}\n`);
        } catch (error) {
            this.output.appendLine(`abort write failed: ${String(error)}`);
        }
    }

    dispose(): void {
        this.stop();
        this.rejectAll(new Error('engine client disposed'));
        this.stateEmitter.dispose();
    }

    private consume(chunk: string): void {
        this.buffer += chunk;

        let separator = this.buffer.indexOf('\n');

        while (separator >= 0) {
            const line = this.buffer.slice(0, separator).trim();
            this.buffer = this.buffer.slice(separator + 1);

            if (line.length > 0) {
                this.handleLine(line);
            }

            separator = this.buffer.indexOf('\n');
        }
    }

    private handleLine(line: string): void {
        let envelope: EngineEnvelope;

        try {
            envelope = JSON.parse(line) as EngineEnvelope;
        } catch {
            this.output.appendLine(`engine emitted invalid json: ${line}`);
            return;
        }

        if (envelope.type === 'delta') {
            this.routeDelta(envelope);
            return;
        }

        if (envelope.type === 'final') {
            this.routeFinal(envelope);
            return;
        }

        if (envelope.type !== 'response') {
            this.output.appendLine(`engine ${envelope.type}: ${line}`);
            return;
        }

        const entry = this.pending.get(envelope.id);

        if (!entry) {
            if (envelope.id === 'boot' || envelope.id === 'exit' || envelope.id === 'shutdown') {
                this.output.appendLine(`engine ${envelope.id}: ${line}`);
                return;
            }

            this.output.appendLine(`engine answered unknown id ${envelope.id}`);
            return;
        }

        this.pending.delete(envelope.id);
        clearTimeout(entry.timer);
        entry.subscription.dispose();

        if (envelope.status === 'error') {
            const failure = envelope.payload as { code?: string; message?: string } | undefined;
            entry.reject(new Error(failure?.message ?? 'engine reported an error'));
            return;
        }

        entry.resolve(envelope.payload);
    }

    private routeDelta(envelope: EngineEnvelope): void {
        const stream = this.streams.get(envelope.id);

        if (!stream) {
            return;
        }

        const payload = envelope.payload as { text?: string; done?: boolean };

        if (typeof payload.text === 'string' && payload.text.length > 0) {
            stream.accumulated += payload.text;
            stream.handlers.onDelta?.(payload.text, stream.accumulated);
        }
    }

    private routeFinal(envelope: EngineEnvelope): void {
        const stream = this.streams.get(envelope.id);

        if (!stream) {
            return;
        }

        stream.handlers.onFinal?.(envelope.payload as EngineFinalPayload);
        this.dropStream(envelope.id);
    }

    private dropStream(id: string): void {
        const stream = this.streams.get(id);

        if (!stream) {
            return;
        }

        clearTimeout(stream.timer);
        this.streams.delete(id);
    }

    private settle(id: string): void {
        const entry = this.pending.get(id);

        if (!entry) {
            return;
        }

        this.pending.delete(id);
        clearTimeout(entry.timer);
        entry.subscription.dispose();
    }

    private rejectAll(error: Error): void {
        for (const [id, entry] of this.pending) {
            this.settle(id);
            entry.reject(error);
        }

        for (const id of Array.from(this.streams.keys())) {
            this.dropStream(id);
        }
    }
}

export class GalaxyCompletionProvider implements vscode.CompletionItemProvider {
    constructor(private readonly client: GalaxyEngineClient) {}

    async provideCompletionItems(
        document: vscode.TextDocument,
        position: vscode.Position,
        token: vscode.CancellationToken
    ): Promise<vscode.CompletionList | undefined> {
        if (!vscode.workspace.getConfiguration('galaxy').get<boolean>('completion.list.enabled', true)) {
            return undefined;
        }

        if (!this.client.isRunning) {
            return undefined;
        }

        const request = buildEngineRequest(document, position);
        request.ai = { ...readAIPreferences(), enabled: false };

        try {
            const payload = await this.client.request<EngineCompletionPayload>(
                'completion',
                request,
                requestTimeout(),
                token
            );

            const limit = vscode.workspace.getConfiguration('galaxy').get<number>('completion.inline.maxItems', 5);
            const items = payload.items.slice(0, limit).map((entry) => toCompletionItem(entry));

            return new vscode.CompletionList(items, payload.isIncomplete);
        } catch {
            return undefined;
        }
    }
}

export class GalaxyInlineCompletionProvider implements vscode.InlineCompletionItemProvider {
    private activeId: string | undefined;
    private generationInFlight = false;
    private watchdog: NodeJS.Timeout | undefined;

    constructor(private readonly client: GalaxyEngineClient) {}

    async provideInlineCompletionItems(
        document: vscode.TextDocument,
        position: vscode.Position,
        _context: vscode.InlineCompletionContext,
        token: vscode.CancellationToken
    ): Promise<ProvideInlineCompletionItemsResult> {
        const settings = vscode.workspace.getConfiguration('galaxy');

        if (!settings.get<boolean>('completion.inline.enabled', true)) {
            return undefined;
        }

        const mode = settings.get<string>('completion.inline.mode', 'hybrid');
        const minimum = settings.get<number>('completion.inline.minPrefixLength', 1);
        const debounce = settings.get<number>('engine.requestDebounceMs', 60);

        if (mode === 'list' || !this.client.isRunning) {
            return undefined;
        }

        const context = buildEngineRequest(document, position);
        const preferences = readAIPreferences();
        const wantsModel = preferences.enabled && !this.generationInFlight;
        const request = { ...context, ai: { ...preferences, enabled: wantsModel } };

        if (context.prefix.length < minimum) {
            return undefined;
        }

        if (settings.get<boolean>('completion.suppressInComments', true) && isInCommentLine(context.currentLine, context.character)) {
            return undefined;
        }

        if (this.activeId !== undefined) {
            this.client.abort(this.activeId);
            this.activeId = undefined;
        }

        let suggested: vscode.InlineCompletionItem | undefined;
        let resolveFinal: ((payload: EngineFinalPayload) => void) | undefined;

        const finalAnswer = new Promise<EngineFinalPayload>((resolve) => {
            resolveFinal = resolve;
        });

        const upgrade = (raw: string): void => {
            const text = normalizeInlineText(raw, context.prefix);

            if (text.length === 0) {
                return;
            }

            if (!suggested) {
                suggested = new vscode.InlineCompletionItem(text, inlineRange(document, position, text));
                return;
            }

            const current = typeof suggested.insertText === 'string' ? suggested.insertText : '';

            if (text.length < current.length) {
                return;
            }

            suggested.insertText = text;
            suggested.range = inlineRange(document, position, text);
        };

        const release = (): void => {
            this.generationInFlight = false;

            if (this.watchdog !== undefined) {
                clearTimeout(this.watchdog);
                this.watchdog = undefined;
            }
        };

        const handlers: StreamHandlers = {
            onDelta: (_chunk, accumulated) => {
                if (suggested !== undefined) {
                    upgrade(accumulated);
                }
            },
            onFinal: (payload) => {
                release();

                if (payload.rejected !== true && payload.available !== false) {
                    upgrade(payload.inlineText ?? '');
                }

                resolveFinal?.(payload);
            }
        };

        const timeout = requestTimeout();

        try {
            if (debounce > 0) {
                await delay(debounce, token);
            }

            if (token.isCancellationRequested) {
                return undefined;
            }

            if (wantsModel) {
                this.generationInFlight = true;
                this.watchdog = setTimeout(release, settings.get<number>('engine.modelTimeoutMs', 4000) * 3);
            }

            const payloadPromise = this.client.request<EngineCompletionPayload>(
                'completion',
                request,
                timeout,
                token,
                handlers
            );

            this.activeId = this.client.lastRequestId;

            const payload = await payloadPromise;

            if (payload.aiEnabled !== true || !wantsModel) {
                this.activeId = undefined;
            }

            upgrade(payload.inlineText);

            if (suggested === undefined && payload.aiQueued === true) {
                const deadline = settings.get<number>('engine.modelTimeoutMs', 4000);
                await Promise.race([finalAnswer, delay(deadline, token)]);
            }

            if (suggested === undefined) {
                this.activeId = undefined;
                return undefined;
            }

            return { items: [suggested] };
        } catch {
            this.activeId = undefined;
            release();
            return undefined;
        }
    }
}

function toCompletionItem(entry: EngineCompletionItem): vscode.CompletionItem {
    const item = new vscode.CompletionItem(entry.label, completionKind(entry.kind));

    item.insertText = entry.text;
    item.detail = entry.detail.length > 0 ? entry.detail : entry.kind;
    item.documentation = entry.documentation.length > 0 ? entry.documentation : undefined;
    item.sortText = String(1_000_000 - Math.min(999_999, Math.max(0, entry.score)));
    item.filterText = entry.label;
    item.preselect = entry.inline;

    return item;
}

function completionKind(kind: string): vscode.CompletionItemKind {
    switch (kind) {
        case 'keyword':
            return vscode.CompletionItemKind.Keyword;
        case 'function':
        case 'member':
            return vscode.CompletionItemKind.Function;
        case 'type':
            return vscode.CompletionItemKind.Struct;
        case 'snippet':
            return vscode.CompletionItemKind.Snippet;
        case 'module':
            return vscode.CompletionItemKind.Module;
        case 'property':
            return vscode.CompletionItemKind.Property;
        default:
            return vscode.CompletionItemKind.Text;
    }
}

function normalizeInlineText(text: string, prefix: string): string {
    let result = text.replace(new RegExp(CURSOR_MARKER, 'g'), '');

    if (prefix.length > 0 && result.startsWith(prefix)) {
        result = result.slice(prefix.length);
    }

    return result.replace(/\s+$/, '');
}

function inlineRange(document: vscode.TextDocument, position: vscode.Position, text: string): vscode.Range {
    const line = document.lineAt(position.line).text;
    const tail = line.slice(position.character);
    const end = position.translate(0, Math.min(tail.length, text.length));

    return new vscode.Range(position, end);
}

function isInCommentLine(line: string, character: number): boolean {
    const head = line.slice(0, character);
    const single = head.indexOf('//');
    const block = head.indexOf('/*');
    const closed = head.indexOf('*/');

    if (single >= 0) {
        return true;
    }

    return block >= 0 && closed <= block;
}

export function buildEngineRequest(document: vscode.TextDocument, position: vscode.Position): EngineRequestContext {
    const line = document.lineAt(position.line).text;
    const head = line.slice(0, position.character);
    const match = IDENTIFIER_PATTERN.exec(head);

    const previousLines: string[] = [];
    const from = Math.max(0, position.line - CONTEXT_LINES);

    for (let index = from; index < position.line; index++) {
        previousLines.push(document.lineAt(index).text);
    }

    const nextLines: string[] = [];
    const to = Math.min(document.lineCount - 1, position.line + CONTEXT_LINES);

    for (let index = position.line + 1; index <= to; index++) {
        nextLines.push(document.lineAt(index).text);
    }

    return {
        filePath: document.uri.fsPath,
        languageId: document.languageId,
        line: position.line,
        character: position.character,
        prefix: match ? match[0] : '',
        suffix: line.slice(position.character),
        currentLine: line,
        previousLines,
        nextLines
    };
}

export function readAIPreferences(): AIPreferences {
    const ai = vscode.workspace.getConfiguration('galaxy.ai');

    return {
        enabled: ai.get<boolean>('enabled', false),
        provider: ai.get<string>('provider', 'auto'),
        model: ai.get<string>('model', ''),
        maxTokens: ai.get<number>('maxTokens', 96),
        temperature: ai.get<number>('temperature', 0.2),
        stream: ai.get<boolean>('stream', true),
        chatMode: ai.get<boolean>('chatMode', false),
        promptStyle: ai.get<string>('promptStyle', 'fim'),
        prefixLines: ai.get<number>('prefixLines', 60),
        suffixLines: ai.get<number>('suffixLines', 24)
    };
}

export function requestTimeout(): number {
    return vscode.workspace.getConfiguration('galaxy').get<number>('engine.requestTimeoutMs', 2500);
}

function delay(milliseconds: number, token: vscode.CancellationToken): Promise<void> {
    return new Promise<void>((resolve) => {
        const timer = setTimeout(() => {
            subscription.dispose();
            resolve();
        }, milliseconds);

        const subscription = token.onCancellationRequested(() => {
            clearTimeout(timer);
            resolve();
        });
    });
}

function extensionVersion(): string {
    const extension = vscode.extensions.getExtension('galaxy-labs.galaxy-extension');

    return extension === undefined ? '0.0.0' : (extension.packageJSON.version as string);
}