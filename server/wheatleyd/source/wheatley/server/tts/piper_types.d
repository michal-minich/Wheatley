module wheatley.server.tts.piper_types;

struct PiperSynthesisSettings
{
    string binary;
    string model;
    string config;
    bool hasSpeaker;
    long speaker;
    double lengthScale;
    double noiseScale;
    double noiseWScale;
    double sentenceSilence;
    double volume;
    double requestTimeoutSeconds;
    string[string] pronunciationReplacements;
}
