# `src/c/` — umbrella header per translate-c

Zig 0.17 ha rimosso il builtin `@cImport`: gli header C che i sorgenti
includevano in-line passano ora da uno step `b.addTranslateC` dichiarato in
`build.zig`, e il risultato si importa come un normale modulo Zig.

Ogni file qui dentro è l'equivalente di un vecchio blocco `@cImport`: stessi
`#include`, stessi `#define`, stesso ordine. Chi li aggancia è `build.zig`
(`translateC` + gli helper `addTsf`/`addStbTruetype`/`LinkAv`/…), che fornisce
anche gli include path e le macro — un header qui non va mai incluso da C.
