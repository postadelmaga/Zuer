# CLAUDE.md — Zuer (Zig 0.17)

## Regole

- **Compila**: `zig build` deve passare prima di chiudere una modifica (`zig build test` per i test).
- **Formatta**: `zig fmt <file>` sui file toccati.
- **Stile**: convenzioni standard di Zig — funzioni `camelCase`, tipi `PascalCase`, variabili `snake_case`, costanti `snake_case` o `MAIUSCOLE`.
- **Errori**: sempre gestiti in modo esplicito (`try`, `catch`, `if (x) |v| … else |err| …`).

Com'è fatto il progetto: [docs/architettura.md](docs/architettura.md). Come si compila e si impacchetta: [docs/sviluppo.md](docs/sviluppo.md).

## Delega a Gemini (MCP `agy-bridge`)

| Quando | Strumento |
|---|---|
| Dubbi su API di `std` o di librerie esterne (Zig cambia in fretta: non indovinare) | `web_lookup` |
| Log di build o sorgenti oltre 800 righe da ispezionare | `analyze_files` |
| Prima di chiudere patch complesse o che toccano l'allocazione di memoria | `adversarial_review` sul diff git |

Se `web_lookup` fallisce (il print mode di agy può bloccarsi sulla ricerca web) o l'MCP non è in sessione, usa WebSearch e i subagenti di Claude invece di riprovare.
