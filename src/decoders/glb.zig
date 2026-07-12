const std = @import("std");
const decoder = @import("decoder");
const texcache = @import("texcache.zig");
const MeshData = decoder.MeshData;
const Face = decoder.Face;
const Decoded = decoder.Decoded;

// stb_image (vendor/stb), compilato dentro il plugin: decodifica le texture
// baseColor embeddate nel GLB (PNG/JPEG nel chunk BIN) in RGBA senza processi.
extern fn stbi_load_from_memory(
    buffer: [*]const u8,
    len: c_int,
    x: *c_int,
    y: *c_int,
    channels_in_file: *c_int,
    desired_channels: c_int,
) ?[*]u8;
extern fn stbi_image_free(retval_from_stbi_load: ?*anyopaque) void;

// Limite di risoluzione della texture caricata sulla GPU: oltre, si sottocampiona.
const max_tex_dim: usize = 2048;
// Risoluzione del tier COARSE (prima fase progressiva): decode veloce + cache
// minima su disco; la seconda fase ridecodifica a max_tex_dim per il dettaglio.
const coarse_tex_dim: usize = 256;

const GltfAccessor = struct {
    bufferView: ?usize = null,
    byteOffset: ?usize = null,
    componentType: usize,
    count: usize,
    type: []const u8,
};

const GltfBufferView = struct {
    buffer: usize,
    byteOffset: ?usize = null,
    byteLength: usize,
    byteStride: ?usize = null,
};

const GltfPrimitive = struct {
    attributes: std.json.Value,
    indices: ?usize = null,
    material: ?usize = null,
};

const GltfMesh = struct {
    primitives: []GltfPrimitive,
};

const GltfTextureRef = struct {
    index: usize,
};

const GltfPbr = struct {
    baseColorFactor: ?[4]f32 = null,
    metallicFactor: ?f32 = null,
    roughnessFactor: ?f32 = null,
    baseColorTexture: ?GltfTextureRef = null,
};

// Estensione KHR_materials_pbrSpecularGlossiness: workflow diffuse/specular
// (molti asset esportati da Maya/Blender). Mappiamo diffuse→baseColor e
// glossiness→(1-roughness), metallic=0.
const GltfSpecGloss = struct {
    diffuseFactor: ?[4]f32 = null,
    diffuseTexture: ?GltfTextureRef = null,
    glossinessFactor: ?f32 = null,
};

const GltfMaterialExt = struct {
    KHR_materials_pbrSpecularGlossiness: ?GltfSpecGloss = null,
};

const GltfMaterial = struct {
    pbrMetallicRoughness: ?GltfPbr = null,
    extensions: ?GltfMaterialExt = null,
    normalTexture: ?GltfTextureRef = null, // normal map (comune a entrambi i workflow)
};

const GltfTexture = struct {
    source: ?usize = null,
};

const GltfImage = struct {
    bufferView: ?usize = null,
    uri: ?[]const u8 = null,
};

const GltfNode = struct {
    mesh: ?usize = null,
    children: ?[]usize = null,
    matrix: ?[16]f32 = null, // column-major (convenzione glTF)
    translation: ?[3]f32 = null,
    rotation: ?[4]f32 = null, // quaternione xyzw
    scale: ?[3]f32 = null,
};

const GltfScene = struct {
    nodes: ?[]usize = null,
};

const GltfStructure = struct {
    accessors: ?[]GltfAccessor = null,
    bufferViews: ?[]GltfBufferView = null,
    meshes: ?[]GltfMesh = null,
    materials: ?[]GltfMaterial = null,
    textures: ?[]GltfTexture = null,
    images: ?[]GltfImage = null,
    nodes: ?[]GltfNode = null,
    scenes: ?[]GltfScene = null,
    scene: ?usize = null,
};

// --- Matrici 4×4 column-major (convenzione glTF) -------------------------
const Mat4 = [16]f32;

const identity4: Mat4 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

fn mat4Mul(a: Mat4, b: Mat4) Mat4 {
    var r: Mat4 = undefined;
    for (0..4) |col| {
        for (0..4) |row| {
            var s: f32 = 0;
            for (0..4) |k| s += a[k * 4 + row] * b[col * 4 + k];
            r[col * 4 + row] = s;
        }
    }
    return r;
}

/// Matrice locale del nodo: `matrix` esplicita oppure composizione T·R·S.
fn nodeLocalMatrix(node: GltfNode) Mat4 {
    if (node.matrix) |m| return m;

    const t = node.translation orelse [3]f32{ 0, 0, 0 };
    const q = node.rotation orelse [4]f32{ 0, 0, 0, 1 };
    const s = node.scale orelse [3]f32{ 1, 1, 1 };

    const x = q[0];
    const y = q[1];
    const z = q[2];
    const w = q[3];
    // Rotazione dal quaternione (righe m00..m22), poi scala per colonna.
    const m00 = 1 - 2 * (y * y + z * z);
    const m01 = 2 * (x * y - w * z);
    const m02 = 2 * (x * z + w * y);
    const m10 = 2 * (x * y + w * z);
    const m11 = 1 - 2 * (x * x + z * z);
    const m12 = 2 * (y * z - w * x);
    const m20 = 2 * (x * z - w * y);
    const m21 = 2 * (y * z + w * x);
    const m22 = 1 - 2 * (x * x + y * y);

    return .{
        m00 * s[0], m10 * s[0], m20 * s[0], 0, // colonna 0
        m01 * s[1], m11 * s[1], m21 * s[1], 0, // colonna 1
        m02 * s[2], m12 * s[2], m22 * s[2], 0, // colonna 2
        t[0], t[1], t[2], 1, // colonna 3 (traslazione)
    };
}

fn transformPoint(m: Mat4, p: [3]f32) [3]f32 {
    return .{
        m[0] * p[0] + m[4] * p[1] + m[8] * p[2] + m[12],
        m[1] * p[0] + m[5] * p[1] + m[9] * p[2] + m[13],
        m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14],
    };
}

fn transformDir(m: Mat4, d: [3]f32) [3]f32 {
    return .{
        m[0] * d[0] + m[4] * d[1] + m[8] * d[2],
        m[1] * d[0] + m[5] * d[1] + m[9] * d[2],
        m[2] * d[0] + m[6] * d[1] + m[10] * d[2],
    };
}

/// Texture decodificata in RGBA8, posseduta dallo scratch allocator della cache.
const DecodedTex = struct { pixels: []u8, w: usize, h: usize };

/// Indice dell'immagine sorgente referenziata da un GltfTextureRef, o null.
fn texSource(gltf: GltfStructure, tex_ref: GltfTextureRef) ?usize {
    const textures = gltf.textures orelse return null;
    if (tex_ref.index >= textures.len) return null;
    return textures[tex_ref.index].source;
}

/// Decodifica in RGBA8 l'immagine sorgente `source` (PNG/JPEG embeddato nel chunk
/// BIN via bufferView). Ritorna null per URI esterni/data-URI o formati non
/// gestiti. Sottocampiona (box filter) oltre `max_tex_dim`.
fn decodeImageSource(
    gltf: GltfStructure,
    bin_data: []const u8,
    source: usize,
    allocator: std.mem.Allocator,
    out_w: *usize,
    out_h: *usize,
    coarse: bool,
) ?[]u8 {
    const images = gltf.images orelse return null;
    if (source >= images.len) return null;
    const bv_idx = images[source].bufferView orelse return null; // no URI esterni
    const bufferViews = gltf.bufferViews orelse return null;
    if (bv_idx >= bufferViews.len) return null;
    const bv = bufferViews[bv_idx];
    // Offset/lunghezze arrivano dal JSON (usize ostili): somma controllata.
    const start = bv.byteOffset orelse 0;
    const end = std.math.add(usize, start, bv.byteLength) catch return null;
    if (end > bin_data.len) return null;
    const encoded = bin_data[start..end];
    if (encoded.len == 0 or encoded.len > std.math.maxInt(c_int)) return null;

    // Fase COARSE: SOLO lettura della cache 256² (nessun decode stbi). Un miss
    // ritorna null → il chiamante abortisce la fase coarse (niente doppio decode
    // alla prima apertura); la cache 256 la popola la fase full.
    if (coarse) return texcache.read_cached(allocator, encoded, out_w, out_h);

    var w: c_int = 0;
    var h: c_int = 0;
    var channels: c_int = 0;
    const data = stbi_load_from_memory(encoded.ptr, @intCast(encoded.len), &w, &h, &channels, 4) orelse return null;
    defer stbi_image_free(data);
    if (w <= 0 or h <= 0) return null;

    const rgba = downscaleRgba(data, @intCast(w), @intCast(h), max_tex_dim, allocator, out_w, out_h) orelse return null;
    // Popola la cache coarse (256²) da questa decodifica full: sotto-campiona a 256
    // in un buffer temporaneo e scrivilo, così la prossima apertura ha la coarse.
    var cw: usize = 0;
    var ch: usize = 0;
    if (downscaleRgba(rgba.ptr, out_w.*, out_h.*, coarse_tex_dim, allocator, &cw, &ch)) |cr| {
        texcache.write_cached(allocator, encoded, cw, ch, cr);
        allocator.free(cr);
    }
    return rgba;
}

// --- Cache texture decodificate in parallelo ------------------------------
// Le texture embeddate (spesso 4K) si decodificano con stbi e si sotto-campionano
// sulla CPU: un GLB texture-heavy (es. 16 texture 4096²) costava decine di secondi
// perché fatte in sequenza sul thread di decode. Qui le decodifichiamo una sola
// volta per immagine sorgente (i materiali possono condividerle) e in parallelo su
// tutti i core — è lavoro puramente CPU (stbi usa il malloc di libc, thread-safe) e
// i buffer d'uscita vengono da page_allocator (thread-safe). Ogni submesh a valle
// ne prende una copia col proprio allocatore, quindi l'ownership resta invariata.

const TexCache = std.AutoHashMapUnmanaged(usize, DecodedTex);

const TexJob = struct {
    gltf: GltfStructure,
    bin: []const u8,
    srcs: []const usize,
    results: []?DecodedTex,
    next: std.atomic.Value(usize),
    coarse: bool,
    missed: std.atomic.Value(bool), // coarse: una texture non era in cache 256²
};

fn texWorker(job: *TexJob) void {
    while (true) {
        const i = job.next.fetchAdd(1, .monotonic);
        if (i >= job.srcs.len) break;
        var w: usize = 0;
        var h: usize = 0;
        if (decodeImageSource(job.gltf, job.bin, job.srcs[i], std.heap.page_allocator, &w, &h, job.coarse)) |px| {
            job.results[i] = .{ .pixels = px, .w = w, .h = h };
        } else if (job.coarse) {
            // Cache coarse mancante per questa texture: la fase coarse non è
            // completabile senza decodificare (ciò che vogliamo evitare) → segnala.
            job.missed.store(true, .monotonic);
        }
    }
}

/// Budget di worker thread per la decodifica texture, CONDIVISO tra tutte le
/// chiamate concorrenti a `buildTexCache`: il decode in primo piano e il
/// prefetch dei vicini girano su thread diversi e possono sovrapporsi, e prima
/// ognuno spawnava fino a (core−1) thread PER SÉ — su una CPU a pochi core
/// (es. 2C/4T) due decode insieme arrivavano a 6+ thread CPU-bound contro 4
/// hardware thread, mettendo in ginocchio anche il thread finestra per minuti
/// (percepito come "si impalla" navigando in rapida successione tra modelli
/// testurizzati). Inizializzato pigro a cores-1: un solo decode in volo si
/// comporta come prima (nessuna regressione), più decode concorrenti si
/// spartiscono lo stesso budget invece di sommare i propri.
var texworker_budget: std.atomic.Value(i32) = .init(-1); // -1 = non inizializzato

/// Riserva fino a `want` slot dal budget condiviso (satura a 0). Ritorna
/// quanti se ne sono ottenuti davvero (≤ want) — mai negativo, mai in attesa:
/// se il budget è esaurito la decode chiamante lavora comunque in linea (vedi
/// `texWorker(&job)` in `buildTexCache`), solo senza aiuto extra.
fn reserveTexWorkers(want: usize) usize {
    if (want == 0) return 0;
    var cur = texworker_budget.load(.monotonic);
    if (cur < 0) {
        const cores = std.Thread.getCpuCount() catch 1;
        const initial: i32 = @intCast(@max(0, @as(isize, @intCast(cores)) - 1));
        // Init lazy ATOMICA: solo chi vince il cmpxchg dalla sentinella -1
        // pubblica il valore; chi perde riparte da quello del vincitore (già
        // eventualmente decrementato). Lo store incondizionato di prima poteva
        // RESETTARE il budget mentre un altro decode aveva slot riservati →
        // oversubscription CPU.
        if (texworker_budget.cmpxchgStrong(-1, initial, .monotonic, .monotonic)) |actual| {
            cur = actual;
        } else {
            cur = initial;
        }
    }
    var reserved: usize = 0;
    while (reserved < want and cur > 0) {
        if (texworker_budget.cmpxchgWeak(cur, cur - 1, .monotonic, .monotonic)) |actual| {
            cur = actual;
        } else {
            reserved += 1;
            cur -= 1;
        }
    }
    return reserved;
}

/// Restituisce al budget condiviso gli slot riservati da `reserveTexWorkers`.
fn releaseTexWorkers(n: usize) void {
    if (n == 0) return;
    _ = texworker_budget.fetchAdd(@intCast(n), .monotonic);
}

fn freeTexCache(cache: *TexCache, allocator: std.mem.Allocator) void {
    var it = cache.valueIterator();
    while (it.next()) |dt| std.heap.page_allocator.free(dt.pixels);
    cache.deinit(allocator);
}

/// Decodifica in parallelo tutte le texture (baseColor/diffuse + normal) uniche
/// referenziate dai materiali, indicizzate per immagine sorgente.
fn buildTexCache(gltf: GltfStructure, bin_data: []const u8, allocator: std.mem.Allocator, coarse: bool) !TexCache {
    var cache: TexCache = .empty;
    errdefer freeTexCache(&cache, allocator);

    // Insieme delle immagini sorgente uniche da decodificare.
    var srcset: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer srcset.deinit(allocator);
    if (gltf.materials) |mats| {
        for (mats) |m| {
            var base: ?GltfTextureRef = null;
            if (m.pbrMetallicRoughness) |pbr| {
                base = pbr.baseColorTexture;
            } else if (m.extensions) |ext| {
                if (ext.KHR_materials_pbrSpecularGlossiness) |sg| base = sg.diffuseTexture;
            }
            for ([_]?GltfTextureRef{ base, m.normalTexture }) |r| {
                if (r) |tr| if (texSource(gltf, tr)) |s| try srcset.put(allocator, s, {});
            }
        }
    }
    const n = srcset.count();
    if (n == 0) return cache;

    const srcs = try allocator.alloc(usize, n);
    defer allocator.free(srcs);
    {
        var it = srcset.keyIterator();
        var i: usize = 0;
        while (it.next()) |k| : (i += 1) srcs[i] = k.*;
    }

    const results = try allocator.alloc(?DecodedTex, n);
    defer allocator.free(results);
    @memset(results, null);

    var job = TexJob{ .gltf = gltf, .bin = bin_data, .srcs = srcs, .results = results, .next = .init(0), .coarse = coarse, .missed = .init(false) };

    // Spawn fino a un budget condiviso da TUTTE le decode in volo (contro
    // (core−1) thread PER CHIAMATA: il decode in primo piano e il prefetch dei
    // vicini girano su thread diversi e possono sovrapporsi, moltiplicando gli
    // spawn — su una CPU a pochi core questo mette in ginocchio anche il thread
    // finestra per minuti, percepito come "si impalla"). Il thread corrente
    // drena comunque la coda, così anche con 0 spawn (budget esaurito) tutte le
    // texture vengono decodificate, solo più lentamente.
    var pool: [31]?std.Thread = .{null} ** 31;
    const want = @min(n -| 1, pool.len);
    const spawn_n = reserveTexWorkers(want);
    defer releaseTexWorkers(spawn_n);
    for (0..spawn_n) |i| pool[i] = std.Thread.spawn(.{}, texWorker, .{&job}) catch null;
    texWorker(&job);
    for (0..spawn_n) |i| if (pool[i]) |t| t.join();

    // Fase coarse con cache 256² incompleta: aborta (il chiamante farà il full).
    // I risultati parziali (hit di cache) non sono ancora nella map → liberali qui.
    if (coarse and job.missed.load(.monotonic)) {
        for (results) |r| if (r) |dt| std.heap.page_allocator.free(dt.pixels);
        return error.CoarseCacheIncomplete;
    }

    // Popola la mappa sorgente→texture (single-thread, ownership al chiamante).
    for (srcs, results) |s, r| {
        if (r) |dt| try cache.put(allocator, s, dt);
    }
    return cache;
}

/// Preleva dalla cache la texture per `tex_ref`. La copia con l'allocatore del
/// builder avviene UNA volta per immagine sorgente e viene condivisa da tutti i
/// submesh che la referenziano (i glTF riusano lo stesso atlas su decine di
/// primitive: N copie da ~16 MB diventano una). L'ownership del buffer condiviso
/// è del primo submesh in ordine; `decoder.freeSubmeshTextures` libera ogni
/// puntatore una sola volta. null se non decodificata.
fn takeCachedTex(b: *Builder, tex_ref: GltfTextureRef, out_w: *usize, out_h: *usize) ?[]u8 {
    const s = texSource(b.gltf, tex_ref) orelse return null;
    if (b.shared_tex.get(s)) |st| {
        out_w.* = st.w;
        out_h.* = st.h;
        return st.pixels;
    }
    const dt = b.tex_cache.get(s) orelse return null;
    const px = b.allocator.dupe(u8, dt.pixels) catch return null;
    // Se la memoizzazione fallisce il submesh possiede la copia da solo:
    // corretto comunque (solo meno condivisione).
    b.shared_tex.put(b.allocator, s, .{ .pixels = px, .w = dt.w, .h = dt.h }) catch {};
    out_w.* = dt.w;
    out_h.* = dt.h;
    return px;
}

/// Copia (ed eventualmente riduce con media per area) i pixel RGBA in un buffer
/// dell'allocator del chiamante, entro `max_dim`×`max_dim`.
fn downscaleRgba(src: [*]const u8, src_w: usize, src_h: usize, max_dim: usize, allocator: std.mem.Allocator, out_w: *usize, out_h: *usize) ?[]u8 {
    const fw: f32 = @floatFromInt(src_w);
    const fh: f32 = @floatFromInt(src_h);
    const fmax: f32 = @floatFromInt(max_dim);
    const scale = @min(1.0, @min(fmax / fw, fmax / fh));
    const dst_w = @max(1, @as(usize, @intFromFloat(@round(fw * scale))));
    const dst_h = @max(1, @as(usize, @intFromFloat(@round(fh * scale))));

    const pixels = allocator.alloc(u8, dst_w * dst_h * 4) catch return null;

    if (dst_w == src_w and dst_h == src_h) {
        @memcpy(pixels, src[0 .. src_w * src_h * 4]);
    } else {
        for (0..dst_h) |dy| {
            const y0 = dy * src_h / dst_h;
            const y1 = @max(y0 + 1, (dy + 1) * src_h / dst_h);
            for (0..dst_w) |dx| {
                const x0 = dx * src_w / dst_w;
                const x1 = @max(x0 + 1, (dx + 1) * src_w / dst_w);
                var sum = [4]u64{ 0, 0, 0, 0 };
                for (y0..y1) |sy| {
                    for (x0..x1) |sx| {
                        const s = (sy * src_w + sx) * 4;
                        inline for (0..4) |c| sum[c] += src[s + c];
                    }
                }
                const count: u64 = @intCast((y1 - y0) * (x1 - x0));
                const d = (dy * dst_w + dx) * 4;
                inline for (0..4) |c| pixels[d + c] = @intCast(sum[c] / count);
            }
        }
    }

    out_w.* = dst_w;
    out_h.* = dst_h;
    return pixels;
}

/// Indice intero di un attributo (es. "NORMAL") nell'oggetto attributes, o null.
fn attributeIndex(attributes: std.json.Value, key: []const u8) ?usize {
    switch (attributes) {
        .object => |obj| if (obj.get(key)) |val| switch (val) {
            .integer => |idx| return @intCast(idx),
            else => return null,
        } else return null,
        else => return null,
    }
}

/// Legge un accessor di float (VEC2/VEC3) in un array di `comps` componenti per
/// elemento. `expected_count` vincola il numero di elementi (deve combaciare coi
/// vertici). Ritorna null se l'accessor è assente o incompatibile.
fn readFloatAccessor(
    comptime comps: usize,
    gltf: GltfStructure,
    bin_data: []const u8,
    accessor_idx: usize,
    expected_count: usize,
    allocator: std.mem.Allocator,
) !?[][comps]f32 {
    const accessors = gltf.accessors orelse return null;
    const bufferViews = gltf.bufferViews orelse return null;
    if (accessor_idx >= accessors.len) return null;
    const acc = accessors[accessor_idx];
    if (acc.componentType != 5126) return null; // solo f32
    if (acc.count != expected_count) return null;
    const want_type = switch (comps) {
        2 => "VEC2",
        3 => "VEC3",
        else => "VEC4",
    };
    if (!std.mem.eql(u8, acc.type, want_type)) return null;

    const bv_idx = acc.bufferView orelse return null;
    if (bv_idx >= bufferViews.len) return null;
    const bv = bufferViews[bv_idx];
    // Offset e stride arrivano dal JSON (usize ostili): l'aritmetica va fatta
    // con somme/moltiplicazioni controllate, e si valida a monte che l'ULTIMO
    // elemento stia dentro il BIN (così il loop non ha bisogno di controlli).
    const base = std.math.add(usize, bv.byteOffset orelse 0, acc.byteOffset orelse 0) catch return null;
    const stride = bv.byteStride orelse (comps * 4);
    if (expected_count == 0) return null;
    const span = std.math.mul(usize, expected_count - 1, stride) catch return null;
    const last = std.math.add(usize, base, span) catch return null;
    const end = std.math.add(usize, last, comps * 4) catch return null;
    if (end > bin_data.len) return null;

    const out = try allocator.alloc([comps]f32, expected_count);
    errdefer allocator.free(out);
    var i: usize = 0;
    while (i < expected_count) : (i += 1) {
        const off = base + i * stride;
        inline for (0..comps) |c| {
            out[i][c] = @bitCast(std.mem.readInt(u32, bin_data[off + c * 4 ..][0..4], .little));
        }
    }
    return out;
}

pub fn decode(bytes: []const u8, filename: []const u8, allocator: std.mem.Allocator, coarse: bool) Decoded {
    defer allocator.free(bytes);

    if (bytes.len < 20) return .{ .err = "File GLB troppo piccolo" };
    if (!std.mem.eql(u8, bytes[0..4], "glTF")) return .{ .err = "Formato GLB non valido (magic header errato)" };

    const version = std.mem.readInt(u32, bytes[4..8], .little);
    if (version != 2) return .{ .err = "Versione glTF non supportata (solo v2)" };

    // Chunk 0: JSON. Le lunghezze arrivano dal file (u32 ostili): tutta
    // l'aritmetica degli offset si fa in usize con controlli espliciti, così un
    // GLB corrotto produce un errore e mai un overflow/OOB.
    const chunk0_len: usize = std.mem.readInt(u32, bytes[12..16], .little);
    const chunk0_type = std.mem.readInt(u32, bytes[16..20], .little);
    if (chunk0_type != 0x4E4F534A) return .{ .err = "Il primo chunk GLB deve essere JSON" };
    const json_end = std.math.add(usize, 20, chunk0_len) catch return .{ .err = "JSON chunk fuori dai limiti del file" };
    if (json_end > bytes.len) return .{ .err = "JSON chunk fuori dai limiti del file" };
    const json_str = bytes[20..json_end];

    // Chunk 1: BIN
    const chunk1_offset = json_end;
    const chunk1_hdr_end = std.math.add(usize, chunk1_offset, 8) catch return .{ .err = "Nessun chunk BIN trovato" };
    if (chunk1_hdr_end > bytes.len) return .{ .err = "Nessun chunk BIN trovato" };
    const chunk1_len: usize = std.mem.readInt(u32, bytes[chunk1_offset..][0..4], .little);
    const chunk1_type = std.mem.readInt(u32, bytes[chunk1_offset + 4 ..][0..4], .little);
    if (chunk1_type != 0x004E4942) return .{ .err = "Il secondo chunk GLB deve essere BIN" };
    const bin_end = std.math.add(usize, chunk1_hdr_end, chunk1_len) catch return .{ .err = "BIN chunk fuori dai limiti del file" };
    if (bin_end > bytes.len) return .{ .err = "BIN chunk fuori dai limiti del file" };
    const bin_data = bytes[chunk1_hdr_end..bin_end];

    // Parse JSON
    var parsed = std.json.parseFromSlice(GltfStructure, allocator, json_str, .{ .ignore_unknown_fields = true }) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Errore parsing JSON glTF: {s}", .{@errorName(err)}) catch "Errore JSON";
        return .{ .err = msg };
    };
    defer parsed.deinit();
    const gltf = parsed.value;

    // Decode meshes to MeshData
    const mesh_data = decodeGltfScene(gltf, bin_data, filename, allocator, coarse) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Errore decodifica modello 3D GLB: {s}", .{@errorName(err)}) catch "Errore GLB";
        return .{ .err = msg };
    };

    return .{ .mesh = mesh_data };
}

/// Stato di fusione della scena: geometria unica + submesh per-materiale.
const Builder = struct {
    gltf: GltfStructure,
    bin: []const u8,
    allocator: std.mem.Allocator,
    tex_cache: TexCache,
    /// Copie (con b.allocator) memoizzate per immagine sorgente: i submesh che
    /// condividono un atlas puntano allo stesso buffer (vedi takeCachedTex).
    shared_tex: TexCache,
    vertices: std.ArrayList([3]f32),
    normals: std.ArrayList([3]f32),
    uvs: std.ArrayList([2]f32),
    tangents: std.ArrayList([4]f32),
    faces: std.ArrayList(Face),
    submeshes: std.ArrayList(decoder.SubMesh),
    bbox_min: [3]f32,
    bbox_max: [3]f32,
    all_normals: bool, // false appena una primitiva è priva di NORMAL affidabili
    all_tangents: bool, // false appena una primitiva è priva di TANGENT
};

fn accessorCount(gltf: GltfStructure, idx: usize) ?usize {
    const accessors = gltf.accessors orelse return null;
    if (idx >= accessors.len) return null;
    return accessors[idx].count;
}

/// Radici della scena: la scena esplicita se presente, altrimenti null (il
/// chiamante ripiega sui nodi non referenziati come figli).
fn rootsFromScene(gltf: GltfStructure) ?[]const usize {
    const scenes = gltf.scenes orelse return null;
    if (scenes.len == 0) return null;
    const idx = gltf.scene orelse 0;
    const si = if (idx < scenes.len) idx else 0;
    return scenes[si].nodes orelse null;
}

/// Aggiunge una primitiva alla geometria fusa, trasformata dalla matrice di
/// mondo del nodo, e registra il submesh (intervallo indici + materiale/texture).
fn addPrimitive(b: *Builder, prim: GltfPrimitive, world: Mat4) !void {
    const pos_idx = attributeIndex(prim.attributes, "POSITION") orelse return;
    const count = accessorCount(b.gltf, pos_idx) orelse return;
    if (count == 0) return;
    const positions = (try readFloatAccessor(3, b.gltf, b.bin, pos_idx, count, b.allocator)) orelse return;
    defer b.allocator.free(positions);

    const vertex_offset = b.vertices.items.len;

    for (positions) |p| {
        const wp = transformPoint(world, p);
        try b.vertices.append(b.allocator, wp);
        inline for (0..3) |c| {
            b.bbox_min[c] = @min(b.bbox_min[c], wp[c]);
            b.bbox_max[c] = @max(b.bbox_max[c], wp[c]);
        }
    }

    // Normali autorali trasformate; se assenti, zeri e flag → ricostruzione a valle.
    if (attributeIndex(prim.attributes, "NORMAL")) |ni| {
        if (try readFloatAccessor(3, b.gltf, b.bin, ni, count, b.allocator)) |ns| {
            defer b.allocator.free(ns);
            for (ns) |n| try b.normals.append(b.allocator, transformDir(world, n));
        } else {
            b.all_normals = false;
            for (0..count) |_| try b.normals.append(b.allocator, .{ 0, 0, 0 });
        }
    } else {
        b.all_normals = false;
        for (0..count) |_| try b.normals.append(b.allocator, .{ 0, 0, 0 });
    }

    // UV (sempre una per vertice: (0,0) se assenti).
    var had_uv = false;
    if (attributeIndex(prim.attributes, "TEXCOORD_0")) |ui| {
        if (try readFloatAccessor(2, b.gltf, b.bin, ui, count, b.allocator)) |us| {
            defer b.allocator.free(us);
            had_uv = true;
            for (us) |u| try b.uvs.append(b.allocator, u);
        } else {
            for (0..count) |_| try b.uvs.append(b.allocator, .{ 0, 0 });
        }
    } else {
        for (0..count) |_| try b.uvs.append(b.allocator, .{ 0, 0 });
    }

    // Tangenti autorali (vec4: xyz direzione + w handedness). xyz trasformate
    // dalla matrice di mondo; se assenti, zeri e flag → il loader le ricostruisce.
    if (attributeIndex(prim.attributes, "TANGENT")) |ti| {
        if (try readFloatAccessor(4, b.gltf, b.bin, ti, count, b.allocator)) |ts| {
            defer b.allocator.free(ts);
            for (ts) |t| {
                const wt = transformDir(world, .{ t[0], t[1], t[2] });
                try b.tangents.append(b.allocator, .{ wt[0], wt[1], wt[2], t[3] });
            }
        } else {
            b.all_tangents = false;
            for (0..count) |_| try b.tangents.append(b.allocator, .{ 0, 0, 0, 1 });
        }
    } else {
        b.all_tangents = false;
        for (0..count) |_| try b.tangents.append(b.allocator, .{ 0, 0, 0, 1 });
    }

    // Facce (indici con offset dei vertici del submesh).
    const first_index = b.faces.items.len * 3;
    try addFaces(b, prim, count, vertex_offset);
    const index_count = b.faces.items.len * 3 - first_index;
    if (index_count == 0) return;

    // Materiale + texture baseColor del submesh. Supporta sia il workflow
    // standard metallic-roughness sia l'estensione specular-glossiness.
    var sub = decoder.SubMesh{ .first_index = first_index, .index_count = index_count };
    if (prim.material) |mat_idx| {
        if (b.gltf.materials) |materials| {
            if (mat_idx < materials.len) {
                const mat = materials[mat_idx];
                var tex_ref: ?GltfTextureRef = null;
                if (mat.pbrMetallicRoughness) |pbr| {
                    if (pbr.baseColorFactor) |bc| sub.base_color = bc;
                    if (pbr.metallicFactor) |mv| sub.metallic = mv;
                    if (pbr.roughnessFactor) |rv| sub.roughness = rv;
                    tex_ref = pbr.baseColorTexture;
                } else if (mat.extensions) |ext| {
                    if (ext.KHR_materials_pbrSpecularGlossiness) |sg| {
                        if (sg.diffuseFactor) |df| sub.base_color = df;
                        sub.metallic = 0; // spec-gloss: superficie non metallica
                        // roughness = 1-glossiness, con un minimo per evitare la
                        // degenerazione GGX (alpha=roughness²→0) senza il gloss map.
                        if (sg.glossinessFactor) |g| sub.roughness = @max(0.05, 1.0 - g);
                        tex_ref = sg.diffuseTexture;
                    }
                }
                if (had_uv) {
                    if (tex_ref) |tref| {
                        if (takeCachedTex(b, tref, &sub.tex_width, &sub.tex_height)) |px| {
                            sub.tex_pixels = px;
                        }
                    }
                    // Normal map (dati lineari, decodifica identica in RGBA8).
                    if (mat.normalTexture) |nref| {
                        if (takeCachedTex(b, nref, &sub.nrm_tex_width, &sub.nrm_tex_height)) |px| {
                            sub.nrm_tex_pixels = px;
                        }
                    }
                }
            }
        }
    }
    try b.submeshes.append(b.allocator, sub);
}

fn addFaces(b: *Builder, prim: GltfPrimitive, pos_count: usize, vertex_offset: usize) !void {
    if (prim.indices) |ind_idx| {
        const accessors = b.gltf.accessors orelse return error.NoAccessors;
        if (ind_idx >= accessors.len) return error.AccessorOutOfBounds;
        const acc = accessors[ind_idx];
        const bvs = b.gltf.bufferViews orelse return error.NoBufferViews;
        const bv_idx = acc.bufferView orelse return error.NoBufferViewForIndices;
        if (bv_idx >= bvs.len) return error.BufferViewOutOfBounds;
        const bv = bvs[bv_idx];
        // Somma controllata: gli offset arrivano dal JSON (usize ostili).
        const ind_offset = std.math.add(usize, bv.byteOffset orelse 0, acc.byteOffset orelse 0) catch return error.OutOfBounds;
        var j: usize = 0;
        while (j + 2 < acc.count) : (j += 3) {
            const v1 = try readIndex(b.bin, ind_offset, j, acc.componentType);
            const v2 = try readIndex(b.bin, ind_offset, j + 1, acc.componentType);
            const v3 = try readIndex(b.bin, ind_offset, j + 2, acc.componentType);
            try b.faces.append(b.allocator, .{ .v1 = v1 + vertex_offset, .v2 = v2 + vertex_offset, .v3 = v3 + vertex_offset });
        }
    } else {
        var j: usize = 0;
        while (j + 2 < pos_count) : (j += 3) {
            try b.faces.append(b.allocator, .{ .v1 = j + vertex_offset, .v2 = j + 1 + vertex_offset, .v3 = j + 2 + vertex_offset });
        }
    }
}

fn addNode(b: *Builder, node_idx: usize, parent: Mat4, depth: u32) !void {
    if (depth > 64) return; // guardia anti-cicli
    const nodes = b.gltf.nodes orelse return;
    if (node_idx >= nodes.len) return;
    const node = nodes[node_idx];
    const world = mat4Mul(parent, nodeLocalMatrix(node));
    if (node.mesh) |mi| {
        if (b.gltf.meshes) |meshes| {
            if (mi < meshes.len) {
                for (meshes[mi].primitives) |prim| try addPrimitive(b, prim, world);
            }
        }
    }
    if (node.children) |children| {
        for (children) |c| try addNode(b, c, world, depth + 1);
    }
}

/// Carica l'intera scena glTF: attraversa il grafo dei nodi applicando le
/// trasformazioni, fonde tutte le mesh/primitive in un'unica geometria e
/// produce un submesh per primitiva (materiale + texture propri).
fn decodeGltfScene(gltf: GltfStructure, bin_data: []const u8, filename: []const u8, allocator: std.mem.Allocator, coarse: bool) !MeshData {
    // Texture decodificate in parallelo, una per immagine sorgente (vedi buildTexCache).
    var tex_cache = try buildTexCache(gltf, bin_data, allocator, coarse);
    defer freeTexCache(&tex_cache, allocator);

    var b = Builder{
        .gltf = gltf,
        .bin = bin_data,
        .allocator = allocator,
        .tex_cache = tex_cache,
        .shared_tex = .empty,
        .vertices = .empty,
        .normals = .empty,
        .uvs = .empty,
        .tangents = .empty,
        .faces = .empty,
        .submeshes = .empty,
        .bbox_min = .{ std.math.inf(f32), std.math.inf(f32), std.math.inf(f32) },
        .bbox_max = .{ -std.math.inf(f32), -std.math.inf(f32), -std.math.inf(f32) },
        .all_normals = true,
        .all_tangents = true,
    };
    // La mappa di memoizzazione si libera sempre (i pixel appartengono ai
    // submesh, qui si rilascia solo la struttura).
    defer b.shared_tex.deinit(allocator);
    errdefer {
        b.vertices.deinit(allocator);
        b.normals.deinit(allocator);
        b.uvs.deinit(allocator);
        b.tangents.deinit(allocator);
        b.faces.deinit(allocator);
        // Le texture possono essere condivise tra submesh: free dedup-aware.
        decoder.freeSubmeshTextures(b.submeshes.items, allocator);
        b.submeshes.deinit(allocator);
    }

    if (gltf.nodes) |nodes| {
        if (rootsFromScene(gltf)) |roots| {
            for (roots) |r| try addNode(&b, r, identity4, 0);
        } else {
            // Nessuna scena esplicita: radici = nodi non referenziati come figli.
            const is_child = try allocator.alloc(bool, nodes.len);
            defer allocator.free(is_child);
            @memset(is_child, false);
            for (nodes) |n| if (n.children) |ch| {
                for (ch) |c| if (c < nodes.len) {
                    is_child[c] = true;
                };
            };
            for (0..nodes.len) |i| if (!is_child[i]) try addNode(&b, i, identity4, 0);
        }
    } else if (gltf.meshes) |meshes| {
        // Nessun grafo di scena: tutte le mesh all'identità.
        for (meshes) |mesh| for (mesh.primitives) |prim| try addPrimitive(&b, prim, identity4);
    }

    if (b.vertices.items.len == 0) return error.NoGeometry;
    const vcount = b.vertices.items.len;

    const name = try allocator.dupe(u8, filename);
    errdefer allocator.free(name);

    const center = [3]f32{
        (b.bbox_min[0] + b.bbox_max[0]) / 2.0,
        (b.bbox_min[1] + b.bbox_max[1]) / 2.0,
        (b.bbox_min[2] + b.bbox_max[2]) / 2.0,
    };

    // Normali solo se ogni primitiva le aveva; altrimenti si scartano e il
    // loader le ricostruisce smooth sull'intera geometria fusa.
    var normals_slice: [][3]f32 = &.{};
    if (b.all_normals and b.normals.items.len == vcount) {
        normals_slice = try b.normals.toOwnedSlice(allocator);
    } else {
        b.normals.deinit(allocator);
    }

    // Tangenti: solo se ogni primitiva le aveva; altrimenti si scartano e il
    // loader le ricostruisce da UV/posizioni (serve solo dove c'è normal map).
    var tangents_slice: [][4]f32 = &.{};
    if (b.all_tangents and b.tangents.items.len == vcount) {
        tangents_slice = try b.tangents.toOwnedSlice(allocator);
    } else {
        b.tangents.deinit(allocator);
    }

    return .{
        .num_vertices = vcount,
        .num_faces = b.faces.items.len,
        .num_normals = normals_slice.len,
        .bbox_min = b.bbox_min,
        .bbox_max = b.bbox_max,
        .center = center,
        .name = name,
        .vertices = try b.vertices.toOwnedSlice(allocator),
        .faces = try b.faces.toOwnedSlice(allocator),
        .normals = normals_slice,
        .uvs = try b.uvs.toOwnedSlice(allocator),
        .tangents = tangents_slice,
        .submeshes = try b.submeshes.toOwnedSlice(allocator),
    };
}

fn readIndex(bin_data: []const u8, offset: usize, index: usize, component_type: usize) !usize {
    // `index` deriva da acc.count (JSON ostile): aritmetica controllata.
    switch (component_type) {
        5121 => { // u8
            const idx = std.math.add(usize, offset, index) catch return error.OutOfBounds;
            if (idx >= bin_data.len) return error.OutOfBounds;
            return bin_data[idx];
        },
        5123 => { // u16
            const rel = std.math.mul(usize, index, 2) catch return error.OutOfBounds;
            const idx = std.math.add(usize, offset, rel) catch return error.OutOfBounds;
            const end = std.math.add(usize, idx, 2) catch return error.OutOfBounds;
            if (end > bin_data.len) return error.OutOfBounds;
            return std.mem.readInt(u16, bin_data[idx..][0..2], .little);
        },
        5125 => { // u32
            const rel = std.math.mul(usize, index, 4) catch return error.OutOfBounds;
            const idx = std.math.add(usize, offset, rel) catch return error.OutOfBounds;
            const end = std.math.add(usize, idx, 4) catch return error.OutOfBounds;
            if (end > bin_data.len) return error.OutOfBounds;
            return std.mem.readInt(u32, bin_data[idx..][0..4], .little);
        },
        else => return error.UnsupportedIndexType,
    }
}

fn decodeExport(
    path: decoder.SliceC,
    content: decoder.SliceC,
    allocator_ptr: *const anyopaque,
    coarse: bool,
) decoder.DecodedC {
    const allocator = @as(*const std.mem.Allocator, @ptrCast(@alignCast(allocator_ptr))).*;
    const filename = std.fs.path.basename(path.toSlice());
    const decoded = decode(content.toSlice(), filename, allocator, coarse);
    return decoded.toDecodedC(allocator) catch |err| {
        const msg = std.fmt.allocPrint(allocator, "Conversion error: {s}", .{@errorName(err)}) catch "error";
        return .{
            .tag = .err,
            .payload = .{ .err = decoder.SliceC.fromSlice(msg) },
        };
    };
}

export fn zuer_decode(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    _ = io_ptr;
    return decodeExport(path, content, allocator_ptr, false);
}

// Prima fase progressiva: texture al tier coarse (256², da cache se presente →
// resa istantanea). L'host la usa opzionalmente prima di `zuer_decode` (full).
export fn zuer_decode_coarse(
    path: decoder.SliceC,
    content: decoder.SliceC,
    io_ptr: *const anyopaque,
    allocator_ptr: *const anyopaque,
) callconv(.c) decoder.DecodedC {
    _ = io_ptr;
    return decodeExport(path, content, allocator_ptr, true);
}

const extensions = "glb";

export fn zuer_extensions() callconv(.c) decoder.SliceC {
    return decoder.SliceC.fromSlice(extensions);
}

/// Versione dell'ABI plugin con cui questo decoder è compilato: l'host la
/// confronta con la propria `decoder.abi_version` e scarta i mismatch.
export fn zuer_abi_version() callconv(.c) u32 {
    return decoder.abi_version;
}
