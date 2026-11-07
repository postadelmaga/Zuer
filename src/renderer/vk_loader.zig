//! Caricamento a runtime del loader Vulkan: nessun eseguibile importa più
//! `vulkan-1.dll` / `libvulkan.so.1` staticamente, quindi Zuer parte anche dove
//! Vulkan non c'è e il renderer GPU si spegne con un errore preciso.
//!
//! Le condizioni restano distinte, ognuna con il suo errore:
//!   - loader assente                    → `error.VulkanLoaderMissing`
//!   - loader senza `vkGetInstanceProcAddr` o comandi core → `error.VulkanLoaderInvalid`
//!   - istanza rifiutata (nessun driver: VK_ERROR_INCOMPATIBLE_DRIVER)
//!                                       → `error.VulkanNoDriver` (in gpu_renderer)
//!   - nessun device / nessuna coda grafica / device non creato
//!                                       → `NoGpu` / `VulkanDeviceFailed` (in gpu_renderer)
//!
//! Dispatch: `vkGetInstanceProcAddr` è l'unico simbolo cercato nella libreria;
//! i comandi globali vengono da `vkGetInstanceProcAddr(NULL, …)`, quelli di
//! istanza e di device da `vkGetInstanceProcAddr(instance, …)` alla prima istanza
//! creata. Per i comandi di device il loader restituisce i propri trampolini, che
//! smistano sul dispatchable handle: valgono per ogni device e ogni istanza finché
//! la libreria è caricata. Per questo la tabella è una sola, risolta una volta, e
//! la libreria NON viene mai scaricata (resta fino all'uscita del processo: nessun
//! oggetto Vulkan può sopravvivere al codice che lo serve). Le estensioni di device
//! restano su `vkGetDeviceProcAddr`, per device, come prima.
//!
//! Test: `ZUER_VULKAN_LOADER=<percorso>` sostituisce la ricerca standard;
//! `ZUER_VULKAN_LOADER=none` simula un sistema senza loader.

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vk.zig");
const dynlib = @import("../dynlib.zig");

pub const Error = error{ VulkanLoaderMissing, VulkanLoaderInvalid };

extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// Nomi cercati, in ordine. macOS: il loader (se installato) e poi MoltenVK
/// usato direttamente (espone vkGetInstanceProcAddr), prima quello nel bundle.
const candidates: []const []const u8 = switch (builtin.os.tag) {
    .windows => &.{"vulkan-1.dll"},
    .macos => &.{
        "@executable_path/../Frameworks/libMoltenVK.dylib",
        "libvulkan.1.dylib",
        "libMoltenVK.dylib",
    },
    else => &.{ "libvulkan.so.1", "libvulkan.so" },
};

// Spinlock (std.atomic.Mutex, come hwdec_caps): Renderer.init non ha un `Io`.
var mutex: std.atomic.Mutex = .unlocked;

fn lock() void {
    while (!mutex.tryLock()) std.Thread.yield() catch {};
}
var lib: ?dynlib.Lib = null;
var gipa: ?vk.PfnGetInstanceProcAddr = null;
var global_state: ?Error!void = null;
var instance_ready = false;

/// Nome (o percorso) della libreria caricata, per i log.
pub var loaded_name: []const u8 = "";

/// Apre il loader e risolve i comandi globali. Idempotente e thread-safe; il
/// risultato (anche un fallimento) è memorizzato: un loader assente non viene
/// ricercato a ogni tentativo del renderer.
pub fn ensureLoaded() Error!void {
    lock();
    defer mutex.unlock();
    if (global_state) |st| return st;
    global_state = loadLocked();
    return global_state.?;
}

fn loadLocked() Error!void {
    const override: ?[]const u8 = if (getenv("ZUER_VULKAN_LOADER")) |p| std.mem.sliceTo(p, 0) else null;
    if (override) |o| {
        if (std.mem.eql(u8, o, "none")) return error.VulkanLoaderMissing;
        lib = dynlib.Lib.open(o) catch return error.VulkanLoaderMissing;
        loaded_name = o;
    } else {
        for (candidates) |name| {
            lib = dynlib.Lib.openSystem(name) catch continue;
            loaded_name = name;
            break;
        }
        if (lib == null) return error.VulkanLoaderMissing;
    }
    gipa = lib.?.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse
        return error.VulkanLoaderInvalid;
    inline for (@typeInfo(vk.Dispatch).@"struct".field_names) |name| {
        if (comptime vk.level(name) == .global) {
            const p = gipa.?(null, name) orelse return error.VulkanLoaderInvalid;
            @field(vk.dispatch, name) = @ptrCast(p);
        }
    }
}

/// Risolve i comandi di istanza e di device da `instance` (la prima istanza
/// creata con successo). Da chiamare subito dopo vkCreateInstance, prima di
/// qualunque altro comando. Thread-safe; le chiamate successive non fanno nulla.
pub fn ensureInstance(instance: vk.VkInstance) Error!void {
    lock();
    defer mutex.unlock();
    if (instance_ready) return;
    inline for (@typeInfo(vk.Dispatch).@"struct".field_names) |name| {
        if (comptime vk.level(name) != .global) {
            const p = gipa.?(instance, name) orelse return error.VulkanLoaderInvalid;
            @field(vk.dispatch, name) = @ptrCast(p);
        }
    }
    instance_ready = true;
}

/// Distrugge un'istanza appena creata quando `ensureInstance` è fallito: chiede
/// `vkDestroyInstance` direttamente al loader (la tabella può essere incompleta).
pub fn destroyInstanceUnresolved(instance: vk.VkInstance) void {
    const g = gipa orelse return;
    const p = g(instance, "vkDestroyInstance") orelse return;
    const destroy: *const fn (vk.VkInstance, ?*const anyopaque) callconv(.c) void = @ptrCast(p);
    destroy(instance, null);
}

var frames_seen = std.atomic.Value(u32).init(0);
var lost_fired = std.atomic.Value(bool).init(false);

/// Perdita del device simulata (`ZUER_TEST_VK_LOST_AFTER=N`): dopo N frame GPU
/// il renderer riceve VK_ERROR_DEVICE_LOST. Una volta sola, salvo
/// `ZUER_TEST_VK_LOST_REPEAT=1` (ogni device nuovo si perde di nuovo: prova il
/// ripiego definitivo dopo i tentativi di recupero).
pub fn testDeviceLost() bool {
    const v = getenv("ZUER_TEST_VK_LOST_AFTER") orelse return false;
    const n = std.fmt.parseInt(u32, std.mem.sliceTo(v, 0), 10) catch return false;
    const repeat = getenv("ZUER_TEST_VK_LOST_REPEAT") != null;
    if (!repeat and lost_fired.load(.monotonic)) return false;
    if (frames_seen.fetchAdd(1, .monotonic) + 1 < n) return false;
    frames_seen.store(0, .monotonic);
    lost_fired.store(true, .monotonic);
    return true;
}

/// Guasto simulato per i test (`ZUER_TEST_VK_FAIL=instance|enumerate|nogpu|device`):
/// verifica i rami di fallback senza toccare driver o sistema.
pub fn testFailure(comptime stage: []const u8) bool {
    const v = getenv("ZUER_TEST_VK_FAIL") orelse return false;
    return std.mem.eql(u8, std.mem.sliceTo(v, 0), stage);
}
