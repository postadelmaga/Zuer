// libmpv (render API OpenGL) + EGL + GL per src/decoders/mpv_video.zig.
// Header di sistema, già nel default include path su Linux.
#include "mpv/client.h"
#include "mpv/render.h"
#include "mpv/render_gl.h"
#include "EGL/egl.h"
#include "EGL/eglext.h"
// GL/gl.h da solo dichiara solo il core 1.1 (ABI storica) — le funzioni FBO
// (glGenFramebuffers e affini, core dal 3.0) sono comunque esportate da
// libGL.so di Mesa, ma servono i prototipi da glext.h per linkarle dirette.
#define GL_GLEXT_PROTOTYPES 1
#include "GL/gl.h"
#include "GL/glext.h"
#include "wayland-client.h"
