//! Il poco Java che serve a un'app NativeActivity, chiamato via JNI dal thread nativo.
//!
//! L'APK non ha `classes.dex` (`hasCode="false"`): non possiamo scrivere codice Java, ma
//! possiamo *chiamarlo*. Due cose vivono solo lassù e ci servono entrambe:
//!
//!   1. **Fullscreen immersivo** — nascondere status bar e barra di navigazione è una
//!      proprietà della View, non della surface: `setSystemUiVisibility` con i flag
//!      IMMERSIVE_STICKY (le barre riappaiono col swipe e si ritirano da sole).
//!   2. **Accesso ai file** — da Android 11 leggere file NON multimediali fuori dalla
//!      sandbox richiede MANAGE_EXTERNAL_STORAGE ("Accesso a tutti i file"): un permesso
//!      che non si concede col dialogo runtime, ma mandando l'utente alla schermata di
//!      sistema. Senza, un file manager vede solo la propria cartella.
//!
//! Gli header JNI/NDK sono @cImport-ati (a differenza del resto dello stack zicro, che
//! dichiara la FFI a mano): qui la superficie è larga e generata, e il sysroot del NDK è
//! comunque già nel percorso di include della build Android.

const std = @import("std");

pub const c = @cImport({
    @cInclude("jni.h");
    @cInclude("android/native_activity.h");
    @cInclude("android/bitmap.h"); // libjnigraphics: i pixel di un android.graphics.Bitmap
});

/// Chiama un metodo JNI gestendo l'eccezione Java che potrebbe lasciare pendente: una
/// eccezione non ripulita fa abortire il processo alla prossima chiamata JNI, con un
/// crash che non somiglia per niente alla sua causa.
fn clearException(env: *c.JNIEnv) void {
    const fns = env.*.*;
    if (fns.ExceptionCheck.?(env) != 0) {
        fns.ExceptionDescribe.?(env); // finisce in logcat: utile a capire cosa è saltato
        fns.ExceptionClear.?(env);
    }
}

/// Il thread che chiama `android_main` è nativo e la JVM non lo conosce: va agganciato
/// per poter usare JNI. Idempotente (una seconda Attach sullo stesso thread è un no-op).
fn attach(activity: *c.ANativeActivity) ?*c.JNIEnv {
    var env: ?*c.JNIEnv = null;
    const vm = activity.vm orelse return null;
    const vm_fns = vm.*.*;
    if (vm_fns.AttachCurrentThread.?(vm, @ptrCast(&env), null) != 0) return null;
    return env;
}

/// Fullscreen immersivo (status bar + barra di navigazione nascoste, contenuto sotto il
/// notch). I flag sono quelli di `View`: il valore combinato equivale a
/// IMMERSIVE_STICKY | HIDE_NAVIGATION | FULLSCREEN | LAYOUT_STABLE |
/// LAYOUT_HIDE_NAVIGATION | LAYOUT_FULLSCREEN.
pub fn goFullscreen(activity_ptr: *anyopaque) void {
    const activity: *c.ANativeActivity = @ptrCast(@alignCast(activity_ptr));

    // Prima il flag di finestra: `ANativeActivity_setWindowFlags` è pensata per essere
    // chiamata dal thread nativo (la posta lei al thread UI) e da sola toglie la status
    // bar, allargando la surface a tutto lo schermo. La chiamata JNI qui sotto aggiunge
    // l'immersivo (barra di navigazione) ma è più fragile — se fallisce, questa regge.
    // Costanti di window.h (enum anonime: non arrivano dal @cImport, si ridichiarano).
    // FULLSCREEN da solo NASCONDE la status bar ma NON allarga la finestra: resterebbe una
    // banda nera dove la barra stava. LAYOUT_IN_SCREEN + LAYOUT_NO_LIMITS estendono la
    // finestra a tutto il display — è la coppia che rende il fullscreen davvero pieno.
    const AWINDOW_FLAG_FULLSCREEN: u32 = 0x0000_0400;
    const AWINDOW_FLAG_LAYOUT_IN_SCREEN: u32 = 0x0000_0100;
    const AWINDOW_FLAG_LAYOUT_NO_LIMITS: u32 = 0x0000_0200;
    c.ANativeActivity_setWindowFlags(
        activity,
        AWINDOW_FLAG_FULLSCREEN | AWINDOW_FLAG_LAYOUT_IN_SCREEN | AWINDOW_FLAG_LAYOUT_NO_LIMITS,
        0,
    );

    const env = attach(activity) orelse return;
    const fns = env.*.*;

    const flags: c.jint = 0x1000 | 0x0002 | 0x0004 | 0x0100 | 0x0200 | 0x0400;

    // activity.getWindow().getDecorView().setSystemUiVisibility(flags)
    const activity_cls = fns.GetObjectClass.?(env, activity.clazz) orelse return;
    const get_window = fns.GetMethodID.?(env, activity_cls, "getWindow", "()Landroid/view/Window;") orelse return;
    const window = fns.CallObjectMethod.?(env, activity.clazz, get_window) orelse {
        clearException(env);
        return;
    };
    const window_cls = fns.GetObjectClass.?(env, window) orelse return;
    const get_decor = fns.GetMethodID.?(env, window_cls, "getDecorView", "()Landroid/view/View;") orelse return;
    const decor = fns.CallObjectMethod.?(env, window, get_decor) orelse {
        clearException(env);
        return;
    };
    const view_cls = fns.GetObjectClass.?(env, decor) orelse return;
    const set_vis = fns.GetMethodID.?(env, view_cls, "setSystemUiVisibility", "(I)V") orelse return;
    fns.CallVoidMethod.?(env, decor, set_vis, flags);
    clearException(env);
}

/// True se abbiamo già l'accesso a tutti i file (`Environment.isExternalStorageManager()`).
/// Sotto Android 11 il metodo non esiste: là il vecchio permesso di lettura basta e la
/// GetStaticMethodID fallisce → trattiamo l'assenza come "concesso" (nessuna schermata
/// da aprire, e comunque il vecchio modello di storage non lo richiede).
pub fn hasAllFilesAccess(activity_ptr: *anyopaque) bool {
    const activity: *c.ANativeActivity = @ptrCast(@alignCast(activity_ptr));
    const env = attach(activity) orelse return false;
    const fns = env.*.*;

    const env_cls = fns.FindClass.?(env, "android/os/Environment") orelse {
        clearException(env);
        return false;
    };
    const mid = fns.GetStaticMethodID.?(env, env_cls, "isExternalStorageManager", "()Z") orelse {
        clearException(env); // pre-Android 11: metodo assente
        return true;
    };
    const granted = fns.CallStaticBooleanMethod.?(env, env_cls, mid) != 0;
    clearException(env);
    return granted;
}

/// Apre la schermata di sistema "Accesso a tutti i file" per la nostra app. Non è un
/// dialogo: l'utente concede il permesso e torna indietro da solo (al rientro
/// `hasAllFilesAccess` diventa true e l'explorer si ripopola).
pub fn requestAllFilesAccess(activity_ptr: *anyopaque) void {
    const activity: *c.ANativeActivity = @ptrCast(@alignCast(activity_ptr));
    const env = attach(activity) orelse return;
    const fns = env.*.*;

    // Uri.parse("package:" + getPackageName())
    const activity_cls = fns.GetObjectClass.?(env, activity.clazz) orelse return;
    const get_pkg = fns.GetMethodID.?(env, activity_cls, "getPackageName", "()Ljava/lang/String;") orelse return;
    const pkg: c.jstring = @ptrCast(fns.CallObjectMethod.?(env, activity.clazz, get_pkg));
    const chars = fns.GetStringUTFChars.?(env, pkg, null) orelse return;
    var buf: [256]u8 = undefined;
    const uri_str = std.fmt.bufPrintZ(&buf, "package:{s}", .{std.mem.span(chars)}) catch "package:dev.zuer.viewer";
    fns.ReleaseStringUTFChars.?(env, pkg, chars);

    const jstr = fns.NewStringUTF.?(env, uri_str.ptr) orelse return;
    const uri_cls = fns.FindClass.?(env, "android/net/Uri") orelse return;
    const parse = fns.GetStaticMethodID.?(env, uri_cls, "parse", "(Ljava/lang/String;)Landroid/net/Uri;") orelse return;
    const uri = fns.CallStaticObjectMethod.?(env, uri_cls, parse, jstr) orelse {
        clearException(env);
        return;
    };

    // new Intent(ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION, uri)
    const action = fns.NewStringUTF.?(env, "android.settings.MANAGE_APP_ALL_FILES_ACCESS_PERMISSION") orelse return;
    const intent_cls = fns.FindClass.?(env, "android/content/Intent") orelse return;
    const ctor = fns.GetMethodID.?(env, intent_cls, "<init>", "(Ljava/lang/String;Landroid/net/Uri;)V") orelse return;
    const intent = fns.NewObject.?(env, intent_cls, ctor, action, uri) orelse {
        clearException(env);
        return;
    };

    const start = fns.GetMethodID.?(env, activity_cls, "startActivity", "(Landroid/content/Intent;)V") orelse return;
    fns.CallVoidMethod.?(env, activity.clazz, start, intent);
    clearException(env);
}

// ── Anteprime di sistema ───────────────────────────────────────────────────────
//
// Un telefono sa già decodificare tutto quello che sa riprodurre: MP3 con copertina, MP4,
// PDF, HEIC. Portarsi dietro ffmpeg per rifare quel lavoro sarebbe assurdo — pesa decine
// di MB, e il chip ha decoder hardware che il framework usa già. Quindi le anteprime che
// i decoder in Zig non coprono le chiediamo ad Android, con tre classi:
//
//   * `MediaMetadataRetriever` — copertina di un audio (i byte JPEG/PNG dentro il tag) e
//     fotogramma di un video.
//   * `PdfRenderer` — la prima pagina di un PDF, rasterizzata dal sistema.
//   * `BitmapFactory` — le immagini che stb_image non conosce (HEIC, AVIF, WEBP recenti).
//
// Tutte restituiscono un `android.graphics.Bitmap`, i cui pixel si leggono da nativo con
// `libjnigraphics` (AndroidBitmap_lockPixels): niente copia attraverso Java, niente array
// intermedi. Il formato RGBA_8888 di Android è byte per byte quello del nostro canvas.

/// Un'anteprima già in RGBA, di proprietà del chiamante.
pub const Image = struct {
    pixels: []u8,
    w: u32,
    h: u32,
};

/// Copia i pixel di un `android.graphics.Bitmap` in un buffer RGBA nostro.
fn bitmapToRgba(env: *c.JNIEnv, gpa: std.mem.Allocator, bmp: c.jobject) ?Image {
    var info: c.AndroidBitmapInfo = undefined;
    if (c.AndroidBitmap_getInfo(env, bmp, &info) != 0) return null;
    if (info.format != c.ANDROID_BITMAP_FORMAT_RGBA_8888) return null;

    var ptr: ?*anyopaque = null;
    if (c.AndroidBitmap_lockPixels(env, bmp, &ptr) != 0) return null;
    defer _ = c.AndroidBitmap_unlockPixels(env, bmp);
    const src: [*]const u8 = @ptrCast(ptr orelse return null);

    const w: u32 = info.width;
    const h: u32 = info.height;
    const out = gpa.alloc(u8, @as(usize, w) * h * 4) catch return null;
    // Lo stride del bitmap può eccedere la larghezza: si copia riga per riga, mai in blocco.
    var y: u32 = 0;
    while (y < h) : (y += 1) {
        const s = @as(usize, y) * info.stride;
        const d = @as(usize, y) * w * 4;
        @memcpy(out[d .. d + w * 4], src[s .. s + w * 4]);
    }
    return .{ .pixels = out, .w = w, .h = h };
}

/// Il fotogramma di apertura di un video (`MediaMetadataRetriever.getFrameAtTime`).
pub fn videoFrame(activity_ptr: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?Image {
    const activity: *c.ANativeActivity = @ptrCast(@alignCast(activity_ptr));
    const env = attach(activity) orelse return null;
    const fns = env.*.*;

    const mmr_cls = fns.FindClass.?(env, "android/media/MediaMetadataRetriever") orelse return null;
    const ctor = fns.GetMethodID.?(env, mmr_cls, "<init>", "()V") orelse return null;
    const mmr = fns.NewObject.?(env, mmr_cls, ctor) orelse {
        clearException(env);
        return null;
    };
    defer {
        if (fns.GetMethodID.?(env, mmr_cls, "release", "()V")) |rel| fns.CallVoidMethod.?(env, mmr, rel);
        clearException(env);
    }

    if (!setDataSource(env, mmr_cls, mmr, path)) return null;

    const get_frame = fns.GetMethodID.?(env, mmr_cls, "getFrameAtTime", "()Landroid/graphics/Bitmap;") orelse return null;
    const bmp = fns.CallObjectMethod.?(env, mmr, get_frame) orelse {
        clearException(env); // video senza tracce video, o codec assente: nessuna anteprima
        return null;
    };
    return bitmapToRgba(env, gpa, bmp);
}

/// I byte della copertina incorporata in un file audio (già JPEG/PNG: li decodifica stb,
/// che nella .so c'è già). null se il file non ne ha.
pub fn embeddedArt(activity_ptr: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?[]u8 {
    const activity: *c.ANativeActivity = @ptrCast(@alignCast(activity_ptr));
    const env = attach(activity) orelse return null;
    const fns = env.*.*;

    const mmr_cls = fns.FindClass.?(env, "android/media/MediaMetadataRetriever") orelse return null;
    const ctor = fns.GetMethodID.?(env, mmr_cls, "<init>", "()V") orelse return null;
    const mmr = fns.NewObject.?(env, mmr_cls, ctor) orelse {
        clearException(env);
        return null;
    };
    defer {
        if (fns.GetMethodID.?(env, mmr_cls, "release", "()V")) |rel| fns.CallVoidMethod.?(env, mmr, rel);
        clearException(env);
    }

    if (!setDataSource(env, mmr_cls, mmr, path)) return null;

    const get_pic = fns.GetMethodID.?(env, mmr_cls, "getEmbeddedPicture", "()[B") orelse return null;
    const arr: c.jbyteArray = @ptrCast(fns.CallObjectMethod.?(env, mmr, get_pic) orelse {
        clearException(env);
        return null;
    });
    const n: usize = @intCast(fns.GetArrayLength.?(env, arr));
    if (n == 0) return null;
    const out = gpa.alloc(u8, n) catch return null;
    fns.GetByteArrayRegion.?(env, arr, 0, @intCast(n), @ptrCast(out.ptr));
    clearException(env);
    return out;
}

/// `MediaMetadataRetriever.setDataSource(path)` — l'eccezione qui è la norma (file corrotto,
/// formato ignoto), quindi va ripulita e trattata come "nessuna anteprima".
fn setDataSource(env: *c.JNIEnv, cls: c.jclass, obj: c.jobject, path: []const u8) bool {
    const fns = env.*.*;
    var buf: [512]u8 = undefined;
    if (path.len >= buf.len) return false;
    const zpath = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return false;
    const jpath = fns.NewStringUTF.?(env, zpath.ptr) orelse return false;
    const set = fns.GetMethodID.?(env, cls, "setDataSource", "(Ljava/lang/String;)V") orelse return false;
    fns.CallVoidMethod.?(env, obj, set, jpath);
    if (fns.ExceptionCheck.?(env) != 0) {
        fns.ExceptionClear.?(env);
        return false;
    }
    return true;
}

/// La prima pagina di un PDF, rasterizzata da `android.graphics.pdf.PdfRenderer` (API 21+).
pub fn pdfPage(activity_ptr: *anyopaque, gpa: std.mem.Allocator, path: []const u8, max_px: u32) ?Image {
    const activity: *c.ANativeActivity = @ptrCast(@alignCast(activity_ptr));
    const env = attach(activity) orelse return null;
    const fns = env.*.*;

    // ParcelFileDescriptor.open(new File(path), MODE_READ_ONLY)
    var buf: [512]u8 = undefined;
    if (path.len >= buf.len) return null;
    const zpath = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return null;
    const jpath = fns.NewStringUTF.?(env, zpath.ptr) orelse return null;
    const file_cls = fns.FindClass.?(env, "java/io/File") orelse return null;
    const file_ctor = fns.GetMethodID.?(env, file_cls, "<init>", "(Ljava/lang/String;)V") orelse return null;
    const file = fns.NewObject.?(env, file_cls, file_ctor, jpath) orelse {
        clearException(env);
        return null;
    };
    const pfd_cls = fns.FindClass.?(env, "android/os/ParcelFileDescriptor") orelse return null;
    const open = fns.GetStaticMethodID.?(env, pfd_cls, "open", "(Ljava/io/File;I)Landroid/os/ParcelFileDescriptor;") orelse return null;
    const MODE_READ_ONLY: c.jint = 0x1000_0000;
    const pfd = fns.CallStaticObjectMethod.?(env, pfd_cls, open, file, MODE_READ_ONLY) orelse {
        clearException(env);
        return null;
    };

    // new PdfRenderer(pfd).openPage(0)
    const rnd_cls = fns.FindClass.?(env, "android/graphics/pdf/PdfRenderer") orelse {
        clearException(env);
        return null;
    };
    const rnd_ctor = fns.GetMethodID.?(env, rnd_cls, "<init>", "(Landroid/os/ParcelFileDescriptor;)V") orelse return null;
    const rnd = fns.NewObject.?(env, rnd_cls, rnd_ctor, pfd) orelse {
        clearException(env); // PDF cifrato o malformato
        return null;
    };
    defer {
        if (fns.GetMethodID.?(env, rnd_cls, "close", "()V")) |cl| fns.CallVoidMethod.?(env, rnd, cl);
        clearException(env);
    }
    const open_page = fns.GetMethodID.?(env, rnd_cls, "openPage", "(I)Landroid/graphics/pdf/PdfRenderer$Page;") orelse return null;
    const page = fns.CallObjectMethod.?(env, rnd, open_page, @as(c.jint, 0)) orelse {
        clearException(env);
        return null;
    };
    const page_cls = fns.GetObjectClass.?(env, page) orelse return null;
    defer {
        if (fns.GetMethodID.?(env, page_cls, "close", "()V")) |cl| fns.CallVoidMethod.?(env, page, cl);
        clearException(env);
    }

    // Il bitmap di destinazione: la pagina in punti (1/72"), scalata perché il lato lungo
    // stia in `max_px` — rasterizzare un A4 a 300 dpi per una miniatura sarebbe uno spreco.
    const get_w = fns.GetMethodID.?(env, page_cls, "getWidth", "()I") orelse return null;
    const get_h = fns.GetMethodID.?(env, page_cls, "getHeight", "()I") orelse return null;
    const pw: u32 = @intCast(@max(1, fns.CallIntMethod.?(env, page, get_w)));
    const ph: u32 = @intCast(@max(1, fns.CallIntMethod.?(env, page, get_h)));
    var bw = pw;
    var bh = ph;
    if (max_px > 0 and @max(pw, ph) > max_px) {
        const s = @as(f32, @floatFromInt(max_px)) / @as(f32, @floatFromInt(@max(pw, ph)));
        bw = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(pw)) * s)));
        bh = @max(1, @as(u32, @intFromFloat(@as(f32, @floatFromInt(ph)) * s)));
    }

    const bmp = createBitmap(env, bw, bh) orelse return null;
    const render = fns.GetMethodID.?(env, page_cls, "render", "(Landroid/graphics/Bitmap;Landroid/graphics/Rect;Landroid/graphics/Matrix;I)V") orelse return null;
    const RENDER_MODE_FOR_DISPLAY: c.jint = 1;
    fns.CallVoidMethod.?(env, page, render, bmp, @as(c.jobject, null), @as(c.jobject, null), RENDER_MODE_FOR_DISPLAY);
    if (fns.ExceptionCheck.?(env) != 0) {
        fns.ExceptionClear.?(env);
        return null;
    }
    return bitmapToRgba(env, gpa, bmp);
}

/// `Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)` — la pagina PDF va rasterizzata
/// dentro un bitmap che dobbiamo fornire noi (in memoria è RGBA byte per byte).
fn createBitmap(env: *c.JNIEnv, w: u32, h: u32) ?c.jobject {
    const fns = env.*.*;
    const bmp_cls = fns.FindClass.?(env, "android/graphics/Bitmap") orelse return null;
    const cfg_cls = fns.FindClass.?(env, "android/graphics/Bitmap$Config") orelse return null;
    const cfg_field = fns.GetStaticFieldID.?(env, cfg_cls, "ARGB_8888", "Landroid/graphics/Bitmap$Config;") orelse return null;
    const cfg = fns.GetStaticObjectField.?(env, cfg_cls, cfg_field) orelse return null;
    const create = fns.GetStaticMethodID.?(env, bmp_cls, "createBitmap", "(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;") orelse return null;
    const bmp = fns.CallStaticObjectMethod.?(env, bmp_cls, create, @as(c.jint, @intCast(w)), @as(c.jint, @intCast(h)), cfg) orelse {
        clearException(env);
        return null;
    };
    return bmp;
}

/// Le immagini che stb_image non conosce (HEIC, AVIF, WEBP animate, TIFF): le decodifica
/// `BitmapFactory`, che sul telefono passa dai decoder hardware.
pub fn decodeImageFile(activity_ptr: *anyopaque, gpa: std.mem.Allocator, path: []const u8) ?Image {
    const activity: *c.ANativeActivity = @ptrCast(@alignCast(activity_ptr));
    const env = attach(activity) orelse return null;
    const fns = env.*.*;

    var buf: [512]u8 = undefined;
    if (path.len >= buf.len) return null;
    const zpath = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return null;
    const jpath = fns.NewStringUTF.?(env, zpath.ptr) orelse return null;

    const bf_cls = fns.FindClass.?(env, "android/graphics/BitmapFactory") orelse return null;
    const decode = fns.GetStaticMethodID.?(env, bf_cls, "decodeFile", "(Ljava/lang/String;)Landroid/graphics/Bitmap;") orelse return null;
    const bmp = fns.CallStaticObjectMethod.?(env, bf_cls, decode, jpath) orelse {
        clearException(env);
        return null;
    };
    return bitmapToRgba(env, gpa, bmp);
}

/// Sgancia il thread corrente dalla JVM. **Obbligatorio** prima che un thread nativo che ha
/// chiamato JNI muoia: la ART aborta il processo con "native thread exited without calling
/// DetachCurrentThread". Chiamarla su un thread mai agganciato è innocuo.
pub fn detach(activity_ptr: *anyopaque) void {
    const activity: *c.ANativeActivity = @ptrCast(@alignCast(activity_ptr));
    const vm = activity.vm orelse return;
    const vm_fns = vm.*.*;
    _ = vm_fns.DetachCurrentThread.?(vm);
}

/// Il percorso con cui l'app è stata aperta: `getIntent().getData().getPath()`.
///
/// È il modo in cui un'app Android riceve "apri QUESTO": un file manager, un browser o un
/// `adb shell am start -d file:///…` passano un Uri, e chi lo apre siamo noi. null quando
/// l'app è stata lanciata dall'icona (allora si parte dalla memoria interna).
pub fn intentPath(activity_ptr: *anyopaque, gpa: std.mem.Allocator) ?[]u8 {
    const activity: *c.ANativeActivity = @ptrCast(@alignCast(activity_ptr));
    const env = attach(activity) orelse return null;
    const fns = env.*.*;

    const act_cls = fns.GetObjectClass.?(env, activity.clazz) orelse return null;
    const get_intent = fns.GetMethodID.?(env, act_cls, "getIntent", "()Landroid/content/Intent;") orelse return null;
    const intent = fns.CallObjectMethod.?(env, activity.clazz, get_intent) orelse {
        clearException(env);
        return null;
    };
    const intent_cls = fns.GetObjectClass.?(env, intent) orelse return null;
    const get_data = fns.GetMethodID.?(env, intent_cls, "getData", "()Landroid/net/Uri;") orelse return null;
    const uri = fns.CallObjectMethod.?(env, intent, get_data) orelse {
        clearException(env); // lancio dall'icona: nessun dato, ed è il caso normale
        return null;
    };
    const uri_cls = fns.GetObjectClass.?(env, uri) orelse return null;
    const get_path = fns.GetMethodID.?(env, uri_cls, "getPath", "()Ljava/lang/String;") orelse return null;
    const jpath: c.jstring = @ptrCast(fns.CallObjectMethod.?(env, uri, get_path) orelse {
        clearException(env);
        return null;
    });
    const chars = fns.GetStringUTFChars.?(env, jpath, null) orelse return null;
    defer fns.ReleaseStringUTFChars.?(env, jpath, chars);
    const path = std.mem.span(chars);
    if (path.len == 0) return null;
    return gpa.dupe(u8, path) catch null;
}
