module wheatley.server.image_generation.types;

struct ImageGenerationRequest
{
    string requestId;
    string prompt;
    int width;
    int height;
    long seed;
}

struct ImageGenerationOutput
{
    ubyte[] png;
}

struct ImagePreset
{
    int width;
    int height;
}

struct ImageGenerationConfig
{
    string endpoint;
    int timeoutSeconds;
    ImagePreset[string] presets;
}
