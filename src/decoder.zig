const std = @import("std");
const builtin = @import("builtin");
const dynlib = @import("dynlib.zig");
const meshcache = @import("meshcache.zig");
const extract_cache = @import("extract_cache.zig");
/// Rilevamento del formato dai byte magici: pubblico, lo usano anche i plugin.
pub const detect = @import("detect.zig");
const pathfrag = @import("fragment.zig");
const utf8_lossy = @import("utf8_lossy.zig");
const scheduler = @import("scheduler.zig");

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

fn hostParallelFor(n: usize, ctx: ?*anyopaque, body: ParallelBody) callconv(.c) void {
    scheduler.parallelForGlobal(n, ctx, body);
}

const host_services: HostServices = .{
    .size = @sizeOf(HostServices),
    .parallel_for = hostParallelFor,
};

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

const LoadedPlugin = struct {
    type_name: []const u8,
    extensions: []const []const u8,
    lib: dynlib.Lib,
    decode_fn: DecodeFn,
    /// Opzionale: prima fase progressiva (texture al tier coarse). Solo i plugin
    /// che la esportano (es. glb) la offrono; gli altri fanno un decode solo.
    decode_coarse_fn: ?DecodeFn = null,
    /// Byte di contenuto richiesti (vedi ContentPrefixFn); maxInt = file intero.
    content_prefix: usize = std.math.maxInt(usize),
};

var plugin_registry: std.ArrayList(LoadedPlugin) = .empty;
var third_party_scanned = false;
/// Plugin che in questo processo non si sono potuti caricare. Senza questa memoria
/// ogni decode rifaceva dlopen e dlclose su tre cartelle, sotto il mutex e con una
/// riga su stderr — e dopo un cambio di Zig, con i plugin rimasti quelli vecchi, sono
/// due decode per miniatura. Un plugin installato a programma aperto si vede al
/// prossimo avvio. Sotto `plugin_cache_mutex`.
var failed_plugins: std.ArrayList(FailedPlugin) = .empty;

const FailedPlugin = struct {
    name: []const u8,
    tries: u8,

    /// Un file che manca ovunque, o che si carica ma ha un'altra ABI, è un verdetto:
    /// basta una volta. Un file che c'è ma non si carica no — dlopen riduce a «non
    /// trovato» anche i descrittori finiti, la memoria esaurita, il file a metà di
    /// un aggiornamento — quindi si riprova, ma non all'infinito: una dipendenza
    /// che manca (libav non installata) fallisce uguale a ogni file multimediale.
    const max_tries: u8 = 3;
};

fn pluginGivenUpLocked(name: []const u8) bool {
    for (failed_plugins.items) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.tries >= FailedPlugin.max_tries;
    }
    return false;
}

fn notePluginFailureLocked(name: []const u8, definitive: bool, allocator: std.mem.Allocator) void {
    for (failed_plugins.items) |*f| {
        if (!std.mem.eql(u8, f.name, name)) continue;
        f.tries = if (definitive) FailedPlugin.max_tries else f.tries +| 1;
        return;
    }
    const owned = allocator.dupe(u8, name) catch return;
    failed_plugins.append(allocator, .{
        .name = owned,
        .tries = if (definitive) FailedPlugin.max_tries else 1,
    }) catch allocator.free(owned);
}
/// Mutex BLOCCANTE del registro plugin (`std.Io.Mutex`, lo stesso tipo usato
/// ovunque nella GUI): sotto questo lock si fanno dlopen e readdir, cioè
/// decine di millisecondi di I/O — lo spin-lock precedente
/// (`tryLock` + `Thread.yield`) bruciava una CPU intera per tutta la durata
/// quando due worker aprivano file diversi insieme.
var plugin_cache_mutex: std.Io.Mutex = .init;
/// `io` dell'host memorizzato al primo uso del registro: `closePluginCache` ne
/// ha bisogno per lock/unlock ma la sua firma non lo porta (i chiamanti sono
/// main/gui/decode_test). Scritto sotto `plugin_cache_mutex`, sempre con lo
/// stesso valore.
var plugin_cache_io: ?std.Io = null;

/// Chiude i plugin caricati e libera il registro. Da chiamare a fine processo,
/// dopo il join di tutti i thread che possono decodificare.
pub fn closePluginCache(allocator: std.mem.Allocator) void {
    if (plugin_cache_io) |io| {
        plugin_cache_mutex.lockUncancelable(io);
        defer plugin_cache_mutex.unlock(io);
        closePluginCacheLocked(allocator);
    } else {
        // Nessuna decodifica è mai avvenuta: il registro è vuoto e nessun altro
        // thread può contendere il lock, quindi non serve prenderlo.
        closePluginCacheLocked(allocator);
    }
}

fn closePluginCacheLocked(allocator: std.mem.Allocator) void {
    for (plugin_registry.items) |*p| {
        allocator.free(p.type_name);
        for (p.extensions) |e| allocator.free(e);
        allocator.free(p.extensions);
        p.lib.close();
    }
    plugin_registry.deinit(allocator);
    plugin_registry = .empty;
    for (failed_plugins.items) |f| allocator.free(f.name);
    failed_plugins.deinit(allocator);
    failed_plugins = .empty;
    third_party_scanned = false;
    if (exe_dir_cache) |d| {
        allocator.free(d);
        exe_dir_cache = null;
    }
    exe_dir_unavailable = false;
}

/// Cache della directory dell'eseguibile: `executableDirPathAlloc` costa una
/// syscall + un'allocazione e veniva richiamata a OGNI tentativo di caricamento
/// plugin (una per estensione mai vista, più lo scan di terze parti). Letta e
/// scritta solo dalle funzioni `…Locked`, cioè sempre sotto
/// `plugin_cache_mutex`: nessuna sincronizzazione aggiuntiva serve. Liberata da
/// `closePluginCacheLocked` (i test girano con un allocator che rileva i leak).
var exe_dir_cache: ?[]const u8 = null;
var exe_dir_unavailable = false;

fn executableDirCachedLocked(io: std.Io, allocator: std.mem.Allocator) ?[]const u8 {
    if (exe_dir_cache) |d| return d;
    if (exe_dir_unavailable) return null;
    const d = std.process.executableDirPathAlloc(io, allocator) catch {
        exe_dir_unavailable = true;
        return null;
    };
    exe_dir_cache = d;
    return d;
}

// A dynamic library's on-disk name is target-specific: `libdecoder_x.so` on Linux,
// `libdecoder_x.dylib` on macOS, `decoder_x.dll` on Windows (no `lib` prefix). Match the
// naming Zig's build emits so plugin discovery works on every platform.
const plugin_prefix = if (builtin.os.tag == .windows) "decoder_" else "libdecoder_";
const plugin_suffix = switch (builtin.os.tag) {
    .windows => ".dll",
    .macos => ".dylib",
    else => ".so",
};

/// Manifest estensione→plugin per il caricamento LAZY del singolo plugin:
/// evita il dlopen di TUTTI i .so/.dll (≈140 MB) solo per leggerne
/// `zuer_extensions` alla prima decodifica. DUPLICA le liste `pub const
/// extensions` dei decoder — importarle direttamente è impossibile: il blocco
/// comptime di ogni decoder @export-a i simboli ABI e colliderebbero nell'host.
/// La fonte di verità resta `zuer_extensions` del plugin: al load l'host
/// ri-verifica, e un manifest stantio degrada nello scan completo di sempre,
/// mai in un decode sbagliato. Plugin di terze parti: coperti dal fallback.
const ManifestEntry = struct { name: []const u8, exts: []const u8 };
const plugin_manifest = [_]ManifestEntry{
    .{ .name = "text", .exts = "txt,text,log,nfo,rst,adoc,asciidoc,org,tex,bib,srt,vtt,diff,patch," ++
        "json,jsonl,ndjson,yaml,yml,toml,ini,cfg,conf,properties,env,plist,editorconfig,gitignore,gitattributes,lock," ++
        "xml,html,htm,xhtml,css,scss,sass,less," ++
        "sh,bash,zsh,fish,ps1,bat,cmd,mk,make,cmake,gradle,dockerfile," ++
        "rs,py,pyi,js,mjs,cjs,jsx,ts,tsx,c,h,cc,cpp,cxx,hpp,hh,cs,java,kt,kts,go,rb,php,swift,scala,lua,pl,pm,r,sql,dart,ex,exs,erl,hrl,hs,clj,cljs,vim,asm,s,zig,jl,nim,proto,graphql,gql" },
    // Oltre ai formati in processo, quelli del codec di sistema (ImageIO su macOS;
    // WIC o ImageMagick altrove, secondo i codec installati): HEIC, JPEG XL, JPEG
    // 2000, OpenEXR, DDS/KTX, ICNS e i RAW delle fotocamere.
    .{ .name = "image", .exts = "png,jpg,jpeg,jpe,jfif,gif,bmp,dib,tga,psd,hdr,pic,pnm,pbm,pgm,ppm,svg,svgz,webp,tif,tiff,ico,avif," ++
        "heic,heif,hif,jxl,jp2,j2k,jpf,jpx,exr,dds,ktx,astc,icns,pct,pict,sgi," ++
        "dng,cr2,cr3,crw,nef,nrw,arw,srf,sr2,orf,rw2,raf,pef,srw,x3f,erf,3fr,mos,mrw,dcr,kdc,rwl,iiq" },
    .{ .name = "media", .exts = "mp3,wav,w64,flac,ogg,oga,ogv,opus,m4a,m4b,mka,aac,ac3,eac3,dts,wma,aif,aiff,aifc,caf,amr,awb,wv,ape,mpc,tta," ++
        "mp4,m4v,mov,qt,mkv,webm,avi,divx,wmv,asf,flv,f4v,mpg,mpeg,mpe,m1v,m2v,vob,mts,m2ts,m2t,3gp,3g2,dv,mid,midi" },
    .{ .name = "csv", .exts = "csv,tsv" },
    .{ .name = "markdown", .exts = "md,markdown" },
    .{ .name = "archive", .exts = "zip,jar,apk,cbz,epub,xpi,whl" },
    .{ .name = "tar", .exts = "tar,tgz,tar.gz,7z,rar,xz,txz,bz2,tbz,tbz2,zst,tzst,lz,lzma,tlz,iso,cab,cpio,xar,pkg,rpm,lha,lzh" },
    .{ .name = "glb", .exts = "glb" },
    .{ .name = "mesh", .exts = "obj,stl" },
    .{ .name = "office", .exts = "docx,pptx,odt,odp,xlsx,xlsm,ods" ++ (if (builtin.os.tag == .macos) ",doc,dot,rtf,webarchive,wordml" else "") },
    .{ .name = "pdf", .exts = "pdf" },
};

fn manifestPluginForExt(ext: []const u8) ?[]const u8 {
    for (&plugin_manifest) |*m| {
        var tokens = std.mem.tokenizeScalar(u8, m.exts, ',');
        while (tokens.next()) |tok| {
            if (asciiEqualIgnoreCase(ext, tok)) return m.name;
        }
    }
    return null;
}

fn manifestHasName(name: []const u8) bool {
    for (&plugin_manifest) |*m| {
        if (std.mem.eql(u8, m.name, name)) return true;
    }
    return false;
}

/// Scansiona una directory alla ricerca di plugin `libdecoder_*.so` e li
/// registra interrogando `zuer_extensions`. Un plugin già registrato con lo
/// stesso nome (da una directory precedente nell'ordine di ricerca) vince.
/// Con `skip_manifested` apre SOLO i plugin fuori manifest (terze parti):
/// il resto è raggiungibile in modo mirato senza pagarne il dlopen.
fn scanPluginDir(dir_path: []const u8, io: std.Io, allocator: std.mem.Allocator, skip_manifested: bool) void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);

    var iterator = dir.iterate();
    while (iterator.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.startsWith(u8, entry.name, plugin_prefix)) continue;
        if (!std.mem.endsWith(u8, entry.name, plugin_suffix)) continue;

        const type_name = entry.name[plugin_prefix.len .. entry.name.len - plugin_suffix.len];
        if (type_name.len == 0) continue;
        if (skip_manifested and manifestHasName(type_name)) continue;
        _ = registerPluginFile(dir_path, entry.name, type_name, io, allocator);
    }
}

/// Esito di `registerPluginFile`. `missing` (il file non c'è) e `rejected` (si carica,
/// ma ha un'altra ABI o gli manca `zuer_decode`) sono verdetti: riprovare darebbe lo
/// stesso risultato. `load_failed` (c'è ma non si carica) e `out_of_memory` no.
const RegisterOutcome = enum { registered, missing, rejected, load_failed, out_of_memory };

/// Apre e registra il singolo file plugin `file_name` (in `dir_path`) come
/// `type_name`, con verifica ABI e lettura di `zuer_extensions`. No-op se un
/// plugin con quel nome è già registrato.
fn registerPluginFile(dir_path: []const u8, file_name: []const u8, type_name: []const u8, io: std.Io, allocator: std.mem.Allocator) RegisterOutcome {
    if (findPluginByName(type_name) != null) return .registered;

    const full_path = std.fs.path.join(allocator, &.{ dir_path, file_name }) catch return .out_of_memory;
    defer allocator.free(full_path);

    var lib = dynlib.Lib.open(full_path) catch {
        std.Io.Dir.cwd().access(io, full_path, .{}) catch return .missing;
        return .load_failed;
    };
    // Verifica dell'ABI: un plugin senza `zuer_abi_version` o compilato
    // contro un'altra versione del contratto C va scartato subito (il
    // layout di `DecodedC` potrebbe non combaciare → corruzione di memoria).
    const abi_ok = if (lib.lookup(AbiVersionFn, "zuer_abi_version")) |abi_fn| blk: {
        const v = abi_fn();
        if (v != abi_version)
            std.debug.print("zuer: plugin {s} ignorato: ABI {x:0>8} != {x:0>8} (compilato con un altro Zig o contratto)\n", .{ file_name, v, abi_version });
        break :blk v == abi_version;
    } else blk: {
        std.debug.print("zuer: plugin {s} ignorato: manca zuer_abi_version (atteso ABI {x:0>8})\n", .{ file_name, abi_version });
        break :blk false;
    };
    if (!abi_ok) {
        lib.close();
        return .rejected;
    }
    const decode_fn = lib.lookup(DecodeFn, "zuer_decode") orelse {
        lib.close();
        return .rejected;
    };
    const decode_coarse_fn = lib.lookup(DecodeFn, "zuer_decode_coarse");
    if (lib.lookup(SetHostFn, "zuer_set_host")) |set_host| set_host(&host_services);
    const content_prefix: usize = if (lib.lookup(ContentPrefixFn, "zuer_content_prefix")) |f| f() else std.math.maxInt(usize);

    // `zuer_extensions` è opzionale: un plugin senza estensioni dichiarate
    // resta raggiungibile solo come fallback per nome (es. "text").
    var exts: std.ArrayList([]const u8) = .empty;
    if (lib.lookup(ExtensionsFn, "zuer_extensions")) |ext_fn| {
        var tokens = std.mem.tokenizeScalar(u8, ext_fn().toSlice(), ',');
        while (tokens.next()) |tok| {
            const trimmed = std.mem.trim(u8, tok, " \t\r\n");
            if (trimmed.len == 0) continue;
            const lower = allocator.dupe(u8, trimmed) catch continue;
            for (lower) |*ch| ch.* = std.ascii.toLower(ch.*);
            exts.append(allocator, lower) catch allocator.free(lower);
        }
    }

    var registered = false;
    defer if (!registered) {
        for (exts.items) |e| allocator.free(e);
        exts.deinit(allocator);
        lib.close();
    };

    const type_name_dup = allocator.dupe(u8, type_name) catch return .out_of_memory;
    const exts_owned = exts.toOwnedSlice(allocator) catch {
        allocator.free(type_name_dup);
        return .out_of_memory;
    };
    plugin_registry.append(allocator, .{
        .type_name = type_name_dup,
        .extensions = exts_owned,
        .lib = lib,
        .decode_fn = decode_fn,
        .decode_coarse_fn = decode_coarse_fn,
        .content_prefix = content_prefix,
    }) catch {
        allocator.free(type_name_dup);
        for (exts_owned) |e| allocator.free(e);
        allocator.free(exts_owned);
        return .out_of_memory;
    };
    registered = true;
    return .registered;
}

/// Cartelle dei plugin, in ordine, tutte relative all'ESEGUIBILE: `<exe>/decoders`
/// (installazione: install.sh, installer Windows), `<exe>` (DLL accanto all'exe) e
/// `<exe>/../lib` (`zig build` e `--prefix`: bin/ + lib/). Mai relative alla
/// cartella corrente: lanciato da una cartella scaricata, zuer farebbe dlopen dei
/// `.so` che ci trova.
fn pluginDirsLocked(io: std.Io, allocator: std.mem.Allocator, out: *[3][]u8) [][]u8 {
    const exe_dir = executableDirCachedLocked(io, allocator) orelse return out[0..0];
    var n: usize = 0;
    for ([_][]const []const u8{ &.{ exe_dir, "decoders" }, &.{exe_dir}, &.{ exe_dir, "..", "lib" } }) |parts| {
        out[n] = std.fs.path.join(allocator, parts) catch continue;
        n += 1;
    }
    return out[0..n];
}

/// Registra (una sola volta) i plugin di TERZE PARTI — quelli fuori manifest —
/// scandendo le cartelle di `pluginDirsLocked`. È un readdir + dlopen dei soli
/// file sconosciuti: nel caso comune (nessun plugin extra) non apre nulla. Con
/// `plugin_cache_mutex` acquisito.
fn ensureThirdPartyLocked(io: std.Io, allocator: std.mem.Allocator) void {
    if (third_party_scanned) return;
    third_party_scanned = true;
    var buf: [3][]u8 = undefined;
    const dirs = pluginDirsLocked(io, allocator, &buf);
    defer for (dirs) |d| allocator.free(d);
    for (dirs) |d| scanPluginDir(d, io, allocator, true);
}

/// Carica il SOLO plugin `name` cercandolo nelle stesse directory (e ordine)
/// dello scan completo. No-op se già registrato, introvabile o dato per perso in
/// questo processo (`failed_plugins`). Con `plugin_cache_mutex` acquisito.
fn loadPluginByNameLocked(name: []const u8, io: std.Io, allocator: std.mem.Allocator) void {
    if (findPluginByName(name) != null) return;
    if (pluginGivenUpLocked(name)) return;
    var fname_buf: [160]u8 = undefined;
    const fname = std.fmt.bufPrint(&fname_buf, "{s}{s}{s}", .{ plugin_prefix, name, plugin_suffix }) catch return;
    var buf: [3][]u8 = undefined;
    const dirs = pluginDirsLocked(io, allocator, &buf);
    defer for (dirs) |d| allocator.free(d);
    // Senza le tre cartelle (o senza quella dell'eseguibile) è mancata la memoria,
    // non il plugin: niente verdetto.
    var conclusive = dirs.len == buf.len;
    var definitive = true;
    for (dirs) |d| {
        switch (registerPluginFile(d, fname, name, io, allocator)) {
            .registered => return,
            .missing, .rejected => {},
            .load_failed => definitive = false,
            .out_of_memory => conclusive = false,
        }
    }
    if (conclusive) notePluginFailureLocked(name, definitive, allocator);
}

/// Risoluzione LAZY per estensione: carica solo il plugin che (da manifest)
/// dichiara `ext`; senza estensione bastano i fallback immagine/testo. Per
/// estensioni fuori manifest — o manifest stantio rispetto al plugin reale —
/// si tenta il registro dei plugin di terze parti (readdir, dlopen dei soli
/// file sconosciuti). Con `plugin_cache_mutex` acquisito.
fn ensureForExtLocked(ext: []const u8, io: std.Io, allocator: std.mem.Allocator) void {
    if (ext.len == 0) {
        loadPluginByNameLocked("image", io, allocator);
        loadPluginByNameLocked("text", io, allocator);
        return;
    }
    if (findPluginByExtension(ext) != null) return;
    if (manifestPluginForExt(ext)) |name| {
        loadPluginByNameLocked(name, io, allocator);
        if (findPluginByExtension(ext) != null) return;
    }
    ensureThirdPartyLocked(io, allocator);
}

fn findPluginByName(type_name: []const u8) ?*const LoadedPlugin {
    for (plugin_registry.items) |*p| {
        if (std.mem.eql(u8, p.type_name, type_name)) return p;
    }
    return null;
}

fn findPluginByExtension(ext: []const u8) ?*const LoadedPlugin {
    if (ext.len == 0) return null;
    for (plugin_registry.items) |*p| {
        for (p.extensions) |e| {
            if (asciiEqualIgnoreCase(ext, e)) return p;
        }
    }
    return null;
}

// `getenv` is in the C runtime on every platform we target.
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

pub const RunResult = struct {
    stdout: []u8,
    exit_code: u8,

    pub fn deinit(self: *RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
    }
};

/// Timeout di default per i tool esterni lanciati con `runCapture`.
pub const default_run_timeout_ms: u32 = 60_000;

/// Capacità iniziale del buffer di stdout di `runCapture`. Senza pre-allocazione
/// la cattura di un output grande (il PPM di `pdftoppm` sono decine di MB) parte
/// da zero e paga tutta la catena di realloc+memcpy della crescita geometrica.
/// 1 MB è irrilevante come picco e copre in un colpo solo l'output tipico;
/// `toOwnedSlice` restringe comunque all'esatto alla fine, quindi i tool che
/// stampano quattro byte (pdfinfo, ffprobe) non pagano nulla di permanente.
pub const default_capture_capacity: usize = 1024 * 1024;

/// Tetto sullo stdout catturato da `runCapture`: oltre, il processo viene terminato
/// e si ritorna `error.OutputTooLarge`. Senza, l'unico limite era il timeout: un
/// archivio con milioni di voci (bsdtar), appunti enormi (wl-paste) o un tool
/// impazzito potevano riempire la RAM in 60 secondi. Gli output leciti più grandi
/// sono i pixel grezzi di un'immagine (4096² × 3 = 50 MB).
pub const max_capture_bytes: usize = 512 * 1024 * 1024;

/// Esegue un comando catturandone lo stdout, senza dipendere da `std.Io`
/// (`std.process.run` si blocca dentro i plugin dinamici: l'`io` dell'host non
/// attraversa il confine DynLib). L'implementazione è per-OS: `posix_spawn` +
/// pipe su Unix, `CreateProcessW` + pipe anonima su Windows. Deadline
/// complessiva di `default_run_timeout_ms`: un tool appeso non può bloccare il
/// worker per sempre (vedi `runCaptureTimeout` per un valore esplicito).
pub fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8) !RunResult {
    return sub.runCapture(allocator, argv, default_run_timeout_ms, default_capture_capacity, null);
}

/// Come `runCapture`, con deadline complessiva esplicita: alla scadenza il
/// processo viene terminato (SIGKILL / TerminateProcess) e ritorna `error.Timeout`.
pub fn runCaptureTimeout(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32) !RunResult {
    return sub.runCapture(allocator, argv, timeout_ms, default_capture_capacity, null);
}

/// Come `runCaptureTimeout`, interrompibile: quando `cancel` diventa vero (lo
/// si controlla ogni ~50 ms) il processo viene terminato e ritorna
/// `error.Canceled`. Su Unix il figlio ha un suo gruppo di processi e si
/// termina il gruppo intero: anche i nipoti (es. deno lanciato da yt-dlp).
pub fn runCaptureCancel(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, cancel: *const std.atomic.Value(bool)) !RunResult {
    return sub.runCapture(allocator, argv, timeout_ms, default_capture_capacity, cancel);
}

/// Come `runCaptureTimeout`, con un hint ESPLICITO di capacità iniziale per lo
/// stdout: chi conosce già l'ordine di grandezza dell'output (es. larghezza ×
/// altezza × 3 di un PPM) evita del tutto le riallocazioni intermedie.
pub fn runCaptureCapacity(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, capacity_hint: usize) !RunResult {
    return sub.runCapture(allocator, argv, timeout_ms, capacity_hint, null);
}

/// Lancia un programma che deve solo PARTIRE (`xdg-open`): stdout e stderr su
/// /dev/null, e si aspetta la sua uscita per al più `wait_ms`. true se è uscito
/// con 0, o se alla scadenza sta ancora girando.
///
/// Non si usa `runCapture` perché cattura lo stdout con una pipe: se il programma
/// lancia a sua volta un processo che resta vivo (il browser, quando `xdg-open`
/// non ha un desktop a cui delegare), quello eredita la pipe e la fine del flusso
/// non arriva mai. Si aspettava il timeout intero e l'apertura riuscita veniva
/// presa per un fallimento. Solo POSIX: su Windows c'è ShellExecute.
pub fn runDetached(allocator: std.mem.Allocator, argv: []const []const u8, wait_ms: u32) bool {
    if (comptime builtin.os.tag == .windows) return false;
    return sub.runDetached(allocator, argv, wait_ms) catch false;
}

/// Legge un intero file senza `std.Io` (open/read/close libc su Unix,
/// CreateFileW/ReadFile su Windows): come runCapture, evita che l'io dell'host
/// si blocchi dentro un plugin dinamico. Il chiamante possiede il buffer.
pub fn readFileLibc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    return sub.readFile(allocator, path, max_bytes);
}

/// Legge gli ultimi `n` byte del file (o meno, se è più corto), senza `std.Io`.
/// Per le strutture che i formati mettono in coda (ultima pagina Ogg, `moov`
/// dei MP4 non-faststart) quando l'host ha passato solo un prefisso.
pub fn readFileTailLibc(allocator: std.mem.Allocator, path: []const u8, n: usize) ![]u8 {
    return sub.readFileTail(allocator, path, n);
}

/// Dimensione del file senza `std.Io` (per i plugin che ricevono solo un
/// prefisso di contenuto ma mostrano la dimensione reale).
pub fn fileSizeLibc(allocator: std.mem.Allocator, path: []const u8) ?u64 {
    return sub.fileSize(allocator, path) catch null;
}

/// Per-OS subprocess + raw file-read backend. Only the selected arm is analyzed, so the
/// POSIX externs never reach a Windows link and vice-versa.
const sub = switch (builtin.os.tag) {
    .windows => struct {
        const HANDLE = ?*anyopaque;
        const SECURITY_ATTRIBUTES = extern struct { nLength: u32, lpSecurityDescriptor: ?*anyopaque, bInheritHandle: i32 };
        const STARTUPINFOW = extern struct {
            cb: u32,
            lpReserved: ?[*:0]u16 = null,
            lpDesktop: ?[*:0]u16 = null,
            lpTitle: ?[*:0]u16 = null,
            dwX: u32 = 0,
            dwY: u32 = 0,
            dwXSize: u32 = 0,
            dwYSize: u32 = 0,
            dwXCountChars: u32 = 0,
            dwYCountChars: u32 = 0,
            dwFillAttribute: u32 = 0,
            dwFlags: u32 = 0,
            wShowWindow: u16 = 0,
            cbReserved2: u16 = 0,
            lpReserved2: ?*u8 = null,
            hStdInput: HANDLE = null,
            hStdOutput: HANDLE = null,
            hStdError: HANDLE = null,
        };
        const PROCESS_INFORMATION = extern struct { hProcess: HANDLE, hThread: HANDLE, dwProcessId: u32, dwThreadId: u32 };
        extern "kernel32" fn CreatePipe(hReadPipe: *HANDLE, hWritePipe: *HANDLE, lpPipeAttributes: ?*const SECURITY_ATTRIBUTES, nSize: u32) callconv(.winapi) i32;
        extern "kernel32" fn SetHandleInformation(hObject: HANDLE, dwMask: u32, dwFlags: u32) callconv(.winapi) i32;
        extern "kernel32" fn CreateProcessW(lpApplicationName: ?[*:0]const u16, lpCommandLine: ?[*:0]u16, lpProcessAttributes: ?*anyopaque, lpThreadAttributes: ?*anyopaque, bInheritHandles: i32, dwCreationFlags: u32, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?[*:0]const u16, lpStartupInfo: *const STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.winapi) i32;
        extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) i32;
        extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) i32;
        extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
        extern "kernel32" fn GetExitCodeProcess(hProcess: HANDLE, lpExitCode: *u32) callconv(.winapi) i32;
        extern "kernel32" fn PeekNamedPipe(hNamedPipe: HANDLE, lpBuffer: ?[*]u8, nBufferSize: u32, lpBytesRead: ?*u32, lpTotalBytesAvail: ?*u32, lpBytesLeftThisMessage: ?*u32) callconv(.winapi) i32;
        extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.winapi) i32;
        extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
        extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
        extern "kernel32" fn CreateFileW(lpFileName: [*:0]const u16, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: HANDLE) callconv(.winapi) HANDLE;
        const HANDLE_FLAG_INHERIT: u32 = 0x00000001;
        const STARTF_USESTDHANDLES: u32 = 0x00000100;
        const CREATE_NO_WINDOW: u32 = 0x08000000;
        const GENERIC_READ: u32 = 0x80000000;
        const FILE_SHARE_READ: u32 = 0x00000001;
        const OPEN_EXISTING: u32 = 3;
        const INVALID_HANDLE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
        const WAIT_OBJECT_0: u32 = 0;
        const WAIT_TIMEOUT: u32 = 0x00000102;

        fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, capacity_hint: usize, cancel: ?*const std.atomic.Value(bool)) !RunResult {
            if (argv.len == 0) return error.EmptyArgv;
            // Build a single, quoted command line (CreateProcess takes a string, not argv).
            // Quoting Win32 (regole di CommandLineToArgvW): le run di backslash che
            // precedono una virgoletta — o la `"` di chiusura dell'argomento — vanno
            // raddoppiate, poi la virgoletta letterale si escapa con un backslash;
            // altrimenti un argomento che termina con `\` fonderebbe i successivi.
            var cmd: std.ArrayList(u8) = .empty;
            defer cmd.deinit(allocator);
            for (argv, 0..) |a, i| {
                if (i != 0) try cmd.append(allocator, ' ');
                try cmd.append(allocator, '"');
                var bs: usize = 0;
                for (a) |ch| {
                    if (ch == '\\') {
                        bs += 1;
                        continue;
                    }
                    if (ch == '"') {
                        // 2n+1 backslash: i letterali raddoppiati + l'escape della virgoletta.
                        try cmd.appendNTimes(allocator, '\\', bs * 2 + 1);
                        try cmd.append(allocator, '"');
                    } else {
                        // Backslash non seguiti da virgoletta: letterali, nessun raddoppio.
                        try cmd.appendNTimes(allocator, '\\', bs);
                        try cmd.append(allocator, ch);
                    }
                    bs = 0;
                }
                // Backslash in coda: raddoppiati, o escaperebbero la `"` di chiusura.
                try cmd.appendNTimes(allocator, '\\', bs * 2);
                try cmd.append(allocator, '"');
            }
            const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd.items);
            defer allocator.free(cmd_w);

            const sa = SECURITY_ATTRIBUTES{ .nLength = @sizeOf(SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = 1 };
            var h_read: HANDLE = null;
            var h_write: HANDLE = null;
            if (CreatePipe(&h_read, &h_write, &sa, 0) == 0) return error.PipeFailed;
            defer _ = CloseHandle(h_read);
            _ = SetHandleInformation(h_read, HANDLE_FLAG_INHERIT, 0); // parent end not inherited

            // stderr NON sulla stessa pipe dello stdout parsato (un warning del
            // tool romperebbe il parse): con STARTF_USESTDHANDLES un handle null
            // equivale a "nessuno stderr" per il figlio.
            var si = STARTUPINFOW{ .cb = @sizeOf(STARTUPINFOW), .dwFlags = STARTF_USESTDHANDLES, .hStdOutput = h_write, .hStdError = null };
            var pi: PROCESS_INFORMATION = undefined;
            const ok = CreateProcessW(null, cmd_w, null, null, 1, CREATE_NO_WINDOW, null, null, &si, &pi);
            _ = CloseHandle(h_write); // parent keeps only the read end
            if (ok == 0) return error.CommandNotFound;
            defer _ = CloseHandle(pi.hProcess);
            defer _ = CloseHandle(pi.hThread);

            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            // Capacità iniziale in UN colpo solo (vedi `default_capture_capacity`).
            if (capacity_hint > 0) try out.ensureTotalCapacityPrecise(allocator, capacity_hint);
            var buf: [65536]u8 = undefined;
            // Lettura con deadline complessiva: una ReadFile bloccante su un figlio
            // appeso non raggiungerebbe mai il wait, quindi si sonda la pipe con
            // PeekNamedPipe e si legge solo quando ci sono byte disponibili; alla
            // scadenza il figlio viene terminato e si ritorna errore.
            const deadline: u64 = GetTickCount64() + timeout_ms;
            while (true) {
                if (cancel) |c| if (c.load(.acquire)) {
                    _ = TerminateProcess(pi.hProcess, 1);
                    _ = WaitForSingleObject(pi.hProcess, 5000);
                    return error.Canceled;
                };
                if (out.items.len > max_capture_bytes) {
                    _ = TerminateProcess(pi.hProcess, 1);
                    _ = WaitForSingleObject(pi.hProcess, 5000);
                    return error.OutputTooLarge;
                }
                var avail: u32 = 0;
                if (PeekNamedPipe(h_read, null, 0, null, &avail, null) == 0) break; // pipe chiusa → EOF
                if (avail > 0) {
                    // Con capacità libera si legge DIRETTAMENTE in coda al buffer:
                    // niente rimbalzo su `buf` + memcpy.
                    const spare = out.capacity - out.items.len;
                    if (spare > 0) {
                        var got_direct: u32 = 0;
                        const want: u32 = @intCast(@min(@as(usize, avail), spare));
                        if (ReadFile(h_read, out.items.ptr + out.items.len, want, &got_direct, null) == 0 or got_direct == 0) break;
                        out.items.len += got_direct;
                        continue;
                    }
                    var got: u32 = 0;
                    if (ReadFile(h_read, &buf, @min(avail, buf.len), &got, null) == 0 or got == 0) break;
                    try out.appendSlice(allocator, buf[0..got]);
                    continue;
                }
                // Niente dati: figlio già uscito → fine; ancora vivo → si controlla
                // la deadline e si attende un attimo prima di risondare.
                if (WaitForSingleObject(pi.hProcess, 0) == WAIT_OBJECT_0) break;
                if (GetTickCount64() >= deadline) {
                    _ = TerminateProcess(pi.hProcess, 1);
                    _ = WaitForSingleObject(pi.hProcess, 5000);
                    return error.Timeout;
                }
                Sleep(10);
            }
            // Attesa finale col budget residuo: copre il figlio che ha chiuso lo
            // stdout ma non esce; su WAIT_TIMEOUT lo si termina e si ritorna errore.
            const now = GetTickCount64();
            const wait_ms: u32 = if (deadline > now) @intCast(@min(deadline - now, std.math.maxInt(u32))) else 0;
            if (WaitForSingleObject(pi.hProcess, wait_ms) == WAIT_TIMEOUT) {
                _ = TerminateProcess(pi.hProcess, 1);
                _ = WaitForSingleObject(pi.hProcess, 5000);
                return error.Timeout;
            }
            var code: u32 = 1;
            _ = GetExitCodeProcess(pi.hProcess, &code);
            return .{ .stdout = try out.toOwnedSlice(allocator), .exit_code = @truncate(code) };
        }

        fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
            const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
            defer allocator.free(path_w);
            const h = CreateFileW(path_w.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
            if (h == INVALID_HANDLE) return error.OpenFailed;
            defer _ = CloseHandle(h);
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            // Dimensione nota dall'handle → capacità esatta in una volta sola e
            // lettura DIRETTA dentro il buffer, invece di crescere a chunk da
            // 64 KB (log2(N) riallocazioni + ricopiature dell'intero contenuto).
            var fsize: i64 = 0;
            if (GetFileSizeEx(h, &fsize) != 0 and fsize > 0)
                try out.ensureTotalCapacityPrecise(allocator, @min(@as(usize, @intCast(fsize)), max_bytes));
            var buf: [65536]u8 = undefined;
            while (out.items.len < max_bytes) {
                const remaining = max_bytes - out.items.len;
                const spare = out.capacity - out.items.len;
                var got: u32 = 0;
                if (spare > 0) {
                    const want: u32 = @intCast(@min(@min(spare, remaining), @as(usize, 1 << 30)));
                    if (ReadFile(h, out.items.ptr + out.items.len, want, &got, null) == 0) return error.ReadFailed;
                    if (got == 0) break;
                    out.items.len += got;
                    continue;
                }
                // Pipe/dimensione ignota, o file cresciuto dopo la stat: chunk classico.
                if (ReadFile(h, &buf, @intCast(@min(buf.len, remaining)), &got, null) == 0) return error.ReadFailed;
                if (got == 0) break;
                try out.appendSlice(allocator, buf[0..got]);
            }
            return out.toOwnedSlice(allocator);
        }

        extern "kernel32" fn GetFileSizeEx(hFile: HANDLE, lpFileSize: *i64) callconv(.winapi) i32;
        extern "kernel32" fn SetFilePointerEx(hFile: HANDLE, liDistanceToMove: i64, lpNewFilePointer: ?*i64, dwMoveMethod: u32) callconv(.winapi) i32;

        fn fileSize(allocator: std.mem.Allocator, path: []const u8) !u64 {
            const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
            defer allocator.free(path_w);
            const h = CreateFileW(path_w.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
            if (h == INVALID_HANDLE) return error.OpenFailed;
            defer _ = CloseHandle(h);
            var size: i64 = 0;
            if (GetFileSizeEx(h, &size) == 0 or size < 0) return error.ReadFailed;
            return @intCast(size);
        }

        fn readFileTail(allocator: std.mem.Allocator, path: []const u8, n: usize) ![]u8 {
            const path_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, path);
            defer allocator.free(path_w);
            const h = CreateFileW(path_w.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
            if (h == INVALID_HANDLE) return error.OpenFailed;
            defer _ = CloseHandle(h);
            var size: i64 = 0;
            if (GetFileSizeEx(h, &size) == 0 or size < 0) return error.ReadFailed;
            const want: usize = @min(n, @as(usize, @intCast(size)));
            if (SetFilePointerEx(h, size - @as(i64, @intCast(want)), null, 0) == 0) return error.ReadFailed; // FILE_BEGIN
            const buf = try allocator.alloc(u8, want);
            errdefer allocator.free(buf);
            var off: usize = 0;
            while (off < want) {
                var got: u32 = 0;
                const chunk: u32 = @intCast(@min(want - off, 1 << 20));
                if (ReadFile(h, buf.ptr + off, chunk, &got, null) == 0 or got == 0) return error.ReadFailed;
                off += got;
            }
            return buf;
        }
    },
    else => struct {
        extern "c" fn pipe(fds: *[2]c_int) c_int;
        extern "c" fn pipe2(fds: *[2]c_int, flags: c_int) c_int;
        extern "c" fn fcntl(fd: c_int, cmd: c_int, arg: c_int) c_int;
        extern "c" fn read(fd: c_int, buf: [*]u8, count: usize) isize;
        extern "c" fn close(fd: c_int) c_int;
        extern "c" fn open(path: [*:0]const u8, flags: c_int) c_int;
        extern "c" fn waitpid(pid: c_int, status: ?*c_int, options: c_int) c_int;
        extern "c" fn kill(pid: c_int, sig: c_int) c_int;
        extern "c" fn poll(fds: [*]PollFd, nfds: c_ulong, timeout: c_int) c_int;
        extern "c" fn clock_gettime(clk_id: c_int, tp: *Timespec) c_int;
        // posix_spawn: fork+exec+ricerca PATH in modo sicuro anche in processi
        // multi-thread (niente malloc nel figlio forkato → niente deadlock).
        extern "c" fn posix_spawnp(pid: *c_int, file: [*:0]const u8, file_actions: ?*const anyopaque, attrp: ?*const anyopaque, argv: [*:null]const ?[*:0]const u8, envp: [*:null]const ?[*:0]const u8) c_int;
        extern "c" fn posix_spawn_file_actions_init(fa: *anyopaque) c_int;
        extern "c" fn posix_spawnattr_init(attr: *anyopaque) c_int;
        extern "c" fn posix_spawnattr_destroy(attr: *anyopaque) c_int;
        extern "c" fn posix_spawnattr_setflags(attr: *anyopaque, flags: c_short) c_int;
        extern "c" fn posix_spawnattr_setpgroup(attr: *anyopaque, pgroup: c_int) c_int;
        /// Uguale su glibc, musl, Bionic e Darwin.
        const POSIX_SPAWN_SETPGROUP: c_short = 0x02;
        extern "c" fn posix_spawn_file_actions_destroy(fa: *anyopaque) c_int;
        extern "c" fn posix_spawn_file_actions_adddup2(fa: *anyopaque, fd: c_int, newfd: c_int) c_int;
        extern "c" fn posix_spawn_file_actions_addclose(fa: *anyopaque, fd: c_int) c_int;
        extern "c" fn posix_spawn_file_actions_addopen(fa: *anyopaque, fd: c_int, path: [*:0]const u8, oflag: c_int, mode: c_uint) c_int;
        extern "c" var environ: [*:null]const ?[*:0]const u8;

        const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
        const POLLIN: c_short = 0x001;
        const Timespec = extern struct { sec: c_long, nsec: c_long };
        const CLOCK_MONOTONIC: c_int = if (builtin.os.tag.isDarwin()) 6 else 1;

        /// Millisecondi di clock monotonico via libc (niente `std.Io`, che non
        /// attraversa il confine dei plugin dinamici). Per le deadline.
        fn nowMs() i64 {
            var ts: Timespec = .{ .sec = 0, .nsec = 0 };
            _ = clock_gettime(CLOCK_MONOTONIC, &ts);
            return @as(i64, @intCast(ts.sec)) * 1000 + @as(i64, @intCast(@divTrunc(ts.nsec, 1_000_000)));
        }

        /// pipe con O_CLOEXEC: senza, un figlio spawnato in parallelo da un ALTRO
        /// thread eredita il write-end e l'EOF sul read-end non arriva finché
        /// anche quello non esce (deadlock del loop di lettura). L'`adddup2` del
        /// figlio giusto azzera CLOEXEC sul fd duplicato, quindi basta questo.
        /// Su Linux `pipe2` è atomica; su Darwin (niente pipe2) fallback
        /// `pipe` + `fcntl(FD_CLOEXEC)`, best-effort.
        fn pipeCloexec(fds: *[2]c_int) c_int {
            if (builtin.os.tag == .linux) {
                return pipe2(fds, 0o2000000); // O_CLOEXEC (Linux)
            } else {
                if (pipe(fds) != 0) return -1;
                _ = fcntl(fds[0], 2, 1); // F_SETFD, FD_CLOEXEC
                _ = fcntl(fds[1], 2, 1);
                return 0;
            }
        }

        fn runCapture(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u32, capacity_hint: usize, cancel: ?*const std.atomic.Value(bool)) !RunResult {
            if (argv.len == 0) return error.EmptyArgv;

            // argv null-terminato costruito PRIMA della fork: nel figlio non si può
            // allocare in sicurezza (multi-thread → solo funzioni async-signal-safe).
            const argvZ = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
            defer {
                for (argvZ[0..argv.len]) |a| if (a) |p| allocator.free(std.mem.span(p));
                allocator.free(argvZ);
            }
            @memset(argvZ[0..argv.len], null); // il defer libera solo ciò che è stato duplicato
            for (argv, 0..) |a, i| argvZ[i] = (try allocator.dupeSentinel(u8, a, 0)).ptr;

            var fds: [2]c_int = undefined;
            if (pipeCloexec(&fds) != 0) return error.PipeFailed;
            const read_fd = fds[0];
            const write_fd = fds[1];
            var read_fd_open = true;
            defer if (read_fd_open) {
                _ = close(read_fd);
            };

            var fa: [256]u8 align(16) = undefined;
            if (posix_spawn_file_actions_init(&fa) != 0) {
                _ = close(write_fd);
                return error.SpawnInit;
            }
            defer _ = posix_spawn_file_actions_destroy(&fa);
            _ = posix_spawn_file_actions_adddup2(&fa, write_fd, 1);
            // stderr del figlio su /dev/null: il terminale dell'host è in
            // raw-mode e i warning dei tool esterni lo sporcherebbero.
            _ = posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", 1, 0); // O_WRONLY
            _ = posix_spawn_file_actions_addclose(&fa, read_fd);

            // Interrompibile: gruppo di processi proprio (pgid = pid del figlio),
            // così l'annullamento termina anche i processi che il figlio lancia.
            var attr: [512]u8 align(16) = undefined;
            const use_attr = cancel != null and posix_spawnattr_init(&attr) == 0;
            defer if (use_attr) {
                _ = posix_spawnattr_destroy(&attr);
            };
            if (use_attr) {
                _ = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
                _ = posix_spawnattr_setpgroup(&attr, 0);
            }

            var pid: c_int = 0;
            const rc = posix_spawnp(&pid, argvZ[0].?, &fa, if (use_attr) @ptrCast(&attr) else null, argvZ.ptr, environ);
            _ = close(write_fd);
            if (rc != 0) return if (rc == 2) error.CommandNotFound else error.SpawnFailed; // 2 = ENOENT

            // Da qui il figlio esiste: su OGNI percorso d'errore va reaped (niente
            // zombie). Si chiude prima il read-end e si manda SIGKILL, così il
            // waitpid non può bloccarsi su un figlio che sta ancora scrivendo.
            var reaped = false;
            errdefer if (!reaped) {
                if (read_fd_open) {
                    _ = close(read_fd);
                    read_fd_open = false;
                }
                _ = kill(if (use_attr) -pid else pid, 9); // SIGKILL (al gruppo, se proprio)
                _ = waitpid(pid, null, 0);
            };

            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            // Capacità iniziale in UN colpo solo (vedi `default_capture_capacity`).
            if (capacity_hint > 0) try out.ensureTotalCapacityPrecise(allocator, capacity_hint);
            var buf: [65536]u8 = undefined;
            // Loop di lettura con deadline complessiva via poll(): un tool esterno
            // appeso non può bloccare il worker per sempre — alla scadenza
            // l'errdefer sopra termina e reap-a il figlio.
            const deadline: i64 = nowMs() + timeout_ms;
            var pfd = [1]PollFd{.{ .fd = read_fd, .events = POLLIN, .revents = 0 }};
            while (true) {
                if (cancel) |c| if (c.load(.acquire)) return error.Canceled;
                // L'errdefer sopra termina e reap-a il figlio.
                if (out.items.len > max_capture_bytes) return error.OutputTooLarge;
                const remaining = deadline - nowMs();
                if (remaining <= 0) return error.Timeout;
                // Con un flag d'annullamento il poll dura al più 50 ms.
                const slice: i64 = if (cancel != null) @min(remaining, 50) else remaining;
                const pr = poll(&pfd, 1, @intCast(@min(slice, std.math.maxInt(c_int))));
                if (pr == 0) continue; // scaduto il tratto: si ricontrolla la deadline
                if (pr < 0) continue; // EINTR e simili: la deadline limita comunque il loop
                // Con capacità libera si legge DIRETTAMENTE in coda al buffer:
                // niente rimbalzo su `buf` + memcpy.
                const spare = out.capacity - out.items.len;
                if (spare > 0) {
                    const n = read(read_fd, out.items.ptr + out.items.len, spare);
                    if (n <= 0) break;
                    out.items.len += @intCast(n);
                    continue;
                }
                const n = read(read_fd, &buf, buf.len);
                if (n <= 0) break;
                try out.appendSlice(allocator, buf[0..@intCast(n)]);
            }

            var status: c_int = 0;
            _ = waitpid(pid, &status, 0);
            reaped = true;
            // WIFEXITED / WEXITSTATUS espansi a mano (glibc): byte basso = segnale.
            const code: u8 = if ((status & 0x7f) == 0) @intCast((status >> 8) & 0xff) else 1;
            return .{ .stdout = try out.toOwnedSlice(allocator), .exit_code = code };
        }

        const WNOHANG: c_int = 1;

        fn runDetached(allocator: std.mem.Allocator, argv: []const []const u8, wait_ms: u32) !bool {
            if (argv.len == 0) return error.EmptyArgv;
            const argvZ = try allocator.allocSentinel(?[*:0]const u8, argv.len, null);
            defer {
                for (argvZ[0..argv.len]) |a| if (a) |p| allocator.free(std.mem.span(p));
                allocator.free(argvZ);
            }
            @memset(argvZ[0..argv.len], null);
            for (argv, 0..) |a, i| argvZ[i] = (try allocator.dupeSentinel(u8, a, 0)).ptr;

            var fa: [256]u8 align(16) = undefined;
            if (posix_spawn_file_actions_init(&fa) != 0) return error.SpawnInit;
            defer _ = posix_spawn_file_actions_destroy(&fa);
            _ = posix_spawn_file_actions_addopen(&fa, 1, "/dev/null", 1, 0); // O_WRONLY
            _ = posix_spawn_file_actions_addopen(&fa, 2, "/dev/null", 1, 0);

            var pid: c_int = 0;
            const rc = posix_spawnp(&pid, argvZ[0].?, &fa, null, argvZ.ptr, environ);
            if (rc != 0) return if (rc == 2) error.CommandNotFound else error.SpawnFailed;

            const deadline: i64 = nowMs() + wait_ms;
            var none: [1]PollFd = undefined;
            while (true) {
                var status: c_int = 0;
                const w = waitpid(pid, &status, WNOHANG);
                if (w == pid) return (status & 0x7f) == 0 and ((status >> 8) & 0xff) == 0;
                if (w < 0) return false;
                // Ancora vivo alla scadenza: sta tenendo in primo piano ciò che ha
                // lanciato. Lo si lascia girare (resterà uno zombie fino alla nostra
                // uscita, se finisce prima): ucciderlo chiuderebbe il browser.
                if (nowMs() >= deadline) return true;
                _ = poll(&none, 0, 20); // attesa di 20 ms senza `std.Io`
            }
        }

        fn readFile(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
            const path_z = try allocator.dupeSentinel(u8, path, 0);
            defer allocator.free(path_z);

            const fd = open(path_z.ptr, 0); // O_RDONLY
            if (fd < 0) return error.OpenFailed;
            defer _ = close(fd);

            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            // Dimensione nota dall'fd (lseek SEEK_END, poi si torna a SEEK_SET):
            // capacità esatta in una volta sola e lettura DIRETTA dentro il
            // buffer, invece di crescere a chunk da 64 KB (log2(N) riallocazioni
            // più la ricopiatura dell'intero contenuto a ogni crescita). Su ciò
            // che non è seekabile (pipe, /proc) lseek fallisce o dà 0 → resta il
            // vecchio loop a chunk, che è anche il fallback se il file cresce.
            const end = lseek(fd, 0, 2); // SEEK_END
            if (end > 0 and lseek(fd, 0, 0) == 0) // SEEK_SET
                try out.ensureTotalCapacityPrecise(allocator, @min(@as(usize, @intCast(end)), max_bytes));

            var buf: [65536]u8 = undefined;
            while (out.items.len < max_bytes) {
                const remaining = max_bytes - out.items.len;
                const spare = out.capacity - out.items.len;
                if (spare > 0) {
                    const n = read(fd, out.items.ptr + out.items.len, @min(spare, remaining));
                    if (n < 0) return error.ReadFailed;
                    if (n == 0) break;
                    out.items.len += @intCast(n);
                    continue;
                }
                const n = read(fd, &buf, @min(buf.len, remaining));
                if (n < 0) return error.ReadFailed;
                if (n == 0) break;
                try out.appendSlice(allocator, buf[0..@intCast(n)]);
            }
            return out.toOwnedSlice(allocator);
        }

        extern "c" fn lseek(fd: c_int, offset: i64, whence: c_int) i64;

        fn fileSize(allocator: std.mem.Allocator, path: []const u8) !u64 {
            const path_z = try allocator.dupeSentinel(u8, path, 0);
            defer allocator.free(path_z);
            const fd = open(path_z.ptr, 0);
            if (fd < 0) return error.OpenFailed;
            defer _ = close(fd);
            const size = lseek(fd, 0, 2); // SEEK_END
            if (size < 0) return error.ReadFailed;
            return @intCast(size);
        }

        fn readFileTail(allocator: std.mem.Allocator, path: []const u8, n: usize) ![]u8 {
            const path_z = try allocator.dupeSentinel(u8, path, 0);
            defer allocator.free(path_z);
            const fd = open(path_z.ptr, 0);
            if (fd < 0) return error.OpenFailed;
            defer _ = close(fd);
            const size = lseek(fd, 0, 2); // SEEK_END
            if (size < 0) return error.ReadFailed;
            const want: usize = @min(n, @as(usize, @intCast(size)));
            if (lseek(fd, size - @as(i64, @intCast(want)), 0) < 0) return error.ReadFailed; // SEEK_SET
            const buf = try allocator.alloc(u8, want);
            errdefer allocator.free(buf);
            var off: usize = 0;
            while (off < want) {
                const r = read(fd, buf.ptr + off, want - off);
                if (r <= 0) return error.ReadFailed;
                off += @intCast(r);
            }
            return buf;
        }
    },
};

/// Cache pigra di `defaultMaxSize`: 0 = non ancora calcolato. Evita di aprire
/// e analizzare /proc/meminfo a OGNI decode (×2 per navigazione + prefetch).
var default_max_size_cache: std.atomic.Value(usize) = .init(0);

/// Budget di dimensione file di default, proporzionale alla memoria disponibile:
/// metà di MemAvailable (il file viene letto in RAM e il decoder vi alloca sopra).
/// Fallback a 128 MB se /proc/meminfo non è leggibile. Calcolato una sola volta.
fn defaultMaxSize(io: std.Io, allocator: std.mem.Allocator) usize {
    const cached = default_max_size_cache.load(.monotonic);
    if (cached != 0) return cached;
    const computed = computeDefaultMaxSize(io, allocator);
    default_max_size_cache.store(computed, .monotonic);
    return computed;
}

fn computeDefaultMaxSize(io: std.Io, allocator: std.mem.Allocator) usize {
    const fallback: usize = 128 * 1024 * 1024;
    // /proc/meminfo riporta dimensione 0 in stat, quindi un reader posizionale
    // (readFileAlloc) legge zero byte e si finisce sempre nel fallback: serve un
    // reader in streaming che legga fino all'EOF reale.
    var file = std.Io.Dir.cwd().openFile(io, "/proc/meminfo", .{}) catch return fallback;
    defer file.close(io);
    var buf: [8 * 1024]u8 = undefined;
    var reader = file.readerStreaming(io, &buf);
    const data = reader.interface.allocRemaining(allocator, std.Io.Limit.limited(64 * 1024)) catch return fallback;
    defer allocator.free(data);
    const key = "MemAvailable:";
    const start = std.mem.indexOf(u8, data, key) orelse return fallback;
    var tokens = std.mem.tokenizeAny(u8, data[start + key.len ..], " \t\n");
    const num = tokens.next() orelse return fallback;
    const kb = std.fmt.parseInt(usize, num, 10) catch return fallback;
    return (kb * 1024) / 2;
}

/// Legge i primi `buf.len` byte del file (meno se è più corto).
fn probeFile(io: std.Io, path: []const u8, buf: []u8) ![]const u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var rbuf: [1024]u8 = undefined;
    var reader = file.readerStreaming(io, &rbuf);
    const n = reader.interface.readSliceShort(buf) catch 0;
    return buf[0..n];
}

/// Stesso criterio di `isBinary` in decoders/text.zig, applicato dall'host al
/// PROBE invece che al file intero: byte NULL sopra l'1% (o più di 16), oppure
/// NULL + caratteri di controllo non stampabili sopra il 10% del campione.
/// Le due implementazioni vanno tenute allineate: qui serve solo a evitare di
/// caricare in RAM un file che il plugin `text` scarterebbe comunque.
fn probeLooksBinary(sample: []const u8) bool {
    if (sample.len == 0) return false;
    var null_count: usize = 0;
    var control_count: usize = 0;
    for (sample) |b| {
        if (b == 0) {
            null_count += 1;
        } else if ((b < 0x09) or (b > 0x0D and b < 0x20 and b != 0x1B)) {
            control_count += 1;
        }
    }
    if (null_count > sample.len / 100 or null_count > 16) return true;
    if ((null_count + control_count) > sample.len / 10) return true;
    return false;
}

/// Byte di campione per `probeLooksBinary`: esattamente gli 8 KB che
/// `decoders/text.zig` guarderebbe, così host e plugin danno lo stesso verdetto.
const binary_probe_bytes = 8192;

/// Foglio richiesto dal frammento del percorso: `foglio.xlsx#sheet=N`, con N
/// 1-based come il `#page=N` dei PDF. Null se il frammento è assente o di altra
/// natura (voce d'archivio, pagina). Vedi `decoders/office.zig`, che interpreta
/// lo stesso frammento per decidere quale foglio decodificare per intero.
fn sheetFromFragment(fragment: []const u8) ?usize {
    if (!std.mem.startsWith(u8, fragment, "sheet=")) return null;
    const n = std.fmt.parseInt(usize, fragment["sheet=".len..], 10) catch return null;
    return if (n == 0) null else n;
}

pub fn decode(path: []const u8, io: std.Io, allocator: std.mem.Allocator) Decoded {
    // Il messaggio va duplicato sull'allocator: `Decoded.deinit` libera `err`
    // incondizionatamente e un free su un letterale statico è UB.
    return decodeImpl(path, io, allocator, false) orelse .{ .err = allocator.dupe(u8, "decode fallito") catch "" };
}

/// Prima fase del caricamento progressivo: texture al tier coarse (256², da cache
/// se presente → resa quasi istantanea alla riapertura). Ritorna null se il plugin
/// risolto non offre `zuer_decode_coarse` (l'host allora fa solo `decode`).
pub fn decodeCoarse(path: []const u8, io: std.Io, allocator: std.mem.Allocator) ?Decoded {
    return decodeImpl(path, io, allocator, true);
}

/// Coordinata letta da un file: NaN e infiniti diventano 0. Un vertice non finito
/// avvelena il bounding box (centro e scala NaN) e a valle arriva a conversioni a
/// intero che su NaN vanno in panic (la proiezione della TUI).
pub fn finiteOrZero(x: f32) f32 {
    return if (std.math.isFinite(x)) x else 0;
}

/// Estensioni degli archivi "navigabili" dentro (anteprima delle voci). Deve
/// restare allineata alle estensioni dichiarate da archive.zig e tar.zig.
pub const isArchiveExt = pathfrag.isArchiveExt;

/// Il frammento `#…` in coda a un percorso (pagina, foglio, voce d'archivio): vedi
/// fragment.zig. Un `#` nel nome di un file o di una cartella non è un frammento.
pub const fragmentIndex = pathfrag.index;
pub const stripFragment = pathfrag.strip;

fn isTarExt(ext: []const u8) bool {
    return asciiEqualIgnoreCase(ext, "tar") or
        asciiEqualIgnoreCase(ext, "tgz") or
        asciiEqualIgnoreCase(ext, "tar.gz");
}

/// Apre un file DENTRO un archivio (`archivio.zip#voce`): estrae la voce in
/// `<cache>/extract/<chiave>/<voce>` in streaming (memoria costante, cap =
/// `max_size` sulla dimensione decompressa) e la ridecodifica col decoder giusto
/// per la sua estensione, riusando l'intera pipeline. Riaperture della stessa
/// voce riusano il file già estratto (chiave = path archivio + mtime).
fn decodeArchiveEntry(base_path: []const u8, entry: []const u8, io: std.Io, allocator: std.mem.Allocator, max_size: usize) ?Decoded {
    const extracted = extractArchiveEntry(base_path, entry, io, allocator, max_size) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile aprire '{s}' dentro l'archivio: {s}", .{ entry, @errorName(err) }) catch "";
        return .{ .err = msg };
    };
    defer allocator.free(extracted);
    // Ridecodifica il file materializzato: senza frammento → dispatch normale per
    // estensione, nessuna ricorsione nel ramo archivio.
    return decodeImpl(extracted, io, allocator, false);
}

/// Materializza la voce dell'archivio su disco e ne ritorna il path assoluto
/// (posseduto dal chiamante). Riusa il file se già estratto per questa versione.
/// Dove sta la cache, i nomi ammessi e la pulizia: extract_cache.zig.
fn extractArchiveEntry(base_path: []const u8, entry: []const u8, io: std.Io, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
    if (!extract_cache.isSafeEntryName(entry)) return error.UnsafeEntryName;

    const root_path = extract_cache.rootDir(allocator) orelse return error.NoCacheDir;
    defer allocator.free(root_path);

    // Una cartella per versione dell'archivio: modificato → chiave nuova →
    // riestrazione automatica.
    const bstat = try std.Io.Dir.cwd().statFile(io, base_path, .{});
    var key_buf: [16]u8 = undefined;
    const key_name = std.fmt.bufPrint(&key_buf, "{x}", .{extract_cache.key(base_path, bstat.mtime)}) catch unreachable;

    const rel_out = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ key_name, entry });
    defer allocator.free(rel_out);
    const out_abs = try std.fs.path.join(allocator, &.{ root_path, rel_out });
    errdefer allocator.free(out_abs);

    var root = try std.Io.Dir.cwd().openDir(io, root_path, .{});
    defer root.close(io);

    // Già estratta (stessa versione dell'archivio)? Riusa senza rileggere, e
    // segnala l'uso alla pulizia (sul file `.used`: la voce non si tocca).
    if (root.statFile(io, rel_out, .{})) |st| {
        if (st.kind == .file) {
            extract_cache.markUsed(io, root, key_name);
            return out_abs;
        }
    } else |_| {}

    var dest = try root.createDirPathOpen(io, key_name, .{});
    defer dest.close(io);

    // Estrazione ATOMICA: scrivi su un `.part` e rinomina solo a estrazione
    // completa. La statFile di riuso sopra cerca `entry` (mai il `.part`), quindi un
    // file parziale lasciato da un crash duro (SIGKILL, kernel panic) non viene mai
    // riusato come cache valida: alla riapertura manca `entry` → riestrazione.
    var tmp_buf: [extract_cache.part_name_max]u8 = undefined;
    const tmp_name = extract_cache.partName(&tmp_buf);

    const ext = getExtension(base_path);
    (if (isTarExt(ext))
        extractTarEntry(base_path, entry, tmp_name, io, dest, max_size)
    else
        extractZipEntry(base_path, entry, tmp_name, io, dest, allocator, max_size)) catch |err| {
        // Estrazione fallita a metà (disco pieno, archivio corrotto…): rimuovi il
        // parziale così non resta a sporcare la cache.
        dest.deleteFile(io, tmp_name) catch {};
        return err;
    };
    // Il `.part` sta in cima alla cartella dell'archivio: la sottocartella della
    // voce (`dir/b.txt`) va creata prima di rinominarlo lì.
    if (std.fs.path.dirname(entry)) |dn| dest.createDirPath(io, dn) catch {};
    dest.rename(tmp_name, dest, entry, io) catch |err| {
        dest.deleteFile(io, tmp_name) catch {};
        // Un'altra estrazione della stessa voce è arrivata prima e qualcuno la sta
        // già leggendo: su Windows un file aperto non si sostituisce. La voce c'è,
        // ed è quella buona.
        if (dest.statFile(io, entry, .{})) |st| {
            if (st.kind == .file) return out_abs;
        } else |_| {}
        return err;
    };

    const written: u64 = if (dest.statFile(io, entry, .{})) |st| st.size else |_| 0;
    extract_cache.noteExtracted(io, allocator, root_path, written);
    return out_abs;
}

fn extractZipEntry(base_path: []const u8, entry: []const u8, out_name: []const u8, io: std.Io, dest: std.Io.Dir, allocator: std.mem.Allocator, max_size: usize) !void {
    var file = try std.Io.Dir.cwd().openFile(io, base_path, .{});
    defer file.close(io);
    var rbuf: [8192]u8 = undefined;
    var reader = file.reader(io, &rbuf);

    // Localizza la central directory col seeking (EOCD/ZIP64) SENZA iterare le
    // voci: `Iterator.next()` abortirebbe su una entry cifrata/multi-disk anche se
    // non è quella cercata. Poi scan lenient della CD, coerente col listato — usa
    // il nome della CENTRAL directory, così il file estratto combacia con `out_abs`.
    const iter = try std.zip.Iterator.init(&reader);
    const cd_read: usize = @intCast(@min(iter.cd_size, @as(u64, 256 * 1024 * 1024)));
    const cd = try allocator.alloc(u8, cd_read);
    defer allocator.free(cd);
    try reader.seekTo(iter.cd_zip_offset);
    reader.interface.readSliceAll(cd) catch |err| switch (err) {
        error.EndOfStream => {},
        else => return error.ZipReadFailed,
    };

    const max32 = std.math.maxInt(u32);
    var pos: usize = 0;
    while (pos + 46 <= cd.len) {
        if (!std.mem.eql(u8, cd[pos..][0..4], &std.zip.central_file_header_sig)) break;
        const method = std.mem.readInt(u16, cd[pos + 10 ..][0..2], .little);
        var comp_size: u64 = std.mem.readInt(u32, cd[pos + 20 ..][0..4], .little);
        var unc_size: u64 = std.mem.readInt(u32, cd[pos + 24 ..][0..4], .little);
        const name_len = std.mem.readInt(u16, cd[pos + 28 ..][0..2], .little);
        const extra_len = std.mem.readInt(u16, cd[pos + 30 ..][0..2], .little);
        const comment_len = std.mem.readInt(u16, cd[pos + 32 ..][0..2], .little);
        var local_off: u64 = std.mem.readInt(u32, cd[pos + 42 ..][0..4], .little);

        const entry_end = pos + 46 + @as(usize, name_len) + extra_len + comment_len;
        if (entry_end > cd.len) break;
        const name = cd[pos + 46 ..][0..name_len];

        // ZIP64: campi saturati → valori reali nell'extra 0x0001, nell'ordine
        // uncompressed, compressed, local_header_offset (solo quelli saturati).
        if (unc_size == max32 or comp_size == max32 or local_off == max32) {
            var extra = cd[pos + 46 + name_len ..][0..extra_len];
            while (extra.len >= 4) {
                const id = std.mem.readInt(u16, extra[0..2], .little);
                const sz = std.mem.readInt(u16, extra[2..4], .little);
                if (4 + @as(usize, sz) > extra.len) break;
                if (id == 0x0001) {
                    var f = extra[4 .. 4 + sz];
                    if (unc_size == max32 and f.len >= 8) {
                        unc_size = std.mem.readInt(u64, f[0..8], .little);
                        f = f[8..];
                    }
                    if (comp_size == max32 and f.len >= 8) {
                        comp_size = std.mem.readInt(u64, f[0..8], .little);
                        f = f[8..];
                    }
                    if (local_off == max32 and f.len >= 8) {
                        local_off = std.mem.readInt(u64, f[0..8], .little);
                    }
                    break;
                }
                extra = extra[4 + sz ..];
            }
        }

        if (std.mem.eql(u8, name, entry)) {
            if (unc_size > max_size) return error.EntryTooLarge;
            return extractZipData(&reader, dest, io, out_name, method, unc_size, local_off);
        }
        pos = entry_end;
    }
    return error.EntryNotFound;
}

/// Decomprime una singola entry ZIP (store/deflate) dallo stream posizionato,
/// leggendo il local header per l'offset dei dati e scrivendo `entry` sotto `dest`.
fn extractZipData(reader: *std.Io.File.Reader, dest: std.Io.Dir, io: std.Io, out_name: []const u8, method: u16, unc_size: u64, local_off: u64) !void {
    try reader.seekTo(local_off);
    var lfh: [30]u8 = undefined;
    try reader.interface.readSliceAll(&lfh);
    if (!std.mem.eql(u8, lfh[0..4], &std.zip.local_file_header_sig)) return error.ZipBadFileOffset;
    const l_name = std.mem.readInt(u16, lfh[26..][0..2], .little);
    const l_extra = std.mem.readInt(u16, lfh[28..][0..2], .little);
    const data_off = local_off + 30 + @as(u64, l_name) + @as(u64, l_extra);

    var out = try createDestFile(dest, io, out_name);
    defer out.close(io);
    var obuf: [8192]u8 = undefined;
    var fw = out.writer(io, &obuf);

    try reader.seekTo(data_off);
    switch (method) {
        0 => try reader.interface.streamExact64(&fw.interface, unc_size),
        8 => {
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var dc = std.compress.flate.Decompress.init(&reader.interface, .raw, &window);
            try dc.reader.streamExact64(&fw.interface, unc_size);
        },
        else => return error.UnsupportedCompressionMethod,
    }
    try fw.end();
}

fn extractTarEntry(base_path: []const u8, entry: []const u8, out_name: []const u8, io: std.Io, dest: std.Io.Dir, max_size: usize) !void {
    var file = try std.Io.Dir.cwd().openFile(io, base_path, .{});
    defer file.close(io);
    var rbuf: [8192]u8 = undefined;
    var reader = file.reader(io, &rbuf);

    var magic: [2]u8 = .{ 0, 0 };
    _ = try file.readPositionalAll(io, &magic, 0);
    const is_gzip = magic[0] == 0x1f and magic[1] == 0x8b;

    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var dec: std.compress.flate.Decompress = undefined;
    var src: *std.Io.Reader = &reader.interface;
    if (is_gzip) {
        dec = std.compress.flate.Decompress.init(&reader.interface, .gzip, &window);
        src = &dec.reader;
    }

    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it = std.tar.Iterator.init(src, .{
        .file_name_buffer = &name_buf,
        .link_name_buffer = &link_buf,
    });
    while (try it.next()) |f| {
        if (f.kind != .file) continue;
        if (!std.mem.eql(u8, f.name, entry)) continue;
        if (f.size > max_size) return error.EntryTooLarge;

        var out_file = try createDestFile(dest, io, out_name);
        defer out_file.close(io);
        var obuf: [8192]u8 = undefined;
        var fw = out_file.writer(io, &obuf);
        try it.streamRemaining(f, &fw.interface);
        try fw.end();
        return;
    }
    return error.EntryNotFound;
}

/// Crea (con eventuali sottocartelle) e apre in scrittura il file di output per
/// una voce, sotto `dest`.
fn createDestFile(dest: std.Io.Dir, io: std.Io, name: []const u8) !std.Io.File {
    if (std.fs.path.dirname(name)) |dn| {
        var parent = try dest.createDirPathOpen(io, dn, .{});
        defer parent.close(io);
        return parent.createFile(io, std.fs.path.basename(name), .{});
    }
    return dest.createFile(io, name, .{});
}

/// Sostituisce il testo di `d` con una copia sanificata se non è UTF-8 valido
/// (byte non validi → U+FFFD). Senza memoria resta com'è: i consumatori che
/// iterano per codepoint usano comunque `utf8_lossy`.
fn ensureValidText(d: *Decoded, allocator: std.mem.Allocator) void {
    const text: *[]const u8 = switch (d.*) {
        .text => |*t| t,
        .markdown => |*m| &m.content,
        else => return,
    };
    const clean = (utf8_lossy.sanitized(allocator, text.*) catch return) orelse return;
    allocator.free(text.*);
    text.* = clean;
}

fn decodeImpl(path: []const u8, io: std.Io, allocator: std.mem.Allocator, coarse: bool) ?Decoded {
    const clean_path = pathfrag.strip(path);
    const entry_frag = pathfrag.of(path);

    // Limite di dimensione proporzionale alla memoria disponibile; ZUER_MAX_MB lo
    // forza a un valore assoluto. Pre-check via stat per rifiutare i file troppo
    // grandi prima di allocarli.
    var max_size: usize = defaultMaxSize(io, allocator);
    if (getenv("ZUER_MAX_MB")) |val| {
        if (std.fmt.parseInt(usize, std.mem.span(val), 10)) |mb| {
            max_size = mb * 1024 * 1024;
        } else |_| {}
    }

    // Anteprima di un file DENTRO un archivio: `archivio.zip#voce`. Gate sull'ext
    // dell'archivio così lo `#N` dei PDF e lo `#foglio` degli XLSX restano ai loro
    // plugin. La voce viene estratta in cache (streaming) e ridecodificata dal
    // decoder giusto per la sua estensione → immagini/testo/pdf/… interni si aprono
    // col loro viewer nativo. In fase coarse si salta: l'host farà il full decode.
    if (!coarse) {
        if (entry_frag) |entry| {
            if (entry.len > 0 and isArchiveExt(getExtension(clean_path)))
                return decodeArchiveEntry(clean_path, entry, io, allocator, max_size);
        }
    }

    const stat = std.Io.Dir.cwd().statFile(io, clean_path, .{}) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile ottenere informazioni sul file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
        return .{ .err = msg };
    };
    // Solo file regolari: aprire una FIFO blocca finché qualcuno non ci scrive (il
    // thread che decodifica resterebbe appeso per sempre, e con lui la chiusura);
    // un device a caratteri non ha una dimensione da leggere.
    if (stat.kind != .file) {
        const msg = std.fmt.allocPrint(allocator, "Non è un file regolare ({s}): {s}", .{ @tagName(stat.kind), clean_path }) catch "";
        return .{ .err = msg };
    }
    // Il limite di dimensione NON viene applicato qui su `stat.size`: un plugin
    // path-based (`zuer_content_prefix = 0`, es. archivi grandi) non carica il
    // file in RAM e deve poter aprire anche archivi da molti GB. Il tetto viene
    // verificato più sotto su `to_read` — i byte che si allocheranno davvero —
    // così i plugin whole-file restano protetti mentre quelli streaming no.

    const mtime_ns: i128 = stat.mtime.nanoseconds;

    // Fase coarse: se esiste una mesh coarse cachata (geometria + texture 256²)
    // valida per questo file (mtime combaciante), ricostruiscila senza leggere né
    // ridecodificare i decine di MB del sorgente → ritorno quasi istantaneo. Miss
    // → si prosegue col decode coarse normale (che popolerà anche questa cache).
    if (coarse) {
        if (meshcache.readCoarse(allocator, clean_path, mtime_ns)) |m|
            return .{ .mesh = m };
    }

    // Risolve il decoder dal registro PRIMA di leggere il contenuto: prima per
    // estensione dichiarata dai plugin stessi, poi immagine per byte magici
    // (basta un piccolo prefisso), infine "text" come fallback. Così la fase
    // coarse di un plugin senza `zuer_decode_coarse` ritorna subito null senza
    // pagare la lettura dell'intero file, e la lettura completa avviene solo
    // quando un decode verrà davvero eseguito.
    const ext = getExtension(clean_path);

    var ext_fn: ?DecodeFn = null;
    var ext_found = false;
    var ext_is_text = false;
    var ext_prefix: usize = std.math.maxInt(usize);
    var text_fn: ?DecodeFn = null;
    {
        plugin_cache_mutex.lockUncancelable(io);
        defer plugin_cache_mutex.unlock(io);
        // `closePluginCache` non riceve un `io`: se lo prende da qui.
        plugin_cache_io = io;
        ensureForExtLocked(ext, io, allocator);
        if (findPluginByExtension(ext)) |p| {
            ext_found = true;
            ext_is_text = std.mem.eql(u8, p.type_name, "text");
            ext_fn = if (coarse) p.decode_coarse_fn else p.decode_fn;
            ext_prefix = p.content_prefix;
        } else {
            // Estensione sconosciuta anche dopo la risoluzione: il plugin
            // giusto lo dirà il rilevamento per byte magici qui sotto; il
            // testo serve come ultimo fallback. Il plugin immagine NON si
            // carica più a scatola chiusa: solo se il probe lo indica.
            loadPluginByNameLocked("text", io, allocator);
            if (findPluginByName("text")) |p| {
                text_fn = if (coarse) p.decode_coarse_fn else p.decode_fn;
            }
        }
    }

    // Fase coarse senza estensione nota → null subito, senza toccare il file:
    // l'unico plugin con `zuer_decode_coarse` (glb) ha un'estensione, e l'host
    // farà comunque il decode full.
    if (coarse and !ext_found) return null;

    var decode_fn: ?DecodeFn = ext_fn;
    var content_prefix: usize = ext_prefix;
    // Rilevamento per contenuto (detect.zig), indipendente dall'estensione:
    // per le estensioni ignote, e per quelle che il manifest manda al plugin
    // `text` (un PNG salvato come `.txt`, un tar.gz chiamato `.log`). Gli altri
    // plugin per estensione sniffano già da soli (stb, libav, gzip in tar.zig).
    // Costo: un solo read di 8 KB, che serve anche al verdetto "binario".
    if (!ext_found or (ext_is_text and !coarse)) {
        var probe_buf: [binary_probe_bytes]u8 = undefined;
        const probe = probeFile(io, clean_path, &probe_buf) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "Impossibile aprire o leggere il file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
            return .{ .err = msg };
        };
        const det = detect.detect(probe, stat.size);
        // Troncato: errore chiaro solo senza estensione. Con un'estensione di
        // testo vince il testo (un `.txt` che contiene solo "GIF89a" è testo).
        if (det.truncated and !ext_found) {
            const msg = std.fmt.allocPrint(allocator, "File {s} incompleto o corrotto: header troncato ({d} byte).", .{ det.label, stat.size }) catch "";
            return .{ .err = msg };
        }
        var routed = false;
        if (det.plugin) |name| {
            if (!det.truncated and !std.mem.eql(u8, name, "text")) {
                plugin_cache_mutex.lockUncancelable(io);
                defer plugin_cache_mutex.unlock(io);
                loadPluginByNameLocked(name, io, allocator);
                if (findPluginByName(name)) |p| {
                    decode_fn = if (coarse) p.decode_coarse_fn else p.decode_fn;
                    content_prefix = p.content_prefix;
                    routed = true;
                }
            }
        }
        if (!routed and !ext_found) {
            if (det.plugin) |name| {
                const msg = std.fmt.allocPrint(allocator, "Formato {s} riconosciuto, ma il plugin '{s}' non è disponibile.", .{ det.label, name }) catch "";
                return .{ .err = msg };
            }
            if (det.known()) {
                const msg = std.fmt.allocPrint(allocator, "Formato riconosciuto ma non supportato: {s} ({s}).", .{ det.label, det.mime }) catch "";
                return .{ .err = msg };
            }
            // Il fallback è il plugin `text`, che leggerebbe TUTTO il file solo
            // per scoprire dai primi 8 KB che è binario: il verdetto si dà QUI,
            // sul probe già letto e con lo stesso criterio del plugin.
            if (probeLooksBinary(probe)) {
                const msg = allocator.dupe(u8, "Formato non riconosciuto o file binario non UTF-8.") catch "";
                return .{ .err = msg };
            }
            decode_fn = text_fn;
            content_prefix = std.math.maxInt(usize);
        }
    }

    // In fase coarse un plugin senza `zuer_decode_coarse` → null: l'host farà il full.
    if (coarse and decode_fn == null) return null;
    const decode_fn_val = decode_fn orelse {
        const msg = std.fmt.allocPrint(allocator, "Nessun plugin decoder disponibile per '.{s}' (cartella decoders/ vuota o mancante)", .{ext}) catch "";
        return .{ .err = msg };
    };

    // Legge solo quanto dichiarato dal plugin (`zuer_content_prefix`): 0 = il
    // plugin lavora dal path (pdf), N = bastano i primi N byte (media: header
    // sniffing — un video multi-GB non va caricato in RAM per il poster).
    // Default (nessun export): file intero, comportamento storico.
    const file_size: usize = @intCast(stat.size);
    const to_read = @min(content_prefix, file_size);
    // Il limite si applica QUI, su ciò che verrà davvero allocato (`to_read`), non
    // sulla dimensione del file su disco: un plugin path-based (`content_prefix=0`,
    // `to_read=0`, es. archivi) apre qualsiasi dimensione senza rischio di OOM,
    // mentre i plugin whole-file (`content_prefix=maxInt`, `to_read=file_size`)
    // restano protetti esattamente come prima.
    if (to_read > max_size) {
        const msg = std.fmt.allocPrint(allocator, "File troppo grande: {d} MB (limite {d} MB, ~metà della memoria disponibile).\nIl caricamento rischierebbe di esaurire la memoria.", .{ to_read / (1024 * 1024), max_size / (1024 * 1024) }) catch "";
        return .{ .err = msg };
    }
    const content: []u8 = if (to_read == 0) &.{} else if (to_read < file_size) blk: {
        // Prefisso parziale: si legge esattamente to_read byte dall'inizio.
        // Mai un letterale in `.err`: `Decoded.deinit` lo libera. Vuoto, come altrove.
        const buf = allocator.alloc(u8, to_read) catch return .{ .err = "" };
        var file = std.Io.Dir.cwd().openFile(io, clean_path, .{}) catch |err| {
            allocator.free(buf);
            const msg = std.fmt.allocPrint(allocator, "Impossibile aprire o leggere il file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
            return .{ .err = msg };
        };
        defer file.close(io);
        var rbuf: [4096]u8 = undefined;
        var reader = file.readerStreaming(io, &rbuf);
        reader.interface.readSliceAll(buf) catch |err| {
            // File cambiato/troncato tra stat e read: errore pulito, niente prefisso a metà.
            allocator.free(buf);
            const msg = std.fmt.allocPrint(allocator, "Impossibile leggere il file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
            return .{ .err = msg };
        };
        break :blk buf;
    } else std.Io.Dir.cwd().readFileAlloc(io, clean_path, allocator, std.Io.Limit.limited(max_size)) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Impossibile aprire o leggere il file: {s} ({s})", .{ clean_path, @errorName(err) }) catch "";
        return .{ .err = msg };
    };
    // Da qui in poi `content` appartiene al plugin (vedi contratto in DecodeFn):
    // lo libera lui, anche in caso di errore.

    const decoded_c = decode_fn_val(
        SliceC.fromSlice(path),
        SliceC.fromSlice(content),
        &io,
        &allocator,
    );

    // Convert the C-compatible decoded structure back to Zig union
    var decoded_data = decoded_c.toDecoded(allocator) catch |err| {
        // La conversione non ha toccato nulla: il risultato è ancora tutto del plugin
        // e va liberato qui.
        decoded_c.deinit(allocator);
        const msg = std.fmt.allocPrint(allocator, "Errore conversione struttura C in plugin: {s}", .{@errorName(err)}) catch "";
        return .{ .err = msg };
    };

    // Il testo dei plugin deve essere UTF-8 valido: chi lo consuma (la stampa in
    // PDF, per dire) lo itera per codepoint, e office copia i byte dell'XML così
    // come sono. Si controlla qui, una volta sola e per tutti: su un testo già
    // valido (il plugin `text` sanifica da sé) è una sola passata senza copie.
    ensureValidText(&decoded_data, allocator);

    // Foglio attivo di un workbook: `DecodedC` non lo trasporta (`toDecoded`
    // mette sempre 0), viaggia nel frammento `#sheet=N` del percorso. Il plugin
    // lo usa per decidere QUALE foglio decodificare per intero, l'host per
    // sapere quale linguetta è selezionata. Indice clampato ai fogli davvero
    // presenti: un frammento fuori range non deve mai sfondare `activeCsv`.
    if (decoded_data == .workbook) {
        if (entry_frag) |f| {
            if (sheetFromFragment(f)) |n| {
                const wb = &decoded_data.workbook;
                if (n - 1 < wb.sheets.len) wb.active = n - 1;
            }
        }
    }

    // Popola/aggiorna la cache mesh coarse dal decode full (texture downscalate a
    // 256²) → la prossima apertura/ritorno usa il fast-path sopra, senza toccare
    // il file né il decoder. Best-effort, non blocca il ritorno.
    if (!coarse and decoded_data == .mesh)
        meshcache.writeCoarse(allocator, clean_path, mtime_ns, &decoded_data.mesh);

    return decoded_data;
}

fn asciiEqualIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |ca, cb| {
        if (std.ascii.toLower(ca) != std.ascii.toLower(cb)) return false;
    }
    return true;
}

pub const getExtension = pathfrag.extension;

test "runDetached: esito, attesa limitata, comando assente" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    try std.testing.expect(runDetached(a, &.{"true"}, 2000));
    try std.testing.expect(!runDetached(a, &.{"false"}, 2000));
    try std.testing.expect(!runDetached(a, &.{"zuer-comando-che-non-esiste"}, 2000));
    // Il caso di xdg-open senza desktop: il lanciatore esce subito ma lascia un
    // processo vivo che ha ereditato il suo stdout. Con una pipe si aspettava
    // quel processo; qui conta solo il lanciatore.
    const t0 = sub.nowMs();
    try std.testing.expect(runDetached(a, &.{ "sh", "-c", "sleep 3 & exit 0" }, 2000));
    try std.testing.expect(sub.nowMs() - t0 < 1500);
    // Lanciatore che resta in primo piano oltre l'attesa: riuscito, e non lo si aspetta.
    const t1 = sub.nowMs();
    try std.testing.expect(runDetached(a, &.{ "sleep", "2" }, 200));
    try std.testing.expect(sub.nowMs() - t1 < 1500);
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
