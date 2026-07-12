//! Riproduzione MIDI di zuer con TinySoundFont (vendor/tsf). Il file .mid è
//! parsato da TinyMidiLoader (`tml.h`) in una lista collegata di messaggi con
//! tempo assoluto in ms; un **thread dedicato** applica i messaggi al synth
//! (`tsf.h`) e renderizza **f32 interleaved 48 kHz stereo** a blocchi su un
//! `DeviceOut` di zicro. La scrittura sul device è bloccante (backpressure) →
//! il thread avanza a tempo reale e mantiene un **clock** in secondi, come
//! `audio_player.zig` (stesso stile: atomics per play/seek, `start → ?*T`).
//!
//! ## SoundFont
//! tsf sintetizza da un SoundFont **.sf2** (i .sf3 compressi NON sono
//! supportati). Nessun font è incluso in zuer: `findSoundfont` lo cerca a
//! runtime, nell'ordine:
//!   1. env `ZUER_SOUNDFONT` (path esplicito a un .sf2);
//!   2. primo `*.sf2` in `/usr/share/soundfonts/`;
//!   3. primo `*.sf2` in `/usr/share/sounds/sf2/`;
//!   4. primo `*.sf2` nella dir dati utente di zuer
//!      (`~/.local/share/zuer/` su Linux, `%APPDATA%\zuer\` su Windows).
//! Se non si trova nulla `start` ritorna `null` e il chiamante mostra la card
//! informativa (può usare `findSoundfont` per distinguere il caso).

const std = @import("std");
const builtin = @import("builtin");
const zicro = @import("zicro");
const DeviceOut = zicro.audio_device.DeviceOut;
const AudioBlock = zicro.audio.AudioBlock;

const c = @cImport({
    @cInclude("tsf.h");
    @cInclude("tml.h");
});

extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Sleep breve cross-platform senza `io` (il thread audio non ne ha uno).
fn sleepMs(ms: u32) void {
    if (builtin.os.tag == .windows) {
        Sleep(ms);
    } else {
        const req = std.c.timespec{ .sec = ms / 1000, .nsec = @intCast((ms % 1000) * std.time.ns_per_ms) };
        _ = std.c.nanosleep(&req, null);
    }
}

const OUT_RATE: u32 = 48_000;
const OUT_CH: u16 = 2;
/// Frame renderizzati per blocco (~21 ms a 48 kHz): abbastanza piccoli da far
/// atterrare i messaggi MIDI vicino al loro tempo, abbastanza grandi da non
/// stressare il device.
const BLOCK_FRAMES: usize = 1024;
// Il device bufferizza qualche decina di ms davanti al "consumato": il clock è
// il tempo sottomesso meno questa latenza stimata (stessa stima del player audio).
const LATENCY_S: f64 = 0.12;

/// `tml_message` ridichiarata in Zig: la struct C usa union/struct anonime che
/// translate-c espone con nomi generati illeggibili. Stesso layout (verificato
/// a comptime), così i puntatori di tml si castano direttamente.
const Msg = extern struct {
    /// Tempo assoluto del messaggio in millisecondi.
    time: c_uint,
    /// Tipo (TML_NOTE_ON, …) e canale MIDI (0-15).
    type: u8,
    channel: u8,
    param: extern union {
        note: extern struct { key: u8, velocity: u8 },
        cc: extern struct { control: u8, value: u8 },
        program: u8,
        pitch_bend: c_ushort,
    },
    next: ?*Msg,
};

comptime {
    if (@sizeOf(Msg) != @sizeOf(c.tml_message)) @compileError("Msg non combacia con tml_message");
}

/// Cerca un SoundFont .sf2 sul sistema (vedi doc del modulo per l'ordine).
/// Ritorna il path (posseduto dal chiamante, da liberare con `gpa.free`) o
/// null. Il path da `ZUER_SOUNDFONT` è ritornato senza verificarne l'esistenza:
/// se non è valido sarà la load di tsf a fallire (e `start` a tornare null).
pub fn findSoundfont(gpa: std.mem.Allocator) ?[]u8 {
    if (getenv("ZUER_SOUNDFONT")) |v| {
        const s = std.mem.span(v);
        if (s.len > 0) return gpa.dupe(u8, s) catch null;
    }
    // Un event loop usa-e-getta per la scansione delle directory: la discovery
    // gira una volta sola all'apertura del file, il costo è trascurabile.
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    for ([_][]const u8{ "/usr/share/soundfonts", "/usr/share/sounds/sf2" }) |d| {
        if (firstSf2In(io, gpa, d)) |p| return p;
    }
    // Dir dati utente di zuer: ~/.local/share/zuer (POSIX) o %APPDATA%\zuer.
    const base_env: [*:0]const u8 = if (builtin.os.tag == .windows) "APPDATA" else "HOME";
    if (getenv(base_env)) |h| {
        const sub: []const u8 = if (builtin.os.tag == .windows) "zuer" else ".local/share/zuer";
        const dir = std.fs.path.join(gpa, &.{ std.mem.span(h), sub }) catch return null;
        defer gpa.free(dir);
        if (firstSf2In(io, gpa, dir)) |p| return p;
    }
    return null;
}

/// Primo `*.sf2` (case-insensitive) in `dir_path`, come path completo posseduto
/// dal chiamante. null se la directory non esiste o non contiene .sf2.
fn firstSf2In(io: std.Io, gpa: std.mem.Allocator, dir_path: []const u8) ?[]u8 {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.ascii.endsWithIgnoreCase(entry.name, ".sf2")) continue;
        return std.fs.path.join(gpa, &.{ dir_path, entry.name }) catch null;
    }
    return null;
}

pub const MidiPlayer = struct {
    synth: *c.tsf,
    head: *Msg, // testa della lista tml (da liberare con tml_free)
    cursor: ?*Msg, // prossimo messaggio da applicare (solo thread audio)
    duration_ms: u64,
    dev: DeviceOut,
    gpa: std.mem.Allocator,

    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    playing: std.atomic.Value(bool) = .init(true),
    seek_ms: std.atomic.Value(i64) = .init(-1), // richiesta di seek (ms), -1 = nessuna
    clock_ms: std.atomic.Value(i64) = .init(0), // posizione riprodotta stimata (ms)
    // Tempo del brano raggiunto dal render (ms, frazionario). Solo thread audio:
    // le richieste esterne passano dagli atomici qui sopra.
    song_ms: f64 = 0,

    /// Apre il MIDI e avvia il thread di sintesi. `null` (senza errore) se manca
    /// un SoundFont sul sistema, se il file non è un MIDI valido o se il device
    /// audio non si apre.
    pub fn start(path: []const u8, gpa: std.mem.Allocator) ?*MidiPlayer {
        return startInner(path, gpa) catch null;
    }

    /// Corpo di `start` con gestione errori esplicita: gli early-out sono errori
    /// veri così gli `errdefer` liberano synth, lista messaggi e device anche
    /// sui percorsi di fallimento (stesso pattern di audio_player.zig).
    fn startInner(path: []const u8, gpa: std.mem.Allocator) anyerror!*MidiPlayer {
        const sf_path = findSoundfont(gpa) orelse return error.NoSoundfont;
        defer gpa.free(sf_path);
        const sf_z = try gpa.dupeZ(u8, sf_path);
        defer gpa.free(sf_z);
        const synth = c.tsf_load_filename(sf_z.ptr) orelse return error.SoundfontLoadFailed;
        errdefer c.tsf_close(synth);

        const path_z = try gpa.dupeZ(u8, path);
        defer gpa.free(path_z);
        const head_c = c.tml_load_filename(path_z.ptr) orelse return error.MidiLoadFailed;
        errdefer c.tml_free(head_c);
        const head: *Msg = @ptrCast(@alignCast(head_c));

        var time_length: c_uint = 0;
        _ = c.tml_get_info(head_c, null, null, null, null, &time_length);

        var dev = try DeviceOut.open(OUT_RATE, OUT_CH);
        errdefer dev.close();

        c.tsf_set_output(synth, c.TSF_STEREO_INTERLEAVED, @intCast(OUT_RATE), 0.0);
        initChannels(synth);

        const self = try gpa.create(MidiPlayer);
        errdefer gpa.destroy(self);
        self.* = .{
            .synth = synth,
            .head = head,
            .cursor = head,
            .duration_ms = time_length,
            .dev = dev,
            .gpa = gpa,
        };
        self.thread = try std.Thread.spawn(.{}, threadMain, .{self});
        return self;
    }

    /// Pre-inizializza i 16 canali MIDI: tsf ignora le note su canali mai
    /// "creati", e un file può suonare su un canale senza mandare prima un
    /// program change. Canale 10 (indice 9) → percussioni General MIDI.
    fn initChannels(synth: *c.tsf) void {
        var ch: c_int = 0;
        while (ch < 16) : (ch += 1) {
            _ = c.tsf_channel_set_presetnumber(synth, ch, 0, @intFromBool(ch == 9));
        }
    }

    /// Posizione riprodotta in secondi (per la label/progress della GUI).
    /// A fine brano resta ferma sulla durata.
    pub fn clockSeconds(self: *const MidiPlayer) f64 {
        return @as(f64, @floatFromInt(self.clock_ms.load(.monotonic))) / 1000.0;
    }

    /// Durata del brano in secondi (tempo dell'ultimo messaggio della lista).
    pub fn durationSeconds(self: *const MidiPlayer) f64 {
        return @as(f64, @floatFromInt(self.duration_ms)) / 1000.0;
    }

    /// Pausa/riprendi. A fine brano il player si mette in pausa da solo:
    /// per farlo ripartire dall'inizio fare `seek(0)` + `setPlaying(true)`.
    pub fn setPlaying(self: *MidiPlayer, on: bool) void {
        self.playing.store(on, .monotonic);
    }

    /// Stato di riproduzione corrente. Serve alla GUI per il toggle con spazio:
    /// a fine brano `playing` diventa false da solo (vedi threadMain).
    pub fn isPlaying(self: *const MidiPlayer) bool {
        return self.playing.load(.monotonic);
    }

    pub fn seek(self: *MidiPlayer, seconds: f64) void {
        self.seek_ms.store(@intFromFloat(@max(0, seconds) * 1000.0), .monotonic);
    }

    /// Ferma il thread e libera tutto (chiamare una volta e azzerare il puntatore).
    pub fn stopAndDestroy(self: *MidiPlayer) void {
        self.stop.store(true, .monotonic);
        if (self.thread) |t| t.join();
        self.thread = null;
        self.dev.close();
        c.tml_free(@ptrCast(self.head));
        c.tsf_close(self.synth);
        self.gpa.destroy(self);
    }

    fn threadMain(self: *MidiPlayer) void {
        // Buffer di render fisso: BLOCK_FRAMES frame stereo interleaved.
        var buf: [BLOCK_FRAMES * OUT_CH]f32 = undefined;

        while (!self.stop.load(.monotonic)) {
            const sk = self.seek_ms.swap(-1, .monotonic);
            if (sk >= 0) self.applySeek(@intCast(sk));
            if (!self.playing.load(.monotonic)) {
                sleepMs(10);
                continue;
            }
            if (self.cursor == null and c.tsf_active_voice_count(self.synth) == 0) {
                // Fine lista e code di rilascio esaurite: il player si ferma e il
                // clock resta sulla durata; l'eventuale loop lo decide il chiamante.
                self.playing.store(false, .monotonic);
                self.clock_ms.store(@intCast(self.duration_ms), .monotonic);
                continue;
            }
            // Avanza il tempo del brano di un blocco e applica i messaggi maturati
            // (note on/off, program change, pitch bend, control — come l'esempio
            // ufficiale in testa a tml.h), poi renderizza il blocco.
            self.song_ms += @as(f64, @floatFromInt(BLOCK_FRAMES)) * 1000.0 / @as(f64, @floatFromInt(OUT_RATE));
            while (self.cursor) |m| {
                if (@as(f64, @floatFromInt(m.time)) > self.song_ms) break;
                self.applyMessage(m);
                self.cursor = m.next;
            }
            c.tsf_render_float(self.synth, &buf, @intCast(BLOCK_FRAMES), 0);

            var block = AudioBlock.init(self.gpa, OUT_RATE, OUT_CH, &buf) catch continue;
            defer block.deinit();
            self.dev.play(&block); // bloccante → pacing real-time (backpressure)

            const played_ms: i64 = @intFromFloat(@max(0.0, self.song_ms - LATENCY_S * 1000.0));
            self.clock_ms.store(@min(played_ms, @as(i64, @intCast(self.duration_ms))), .monotonic);
        }
    }

    /// Applica un messaggio tml al synth (mappatura dell'esempio ufficiale di
    /// tml.h). KEY/CHANNEL_PRESSURE non hanno API in tsf; SET_TEMPO è già cotto
    /// nei tempi assoluti dei messaggi.
    fn applyMessage(self: *MidiPlayer, m: *const Msg) void {
        const ch: c_int = m.channel;
        switch (m.type) {
            c.TML_PROGRAM_CHANGE => _ = c.tsf_channel_set_presetnumber(self.synth, ch, m.param.program, @intFromBool(ch == 9)),
            c.TML_NOTE_ON => _ = c.tsf_channel_note_on(self.synth, ch, m.param.note.key, @as(f32, @floatFromInt(m.param.note.velocity)) / 127.0),
            c.TML_NOTE_OFF => c.tsf_channel_note_off(self.synth, ch, m.param.note.key),
            c.TML_PITCH_BEND => _ = c.tsf_channel_set_pitchwheel(self.synth, ch, m.param.pitch_bend),
            c.TML_CONTROL_CHANGE => _ = c.tsf_channel_midi_control(self.synth, ch, m.param.cc.control, m.param.cc.value),
            else => {},
        }
    }

    /// Seek con lista tml (pattern standard): si riavvolge alla testa, si azzera
    /// il synth (`tsf_reset` spegne le voci e ricrea i canali da zero) e si
    /// ri-applica lo STATO dei canali — program change, control, pitch bend —
    /// fino al target SENZA renderizzare. Le note passate non si riavviano:
    /// partirebbero tutte insieme nel punto di seek.
    fn applySeek(self: *MidiPlayer, target_ms: u64) void {
        const t = @min(target_ms, self.duration_ms);
        c.tsf_reset(self.synth);
        initChannels(self.synth);
        var cur: ?*Msg = self.head;
        while (cur) |m| {
            if (@as(u64, m.time) >= t) break;
            switch (m.type) {
                c.TML_PROGRAM_CHANGE, c.TML_CONTROL_CHANGE, c.TML_PITCH_BEND => self.applyMessage(m),
                else => {},
            }
            cur = m.next;
        }
        self.cursor = cur;
        self.song_ms = @floatFromInt(t);
        self.clock_ms.store(@intCast(t), .monotonic);
    }
};
