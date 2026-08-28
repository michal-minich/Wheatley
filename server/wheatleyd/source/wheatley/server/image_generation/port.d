module wheatley.server.image_generation.port;

import wheatley.server.image_generation.types : ImageGenerationOutput, ImageGenerationRequest;

interface ImageGeneratorPort
{
    ImageGenerationOutput generate(ImageGenerationRequest request);
    bool healthy();
}
