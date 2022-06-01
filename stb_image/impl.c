
#define STBI_MALLOC userMalloc
#define STBI_REALLOC userRealloc
#define STBI_FREE userFree

#include <stdlib.h>
void *userMalloc(size_t size);
void *userRealloc(void *ptr, size_t size);
void userFree(void *ptr);

#define STB_IMAGE_IMPLEMENTATION
#include <stb_image.h>
