//! La tabella dei formati: quale plugin apre quale estensione.
//!
//! È l'unica copia. Da qui vengono le estensioni che ogni plugin dichiara all'host
//! (`decoder.exportPlugin`), il manifest con cui l'host sceglie quale plugin caricare
//! senza aprirli tutti, e gli archivi di cui si può aprire una voce (fragment.zig).
//! Prima erano liste scritte a mano in ogni decoder e ricopiate in decoder.zig.
//!
//! In fondo stanno le liste con cui la GUI decide la forma della finestra PRIMA del
//! decode (`layout.winKindFromExt`). Non coincidono con la tabella — raggruppano per
//! forma, non per plugin, e contengono qualche eccezione voluta — ma un test le lega
//! a essa: un'estensione nuova o tolta di qui fa fallire il test finché non si decide
//! che forma ha.

const std = @import("std");
const builtin = @import("builtin");

pub const Entry = struct {
    /// Nome del plugin: `libdecoder_<plugin>.so`, `decoder_<plugin>.dll`.
    plugin: []const u8,
    /// Estensioni in minuscolo, separate da virgola, senza punto.
    exts: []const u8,
};

pub const plugins = [_]Entry{
    .{ .plugin = "text", .exts = "txt,text,log,nfo,rst,adoc,asciidoc,org,tex,bib,srt,vtt,diff,patch," ++
        "json,jsonl,ndjson,yaml,yml,toml,ini,cfg,conf,properties,env,plist,editorconfig,gitignore,gitattributes,lock," ++
        "xml,html,htm,xhtml,css,scss,sass,less," ++
        "sh,bash,zsh,fish,ps1,bat,cmd,mk,make,cmake,gradle,dockerfile," ++
        "rs,py,pyi,js,mjs,cjs,jsx,ts,tsx,c,h,cc,cpp,cxx,hpp,hh,cs,java,kt,kts,go,rb,php,swift,scala,lua,pl,pm,r,sql,dart,ex,exs,erl,hrl,hs,clj,cljs,vim,asm,s,zig,jl,nim,proto,graphql,gql" },
    // Oltre ai formati in processo, quelli del codec di sistema (ImageIO su macOS;
    // WIC o ImageMagick altrove, secondo i codec installati): HEIC, JPEG XL, JPEG
    // 2000, OpenEXR, DDS/KTX, ICNS e i RAW delle fotocamere.
    .{ .plugin = "image", .exts = "png,jpg,jpeg,jpe,jfif,gif,bmp,dib,tga,psd,hdr,pic,pnm,pbm,pgm,ppm,svg,svgz,webp,tif,tiff,ico,avif," ++
        "heic,heif,hif,jxl,jp2,j2k,jpf,jpx,exr,dds,ktx,astc,icns,pct,pict,sgi," ++
        "dng,cr2,cr3,crw,nef,nrw,arw,srf,sr2,orf,rw2,raf,pef,srw,x3f,erf,3fr,mos,mrw,dcr,kdc,rwl,iiq" },
    .{ .plugin = "media", .exts = "mp3,wav,w64,flac,ogg,oga,ogv,opus,m4a,m4b,mka,aac,ac3,eac3,dts,wma,aif,aiff,aifc,caf,amr,awb,wv,ape,mpc,tta," ++
        "mp4,m4v,mov,qt,mkv,webm,avi,divx,wmv,asf,flv,f4v,mpg,mpeg,mpe,m1v,m2v,vob,mts,m2ts,m2t,3gp,3g2,dv,mid,midi" },
    .{ .plugin = "csv", .exts = "csv,tsv" },
    .{ .plugin = "markdown", .exts = "md,markdown" },
    .{ .plugin = "archive", .exts = "zip,jar,apk,cbz,epub,xpi,whl" },
    .{ .plugin = "tar", .exts = "tar,tgz,tar.gz,7z,rar,xz,txz,bz2,tbz,tbz2,zst,tzst,lz,lzma,tlz,iso,cab,cpio,xar,pkg,rpm,lha,lzh" },
    .{ .plugin = "glb", .exts = "glb" },
    .{ .plugin = "mesh", .exts = "obj,stl" },
    // Su macOS anche i formati di `textutil`.
    .{ .plugin = "office", .exts = "docx,pptx,odt,odp,xlsx,xlsm,ods" ++ (if (builtin.os.tag == .macos) ",doc,dot,rtf,webarchive,wordml" else "") },
    .{ .plugin = "pdf", .exts = "pdf" },
};

/// Le estensioni di `plugin`, come le dichiara all'host.
pub fn extensionsOf(comptime plugin: []const u8) []const u8 {
    inline for (plugins) |p| {
        if (comptime std.mem.eql(u8, p.plugin, plugin)) return p.exts;
    }
    @compileError("formats.zig non conosce il plugin '" ++ plugin ++ "'");
}

/// Il plugin che apre `ext` (senza punto, maiuscole indifferenti), o null.
pub fn pluginFor(ext: []const u8) ?[]const u8 {
    for (&plugins) |*p| {
        var it = std.mem.tokenizeScalar(u8, p.exts, ',');
        while (it.next()) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return p.plugin;
        }
    }
    return null;
}

pub fn hasPlugin(name: []const u8) bool {
    for (&plugins) |*p| {
        if (std.mem.eql(u8, p.plugin, name)) return true;
    }
    return false;
}

// ── Forma della finestra per estensione ─────────────────────────────────────

pub const shape_image = [_][]const u8{ "png", "jpg", "jpeg", "gif", "bmp", "webp", "tif", "tiff", "avif", "heic", "heif", "jxl", "jp2", "exr", "ico", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2", "raf" };
pub const shape_mesh = [_][]const u8{ "obj", "stl", "glb", "gltf", "ply", "fbx", "dae", "3ds" };
pub const shape_video = [_][]const u8{ "mp4", "mkv", "webm", "mov", "qt", "avi", "divx", "m4v", "wmv", "asf", "flv", "f4v", "mpg", "mpeg", "mpe", "m1v", "m2v", "vob", "ts", "mts", "m2ts", "m2t", "3gp", "3g2", "ogv", "dv" };
/// Audio: stessa strada del player (`.video`), che senza traccia video ripiega
/// sull'oscilloscopio. mid/midi restano al loro synth, fuori da qui.
pub const shape_audio = [_][]const u8{ "mp3", "wav", "w64", "flac", "ogg", "oga", "opus", "m4a", "m4b", "mka", "aac", "ac3", "eac3", "dts", "wma", "aiff", "aif", "aifc", "caf", "amr", "awb", "wv", "ape", "mpc", "tta" };
pub const shape_table = [_][]const u8{ "csv", "tsv", "xlsx", "xls", "ods", "zip", "jar", "apk", "cbz", "epub", "xpi", "whl" };

/// Estensioni delle liste qui sopra che la tabella dei plugin non conferma, e perché.
const shape_exceptions = [_][]const u8{
    // Formati riconosciuti per la forma ma che nessun plugin apre.
    "gltf", "ply", "fbx", "dae", "3ds", "xls",
    // `.ts` è MPEG-TS per il player e TypeScript per il plugin `text`: il player
    // prova per primo, e se non è un video il decode per contenuto fa il resto.
    "ts",
};

test "nessuna estensione sta sotto due plugin" {
    for (&plugins, 0..) |*p, i| {
        var it = std.mem.tokenizeScalar(u8, p.exts, ',');
        while (it.next()) |e| {
            try std.testing.expect(e.len > 0);
            for (e) |ch| try std.testing.expect(!std.ascii.isUpper(ch));
            // Il primo plugin che la dichiara deve essere questo.
            const first = pluginFor(e).?;
            if (!std.mem.eql(u8, first, p.plugin)) {
                std.debug.print("'{s}' sta sotto '{s}' e sotto '{s}' (riga {d})\n", .{ e, first, p.plugin, i });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "pluginFor ed extensionsOf" {
    try std.testing.expectEqualStrings("csv", pluginFor("TSV").?);
    try std.testing.expectEqualStrings("tar", pluginFor("tar.gz").?);
    try std.testing.expectEqualStrings("media", pluginFor("Mp4").?);
    try std.testing.expect(pluginFor("") == null);
    try std.testing.expect(pluginFor("xyz") == null);
    try std.testing.expectEqualStrings("csv,tsv", comptime extensionsOf("csv"));
    try std.testing.expect(hasPlugin("pdf"));
    try std.testing.expect(!hasPlugin("gltf"));
}

test "le forme di finestra della GUI stanno alla tabella dei plugin" {
    const Check = struct {
        fn run(list: []const []const u8, allowed: []const []const u8) !void {
            for (list) |e| {
                const excepted = for (shape_exceptions) |x| {
                    if (std.mem.eql(u8, x, e)) break true;
                } else false;
                const got = pluginFor(e);
                const ok = if (got) |g| for (allowed) |a| {
                    if (std.mem.eql(u8, a, g)) break true;
                } else false else false;
                // Deve essere confermata dalla tabella, oppure essere un'eccezione
                // dichiarata — non le due cose insieme (eccezione rimasta in giro).
                if (ok == excepted) {
                    std.debug.print("'{s}': plugin {?s}, eccezione dichiarata: {}\n", .{ e, got, excepted });
                    return error.TestUnexpectedResult;
                }
            }
        }
    };
    try Check.run(&shape_image, &.{"image"});
    try Check.run(&shape_mesh, &.{ "mesh", "glb" });
    try Check.run(&shape_video, &.{"media"});
    try Check.run(&shape_audio, &.{"media"});
    try Check.run(&shape_table, &.{ "csv", "office", "archive" });
}
