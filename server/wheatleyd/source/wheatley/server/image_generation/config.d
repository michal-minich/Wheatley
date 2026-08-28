module wheatley.server.image_generation.config;

import std.exception : enforce;

import wheatley.server.image_generation.types : ImageGenerationConfig, ImagePreset;
import wheatley.server.profiles.config_properties :
    ProfileConfigIndex,
    requiredConfigInt,
    requiredConfigText;

ImageGenerationConfig loadImageGenerationConfig(ProfileConfigIndex props)
{
    ImageGenerationConfig config;
    config.endpoint = requiredConfigText(props, "image_generation.endpoint");
    config.timeoutSeconds = cast(int) requiredConfigInt(
        props,
        "image_generation.request_timeout_seconds",
        1,
        3_600,
    );
    foreach (quality; ["low", "medium", "high"]) {
        foreach (aspect; ["square", "portrait", "landscape"]) {
            auto key = quality ~ "." ~ aspect;
            auto path = "image_generation.presets." ~ key;
            auto width = cast(int) requiredConfigInt(props, path ~ ".width", 256, 2_048);
            auto height = cast(int) requiredConfigInt(props, path ~ ".height", 256, 2_048);
            enforce(width % 16 == 0 && height % 16 == 0,
                "Image preset dimensions must be multiples of 16: " ~ path);
            final switch (aspect) {
                case "square": enforce(width == height, "Square image preset must be square: " ~ path); break;
                case "portrait": enforce(height > width, "Portrait image preset must be taller: " ~ path); break;
                case "landscape": enforce(width > height, "Landscape image preset must be wider: " ~ path); break;
            }
            config.presets[key] = ImagePreset(width, height);
        }
    }
    enforce(config.presets.length == 9, "Image generation must define nine presets");
    return config;
}

unittest
{
    import std.exception : assertThrown;
    import std.json : parseJSON;

    import wheatley.server.profiles.config_properties :
        flattenConfigProperties,
        indexProfileConfigProperties;

    auto valid = parseJSON(`{
      "image_generation": {
        "endpoint": "http://image-host:8790",
        "request_timeout_seconds": 600,
        "presets": {
          "low": {
            "square": {"width":512,"height":512},
            "portrait": {"width":416,"height":624},
            "landscape": {"width":624,"height":416}
          },
          "medium": {
            "square": {"width":1024,"height":1024},
            "portrait": {"width":832,"height":1248},
            "landscape": {"width":1248,"height":832}
          },
          "high": {
            "square": {"width":2048,"height":2048},
            "portrait": {"width":1376,"height":2048},
            "landscape": {"width":2048,"height":1376}
          }
        }
      }
    }`);
    auto config = loadImageGenerationConfig(indexProfileConfigProperties(
        flattenConfigProperties(valid),
    ));
    assert(config.presets.length == 9);
    assert(config.presets["medium.square"] == ImagePreset(1024, 1024));
    assert(config.presets["high.landscape"] == ImagePreset(2048, 1376));

    valid["image_generation"]["presets"]["low"]["portrait"]["width"] = 624;
    assertThrown!Exception(loadImageGenerationConfig(indexProfileConfigProperties(
        flattenConfigProperties(valid),
    )));
}
