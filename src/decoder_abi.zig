//! Il contratto fra host e plugin decoder: i tipi del risultato (`Decoded`), il loro
//! layout C (`DecodedC`) con i convertitori nelle due direzioni, la versione dell'ABI e
//! la colla che ogni plugin usa per esportare i propri simboli (`exportPlugin`).
//!
//! Sta in un file a sé perché è la parte che host e plugin devono leggere allo stesso
//! modo. Il registro dei plugin, il dispatch e l'estrazione dagli archivi stanno in
//! decoder.zig, che riesporta tutto ciò che è qui: chi importa `decoder` non cambia.

const std = @import("std");
const builtin = @import("builtin");
const formats = @import("formats.zig");

pub const CsvData = struct {
    headers: [][]const u8,
    rows: [][][]const u8,
    /// Buffer di appoggio POSSEDUTO da questa tabella. Due modelli di ownership,
    /// distinti proprio da questo campo:
    ///   - `backing.len == 0` (default): ogni cella è un'allocazione a sé e va
    ///     liberata una per una — è il caso dei fogli xlsx/ods, dove il testo
    ///     nasce da entity XML e stringhe condivise, quindi va comunque costruito.
    ///   - `backing.len > 0`: le celle sono SLICE DENTRO `backing` (zero-copy,
    ///     vedi decoders/csv.zig) e NON vanno liberate singolarmente: si libera
    ///     solo `backing`, una volta sola.
    /// Restano allocati a sé, in entrambi i casi, i container `headers`/`rows`.
    backing: []const u8 = &.{},

    pub fn deinit(self: *CsvData, allocator: std.mem.Allocator) void {
        if (self.backing.len == 0) {
            for (self.headers) |h| allocator.free(h);
            for (self.rows) |row| {
                for (row) |cell| allocator.free(cell);
            }
        }
        allocator.free(self.headers);
        for (self.rows) |row| allocator.free(row);
        allocator.free(self.rows);
        if (self.backing.len > 0) allocator.free(self.backing);
    }
};

/// Un singolo foglio di un workbook: nome (per la linguetta) + dati tabellari.
pub const Sheet = struct {
    name: []const u8,
    data: CsvData,

    pub fn deinit(self: *Sheet, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        self.data.deinit(allocator);
    }
};

/// Foglio di calcolo multi-foglio (xlsx con più sheet). Il foglio mostrato è
/// `active`, un indice di RUNTIME della GUI (non attraversa il confine C-ABI:
/// il plugin restituisce sempre tutti i fogli, la selezione è lato host).
pub const WorkbookData = struct {
    sheets: []Sheet,
    active: usize = 0,

    pub fn deinit(self: *WorkbookData, allocator: std.mem.Allocator) void {
        for (self.sheets) |*s| s.deinit(allocator);
        allocator.free(self.sheets);
    }

    /// Dati del foglio attivo (clampato: `active` è convalidato dalla GUI).
    pub fn activeCsv(self: *const WorkbookData) CsvData {
        return self.sheets[self.active].data;
    }
};

pub const MarkdownData = struct {
    content: []const u8,

    pub fn deinit(self: *MarkdownData, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const Face = struct {
    v1: usize,
    v2: usize,
    v3: usize,
};

/// Un sotto-mesh = un intervallo contiguo dell'index buffer con il proprio
/// materiale e la propria texture. I modelli glTF con più mesh/primitive/
/// materiali producono più submesh sulla stessa geometria fusa; il renderer
/// disegna ogni intervallo con la sua texture.
pub const SubMesh = struct {
    first_index: usize, // offset (in indici) nel buffer indici fuso
    index_count: usize, // numero di indici del submesh (3 × facce)
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
    metallic: f32 = 1.0,
    roughness: f32 = 1.0,
    tex_width: usize = 0,
    tex_height: usize = 0,
    tex_pixels: []const u8 = &.{},
    // Normal map tangent-space RGBA8 (dati lineari); vuota se assente.
    nrm_tex_width: usize = 0,
    nrm_tex_height: usize = 0,
    nrm_tex_pixels: []const u8 = &.{},
};

/// Libera le texture dei submesh tenendo conto della condivisione: i glTF
/// spesso riusano lo stesso atlas su molti submesh e il decoder li fa puntare
/// a UN solo buffer (niente N copie da decine di MB) — ogni puntatore va
/// quindi liberato una volta sola, alla sua prima occorrenza.
pub fn freeSubmeshTextures(subs: []const SubMesh, allocator: std.mem.Allocator) void {
    freeSubmeshTexturesOf(SubMesh, subs, allocator);
}

/// `T` è `SubMesh` o `SubMeshC`: stessi campi, e sia `[]const u8` sia `SliceC` hanno
/// `ptr` e `len`.
fn freeSubmeshTexturesOf(comptime T: type, subs: []const T, allocator: std.mem.Allocator) void {
    for (subs, 0..) |s, i| {
        if (s.tex_pixels.len > 0 and firstTexOccurrence(T, subs, i, false, s.tex_pixels.ptr))
            allocator.free(s.tex_pixels.ptr[0..s.tex_pixels.len]);
        if (s.nrm_tex_pixels.len > 0 and firstTexOccurrence(T, subs, i, true, s.nrm_tex_pixels.ptr))
            allocator.free(s.nrm_tex_pixels.ptr[0..s.nrm_tex_pixels.len]);
    }
}

/// True se (i, campo) è la prima occorrenza di `ptr` scandendo i submesh in
/// ordine (per ciascuno: prima baseColor, poi normal map).
fn firstTexOccurrence(comptime T: type, subs: []const T, i: usize, is_nrm: bool, ptr: [*]const u8) bool {
    for (subs[0 .. i + 1], 0..) |p, j| {
        if (p.tex_pixels.len > 0 and p.tex_pixels.ptr == ptr)
            return j == i and !is_nrm;
        if (p.nrm_tex_pixels.len > 0 and p.nrm_tex_pixels.ptr == ptr)
            return j == i and is_nrm;
    }
    return false;
}

pub const MeshData = struct {
    num_vertices: usize,
    num_faces: usize,
    num_normals: usize,
    bbox_min: [3]f32,
    bbox_max: [3]f32,
    center: [3]f32,
    name: []const u8,
    vertices: [][3]f32,
    faces: []Face,
    // Attributi opzionali (len 0 se assenti): normali autorali, UV e tangenti
    // autorali (vec4: xyz + handedness, per il normal mapping).
    normals: [][3]f32 = &.{},
    uvs: [][2]f32 = &.{},
    tangents: [][4]f32 = &.{},
    // Materiale PBR di fallback (glTF metallic-roughness), usato quando non ci
    // sono submesh (es. OBJ/STL). Default: bianco opaco, plastica.
    base_color: [4]f32 = .{ 1, 1, 1, 1 },
    metallic: f32 = 1.0,
    roughness: f32 = 1.0,
    // Texture baseColor di fallback RGBA8 (tex_width*tex_height*4); vuota se assente.
    tex_width: usize = 0,
    tex_height: usize = 0,
    tex_pixels: []const u8 = &.{},
    // Sotto-mesh per-materiale (vuoto = si usa il materiale/texture di fallback).
    submeshes: []SubMesh = &.{},

    pub fn deinit(self: *MeshData, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.vertices);
        allocator.free(self.faces);
        if (self.normals.len > 0) allocator.free(self.normals);
        if (self.uvs.len > 0) allocator.free(self.uvs);
        if (self.tangents.len > 0) allocator.free(self.tangents);
        if (self.tex_pixels.len > 0) allocator.free(self.tex_pixels);
        freeSubmeshTextures(self.submeshes, allocator);
        if (self.submeshes.len > 0) allocator.free(self.submeshes);
    }
};

pub const ImageData = struct {
    width: usize,
    height: usize,
    pixels: []const u8, // RGB 24-bit
    name: []const u8,
    // Numero totale di pagine del documento sorgente (PDF e simili), in forma
    // STRUTTURATA: la GUI lo usa per la navigazione PgUp/PgDown invece di
    // parsare la label di presentazione ("(pagina N di M)", fragile perché
    // legata a formato/lingua). 0 = non paginato / sconosciuto.
    total_pages: u32 = 0,

    pub fn deinit(self: *ImageData, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        allocator.free(self.name);
    }
};

pub const Decoded = union(enum) {
    text: []const u8,
    csv: CsvData,
    workbook: WorkbookData,
    markdown: MarkdownData,
    mesh: MeshData,
    image: ImageData,
    err: []const u8,

    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .text => |t| allocator.free(t),
            .csv => |*c| c.deinit(allocator),
            .workbook => |*w| w.deinit(allocator),
            .markdown => |*m| m.deinit(allocator),
            .mesh => |*m| m.deinit(allocator),
            .image => |*i| i.deinit(allocator),
            .err => |e| allocator.free(e),
        }
    }

    /// Converte nel layout C **consumando** `self`: i contenitori Zig si liberano, le
    /// foglie (testi, celle, pixel) passano al `DecodedC`. Tutto o niente: se manca
    /// la memoria non si è liberato né ceduto nulla e `self` resta intero, del
    /// chiamante. I plugin usano `intoC`, che in quel caso lo libera.
    pub fn toDecodedC(self: Decoded, allocator: std.mem.Allocator) !DecodedC {
        switch (self) {
            .text => |t| {
                return .{
                    .tag = .text,
                    .payload = .{ .text = SliceC.fromSlice(t) },
                };
            },
            .csv => |c| {
                const csv_c = try csvBuildC(allocator, c);
                csvFreeContainers(allocator, c);
                return .{
                    .tag = .csv,
                    .payload = .{ .csv = csv_c },
                };
            },
            .workbook => |w| {
                const sheets_c = try allocator.alloc(SheetC, w.sheets.len);
                errdefer allocator.free(sheets_c);
                var built: usize = 0;
                errdefer for (sheets_c[0..built]) |s| csvFreeContainersC(allocator, s.data);
                for (w.sheets, 0..) |s, i| {
                    sheets_c[i] = .{
                        .name = SliceC.fromSlice(s.name),
                        .data = try csvBuildC(allocator, s.data),
                    };
                    built = i + 1;
                }
                // Da qui niente può più fallire: i contenitori Zig si liberano (le
                // leaf name/celle restano vive, ora possedute da DecodedC via i SliceC).
                for (w.sheets) |s| csvFreeContainers(allocator, s.data);
                allocator.free(w.sheets);
                return .{
                    .tag = .workbook,
                    .payload = .{
                        .workbook = .{ .sheets = .{ .ptr = sheets_c.ptr, .len = sheets_c.len } },
                    },
                };
            },
            .markdown => |m| {
                return .{
                    .tag = .markdown,
                    .payload = .{ .markdown = .{ .content = SliceC.fromSlice(m.content) } },
                };
            },
            .mesh => |m| {
                // Converte i submesh in layout C (le texture-leaf restano vive,
                // ora possedute da DecodedC; il container []SubMesh si libera).
                const subs_c = try allocator.alloc(SubMeshC, m.submeshes.len);
                for (m.submeshes, 0..) |s, i| {
                    subs_c[i] = .{
                        .first_index = s.first_index,
                        .index_count = s.index_count,
                        .base_color = s.base_color,
                        .metallic = s.metallic,
                        .roughness = s.roughness,
                        .tex_width = s.tex_width,
                        .tex_height = s.tex_height,
                        .tex_pixels = SliceC.fromSlice(s.tex_pixels),
                        .nrm_tex_width = s.nrm_tex_width,
                        .nrm_tex_height = s.nrm_tex_height,
                        .nrm_tex_pixels = SliceC.fromSlice(s.nrm_tex_pixels),
                    };
                }
                if (m.submeshes.len > 0) allocator.free(m.submeshes);

                return .{
                    .tag = .mesh,
                    .payload = .{
                        .mesh = .{
                            .num_vertices = m.num_vertices,
                            .num_faces = m.num_faces,
                            .num_normals = m.num_normals,
                            .bbox_min = m.bbox_min,
                            .bbox_max = m.bbox_max,
                            .center = m.center,
                            .name = SliceC.fromSlice(m.name),
                            .vertices = .{ .ptr = m.vertices.ptr, .len = m.vertices.len },
                            .faces = .{ .ptr = m.faces.ptr, .len = m.faces.len },
                            .normals = .{ .ptr = m.normals.ptr, .len = m.normals.len },
                            .uvs = .{ .ptr = m.uvs.ptr, .len = m.uvs.len },
                            .tangents = .{ .ptr = m.tangents.ptr, .len = m.tangents.len },
                            .base_color = m.base_color,
                            .metallic = m.metallic,
                            .roughness = m.roughness,
                            .tex_width = m.tex_width,
                            .tex_height = m.tex_height,
                            .tex_pixels = SliceC.fromSlice(m.tex_pixels),
                            .submeshes = .{ .ptr = subs_c.ptr, .len = subs_c.len },
                        },
                    },
                };
            },
            .image => |i| {
                return .{
                    .tag = .image,
                    .payload = .{
                        .image = .{
                            .width = i.width,
                            .height = i.height,
                            .pixels = SliceC.fromSlice(i.pixels),
                            .name = SliceC.fromSlice(i.name),
                            .total_pages = i.total_pages,
                        },
                    },
                };
            },
            .err => |e| {
                return .{
                    .tag = .err,
                    .payload = .{ .err = SliceC.fromSlice(e) },
                };
            },
        }
    }

    /// `toDecodedC` per l'uscita di un plugin: non fallisce. Se manca la memoria per
    /// i contenitori C, libera `self` e ritorna un `.err` (vuoto se non ce n'è
    /// nemmeno per il messaggio).
    pub fn intoC(self: Decoded, allocator: std.mem.Allocator) DecodedC {
        return self.toDecodedC(allocator) catch |err| {
            var owned = self;
            owned.deinit(allocator);
            const msg = std.fmt.allocPrint(allocator, "Errore di conversione del risultato: {s}", .{@errorName(err)}) catch "";
            return .{ .tag = .err, .payload = .{ .err = SliceC.fromSlice(msg) } };
        };
    }
};

/// Costruisce il layout C di una `CsvData`: alloca i container SliceC/RowC e non
/// tocca l'originale (lo libera il chiamante con `csvFreeContainers`, quando non può
/// più fallire niente). Se manca la memoria non resta allocato nulla.
fn csvBuildC(allocator: std.mem.Allocator, c: CsvData) !CsvDataC {
    const headers_c = try allocator.alloc(SliceC, c.headers.len);
    errdefer allocator.free(headers_c);
    for (c.headers, 0..) |h, i| {
        headers_c[i] = SliceC.fromSlice(h);
    }
    const rows_c = try allocator.alloc(RowC, c.rows.len);
    errdefer allocator.free(rows_c);
    var built: usize = 0;
    errdefer for (rows_c[0..built]) |r| allocator.free(r.ptr[0..r.len]);
    for (c.rows, 0..) |row, r_idx| {
        const row_cells_c = try allocator.alloc(SliceC, row.len);
        for (row, 0..) |cell, c_idx| {
            row_cells_c[c_idx] = SliceC.fromSlice(cell);
        }
        rows_c[r_idx] = .{ .ptr = row_cells_c.ptr, .len = row_cells_c.len };
        built = r_idx + 1;
    }
    return .{
        .headers = .{ .ptr = headers_c.ptr, .len = headers_c.len },
        .rows = .{ .ptr = rows_c.ptr, .len = rows_c.len },
        // Il buffer di appoggio (se c'è) passa di proprietà al chiamante insieme
        // alle celle che ci puntano dentro: vedi `CsvData.backing`.
        .backing = SliceC.fromSlice(c.backing),
    };
}

/// Libera i soli container di una `CsvData` (le leaf — header, celle, `backing` —
/// restano vive: sono passate al layout C).
fn csvFreeContainers(allocator: std.mem.Allocator, c: CsvData) void {
    allocator.free(c.headers);
    for (c.rows) |row| allocator.free(row);
    allocator.free(c.rows);
}

/// Il contrario di `csvBuildC`: ricostruisce i container slice Zig senza toccare
/// quelli C (li libera il chiamante con `csvFreeContainersC`).
fn csvBuildZig(allocator: std.mem.Allocator, c: CsvDataC) !CsvData {
    const headers = try allocator.alloc([]const u8, c.headers.len);
    errdefer allocator.free(headers);
    for (c.headers.ptr[0..c.headers.len], 0..) |h, i| {
        headers[i] = h.toSlice();
    }
    const rows = try allocator.alloc([][]const u8, c.rows.len);
    errdefer allocator.free(rows);
    var built: usize = 0;
    errdefer for (rows[0..built]) |row| allocator.free(row);
    for (c.rows.ptr[0..c.rows.len], 0..) |row_c, r_idx| {
        const row = try allocator.alloc([]const u8, row_c.len);
        for (row_c.ptr[0..row_c.len], 0..) |cell, c_idx| {
            row[c_idx] = cell.toSlice();
        }
        rows[r_idx] = row;
        built = r_idx + 1;
    }
    return .{ .headers = headers, .rows = rows, .backing = c.backing.toSlice() };
}

/// Libera i soli container di una `CsvDataC` (le leaf restano vive).
fn csvFreeContainersC(allocator: std.mem.Allocator, c: CsvDataC) void {
    allocator.free(c.headers.ptr[0..c.headers.len]);
    for (c.rows.ptr[0..c.rows.len]) |row_c| allocator.free(row_c.ptr[0..row_c.len]);
    allocator.free(c.rows.ptr[0..c.rows.len]);
}

/// Libera una `CsvDataC` per intero, leaf comprese: come `CsvData.deinit`, con gli
/// stessi due modelli di ownership (celle a sé, oppure slice dentro `backing`).
fn csvDeinitC(allocator: std.mem.Allocator, c: CsvDataC) void {
    if (c.backing.len == 0) {
        for (c.headers.ptr[0..c.headers.len]) |h| allocator.free(h.toSlice());
        for (c.rows.ptr[0..c.rows.len]) |row_c| {
            for (row_c.ptr[0..row_c.len]) |cell| allocator.free(cell.toSlice());
        }
    }
    csvFreeContainersC(allocator, c);
    if (c.backing.len > 0) allocator.free(c.backing.toSlice());
}

// C-compatible Layouts for Plugins
pub const SliceC = extern struct {
    ptr: [*]const u8,
    len: usize,

    pub fn fromSlice(slice: []const u8) SliceC {
        return .{ .ptr = slice.ptr, .len = slice.len };
    }
    pub fn toSlice(self: SliceC) []const u8 {
        return self.ptr[0..self.len];
    }
};

pub const RowC = extern struct {
    ptr: [*]const SliceC,
    len: usize,
};

pub const CsvDataC = extern struct {
    headers: extern struct { ptr: [*]const SliceC, len: usize },
    rows: extern struct { ptr: [*]const RowC, len: usize },
    // Buffer di appoggio delle celle zero-copy (vedi `CsvData.backing`); vuoto
    // quando ogni cella è un'allocazione a sé. In CODA alla struct: gli offset
    // dei campi preesistenti non cambiano, ma la dimensione sì → abi_version bumpata.
    backing: SliceC = SliceC.fromSlice(""),
};

pub const SheetC = extern struct {
    name: SliceC,
    data: CsvDataC,
};

pub const WorkbookDataC = extern struct {
    sheets: extern struct { ptr: [*]const SheetC, len: usize },
};

pub const MarkdownDataC = extern struct {
    content: SliceC,
};

pub const SubMeshC = extern struct {
    first_index: usize,
    index_count: usize,
    base_color: [4]f32,
    metallic: f32,
    roughness: f32,
    tex_width: usize,
    tex_height: usize,
    tex_pixels: SliceC,
    nrm_tex_width: usize,
    nrm_tex_height: usize,
    nrm_tex_pixels: SliceC,
};

pub const MeshDataC = extern struct {
    num_vertices: usize,
    num_faces: usize,
    num_normals: usize,
    bbox_min: [3]f32,
    bbox_max: [3]f32,
    center: [3]f32,
    name: SliceC,
    vertices: extern struct { ptr: [*]const [3]f32, len: usize },
    faces: extern struct { ptr: [*]const Face, len: usize },
    normals: extern struct { ptr: [*]const [3]f32, len: usize },
    uvs: extern struct { ptr: [*]const [2]f32, len: usize },
    tangents: extern struct { ptr: [*]const [4]f32, len: usize },
    base_color: [4]f32,
    metallic: f32,
    roughness: f32,
    tex_width: usize,
    tex_height: usize,
    tex_pixels: SliceC,
    submeshes: extern struct { ptr: [*]const SubMeshC, len: usize },
};

pub const ImageDataC = extern struct {
    width: usize,
    height: usize,
    pixels: SliceC,
    name: SliceC,
    // Pagine totali del documento (0 = non paginato/sconosciuto). In CODA alla
    // struct: gli offset dei campi preesistenti non cambiano. Il layout resta
    // comunque una modifica ABI (dimensione della struct) → abi_version bumpata.
    total_pages: u32 = 0,
};

pub const DecodedTag = enum(u32) {
    text = 0,
    csv = 1,
    markdown = 2,
    mesh = 3,
    image = 4,
    err = 5,
    workbook = 6,
};

pub const DecodedC = extern struct {
    tag: DecodedTag,
    payload: extern union {
        text: SliceC,
        csv: CsvDataC,
        workbook: WorkbookDataC,
        markdown: MarkdownDataC,
        mesh: MeshDataC,
        image: ImageDataC,
        err: SliceC,
    },

    /// Converte nel layout Zig **consumando** `self`: i contenitori C si liberano, le
    /// foglie passano al `Decoded`. Tutto o niente, come `Decoded.toDecodedC`: se
    /// manca la memoria `self` resta intero e va liberato con `deinit`.
    pub fn toDecoded(self: DecodedC, allocator: std.mem.Allocator) !Decoded {
        switch (self.tag) {
            .text => {
                const t = self.payload.text;
                return .{ .text = t.toSlice() };
            },
            .csv => {
                const csv = try csvBuildZig(allocator, self.payload.csv);
                csvFreeContainersC(allocator, self.payload.csv);
                return .{ .csv = csv };
            },
            .workbook => {
                const w = self.payload.workbook;
                const sheets_c = w.sheets.ptr[0..w.sheets.len];
                const sheets = try allocator.alloc(Sheet, sheets_c.len);
                errdefer allocator.free(sheets);
                var built: usize = 0;
                errdefer for (sheets[0..built]) |s| csvFreeContainers(allocator, s.data);
                for (sheets_c, 0..) |s_c, i| {
                    sheets[i] = .{
                        .name = s_c.name.toSlice(),
                        .data = try csvBuildZig(allocator, s_c.data),
                    };
                    built = i + 1;
                }
                for (sheets_c) |s_c| csvFreeContainersC(allocator, s_c.data);
                allocator.free(sheets_c);
                return .{ .workbook = .{ .sheets = sheets, .active = 0 } };
            },
            .markdown => {
                const m = self.payload.markdown;
                return .{
                    .markdown = .{ .content = m.content.toSlice() },
                };
            },
            .mesh => {
                const m = self.payload.mesh;
                // Ricostruisce i submesh in slice Zig (copia il container C, che
                // poi si libera; le texture-leaf restano possedute dal MeshData).
                const subs = try allocator.alloc(SubMesh, m.submeshes.len);
                for (0..m.submeshes.len) |i| {
                    const s = m.submeshes.ptr[i];
                    subs[i] = .{
                        .first_index = s.first_index,
                        .index_count = s.index_count,
                        .base_color = s.base_color,
                        .metallic = s.metallic,
                        .roughness = s.roughness,
                        .tex_width = s.tex_width,
                        .tex_height = s.tex_height,
                        .tex_pixels = s.tex_pixels.toSlice(),
                        .nrm_tex_width = s.nrm_tex_width,
                        .nrm_tex_height = s.nrm_tex_height,
                        .nrm_tex_pixels = s.nrm_tex_pixels.toSlice(),
                    };
                }
                if (m.submeshes.len > 0) allocator.free(@constCast(m.submeshes.ptr[0..m.submeshes.len]));

                return .{
                    .mesh = .{
                        .num_vertices = m.num_vertices,
                        .num_faces = m.num_faces,
                        .num_normals = m.num_normals,
                        .bbox_min = m.bbox_min,
                        .bbox_max = m.bbox_max,
                        .center = m.center,
                        .name = m.name.toSlice(),
                        .vertices = @constCast(m.vertices.ptr[0..m.vertices.len]),
                        .faces = @constCast(m.faces.ptr[0..m.faces.len]),
                        .normals = @constCast(m.normals.ptr[0..m.normals.len]),
                        .uvs = @constCast(m.uvs.ptr[0..m.uvs.len]),
                        .tangents = @constCast(m.tangents.ptr[0..m.tangents.len]),
                        .base_color = m.base_color,
                        .metallic = m.metallic,
                        .roughness = m.roughness,
                        .tex_width = m.tex_width,
                        .tex_height = m.tex_height,
                        .tex_pixels = m.tex_pixels.toSlice(),
                        .submeshes = subs,
                    },
                };
            },
            .image => {
                const i = self.payload.image;
                return .{
                    .image = .{
                        .width = i.width,
                        .height = i.height,
                        .pixels = i.pixels.toSlice(),
                        .name = i.name.toSlice(),
                        .total_pages = i.total_pages,
                    },
                };
            },
            .err => {
                // Contratto v6: il messaggio è allocato con `allocator` (o vuoto),
                // l'host ne prende possesso e lo libera in `Decoded.deinit`.
                return .{ .err = self.payload.err.toSlice() };
            },
        }
    }

    /// Libera tutto ciò che un `DecodedC` possiede, senza convertirlo. Serve all'host
    /// quando `toDecoded` fallisce: il risultato del plugin (anche centinaia di MB di
    /// geometria e texture) altrimenti resterebbe allocato proprio quando la memoria
    /// è finita. Speculare a `Decoded.deinit`.
    pub fn deinit(self: DecodedC, allocator: std.mem.Allocator) void {
        switch (self.tag) {
            .text => allocator.free(self.payload.text.toSlice()),
            .markdown => allocator.free(self.payload.markdown.content.toSlice()),
            .err => allocator.free(self.payload.err.toSlice()),
            .csv => csvDeinitC(allocator, self.payload.csv),
            .workbook => {
                const w = self.payload.workbook;
                const sheets_c = w.sheets.ptr[0..w.sheets.len];
                for (sheets_c) |s_c| {
                    allocator.free(s_c.name.toSlice());
                    csvDeinitC(allocator, s_c.data);
                }
                allocator.free(sheets_c);
            },
            .mesh => {
                const m = self.payload.mesh;
                allocator.free(m.name.toSlice());
                allocator.free(m.vertices.ptr[0..m.vertices.len]);
                allocator.free(m.faces.ptr[0..m.faces.len]);
                if (m.normals.len > 0) allocator.free(m.normals.ptr[0..m.normals.len]);
                if (m.uvs.len > 0) allocator.free(m.uvs.ptr[0..m.uvs.len]);
                if (m.tangents.len > 0) allocator.free(m.tangents.ptr[0..m.tangents.len]);
                if (m.tex_pixels.len > 0) allocator.free(m.tex_pixels.toSlice());
                const subs = m.submeshes.ptr[0..m.submeshes.len];
                freeSubmeshTexturesOf(SubMeshC, subs, allocator);
                if (subs.len > 0) allocator.free(subs);
            },
            .image => {
                const i = self.payload.image;
                allocator.free(i.pixels.toSlice());
                allocator.free(i.name.toSlice());
            },
        }
    }
};

/// Errore di un plugin secondo il contratto ABI v6: messaggio allocato con
/// `allocator` (l'allocator dell'host passato a `zuer_decode`), di cui l'host
/// prende possesso; vuoto se manca la memoria (liberare una slice vuota non fa
/// nulla). MAI un letterale: l'host lo libererebbe.
pub fn pluginError(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) Decoded {
    return .{ .err = std.fmt.allocPrint(allocator, fmt, args) catch "" };
}

/// Versione dell'ABI plugin (layout di `DecodedC`, firma di `DecodeFn` E layout
/// dei tipi std che attraversano il confine — `io_ptr` e `allocator_ptr` puntano
/// a `std.Io` e `std.mem.Allocator`, quindi il contratto dipende anche dalla
/// VERSIONE DI ZIG con cui host e plugin sono compilati).
/// Va incrementata a ogni modifica incompatibile: l'host scarta i plugin
/// compilati contro una versione diversa (un .so stantio con un layout
/// `DecodedC` vecchio corromperebbe la memoria).
/// v2: aggiunto `total_pages: u32` in coda a `ImageDataC`.
/// v3: aggiunto `backing: SliceC` in coda a `CsvDataC` (celle CSV zero-copy).
/// v4: Zig 0.17 — `std.mem.Allocator`/`std.Io` hanno cambiato layout. Un plugin
///     pre-0.17 passa un `Alignment` che l'host interpreta come spazzatura e
///     `SafeAllocator.alloc` muore in `@alignCast` ("incorrect alignment"):
///     `DecodedC` era identico, quindi solo il bump lo fa scartare.
/// v5: l'impronta qui sotto, calcolata a comptime, al posto del numero a mano.
/// v6: il messaggio di `.err` è SEMPRE allocato con l'allocator dell'host (o
///     vuoto) e l'host ne prende possesso. Prima poteva essere un letterale,
///     quindi l'host lo duplicava e non liberava mai l'originale (un leak per
///     ogni decode fallito). Un plugin v5 darebbe all'host un letterale da
///     liberare: il bump lo fa scartare.
pub const abi_contract: u32 = 6;

/// Versione effettiva confrontata al caricamento: `abi_contract` + versione di
/// Zig + layout dei tipi std che attraversano il confine (`io_ptr` e
/// `allocator_ptr` di `DecodeFn` puntano a `std.Io`/`std.mem.Allocator` dell'
/// host, NON a tipi C). La v4 ha mostrato che un cambio di quei layout lascia
/// identico `DecodedC` e passa il controllo: ora un plugin compilato con un
/// altro Zig viene scartato da solo, senza ricordarsi di bumpare nulla.
/// Host e plugin la calcolano dallo stesso sorgente, quindi coincidono
/// esattamente quando coincidono compilatore e contratto.
pub const abi_version: u32 = blk: {
    @setEvalBranchQuota(10_000);
    var h = std.hash.Fnv1a_32.init();
    h.update(std.mem.asBytes(&abi_contract));
    h.update(builtin.zig_version_string);
    for ([_]usize{
        @sizeOf(std.mem.Allocator),        @alignOf(std.mem.Allocator),
        @sizeOf(std.mem.Allocator.VTable), @sizeOf(std.Io),
        @alignOf(std.Io),                  @sizeOf(std.Io.VTable),
        @sizeOf(DecodedC),                 @alignOf(DecodedC),
        @sizeOf(HostServices),
    }) |n| {
        const v: u64 = n;
        h.update(std.mem.asBytes(&v));
    }
    break :blk h.final();
};

/// True quando i decoder sono compilati come **plugin** caricabili con `dlopen` — il caso
/// del desktop. Su Android no: l'APK porta una libreria sola e i decoder ci finiscono
/// dentro linkati, dove gli export dell'ABI plugin (`zuer_decode`, `zuer_extensions`…)
/// colliderebbero l'uno con l'altro, uno per decoder, senza che nessuno li chiami.
pub const plugin_abi = builtin.abi != .android;

/// Servizi che l'host offre ai plugin, consegnati al caricamento tramite
/// l'export OPZIONALE `zuer_set_host`. Un plugin non può raggiungere da solo lo
/// scheduler dell'host (è un .so con le sue variabili statiche): senza questa
/// tabella ogni plugin dovrebbe crearsi i propri thread, come faceva glb.
/// Un plugin senza `zuer_set_host`, o un host che non lo chiama (Android, dove i
/// decoder sono linkati e non caricati), resta sul proprio ripiego.
pub const HostServices = extern struct {
    /// `@sizeOf(HostServices)` dell'host: un campo aggiunto in coda si
    /// riconosce senza rompere i plugin esistenti.
    size: usize,
    /// Esegue `body(ctx, i)` per `i` in `0..n` sui worker condivisi, con la
    /// priorità del thread chiamante; ritorna quando tutti gli indici sono
    /// stati eseguiti e nessun worker tocca più `ctx`.
    parallel_for: *const fn (n: usize, ctx: ?*anyopaque, body: ParallelBody) callconv(.c) void,
};
pub const ParallelBody = *const fn (ctx: ?*anyopaque, index: usize) callconv(.c) void;
pub const SetHostFn = *const fn (services: *const HostServices) callconv(.c) void;

/// Ogni plugin esporta `zuer_abi_version` (ritorna l'`abi_version` con cui è
/// stato compilato); l'host la verifica al caricamento e scarta i mismatch.
pub const AbiVersionFn = *const fn () callconv(.c) u32;

/// Contratto di ownership: il plugin prende possesso di `content` e lo libera
/// lui (con l'allocator passato), anche nei percorsi d'errore.
pub const DecodeFn = *const fn (
    path: SliceC,
    content: SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) DecodedC;

/// Ogni plugin dichiara le estensioni che sa decodificare esportando
/// `zuer_extensions`: una stringa statica di estensioni separate da virgola
/// (es. "csv,tsv"). L'host la interroga una sola volta al caricamento, così
/// aggiungere un formato significa solo installare un nuovo .so.
pub const ExtensionsFn = *const fn () callconv(.c) SliceC;

/// Opzionale: quanti byte di `content` servono davvero al plugin. 0 = solo il
/// percorso (es. pdf: rilegge lui dal path); N = bastano i primi N byte (es.
/// media: header sniffing — un MKV multi-GB non va caricato in RAM per il
/// poster). Assente = l'host passa l'intero file (default storico).
pub const ContentPrefixFn = *const fn () callconv(.c) usize;

/// Ciò che un plugin riceve per un decode, già nei tipi di Zig.
pub const PluginRequest = struct {
    /// Percorso come l'ha chiesto l'utente, frammento `#…` compreso.
    path: []const u8,
    /// I byte che l'host ha letto (tutto il file, un prefisso o niente: vedi
    /// `plugin_content_prefix`). Sono DEL PLUGIN, allocati con `allocator`: li libera
    /// lui, anche se fallisce, oppure li cede al risultato (testo e CSV zero-copy).
    content: []u8,
    io: std.Io,
    allocator: std.mem.Allocator,
};

/// Esporta i simboli dell'ABI plugin per il decoder `Impl`. Da chiamare in un blocco
/// `comptime` del file del decoder: `comptime { decoder.exportPlugin(@This()); }`.
///
/// `Impl` dichiara (tutto `pub`):
///   - `plugin_name`: il nome nella tabella di formats.zig, da cui vengono le estensioni;
///   - `pluginDecode(req: PluginRequest) Decoded`;
///   - facoltativi: `pluginDecodeCoarse(req) Decoded` (prima fase progressiva),
///     `plugin_content_prefix: usize` (quanti byte del file servono: 0 = solo il
///     percorso; assente = tutto), `pluginSetHost(*const HostServices) void`.
///
/// Dove i decoder non sono plugin (Android: linkati nell'unica libreria dell'APK) non
/// esporta nulla: i nomi colliderebbero, uno per decoder.
pub fn exportPlugin(comptime Impl: type) void {
    if (!plugin_abi) return;
    const Glue = struct {
        fn request(path: SliceC, content: SliceC, io_ptr: *const anyopaque, allocator_ptr: *const anyopaque) PluginRequest {
            return .{
                .path = path.toSlice(),
                // L'host alloca sempre `content` sull'heap con questo allocator: il
                // `const` è solo del layout C.
                .content = @constCast(content.toSlice()),
                .io = @as(*const std.Io, @ptrCast(@alignCast(io_ptr))).*,
                .allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*,
            };
        }

        fn decode(path: SliceC, content: SliceC, io_ptr: *const anyopaque, allocator_ptr: *const anyopaque) callconv(.c) DecodedC {
            const req = request(path, content, io_ptr, allocator_ptr);
            return Impl.pluginDecode(req).intoC(req.allocator);
        }

        fn decodeCoarse(path: SliceC, content: SliceC, io_ptr: *const anyopaque, allocator_ptr: *const anyopaque) callconv(.c) DecodedC {
            const req = request(path, content, io_ptr, allocator_ptr);
            return Impl.pluginDecodeCoarse(req).intoC(req.allocator);
        }

        fn extensions() callconv(.c) SliceC {
            return SliceC.fromSlice(comptime formats.extensionsOf(Impl.plugin_name));
        }

        fn abiVersion() callconv(.c) u32 {
            return abi_version;
        }

        fn contentPrefix() callconv(.c) usize {
            return Impl.plugin_content_prefix;
        }

        fn setHost(services: *const HostServices) callconv(.c) void {
            Impl.pluginSetHost(services);
        }
    };
    @export(&Glue.decode, .{ .name = "zuer_decode", .linkage = .strong });
    @export(&Glue.extensions, .{ .name = "zuer_extensions", .linkage = .strong });
    @export(&Glue.abiVersion, .{ .name = "zuer_abi_version", .linkage = .strong });
    if (@hasDecl(Impl, "pluginDecodeCoarse")) @export(&Glue.decodeCoarse, .{ .name = "zuer_decode_coarse", .linkage = .strong });
    if (@hasDecl(Impl, "plugin_content_prefix")) @export(&Glue.contentPrefix, .{ .name = "zuer_content_prefix", .linkage = .strong });
    if (@hasDecl(Impl, "pluginSetHost")) @export(&Glue.setHost, .{ .name = "zuer_set_host", .linkage = .strong });
}

/// Un `Decoded` di prova per ogni forma che attraversa l'ABI, con ogni foglia
/// allocata da `a` come farebbe un plugin.
fn sampleDecodedForTest(a: std.mem.Allocator, kind: u8) !Decoded {
    const S = struct {
        fn csv(al: std.mem.Allocator, cols: usize, rows: usize) !CsvData {
            const headers = try al.alloc([]const u8, cols);
            for (headers, 0..) |*h, i| h.* = try std.fmt.allocPrint(al, "col{d}", .{i});
            const out = try al.alloc([][]const u8, rows);
            for (out, 0..) |*row, r| {
                row.* = try al.alloc([]const u8, cols);
                for (row.*, 0..) |*cell, c| cell.* = try std.fmt.allocPrint(al, "r{d}c{d}", .{ r, c });
            }
            return .{ .headers = headers, .rows = out };
        }
    };
    switch (kind) {
        0 => return .{ .text = try a.dupe(u8, "testo") },
        1 => return .{ .markdown = .{ .content = try a.dupe(u8, "# titolo") } },
        2 => return .{ .err = try a.dupe(u8, "errore") },
        3 => return .{ .csv = try S.csv(a, 3, 4) },
        4 => {
            // Celle zero-copy: slice dentro `backing`, mai liberate una per una.
            const backing = try a.dupe(u8, "a,b\n1,2\n");
            const headers = try a.alloc([]const u8, 2);
            headers[0] = backing[0..1];
            headers[1] = backing[2..3];
            const rows = try a.alloc([][]const u8, 1);
            rows[0] = try a.alloc([]const u8, 2);
            rows[0][0] = backing[4..5];
            rows[0][1] = backing[6..7];
            return .{ .csv = .{ .headers = headers, .rows = rows, .backing = backing } };
        },
        5 => {
            const sheets = try a.alloc(Sheet, 3);
            for (sheets, 0..) |*s, i| s.* = .{
                .name = try std.fmt.allocPrint(a, "Foglio {d}", .{i + 1}),
                .data = try S.csv(a, 2, i + 1),
            };
            return .{ .workbook = .{ .sheets = sheets } };
        },
        6 => {
            // Due submesh sullo stesso atlas (un solo buffer) più una normal map.
            const atlas = try a.alloc(u8, 16);
            const nrm = try a.alloc(u8, 16);
            const subs = try a.alloc(SubMesh, 2);
            subs[0] = .{ .first_index = 0, .index_count = 3, .tex_width = 2, .tex_height = 2, .tex_pixels = atlas };
            subs[1] = .{ .first_index = 3, .index_count = 3, .tex_width = 2, .tex_height = 2, .tex_pixels = atlas, .nrm_tex_width = 2, .nrm_tex_height = 2, .nrm_tex_pixels = nrm };
            const vertices = try a.alloc([3]f32, 4);
            @memset(vertices, .{ 1, 2, 3 });
            const faces = try a.alloc(Face, 2);
            @memset(faces, .{ .v1 = 0, .v2 = 1, .v3 = 2 });
            const uvs = try a.alloc([2]f32, 4);
            @memset(uvs, .{ 0, 1 });
            return .{ .mesh = .{
                .num_vertices = 4,
                .num_faces = 2,
                .num_normals = 0,
                .bbox_min = .{ 0, 0, 0 },
                .bbox_max = .{ 1, 1, 1 },
                .center = .{ 0.5, 0.5, 0.5 },
                .name = try a.dupe(u8, "modello.glb"),
                .vertices = vertices,
                .faces = faces,
                .uvs = uvs,
                .tex_width = 1,
                .tex_height = 1,
                .tex_pixels = try a.alloc(u8, 4),
                .submeshes = subs,
            } };
        },
        7 => {
            // OBJ/STL: nessun submesh, nessun attributo opzionale.
            const vertices = try a.alloc([3]f32, 3);
            @memset(vertices, .{ 0, 0, 0 });
            const faces = try a.alloc(Face, 1);
            faces[0] = .{ .v1 = 0, .v2 = 1, .v3 = 2 };
            return .{ .mesh = .{
                .num_vertices = 3,
                .num_faces = 1,
                .num_normals = 0,
                .bbox_min = .{ 0, 0, 0 },
                .bbox_max = .{ 0, 0, 0 },
                .center = .{ 0, 0, 0 },
                .name = try a.dupe(u8, "cubo.obj"),
                .vertices = vertices,
                .faces = faces,
            } };
        },
        else => return .{ .image = .{
            .width = 2,
            .height = 1,
            .pixels = try a.alloc(u8, 6),
            .name = try a.dupe(u8, "foto.png"),
            .total_pages = 7,
        } },
    }
}

test "convertitori ABI: andata e ritorno senza perdere nulla" {
    const a = std.testing.allocator;
    var kind: u8 = 0;
    while (kind <= 8) : (kind += 1) {
        const d = try sampleDecodedForTest(a, kind);
        const c = try d.toDecodedC(a);
        var back = try c.toDecoded(a);
        defer back.deinit(a);
        try std.testing.expectEqual(std.meta.activeTag(d), std.meta.activeTag(back));
        switch (back) {
            .csv => |t| {
                if (kind == 3) {
                    try std.testing.expectEqual(@as(usize, 4), t.rows.len);
                    try std.testing.expectEqualStrings("col2", t.headers[2]);
                    try std.testing.expectEqualStrings("r3c1", t.rows[3][1]);
                } else {
                    try std.testing.expect(t.backing.len > 0);
                    try std.testing.expectEqualStrings("2", t.rows[0][1]);
                }
            },
            .workbook => |w| {
                try std.testing.expectEqual(@as(usize, 3), w.sheets.len);
                try std.testing.expectEqualStrings("Foglio 3", w.sheets[2].name);
                try std.testing.expectEqualStrings("r2c1", w.sheets[2].data.rows[2][1]);
            },
            .mesh => |m| if (kind == 6) {
                try std.testing.expectEqual(@as(usize, 2), m.submeshes.len);
                try std.testing.expectEqual(m.submeshes[0].tex_pixels.ptr, m.submeshes[1].tex_pixels.ptr);
                try std.testing.expectEqual(@as(usize, 16), m.submeshes[1].nrm_tex_pixels.len);
            } else try std.testing.expectEqual(@as(usize, 0), m.submeshes.len),
            .image => |i| try std.testing.expectEqual(@as(u32, 7), i.total_pages),
            else => {},
        }
    }
}

test "convertitori ABI: a memoria esaurita niente leak e niente doppie liberazioni" {
    // Il campione nasce dall'allocatore dei test (che non fallisce e conta i leak);
    // la conversione passa da uno che fallisce all'allocazione numero `fail_index`,
    // provate tutte fino alla prima corsa che arriva in fondo. A ogni fallimento
    // l'ingresso deve essere ancora intero: lo libera chi ha chiamato, come fanno
    // `intoC` nei plugin e `decodeImpl` nell'host.
    const base = std.testing.allocator;
    var kind: u8 = 0;
    while (kind <= 8) : (kind += 1) {
        var failures: usize = 0;
        var fail_index: usize = 0;
        while (true) : (fail_index += 1) {
            var d = try sampleDecodedForTest(base, kind);
            var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = fail_index });
            const a = failing.allocator();
            const c = d.toDecodedC(a) catch {
                d.deinit(a);
                failures += 1;
                continue;
            };
            var back = c.toDecoded(a) catch {
                c.deinit(a);
                failures += 1;
                continue;
            };
            back.deinit(a);
            break;
        }
        // Tabelle e mesh con submesh allocano contenitori: lì almeno un fallimento
        // va provato davvero (una mesh senza submesh non alloca nulla).
        if (kind >= 3 and kind <= 6) try std.testing.expect(failures > 0);
    }
}

test "intoC: senza memoria libera il risultato e ritorna un errore" {
    const base = std.testing.allocator;
    const d = try sampleDecodedForTest(base, 5);
    var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = 0 });
    const c = d.intoC(failing.allocator());
    defer c.deinit(base);
    try std.testing.expectEqual(DecodedTag.err, c.tag);
    // Nemmeno il messaggio ha trovato memoria: vuoto, mai un letterale.
    try std.testing.expectEqual(@as(usize, 0), c.payload.err.len);
}
