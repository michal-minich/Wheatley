module wheatley.server.stt.whisper_cpp;

import core.sync.mutex : Mutex;
import core.time : MonoTime, dur;

import std.algorithm.comparison : max;
import std.array : Appender, appender, join;
import std.conv : to;
import std.exception : enforce;
import std.file : read;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : absolutePath, baseName, buildNormalizedPath;
import std.socket : AddressFamily, InternetAddress, Socket, SocketType;
import std.string : strip;
import std.typecons : Nullable, nullable;
import std.uuid : randomUUID;

import vibe.core.core : sleep;
import vibe.core.path : NativePath;
import vibe.core.process : Config, Process, spawnProcess;
import vibe.core.sync : TaskMutex, scopedMutexLock;
import vibe.http.client : HTTPClient, HTTPClientSettings;
import vibe.http.client : requestHTTP;
import vibe.http.common : HTTPMethod;
import vibe.stream.operations : readAllUTF8;

import wheatley.common.json.read : Json;
import wheatley.server.stt.runtime_settings :
    SttModelRole,
    SttRecognizerType,
    SttRuntimeSettings;
import wheatley.server.stt.transcription : SttExecutionMetrics, SttTimedText, SttTranscription;

final class WhisperCppWorkers
{
    private Mutex mutex;
    private WhisperCppWorker preview;
    private WhisperCppWorker finalTurn;

    this()
    {
        mutex = new Mutex;
    }

    SttTranscription transcribe(
        SttRuntimeSettings settings,
        string audioPath,
        string prompt,
        bool timestamps,
        bool allowEmpty = false,
    )
    {
        return workerFor(settings).transcribe(settings, audioPath, prompt, timestamps, allowEmpty);
    }

    void shutdown()
    {
        WhisperCppWorker previewWorker;
        WhisperCppWorker finalWorker;
        synchronized (mutex) {
            previewWorker = preview;
            finalWorker = finalTurn;
            preview = null;
            finalTurn = null;
        }
        if (previewWorker !is null) previewWorker.shutdown();
        if (finalWorker !is null) finalWorker.shutdown();
    }

    private WhisperCppWorker workerFor(SttRuntimeSettings settings)
    {
        synchronized (mutex) {
            auto slot = settings.role == SttModelRole.preview ? &preview : &finalTurn;
            auto fingerprint = settings.recognizerType.to!string ~ "\n" ~
                settings.serverBinary ~ "\n" ~ settings.model ~ "\n" ~ settings.endpoint;
            if (*slot !is null && (*slot).fingerprint == fingerprint) return *slot;
            if (*slot !is null) (*slot).shutdown();
            *slot = new WhisperCppWorker(
                fingerprint,
                settings.recognizerType,
                settings.serverBinary,
                settings.model,
                settings.endpoint,
            );
            return *slot;
        }
    }
}

private final class WhisperCppWorker
{
    immutable string fingerprint;

    private string binary;
    private string model;
    private string endpoint;
    private SttRecognizerType recognizerType;
    private TaskMutex runMutex;
    private Process process;
    private bool started;
    private ushort port;

    this(
        string fingerprint,
        SttRecognizerType recognizerType,
        string binary,
        string model,
        string endpoint,
    )
    {
        this.fingerprint = fingerprint;
        this.recognizerType = recognizerType;
        this.binary = binary;
        this.model = model;
        this.endpoint = endpoint;
        this.runMutex = new TaskMutex;
    }

    SttTranscription transcribe(
        SttRuntimeSettings settings,
        string audioPath,
        string prompt,
        bool timestamps,
        bool allowEmpty,
    )
    {
        auto queuedAt = MonoTime.currTime;
        auto guard = scopedMutexLock(runMutex);
        auto queueMs = elapsedMs(queuedAt);
        bool restarted;

        foreach (attempt; 0 .. 2) {
            try {
                auto start = ensureStarted(settings.requestTimeoutSeconds);
                auto inferenceStarted = MonoTime.currTime;
                auto response = requestTranscription(settings, audioPath, prompt, timestamps);
                auto transcription = sttTranscriptionFromWhisperCppServerJson(response, allowEmpty);
                if (settings.language.length) transcription.language = settings.language;
                transcription.execution = SttExecutionMetrics(
                    start.started,
                    restarted,
                    start.startupMs,
                    queueMs,
                    elapsedMs(inferenceStarted),
                );
                return transcription;
            } catch (WhisperCppRequestFailure error) {
                if (
                    recognizerType == SttRecognizerType.remoteWhisperCpp ||
                    error.clientFailure || attempt == 1
                ) throw error;
                stop();
                restarted = true;
            } catch (Exception error) {
                if (recognizerType == SttRecognizerType.remoteWhisperCpp || attempt == 1) throw error;
                stop();
                restarted = true;
            }
        }
        assert(false, "Whisper worker retry loop did not return");
    }

    void shutdown()
    {
        auto guard = scopedMutexLock(runMutex);
        stop();
    }

    private WorkerStart ensureStarted(double timeoutSeconds)
    {
        if (recognizerType == SttRecognizerType.remoteWhisperCpp) return WorkerStart.init;
        if (started && !process.exited) return WorkerStart.init;
        stop();

        auto startedAt = MonoTime.currTime;
        port = availableLoopbackPort();
        process = spawnProcess(
            [
                binary,
                "--host", "127.0.0.1",
                "--port", port.to!string,
                "--model", model,
                "--language", "auto",
            ],
            null,
            Config.detached,
            NativePath(absolutePath(buildNormalizedPath("."))),
        );
        started = true;
        waitUntilReady(timeoutSeconds);
        return WorkerStart(true, elapsedMs(startedAt));
    }

    private void waitUntilReady(double timeoutSeconds)
    {
        auto deadline = MonoTime.currTime + dur!"msecs"(timeoutMillis(timeoutSeconds));
        while (MonoTime.currTime < deadline) {
            if (process.exited) {
                auto status = process.wait();
                started = false;
                throw new Exception("whisper-server exited during startup with status " ~ status.to!string);
            }
            try {
                string body;
                auto client = workerClient(port, timeoutSeconds);
                scope(exit) client.disconnect();
                client.request((scope request) {
                    request.method = HTTPMethod.GET;
                    request.requestURL = "/health";
                }, (scope response) {
                    enforce(response.statusCode >= 200 && response.statusCode < 300, "health request failed");
                    body = response.bodyReader.readAllUTF8();
                });
                if (body.length) return;
            } catch (Exception) {
            }
            sleep(dur!"msecs"(25));
        }
        throw new Exception("whisper-server did not become ready before the STT timeout");
    }

    private string requestTranscription(
        SttRuntimeSettings settings,
        string audioPath,
        string prompt,
        bool timestamps,
    )
    {
        auto boundary = "wheatley-whisper-" ~ randomUUID().toString();
        auto body = whisperMultipartBody(boundary, settings, audioPath, prompt, timestamps);
        string responseBody;
        int statusCode;
        if (recognizerType == SttRecognizerType.localWhisperCpp) {
            auto client = workerClient(port, settings.requestTimeoutSeconds);
            scope(exit) client.disconnect();
            client.request((scope request) {
                request.method = HTTPMethod.POST;
                request.requestURL = "/inference";
                request.writeBody(body, "multipart/form-data; boundary=" ~ boundary);
            }, (scope response) {
                statusCode = response.statusCode;
                responseBody = response.bodyReader.readAllUTF8();
            });
        } else {
            requestHTTP(
                endpoint ~ "/inference",
                (scope request) {
                    request.method = HTTPMethod.POST;
                    request.writeBody(body, "multipart/form-data; boundary=" ~ boundary);
                },
                (scope response) {
                    statusCode = response.statusCode;
                    responseBody = response.bodyReader.readAllUTF8();
                },
                remoteHttpSettings(settings.requestTimeoutSeconds),
            );
        }
        if (statusCode < 200 || statusCode >= 300) {
            throw new WhisperCppRequestFailure(
                "whisper-server request failed with HTTP " ~ statusCode.to!string ~ ": " ~ responseBody.strip,
                statusCode >= 400 && statusCode < 500,
            );
        }
        return responseBody;
    }

    private void stop()
    {
        if (recognizerType == SttRecognizerType.remoteWhisperCpp) return;
        if (!started) return;
        started = false;
        try {
            if (!process.exited && process.wait(dur!"msecs"(500)).isNull) process.kill();
            if (!process.exited && process.wait(dur!"seconds"(2)).isNull)
                process.forceKill();
            // Shutdown can run while vibe's event loop is itself stopping. A
            // final unbounded Process.wait() can then never receive its exit
            // callback even though the child has been killed.
            if (!process.exited) process.wait(dur!"msecs"(500));
        } catch (Exception) {
        }
        process = Process.init;
        port = 0;
    }
}

private final class WhisperCppRequestFailure : Exception
{
    bool clientFailure;

    this(string message, bool clientFailure)
    {
        super(message);
        this.clientFailure = clientFailure;
    }
}

private struct WorkerStart
{
    bool started;
    long startupMs;
}

SttTranscription sttTranscriptionFromWhisperCppServerJson(string responseBody, bool allowEmpty)
{
    auto payload = parseJSON(responseBody);
    enforce(payload.type == JSONType.object, "whisper-server returned non-object JSON");

    auto payloadJson = Json.object(payload);

    auto text = payloadJson.opt.textOrEmpty("text").strip;
    long coveredAudioMs;
    SttTimedText[] timedText;
    auto segments = "segments" in payload.objectNoRef;
    if (segments !is null) {
        enforce(segments.type == JSONType.array, "whisper-server segments is not an array");
        string[] segmentTexts;
        foreach (segment; segments.array) {
            auto segmentJson = Json.object(segment);
            auto rawSegmentText = segmentJson.opt.textOrEmpty("text");
            auto segmentText = rawSegmentText.strip;
            if (segmentText.length) segmentTexts ~= segmentText;
            auto start = numericField(segment, "start");
            auto end = numericField(segment, "end");
            if (!end.isNull) {
                coveredAudioMs = max(coveredAudioMs, cast(long) (end.get * 1_000.0));
            }
            auto timedTextStart = timedText.length;
            auto words = "words" in segment.objectNoRef;
            if (words !is null) {
                enforce(words.type == JSONType.array, "whisper-server segment words is not an array");
                foreach (word; words.array) {
                    auto wordText = Json.object(word).opt.textOrEmpty("word");
                    auto wordStart = numericField(word, "start");
                    auto wordEnd = numericField(word, "end");
                    if (wordText.length && !wordStart.isNull && !wordEnd.isNull) {
                        timedText ~= SttTimedText(
                            wordText,
                            cast(long) (wordStart.get * 1_000.0),
                            cast(long) (wordEnd.get * 1_000.0),
                        );
                    }
                }
            }
            if (
                timedText.length == timedTextStart && segmentText.length &&
                !start.isNull && !end.isNull
            ) {
                timedText ~= SttTimedText(
                    rawSegmentText,
                    cast(long) (start.get * 1_000.0),
                    cast(long) (end.get * 1_000.0),
                );
            }
        }
        if (segmentTexts.length) text = segmentTexts.join(" ").strip;
    }

    enforce(allowEmpty || text.length > 0, "whisper-server returned empty text");
    auto language = payloadJson.opt.textOrEmpty("detected_language");
    if (!language.length)
        language = payloadJson.opt.textOrEmpty("language");
    return SttTranscription(text, language, coveredAudioMs, timedText);
}

private ubyte[] whisperMultipartBody(
    string boundary,
    SttRuntimeSettings settings,
    string audioPath,
    string prompt,
    bool timestamps,
)
{
    auto output = appender!(ubyte[])();
    putField(output, boundary, "response_format", "verbose_json");
    putField(output, boundary, "language", settings.language.length ? settings.language : "auto");
    putField(output, boundary, "beam_size", settings.beamSize.to!string);
    putField(output, boundary, "no_timestamps", timestamps ? "false" : "true");
    putField(output, boundary, "no_language_probabilities", "true");
    if (settings.maxContextTokens >= 0) {
        putField(output, boundary, "max_context", settings.maxContextTokens.to!string);
    }
    auto promptText = prompt.strip;
    if (promptText.length) putField(output, boundary, "prompt", promptText);
    putFile(output, boundary, "file", baseName(audioPath), cast(ubyte[]) read(audioPath));
    putAscii(output, "--" ~ boundary ~ "--\r\n");
    return output.data;
}

private void putField(ref Appender!(ubyte[]) output, string boundary, string name, string value)
{
    putAscii(output, "--" ~ boundary ~ "\r\n");
    putAscii(output, "Content-Disposition: form-data; name=\"" ~ name ~ "\"\r\n\r\n");
    putAscii(output, value ~ "\r\n");
}

private void putFile(
    ref Appender!(ubyte[]) output,
    string boundary,
    string name,
    string fileName,
    const(ubyte)[] bytes,
)
{
    putAscii(output, "--" ~ boundary ~ "\r\n");
    putAscii(
        output,
        "Content-Disposition: form-data; name=\"" ~ name ~ "\"; filename=\"" ~ fileName ~ "\"\r\n",
    );
    putAscii(output, "Content-Type: audio/wav\r\n\r\n");
    output.put(bytes);
    putAscii(output, "\r\n");
}

private void putAscii(ref Appender!(ubyte[]) output, string value)
{
    output.put(cast(const(ubyte)[]) value);
}

private Nullable!double numericField(ref JSONValue object, string name)
{
    auto value = name in object.objectNoRef;
    if (value is null) return Nullable!double.init;
    if (value.type == JSONType.float_) {
        return value.floating.nullable;
    }
    if (value.type == JSONType.integer) {
        return (cast(double) value.integer).nullable;
    }
    return Nullable!double.init;
}

private ushort availableLoopbackPort()
{
    auto socket = new Socket(AddressFamily.INET, SocketType.STREAM);
    scope(exit) socket.close();
    socket.bind(new InternetAddress("127.0.0.1", 0));
    return (cast(InternetAddress) socket.localAddress()).port;
}

private HTTPClient workerClient(ushort port, double timeoutSeconds)
{
    auto client = new HTTPClient;
    client.connect("127.0.0.1", port, false, httpSettings(timeoutSeconds));
    return client;
}

private HTTPClientSettings httpSettings(double timeoutSeconds)
{
    auto settings = new HTTPClientSettings;
    settings.connectTimeout = dur!"msecs"(250);
    settings.readTimeout = dur!"msecs"(timeoutMillis(timeoutSeconds));
    settings.dnsAddressFamily = AddressFamily.INET;
    return settings;
}

private HTTPClientSettings remoteHttpSettings(double timeoutSeconds)
{
    auto settings = httpSettings(timeoutSeconds);
    settings.connectTimeout = dur!"seconds"(5);
    return settings;
}

private long timeoutMillis(double seconds)
{
    auto value = cast(long) (seconds * 1_000.0);
    return value > 0 ? value : 1;
}

private long elapsedMs(MonoTime started)
{
    return cast(long) (MonoTime.currTime - started).total!"msecs";
}

unittest
{
    auto response = `{
        "text":" \"Hello\"\n \"world.\" ",
        "language":"en",
        "detected_language":"en",
        "segments":[
            {"start":0.0,"end":0.82,"text":" Hello","words":[
                {"word":" Hello","start":0.1,"end":0.7}
            ]},
            {"start":0.82,"end":1.25,"text":" world."}
        ]
    }`;
    auto transcription = sttTranscriptionFromWhisperCppServerJson(response, false);
    assert(transcription.text == "Hello world.");
    assert(transcription.language == "en");
    assert(transcription.coveredAudioMs == 1_250);
    assert(transcription.timedText.length == 2);
    assert(transcription.timedText[0] == SttTimedText(" Hello", 100, 700));
    assert(transcription.timedText[1] == SttTimedText(" world.", 820, 1_250));
}
