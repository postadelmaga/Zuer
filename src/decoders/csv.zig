const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;

/// Come si è chiusa una cella: separatore, fine riga, fine buffer.
const Term = enum { delim, newline, eof };

const Cell = struct {
    text: []const u8,
    term: Term,
};

/// Estrae la cella che inizia a `i.*` e avanza `i.*` oltre il carattere che la
/// chiude. La cella è una SLICE DENTRO `bytes`: niente allocazione.
///
/// Le virgolette si tolgono compattando il testo IN PLACE dentro lo span della
/// cella stessa. È sempre lecito: togliere caratteri accorcia, quindi la testa
/// di scrittura non supera mai quella di lettura, e resta comunque dentro i
/// byte di QUESTA cella (le celle già emesse finiscono prima dell'inizio di
/// questa, che è a sua volta ≥ della loro testa di scrittura). Nel caso comune
/// — nessuna virgoletta — le due teste coincidono e non si copia nulla.
///
/// La semantica ricalca quella del vecchio parser byte-per-byte: le virgolette
/// aprono/chiudono ovunque nella cella (anche a metà: `a"b,c"d` → `ab,cd`),
/// dentro le virgolette `""` è una virgoletta letterale e separatore/fine riga
/// sono testo normale.
fn scanCell(bytes: []u8, i: *usize, delimiter: u8) Cell {
    const len = bytes.len;
    const start = i.*;
    var w = start; // testa di scrittura (compattazione in place)
    var p = start; // testa di lettura
    var in_quotes = false;
    var term: Term = .eof;

    // Fuori dalle virgolette sono speciali separatore, virgoletta e fine riga;
    // dentro, solo la virgoletta. Si salta da un carattere speciale al successivo
    // invece di ispezionare un byte alla volta.
    const specials = [_]u8{ delimiter, '"', '\n', '\r' };

    while (p < len) {
        const stop = if (in_quotes)
            std.mem.indexOfScalarPos(u8, bytes, p, '"') orelse len
        else
            std.mem.indexOfAnyPos(u8, bytes, p, &specials) orelse len;

        if (stop > p) {
            // Run di testo letterale: si ricopia solo se la compattazione ha già
            // arretrato la testa di scrittura.
            if (w != p) std.mem.copyForwards(u8, bytes[w .. w + (stop - p)], bytes[p..stop]);
            w += stop - p;
            p = stop;
        }
        if (p >= len) break;

        const c = bytes[p];
        if (c == '"') {
            if (in_quotes and p + 1 < len and bytes[p + 1] == '"') {
                bytes[w] = '"'; // `""` → una virgoletta letterale
                w += 1;
                p += 2;
                continue;
            }
            in_quotes = !in_quotes;
            p += 1;
            continue;
        }
        if (c == delimiter) {
            term = .delim;
            p += 1;
            break;
        }
        // `\r`, `\n` o `\r\n`: fine riga.
        term = .newline;
        p += if (c == '\r' and p + 1 < len and bytes[p + 1] == '\n') 2 else 1;
        break;
    }

    i.* = p;
    return .{ .text = bytes[start..w], .term = term };
}

/// Analizza un CSV/TSV. `bytes` passa di PROPRIETÀ a questa funzione e diventa
/// il `backing` del `CsvData` risultante: tutte le celle sono slice dentro di
/// lui (zero-copy) e vengono liberate in blocco da `CsvData.deinit`, che sul
/// `backing` non vuoto salta la free per-cella. Sui percorsi d'errore il buffer
/// viene liberato qui. Restano allocati solo i container di righe e intestazioni.
pub fn decode(bytes: []u8, delimiter: u8, allocator: std.mem.Allocator) Decoded {
    var rows = std.ArrayList([][]const u8).empty;
    var current_row = std.ArrayList([]const u8).empty;

    // Nessuna cella è allocata a sé: in caso di uscita anticipata bastano i
    // container e il buffer di appoggio.
    var handed_over = false;
    defer if (!handed_over) {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
        current_row.deinit(allocator);
        allocator.free(bytes);
    };

    var i: usize = 0;
    while (i < bytes.len) {
        const cell = scanCell(bytes, &i, delimiter);
        current_row.append(allocator, cell.text) catch return .{ .err = "Out of memory" };
        switch (cell.term) {
            .delim => {}, // la riga continua
            .newline, .eof => {
                const row = current_row.toOwnedSlice(allocator) catch return .{ .err = "Out of memory" };
                rows.append(allocator, row) catch {
                    allocator.free(row);
                    return .{ .err = "Out of memory" };
                };
            },
        }
    }

    if (rows.items.len == 0) {
        const msg = allocator.dupe(u8, "Tabella CSV vuota.") catch "CSV vuoto";
        return .{ .err = msg };
    }

    // La prima riga sono le intestazioni.
    const headers = rows.orderedRemove(0);
    const final_rows = rows.toOwnedSlice(allocator) catch {
        allocator.free(headers);
        return .{ .err = "Out of memory" };
    };

    handed_over = true;
    current_row.deinit(allocator);
    return .{ .csv = .{
        .headers = headers,
        .rows = final_rows,
        .backing = bytes,
    } };
}

fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    _ = io_ptr;
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;

    const path_slice = path.toSlice();
    const content_slice = content.toSlice();

    var delimiter: u8 = ',';
    const filename = std.fs.path.basename(path_slice);
    if (std.mem.lastIndexOfScalar(u8, filename, '.')) |dot_index| {
        const ext = filename[dot_index + 1 ..];
        if (std.mem.eql(u8, ext, "tsv")) {
            delimiter = '\t';
        }
    }

    // Il contratto ABI (vedi `decoder.DecodeFn`) dà al plugin la PROPRIETÀ di
    // `content`, che l'host alloca sempre sull'heap con questo stesso allocator:
    // il buffer è quindi scrivibile, ed è lecito de-escapare le celle quotate
    // compattandole al suo interno. Il `const` è solo del layout C `SliceC`.
    const decoded = decode(@constCast(content_slice), delimiter, allocator);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

pub const extensions = "csv,tsv";

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
