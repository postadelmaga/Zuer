const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;
const DecodedC = decoder.DecodedC;

/// Riconosce se un buffer di byte appartiene a un file binario (es. eseguibili, immagini, archivi).
/// Analizza i primi byte (fino a 8KB) contando byte NULL e caratteri di controllo non stampabili.
fn isBinary(bytes: []const u8) bool {
    const sample_len = @min(bytes.len, 8192);
    if (sample_len == 0) return false;

    var null_count: usize = 0;
    var control_count: usize = 0;

    for (bytes[0..sample_len]) |b| {
        if (b == 0) {
            null_count += 1;
        } else if ((b < 0x09) or (b > 0x0D and b < 0x20 and b != 0x1B)) {
            control_count += 1;
        }
    }

    // Un file è considerato binario se nei primi 8KB ha più dell'1% di byte NULL (o >16 NULL),
    // oppure se la somma di byte NULL e caratteri di controllo supera il 10% del campione.
    if (null_count > sample_len / 100 or null_count > 16) return true;
    if ((null_count + control_count) > sample_len / 10) return true;

    return false;
}

/// Converte/sanifica una sequenza di byte in UTF-8 valido.
/// - Byte NULL (`0x00`) vengono sostituiti con uno spazio `' '`.
/// - Sequenze UTF-8 valide vengono mantenute intatte.
/// - Byte non UTF-8 (es. ISO-8859-1 / Windows-1252 come `è`, `à`, `°`) vengono convertiti in UTF-8.
pub fn sanitizeToUtf8(bytes: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        const b = bytes[i];
        if (b == 0) {
            try out.append(allocator, ' ');
            i += 1;
        } else if (b < 0x80) {
            try out.append(allocator, b);
            i += 1;
        } else {
            const seq_len = std.unicode.utf8ByteSequenceLength(b) catch 0;
            if (seq_len > 0 and i + seq_len <= bytes.len) {
                if (std.unicode.utf8ValidateSlice(bytes[i .. i + seq_len])) {
                    try out.appendSlice(allocator, bytes[i .. i + seq_len]);
                    i += seq_len;
                    continue;
                }
            }
            // Byte >= 0x80 non UTF-8 valido: converti da Latin-1 (ISO-8859-1) a UTF-8
            const c1: u8 = 0xC0 | (b >> 6);
            const c2: u8 = 0x80 | (b & 0x3F);
            try out.appendSlice(allocator, &.{ c1, c2 });
            i += 1;
        }
    }

    return out.toOwnedSlice(allocator);
}

pub fn decode(bytes: []const u8, allocator: std.mem.Allocator) Decoded {
    if (isBinary(bytes)) {
        allocator.free(bytes);
        return .{ .err = "Formato non riconosciuto o file binario non UTF-8." };
    }

    // Se è già UTF-8 valido e senza byte NULL, ritorna la slice originale senza allocazioni aggiuntive.
    if (!std.mem.containsAtLeast(u8, bytes, 1, &.{0}) and std.unicode.utf8ValidateSlice(bytes)) {
        return .{ .text = bytes };
    }

    // Altrimenti sanifica in UTF-8 (sostituisce NULL con spazi, converte ISO-8859-1/non-UTF8 in UTF-8)
    const sanitized = sanitizeToUtf8(bytes, allocator) catch {
        allocator.free(bytes);
        return .{ .err = "Impossibile allocare memoria per la sanificazione del testo." };
    };

    allocator.free(bytes);
    return .{ .text = sanitized };
}

fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) DecodedC {
    _ = path;
    _ = io_ptr;
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    const decoded = decode(content.toSlice(), allocator);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

// Estensioni testuali note (parità con viewer); il plugin "text" resta comunque
// il fallback dell'host per qualsiasi estensione non reclamata da altri plugin.
pub const extensions = "txt,text,log,nfo,rst,adoc,asciidoc,org,tex,bib,srt,vtt,diff,patch," ++
    "json,jsonl,ndjson,yaml,yml,toml,ini,cfg,conf,properties,env,plist,editorconfig,gitignore,gitattributes,lock," ++
    "xml,html,htm,xhtml,css,scss,sass,less," ++
    "sh,bash,zsh,fish,ps1,bat,cmd,mk,make,cmake,gradle,dockerfile," ++
    "rs,py,pyi,js,mjs,cjs,jsx,ts,tsx,c,h,cc,cpp,cxx,hpp,hh,cs,java,kt,kts,go,rb,php,swift,scala,lua,pl,pm,r,sql,dart,ex,exs,erl,hrl,hs,clj,cljs,vim,asm,s,zig,jl,nim,proto,graphql,gql";

fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}

/// Versione dell'ABI plugin con cui questo decoder è compilato: l'host la
/// confronta con la propria `decoder.abi_version` e scarta i mismatch.
fn zuer_abi_version() callconv(.c) u32 {
    return decoder.abi_version;
}

// Gli export dell'ABI plugin esistono solo dove i decoder SONO plugin (vedi
// decoder.plugin_abi): su Android sono linkati dentro l'unica libreria dell'APK e i loro
// nomi colliderebbero.
comptime {
    if (decoder.plugin_abi) {
        @export(&zuer_decode, .{ .name = "zuer_decode", .linkage = .strong });
        @export(&zuer_extensions, .{ .name = "zuer_extensions", .linkage = .strong });
        @export(&zuer_abi_version, .{ .name = "zuer_abi_version", .linkage = .strong });
    }
}
