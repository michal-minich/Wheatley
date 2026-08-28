module wheatley.server.turns.text.pi_compaction;

import wheatley.common.json.object :
    jsonBoolField,
    jsonLongField,
    jsonObject,
    jsonRawField,
    jsonStringField;

struct PiCompactionEvent
{
    string id;
    string reason;
    string status;
    string startedAt;
    string completedAt;
    long durationMs;
    string summary;
    string errorMessage;
    long tokensBefore;
    long estimatedTokensAfter;
    bool willRetry;
    string usageJson;
    string detailsJson;

    string json(long presentationSequence = 0) const
    {
        return jsonObject([
            jsonStringField("id", id),
            jsonStringField("reason", reason),
            jsonStringField("status", status),
            jsonStringField("started_at", startedAt),
            jsonStringField("completed_at", completedAt),
            jsonLongField("duration_ms", durationMs),
            jsonStringField("summary", summary),
            jsonStringField("error_message", errorMessage),
            jsonLongField("tokens_before", tokensBefore),
            jsonLongField("estimated_tokens_after", estimatedTokensAfter),
            jsonBoolField("will_retry", willRetry),
            jsonRawField("usage", usageJson.length ? usageJson : "{}"),
            jsonRawField("details", detailsJson.length ? detailsJson : "{}"),
            presentationSequence > 0
                ? jsonLongField("presentation_sequence", presentationSequence)
                : "",
        ]);
    }
}

alias PiCompactionSink = long delegate(PiCompactionEvent event);
