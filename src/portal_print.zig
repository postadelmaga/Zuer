//! Dialogo di stampa del desktop (Linux) via xdg-desktop-portal:
//! `org.freedesktop.portal.Print`. È la finestra di stampa di KDE o GNOME, con
//! le stampanti di CUPS, copie, intervallo di pagine, fronte-retro e anteprima;
//! funziona anche da Flatpak e con CUPS solo dietro al portale.
//!
//! Due passi, ciascuno con la risposta che arriva come segnale
//! `org.freedesktop.portal.Request.Response` sull'oggetto della richiesta:
//! 1. `PreparePrint` apre il dialogo e restituisce un `token`;
//! 2. `Print` riceve il PDF come file descriptor (SCM_RIGHTS) e quel `token`:
//!    il backend lo stampa con le impostazioni scelte.
//!
//! Il bus è parlato direttamente (socket unix, autenticazione EXTERNAL, un
//! sottoinsieme del protocollo D-Bus): niente libdbus né sd-bus da caricare.
//! Tutto è bloccante e va chiamato dal thread della stampa.

const std = @import("std");
const builtin = std.builtin;

pub const Error = error{
    /// Nessun bus di sessione, nessun portale o nessuna interfaccia Print:
    /// il chiamante ripiega sulla stampa diretta.
    Unavailable,
    /// Il portale ha risposto con un errore o con dati inattesi.
    Failed,
    OutOfMemory,
};

pub const Outcome = enum { ok, cancelled };

const portal_dest = "org.freedesktop.portal.Desktop";
const portal_path = "/org/freedesktop/portal/desktop";
const print_iface = "org.freedesktop.portal.Print";

// ── Socket ──────────────────────────────────────────────────────────────────

extern "c" fn socket(domain: c_int, sock_type: c_int, protocol: c_int) c_int;
extern "c" fn connect(fd: c_int, addr: *const anyopaque, len: u32) c_int;
extern "c" fn close(fd: c_int) c_int;
extern "c" fn read(fd: c_int, buf: [*]u8, n: usize) isize;
extern "c" fn sendmsg(fd: c_int, msg: *const MsgHdr, flags: c_int) isize;
extern "c" fn getuid() u32;
extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;

const AF_UNIX = 1;
const SOCK_STREAM = 1;
const SOCK_CLOEXEC = 0o2000000;
const SOL_SOCKET = 1;
const SCM_RIGHTS = 1;
const MSG_NOSIGNAL = 0x4000;

const SockaddrUn = extern struct {
    family: u16 = AF_UNIX,
    path: [108]u8 = @splat(0),
};

const IoVec = extern struct { base: [*]const u8, len: usize };
const MsgHdr = extern struct {
    name: ?*anyopaque = null,
    namelen: u32 = 0,
    iov: [*]const IoVec,
    iovlen: usize,
    control: ?*const anyopaque = null,
    controllen: usize = 0,
    flags: c_int = 0,
};
/// cmsghdr (glibc) seguito da un solo fd, allineato come CMSG_SPACE(4).
const FdCmsg = extern struct {
    len: usize,
    level: c_int,
    type: c_int,
    fd: c_int,
    pad: c_int = 0,
};

/// Connessione al bus di sessione, già autenticata e con il nome unico.
const Bus = struct {
    fd: c_int,
    gpa: std.mem.Allocator,
    serial: u32 = 0,
    /// Nome unico assegnato dal bus (":1.42").
    name: []u8 = &.{},
    /// Byte letti dal socket non ancora consumati.
    in: std.ArrayList(u8) = .empty,
    /// Segnale `Response` arrivato mentre si aspettava una risposta di metodo:
    /// lo raccoglie `waitResponse`.
    pending: ?Message = null,

    fn open(gpa: std.mem.Allocator) Error!Bus {
        var addr: SockaddrUn = .{};
        var abstract = false;
        const path = blk: {
            if (getenv("DBUS_SESSION_BUS_ADDRESS")) |a| {
                // "unix:path=/run/user/1000/bus;…" — si usa il primo indirizzo unix.
                var it = std.mem.splitScalar(u8, std.mem.span(a), ';');
                while (it.next()) |entry| {
                    if (!std.mem.startsWith(u8, entry, "unix:")) continue;
                    var kv = std.mem.splitScalar(u8, entry["unix:".len..], ',');
                    while (kv.next()) |p| {
                        if (std.mem.startsWith(u8, p, "path=")) break :blk p["path=".len..];
                        if (std.mem.startsWith(u8, p, "abstract=")) {
                            abstract = true;
                            break :blk p["abstract=".len..];
                        }
                    }
                }
                return error.Unavailable;
            }
            // Senza variabile: il socket standard di systemd/dbus-broker.
            const rt = getenv("XDG_RUNTIME_DIR") orelse return error.Unavailable;
            const n = std.fmt.bufPrint(addr.path[0 .. addr.path.len - 1], "{s}/bus", .{std.mem.span(rt)}) catch return error.Unavailable;
            break :blk addr.path[0..n.len];
        };
        // I percorsi con escape (%xx) non si usano mai per il bus di sessione.
        if (std.mem.indexOfScalar(u8, path, '%') != null) return error.Unavailable;
        const off: usize = @intFromBool(abstract);
        if (path.len + off >= addr.path.len) return error.Unavailable;
        if (@intFromPtr(path.ptr) != @intFromPtr(&addr.path)) @memcpy(addr.path[off .. off + path.len], path);
        const len: u32 = @intCast(@sizeOf(u16) + off + path.len + @intFromBool(!abstract));

        const fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
        if (fd < 0) return error.Unavailable;
        errdefer _ = close(fd);
        if (connect(fd, &addr, len) != 0) return error.Unavailable;

        var bus: Bus = .{ .fd = fd, .gpa = gpa };
        errdefer bus.in.deinit(gpa);
        try bus.auth();
        try bus.hello();
        return bus;
    }

    fn deinit(self: *Bus) void {
        if (self.pending) |*m| m.deinit(self.gpa);
        _ = close(self.fd);
        self.gpa.free(self.name);
        self.in.deinit(self.gpa);
    }

    fn writeAll(self: *Bus, bytes: []const u8) Error!void {
        var rest = bytes;
        while (rest.len > 0) {
            const iov = [_]IoVec{.{ .base = rest.ptr, .len = rest.len }};
            const n = sendmsg(self.fd, &.{ .iov = &iov, .iovlen = 1 }, MSG_NOSIGNAL);
            if (n <= 0) return error.Failed;
            rest = rest[@intCast(n)..];
        }
    }

    /// Altri byte dal socket in coda a `in`.
    fn fill(self: *Bus) Error!void {
        var buf: [4096]u8 = undefined;
        const n = read(self.fd, &buf, buf.len);
        if (n <= 0) return error.Failed;
        try self.in.appendSlice(self.gpa, buf[0..@intCast(n)]);
    }

    fn consume(self: *Bus, n: usize) void {
        const rest = self.in.items.len - n;
        std.mem.copyForwards(u8, self.in.items[0..rest], self.in.items[n..]);
        self.in.items.len = rest;
    }

    /// Una riga del dialogo di autenticazione (senza "\r\n").
    fn authLine(self: *Bus, out: []u8) Error![]u8 {
        while (true) {
            if (std.mem.indexOf(u8, self.in.items, "\r\n")) |i| {
                if (i > out.len) return error.Failed;
                @memcpy(out[0..i], self.in.items[0..i]);
                self.consume(i + 2);
                return out[0..i];
            }
            if (self.in.items.len > 1024) return error.Failed;
            try self.fill();
        }
    }

    fn auth(self: *Bus) Error!void {
        // EXTERNAL: l'uid in decimale, scritto in esadecimale carattere per carattere.
        var uid_buf: [16]u8 = undefined;
        const uid = std.fmt.bufPrint(&uid_buf, "{d}", .{getuid()}) catch unreachable;
        var line: [96]u8 = undefined;
        const cmd = std.fmt.bufPrint(&line, "\x00AUTH EXTERNAL {x}\r\n", .{uid}) catch unreachable;
        try self.writeAll(cmd);
        var resp: [256]u8 = undefined;
        if (!std.mem.startsWith(u8, try self.authLine(&resp), "OK ")) return error.Unavailable;
        try self.writeAll("NEGOTIATE_UNIX_FD\r\n");
        if (!std.mem.eql(u8, try self.authLine(&resp), "AGREE_UNIX_FD")) return error.Unavailable;
        try self.writeAll("BEGIN\r\n");
    }

    fn hello(self: *Bus) Error!void {
        const serial = try self.call(.{
            .dest = "org.freedesktop.DBus",
            .path = "/org/freedesktop/DBus",
            .iface = "org.freedesktop.DBus",
            .member = "Hello",
        }, "", "", null);
        var reply = try self.waitReply(serial);
        defer reply.deinit(self.gpa);
        var r = reply.bodyReader();
        self.name = try self.gpa.dupe(u8, try r.string());
    }

    const Target = struct { dest: []const u8, path: []const u8, iface: []const u8, member: []const u8 };

    /// Manda una chiamata di metodo con il corpo già serializzato (`sig`/`body`)
    /// e, se dato, un file descriptor. Ritorna il serial della chiamata.
    fn call(self: *Bus, t: Target, sig: []const u8, body: []const u8, fd: ?c_int) Error!u32 {
        self.serial += 1;
        var m: Writer = .{ .gpa = self.gpa };
        defer m.list.deinit(self.gpa);
        try m.byte('l');
        try m.byte(1); // METHOD_CALL
        try m.byte(0);
        try m.byte(1);
        try m.uint(@intCast(body.len));
        try m.uint(self.serial);
        const fields = try m.beginArray(8);
        try m.field(1, "o", t.path);
        try m.field(2, "s", t.iface);
        try m.field(3, "s", t.member);
        try m.field(6, "s", t.dest);
        if (sig.len > 0) try m.field(8, "g", sig);
        if (fd != null) {
            try m.pad(8);
            try m.byte(9);
            try m.signature("u");
            try m.uint(1);
        }
        m.endArray(fields);
        try m.pad(8);
        try m.list.appendSlice(self.gpa, body);

        if (fd) |f| {
            const cm: FdCmsg = .{ .len = @sizeOf(usize) + 2 * @sizeOf(c_int) + @sizeOf(c_int), .level = SOL_SOCKET, .type = SCM_RIGHTS, .fd = f };
            const iov = [_]IoVec{.{ .base = m.list.items.ptr, .len = m.list.items.len }};
            const n = sendmsg(self.fd, &.{ .iov = &iov, .iovlen = 1, .control = &cm, .controllen = @sizeOf(FdCmsg) }, MSG_NOSIGNAL);
            if (n <= 0) return error.Failed;
            // L'fd viaggia col primo byte: il resto, se il kernel l'ha spezzato, va a parte.
            try self.writeAll(m.list.items[@intCast(n)..]);
        } else {
            try self.writeAll(m.list.items);
        }
        return self.serial;
    }

    /// Il prossimo messaggio completo dal bus.
    fn next(self: *Bus) Error!Message {
        while (self.in.items.len < 16) try self.fill();
        const big = switch (self.in.items[0]) {
            'l' => false,
            'B' => true,
            else => return error.Failed,
        };
        const rd = struct {
            fn f(b: []const u8, be: bool) u32 {
                return std.mem.readInt(u32, b[0..4], if (be) .big else .little);
            }
        }.f;
        const body_len = rd(self.in.items[4..8], big);
        const fields_len = rd(self.in.items[12..16], big);
        if (body_len > 1 << 24 or fields_len > 1 << 20) return error.Failed;
        const hdr_end = std.mem.alignForward(usize, 16 + fields_len, 8);
        const total = hdr_end + body_len;
        while (self.in.items.len < total) try self.fill();
        const bytes = try self.gpa.dupe(u8, self.in.items[0..total]);
        self.consume(total);
        var msg: Message = .{ .bytes = bytes, .big = big, .kind = bytes[1], .body_start = hdr_end };
        errdefer msg.deinit(self.gpa);
        // Campi dell'intestazione.
        var r: Reader = .{ .b = bytes[0..hdr_end], .pos = 16, .big = big };
        const end = 16 + fields_len;
        while (r.pos < end) {
            try r.alignTo(8);
            if (r.pos >= end) break;
            const code = try r.u8_();
            const s = try r.sig();
            switch (code) {
                1 => msg.path = try r.string(),
                2 => msg.iface = try r.string(),
                3 => msg.member = try r.string(),
                4 => msg.err_name = try r.string(),
                5 => msg.reply_serial = try r.u32_(),
                8 => msg.body_sig = try r.sig(),
                else => try r.skip(s),
            }
        }
        return msg;
    }

    /// Aspetta la risposta alla chiamata `serial` (i segnali in mezzo si
    /// scartano). Un errore D-Bus diventa `Unavailable` se dice che il portale
    /// o la sua interfaccia mancano, `Failed` altrimenti.
    fn waitReply(self: *Bus, serial: u32) Error!Message {
        while (true) {
            var m = try self.next();
            if ((m.kind == 2 or m.kind == 3) and m.reply_serial == serial) {
                if (m.kind == 3) {
                    defer m.deinit(self.gpa);
                    const missing = for ([_][]const u8{ "ServiceUnknown", "UnknownMethod", "UnknownInterface", "UnknownObject", "NameHasNoOwner" }) |e| {
                        if (std.mem.endsWith(u8, m.err_name, e)) break true;
                    } else false;
                    return if (missing) error.Unavailable else error.Failed;
                }
                return m;
            }
            if (m.kind == 4 and std.mem.eql(u8, m.member, "Response") and self.pending == null) {
                self.pending = m;
                continue;
            }
            m.deinit(self.gpa);
        }
    }

    /// Aspetta il segnale `Response` della richiesta `handle`: codice di
    /// risposta e, se c'è, il `token` nei risultati.
    fn waitResponse(self: *Bus, handle: []const u8) Error!struct { code: u32, token: ?u32 } {
        while (true) {
            var m = if (self.pending) |p| p else try self.next();
            self.pending = null;
            defer m.deinit(self.gpa);
            if (m.kind != 4 or !std.mem.eql(u8, m.member, "Response") or !std.mem.eql(u8, m.path, handle)) continue;
            if (!std.mem.eql(u8, m.body_sig, "ua{sv}")) return error.Failed;
            var r = m.bodyReader();
            const code = try r.u32_();
            var token: ?u32 = null;
            const end = try r.arrayStart(8);
            while (r.pos < end) {
                try r.alignTo(8);
                const key = try r.string();
                const vs = try r.sig();
                if (std.mem.eql(u8, key, "token") and std.mem.eql(u8, vs, "u")) {
                    token = try r.u32_();
                } else try r.skip(vs);
            }
            return .{ .code = code, .token = token };
        }
    }

    fn addMatch(self: *Bus, handle: []const u8) Error!void {
        var w: Writer = .{ .gpa = self.gpa };
        defer w.list.deinit(self.gpa);
        var rule_buf: [256]u8 = undefined;
        const rule = std.fmt.bufPrint(&rule_buf, "type='signal',interface='org.freedesktop.portal.Request',member='Response',path='{s}'", .{handle}) catch return error.Failed;
        try w.string(rule);
        const serial = try self.call(.{
            .dest = "org.freedesktop.DBus",
            .path = "/org/freedesktop/DBus",
            .iface = "org.freedesktop.DBus",
            .member = "AddMatch",
        }, "s", w.list.items, null);
        var reply = try self.waitReply(serial);
        reply.deinit(self.gpa);
    }

    /// Percorso dell'oggetto Request che il portale creerà per `token`
    /// (/org/freedesktop/portal/desktop/request/SENDER/TOKEN): l'abbonamento al
    /// segnale va fatto PRIMA della chiamata, o la risposta può sfuggire.
    fn requestPath(self: *Bus, buf: []u8, token: []const u8) Error![]const u8 {
        var sender: [64]u8 = undefined;
        const nm = if (self.name.len > 0 and self.name[0] == ':') self.name[1..] else self.name;
        if (nm.len > sender.len) return error.Failed;
        for (nm, 0..) |ch, i| sender[i] = if (ch == '.') '_' else ch;
        return std.fmt.bufPrint(buf, "/org/freedesktop/portal/desktop/request/{s}/{s}", .{ sender[0..nm.len], token }) catch error.Failed;
    }
};

const Message = struct {
    bytes: []u8,
    big: bool,
    kind: u8,
    body_start: usize,
    path: []const u8 = "",
    iface: []const u8 = "",
    member: []const u8 = "",
    err_name: []const u8 = "",
    body_sig: []const u8 = "",
    reply_serial: u32 = 0,

    fn deinit(self: *Message, gpa: std.mem.Allocator) void {
        gpa.free(self.bytes);
    }

    /// Lettore del corpo: l'allineamento è relativo all'inizio del messaggio,
    /// che coincide (modulo 8) con quello del corpo.
    fn bodyReader(self: *const Message) Reader {
        return .{ .b = self.bytes, .pos = self.body_start, .big = self.big };
    }
};

// ── Serializzazione ─────────────────────────────────────────────────────────

const Writer = struct {
    gpa: std.mem.Allocator,
    list: std.ArrayList(u8) = .empty,

    fn pad(self: *Writer, a: usize) Error!void {
        while (self.list.items.len % a != 0) try self.list.append(self.gpa, 0);
    }
    fn byte(self: *Writer, v: u8) Error!void {
        try self.list.append(self.gpa, v);
    }
    fn uint(self: *Writer, v: u32) Error!void {
        try self.pad(4);
        try self.list.appendSlice(self.gpa, &std.mem.toBytes(std.mem.nativeToLittle(u32, v)));
    }
    fn string(self: *Writer, s: []const u8) Error!void {
        try self.uint(@intCast(s.len));
        try self.list.appendSlice(self.gpa, s);
        try self.byte(0);
    }
    fn signature(self: *Writer, s: []const u8) Error!void {
        try self.byte(@intCast(s.len));
        try self.list.appendSlice(self.gpa, s);
        try self.byte(0);
    }
    /// Apre un array: ritorna la posizione della lunghezza da chiudere con
    /// `endArray` (la lunghezza esclude il padding verso il primo elemento).
    fn beginArray(self: *Writer, elem_align: usize) Error!struct { at: usize, start: usize } {
        try self.uint(0);
        const at = self.list.items.len - 4;
        try self.pad(elem_align);
        return .{ .at = at, .start = self.list.items.len };
    }
    fn endArray(self: *Writer, a: anytype) void {
        const n: u32 = @intCast(self.list.items.len - a.start);
        @memcpy(self.list.items[a.at..][0..4], &std.mem.toBytes(std.mem.nativeToLittle(u32, n)));
    }
    /// Campo dell'intestazione (struct (yv)) con un valore stringa.
    fn field(self: *Writer, code: u8, sig: []const u8, v: []const u8) Error!void {
        try self.pad(8);
        try self.byte(code);
        try self.signature(sig);
        if (sig[0] == 'g') try self.signature(v) else try self.string(v);
    }
    /// Voce di un dizionario a{sv}.
    fn entry(self: *Writer, key: []const u8, comptime vsig: []const u8, v: anytype) Error!void {
        try self.pad(8);
        try self.string(key);
        try self.signature(vsig);
        switch (vsig[0]) {
            's' => try self.string(v),
            'u' => try self.uint(v),
            'b' => try self.uint(@intFromBool(v)),
            else => @compileError("tipo non gestito"),
        }
    }
};

const Reader = struct {
    b: []const u8,
    pos: usize,
    big: bool,

    fn alignTo(self: *Reader, a: usize) Error!void {
        self.pos = std.mem.alignForward(usize, self.pos, a);
        if (self.pos > self.b.len) return error.Failed;
    }
    fn take(self: *Reader, n: usize) Error![]const u8 {
        if (self.pos + n > self.b.len) return error.Failed;
        defer self.pos += n;
        return self.b[self.pos..][0..n];
    }
    fn u8_(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }
    fn u32_(self: *Reader) Error!u32 {
        try self.alignTo(4);
        return std.mem.readInt(u32, (try self.take(4))[0..4], if (self.big) .big else .little);
    }
    fn string(self: *Reader) Error![]const u8 {
        const n = try self.u32_();
        const s = try self.take(@as(usize, n) + 1);
        return s[0..n];
    }
    fn sig(self: *Reader) Error![]const u8 {
        const n = try self.u8_();
        const s = try self.take(@as(usize, n) + 1);
        return s[0..n];
    }
    /// Lunghezza di un array e allineamento al primo elemento: ritorna la fine.
    fn arrayStart(self: *Reader, elem_align: usize) Error!usize {
        const n = try self.u32_();
        try self.alignTo(elem_align);
        const end = self.pos + n;
        if (end > self.b.len) return error.Failed;
        return end;
    }
    /// Salta i valori della firma `s` (uno o più tipi completi).
    fn skip(self: *Reader, s: []const u8) Error!void {
        var i: usize = 0;
        while (i < s.len) i = try self.skipOne(s, i);
    }
    /// Salta un valore del tipo completo che inizia a `s[i]`; ritorna l'indice
    /// del tipo successivo nella firma.
    fn skipOne(self: *Reader, s: []const u8, i: usize) Error!usize {
        switch (s[i]) {
            'y' => _ = try self.take(1),
            'n', 'q' => {
                try self.alignTo(2);
                _ = try self.take(2);
            },
            'b', 'i', 'u', 'h' => _ = try self.u32_(),
            'x', 't', 'd' => {
                try self.alignTo(8);
                _ = try self.take(8);
            },
            's', 'o' => _ = try self.string(),
            'g' => _ = try self.sig(),
            'v' => try self.skip(try self.sig()),
            'a' => {
                const elem_end = try typeEnd(s, i + 1);
                const end = try self.arrayStart(typeAlign(s[i + 1]));
                self.pos = end;
                return elem_end;
            },
            '(', '{' => {
                try self.alignTo(8);
                const close_ch: u8 = if (s[i] == '(') ')' else '}';
                var j = i + 1;
                while (j < s.len and s[j] != close_ch) j = try self.skipOne(s, j);
                if (j >= s.len) return error.Failed;
                return j + 1;
            },
            else => return error.Failed,
        }
        return i + 1;
    }
};

fn typeAlign(c: u8) usize {
    return switch (c) {
        'y', 'g', 'v' => 1,
        'n', 'q' => 2,
        'x', 't', 'd', '(', '{' => 8,
        else => 4,
    };
}

/// Indice successivo al tipo completo che inizia a `s[i]`.
fn typeEnd(s: []const u8, i: usize) Error!usize {
    if (i >= s.len) return error.Failed;
    switch (s[i]) {
        'a' => return typeEnd(s, i + 1),
        '(', '{' => {
            const close_ch: u8 = if (s[i] == '(') ')' else '}';
            var j = i + 1;
            while (j < s.len and s[j] != close_ch) j = try typeEnd(s, j);
            if (j >= s.len) return error.Failed;
            return j + 1;
        },
        else => return i + 1,
    }
}

// ── Portale ─────────────────────────────────────────────────────────────────

/// Sessione di stampa col portale: la connessione resta aperta tra il dialogo
/// (`prepare`) e l'invio (`print`), che deve riusare il `token`.
pub const Session = struct {
    bus: Bus,
    token: u32 = 0,
    seq: u32 = 0,

    pub fn open(gpa: std.mem.Allocator) Error!Session {
        return .{ .bus = try Bus.open(gpa) };
    }

    pub fn deinit(self: *Session) void {
        self.bus.deinit();
    }

    /// Mostra il dialogo di stampa del desktop. Ritorna quando l'utente ha
    /// scelto (`.ok`) o annullato. `error.Unavailable` se il portale non offre
    /// la stampa: il chiamante ripiega sulla stampa diretta.
    pub fn prepare(self: *Session, title: []const u8, accept_label: []const u8) Error!Outcome {
        const gpa = self.bus.gpa;
        var tok_buf: [32]u8 = undefined;
        const handle_token = self.nextToken(&tok_buf);
        var path_buf: [256]u8 = undefined;
        const handle = try self.bus.requestPath(&path_buf, handle_token);
        try self.bus.addMatch(handle);

        var w: Writer = .{ .gpa = gpa };
        defer w.list.deinit(gpa);
        try w.string(""); // parent_window: nessun handle esportato
        try w.string(title);
        const settings = try w.beginArray(8);
        w.endArray(settings);
        const page_setup = try w.beginArray(8);
        w.endArray(page_setup);
        const opts = try w.beginArray(8);
        try w.entry("handle_token", "s", handle_token);
        try w.entry("modal", "b", true);
        try w.entry("accept_label", "s", accept_label);
        w.endArray(opts);
        const serial = try self.bus.call(.{ .dest = portal_dest, .path = portal_path, .iface = print_iface, .member = "PreparePrint" }, "ssa{sv}a{sv}a{sv}", w.list.items, null);
        var reply = try self.bus.waitReply(serial);
        reply.deinit(gpa);

        const res = try self.bus.waitResponse(handle);
        return switch (res.code) {
            0 => blk: {
                self.token = res.token orelse return error.Failed;
                break :blk .ok;
            },
            1 => .cancelled,
            else => error.Failed,
        };
    }

    /// Manda il PDF aperto in `fd` alla stampante scelta in `prepare`.
    pub fn print(self: *Session, title: []const u8, fd: c_int) Error!Outcome {
        const gpa = self.bus.gpa;
        var tok_buf: [32]u8 = undefined;
        const handle_token = self.nextToken(&tok_buf);
        var path_buf: [256]u8 = undefined;
        const handle = try self.bus.requestPath(&path_buf, handle_token);
        try self.bus.addMatch(handle);

        var w: Writer = .{ .gpa = gpa };
        defer w.list.deinit(gpa);
        try w.string("");
        try w.string(title);
        try w.uint(0); // fd: indice 0 tra quelli allegati al messaggio
        const opts = try w.beginArray(8);
        try w.entry("handle_token", "s", handle_token);
        try w.entry("modal", "b", true);
        try w.entry("token", "u", self.token);
        w.endArray(opts);
        const serial = try self.bus.call(.{ .dest = portal_dest, .path = portal_path, .iface = print_iface, .member = "Print" }, "ssha{sv}", w.list.items, fd);
        var reply = try self.bus.waitReply(serial);
        reply.deinit(gpa);

        const res = try self.bus.waitResponse(handle);
        return switch (res.code) {
            0 => .ok,
            1 => .cancelled,
            else => error.Failed,
        };
    }

    fn nextToken(self: *Session, buf: []u8) []const u8 {
        self.seq += 1;
        return std.fmt.bufPrint(buf, "zuer_print_{d}_{d}", .{ std.c.getpid(), self.seq }) catch unreachable;
    }
};

test "firma: salto di tipi annidati" {
    // a{sv} con una voce "k" → variant "(us)" = (7, "x")
    const gpa = std.testing.allocator;
    var w: Writer = .{ .gpa = gpa };
    defer w.list.deinit(gpa);
    try w.uint(3);
    const a = try w.beginArray(8);
    try w.pad(8);
    try w.string("k");
    try w.signature("(us)");
    try w.pad(8);
    try w.uint(7);
    try w.string("x");
    try w.entry("token", "u", 42);
    w.endArray(a);
    var r: Reader = .{ .b = w.list.items, .pos = 0, .big = false };
    try std.testing.expectEqual(@as(u32, 3), try r.u32_());
    const end = try r.arrayStart(8);
    var token: ?u32 = null;
    while (r.pos < end) {
        try r.alignTo(8);
        const key = try r.string();
        const vs = try r.sig();
        if (std.mem.eql(u8, key, "token")) token = try r.u32_() else try r.skip(vs);
    }
    try std.testing.expectEqual(@as(?u32, 42), token);
}
