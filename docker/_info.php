<?php
// lucos /_info for Kanka (#4). Served only via nginx's exact `location = /_info`; reads nothing from the request.
declare(strict_types=1);

const AUTH_GATE_URL = 'http://lucos_campaigns_auth:4180/oauth2/auth';
const HTTP_TIMEOUT_MS = 300;

function check(bool $ok, string $techDetail, ?string $debug = null): array
{
	$check = ['ok' => $ok, 'techDetail' => $techDetail];
	if (!$ok && $debug !== null) {
		$check['debug'] = $debug;
	}
	return $check;
}

// Only the exception class is exposed (the endpoint is public); the full message goes to the log.
function failure(string $name, \Throwable $e): string
{
	error_log("lucos_campaigns /_info: $name check failed: " . get_class($e) . ': ' . $e->getMessage());
	return get_class($e);
}

// Runs the given GET requests in parallel; returns [name => [status, body, curl error]].
function parallelGet(array $urls): array
{
	$multi = curl_multi_init();
	$handles = [];
	foreach ($urls as $name => $url) {
		$handle = curl_init($url);
		curl_setopt_array($handle, [
			CURLOPT_RETURNTRANSFER => true,
			CURLOPT_TIMEOUT_MS => HTTP_TIMEOUT_MS,
			CURLOPT_CONNECTTIMEOUT_MS => HTTP_TIMEOUT_MS,
			CURLOPT_FOLLOWLOCATION => false,
			CURLOPT_NOSIGNAL => true,
		]);
		curl_multi_add_handle($multi, $handle);
		$handles[$name] = $handle;
	}
	do {
		$status = curl_multi_exec($multi, $running);
		if ($running) {
			curl_multi_select($multi, 0.05);
		}
	} while ($running && $status === CURLM_OK);
	$results = [];
	foreach ($handles as $name => $handle) {
		$results[$name] = [
			curl_getinfo($handle, CURLINFO_RESPONSE_CODE),
			(string) curl_multi_getcontent($handle),
			curl_error($handle),
		];
		curl_multi_remove_handle($multi, $handle);
	}
	curl_multi_close($multi);
	return $results;
}

$checks = [];
$app = null;
try {
	// A failed require is a fatal error, not an exception, so check first.
	foreach (['vendor/autoload.php', 'bootstrap/app.php'] as $file) {
		if (!is_file(__DIR__ . "/../$file")) {
			throw new \RuntimeException("missing $file");
		}
	}
	require __DIR__ . '/../vendor/autoload.php';
	$app = require __DIR__ . '/../bootstrap/app.php';
	// Kernel::handle() binds the request before bootstrapping; bind a fixed one, never the real request.
	$app->instance('request', Illuminate\Http\Request::create('/_info', 'GET'));
	$app->make(Illuminate\Contracts\Http\Kernel::class)->bootstrap();
	$checks['app'] = check(true, 'Whether Kanka\'s Laravel application boots');
} catch (\Throwable $e) {
	$checks['app'] = check(false, 'Whether Kanka\'s Laravel application boots', failure('app', $e));
	$app = null;
}

$searchHost = null;
if ($app !== null) {
	try {
		$config = $app['config'];
		$connection = $config->get('database.default');
		// mysqlnd's default connect timeout is 60s; 1s is the lowest PDO allows.
		$config->set("database.connections.$connection.options." . \PDO::ATTR_TIMEOUT, 1);
		$app['db']->connection()->select('select 1');
		$checks['database'] = check(true, 'Whether MariaDB answers a query on Laravel\'s configured connection');
	} catch (\Throwable $e) {
		$checks['database'] = check(false, 'Whether MariaDB answers a query on Laravel\'s configured connection', failure('database', $e));
	}
	try {
		$searchHost = rtrim((string) $app['config']->get('scout.meilisearch.host'), '/');
	} catch (\Throwable $e) {
		$checks['search'] = check(false, 'Whether Meilisearch reports itself available', failure('search', $e));
	}
} else {
	$checks['database'] = check(false, 'Whether MariaDB answers a query on Laravel\'s configured connection', 'not checked: app failed to boot');
	$checks['search'] = check(false, 'Whether Meilisearch reports itself available', 'not checked: app failed to boot');
}

$urls = ['auth-gate' => AUTH_GATE_URL];
if ($searchHost) {
	$urls['search'] = "$searchHost/health";
}
try {
	$responses = parallelGet($urls);
} catch (\Throwable $e) {
	$responses = [];
	failure('http', $e);
}

if ($searchHost) {
	[$code, $body, $error] = $responses['search'] ?? [0, '', 'not run'];
	$health = json_decode($body, true);
	$ok = $code === 200 && is_array($health) && ($health['status'] ?? null) === 'available';
	$checks['search'] = check($ok, 'Whether Meilisearch reports itself available', $error !== '' ? 'request failed' : "HTTP $code");
}

[$code, , $error] = $responses['auth-gate'] ?? [0, '', 'not run'];
$checks['auth-gate'] = check(
	$code === 401,
	'Whether the oauth2-proxy sidecar answers auth checks (expects 401 for a request with no cookie)',
	$error !== '' ? 'request failed' : "HTTP $code",
);

$version = getenv('VERSION');
$info = [
	'system' => getenv('SYSTEM') ?: 'lucos_campaigns',
	'checks' => $checks,
	'metrics' => new \stdClass(),
	'ci' => ['circle' => 'gh/lucas42/lucos_campaigns'],
	'title' => 'Campaigns',
	'icon' => '/favicon.ico',
	'show_on_homepage' => true,
	'network_only' => true,
	'start_url' => '/',
];
if ($version !== false && $version !== '') {
	$info['version'] = $version;
}

http_response_code(200);
header('Content-Type: application/json');
header('Cache-Control: no-store');
echo json_encode($info, JSON_UNESCAPED_SLASHES);
