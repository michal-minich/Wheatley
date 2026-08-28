module wheatley.server.stt.transcription;

struct SttTimedText
{
    string text;
    long startMs;
    long endMs;
}

struct SttTranscription
{
    string text;
    string language;
    long coveredAudioMs;
    SttTimedText[] timedText;
    SttExecutionMetrics execution;
}

struct SttExecutionMetrics
{
    bool workerStarted;
    bool workerRestarted;
    long workerStartupMs;
    long queueMs;
    long inferenceMs;
}
