<?php
/**
 * Receiver dei crash report di zuer-gui → issue GitHub.
 *
 * Il client (src/crash_report.zig) POSTa il crash.log come text/plain al
 * prossimo avvio dopo un panic. Questo script:
 *   1. valida (POST, dimensione, non vuoto);
 *   2. deduplica per firma (prima riga senza timestamp/indirizzi);
 *   3. limita la frequenza (max N issue/ora);
 *   4. crea l'issue su GitHub col token letto DA FILE server-side
 *      (mai nel binario distribuito).
 *
 * Deploy: copia questo file nella docroot e accanto (o in TOKEN_FILE) metti
 * il token in un file 0600 leggibile dall'utente PHP. Consigliato un
 * fine-grained PAT limitato a "Issues: Read and write" sul solo repo Zuer.
 */

const REPO = 'postadelmaga/Zuer';
const MAX_BODY = 64 * 1024;        // dimensione massima del log accettato
const MAX_PER_HOUR = 6;            // tetto issue/ora (client impazzito)
const BODY_TAIL = 6000;            // coda del log inclusa nell'issue

// Il token si cerca in: $ZUER_CRASH_TOKEN_FILE, poi accanto allo script.
$token_file = getenv('ZUER_CRASH_TOKEN_FILE') ?: __DIR__ . '/zuer-crash-token';
// Stato (dedup + rate limit): dir scrivibile dall'utente PHP.
$state_dir = getenv('ZUER_CRASH_STATE_DIR') ?: sys_get_temp_dir() . '/zuer-crash-state';

header('Content-Type: application/json');

function fail(int $code, string $msg): never
{
    http_response_code($code);
    echo json_encode(['status' => 'error', 'error' => $msg]) . "\n";
    exit;
}

if (($_SERVER['REQUEST_METHOD'] ?? '') !== 'POST') {
    fail(405, 'POST only');
}

$log = file_get_contents('php://input', false, null, 0, MAX_BODY + 1);
if ($log === false || strlen($log) > MAX_BODY) {
    fail(413, 'log troppo grande');
}
$log = trim($log);
if ($log === '') {
    fail(400, 'log vuoto');
}
// Solo testo: byte di controllo (salvo \n\t) = non è un nostro crash log.
if (preg_match('/[\x00-\x08\x0B\x0C\x0E-\x1F]/', $log)) {
    fail(400, 'contenuto non testuale');
}

$platform = substr(preg_replace('/[^\w.,: -]/', '', $_SERVER['HTTP_X_ZUER_PLATFORM'] ?? 'sconosciuta'), 0, 80);

if (!is_dir($state_dir) && !mkdir($state_dir, 0700, true)) {
    fail(500, 'state dir non scrivibile');
}

// Firma del crash: prima riga senza epoch/indirizzi, così lo stesso panic
// non apre un issue per ogni avvio/macchina.
$first_line = strtok($log, "\n");
$sig_src = preg_replace('/\b\d+s\b|0x[0-9a-fA-F]+/', '', $first_line);
$sig = sha1($sig_src);
$sig_file = "$state_dir/sig-$sig";
if (file_exists($sig_file)) {
    $known = json_decode((string)file_get_contents($sig_file), true);
    echo json_encode(['status' => 'duplicate', 'issue_url' => $known['issue_url'] ?? null]) . "\n";
    exit;
}

// Rate limit: marker orario.
$hour_file = "$state_dir/hour-" . gmdate('YmdH');
$count = (int)@file_get_contents($hour_file);
if ($count >= MAX_PER_HOUR) {
    fail(429, 'troppi report in quest\'ora');
}
file_put_contents($hour_file, (string)($count + 1));

$token = trim((string)@file_get_contents($token_file));
if ($token === '') {
    fail(500, 'token GitHub non configurato');
}

$tail = strlen($log) > BODY_TAIL ? substr($log, -BODY_TAIL) : $log;
$title = 'crash zuer-gui: ' . substr($first_line, 0, 90);
$body = "Report automatico dal crash log.\n\n"
    . "Piattaforma client: `$platform`\n\n"
    . "```\n$tail\n```\n";

$payload = json_encode([
    'title' => $title,
    'body' => $body,
    'labels' => ['crash'],
]);

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
