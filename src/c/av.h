// libav (FFmpeg) per src/decoders/player.zig — e per src/audio_player.zig, che
// riusa questo modulo per condividere i tipi.
// Su Linux gli header sono in /usr/include (default search path); su Windows
// sono quelli vendorati, vedi LinkAv.headersOnly in build.zig.
#include "libavformat/avformat.h"
#include "libavcodec/avcodec.h"
#include "libavutil/imgutils.h"
// Decodifica hardware VAAPI: device context (hwcontext) e descrittori dei pixel
// format (per riconoscere i formati hw nel callback get_format).
#include "libavutil/hwcontext.h"
#include "libavutil/pixdesc.h"
#include "libswscale/swscale.h"
// Audio: resample → f32 interleaved e gestione dei channel layout.
#include "libswresample/swresample.h"
#include "libavutil/channel_layout.h"
#include "libavutil/opt.h"
