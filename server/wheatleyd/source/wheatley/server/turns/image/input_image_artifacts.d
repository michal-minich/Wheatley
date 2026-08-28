module wheatley.server.turns.image.input_image_artifacts;

import std.algorithm : canFind;
import std.exception : enforce;
import std.file : copy, exists, getSize, mkdirRecurse, readText;
import std.json : parseJSON;
import std.path : baseName, buildPath;
import std.string : startsWith;
import std.uuid : randomUUID;

import wheatley.common.json.object :
    jsonLongField,
    jsonObject,
    jsonStringField;
import wheatley.common.json.read : Json;
import wheatley.common.runtime.files : moveFileReplacing;
import wheatley.common.runtime.temp_files : removeQuietly;
import wheatley.common.safe_token : enforceSafeToken;
import wheatley.server.api.core.config : ServerConfig;
import wheatley.server.history.rows.image_artifact_record : UserImageArtifactRecord;

enum maxUserImageBytes = 32UL * 1024 * 1024;

UserImageArtifactRecord persistUploadedUserImage(
    ServerConfig config,
    string profileId,
    string submissionId,
    string uploadPath,
    string filename,
    string mediaType,
)
{
    enforceSafeToken(profileId, "Image profile ID");
    enforceSafeToken(submissionId, "Image submission ID");
    enforce(exists(uploadPath), "Uploaded image file does not exist");
    enforceUserImageFilename(filename);
    enforceUserImageMediaType(mediaType);
    auto uploadBytes = getSize(uploadPath);
    enforce(uploadBytes <= maxUserImageBytes, "Uploaded image exceeds the 32 MiB limit");

    auto root = stagedUserImagesRoot(config, profileId);
    auto directory = buildPath(root, submissionId);
    auto stagedPath = buildPath(directory, filename);
    auto manifestPath = buildPath(root, submissionId ~ ".json");
    mkdirRecurse(directory);
    auto partialPath = buildPath(directory, ".upload-" ~ randomUUID().toString());
    scope(failure) removeQuietly(partialPath);
    copy(uploadPath, partialPath);
    moveFileReplacing(partialPath, stagedPath);

    auto artifact = UserImageArtifactRecord(
        filename,
        mediaType,
        stagedPath,
        manifestPath,
        uploadBytes,
    );
    import wheatley.server.history.store.json : writeJsonFileAtomic;
    writeJsonFileAtomic(manifestPath, userImageArtifactJson(artifact));
    return artifact;
}

UserImageArtifactRecord loadStagedUserImage(
    ServerConfig config,
    string profileId,
    string submissionId,
)
{
    enforceSafeToken(profileId, "Image profile ID");
    enforceSafeToken(submissionId, "Image submission ID");
    auto root = stagedUserImagesRoot(config, profileId);
    auto manifestPath = buildPath(root, submissionId ~ ".json");
    if (!exists(manifestPath)) return UserImageArtifactRecord();

    auto json = Json.object(parseJSON(readText(manifestPath)));
    auto filename = json.nonEmpty("filename");
    auto mediaType = json.nonEmpty("media_type");
    auto bytes = json.nonNegativeInt("bytes");
    enforceUserImageFilename(filename);
    enforceUserImageMediaType(mediaType);
    auto stagedPath = buildPath(root, submissionId, filename);
    enforce(exists(stagedPath), "Staged image file does not exist");
    enforce(getSize(stagedPath) == bytes, "Staged image byte count changed");
    return UserImageArtifactRecord(
        filename,
        mediaType,
        stagedPath,
        manifestPath,
        cast(ulong) bytes,
    );
}

void enforceUserImageFilename(string filename)
{
    enforce(filename.length, "Image filename is required");
    enforce(baseName(filename) == filename, "Image filename must not contain a path");
    enforce(filename != "." && filename != "..", "Image filename is unsafe");
    enforce(!filename.canFind('\0'), "Image filename contains a null byte");
    foreach (ch; filename) {
        enforce(ch >= 0x20 && ch != 0x7f, "Image filename contains a control character");
    }
}

void enforceUserImageMediaType(string mediaType)
{
    enforce(mediaType.startsWith("image/") && mediaType.length > "image/".length,
        "Uploaded file is not an image");
    foreach (ch; mediaType) {
        enforce(
            ch >= 'a' && ch <= 'z'
                || ch >= '0' && ch <= '9'
                || ch == '/' || ch == '+' || ch == '-' || ch == '.',
            "Image media type is invalid",
        );
    }
}

private string stagedUserImagesRoot(ServerConfig config, string profileId)
{
    return buildPath(
        config.profilesRoot,
        profileId,
        "files",
        "_staged",
        "user-images",
    );
}

private string userImageArtifactJson(UserImageArtifactRecord artifact)
{
    return jsonObject([
        jsonStringField("filename", artifact.filename),
        jsonStringField("media_type", artifact.mediaType),
        jsonLongField("bytes", cast(long) artifact.bytes),
    ]);
}

unittest
{
    import std.file : read, rmdirRecurse, tempDir, write;

    auto root = buildPath(tempDir(), "wheatley-user-image-" ~ randomUUID().toString());
    scope(exit) if (exists(root)) rmdirRecurse(root);
    auto upload = buildPath(root, "upload");
    mkdirRecurse(root);
    write(upload, cast(ubyte[]) [1, 2, 3]);
    ServerConfig config;
    config.profilesRoot = buildPath(root, "profiles");
    auto saved = persistUploadedUserImage(
        config,
        "tester",
        "submission-a",
        upload,
        "Photo žužu.webp",
        "image/webp",
    );
    auto loaded = loadStagedUserImage(config, "tester", "submission-a");
    assert(loaded.filename == saved.filename);
    assert(loaded.mediaType == "image/webp");
    assert(loaded.bytes == 3);
    assert(loaded.stagedPath == saved.stagedPath);
    assert(read(loaded.stagedPath) == cast(ubyte[]) [1, 2, 3]);
}
