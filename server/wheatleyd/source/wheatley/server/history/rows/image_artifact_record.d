module wheatley.server.history.rows.image_artifact_record;

struct UserImageArtifactRecord
{
    string filename;
    string mediaType;
    string stagedPath;
    string stagedManifestPath;
    ulong bytes;
}
