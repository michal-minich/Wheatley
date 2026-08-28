module wheatley.server.tts.generated_artifacts;

import std.digest : LetterCase, toHexString;
import std.digest.sha : sha1Of, sha256Of;
import std.file : read;
import std.uuid : randomUUID;

import wheatley.common.safe_token : safeToken;

string generatedTtsArtifactId(string profileId, string text)
{
    auto fullDigest = toHexString!(LetterCase.lower)(sha1Of(text)).idup;
    auto digest = fullDigest[0 .. 12];
    return ("tts-" ~ safeToken(profileId, "profile") ~ "-" ~ digest ~ "-" ~ randomUUID().toString()).idup;
}

string sha256File(string path)
{
    auto data = cast(ubyte[]) read(path);
    return toHexString!(LetterCase.lower)(sha256Of(data)).idup;
}
