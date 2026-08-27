//! Plugin Office: documenti OOXML/OpenDocument. Sono archivi ZIP con l'XML
//! del contenuto dentro: si legge la central directory e si decomprime
//! l'entry giusta con la flate della std. Nessuna dipendenza esterna.
//!
//! - docx, pptx, odt, odp → estrazione testo (XML spogliato dai tag)
//! - xlsx, xlsm, ods → foglio attivo come tabella CSV
//!
//! Fogli xlsx PIGRI: si decodifica per intero SOLO il foglio attivo; degli altri
//! si tiene il nome (serve alla barra delle linguette) e i dati restano vuoti.
//! Il foglio attivo arriva nel frammento del percorso — `cartella.xlsx#sheet=N`,
//! N 1-based come il `#page=N` dei PDF — che l'host lascia passare fino al
//! plugin (vedi `decoder.decodeImpl`) e rilegge lui stesso per impostare
//! `WorkbookData.active`. Cliccare una linguetta senza dati riapre il documento
//! con il frammento del foglio scelto, esattamente come il cambio pagina PDF.
//! Chi consuma il documento intero e non ha linguette da cliccare (`zuer --json`)
//! può ripristinare la decodifica di tutti i fogli con `ZUER_XLSX_ALL_SHEETS=1`.

const std = @import("std");
const decoder = @import("decoder");
const Decoded = decoder.Decoded;

/// Foglio richiesto dal frammento `#sheet=N` del percorso (N 1-based). Null se
/// il frammento manca o non è un riferimento a foglio: allora si mostra il primo.
pub fn sheetFromPath(path: []const u8) ?usize {
    const hash = std.mem.indexOfScalar(u8, path, '#') orelse return null;
    const frag = path[hash + 1 ..];
    if (!std.mem.startsWith(u8, frag, "sheet=")) return null;
    const n = std.fmt.parseInt(usize, frag["sheet=".len..], 10) catch return null;
    return if (n == 0) null else n;
}

/// `filename` è il nome del file SENZA frammento (vedi `zuer_decode`);
/// `want_sheet` è il foglio 1-based da decodificare per intero (null = il primo).
pub fn decode(bytes: []const u8, filename: []const u8, want_sheet: ?usize, allocator: std.mem.Allocator) Decoded {
    defer allocator.free(bytes);

    // Central directory parsata una volta sola: tutte le letture di entry
    // successive sono lookup in memoria sulla stessa lista.
    const entries = parseCentralDirectory(bytes, allocator) catch |err| {
        return errMsg(allocator, "Archivio ZIP non valido: {s}", .{@errorName(err)});
    };
    defer allocator.free(entries);

    if (hasExtension(filename, ".xlsx") or hasExtension(filename, ".xlsm")) {
        return decodeXlsx(bytes, entries, want_sheet, allocator);
    }
    if (hasExtension(filename, ".ods")) {
        return decodeOds(bytes, entries, allocator);
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;

    const result = extract(bytes, entries, filename, allocator, w);
    if (result) {
        const text = out.toOwnedSlice() catch {
            const msg = allocator.dupe(u8, "Memoria esaurita durante l'estrazione.") catch "";
            return .{ .err = msg };
        };
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
            allocator.free(text);
            const msg = allocator.dupe(u8, "Il documento non contiene testo estraibile.") catch "";
            return .{ .err = msg };
        }
        return .{ .text = text };
    } else |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile estrarre il documento: {s}", .{@errorName(err)}) catch "";
        return .{ .err = msg };
    }
}

fn extract(bytes: []const u8, entries: []const ZipEntry, filename: []const u8, allocator: std.mem.Allocator, w: *std.Io.Writer) !void {
    if (hasExtension(filename, ".docx")) {
        const xml = try readZipEntry(bytes, entries, "word/document.xml", allocator);
        defer allocator.free(xml);
        try xmlToText(xml, w);
    } else if (hasExtension(filename, ".pptx")) {
        // Le slide sono entry numerate: ci si ferma alla prima mancante.
        //
        // Niente decodifica pigra qui, a differenza degli xlsx: una presentazione
        // diventa UN testo scorrevole (`Decoded.text`), non un modello a fogli con
        // le linguette, quindi non esiste una "slide attiva" da cui ripartire — la
        // vista mostra tutto insieme e servono tutte le slide in una volta. Il
        // costo si limita allora con un tetto esplicito: oltre `max_pptx_slides`
        // l'estrazione si ferma e lo dichiara in coda al testo, invece di
        // inflazionare centinaia di XML che nessuno scorrerà.
        var slide: usize = 1;
        while (slide <= max_pptx_slides) : (slide += 1) {
            var name_buf: [48]u8 = undefined;
            const entry_name = try std.fmt.bufPrint(&name_buf, "ppt/slides/slide{d}.xml", .{slide});
            const xml = readZipEntry(bytes, entries, entry_name, allocator) catch break;
            defer allocator.free(xml);
            try w.print("— Slide {d} —\n", .{slide});
            try xmlToText(xml, w);
            try w.writeAll("\n");
        }
        if (slide == 1) return error.NoSlidesFound;
        if (slide > max_pptx_slides) {
            var name_buf: [48]u8 = undefined;
            const next_name = try std.fmt.bufPrint(&name_buf, "ppt/slides/slide{d}.xml", .{max_pptx_slides + 1});
            if (findEntry(entries, next_name) != null)
                try w.print("— (oltre la slide {d}: contenuto non estratto) —\n", .{max_pptx_slides});
        }
    } else {
        // odt / odp
        const xml = try readZipEntry(bytes, entries, "content.xml", allocator);
        defer allocator.free(xml);
        try xmlToText(xml, w);
    }
}

fn hasExtension(filename: []const u8, comptime ext: []const u8) bool {
    if (filename.len < ext.len) return false;
    const tail = filename[filename.len - ext.len ..];
    for (tail, ext) |a, b| {
        if (std.ascii.toLower(a) != b) return false;
    }
    return true;
}

// --- ZIP -----------------------------------------------------------------

const eocd_sig = 0x06054b50;
const central_sig = 0x02014b50;
const local_sig = 0x04034b50;

/// Tetto sulle slide estratte da un pptx: oltre questa soglia il testo viene
/// troncato con una nota. Vedi il commento in `extract` per il perché non si
/// possa essere pigri come con i fogli xlsx.
const max_pptx_slides = 200;

fn readU16(bytes: []const u8, off: usize) u16 {
    return std.mem.readInt(u16, bytes[off..][0..2], .little);
}

fn readU32(bytes: []const u8, off: usize) u32 {
    return std.mem.readInt(u32, bytes[off..][0..4], .little);
}

/// Entry della central directory: il nome punta dentro `bytes` (nessuna copia).
const ZipEntry = struct {
    name: []const u8,
    method: u16,
    comp_size: usize,
    uncomp_size: usize,
    local_off: usize,
};

/// Analizza la central directory UNA volta sola in una lista di entry. I fogli
/// xlsx (fino a 256) e le slide pptx (fino a 500) si leggono poi con lookup in
/// memoria: riscandire EOCD + intera CD per ogni entry era O(entry × CD) sul
/// percorso di apertura. Il chiamante libera lo slice con `allocator.free`.
fn parseCentralDirectory(bytes: []const u8, allocator: std.mem.Allocator) ![]ZipEntry {
    if (bytes.len < 22) return error.NotAZipFile;

    // End Of Central Directory: si cerca all'indietro (può seguirlo un commento)
    var eocd: ?usize = null;
    const scan_start = if (bytes.len > 22 + 65535) bytes.len - 22 - 65535 else 0;
    var pos = bytes.len - 22;
    while (true) {
        if (readU32(bytes, pos) == eocd_sig) {
            eocd = pos;
            break;
        }
        if (pos == scan_start) break;
        pos -= 1;
    }
    const eocd_off = eocd orelse return error.NotAZipFile;

    const total_entries = readU16(bytes, eocd_off + 10);
    var cd_off: usize = readU32(bytes, eocd_off + 16);

    var entries: std.ArrayList(ZipEntry) = .empty;
    errdefer entries.deinit(allocator);

    var i: usize = 0;
    while (i < total_entries) : (i += 1) {
        if (cd_off + 46 > bytes.len or readU32(bytes, cd_off) != central_sig) return error.CorruptZip;
        const name_len: usize = readU16(bytes, cd_off + 28);
        const extra_len: usize = readU16(bytes, cd_off + 30);
        const comment_len: usize = readU16(bytes, cd_off + 32);
        if (cd_off + 46 + name_len > bytes.len) return error.CorruptZip;
        try entries.append(allocator, .{
            .name = bytes[cd_off + 46 .. cd_off + 46 + name_len],
            .method = readU16(bytes, cd_off + 10),
            .comp_size = readU32(bytes, cd_off + 20),
            .uncomp_size = readU32(bytes, cd_off + 24),
            .local_off = readU32(bytes, cd_off + 42),
        });
        cd_off += 46 + name_len + extra_len + comment_len;
    }
    return entries.toOwnedSlice(allocator);
}

/// Cerca un'entry per nome nella central directory già parsata, SENZA
/// decomprimerla: basta a sapere che un foglio/una slide esiste.
fn findEntry(entries: []const ZipEntry, wanted: []const u8) ?*const ZipEntry {
    for (entries) |*e| {
        if (std.mem.eql(u8, e.name, wanted)) return e;
    }
    return null;
}

/// Estrae e decomprime l'entry `wanted` cercandola nella lista già parsata.
/// Supporta i metodi stored (0) e deflate (8).
fn readZipEntry(bytes: []const u8, entries: []const ZipEntry, wanted: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const e = findEntry(entries, wanted) orelse return error.EntryNotFound;
    if (e.local_off + 30 > bytes.len or readU32(bytes, e.local_off) != local_sig) return error.CorruptZip;
    const l_name_len: usize = readU16(bytes, e.local_off + 26);
    const l_extra_len: usize = readU16(bytes, e.local_off + 28);
    const data_off = e.local_off + 30 + l_name_len + l_extra_len;
    if (data_off + e.comp_size > bytes.len) return error.CorruptZip;
    const comp = bytes[data_off .. data_off + e.comp_size];

    return switch (e.method) {
        0 => allocator.dupe(u8, comp),
        8 => inflateRaw(comp, e.uncomp_size, allocator),
        else => error.UnsupportedCompression,
    };
}

fn inflateRaw(comp: []const u8, uncomp_size: usize, allocator: std.mem.Allocator) ![]u8 {
    // Tetto di sicurezza contro dichiarazioni assurde nell'header ZIP
    if (uncomp_size > 512 * 1024 * 1024) return error.EntryTooLarge;

    var in: std.Io.Reader = .fixed(comp);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec = std.compress.flate.Decompress.init(&in, .raw, &window);

    const out = try allocator.alloc(u8, uncomp_size);
    errdefer allocator.free(out);
    try dec.reader.readSliceAll(out);
    return out;
}

// --- XML -------------------------------------------------------------------

/// Riduce l'XML al solo testo: i contenuti si accumulano, la chiusura di un
/// paragrafo (w:p per docx, a:p per pptx, text:p/text:h per ODF) va a capo.
fn xmlToText(xml: []const u8, w: *std.Io.Writer) !void {
    var i: usize = 0;
    while (i < xml.len) {
        const c = xml[i];
        if (c == '<') {
            const end = std.mem.indexOfScalarPos(u8, xml, i + 1, '>') orelse break;
            const tag = xml[i + 1 .. end];
            if (std.mem.eql(u8, tag, "/w:p") or
                std.mem.eql(u8, tag, "/a:p") or
                std.mem.eql(u8, tag, "/text:p") or
                std.mem.eql(u8, tag, "/text:h"))
            {
                try w.writeByte('\n');
            } else if (std.mem.eql(u8, tag, "w:br/") or std.mem.eql(u8, tag, "text:line-break/")) {
                try w.writeByte('\n');
            } else if (std.mem.eql(u8, tag, "w:tab/") or std.mem.eql(u8, tag, "text:tab/")) {
                try w.writeByte('\t');
            }
            i = end + 1;
        } else if (c == '&') {
            // Entity più comuni; le sconosciute passano letterali
            const entities = [_]struct { name: []const u8, ch: u8 }{
                .{ .name = "&amp;", .ch = '&' },
                .{ .name = "&lt;", .ch = '<' },
                .{ .name = "&gt;", .ch = '>' },
                .{ .name = "&quot;", .ch = '"' },
                .{ .name = "&apos;", .ch = '\'' },
            };
            var matched = false;
            for (entities) |e| {
                if (std.mem.startsWith(u8, xml[i..], e.name)) {
                    try w.writeByte(e.ch);
                    i += e.name.len;
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                try w.writeByte(c);
                i += 1;
            }
        } else {
            try w.writeByte(c);
            i += 1;
        }
    }
}

// --- Fogli di calcolo -------------------------------------------------------

const max_sheet_rows = 100_000;
const max_sheet_cols = 1024;

fn errMsg(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Decoded {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "";
    return .{ .err = msg };
}

const RowsBuilder = struct {
    rows: std.ArrayList([][]const u8) = .empty,

    fn deinitAll(self: *RowsBuilder, allocator: std.mem.Allocator) void {
        for (self.rows.items) |row| {
            for (row) |cell| allocator.free(cell);
            allocator.free(row);
        }
        self.rows.deinit(allocator);
    }

    /// Consuma le righe accumulate in un CsvData (prima riga = intestazioni).
    fn toCsv(self: *RowsBuilder, allocator: std.mem.Allocator) Decoded {
        if (self.rows.items.len == 0) {
            self.rows.deinit(allocator);
            const msg = allocator.dupe(u8, "Foglio di calcolo vuoto.") catch "";
            return .{ .err = msg };
        }
        const headers = self.rows.orderedRemove(0);
        const final_rows = self.rows.toOwnedSlice(allocator) catch {
            for (headers) |h| allocator.free(h);
            allocator.free(headers);
            return .{ .err = allocator.dupe(u8, "Memoria esaurita.") catch "" };
        };
        return .{ .csv = .{ .headers = headers, .rows = final_rows } };
    }
};

/// Decodifica le entity XML di `text` in `w` (nessun tag atteso all'interno).
fn appendXmlText(w: *std.Io.Writer, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '&') {
            const entities = [_]struct { name: []const u8, ch: u8 }{
                .{ .name = "&amp;", .ch = '&' },
                .{ .name = "&lt;", .ch = '<' },
                .{ .name = "&gt;", .ch = '>' },
                .{ .name = "&quot;", .ch = '"' },
                .{ .name = "&apos;", .ch = '\'' },
            };
            var matched = false;
            for (entities) |e| {
                if (std.mem.startsWith(u8, text[i..], e.name)) {
                    try w.writeByte(e.ch);
                    i += e.name.len;
                    matched = true;
                    break;
                }
            }
            if (!matched) {
                try w.writeByte(text[i]);
                i += 1;
            }
        } else {
            try w.writeByte(text[i]);
            i += 1;
        }
    }
}

fn xmlTextDupe(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try appendXmlText(&out.writer, text);
    return out.toOwnedSlice();
}

/// Trova la prossima occorrenza del tag `name` (aperto: `<name ` / `<name>` /
/// `<name/>`) a partire da `from`. Restituisce l'indice del `<`.
fn findTag(xml: []const u8, from: usize, comptime name: []const u8) ?usize {
    var pos = from;
    while (std.mem.indexOfPos(u8, xml, pos, "<" ++ name)) |at| {
        const after = at + 1 + name.len;
        if (after >= xml.len) return null;
        const c = xml[after];
        if (c == ' ' or c == '>' or c == '/') return at;
        pos = after;
    }
    return null;
}

/// Valore dell'attributo `name="…"` dentro il tag di apertura `tag`.
fn attrValue(tag: []const u8, comptime name: []const u8) ?[]const u8 {
    const needle = " " ++ name ++ "=\"";
    const at = std.mem.indexOf(u8, tag, needle) orelse return null;
    const vstart = at + needle.len;
    const vend = std.mem.indexOfScalarPos(u8, tag, vstart, '"') orelse return null;
    return tag[vstart..vend];
}

/// Colonna 0-based da un riferimento cella A1 ("BC12" → 54).
fn colFromRef(ref: []const u8) ?usize {
    var col: usize = 0;
    var letters: usize = 0;
    for (ref) |c| {
        if (c >= 'A' and c <= 'Z') {
            // Excel arriva a XFD (3 lettere): oltre 4 il riferimento non è
            // plausibile e col*26 finirebbe in overflow su input ostili.
            letters += 1;
            if (letters > 4) return null;
            col = col * 26 + (c - 'A' + 1);
        } else break;
    }
    if (letters == 0 or col == 0) return null;
    return col - 1;
}

const max_sheets = 256;

/// Slice vuoti STATICI per i fogli non ancora decodificati: di loro si tiene
/// solo il nome (per la linguetta) e la tabella resta vuota. `CsvData.deinit`
/// su una slice di lunghezza 0 non chiama l'allocator, quindi non c'è nulla da
/// possedere e nulla da liberare.
var no_headers: [0][]const u8 = .{};
var no_rows: [0][][]const u8 = .{};

/// Un foglio risolto ma NON ancora decodificato: nome per la linguetta (preso
/// in prestito da `SheetRef`, o null → "Foglio N") e nome dell'entry ZIP da
/// decomprimere quando servirà davvero.
const SheetSlot = struct {
    name: ?[]const u8,
    target: []const u8,
};

// `getenv` è nella libc su tutte le piattaforme in cui questo plugin viene costruito.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// `ZUER_XLSX_ALL_SHEETS=1` disattiva la decodifica pigra e analizza TUTTI i
/// fogli in un colpo solo. Serve a chi consuma il documento intero e non ha
/// nessuna linguetta da cliccare — tipicamente `zuer --json`, che stampa i dati
/// di ogni foglio.
fn allSheetsRequested() bool {
    const raw = getenv("ZUER_XLSX_ALL_SHEETS") orelse return false;
    const v = std.mem.span(raw);
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Decomprime e analizza il foglio `target`. Tabella VUOTA (non un errore) se
/// l'entry manca, è illeggibile o il foglio non ha righe: le altre linguette
/// devono restare raggiungibili, e la vista mostra "(tabella vuota)".
fn parseSheetSlot(
    bytes: []const u8,
    entries: []const ZipEntry,
    target: []const u8,
    shared: []const []const u8,
    allocator: std.mem.Allocator,
) decoder.CsvData {
    const empty: decoder.CsvData = .{ .headers = &no_headers, .rows = &no_rows };
    const sheet_xml = readZipEntry(bytes, entries, target, allocator) catch return empty;
    defer allocator.free(sheet_xml);
    var d = parseSheetRows(sheet_xml, shared, allocator);
    switch (d) {
        .csv => |c| return c,
        else => {
            d.deinit(allocator);
            return empty;
        },
    }
}

/// xlsx/xlsm. Un solo foglio → tabella semplice (`.csv`); più fogli →
/// `.workbook` con le linguette. Ordine e nomi da `xl/workbook.xml`, entry dei
/// fogli risolte via `r:id` → `xl/_rels/workbook.xml.rels` (la numerazione dei
/// file sheetN.xml può essere sparsa dopo l'eliminazione di un foglio), testo
/// condiviso da `xl/sharedStrings.xml`. Senza rels → enumerazione legacy.
///
/// Si decomprime e si analizza SOLO il foglio `want_sheet` (1-based, null = il
/// primo): elencare i fogli costa due XML piccoli (workbook.xml + i rels) più
/// dei lookup in central directory, mentre inflate + parse di ogni foglio —
/// il grosso del lavoro, con un'allocazione per cella — si paga una volta sola,
/// per quello che si guarda davvero. Gli altri fogli restano con `rows`/
/// `headers` vuoti finché la GUI non li richiede con `percorso.xlsx#sheet=N`.
fn decodeXlsx(bytes: []const u8, entries: []const ZipEntry, want_sheet: ?usize, allocator: std.mem.Allocator) Decoded {
    // Riferimenti dei fogli nell'ordine di workbook.xml: nome + entry ZIP
    // risolta dalle relationship. Assenti → fallback legacy più sotto.
    var refs = std.ArrayList(SheetRef).empty;
    defer {
        for (refs.items) |r| {
            if (r.name) |n| allocator.free(n);
            if (r.target) |t| allocator.free(t);
        }
        refs.deinit(allocator);
    }
    readSheetRefs(bytes, entries, allocator, &refs);

    // Elenco dei fogli SENZA decomprimerne nessuno: nomi e target sono presi in
    // prestito da `refs` (percorso standard) o dai nomi di entry dentro `bytes`
    // (fallback legacy), quindi restano validi per tutta la funzione.
    var slots = std.ArrayList(SheetSlot).empty;
    defer slots.deinit(allocator);

    for (refs.items) |r| {
        if (slots.items.len >= max_sheets) break;
        const target = r.target orelse continue;
        // Un foglio dichiarato ma con entry assente nell'archivio non è
        // apribile: si salta subito, così gli indici delle linguette
        // corrispondono sempre a fogli davvero leggibili.
        if (findEntry(entries, target) == null) continue;
        slots.append(allocator, .{ .name = r.name, .target = target }) catch break;
    }

    // Fallback legacy: rels mancante/illeggibile o nessun foglio risolto →
    // enumerazione xl/worksheets/sheetN.xml come prima, nomi per posizione.
    if (slots.items.len == 0) {
        var idx: usize = 1;
        while (idx <= max_sheets) : (idx += 1) {
            var name_buf: [64]u8 = undefined;
            const wanted = std.fmt.bufPrint(&name_buf, "xl/worksheets/sheet{d}.xml", .{idx}) catch break;
            const e = findEntry(entries, wanted) orelse break; // foglio mancante → fine
            const nm: ?[]const u8 = if (idx - 1 < refs.items.len) refs.items[idx - 1].name else null;
            // `e.name` punta dentro `bytes`, non dentro `name_buf`: sopravvive al giro di loop.
            slots.append(allocator, .{ .name = nm, .target = e.name }) catch break;
        }
    }

    if (slots.items.len == 0) {
        return .{ .err = allocator.dupe(u8, "Nessun foglio leggibile nel file xlsx.") catch "" };
    }

    // Foglio da decodificare per intero: 1-based nel frammento, clampato al
    // primo se fuori range (frammento inventato o file cambiato sotto i piedi).
    const active: usize = blk: {
        const n = want_sheet orelse 1;
        break :blk if (n - 1 < slots.items.len) n - 1 else 0;
    };

    // Le stringhe condivise servono solo a chi analizza davvero un foglio.
    const shared_xml: ?[]u8 = readZipEntry(bytes, entries, "xl/sharedStrings.xml", allocator) catch null;
    defer if (shared_xml) |sx| allocator.free(sx);

    var shared = std.ArrayList([]const u8).empty;
    defer {
        for (shared.items) |s| allocator.free(s);
        shared.deinit(allocator);
    }
    if (shared_xml) |sx| {
        parseSharedStrings(sx, allocator, &shared) catch {
            return .{ .err = allocator.dupe(u8, "sharedStrings.xml non valido.") catch "" };
        };
    }

    if (slots.items.len == 1) {
        // Un foglio solo: tabella semplice, niente barra delle linguette. Qui un
        // foglio vuoto resta un ERRORE come prima — non c'è nessun'altra
        // linguetta da raggiungere, quindi non serve una tabella vuota.
        const sheet_xml = readZipEntry(bytes, entries, slots.items[0].target, allocator) catch {
            return .{ .err = allocator.dupe(u8, "Nessun foglio leggibile nel file xlsx.") catch "" };
        };
        defer allocator.free(sheet_xml);
        return parseSheetRows(sheet_xml, shared.items, allocator);
    }

    const decode_all = allSheetsRequested();

    var sheets = std.ArrayList(decoder.Sheet).empty;
    var handed_over = false;
    defer if (!handed_over) {
        for (sheets.items) |*s| s.deinit(allocator);
        sheets.deinit(allocator);
    };
    sheets.ensureTotalCapacityPrecise(allocator, slots.items.len) catch {
        return .{ .err = allocator.dupe(u8, "Memoria esaurita.") catch "" };
    };

    for (slots.items, 0..) |slot, i| {
        const nm = if (slot.name) |src|
            (allocator.dupe(u8, src) catch break)
        else
            (std.fmt.allocPrint(allocator, "Foglio {d}", .{i + 1}) catch break);
        // Porta dati solo il foglio attivo; degli altri resta il nome, e i loro
        // slice vuoti dicono alla GUI "non ancora caricato" (vedi input.zig).
        const data: decoder.CsvData = if (i == active or decode_all)
            parseSheetSlot(bytes, entries, slot.target, shared.items, allocator)
        else
            .{ .headers = &no_headers, .rows = &no_rows };
        sheets.appendAssumeCapacity(.{ .name = nm, .data = data });
    }

    if (sheets.items.len == 0) {
        return .{ .err = allocator.dupe(u8, "Memoria esaurita.") catch "" };
    }

    const owned = sheets.toOwnedSlice(allocator) catch {
        return .{ .err = allocator.dupe(u8, "Memoria esaurita.") catch "" };
    };
    handed_over = true;
    // `active` è già clampato a `slots`; un `break` per memoria esaurita può aver
    // reso `sheets` più corto, quindi si riclampa.
    return .{ .workbook = .{ .sheets = owned, .active = @min(active, owned.len - 1) } };
}

/// Riferimento a un foglio, nell'ordine in cui compare in `xl/workbook.xml`.
/// Entrambi i campi sono allocati e di proprietà del chiamante.
const SheetRef = struct {
    name: ?[]const u8, // null se il tag <sheet> non ha l'attributo name
    target: ?[]const u8, // path completo dell'entry ZIP; null se r:id non risolto
};

/// Legge i fogli da `xl/workbook.xml` (elemento `<sheet name="…" r:id="…"/>`)
/// e risolve ogni `r:id` nell'entry ZIP corrispondente tramite
/// `xl/_rels/workbook.xml.rels`. Fallimento non fatale: senza rels i target
/// restano null e il chiamante ricade sull'enumerazione legacy sheetN.xml.
fn readSheetRefs(bytes: []const u8, entries: []const ZipEntry, allocator: std.mem.Allocator, out: *std.ArrayList(SheetRef)) void {
    const wb = readZipEntry(bytes, entries, "xl/workbook.xml", allocator) catch return;
    defer allocator.free(wb);

    const rels: ?[]u8 = readZipEntry(bytes, entries, "xl/_rels/workbook.xml.rels", allocator) catch null;
    defer if (rels) |r| allocator.free(r);

    var pos: usize = 0;
    // findTag("sheet") non matcha `<sheets>` (il carattere dopo "sheet" è 's').
    while (findTag(wb, pos, "sheet")) |at| {
        if (out.items.len >= max_sheets) break;
        const open_end = std.mem.indexOfScalarPos(u8, wb, at, '>') orelse break;
        const tag = wb[at..open_end];

        const name: ?[]const u8 = if (attrValue(tag, "name")) |raw|
            (xmlTextDupe(allocator, raw) catch null)
        else
            null;

        var target: ?[]const u8 = null;
        if (rels) |rx| {
            if (ridValue(tag)) |rid| target = resolveRelTarget(rx, rid, allocator);
        }

        out.append(allocator, .{ .name = name, .target = target }) catch {
            if (name) |n| allocator.free(n);
            if (target) |t| allocator.free(t);
            break;
        };
        pos = open_end + 1;
    }
}

/// Valore dell'attributo `r:id` di un tag `<sheet>`. Il prefisso di namespace
/// non è garantito essere "r": in mancanza si accetta qualunque attributo che
/// termini in `:id` (parsing tollerante, coerente col resto del file).
fn ridValue(tag: []const u8) ?[]const u8 {
    if (attrValue(tag, "r:id")) |v| return v;
    const needle = ":id=\"";
    const at = std.mem.indexOf(u8, tag, needle) orelse return null;
    const vstart = at + needle.len;
    const vend = std.mem.indexOfScalarPos(u8, tag, vstart, '"') orelse return null;
    return tag[vstart..vend];
}

/// Cerca in `rels_xml` la `<Relationship Id="rid" Target="…"/>` e converte il
/// Target in path di entry ZIP. Restituisce una stringa allocata o null.
fn resolveRelTarget(rels_xml: []const u8, rid: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    var pos: usize = 0;
    // findTag("Relationship") non matcha il tag radice `<Relationships>`.
    while (findTag(rels_xml, pos, "Relationship")) |at| {
        const open_end = std.mem.indexOfScalarPos(u8, rels_xml, at, '>') orelse return null;
        const tag = rels_xml[at..open_end];
        pos = open_end + 1;
        const id = attrValue(tag, "Id") orelse continue;
        if (!std.mem.eql(u8, id, rid)) continue;
        const target = attrValue(tag, "Target") orelse return null;
        return zipPathFromTarget(target, allocator);
    }
    return null;
}

/// Converte il Target di una relationship in path di entry ZIP. Il Target è
/// relativo a `xl/` ("worksheets/sheet3.xml") oppure assoluto ("/xl/…");
/// `../` risale di una componente (oltre la prima uscirebbe dall'archivio →
/// null, senza crash). Restituisce una stringa allocata o null.
fn zipPathFromTarget(target: []const u8, allocator: std.mem.Allocator) ?[]const u8 {
    if (target.len == 0) return null;
    if (target[0] == '/') {
        if (target.len == 1) return null;
        return allocator.dupe(u8, target[1..]) catch null;
    }
    var rest = target;
    var ups: usize = 0;
    while (std.mem.startsWith(u8, rest, "../")) {
        rest = rest[3..];
        ups += 1;
    }
    // La base "xl/" ha una sola componente: più di un "../" non è risolvibile.
    if (rest.len == 0 or ups > 1) return null;
    if (ups == 1) return allocator.dupe(u8, rest) catch null;
    return std.fmt.allocPrint(allocator, "xl/{s}", .{rest}) catch null;
}

/// Analizza un singolo foglio (`xl/worksheets/sheetN.xml`) in `.csv` (prima riga
/// = intestazioni) usando le stringhe condivise `shared`. `.err` se vuoto.
fn parseSheetRows(sheet_xml: []const u8, shared: []const []const u8, allocator: std.mem.Allocator) Decoded {
    var builder = RowsBuilder{};
    errdefer builder.deinitAll(allocator);

    var pos: usize = 0;
    while (findTag(sheet_xml, pos, "row")) |r_at| {
        if (builder.rows.items.len >= max_sheet_rows) break;
        const open_end = std.mem.indexOfScalarPos(u8, sheet_xml, r_at, '>') orelse break;
        if (sheet_xml[open_end - 1] == '/') {
            // riga vuota auto-chiusa
            builder.rows.append(allocator, allocator.alloc([]const u8, 0) catch break) catch break;
            pos = open_end + 1;
            continue;
        }
        const r_end = std.mem.indexOfPos(u8, sheet_xml, open_end, "</row>") orelse break;
        const inner = sheet_xml[open_end + 1 .. r_end];

        var cells = std.ArrayList([]const u8).empty;
        errdefer {
            for (cells.items) |c| allocator.free(c);
            cells.deinit(allocator);
        }

        var cpos: usize = 0;
        while (findTag(inner, cpos, "c")) |c_at| {
            if (cells.items.len >= max_sheet_cols) break;
            const c_open_end = std.mem.indexOfScalarPos(u8, inner, c_at, '>') orelse break;
            const open_tag = inner[c_at..c_open_end];
            const self_closing = inner[c_open_end - 1] == '/';

            const col: usize = if (attrValue(open_tag, "r")) |ref|
                colFromRef(ref) orelse cells.items.len
            else
                cells.items.len;

            // celle mancanti tra l'ultima e questa → vuote
            while (cells.items.len < @min(col, max_sheet_cols)) {
                cells.append(allocator, allocator.dupe(u8, "") catch break) catch break;
            }

            var value: []const u8 = allocator.dupe(u8, "") catch break;
            if (!self_closing) {
                const c_end = std.mem.indexOfPos(u8, inner, c_open_end, "</c>") orelse {
                    allocator.free(value);
                    break;
                };
                const cell_inner = inner[c_open_end + 1 .. c_end];
                const cell_type = attrValue(open_tag, "t") orelse "";

                if (extractTagText(cell_inner, "v")) |raw| {
                    if (std.mem.eql(u8, cell_type, "s")) {
                        // indice nelle shared strings
                        if (std.fmt.parseInt(usize, raw, 10) catch null) |idx| {
                            if (idx < shared.len) {
                                allocator.free(value);
                                value = allocator.dupe(u8, shared[idx]) catch break;
                            }
                        }
                    } else {
                        allocator.free(value);
                        value = xmlTextDupe(allocator, raw) catch break;
                    }
                } else if (std.mem.eql(u8, cell_type, "inlineStr")) {
                    if (extractTagText(cell_inner, "t")) |raw| {
                        allocator.free(value);
                        value = xmlTextDupe(allocator, raw) catch break;
                    }
                }
                cpos = c_end + "</c>".len;
            } else {
                cpos = c_open_end + 1;
            }

            cells.append(allocator, value) catch {
                allocator.free(value);
                break;
            };
        }

        builder.rows.append(allocator, cells.toOwnedSlice(allocator) catch break) catch break;
        pos = r_end + "</row>".len;
    }

    return builder.toCsv(allocator);
}

/// Contenuto testuale del primo tag `name` dentro `xml` (senza decodifica entity).
fn extractTagText(xml: []const u8, comptime name: []const u8) ?[]const u8 {
    const at = findTag(xml, 0, name) orelse return null;
    const open_end = std.mem.indexOfScalarPos(u8, xml, at, '>') orelse return null;
    if (xml[open_end - 1] == '/') return null;
    const close = std.mem.indexOfPos(u8, xml, open_end, "</" ++ name ++ ">") orelse return null;
    return xml[open_end + 1 .. close];
}

/// Popola `out` con le stringhe condivise: ogni <si> concatena i suoi <t>.
fn parseSharedStrings(xml: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList([]const u8)) !void {
    var pos: usize = 0;
    while (findTag(xml, pos, "si")) |si_at| {
        const open_end = std.mem.indexOfScalarPos(u8, xml, si_at, '>') orelse break;
        const si_end = std.mem.indexOfPos(u8, xml, open_end, "</si>") orelse break;
        const inner = xml[open_end + 1 .. si_end];

        var buf: std.Io.Writer.Allocating = .init(allocator);
        defer buf.deinit();

        var tpos: usize = 0;
        while (findTag(inner, tpos, "t")) |t_at| {
            const t_open_end = std.mem.indexOfScalarPos(u8, inner, t_at, '>') orelse break;
            if (inner[t_open_end - 1] == '/') {
                tpos = t_open_end + 1;
                continue;
            }
            const t_end = std.mem.indexOfPos(u8, inner, t_open_end, "</t>") orelse break;
            try appendXmlText(&buf.writer, inner[t_open_end + 1 .. t_end]);
            tpos = t_end + "</t>".len;
        }

        try out.append(allocator, try buf.toOwnedSlice());
        pos = si_end + "</si>".len;
    }
}

/// ods: prima <table:table> di content.xml.
fn decodeOds(bytes: []const u8, entries: []const ZipEntry, allocator: std.mem.Allocator) Decoded {
    const content = readZipEntry(bytes, entries, "content.xml", allocator) catch |err| {
        return errMsg(allocator, "Impossibile leggere content.xml: {s}", .{@errorName(err)});
    };
    defer allocator.free(content);

    const table_at = findTag(content, 0, "table:table") orelse {
        return .{ .err = allocator.dupe(u8, "Nessuna tabella nel documento ODS.") catch "" };
    };
    const table_end = std.mem.indexOfPos(u8, content, table_at, "</table:table>") orelse content.len;
    const table = content[table_at..table_end];

    var builder = RowsBuilder{};
    errdefer builder.deinitAll(allocator);

    var pos: usize = 0;
    while (findTag(table, pos, "table:table-row")) |r_at| {
        if (builder.rows.items.len >= max_sheet_rows) break;
        const open_end = std.mem.indexOfScalarPos(u8, table, r_at, '>') orelse break;
        if (table[open_end - 1] == '/') {
            pos = open_end + 1;
            continue;
        }
        const r_end = std.mem.indexOfPos(u8, table, open_end, "</table:table-row>") orelse break;
        const inner = table[open_end + 1 .. r_end];

        var cells = std.ArrayList([]const u8).empty;
        errdefer {
            for (cells.items) |c| allocator.free(c);
            cells.deinit(allocator);
        }

        var cpos: usize = 0;
        while (nextOdsCell(inner, cpos, allocator)) |cell| {
            cpos = cell.next_pos;
            if (cells.items.len >= max_sheet_cols) break;

            // LibreOffice riempie la riga fino a 16k colonne con un'unica
            // cella vuota ripetuta: le ripetizioni vuote oltre poche unità
            // non portano informazione e si troncano.
            var repeat: usize = 1;
            if (attrValue(cell.open_tag, "table:number-columns-repeated")) |rep| {
                repeat = std.fmt.parseInt(usize, rep, 10) catch 1;
            }
            if (cell.text.len == 0 and repeat > 8) repeat = 1;
            repeat = @min(repeat, max_sheet_cols - cells.items.len);

            var r: usize = 0;
            while (r < repeat) : (r += 1) {
                const dup = allocator.dupe(u8, cell.text) catch break;
                cells.append(allocator, dup) catch {
                    allocator.free(dup);
                    break;
                };
            }
            allocator.free(cell.text);
        }

        // Le celle vuote in coda non portano informazione
        while (cells.items.len > 0 and cells.items[cells.items.len - 1].len == 0) {
            allocator.free(cells.pop().?);
        }

        builder.rows.append(allocator, cells.toOwnedSlice(allocator) catch break) catch break;
        pos = r_end + "</table:table-row>".len;
    }

    return builder.toCsv(allocator);
}

const OdsCell = struct {
    open_tag: []const u8,
    text: []const u8, // allocata, di proprietà del chiamante
    next_pos: usize,
};

fn nextOdsCell(inner: []const u8, from: usize, allocator: std.mem.Allocator) ?OdsCell {
    const plain_at = findTag(inner, from, "table:table-cell");
    const cov_at = findTag(inner, from, "table:covered-table-cell");
    // Prendi la più vicina tra cella normale e cella coperta
    const cell_at = if (plain_at != null and cov_at != null)
        @min(plain_at.?, cov_at.?)
    else
        plain_at orelse cov_at orelse return null;

    const open_end = std.mem.indexOfScalarPos(u8, inner, cell_at, '>') orelse return null;
    const open_tag = inner[cell_at..open_end];

    if (inner[open_end - 1] == '/') {
        const empty = allocator.dupe(u8, "") catch return null;
        return .{ .open_tag = open_tag, .text = empty, .next_pos = open_end + 1 };
    }

    const close_needle = "</table:table-cell>";
    const c_end = std.mem.indexOfPos(u8, inner, open_end, close_needle) orelse return null;
    const cell_inner = inner[open_end + 1 .. c_end];

    // Testo = contenuto dei <text:p>, uniti da spazio, tag interni ignorati
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    var first = true;
    var ppos: usize = 0;
    while (findTag(cell_inner, ppos, "text:p")) |p_at| {
        const p_open_end = std.mem.indexOfScalarPos(u8, cell_inner, p_at, '>') orelse break;
        if (cell_inner[p_open_end - 1] == '/') {
            ppos = p_open_end + 1;
            continue;
        }
        const p_end = std.mem.indexOfPos(u8, cell_inner, p_open_end, "</text:p>") orelse break;
        if (!first) buf.writer.writeByte(' ') catch break;
        first = false;
        stripTagsInto(&buf.writer, cell_inner[p_open_end + 1 .. p_end]) catch break;
        ppos = p_end + "</text:p>".len;
    }

    const text = buf.toOwnedSlice() catch return null;
    return .{ .open_tag = open_tag, .text = text, .next_pos = c_end + close_needle.len };
}

/// Testo di un frammento XML senza i tag, con entity decodificate.
fn stripTagsInto(w: *std.Io.Writer, xml: []const u8) !void {
    var i: usize = 0;
    while (i < xml.len) {
        if (xml[i] == '<') {
            const end = std.mem.indexOfScalarPos(u8, xml, i + 1, '>') orelse break;
            i = end + 1;
        } else {
            const next_tag = std.mem.indexOfScalarPos(u8, xml, i, '<') orelse xml.len;
            try appendXmlText(w, xml[i..next_tag]);
            i = next_tag;
        }
    }
}

export fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    _ = io_ptr;
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    const path_slice = path.toSlice();
    // Il percorso può portare un frammento (`cartella.xlsx#sheet=3`): l'host lo
    // lascia passare intatto. Va tolto prima di guardare l'estensione, altrimenti
    // `hasExtension` non riconoscerebbe più il formato.
    const want_sheet = sheetFromPath(path_slice);
    const clean_path = if (std.mem.indexOfScalar(u8, path_slice, '#')) |h| path_slice[0..h] else path_slice;
    const filename = std.fs.path.basename(clean_path);
    const decoded = decode(content.toSlice(), filename, want_sheet, allocator);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

pub const extensions = "docx,pptx,odt,odp,xlsx,xlsm,ods";

export fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}

/// Versione dell'ABI plugin con cui questo decoder è compilato: l'host la
/// confronta con la propria `decoder.abi_version` e scarta i mismatch.
export fn zuer_abi_version() callconv(.c) u32 {
    return decoder.abi_version;
}
