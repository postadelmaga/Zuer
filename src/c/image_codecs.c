/* Codec immagine compilati DENTRO il plugin decoder_image, su ogni piattaforma:
 *   - WebP con libwebp (dipendenza Zig `libwebp`, sorgenti ufficiali 1.5.0),
 *     incluso il primo fotogramma dei WebP animati (demux);
 *   - SVG con nanosvg (vendor/nanosvg), il ripiego quando `rsvg-convert` manca.
 * Interfaccia minima verso image.zig: pixel RGBA 8 bit NON premoltiplicati,
 * allocati con malloc e liberati con zuer_img_free. Ritorno 0 = riuscito. */
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "webp/decode.h"
#include "webp/demux.h"

#define NANOSVG_IMPLEMENTATION
#include "nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "nanosvgrast.h"

void zuer_img_free(void *p) { free(p); }

/* Decodifica direttamente in un buffer malloc (niente copia: un 4K RGBA sono
 * 33 MB): RGB se il bitstream non ha alfa, RGBA altrimenti. */
static int webp_into(const uint8_t *data, size_t len, int has_alpha, int w, int h, unsigned char **out, int *ch) {
    int c = has_alpha ? 4 : 3;
    size_t stride = (size_t)w * c, n = stride * (size_t)h;
    unsigned char *buf = (unsigned char *)malloc(n);
    if (!buf) return -2;
    uint8_t *r = has_alpha ? WebPDecodeRGBAInto(data, len, buf, n, (int)stride)
                           : WebPDecodeRGBInto(data, len, buf, n, (int)stride);
    if (!r) { free(buf); return -1; }
    *out = buf;
    *ch = c;
    return 0;
}

int zuer_webp_decode(const uint8_t *data, size_t len, int max_pixels, unsigned char **out, int *w, int *h, int *ch) {
    *out = NULL;
    WebPBitstreamFeatures f;
    if (WebPGetFeatures(data, len, &f) != VP8_STATUS_OK) return -1;
    if (f.width <= 0 || f.height <= 0 || (int64_t)f.width * f.height > max_pixels) return -3;
    if (!f.has_animation) {
        *w = f.width;
        *h = f.height;
        return webp_into(data, len, f.has_alpha, f.width, f.height, out, ch);
    }
    /* Animato: il primo fotogramma, come per le GIF. */
    WebPData wd = { data, len };
    WebPDemuxer *dmx = WebPDemux(&wd);
    if (!dmx) return -1;
    WebPIterator it;
    int rc = -1;
    if (WebPDemuxGetFrame(dmx, 1, &it)) {
        WebPBitstreamFeatures ff;
        if (WebPGetFeatures(it.fragment.bytes, it.fragment.size, &ff) == VP8_STATUS_OK &&
            ff.width > 0 && ff.height > 0 && (int64_t)ff.width * ff.height <= max_pixels) {
            *w = ff.width;
            *h = ff.height;
            rc = webp_into(it.fragment.bytes, it.fragment.size, 1, ff.width, ff.height, out, ch);
        }
        WebPDemuxReleaseIterator(&it);
    }
    WebPDemuxDelete(dmx);
    return rc;
}

/* `data` deve essere terminato da NUL e MODIFICABILE (nanosvg lo analizza sul
 * posto). Rasterizza dentro un box max_dim×max_dim mantenendo le proporzioni. */
int zuer_svg_rgba(char *data, int max_dim, unsigned char **out, int *w, int *h) {
    *out = NULL;
    NSVGimage *img = nsvgParse(data, "px", 96.0f);
    if (!img) return -1;
    float iw = img->width, ih = img->height;
    if (!(iw > 0 && ih > 0) || !img->shapes) { nsvgDelete(img); return -1; }
    float s = fminf((float)max_dim / iw, (float)max_dim / ih);
    int ow = (int)lroundf(iw * s), oh = (int)lroundf(ih * s);
    if (ow < 1) ow = 1;
    if (oh < 1) oh = 1;
    unsigned char *px = (unsigned char *)calloc((size_t)ow * oh, 4);
    NSVGrasterizer *r = px ? nsvgCreateRasterizer() : NULL;
    if (!r) { free(px); nsvgDelete(img); return -2; }
    nsvgRasterize(r, img, 0, 0, s, px, ow, oh, ow * 4);
    nsvgDeleteRasterizer(r);
    nsvgDelete(img);
    *out = px; *w = ow; *h = oh;
    return 0;
}
