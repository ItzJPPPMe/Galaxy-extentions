import std.algorithm : canFind;
import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.json : JSONType, JSONValue, parseJSON, toJSON;
import std.process : environment, thisProcessID;
import std.stdio : stdin, stdout;
import std.string : join, strip, stripRight, toLower;

import completer : Completer, CompletionItem, CompletionRequest, CompletionResponse, MergeOptions, MergeResult, PromptOptions, PromptStyle, ProtocolVersion, buildModelPrompt, mergeSuggestions;
import fetcher : AbortToken, DeltaSink, Fetcher, FetcherConfig, GenerationOptions, GenerationResult, ProviderKind;

enum EngineVersion = "0.1.0";
enum DefaultMaxItems = 24;
enum DefaultTimeoutMs = 4000;
enum DefaultRetries = 2;
enum MaxTrackedJobs = 64;

enum SessionState
{
    starting,
    ready,
    degraded,
    stopping,
    stopped
}

private struct Job
{
    string id;
    bool queued;
    bool abort;
    AbortToken token;
}

private struct SessionContext
{
    CompletionRequest request;
    CompletionItem[] seed;
    GenerationOptions options;
    MergeOptions merge;
}

final class EngineShutdown : Exception
{
    this(string reason)
    {
        super(reason);
    }
}

struct Session
{
    Completer completer;
    Fetcher fetcher;
    StopWatch boot;
    SessionState state = SessionState.starting;
    Job[string] jobs;
    SessionContext[string] contexts;
    ulong served;
    ulong rejected;
    ulong broken;
    ulong models;
    ulong sequence;

    long uptimeMs() const
    {
        return boot.peek().total!"msecs";
    }
}

private Session buildSession()
{
    FetcherConfig config;
    config.endpoint = environment.get("GALAXY_ENDPOINT", "https://api.galaxy.dev/v1");
    config.apiKeyEnv = environment.get("GALAXY_API_KEY_ENV", "GALAXY_API_KEY");
    config.timeoutMs = environment.get("GALAXY_TIMEOUT_MS", DefaultTimeoutMs.to!string).to!uint;
    config.maxRetries = environment.get("GALAXY_MAX_RETRIES", DefaultRetries.to!string).to!uint;
    config.verbose = environment.get("GALAXY_VERBOSE", "0") != "0";
    config.ollamaEndpoint = environment.get("GALAXY_OLLAMA_ENDPOINT", "http://127.0.0.1:11434");
    config.aiEnabled = environment.get("GALAXY_AI_ENABLED", "1") != "0";
    config.chatMode = environment.get("GALAXY_AI_CHAT", "0") != "0";
    config.model = environment.get("GALAXY_AI_MODEL", "");
    config.maxTokens = environment.get("GALAXY_AI_MAX_TOKENS", "96").to!uint;
    config.provider = providerFrom(environment.get("GALAXY_AI_PROVIDER", "auto"), ProviderKind.automatic);

    Session session;
    session.completer = new Completer(DefaultMaxItems);
    session.fetcher = new Fetcher(config);
    session.state = SessionState.starting;
    session.boot.start();
    return session;
}

private void handleInitialize(ref Session session, string id, JSONValue payload)
{
    session.state = SessionState.ready;

    JSONValue[string] body;
    body["engineVersion"] = JSONValue(EngineVersion);
    body["protocol"] = JSONValue(ProtocolVersion);
    body["client"] = JSONValue(stringField(payload, "client"));
    body["clientVersion"] = JSONValue(stringField(payload, "clientVersion"));
    body["languages"] = JSONValue(languageList());
    body["credentials"] = JSONValue(session.fetcher.hasCredential());
    body["credentialName"] = JSONValue(session.fetcher.credentialName());
    body["endpoint"] = JSONValue(session.fetcher.settings().endpoint);
    body["state"] = JSONValue("ready");
    body["served"] = JSONValue(cast(long) session.served);

    emitEnvelope(id, "response", true, JSONValue(body));
}

private void handleCompletion(ref Session session, string id, JSONValue payload)
{
    CompletionRequest request = readRequest(payload);
    CompletionResponse response = session.completer.complete(request);
    session.served++;

    bool queued = shouldRunModel(session, payload, request);
    session.sequence++;

    Job job;
    job.id = id;
    job.queued = queued;
    job.token = new AbortToken;
    session.jobs[id] = job;

    if (queued)
        captureContext(session, id, request, response.items, payload);

    if (session.jobs.length > MaxTrackedJobs)
        pruneJobs(session);

    JSONValue[string] body;
    body["source"] = JSONValue("local");
    body["trigger"] = JSONValue(response.trigger);
    body["inlineText"] = JSONValue(response.inlineText);
    body["isIncomplete"] = JSONValue(response.isIncomplete);
    body["items"] = JSONValue(encodeItems(response.items));
    body["aiEnabled"] = JSONValue(session.fetcher.isAiEnabled());
    body["aiQueued"] = JSONValue(queued);
    body["provider"] = JSONValue(session.fetcher.activeProvider().to!string);
    body["model"] = JSONValue(session.fetcher.modelName());
    body["generation"] = JSONValue(cast(long) session.sequence);

    emitEnvelope(id, "response", true, JSONValue(body));
}

private void drainModels(ref Session session)
{
    pruneJobs(session);

    Job[string] pending = session.jobs;
    session.jobs = null;

    foreach (target, job; pending)
    {
        if (job.abort)
        {
            job.token.cancel();
            emitCancelled(target);
            continue;
        }

        if (!job.queued)
            continue;

        session.models++;
        emitFinal(session, target, job);
    }
}

private void emitCancelled(string target)
{
    JSONValue[string] body;
    body["source"] = JSONValue("ai");
    body["available"] = JSONValue(false);
    body["aborted"] = JSONValue(true);
    body["rejected"] = JSONValue(true);
    body["rejectReason"] = JSONValue("superseded by a newer request");
    body["inlineText"] = JSONValue("");
    body["items"] = JSONValue(JSONValue[].init);
    body["done"] = JSONValue(true);

    emitEnvelope(target, "final", true, JSONValue(body));
}

private void emitFinal(ref Session session, string id, Job job)
{
    session.jobs[id] = job;

    CompletionRequest request;
    GenerationOptions options;
    CompletionItem[] seed;
    MergeOptions merge;

    if (!storeContext(session, id, request, options, seed, merge))
    {
        JSONValue[string] body;
        body["source"] = JSONValue("local");
        body["inlineText"] = JSONValue("");
        body["items"] = JSONValue(JSONValue[].init);
        body["available"] = JSONValue(false);
        body["error"] = JSONValue("request context expired");
        body["done"] = JSONValue(true);

        emitEnvelope(id, "final", true, JSONValue(body));
        return;
    }

    DeltaSink sink = (chunk, done) {
        emitDelta(id, chunk, done);
    };

    GenerationResult generation = session.fetcher.generate(options, sink, job.token);
    job.token.complete();

    MergeResult merged = mergeSuggestions(seed, generation.text, merge);

    JSONValue[string] body;
    body["source"] = JSONValue(merged.source);
    body["provider"] = JSONValue(generation.provider);
    body["model"] = JSONValue(generation.model);
    body["inlineText"] = JSONValue(merged.inlineText);
    body["isIncomplete"] = JSONValue(true);
    body["items"] = JSONValue(encodeItems(merged.items));
    body["available"] = JSONValue(generation.available);
    body["cached"] = JSONValue(generation.cached);
    body["aborted"] = JSONValue(generation.aborted);
    body["rejected"] = JSONValue(merged.rejected);
    body["rejectReason"] = JSONValue(merged.rejectReason);
    body["acceptedLines"] = JSONValue(cast(long) merged.acceptedLines);
    body["overlap"] = JSONValue(cast(long) merged.overlap);
    body["finishReason"] = JSONValue(generation.finishReason);
    body["elapsedMs"] = JSONValue(generation.elapsedMs);
    body["error"] = JSONValue(generation.error);
    body["done"] = JSONValue(true);

    emitEnvelope(id, "final", true, JSONValue(body));
}

private bool storeContext(ref Session session, string id, out CompletionRequest request, out GenerationOptions options, out CompletionItem[] seed, out MergeOptions merge)
{
    request = CompletionRequest.init;
    options = GenerationOptions.init;
    seed = null;
    merge = MergeOptions.init;

    string key = id.idup;
    SessionContext* stored = key in session.contexts;

    if (stored is null)
        return false;

    request = stored.request;
    options = stored.options;
    seed = stored.seed;
    merge = stored.merge;

    session.contexts.remove(key);

    return true;
}

private void captureContext(ref Session session, string id, CompletionRequest request, CompletionItem[] seed, JSONValue payload)
{
    SessionContext stored;
    stored.request = request;
    stored.seed = seed.dup;
    stored.options = modelOptions(session, payload, request);
    stored.merge.prefix = request.prefix;
    stored.merge.suffix = request.suffix;
    stored.merge.insideString = request.insideString;
    stored.merge.insideComment = request.insideComment;
    stored.merge.acceptMultiLine = !request.insideString;

    session.contexts[id.idup] = stored;

    while (session.contexts.length > MaxTrackedJobs)
    {
        string[] known = session.contexts.keys;
        session.contexts.remove(known[0]);
    }
}

private void handleAbort(ref Session session, string id, JSONValue payload)
{
    string target = stringField(payload, "target");

    if (target.length == 0)
        target = id;

    Job* job = target in session.jobs;

    if (job is null)
        return;

    job.abort = true;
    job.token.cancel();
    session.contexts.remove(target);

    JSONValue[string] body;
    body["target"] = JSONValue(target);
    body["cancelled"] = JSONValue(true);
    body["aborted"] = JSONValue(true);
    body["available"] = JSONValue(false);
    body["inlineText"] = JSONValue("");
    body["items"] = JSONValue(JSONValue[].init);
    body["done"] = JSONValue(true);

    emitEnvelope(target, "final", true, JSONValue(body));
}

private static void pruneJobs(ref Session session)
{
    string[] expired;

    foreach (id, job; session.jobs)
    {
        if (job.token.completed || job.token.cancelled)
            expired ~= id;
    }

    foreach (id; expired)
    {
        session.jobs.remove(id);
        session.contexts.remove(id);
    }
}

private CompletionRequest readRequest(JSONValue payload)
{
    CompletionRequest request;
    request.filePath = stringField(payload, "filePath");
    request.languageId = stringField(payload, "languageId");
    request.line = cast(int) longField(payload, "line", 0);
    request.character = cast(int) longField(payload, "character", 0);
    request.prefix = stringField(payload, "prefix");
    request.suffix = stringField(payload, "suffix");
    request.currentLine = stringField(payload, "currentLine");
    request.previousLines = stringArrayField(payload, "previousLines");
    request.nextLines = stringArrayField(payload, "nextLines");
    request.insideComment = boolField(payload, "insideComment", detectComment(request));
    request.insideString = boolField(payload, "insideString", detectString(request));

    return request;
}

private static bool shouldRunModel(Session session, JSONValue payload, CompletionRequest request)
{
    if (!session.fetcher.isAiEnabled())
        return false;

    JSONValue options = objectField(payload, "ai");

    if (options.type == JSONType.object && !boolField(options, "enabled", true))
        return false;

    if (request.insideComment)
        return false;

    bool empty = request.currentLine.strip.length == 0
        && request.previousLines.length == 0
        && request.nextLines.length == 0;

    return !empty;
}

private GenerationOptions modelOptions(Session session, JSONValue payload, CompletionRequest request)
{
    JSONValue options = objectField(payload, "ai");
    FetcherConfig settings = session.fetcher.settings();

    GenerationOptions generation;
    generation.prompt = buildModelPrompt(request, promptOptions(options));
    generation.suffix = suffixText(request);
    generation.provider = providerFrom(stringField(options, "provider"), settings.provider);
    generation.model = stringField(options, "model");
    generation.maxTokens = cast(uint) longField(options, "maxTokens", cast(long) settings.maxTokens);
    generation.temperature = cast(float) doubleField(options, "temperature", cast(double) settings.temperature);
    generation.stream = boolField(options, "stream", settings.stream);
    generation.chatMode = boolField(options, "chatMode", settings.chatMode);

    return generation;
}

private static PromptOptions promptOptions(JSONValue options)
{
    PromptOptions prompt;

    if (stringField(options, "promptStyle").toLower == "instruct")
        prompt.style = PromptStyle.instruct;

    prompt.prefixLines = cast(size_t) longField(options, "prefixLines", cast(long) prompt.prefixLines);
    prompt.suffixLines = cast(size_t) longField(options, "suffixLines", cast(long) prompt.suffixLines);
    prompt.maxChars = cast(size_t) longField(options, "maxChars", cast(long) prompt.maxChars);

    return prompt;
}

private static string suffixText(CompletionRequest request)
{
    string[] lines = request.nextLines.dup;
    string tail = request.suffix.stripRight;

    if (tail.length > 0)
        lines ~= tail;

    return lines.join("\n");
}

private static ProviderKind providerFrom(string value, ProviderKind fallback)
{
    switch (value.toLower)
    {
        case "":
            return fallback;
        case "auto":
            return ProviderKind.automatic;
        case "openai":
        case "openai-compatible":
        case "cloud":
            return ProviderKind.openai;
        case "ollama":
        case "local":
            return ProviderKind.ollama;
        case "none":
        case "off":
            return ProviderKind.none;
        default:
            return fallback;
    }
}

private void handleHealth(ref Session session, string id)
{
    JSONValue[string] body;
    body["state"] = JSONValue(stateName(session.state));
    body["engineVersion"] = JSONValue(EngineVersion);
    body["protocol"] = JSONValue(ProtocolVersion);
    body["uptimeMs"] = JSONValue(session.uptimeMs());
    body["served"] = JSONValue(cast(long) session.served);
    body["models"] = JSONValue(cast(long) session.models);
    body["activeJobs"] = JSONValue(cast(long) session.jobs.length);
    body["rejected"] = JSONValue(cast(long) session.rejected);
    body["broken"] = JSONValue(cast(long) session.broken);
    body["requests"] = JSONValue(cast(long) session.fetcher.requestCount());
    body["averageHttpMs"] = JSONValue(session.fetcher.averageElapsedMs());
    body["credentials"] = JSONValue(session.fetcher.hasCredential());
    body["aiEnabled"] = JSONValue(session.fetcher.isAiEnabled());
    body["provider"] = JSONValue(session.fetcher.activeProvider().to!string);
    body["model"] = JSONValue(session.fetcher.modelName());

    emitEnvelope(id, "response", true, JSONValue(body));
}

private void handleConfig(ref Session session, string id, JSONValue payload)
{
    FetcherConfig settings = session.fetcher.settings();
    bool changed;

    string endpoint = stringField(payload, "endpoint");
    if (endpoint.length > 0)
    {
        settings.endpoint = endpoint;
        changed = true;
    }

    string ollama = stringField(payload, "ollamaEndpoint");
    if (ollama.length > 0)
    {
        settings.ollamaEndpoint = ollama;
        changed = true;
    }

    uint retries = cast(uint) longField(payload, "maxRetries", cast(long) settings.maxRetries);
    if (retries <= 5 && retries != settings.maxRetries)
    {
        settings.maxRetries = retries;
        changed = true;
    }

    long timeout = longField(payload, "timeoutMs", cast(long) settings.timeoutMs);
    if (timeout >= 200 && timeout != cast(long) settings.timeoutMs)
    {
        settings.timeoutMs = cast(uint) timeout;
        changed = true;
    }

    JSONValue ai = objectField(payload, "ai");

    if (ai.type == JSONType.object)
    {
        bool aiEnabled = boolField(ai, "enabled", settings.aiEnabled);
        string model = stringField(ai, "model");
        ProviderKind provider = providerFrom(stringField(ai, "provider"), settings.provider);
        uint maxTokens = cast(uint) longField(ai, "maxTokens", cast(long) settings.maxTokens);
        float temperature = cast(float) doubleField(ai, "temperature", cast(double) settings.temperature);
        bool stream = boolField(ai, "stream", settings.stream);
        bool chatMode = boolField(ai, "chatMode", settings.chatMode);

        if (aiEnabled != settings.aiEnabled
            || model != settings.model
            || provider != settings.provider
            || maxTokens != settings.maxTokens
            || temperature != settings.temperature
            || stream != settings.stream
            || chatMode != settings.chatMode)
        {
            settings.aiEnabled = aiEnabled;
            settings.model = model;
            settings.provider = provider;
            settings.maxTokens = maxTokens;
            settings.temperature = temperature;
            settings.stream = stream;
            settings.chatMode = chatMode;
            changed = true;
        }
    }

    if (changed)
        session.fetcher.reconfigure(settings);

    if (boolField(payload, "clearCache", false))
        session.fetcher.clearCache();

    JSONValue[string] body;
    body["endpoint"] = JSONValue(settings.endpoint);
    body["ollamaEndpoint"] = JSONValue(settings.ollamaEndpoint);
    body["maxRetries"] = JSONValue(cast(long) settings.maxRetries);
    body["timeoutMs"] = JSONValue(cast(long) settings.timeoutMs);
    body["aiEnabled"] = JSONValue(session.fetcher.isAiEnabled());
    body["provider"] = JSONValue(session.fetcher.activeProvider().to!string);
    body["model"] = JSONValue(settings.model);
    body["applied"] = JSONValue(changed);

    emitEnvelope(id, "response", true, JSONValue(body));
}

private void dispatch(ref Session session, string id, string type, JSONValue payload)
{
    switch (type)
    {
        case "initialize":
            handleInitialize(session, id, payload);
            break;

        case "completion":
            handleCompletion(session, id, payload);
            break;

        case "health":
            handleHealth(session, id);
            break;

        case "config":
            handleConfig(session, id, payload);
            break;

        case "abort":
            handleAbort(session, id, payload);
            break;

        case "shutdown":
            session.state = SessionState.stopping;

            foreach (key, job; session.jobs)
                job.token.cancel();

            JSONValue[string] body;
            body["state"] = JSONValue("stopped");
            body["served"] = JSONValue(cast(long) session.served);

            emitEnvelope(id, "response", true, JSONValue(body));
            throw new EngineShutdown("client requested shutdown");

        case "":
            session.rejected++;
            emit(errorEnvelope(id, "missing_type", "request envelope has no type field"));
            break;

        default:
            session.rejected++;
            emit(errorEnvelope(id, "unknown_type", "unsupported request type: " ~ type));
            break;
    }
}

private JSONValue[] encodeItems(CompletionItem[] items)
{
    JSONValue[] encoded;

    foreach (item; items)
    {
        JSONValue[string] entry;
        entry["label"] = JSONValue(item.label);
        entry["text"] = JSONValue(item.text);
        entry["detail"] = JSONValue(item.detail);
        entry["kind"] = JSONValue(item.kind);
        entry["documentation"] = JSONValue(item.documentation);
        entry["score"] = JSONValue(cast(long) item.score);
        entry["inline"] = JSONValue(item.inline);

        encoded ~= JSONValue(entry);
    }

    return encoded;
}

private JSONValue envelope(string id, string type, bool success, JSONValue payload)
{
    JSONValue[string] root;
    root["id"] = JSONValue(id);
    root["type"] = JSONValue(type);
    root["status"] = JSONValue(success ? "ok" : "error");
    root["protocol"] = JSONValue(ProtocolVersion);
    root["payload"] = payload;

    return JSONValue(root);
}

private void emit(JSONValue value)
{
    stdout.writeln(toJSON(value));
    stdout.flush();
}

private void emitEnvelope(string id, string type, bool success, JSONValue payload)
{
    emit(envelope(id, type, success, payload));
}

private void emitDelta(string id, string chunk, bool done)
{
    JSONValue[string] body;
    body["source"] = JSONValue("ai");
    body["text"] = JSONValue(chunk);
    body["done"] = JSONValue(done);

    emitEnvelope(id, "delta", true, JSONValue(body));
}

private JSONValue errorEnvelope(string id, string code, string message)
{
    JSONValue[string] body;
    body["code"] = JSONValue(code);
    body["message"] = JSONValue(message);

    return envelope(id, "response", false, JSONValue(body));
}

private JSONValue[] languageList()
{
    JSONValue[] languages;

    static immutable string[] supported = [
        "c", "cpp", "css", "d", "go", "html", "java", "javascript",
        "javascriptreact", "json", "jsonc", "python", "rust",
        "typescript", "typescriptreact"
    ];

    foreach (language; supported)
        languages ~= JSONValue(language);

    return languages;
}

private string stringField(JSONValue source, string key)
{
    if (source.type != JSONType.object)
        return "";

    JSONValue[string] storage = source.object;
    auto slot = key in storage;

    if (slot is null)
        return "";

    JSONValue value = *slot;
    return value.type == JSONType.string ? value.str : "";
}

private JSONValue objectField(JSONValue source, string key)
{
    if (source.type != JSONType.object)
        return JSONValue.init;

    JSONValue[string] storage = source.object;
    auto slot = key in storage;

    if (slot is null)
        return JSONValue.init;

    return *slot;
}

private long longField(JSONValue source, string key, long fallback)
{
    if (source.type != JSONType.object)
        return fallback;

    JSONValue[string] storage = source.object;
    auto slot = key in storage;

    if (slot is null)
        return fallback;

    JSONValue value = *slot;

    switch (value.type)
    {
        case JSONType.integer:
            return value.integer;

        case JSONType.uinteger:
            return cast(long) value.uinteger;

        case JSONType.float_:
            return cast(long) value.floating;

        case JSONType.string:
            try
            {
                return value.str.strip.to!long;
            }
            catch (Exception conversionFailure)
            {
                return fallback;
            }

        case JSONType.true_:
            return 1;

        case JSONType.false_:
            return 0;

        default:
            return fallback;
    }
}

private double doubleField(JSONValue source, string key, double fallback)
{
    if (source.type != JSONType.object)
        return fallback;

    JSONValue[string] storage = source.object;
    auto slot = key in storage;

    if (slot is null)
        return fallback;

    JSONValue value = *slot;

    switch (value.type)
    {
        case JSONType.float_:
            return value.floating;

        case JSONType.integer:
            return cast(double) value.integer;

        case JSONType.uinteger:
            return cast(double) value.uinteger;

        case JSONType.string:
            try
            {
                return value.str.strip.to!double;
            }
            catch (Exception conversionFailure)
            {
                return fallback;
            }

        default:
            return fallback;
    }
}

private bool boolField(JSONValue source, string key, bool fallback)
{
    if (source.type != JSONType.object)
        return fallback;

    JSONValue[string] storage = source.object;
    auto slot = key in storage;

    if (slot is null)
        return fallback;

    JSONValue value = *slot;

    if (value.type == JSONType.true_)
        return true;

    if (value.type == JSONType.false_)
        return false;

    return fallback;
}

private string[] stringArrayField(JSONValue source, string key)
{
    if (source.type != JSONType.object)
        return null;

    JSONValue[string] storage = source.object;
    auto slot = key in storage;

    if (slot is null || slot.type != JSONType.array)
        return null;

    JSONValue[] values = slot.array;
    string[] result;

    foreach (entry; values)
    {
        if (entry.type == JSONType.string)
            result ~= entry.str;
    }

    return result;
}

private static bool detectComment(CompletionRequest request)
{
    string head = headOf(request);

    if (head.length == 0)
        return false;

    if (request.languageId == "html" || request.languageId == "xml")
        return false;

    if (head.canFind("//"))
        return true;

    size_t blockStart = head.canFind("/*");
    size_t blockEnd = head.canFind("*/");

    return blockStart && blockEnd <= blockStart;
}

private static bool detectString(CompletionRequest request)
{
    string head = headOf(request);

    size_t single = 0;
    size_t doubleQuotes = 0;

    foreach (character; head)
    {
        if (character == '\'')
            single++;

        if (character == '"')
            doubleQuotes++;
    }

    return single % 2 == 1 || doubleQuotes % 2 == 1;
}

private static string headOf(CompletionRequest request)
{
    if (request.character <= 0 || request.character >= request.currentLine.length)
        return request.currentLine;

    return request.currentLine[0 .. request.character];
}

private static string stateName(SessionState state)
{
    final switch (state)
    {
        case SessionState.starting:
            return "starting";

        case SessionState.ready:
            return "ready";

        case SessionState.degraded:
            return "degraded";

        case SessionState.stopping:
            return "stopping";

        case SessionState.stopped:
            return "stopped";
    }
}

private void serve()
{
    Session session = buildSession();
    session.state = SessionState.ready;

    JSONValue[string] banner;
    banner["engineVersion"] = JSONValue(EngineVersion);
    banner["protocol"] = JSONValue(ProtocolVersion);
    banner["pid"] = JSONValue(cast(long) thisProcessID);
    banner["state"] = JSONValue(stateName(session.state));
    banner["credentials"] = JSONValue(session.fetcher.hasCredential());

emitEnvelope("boot", "response", true, JSONValue(banner));

    while (session.state != SessionState.stopped)
    {
        processInput(session);

        if (session.state == SessionState.ready || session.state == SessionState.degraded)
            drainModels(session);
    }

    session.state = SessionState.stopped;

    JSONValue[string] body;
    body["state"] = JSONValue("stopped");
    body["served"] = JSONValue(cast(long) session.served);
    body["models"] = JSONValue(cast(long) session.models);
    body["rejected"] = JSONValue(cast(long) session.rejected);
    body["broken"] = JSONValue(cast(long) session.broken);
    body["uptimeMs"] = JSONValue(session.uptimeMs());

    emitEnvelope("exit", "response", true, JSONValue(body));
}

private void processInput(ref Session session)
{
    string line = stdin.readln();

    if (line is null)
    {
        session.state = SessionState.stopped;
        return;
    }

    dispatchLine(session, line);
    drainModels(session);
}

private void dispatchLine(ref Session session, string line)
{
    if (line.length == 0)
        return;

    try
    {
        JSONValue request = parseJSON(line);

        string id = stringField(request, "id");
        string type = stringField(request, "type");
        JSONValue payload = payloadOf(request);

        dispatch(session, id, type, payload);
    }
    catch (EngineShutdown stopSignal)
    {
        session.state = SessionState.stopped;
    }
    catch (Exception failure)
    {
        session.broken++;
        emit(errorEnvelope("unknown", "parse_failure", failure.msg));
    }
}

private JSONValue payloadOf(JSONValue request)
{
    if (request.type != JSONType.object)
        return JSONValue.init;

    JSONValue[string] storage = request.object;
    auto slot = "payload" in storage;

    if (slot is null)
        return JSONValue.init;

    return *slot;
}

private int run(string[] arguments)
{
    foreach (argument; arguments[1 .. $])
    {
        if (argument == "--version")
        {
            stdout.writeln(EngineVersion);
            return 0;
        }

        if (argument == "--help")
        {
            stdout.writeln("galaxy-engine " ~ EngineVersion);
            stdout.writeln("protocol " ~ ProtocolVersion);
            stdout.writeln("reads newline delimited JSON requests from stdin and answers on stdout");
            return 0;
        }
    }

    serve();
    return 0;
}

int main(string[] arguments)
{
    try
    {
        return run(arguments);
    }
    catch (Exception failure)
    {
        JSONValue[string] body;
        body["state"] = JSONValue("crashed");
        body["message"] = JSONValue(failure.msg);

        emit(errorEnvelope("fatal", "engine_failure", failure.msg));
        return 1;
    }
}