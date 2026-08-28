module wheatley.server.image_generation.remote_http_port;

import core.time : dur;
import std.algorithm.searching : startsWith;
import std.exception : enforce;
import std.format : format;
import std.socket : AddressFamily;
import std.string : strip;

import vibe.http.client : HTTPClientSettings, requestHTTP;
import vibe.http.common : HTTPMethod;
import vibe.stream.operations : readAll, readAllUTF8;

import wheatley.common.json.object : jsonLongField, jsonObject, jsonStringField;
import wheatley.server.image_generation.port : ImageGeneratorPort;
import wheatley.server.image_generation.types : ImageGenerationOutput, ImageGenerationRequest;

final class RemoteImageGeneratorHttpPort : ImageGeneratorPort
{
    private string endpoint;
    private string token;
    private int timeoutSeconds;

    this(string endpoint, string token, int timeoutSeconds)
    {
        this.endpoint = normalizeEndpoint(endpoint);
        this.token = token.strip;
        this.timeoutSeconds = timeoutSeconds;
        enforce(this.token.length, "WHEATLEY_IMAGE_API_TOKEN is required");
        enforce(timeoutSeconds > 0, "Image generation timeout must be positive");
    }

    ImageGenerationOutput generate(ImageGenerationRequest input)
    {
        ubyte[] bytes;
        requestHTTP(endpoint ~ "/v1/generate", (scope request) {
            request.method = HTTPMethod.POST;
            request.headers["Authorization"] = "Bearer " ~ token;
            request.writeBody(cast(ubyte[]) jsonObject([
                jsonStringField("request_id", input.requestId),
                jsonStringField("prompt", input.prompt),
                jsonLongField("width", input.width),
                jsonLongField("height", input.height),
                jsonLongField("seed", input.seed),
            ]), "application/json; charset=UTF-8");
        }, (scope response) {
            enforceHttpOk(response, "Remote image generation");
            auto mediaType = response.headers.get("Content-Type", "");
            enforce(mediaType.startsWith("image/png"), "Image worker did not return image/png");
            bytes = response.bodyReader.readAll();
        }, settings());
        return ImageGenerationOutput(bytes);
    }

    bool healthy()
    {
        try {
            bool ready;
            // vibe-http pools clients by endpoint, not timeout settings. Health
            // and generation must therefore use identical connection settings;
            // otherwise the first health probe's short read timeout leaks into
            // the subsequent long-running generation request.
            requestHTTP(endpoint ~ "/health", (scope request) {
                request.method = HTTPMethod.GET;
                request.headers["Authorization"] = "Bearer " ~ token;
            }, (scope response) {
                ready = response.statusCode >= 200 && response.statusCode < 300;
                if (!ready) response.bodyReader.readAllUTF8();
            }, settings());
            return ready;
        } catch (Exception) {
            return false;
        }
    }

    private HTTPClientSettings settings()
    {
        auto value = new HTTPClientSettings;
        value.connectTimeout = dur!"seconds"(5);
        value.readTimeout = dur!"seconds"(timeoutSeconds);
        value.dnsAddressFamily = AddressFamily.INET;
        return value;
    }

}

private string normalizeEndpoint(string value)
{
    auto clean = value.strip;
    enforce(clean.startsWith("http://") || clean.startsWith("https://"),
        "Image generation endpoint must be HTTP(S)");
    while (clean.length && clean[$ - 1] == '/') clean = clean[0 .. $ - 1];
    return clean;
}

private void enforceHttpOk(Response)(Response response, string label)
{
    if (response.statusCode >= 200 && response.statusCode < 300) return;
    throw new Exception(format!"%s failed with HTTP %s: %s"(
        label,
        response.statusCode,
        response.bodyReader.readAllUTF8().strip,
    ));
}
