# CLAUDE.md — Guida all'uso dei Tool in questo Progetto Zig

Questo file guida Claude Code sulle regole del progetto e su come cooperare con la CLI `agy` (Gemini) tramite l'MCP server `agy-bridge`.

## 1. Regole del Progetto (Zig)
- **Compilazione**: Usa `zig build` per verificare che non ci siano errori di compilazione.
- **Formattazione**: Usa `zig fmt <file>` prima di salvare le modifiche.
- **Stile**: Segui le convenzioni standard di Zig (camelCase per le funzioni, PascalCase per i tipi, costanti maiuscole/snake_case).
- **Gestione Errori**: Usa sempre la gestione esplicita degli errori con `try`, `catch`, o `if (err) |e|`.

## 2. Delegazione a `agy-bridge` (Gemini)
Per risparmiare token e velocizzare lo sviluppo, delega i seguenti compiti a Gemini tramite gli strumenti MCP di `agy-bridge`:

### A. Documentazione e Ricerca Web (`web_lookup`)
- Zig evolve rapidamente e la documentazione online è spesso frammentata. Se hai dubbi sulle API della Standard Library di Zig (es. `std.mem`, `std.fs`, `std.json`) o su librerie esterne, **usa `web_lookup`** per cercare informazioni aggiornate sul web anziché tentare di indovinarle.

### B. Analisi di File Grandi (`analyze_files`)
- Se devi ispezionare log di build o file sorgente superiori a 800 righe, **usa `analyze_files`**. Lascia che sia Gemini a riassumere i punti chiave per te, evitando di riempire la tua finestra di contesto.

### C. Doppio Controllo del Codice (`adversarial_review`)
- Prima di finalizzare patch complesse o modifiche all'allocazione di memoria (essenziale in Zig), richiedi una revisione indipendente a Gemini con `adversarial_review` sul diff git.
