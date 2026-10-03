import std.conv : to;
import std.datetime.stopwatch : AutoStart, StopWatch;
import std.json : JSONType, JSONValue, parseJSON, toJSON;
import std.process : environment;
import std.string : endsWith, splitLines, startsWith, strip, stripRight, toUpper;
import std.http : HTTPMethod;
import std.http.client : HTTPClient, HTTPClientRequest, Response;
import core.sync.mutex : Mutex;

enum DefaultEndpoint = "https://api.galaxy.dev/v1";
enum DefaultApiKeyEnv = "GALAXY_API_KEY";
enum DefaultUserAgent = "GalaxyEngine/1.0 (+https://github.com/galaxy-labs/galaxy-extension)";
enum DefaultTimeoutMs = 4000;
enum DefaultMaxRetries = 2;
enum DefaultOllamaEndpoint = "http://127.0.0.1:11434";
enum MaxCachedEntries = 128;

enum FetchStatus : string
{
    ok = "ok",
    unauthorized = "unauthorized",
    rateLimited = "rate_limited",
    notFound = "not_found",
    malformed = "malformed",
    transport = "transport",
    disabled = "disabled"
}

enum ProviderKind : string
{
    none = "none",
    automatic = "automatic",
    openai = "openai",
    ollama = "ollama"
}

struct FetcherConfig
{
    string endpoint = DefaultEndpoint;
    string apiKeyEnv = DefaultApiKeyEnv;
    string userAgent = DefaultUserAgent;
    uint timeoutMs = DefaultTimeoutMs;
    uint maxRetries = DefaultMaxRetries;
    bool verbose = false;

    string ollamaEndpoint = DefaultOllamaEndpoint;
    ProviderKind provider = ProviderKind.automatic;
    string model = "";
    uint maxTokens = 96;
    float temperature = 0.2f;
    bool stream = true;
    bool chatMode = false;
    bool aiEnabled = true;
}

struct FetchResult
{
    FetchStatus status = FetchStatus.transport;
    string message = "";
    string body = "";
    JSONValue payload = JSONValue.init;
    string url = "";
    uint statusCode = 0;
    uint attempts = 0;
    long elapsedMs = 0;
}

struct GenerationOptions
{
    string prompt;
    string suffix;
    ProviderKind provider = ProviderKind.automatic;
    string model = "";
    uint maxTokens = 96;
    float temperature = 0.2f;
    bool stream = true;
    bool chatMode = false;
}

struct GenerationResult
{
    bool available = false;
    bool aborted = false;
    bool cached = false;
    string text = "";
    string provider = "";
    string model = "";
    string finishReason = "";
    string error = "";
    uint statusCode = 0;
    long elapsedMs = 0;
    size_t chunks = 0;
}

struct StreamChunk
{
    string text;
    bool done = false;
    string finishReason = "";
}

alias DeltaSink = void delegate(string chunk, bool done);

final class AbortToken
{
    private shared bool flag;
    private shared bool done;
    private Mutex lock;

    this()
    {
        lock = new Mutex();
    }

    void cancel()
    {
        synchronized (lock)
        {
            flag = true;
        }
    }

    void complete()
    {
        synchronized (lock)
        {
            done = true;
        }
    }

    bool cancelled()
    {
        synchronized (lock)
        {
            return flag;
        }
    }

    bool completed()
    {
        synchronized (lock)
        {
            return done;
        }
    }
}

final class Fetcher
{
    private FetcherConfig config;
    private string credential;
    private bool credentialResolved;
    private FetchResult[string] cache;
    private string[string] generations;
    private ProviderKind resolvedProvider = ProviderKind.none;
    private Mutex shared_lock;
    private size_t totalRequests;
    private long totalElapsedMs;

    this(FetcherConfig settings = FetcherConfig.init)
    {
        shared_lock = new Mutex();
        config = settings;

        if (config.endpoint.length == 0)
            config.endpoint = DefaultEndpoint;

        if (config.apiKeyEnv.length == 0)
            config.apiKeyEnv = DefaultApiKeyEnv;

        if (config.userAgent.length == 0)
            config.userAgent = DefaultUserAgent;

        if (config.timeoutMs == 0)
            config.timeoutMs = DefaultTimeoutMs;

        if (config.ollamaEndpoint.length == 0)
            config.ollamaEndpoint = DefaultOllamaEndpoint;

        if (config.maxTokens == 0)
            config.maxTokens = 96;

        credential = resolveCredential();
        credentialResolved = true;
    }

    FetcherConfig settings() const
    {
        return config;
    }

    void reconfigure(FetcherConfig settings)
    {
        FetcherConfig merged = settings;

        if (merged.endpoint.length == 0)
            merged.endpoint = config.endpoint;

        if (merged.apiKeyEnv.length == 0)
            merged.apiKeyEnv = config.apiKeyEnv;

        if (merged.ollamaEndpoint.length == 0)
            merged.ollamaEndpoint = config.ollamaEndpoint;

        synchronized (shared_lock)
        {
            config = merged;
            credential = resolveCredential();
            credentialResolved = true;
            resolvedProvider = ProviderKind.none;
            generations = null;
        }
    }

    bool isConfigured() const
    {
        return config.endpoint.length > 0;
    }

    bool hasCredential() const
    {
        return credentialResolved ? credential.length > 0 : resolveCredential().length > 0;
    }

    string credentialName() const
    {
        return config.apiKeyEnv;
    }

    bool isAiEnabled() const
    {
        return config.aiEnabled && config.model.length > 0;
    }

    string modelName() const
    {
        return config.model;
    }

    size_t requestCount() const
    {
        return totalRequests;
    }

    long averageElapsedMs() const
    {
        return totalRequests == 0 ? 0 : totalElapsedMs / cast(long) totalRequests;
    }

    void clearCache()
    {
        synchronized (shared_lock)
        {
            cache = null;
            generations = null;
        }
    }

    ProviderKind activeProvider()
    {
        if (resolvedProvider != ProviderKind.none)
            return resolvedProvider;

        if (config.provider != ProviderKind.automatic)
        {
            resolvedProvider = config.provider;
            return resolvedProvider;
        }

        resolvedProvider = hasCredential() ? ProviderKind.openai : ProviderKind.ollama;

        return resolvedProvider;
    }

    FetchResult fetchJSON(string path, string method = "GET", JSONValue body = JSONValue.init)
    {
        FetchResult result;

        if (!isConfigured())
        {
            result.status = FetchStatus.disabled;
            result.message = "no endpoint configured";
            return result;
        }

        result.url = join(config.endpoint, path);

        if (result.url in cache && method.toUpper == "GET")
        {
            FetchResult hit = cache[result.url];
            hit.message = "cache";
            hit.elapsedMs = 0;
            hit.attempts = 0;
            return hit;
        }

        ubyte[] content;
        if (body.type != JSONType.null_ && method.toUpper != "GET")
            content = cast(ubyte[]) toJSON(body).idup;

        string verb = method.toUpper;
        uint budget = config.maxRetries + 1;
        long elapsedTotal;

        foreach (attempt; 1 .. budget)
        {
            StopWatch watch = StopWatch(AutoStart.yes);
            FetchResult attemptResult = performRequest(verb, result.url, content);
            watch.stop();

            attemptResult.attempts = attempt;
            attemptResult.elapsedMs = watch.peek().total!"msecs";
            elapsedTotal += attemptResult.elapsedMs;
            totalElapsedMs += attemptResult.elapsedMs;

            if (attemptResult.status == FetchStatus.ok)
            {
                if (verb == "GET" && cache.length < MaxCachedEntries)
                    cache[result.url] = attemptResult;

                result = attemptResult;
                break;
            }

            result = attemptResult;

            bool retryable = attemptResult.status == FetchStatus.transport
                || attemptResult.status == FetchStatus.rateLimited;

            if (!retryable || attempt == budget)
                break;
        }

        totalRequests++;
        result.elapsedMs = elapsedTotal;
        return result;
    }

    FetchResult probe()
    {
        return fetchJSON("/health", "GET");
    }

    GenerationResult generate(GenerationOptions options, DeltaSink onDelta, AbortToken token)
    {
        GenerationResult result;

        if (!isAiEnabled())
        {
            result.error = "ai disabled or no model configured";
            return result;
        }

        ProviderKind provider = options.provider == ProviderKind.automatic ? activeProvider() : options.provider;

        if (provider == ProviderKind.none)
        {
            result.error = "no provider resolved";
            return result;
        }

        string model = options.model.length > 0 ? options.model : config.model;
        string route = routeFor(provider, options);
        string key = provider ~ "|" ~ model ~ "|" ~ fingerprint(options.prompt, options.suffix);

        if (key in generations)
        {
            result.cached = true;
            result.available = true;
            result.provider = provider.to!string;
            result.model = model;

            StreamChunk[] replay = parseStream(generations[key], provider);

            foreach (chunk; replay)
            {
                if (onDelta !is null)
                    onDelta(chunk.text, chunk.done);

                result.text ~= chunk.text;

                if (token !is null && token.cancelled)
                    break;
            }

            result.finishReason = "cached";
            result.chunks = replay.length;
            return result;
        }

        if (token !is null && token.cancelled)
        {
            result.aborted = true;
            return result;
        }

        JSONValue payload = provider == ProviderKind.ollama ? ollamaBody(model, options) : openAiBody(model, options);

        StopWatch watch = StopWatch(AutoStart.yes);
        FetchResult response = performRequest("POST", route, cast(ubyte[]) toJSON(payload).idup);
        watch.stop();

        totalRequests++;
        totalElapsedMs += response.elapsedMs;
        result.elapsedMs = watch.peek().total!"msecs";
        result.statusCode = response.statusCode;
        result.provider = provider.to!string;
        result.model = model;

        if (response.status != FetchStatus.ok)
        {
            result.error = response.message;

            if (provider == ProviderKind.ollama && response.status == FetchStatus.transport && config.provider == ProviderKind.automatic)
            {
                resolvedProvider = ProviderKind.openai;
                result.error ~= "; fell back to openai compatible provider";
            }

            return result;
        }

        string body = response.body;
        StreamChunk[] chunks = parseStream(body, provider);

        bool terminated;

        foreach (chunk; chunks)
        {
            if (token !is null && token.cancelled)
            {
                result.aborted = true;
                break;
            }

            if (chunk.done)
            {
                if (terminated)
                    continue;

                terminated = true;
                result.finishReason = chunk.finishReason;
            }

            if (onDelta !is null)
                onDelta(chunk.text, chunk.done);

            result.text ~= chunk.text;
            result.chunks++;
        }

        result.available = result.text.length > 0;

        if (result.available && !result.aborted && generations.length < MaxCachedEntries)
            generations[key] = body;

        return result;
    }

    private JSONValue openAiBody(string model, GenerationOptions options)
    {
        JSONValue[string] root;
        root["model"] = JSONValue(model);
        root["max_tokens"] = JSONValue(cast(long) options.maxTokens);
        root["temperature"] = JSONValue(cast(double) options.temperature);
        root["stream"] = JSONValue(options.stream);

        if (options.chatMode)
        {
            JSONValue[string] message;
            message["role"] = JSONValue("user");
            message["content"] = JSONValue(options.prompt);

            JSONValue[string] envelope;
            envelope["role"] = JSONValue("system");
            envelope["content"] = JSONValue("You are a code completion engine. Return only code.");

            root["messages"] = JSONValue([JSONValue(envelope), JSONValue(message)]);
            root["n"] = JSONValue(1L);
        }
        else
        {
            root["prompt"] = JSONValue(options.prompt);
            root["suffix"] = JSONValue(options.suffix);
        }

        return JSONValue(root);
    }

    private JSONValue ollamaBody(string model, GenerationOptions options)
    {
        JSONValue[string] tuned;
        tuned["num_predict"] = JSONValue(cast(long) options.maxTokens);
        tuned["temperature"] = JSONValue(cast(double) options.temperature);
        tuned["stop"] = JSONValue(["```"]);

        JSONValue[string] root;
        root["model"] = JSONValue(model);
        root["prompt"] = JSONValue(options.prompt);
        root["stream"] = JSONValue(options.stream);
        root["options"] = JSONValue(tuned);

        return JSONValue(root);
    }

    private string routeFor(ProviderKind provider, GenerationOptions options)
    {
        if (provider == ProviderKind.ollama)
            return join(config.ollamaEndpoint, "/api/generate");

        if (provider == ProviderKind.openai)
        {
            string base = config.endpoint;

            if (base.endsWith("/completions"))
                return base;

            return join(base, options.chatMode ? "/chat/completions" : "/completions");
        }

        return join(config.endpoint, "/generate");
    }

    private static StreamChunk[] parseStream(string body, ProviderKind provider)
    {
        StreamChunk[] chunks;
        string[] lines = splitLines(body);
        size_t emitted;

        foreach (line; lines)
        {
            string payload = line.strip;

            if (payload.length == 0)
                continue;

            if (payload.startsWith("data:"))
                payload = payload[5 .. $].strip;

            if (payload == "[DONE]")
            {
                StreamChunk terminator;
                terminator.done = true;
                terminator.finishReason = "stop";
                chunks ~= terminator;
                break;
            }

            JSONValue event;

            try
            {
                event = parseJSON(payload);
            }
            catch (Exception parseFailure)
            {
                continue;
            }

            if (event.type != JSONType.object)
                continue;

            if (provider == ProviderKind.ollama)
            {
                string text = objectString(event, "response");
                bool done = objectBool(event, "done");

                if (text.length > 0)
                {
                    StreamChunk chunk;
                    chunk.text = text;
                    chunks ~= chunk;
                    emitted++;
                }

                if (done)
                {
                    StreamChunk terminator;
                    terminator.done = true;
                    terminator.finishReason = objectString(event, "done_reason");
                    chunks ~= terminator;
                    break;
                }

                continue;
            }

            JSONValue[] choices = objectArray(event, "choices");

            foreach (choice; choices)
            {
                JSONValue delta = objectValue(choice, "delta");
                string text = objectString(choice, "text");

                if (text.length == 0 && delta.type == JSONType.object)
                    text = objectString(delta, "content");

                if (text.length == 0)
                {
                    JSONValue message = objectValue(choice, "message");

                    if (message.type == JSONType.object)
                        text = objectString(message, "content");
                }

                string finish = objectString(choice, "finish_reason");

                if (text.length > 0)
                {
                    StreamChunk chunk;
                    chunk.text = text;
                    chunks ~= chunk;
                    emitted++;
                }

                if (finish.length > 0)
                {
                    StreamChunk terminator;
                    terminator.done = true;
                    terminator.finishReason = finish;
                    chunks ~= terminator;
                }
            }
        }

        if (emitted > 0)
        {
            bool hasTerminator;

            foreach (chunk; chunks)
            {
                if (chunk.done)
                {
                    hasTerminator = true;
                    break;
                }
            }

            if (!hasTerminator)
            {
                StreamChunk terminator;
                terminator.done = true;
                terminator.finishReason = "eof";
                chunks ~= terminator;
            }
        }

        return chunks;
    }

    private FetchResult performRequest(string verb, string url, const(ubyte)[] content)
    {
        FetchResult result;
        result.url = url;

        try
        {
            if (content.length == 0)
            {
                HTTPClient client = new HTTPClient;
                scope (exit) client.shutdown();

                Response response = verb == "HEAD" ? client.head(url) : client.get(url);
                return interpret(response, result);
            }

            auto request = new HTTPClientRequest(url, verb == "POST" ? HTTPMethod.post : HTTPMethod.put);
            applyHeaders(request.headers);

            Response response = request.send(verb, url, content, "application/json");
            return interpret(response, result);
        }
        catch (Throwable failure)
        {
            result.status = FetchStatus.transport;
            result.message = failure.msg;
        }

        return result;
    }

    private FetchResult interpret(Response response, FetchResult result)
    {
        result.statusCode = response.code;

        string body = cast(string) response.responseBody.idup;
        if (body.length == 0)
            body = cast(string) response.contentBody.idup;

        result.body = body;

        if (response.code >= 200 && response.code < 300)
        {
            result.status = FetchStatus.ok;
            result.message = "ok";
            result.body = body;

            if (body.length > 0 && looksLikeJson(body))
            {
                try
                {
                    result.payload = parseJSON(body);
                }
                catch (Exception parseFailure)
                {
                    result.status = FetchStatus.malformed;
                    result.message = parseFailure.msg;
                    result.payload = JSONValue.init;
                }
            }
        }
        else if (response.code == 401 || response.code == 403)
        {
            result.status = FetchStatus.unauthorized;
            result.message = "credential rejected";
        }
        else if (response.code == 429)
        {
            result.status = FetchStatus.rateLimited;
            result.message = "rate limit reached";
        }
        else if (response.code == 404)
        {
            result.status = FetchStatus.notFound;
            result.message = "unknown route";
        }
        else
        {
            result.status = FetchStatus.transport;
            result.message = "unexpected status " ~ response.code.to!string;
        }

        if (config.verbose)
            result.message ~= " (" ~ result.url ~ ")";

        return result;
    }

    private void applyHeaders(string[string] headers)
    {
        headers["Accept"] = "application/json";
        headers["User-Agent"] = config.userAgent;
        headers["X-Galaxy-Client"] = "engine";
        headers["X-Galaxy-Timeout"] = timeoutSeconds().to!string;

        if (credential.length > 0)
            headers["Authorization"] = "Bearer " ~ credential;
    }

    private uint timeoutSeconds() const
    {
        return config.timeoutMs / 1000 + 1;
    }

    private string join(string base, string path) const
    {
        string trimmed = path.strip;

        if (trimmed.startsWith("http://") || trimmed.startsWith("https://"))
            return trimmed;

        string root = base.strip;

        while (root.length > 0 && root[$ - 1] == '/')
            root = root[0 .. $ - 1];

        if (trimmed.length == 0 || trimmed == "/")
            return root;

        if (trimmed[0] == '/')
            return root ~ trimmed;

        return root ~ "/" ~ trimmed;
    }

    private string resolveCredential() const
    {
        if (config.apiKeyEnv.length == 0)
            return "";

        const(string)[] names = [config.apiKeyEnv, "GALAXY_API_KEY", "GALAXY_TOKEN"];

        foreach (name; names)
        {
            auto value = environment.get(name);

            if (value.length > 0)
                return value.strip;
        }

        return "";
    }

    private static string fingerprint(string prompt, string suffix)
    {
        ulong hash = 14695981039346656037UL;

        foreach (character; prompt ~ "|" ~ suffix)
        {
            hash ^= cast(ulong) character;
            hash *= 1099511628211UL;
        }

        return hash.to!string;
    }

    private static bool looksLikeJson(string body)
    {
        size_t start = 0;

        while (start < body.length && (body[start] == ' ' || body[start] == '\n' || body[start] == '\r' || body[start] == '\t'))
            start++;

        if (start >= body.length)
            return false;

        char head = body[start];
        return head == '{' || head == '[' || head == '"';
    }

private static string objectString(JSONValue source, string key)
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

    private static bool objectBool(JSONValue source, string key)
    {
        if (source.type != JSONType.object)
            return false;

        JSONValue[string] storage = source.object;
        auto slot = key in storage;

        if (slot is null)
            return false;

        JSONValue value = *slot;
        return value.type == JSONType.true_;
    }

    private static JSONValue objectValue(JSONValue source, string key)
    {
        if (source.type != JSONType.object)
            return JSONValue.init;

        JSONValue[string] storage = source.object;
        auto slot = key in storage;

        if (slot is null)
            return JSONValue.init;

        return *slot;
    }

    private static JSONValue[] objectArray(JSONValue source, string key)
    {
        JSONValue value = objectValue(source, key);

        if (value.type != JSONType.array)
            return null;

        JSONValue[] items = value.array;
        return items;
    }
}