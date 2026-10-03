# Galaxy

**Galaxy** is an open source AI code completion engine for Visual Studio Code. A native process written in **D** performs the heavy lifting — context assembly, ranking, prompt building and network I/O — while a thin **TypeScript** layer bridges it to the editor. The result is a local first answer in microseconds and a model powered ghost text that upgrades the suggestion when it arrives.

## Highlights

| Capability | Description |
| --- | --- |
| Local first, model second | Static analysis answers instantly; the model result upgrades the ghost text in place. |
| Hybrid completions | One ranked candidate list feeds both the suggestion widget and the grey ghost text. |
| Native engine | `GalaxyEngine` is a single native D executable started as a long lived child process. |
| Line delimited IPC | Newline delimited JSON over `stdin`/`stdout` keeps the protocol trivial, portable and debuggable. |
| Pluggable providers | Any OpenAI compatible endpoint or a local Ollama runtime, chosen by configuration. |
| Fill in the middle | Prefix, suffix and next lines are all transmitted, so FIM tuned models get proper context. |
| Guardrailed merging | Drift markers, duplicated lines, empty runs and prefix mismatch reject low quality output. |
| Offline capable | The whole local pipeline works with no network access at all. |
| Language aware | Profiles for D, TypeScript, JavaScript, Python, Rust, Go, C, C++, Java, JSON, HTML and CSS. |

## Architecture

```
┌──────────────────────────────────────────────────────────────┐
│  Visual Studio Code                                          │
│  ┌────────────────────┐        ┌──────────────────────────┐  │
│  │ extension.ts       │        │ completionProvider.ts    │  │
│  │ activate / lifecycle│──────▶│ client + providers      │  │
│  └────────────────────┘        └───────────┬──────────────┘  │
└─────────────────────────────────────────────┼────────────────┘
                    response · delta · final │ abort
┌─────────────────────────────────────────────▼────────────────┐
│  GalaxyEngine (native D executable)                          │
│  ┌──────────┐   ┌────────────┐   ┌───────────┐ ┌──────────┐  │
│  │ app.d    │──▶│ completer.d│◀─▶│ fetcher.d │ │ prompt   │  │
│  │ stdio IPC│   │ ranking    │   │ provider  │ │ + merge  │  │
│  │ event loop│  │ + merge    │   │ + stream  │ │          │  │
│  └──────────┘   └────────────┘   └─────┬─────┘ └──────────┘  │
└────────────────────────────────────────┼───────────────────────┘
                    OpenAI compatible /v1/completions
                    Ollama /api/generate (NDJSON)
```

### Responsibilities

* **`extension/src/extension.ts`** resolves the engine binary, starts it as a background process, registers both provider surfaces, owns the status bar entry and manages commands, configuration changes, shutdown and the `config` push that reconfigures the model at runtime.
* **`extension/src/completionProvider.ts`** implements the newline delimited JSON client with per request streams, the debounce layer, the `CompletionItemProvider` for the suggestion widget and the `InlineCompletionItemProvider` for ghost text.
* **`engine/source/app.d`** is the process entry point. It reads request envelopes from `stdin`, routes them, answers each request in two phases and writes `response`, `delta` and `final` envelopes back to `stdout`.
* **`engine/source/completer.d`** turns cursor position plus surrounding lines into scored candidates, builds the fill in the middle prompt and merges validated model output into the ranked list.
* **`engine/source/fetcher.d`** performs the HTTP call against the configured provider with timeout, retry, credential handling, prefix caching and stream parsing.

## Request lifecycle

```
client                                   engine                         provider
  |  completion (ai.enabled)                  |                              |
  |------------------------------------------>|                              |
  |  response  (local, immediate)             |                              |
  |<------------------------------------------|                              |
  |  delta   ...                             |                              |
  |<------------------------------------------|                              |
  |  final    (validated, merged)             |                              |
  |<------------------------------------------|                              |
```

1. The engine answers every keystroke from the local pipeline, so the suggestion widget and a first ghost text never wait for the network.
2. The model call runs on the engine loop and streams its output back as `delta` envelopes.
3. The validator sanitises the text, checks prefix continuity and merges the result as the highest scoring item, delivered in a `final` envelope.
4. `abort` cancels a queued generation. The extension never lets two generations overlap, so a stale answer is discarded rather than rendered.

The engine processes one generation at a time by design. That keeps the native process single threaded, deterministic and free of locks, and the extension coalesces requests so at most one model call is in flight.

## Project layout

```
.
├── package.json
├── tsconfig.json
├── .vscodeignore
├── .gitignore
├── README.md
├── .vscode
│   ├── launch.json
│   └── tasks.json
├── engine
│   ├── dub.json
│   └── source
│       ├── app.d
│       ├── completer.d
│       └── fetcher.d
└── extension
    └── src
        ├── extension.ts
        └── completionProvider.ts
```

## Prerequisites

* Visual Studio Code `1.84.0` or newer
* Node.js `18` or newer
* A D toolchain — either `dmd` or `ldc2` on `PATH`
* [DUB](https://dub.pm/) package manager
* `npm` for the extension client

## Building

```bash
npm install
npm run engine:build
npm run build
```

The engine build produces a single executable at `engine/bin/galaxy-engine` (`galaxy-engine.exe` on Windows) because `engine/dub.json` declares an executable target with a fixed `targetPath`.

| Script | Purpose |
| --- | --- |
| `npm run engine:build` | Release build with `dmd`. |
| `npm run engine:build:lcd` | Release build with `ldc2`. |
| `npm run engine:build:debug` | Debug build with runtime bounds checks. |
| `npm run engine:run` | Start the engine directly and talk to it over `stdin`. |
| `npm run build` | Compile the extension into `out/`. |
| `npm run watch` | Incremental TypeScript compilation. |
| `npm run typecheck` | Type check without emitting files. |
| `npm run compile` | Engine and extension in one command. |
| `npm run package` | Produce a `.vsix` with `vsce`. |
| `npm run package:full` | Build the engine first, then produce a `.vsix` that includes it. |

## Running

Press `F5` in VS Code to launch an Extension Development Host, or install a packaged build.

1. Open a source file in a supported language.
2. Type an identifier prefix and observe the ranked list and the grey inline suggestion.
3. Press `Tab` to accept the inline suggestion or `Enter` to accept the highlighted list item.
4. Use `Galaxy: Restart Engine` if the engine process is replaced after a rebuild.

The status bar entry shows the engine lifecycle. Hover it to see the binary path and the last transport error.

## Protocol

Every line on `stdin` and `stdout` is one JSON object.

### Initialization

```json
{ "id": "1", "type": "initialize", "payload": { "client": "vscode", "clientVersion": "0.1.0" } }
```

```json
{ "id": "1", "type": "response", "status": "ok", "protocol": "1.0.0", "payload": { "languages": ["d", "typescript"], "engineVersion": "0.1.0", "provider": "ollama", "aiEnabled": true } }
```

### Completion

```json
{ "id": "2", "type": "completion", "payload": { "filePath": "/w/app.d", "languageId": "d", "line": 12, "character": 8, "prefix": "wri", "suffix": "", "currentLine": "        wr", "previousLines": ["import std.stdio;"], "nextLines": ["}"], "ai": { "enabled": true, "provider": "auto", "model": "qwen2.5-coder:1.5b", "stream": true, "promptStyle": "fim" } } }
```

```json
{ "id": "2", "type": "response", "status": "ok", "protocol": "1.0.0", "payload": { "source": "local", "trigger": "identifier", "isIncomplete": false, "inlineText": "writeln", "aiQueued": true, "generation": 1, "items": [ { "label": "writeln", "text": "writeln", "kind": "function", "detail": "void writeln(T)(T value)", "score": 920, "inline": true } ] } }
```

### Model answer

```json
{ "id": "2", "type": "delta", "status": "ok", "protocol": "1.0.0", "payload": { "source": "ai", "text": "iteln(\"galaxy\");\n", "done": false } }
```

```json
{ "id": "2", "type": "final", "status": "ok", "protocol": "1.0.0", "payload": { "source": "ai", "provider": "ollama", "model": "qwen2.5-coder:1.5b", "inlineText": "iteln(\"galaxy\");", "available": true, "rejected": false, "rejectReason": "", "acceptedLines": 1, "overlap": 2, "finishReason": "stop", "elapsedMs": 118, "done": true, "items": [] } }
```

### Supported request types

| Type | Direction | Purpose |
| --- | --- | --- |
| `initialize` | client to engine | Handshake, capability and version exchange. |
| `completion` | client to engine | Context aware candidate generation, optionally followed by a model call. |
| `config` | client to engine | Reconfigure endpoint, credentials, timeouts and the model at runtime. |
| `abort` | client to engine | Cancel a queued generation by target id. |
| `health` | client to engine | Liveness probe and statistics. |
| `shutdown` | client to engine | Graceful termination. |

### Answer types

| Type | Meaning |
| --- | --- |
| `response` | Primary answer for the request id. Resolves the pending promise. |
| `delta` | Incremental model text for a request id. Updates the ghost text in place. |
| `final` | Terminal model answer with the validated text and the merged candidate list. |

Malformed envelopes never terminate the loop. The engine answers with `status` set to `error` and continues reading, so one bad keystroke cannot kill the session.

## Packaging

```bash
npm run package:full
code --install-extension galaxy-extension-0.1.0.vsix
```

The VSIX ships the manifest, the compiled extension under `out/`, the licence and the readme. Sources, `tsconfig.json` and the engine sources are excluded by `.vscodeignore`; the compiled binary at `engine/bin/galaxy-engine.exe` (or `engine/bin/galaxy-engine`) is included automatically when it exists, which is what makes `package:full` the release command.

If the binary is missing the extension still installs and starts: the status bar reports `missing`, the output channel explains it, and the suggestion widget falls back to pure local ranking until `galaxy.engine.path` points at a binary or the engine is built.

## Model setup

Galaxy ships with two provider adapters and picks one automatically.

### Local, no credentials

```bash
ollama serve
ollama pull qwen2.5-coder:1.5b
```

```json
{
  "galaxy.ai.enabled": true,
  "galaxy.ai.provider": "ollama",
  "galaxy.ai.model": "qwen2.5-coder:1.5b"
}
```

### Cloud, your own key

```bash
export GALAXY_API_KEY=sk-...
```

```json
{
  "galaxy.ai.enabled": true,
  "galaxy.ai.provider": "openai",
  "galaxy.ai.model": "qwen2.5-coder-7b-instruct",
  "galaxy.ai.chatMode": true
}
```

`galaxy.ai.provider` set to `auto` uses the cloud route when `GALAXY_API_KEY` is present and the local route otherwise.

### Prompt styles

* `fim` wraps the code with `<|fim_prefix|>`, `<|fim_suffix|>` and `<|fim_middle|>` and posts to `/v1/completions` with the `suffix` field. Use this for FIM tuned models.
* `instruct` builds a fenced instruction block. Pair it with `galaxy.ai.chatMode` for chat only endpoints such as `/chat/completions`.

### Output validation

Generated text is rejected when it drifts into prose, opens a code fence, repeats a line, opens more than one blank line in a row, adds a second statement that contradicts the suffix, or does not continue the typed prefix. Everything that survives becomes the highest scoring candidate.

## Configuration

All settings live under the `galaxy` namespace.

| Setting | Default | Meaning |
| --- | --- | --- |
| `galaxy.engine.path` | `""` | Explicit binary location. Empty means automatic probing. |
| `galaxy.engine.enabled` | `true` | Master switch for the background process. |
| `galaxy.engine.autoRestart` | `true` | Restart after an unexpected exit. |
| `galaxy.engine.requestTimeoutMs` | `2500` | Cancellation window per request. |
| `galaxy.engine.requestDebounceMs` | `60` | Keystroke debounce. |
| `galaxy.engine.modelTimeoutMs` | `4000` | How long the inline provider waits for a model answer when the local engine produced nothing. |
| `galaxy.completion.list.enabled` | `true` | Suggestion widget surface. |
| `galaxy.completion.inline.enabled` | `true` | Grey ghost text surface. |
| `galaxy.completion.inline.mode` | `hybrid` | `hybrid`, `inline` or `list`. |
| `galaxy.completion.inline.minPrefixLength` | `1` | Typed characters required before a ghost text appears. |
| `galaxy.completion.inline.maxItems` | `5` | Candidates returned per request. |
| `galaxy.completion.suppressInComments` | `true` | Skip comment and string positions. |
| `galaxy.completion.languages` | see manifest | Language identifiers to register for. |
| `galaxy.service.endpoint` | `https://api.galaxy.dev/v1` | Remote service base URL. |
| `galaxy.service.apiKeyEnv` | `GALAXY_API_KEY` | Environment variable holding the credential. |
| `galaxy.service.timeoutMs` | `4000` | Engine side HTTP timeout. |
| `galaxy.service.maxRetries` | `2` | Retry budget per HTTP call. |
| `galaxy.ai.enabled` | `false` | Master switch for model powered ghost text. |
| `galaxy.ai.provider` | `auto` | `auto`, `openai`, `ollama` or `none`. |
| `galaxy.ai.model` | `""` | Model identifier. Empty keeps AI disabled. |
| `galaxy.ai.ollamaEndpoint` | `http://127.0.0.1:11434` | Local runtime URL. |
| `galaxy.ai.maxTokens` | `96` | Upper bound for generated tokens. |
| `galaxy.ai.temperature` | `0.2` | Sampling temperature. |
| `galaxy.ai.stream` | `true` | Request incremental deltas. |
| `galaxy.ai.chatMode` | `false` | Use `/chat/completions` instead of `/v1/completions`. |
| `galaxy.ai.promptStyle` | `fim` | `fim` or `instruct`. |
| `galaxy.ai.prefixLines` | `60` | Context lines before the cursor. |
| `galaxy.ai.suffixLines` | `24` | Context lines after the cursor. |
| `galaxy.logging.level` | `info` | Verbosity of the output channel. |

Model settings are pushed to the engine with a `config` request the moment you change them, so no reload is required.

## Known limitations

* The engine is single threaded by design. A model call occupies the loop for its duration, so the extension keeps at most one generation in flight and coalesces the rest. `abort` cancels queued work, not an in flight HTTP request.
* Stream parsing handles both OpenAI style server sent events and Ollama newline delimited JSON, and also tolerates non streamed responses. Chunk level delivery depends on the provider flushing each token.
* The suggestion widget is intentionally local only. Model output is routed to the ghost text surface, which keeps list rendering instant while typing.

## Development workflow

* Build the engine first. The extension probes `bin/`, `engine/bin/` and `out/engine/bin/` relative to the installation folder and logs every rejected candidate to the `Galaxy Engine` output channel.
* Use `npm run engine:build:debug` while iterating on `completer.d` to get assertions and bounds checks, then switch back to the release build.
* Send a completion envelope by hand with `npm run engine:run` to isolate engine behaviour from editor behaviour.
* The engine prints one JSON line per envelope, so `engine/bin/galaxy-engine < requests.jsonl` replays a recorded session.
* Read the output channel with `Galaxy: Show Engine Logs` when a provider silently stops answering. `health` reports provider, model, served and model counters.

## Contributing

1. Fork the repository and create a topic branch.
2. Keep the protocol backward compatible; add fields, never repurpose existing ones.
3. Run `npm run typecheck` and `npm run engine:build` before opening a pull request.
4. Describe observable behaviour in the pull request body.

## License

MIT. See the repository for the full text.