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

/* Copia in un buffer malloc (WebPFree non è free su ogni build). */
static int webp_copy_out(uint8_t *px, int w, int h, unsigned char **out) {
    size_t n = (size_t)w * (size_t)h * 4;
    *out = (unsigned char *)malloc(n);
    if (!*out) { WebPFree(px); return -2; }
    memcpy(*out, px, n);
    WebPFree(px);
    return 0;
}

int zuer_webp_rgba(const uint8_t *data, size_t len, int max_pixels, unsigned char **out, int *w, int *h) {
    *out = NULL;
    WebPBitstreamFeatures f;
    if (WebPGetFeatures(data, len, &f) != VP8_STATUS_OK) return -1;
    if (f.width <= 0 || f.height <= 0 || (int64_t)f.width * f.height > max_pixels) return -3;
    if (!f.has_animation) {
        uint8_t *px = WebPDecodeRGBA(data, len, w, h);
        if (!px) return -1;
        return webp_copy_out(px, *w, *h, out);
    }
    /* Animato: il primo fotogramma, come per le GIF. */
    WebPData wd = { data, len };
    WebPDemuxer *dmx = WebPDemux(&wd);
    if (!dmx) return -1;
    WebPIterator it;
    int rc = -1;
    if (WebPDemuxGetFrame(dmx, 1, &it)) {
        uint8_t *px = WebPDecodeRGBA(it.fragment.bytes, it.fragment.size, w, h);
        if (px) rc = webp_copy_out(px, *w, *h, out);
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
