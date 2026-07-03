const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;
const DecodedC = decoder.DecodedC;

pub fn decode(bytes: []const u8, allocator: std.mem.Allocator) Decoded {
    // Check if the file is binary. A simple heuristic: count null bytes or non-printable chars.
    var null_count: usize = 0;
    for (bytes) |b| {
        if (b == 0) {
            null_count += 1;
        }
    }

    if (null_count > 0 or !std.unicode.utf8ValidateSlice(bytes)) {
        // If it's not valid UTF-8, return an error.
        allocator.free(bytes);
        const msg = allocator.dupe(u8, "Formato non riconosciuto o file binario non UTF-8.") catch "File binario non supportato";
        return .{ .err = msg };
    }

    return .{ .text = bytes };
}

export fn zuer_decode(
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
const extensions = "txt,text,log,nfo,rst,adoc,asciidoc,org,tex,bib,srt,vtt,diff,patch," ++
    "json,jsonl,ndjson,yaml,yml,toml,ini,cfg,conf,properties,env,plist,editorconfig,gitignore,gitattributes,lock," ++
    "xml,html,htm,xhtml,css,scss,sass,less," ++
    "sh,bash,zsh,fish,ps1,bat,cmd,mk,make,cmake,gradle,dockerfile," ++
    "rs,py,pyi,js,mjs,cjs,jsx,ts,tsx,c,h,cc,cpp,cxx,hpp,hh,cs,java,kt,kts,go,rb,php,swift,scala,lua,pl,pm,r,sql,dart,ex,exs,erl,hrl,hs,clj,cljs,vim,asm,s,zig,jl,nim,proto,graphql,gql";

export fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}
