<?php
/**
 * Receiver dei crash report di zuer-gui → issue GitHub.
 *
 * Il client (src/crash_report.zig) POSTa il crash.log come text/plain al
 * prossimo avvio dopo un panic. Questo script:
 *   1. valida (POST, dimensione) e accetta SOLO la forma del log vero: righe
 *      `panic <epoch>s @ 0x<indirizzo>: <messaggio>` (src/crash_log.zig). Chiunque
 *      conosca l'URL può fare POST: tutto il resto è rifiutato;
 *   2. deduplica per firma (prima riga senza timestamp/indirizzi);
 *   3. limita la frequenza: N issue/ora in tutto e M per indirizzo, così un solo
 *      client non consuma la quota di tutti;
 *   4. crea l'issue su GitHub col token letto DA FILE server-side
 *      (mai nel binario distribuito). Il log va in un blocco di codice e non può
 *      chiuderlo: nell'issue non entra Markdown scelto da chi invia.
 *
 * Cosa NON può fare: distinguere un panic vero da uno inventato. Chi conosce
 * l'URL può ancora far aprire un'issue con un messaggio a sua scelta (ASCII, senza
 * link, in un blocco di codice) e, usando il messaggio di un panic comune, far
 * risultare «duplicate» i report veri con lo stesso messaggio per SIG_DAYS giorni.
 * I tetti orari limitano il danno; per toglierlo serve un segreto nel client.
 *
 * Dietro un reverse proxy REMOTE_ADDR è il proxy: il tetto per indirizzo vale
 * allora per tutti insieme. In quel caso alzare MAX_PER_HOUR_IP a MAX_PER_HOUR.
 *
 * Dedup e contatori stanno sotto un lock: due richieste insieme non superano il
 * tetto né aprono due volte la stessa issue.
 *
 * Prova senza GitHub: con ZUER_CRASH_DRY_RUN=1 nell'ambiente del server lo script
 * fa tutto tranne la chiamata all'API e restituisce il payload che avrebbe inviato.
 *
 * Deploy: copia questo file nella docroot e accanto (o in TOKEN_FILE) metti
 * il token in un file 0600 leggibile dall'utente PHP. Consigliato un
 * fine-grained PAT limitato a "Issues: Read and write" sul solo repo Zuer.
 */

const REPO = 'postadelmaga/Zuer';
const MAX_BODY = 64 * 1024;        // dimensione massima del log accettato
const MAX_LINES = 200;             // righe massime (un panic per riga)
const MAX_PER_HOUR = 6;            // tetto issue/ora, in tutto
const MAX_PER_HOUR_IP = 2;         // tetto issue/ora per indirizzo
const BODY_TAIL = 6000;            // coda del log inclusa nell'issue (byte, a righe intere)
const SIG_DAYS = 30;               // dopo, la stessa firma riapre un'issue
// La riga che scrive il client: `panic <epoch>s @ 0x<addr>: <msg>`. Il messaggio
// è testo libero per natura (lo scrive chi chiama @panic), ma quelli veri sono
// ASCII stampabile: niente altro passa.
const LINE_RE = '/^panic ([0-9]{1,12})s @ 0x[0-9a-f]{1,16}: ([\x20-\x7E]{0,1024})$/';

// Il token si cerca in: $ZUER_CRASH_TOKEN_FILE, poi accanto allo script.
$token_file = getenv('ZUER_CRASH_TOKEN_FILE') ?: __DIR__ . '/zuer-crash-token';
// Stato (dedup + rate limit): dir dell'utente PHP, 0700. Meglio impostarla
// esplicitamente fuori dalla tmp condivisa; quella di ripiego viene accettata
// solo se è davvero nostra (vedi sotto).
$state_dir = getenv('ZUER_CRASH_STATE_DIR') ?: sys_get_temp_dir() . '/zuer-crash-state';
$dry_run = getenv('ZUER_CRASH_DRY_RUN') === '1';

header('Content-Type: application/json');

function fail(int $code, string $msg): never
{
    http_response_code($code);
    echo json_encode(['status' => 'error', 'error' => $msg]) . "\n";
    exit;
}

/** Richieste già contate nel file `$file` (0 se non c'è). */
function counted(string $file): int
{
    return is_file($file) && !is_link($file) ? (int)file_get_contents($file) : 0;
}

/**
 * Chiave del tetto per indirizzo: l'indirizzo IPv4, o il prefisso /64 di un IPv6
 * (chi ha un IPv6 ha di solito tutto il /64: contare l'indirizzo intero vorrebbe
 * dire nessun tetto). Si tiene solo un hash.
 */
function client_key(string $addr): string
{
    $bin = @inet_pton($addr);
    if ($bin !== false && strlen($bin) === 16) {
        $bin = substr($bin, 0, 8);
    }
    return substr(sha1($bin === false ? $addr : $bin), 0, 16);
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    fail(405, 'POST only');
}

$log = file_get_contents('php://input', false, null, 0, MAX_BODY + 1);
if ($log === false || strlen($log) > MAX_BODY) {
    fail(413, 'log troppo grande');
}
$log = trim(str_replace("\r\n", "\n", $log));
if ($log === '') {
    fail(400, 'log vuoto');
}
// Deve essere il NOSTRO crash log: ogni riga nella forma che scrive il client
// (solo ASCII stampabile). Niente testo libero pubblicato a nome del maintainer.
$lines = explode("\n", $log);
if (count($lines) > MAX_LINES) {
    fail(413, 'troppe righe');
}
$first_msg = null;
foreach ($lines as $line) {
    if (!preg_match(LINE_RE, $line, $m)) {
        fail(400, 'non è un crash log di zuer');
    }
    // Un panic non contiene indirizzi web: chi li manda vuole un link in un'issue.
    if (preg_match('~://|www\.~i', $m[2])) {
        fail(400, 'non è un crash log di zuer');
    }
    $first_msg ??= $m[2];
}

$platform = substr(preg_replace('/[^\w.,: -]/', '', $_SERVER['HTTP_X_ZUER_PLATFORM'] ?? 'sconosciuta'), 0, 80);

// La dir di stato deve essere una directory vera, nostra e non leggibile da altri:
// nella tmp condivisa un altro utente potrebbe averla creata prima, con dentro
// link verso file da farci sovrascrivere.
if (!is_dir($state_dir) && !@mkdir($state_dir, 0700, true)) {
    fail(500, 'state dir non scrivibile');
}
clearstatcache();
if (is_link($state_dir) || !is_dir($state_dir)
    || (function_exists('posix_geteuid') && fileowner($state_dir) !== posix_geteuid())
    || (fileperms($state_dir) & 0077) !== 0) {
    fail(500, 'state dir non sicura');
}

// Da qui in poi una richiesta alla volta: dedup, contatori e creazione
// dell'issue sono letture-poi-scritture sullo stesso stato.
$lock = fopen("$state_dir/lock", 'c');
if ($lock === false || !flock($lock, LOCK_EX)) {
    fail(500, 'lock non disponibile');
}

// Firma del crash: prima riga senza epoch/indirizzi, così lo stesso panic
// non apre un issue per ogni avvio/macchina.
$sig_src = preg_replace('/\b\d+s\b|0x[0-9a-fA-F]+/', '', $lines[0]);
$sig = sha1($sig_src);
$sig_file = "$state_dir/sig-$sig";
if (is_file($sig_file) && !is_link($sig_file) && filemtime($sig_file) > time() - SIG_DAYS * 86400) {
    $known = json_decode((string)file_get_contents($sig_file), true);
    echo json_encode(['status' => 'duplicate', 'issue_url' => $known['issue_url'] ?? null]) . "\n";
    exit;
}

// Rate limit: un contatore per ora, uno per ora e indirizzo. Si scrivono solo
// per le richieste ACCETTATE: chi è oltre un tetto non lascia file né consuma
// la quota di tutti, quindi i contatori di un'ora sono al più MAX_PER_HOUR + 1.
// Quelli delle ore passate si buttano.
$hour = gmdate('YmdH');
foreach (array_merge(glob("$state_dir/hour-*") ?: [], glob("$state_dir/ip-*") ?: []) as $old) {
    if (!str_contains($old, "-$hour") && !is_link($old)) {
        @unlink($old);
    }
}
$ip_file = "$state_dir/ip-$hour-" . client_key($_SERVER['REMOTE_ADDR'] ?? '');
$hour_file = "$state_dir/hour-$hour";
$ip_count = counted($ip_file);
$hour_count = counted($hour_file);
if ($ip_count >= MAX_PER_HOUR_IP || $hour_count >= MAX_PER_HOUR) {
    fail(429, 'troppi report in quest\'ora');
}
file_put_contents($ip_file, (string)($ip_count + 1));
file_put_contents($hour_file, (string)($hour_count + 1));

// Coda del log a righe intere (mai una sequenza UTF-8 spezzata a metà).
$tail_lines = [];
$tail_len = 0;
foreach (array_reverse($lines) as $line) {
    $tail_len += strlen($line) + 1;
    if ($tail_len > BODY_TAIL && $tail_lines) {
        break;
    }
    array_unshift($tail_lines, $line);
}
// Dentro un blocco di codice GitHub non interpreta Markdown né menzioni; l'unico
// modo di uscirne è una sequenza di backtick, che qui non può esserci.
$tail = str_replace('`', "'", implode("\n", $tail_lines));
$title = 'crash zuer-gui: ' . str_replace(['`', '@'], ["'", '(at)'], substr($first_msg, 0, 90));
$body = "Report automatico dal crash log.\n\n"
    . "Piattaforma client: `$platform`\n\n"
    . "```\n$tail\n```\n";

$payload = json_encode([
    'title' => $title,
    'body' => $body,
    'labels' => ['crash'],
], JSON_INVALID_UTF8_SUBSTITUTE | JSON_UNESCAPED_UNICODE);
if ($payload === false) {
    fail(500, 'payload non codificabile');
}

if ($dry_run) {
    echo json_encode(['status' => 'dry_run', 'payload' => json_decode($payload, true)], JSON_UNESCAPED_UNICODE) . "\n";
    exit;
}

$token = trim((string)@file_get_contents($token_file));
if ($token === '') {
    fail(500, 'token GitHub non configurato');
}

$ch = curl_init('https://api.github.com/repos/' . REPO . '/issues');
curl_setopt_array($ch, [
    CURLOPT_POST => true,
    CURLOPT_POSTFIELDS => $payload,
    CURLOPT_RETURNTRANSFER => true,
    CURLOPT_TIMEOUT => 15,
    CURLOPT_HTTPHEADER => [
        'Accept: application/vnd.github+json',
        'Authorization: Bearer ' . $token,
        'Content-Type: application/json',
        'User-Agent: zuer-crash-report',
        'X-GitHub-Api-Version: 2022-11-28',
    ],
]);
$resp = curl_exec($ch);
$http = curl_getinfo($ch, CURLINFO_RESPONSE_CODE);
curl_close($ch);

if ($resp === false || $http !== 201) {
    fail(502, "GitHub API: HTTP $http");
}

$issue = json_decode($resp, true);
$issue_url = $issue['html_url'] ?? null;
file_put_contents($sig_file, json_encode(['issue_url' => $issue_url, 'at' => gmdate('c')]));

echo json_encode(['status' => 'created', 'issue_url' => $issue_url]) . "\n";
