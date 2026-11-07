/* Windows Imaging Component: il codec immagine DI SISTEMA di Windows, il ripiego
 * per i formati che stb_image/libwebp/nanosvg non coprono (TIFF, ICO particolari,
 * JPEG XR, DDS e, se le estensioni sono installate, HEIC/AVIF) — lo stesso ruolo
 * di ImageMagick su Linux e di ImageIO su macOS. Compilato solo per Windows.
 *
 * Pixel in uscita: RGBA 8 bit NON premoltiplicati, malloc (zuer_img_free).
 * Ritorno: 0 riuscito, -1 formato non riconosciuto/errore, -2 memoria,
 * -3 immagine oltre `max_pixels`, -4 COM/WIC non disponibili. */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <wincodec.h>
#include <stdint.h>
#include <stdlib.h>

/* GUID definiti qui: niente dipendenza da libuuid/windowscodecs per i simboli. */
static const GUID zCLSID_WICImagingFactory = {0xcacaf262, 0x9370, 0x4615, {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
static const GUID zIID_IWICImagingFactory = {0xec5ec8a9, 0xc395, 0x4314, {0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70}};
static const GUID zGUID_WICPixelFormat32bppRGBA = {0xf5c7ad2d, 0x6a8d, 0x43dd, {0xa7, 0xa8, 0xa2, 0x99, 0x35, 0x26, 0x1a, 0xe9}};

int zuer_wic_rgba(const uint8_t *data, size_t len, int max_pixels, unsigned char **out, int *w, int *h) {
    *out = NULL;
    if (len == 0 || len > 0x7fffffff) return -1;
    /* Il worker del plugin è un thread qualunque: MTA. Se il thread fosse già STA
     * (RPC_E_CHANGED_MODE) WIC funziona comunque, ma allora non tocca a noi
     * chiamare CoUninitialize. */
    HRESULT hi = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    int uninit = SUCCEEDED(hi);
    int rc = -1;
    IWICImagingFactory *fac = NULL;
    IWICStream *st = NULL;
    IWICBitmapDecoder *dec = NULL;
    IWICBitmapFrameDecode *fr = NULL;
    IWICFormatConverter *cv = NULL;

    if (FAILED(CoCreateInstance(&zCLSID_WICImagingFactory, NULL, CLSCTX_INPROC_SERVER, &zIID_IWICImagingFactory, (void **)&fac))) {
        rc = -4;
        goto done;
    }
    if (FAILED(IWICImagingFactory_CreateStream(fac, &st))) goto done;
    if (FAILED(IWICStream_InitializeFromMemory(st, (BYTE *)data, (DWORD)len))) goto done;
    if (FAILED(IWICImagingFactory_CreateDecoderFromStream(fac, (IStream *)st, NULL, WICDecodeMetadataCacheOnDemand, &dec))) goto done;
    if (FAILED(IWICBitmapDecoder_GetFrame(dec, 0, &fr))) goto done;
    UINT fw = 0, fh = 0;
    if (FAILED(IWICBitmapFrameDecode_GetSize(fr, &fw, &fh)) || fw == 0 || fh == 0) goto done;
    if ((int64_t)fw * fh > max_pixels) { rc = -3; goto done; }
    if (FAILED(IWICImagingFactory_CreateFormatConverter(fac, &cv))) goto done;
    if (FAILED(IWICFormatConverter_Initialize(cv, (IWICBitmapSource *)fr, &zGUID_WICPixelFormat32bppRGBA,
                                              WICBitmapDitherTypeNone, NULL, 0.0, WICBitmapPaletteTypeCustom))) goto done;
    size_t stride = (size_t)fw * 4, n = stride * fh;
    unsigned char *px = (unsigned char *)malloc(n);
    if (!px) { rc = -2; goto done; }
    if (FAILED(IWICFormatConverter_CopyPixels(cv, NULL, (UINT)stride, (UINT)n, px))) { free(px); goto done; }
    *out = px; *w = (int)fw; *h = (int)fh;
    rc = 0;
done:
    if (cv) IWICFormatConverter_Release(cv);
    if (fr) IWICBitmapFrameDecode_Release(fr);
    if (dec) IWICBitmapDecoder_Release(dec);
    if (st) IWICStream_Release(st);
    if (fac) IWICImagingFactory_Release(fac);
    if (uninit) CoUninitialize();
    return rc;
}
