import * as vscode from 'vscode';
import * as fs from 'fs';
import * as path from 'path';
import {
    EngineState,
    GalaxyCompletionProvider,
    GalaxyEngineClient,
    GalaxyInlineCompletionProvider
} from './completionProvider';

const SECTION = 'galaxy';
const BINARY_NAMES = process.platform === 'win32' ? ['galaxy-engine.exe', 'galaxy-engine'] : ['galaxy-engine'];
const TRIGGER_CHARACTERS = ['.', ':', '/', '"', '\'', '(', '[', '<', '>', ' ', '\t'];
const AI_SECTION = `${SECTION}.ai`;

const STATE_ICONS: Record<string, string> = {
    starting: '$(sync~spin)',
    ready: '$(sparkle)',
    stopped: '$(circle-slash)',
    crashed: '$(error)',
    missing: '$(warning)',
    disabled: '$(circle-slash)'
};

let client: GalaxyEngineClient | undefined;
let channel: vscode.OutputChannel | undefined;
let statusBar: vscode.StatusBarItem | undefined;
let engineBinary: string | undefined;
let providerRegistrations: vscode.Disposable[] = [];
let activeState: EngineState = 'stopped';

export async function activate(context: vscode.ExtensionContext): Promise<void> {
    channel = vscode.window.createOutputChannel('Galaxy Engine');
    context.subscriptions.push(channel);

    statusBar = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Right, 100);
    statusBar.command = 'galaxy.restartEngine';
    context.subscriptions.push(statusBar);

    registerCommands(context);

    context.subscriptions.push(
        vscode.workspace.onDidChangeConfiguration((event) => {
            if (event.affectsConfiguration(`${SECTION}.engine.path`) || event.affectsConfiguration(`${SECTION}.engine.enabled`)) {
                void restartEngine(context);
                return;
            }

            if (event.affectsConfiguration(`${SECTION}.completion.languages`)) {
                registerProviders(context);
            }

            if (event.affectsConfiguration(AI_SECTION)) {
                void pushModelConfiguration();
                return;
            }

            if (event.affectsConfiguration(`${SECTION}.completion.inline.enabled`)) {
                writeLine(`inline completion ${enabled('completion.inline.enabled') ? 'enabled' : 'disabled'}`);
            }
        })
    );

    await startEngine(context);
}

export function deactivate(): void {
    disposeProviders();

    const running = client;
    client = undefined;
    running?.stop();

    setState('stopped');
}

function registerCommands(context: vscode.ExtensionContext): void {
    context.subscriptions.push(
        vscode.commands.registerCommand('galaxy.restartEngine', async () => {
            await restartEngine(context);
        }),
        vscode.commands.registerCommand('galaxy.showLogs', () => {
            channel?.show(true);
        }),
        vscode.commands.registerCommand('galaxy.toggleInlineCompletion', async () => {
            const next = !enabled('completion.inline.enabled');
            await vscode.workspace
                .getConfiguration(SECTION)
                .update('completion.inline.enabled', next, vscode.ConfigurationTarget.Global);
            writeLine(`inline completion ${next ? 'enabled' : 'disabled'}`);
        }),
        vscode.commands.registerCommand('galaxy.showEngineStatus', () => {
            void vscode.window.showInformationMessage(
                `Galaxy engine state: ${activeState}, binary: ${engineBinary ?? 'not resolved'}`
            );
        })
    );
}

async function startEngine(context: vscode.ExtensionContext): Promise<void> {
    disposeProviders();

    if (!enabled('engine.enabled')) {
        setState('disabled');
        writeLine('engine disabled by configuration');
        return;
    }

    const binary = resolveEngineBinary(context.extensionPath);

    if (binary === undefined) {
        engineBinary = undefined;
        setState('missing');
        writeLine('engine binary not found, build it with: npm run engine:build');

        const selection = await vscode.window.showWarningMessage(
            'Galaxy could not locate the engine binary. Run "npm run engine:build" and reload the window.',
            'Show Logs'
        );

        if (selection === 'Show Logs') {
            channel?.show(true);
        }

        return;
    }

    engineBinary = binary;
    writeLine(`resolved engine binary: ${binary}`);

    const engine = new GalaxyEngineClient(channel as vscode.OutputChannel);
    client = engine;
    context.subscriptions.push(engine);

    engine.onStateChanged((state) => {
        setState(state);

        if (state === 'crashed' && enabled('engine.autoRestart')) {
            writeLine('engine crashed, scheduling restart');
            setTimeout(() => void restartEngine(context), 750);
        }
    });

    try {
        await engine.start(binary, {
            args: ['--stdio'],
            env: engineEnvironment()
        });
    } catch (error) {
        writeLine(`engine handshake failed: ${String(error)}`);
        setState('crashed');
        return;
    }

    setState('ready');
    registerProviders(context);
    await pushModelConfiguration();
}

function engineEnvironment(): NodeJS.ProcessEnv {
    const service = vscode.workspace.getConfiguration(SECTION);
    const ai = vscode.workspace.getConfiguration(AI_SECTION);

    return {
        GALAXY_ENDPOINT: service.get<string>('service.endpoint', ''),
        GALAXY_API_KEY_ENV: service.get<string>('service.apiKeyEnv', ''),
        GALAXY_TIMEOUT_MS: String(service.get<number>('service.timeoutMs', 4000)),
        GALAXY_MAX_RETRIES: String(service.get<number>('service.maxRetries', 2)),
        GALAXY_OLLAMA_ENDPOINT: ai.get<string>('ollamaEndpoint', 'http://127.0.0.1:11434'),
        GALAXY_AI_ENABLED: ai.get<boolean>('enabled', false) ? '1' : '0',
        GALAXY_AI_PROVIDER: ai.get<string>('provider', 'automatic'),
        GALAXY_AI_MODEL: ai.get<string>('model', ''),
        GALAXY_AI_MAX_TOKENS: String(ai.get<number>('maxTokens', 96)),
        GALAXY_AI_CHAT: ai.get<boolean>('chatMode', false) ? '1' : '0'
    };
}

async function pushModelConfiguration(): Promise<void> {
    const engine = client;

    if (engine === undefined || !engine.isRunning) {
        return;
    }

    const ai = vscode.workspace.getConfiguration(AI_SECTION);
    const payload: Record<string, unknown> = {
        ai: {
            enabled: ai.get<boolean>('enabled', false),
            provider: ai.get<string>('provider', 'automatic'),
            model: ai.get<string>('model', ''),
            maxTokens: ai.get<number>('maxTokens', 96),
            temperature: ai.get<number>('temperature', 0.2),
            stream: ai.get<boolean>('stream', true),
            chatMode: ai.get<boolean>('chatMode', false)
        }
    };

    try {
        const applied = await engine.request<Record<string, unknown>>('config', payload, 2000);
        writeLine(`model configuration applied: ${JSON.stringify(applied)}`);
    } catch (error) {
        writeLine(`model configuration failed: ${String(error)}`);
    }
}

async function restartEngine(context: vscode.ExtensionContext): Promise<void> {
    writeLine('restart requested');
    disposeProviders();

    const previous = client;
    client = undefined;
    previous?.stop();

    await startEngine(context);
}

function registerProviders(context: vscode.ExtensionContext): void {
    disposeProviders();

    const engine = client;

    if (engine === undefined) {
        return;
    }

    const languages = vscode.workspace.getConfiguration(SECTION).get<string[]>('completion.languages', []);
    const selector: vscode.DocumentSelector = languages.length > 0 ? languages : ['*'];

    const listProvider = new GalaxyCompletionProvider(engine);
    const inlineProvider = new GalaxyInlineCompletionProvider(engine);

    providerRegistrations = [
        vscode.languages.registerCompletionItemProvider(selector, listProvider, ...TRIGGER_CHARACTERS),
        vscode.languages.registerInlineCompletionItemProvider(selector, inlineProvider)
    ];

    for (const registration of providerRegistrations) {
        context.subscriptions.push(registration);
    }

    writeLine(`registered providers for ${languages.length > 0 ? languages.join(', ') : 'all languages'}`);
}

function disposeProviders(): void {
    for (const registration of providerRegistrations) {
        registration.dispose();
    }

    providerRegistrations = [];
}

export function resolveEngineBinary(extensionRoot: string): string | undefined {
    const configured = vscode.workspace.getConfiguration(SECTION).get<string>('engine.path', '').trim();
    const candidates: string[] = [];

    if (configured.length > 0) {
        candidates.push(configured);

        for (const name of BINARY_NAMES) {
            candidates.push(path.join(configured, name));
            candidates.push(path.join(configured, 'bin', name));
        }
    }

    const roots = [extensionRoot, path.join(extensionRoot, 'engine')];

    for (const root of roots) {
        for (const name of BINARY_NAMES) {
            candidates.push(path.join(root, 'bin', name));
            candidates.push(path.join(root, name));
        }
    }

    for (const name of BINARY_NAMES) {
        candidates.push(path.join(extensionRoot, 'out', 'engine', 'bin', name));
        candidates.push(path.join(extensionRoot, 'out', 'bin', name));
    }

    for (const candidate of candidates) {
        if (isFile(candidate)) {
            return candidate;
        }
    }

    writeLine(`no engine binary among ${candidates.length} candidate locations`);

    return undefined;
}

function isFile(candidate: string): boolean {
    try {
        return fs.statSync(candidate).isFile();
    } catch {
        return false;
    }
}

function enabled(key: string): boolean {
    return vscode.workspace.getConfiguration(SECTION).get<boolean>(key, true);
}

function setState(state: EngineState): void {
    activeState = state;

    if (!statusBar) {
        return;
    }

    const icon = STATE_ICONS[state] ?? '$(question)';

    statusBar.text = `${icon} Galaxy ${state}`;
    statusBar.tooltip = new vscode.MarkdownString(
        [
            `**Galaxy engine**`,
            ``,
            `- state: \`${state}\``,
            `- binary: \`${engineBinary ?? 'not resolved'}\``,
            `- pid: \`${client?.isRunning ? 'running' : 'stopped'}\``
        ].join('\n')
    );

    statusBar.backgroundColor =
        state === 'ready' || state === 'stopped' ? undefined : new vscode.ThemeColor('statusBarItem.warningBackground');

    statusBar.show();
}

function writeLine(message: string): void {
    channel?.appendLine(`${new Date().toISOString()} ${message}`);
}