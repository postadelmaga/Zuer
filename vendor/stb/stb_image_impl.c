/* Implementazione di stb_image compilata dentro libdecoder_image.so.
   Solo i formati raster comuni; niente stdio, si decodifica sempre da memoria. */
#define STB_IMAGE_IMPLEMENTATION
#define STBI_ONLY_PNG
#define STBI_ONLY_JPEG
#define STBI_ONLY_GIF
#define STBI_ONLY_BMP
#define STBI_NO_STDIO
#include "stb_image.h"
