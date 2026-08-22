<#
	Server-side chat debugger.

	This is intentionally a thin client of the same chat API used by the web and desktop clients. The
	event stream is the server's observable execution trace: it includes planning/reasoning, model calls,
	tool activity, policy/status decisions, the visible answer, usage, errors, and the terminal done frame.
#>
param(
	[string]$ServerUrl = "http://127.0.0.1:8787"
)

$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDir = Join-Path $repo "data"
$keyPath = Join-Path $dataDir ".desktop_key"

function Get-AuthHeaders {
	if (-not (Test-Path -LiteralPath $keyPath)) {
		throw "No server key found at $keyPath. Start the server first so it can mint data\.desktop_key."
	}
	$token = (Get-Content -LiteralPath $keyPath -Raw).Trim()
	if ([string]::IsNullOrWhiteSpace($token)) { throw "The server key is empty: $keyPath" }
	return @{ Authorization = "Bearer $token" }
}

function Invoke-Veil {
	param(
		[ValidateSet("GET", "POST")][string]$Method,
		[string]$Path,
		[object]$Body = $null,
		[int]$TimeoutSec = 30
	)
	$params = @{
		Uri = "$ServerUrl$Path"
		Method = $Method
		Headers = Get-AuthHeaders
		TimeoutSec = $TimeoutSec
		UseBasicParsing = $true
	}
	if ($null -ne $Body) {
		$params.ContentType = "application/json"
		$params.Body = ($Body | ConvertTo-Json -Depth 20 -Compress)
	}
	return Invoke-WebRequest @params
}

function Get-JsonResponse {
	param([Microsoft.PowerShell.Commands.WebResponseObject]$Response)
	if ([string]::IsNullOrWhiteSpace($Response.Content)) { return $null }
	return $Response.Content | ConvertFrom-Json
}

function Get-ProviderBaseUrl {
	param($Catalog, [string]$ProviderKey)
	$provider = @($Catalog.providers) | Where-Object { $_.key -eq $ProviderKey } | Select-Object -First 1
	if ($null -eq $provider) { return "" }
	switch ($provider.base_url) {
		"local" { return "http://127.0.0.1:11434/v1" }
		"cloudflare" { return "" }
		default { return [string]$provider.base_url }
	}
}

function Get-DisplayValue {
	param($Value)
	if ($null -eq $Value) { return "" }
	return ([string]$Value).Replace("`r", " ").Replace("`n", " ").Trim()
}

function Read-ApiKey {
	$secure = Read-Host "API key (input is hidden; press Enter to use the server vault)" -AsSecureString
	$ptr = [IntPtr]::Zero
	try {
		$ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
		return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
	} finally {
		if ($ptr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr) }
	}
}

function Write-TraceEvent {
	param($Event, [System.Text.StringBuilder]$Answer)
	$kind = [string]$Event.kind
	switch ($kind) {
		"status" {
			Write-Host ("  [STATUS] " + (Get-DisplayValue $Event.text)) -ForegroundColor DarkCyan
		}
		"reasoning" {
			Write-Host ("  [REASONING] " + (Get-DisplayValue $Event.delta)) -ForegroundColor DarkYellow
		}
		"token" {
			$delta = [string]$Event.delta
			[void]$Answer.Append($delta)
			Write-Host $delta -NoNewline -ForegroundColor White
		}
		"message" {
			if ([string]$Event.role -eq "assistant" -and [string]$Event.content) {
				Write-Host ("  [MESSAGE/assistant] " + (Get-DisplayValue $Event.content)) -ForegroundColor White
				# authoritative: replaces whatever the token deltas accumulated, rather than adding to it
				[void]$Answer.Clear()
				[void]$Answer.Append([string]$Event.content)
			}
		}
		"llm" {
			$ok = if ($null -eq $Event.ok) { "?" } else { [string]$Event.ok }
			Write-Host ("  [LLM] role={0} label={1} model={2} ok={3} total={4}ms first-byte={5}ms in={6} out={7}" -f `
				$Event.role, $Event.label, $Event.model, $ok, $Event.ms, $Event.fb_ms, $Event.in, $Event.out) -ForegroundColor DarkGreen
		}
		"trace" {
			$timing = if ($null -ne $Event.ms) { " duration=$($Event.ms)ms" } else { "" }
			$marker = if ([string]$Event.phase -eq "enter") { ">>" } else { "<<" }
			Write-Host ("  [TRACE] {0} {1}.{2}{3}" -f $marker, $Event.module, $Event.function, $timing) -ForegroundColor DarkBlue
		}
		"tool" {
			$copy = $Event | ConvertTo-Json -Depth 20 -Compress
			$copy = $copy -replace '(?i)("(?:api[_-]?key|authorization|bearer|token|password|secret)"\s*:\s*)"[^"]*"', '$1"[REDACTED]"'
			Write-Host ("  [TOOL] " + $copy) -ForegroundColor DarkMagenta
		}
		"usage" {
			Write-Host ("  [USAGE] " + (Get-DisplayValue $Event.text)) -ForegroundColor DarkGreen
		}
		"error" {
			Write-Host ("  [ERROR] " + (Get-DisplayValue $Event.err)) -ForegroundColor Red
		}
		"done" { }
		default {
			$copy = $Event | ConvertTo-Json -Depth 20 -Compress
			Write-Host ("  [" + $kind.ToUpperInvariant() + "] " + $copy) -ForegroundColor Gray
		}
	}
}

# events.jsonl is APPEND-ONLY PER CONVERSATION, so the read offset has to survive across turns. It used to be
# reset to 0 on every call: from turn 2 onward this re-read the whole history, hit turn 1's {done} on the first
# poll, and returned turn 1's answer as if it were the new one. Every multi-turn debug session was reading a
# replay of its own first turn.
$script:EventOffset = 0L
function Watch-Turn {
	param([string]$ConversationId)
	$offset = $script:EventOffset
	$answer = New-Object System.Text.StringBuilder
	$done = $false
	while (-not $done) {
		try {
			$response = Invoke-Veil -Method GET -Path "/api/v1/chat/convs/$ConversationId/events?from=$offset" -TimeoutSec 10
		} catch {
			Write-Host ("`n  [TRACE ERROR] " + $_.Exception.Message) -ForegroundColor Red
			break
		}
		$next = $response.Headers["X-Next-Offset"]
		if ($next) { $offset = [int64]$next }
		foreach ($line in ($response.Content -split "`n")) {
			$trimmed = $line.Trim()
			if (-not $trimmed) { continue }
			try {
				$event = $trimmed | ConvertFrom-Json
				Write-TraceEvent -Event $event -Answer $answer
				if ([string]$event.kind -eq "done") { $done = $true }
			} catch {
				Write-Host ("  [RAW EVENT] " + $trimmed) -ForegroundColor Gray
			}
		}
		if (-not $done) { Start-Sleep -Milliseconds 250 }
	}
	$script:EventOffset = $offset
	Write-Host ""
	return $answer.ToString()
}

try {
	$headers = Get-AuthHeaders
	$catalogResponse = Invoke-WebRequest -Uri "$ServerUrl/models.json" -Method GET -TimeoutSec 10 -UseBasicParsing
	$catalog = $catalogResponse.Content | ConvertFrom-Json
	$models = @($catalog.models)
	if ($models.Count -eq 0) { throw "The server returned an empty model catalog." }
} catch {
	Write-Host ("Unable to initialize debugger: " + $_.Exception.Message) -ForegroundColor Red
	exit 1
}

Write-Host "VEIL SERVER CHAT DEBUGGER" -ForegroundColor Cyan
Write-Host ("Server: " + $ServerUrl)
Write-Host "The list below is loaded once. Each turn will stream the server's observable execution trace."
Write-Host ""
for ($i = 0; $i -lt $models.Count; $i++) {
	$model = $models[$i]
	Write-Host ("[{0,3}] {1}  ({2}, {3})" -f ($i + 1), $model.label, $model.id, $model.provider)
}

do {
	$selection = Read-Host ("Choose a model [1-$($models.Count)]")
	$number = 0
	$valid = [int]::TryParse($selection, [ref]$number) -and $number -ge 1 -and $number -le $models.Count
	if (-not $valid) { Write-Host "Enter one of the numbers shown above." -ForegroundColor Yellow }
} while (-not $valid)

$chosen = $models[$number - 1]
$baseUrl = Get-ProviderBaseUrl -Catalog $catalog -ProviderKey ([string]$chosen.provider)
if ([string]$chosen.provider -eq "builtin") { $baseUrl = "builtin" }
$apiKey = Read-ApiKey
$conversationId = "debug-" + ([guid]::NewGuid().ToString("N").Substring(0, 12))

Write-Host ""
Write-Host ("Selected: {0} [{1}]" -f $chosen.label, $chosen.id) -ForegroundColor Green
Write-Host ("Conversation: " + $conversationId)
Write-Host "Commands: /quit exits, /new starts a fresh context, /fast skips advanced reasoning passes."

while ($true) {
	$inputText = Read-Host "`nYou"
	if ($null -eq $inputText) { break }
	$inputText = $inputText.Trim()
	if (-not $inputText) { continue }
	if ($inputText -in @("/quit", "/exit")) { break }
	if ($inputText -eq "/new") {
		$conversationId = "debug-" + ([guid]::NewGuid().ToString("N").Substring(0, 12))
		$script:EventOffset = 0L   # a fresh conversation has a fresh (empty) event log
		Write-Host ("New conversation: " + $conversationId) -ForegroundColor Green
		continue
	}
	$fast = $false
	if ($inputText -eq "/fast") {
		$inputText = Read-Host "You (fast mode prompt)"
		$fast = $true
	}
	if ([string]::IsNullOrWhiteSpace($inputText)) { continue }

	$body = @{
		text = $inputText
		base_url = $baseUrl
		model = [string]$chosen.id
		api_key = $apiKey
		loop = 0
		tool_client = $false
		fast = $fast
		trace = $true
	}
	try {
		$sent = Invoke-Veil -Method POST -Path "/api/v1/chat/convs/$conversationId/messages" -Body $body -TimeoutSec 30
		if ($sent.StatusCode -ne 200 -and $sent.StatusCode -ne 201 -and $sent.StatusCode -ne 202) {
			throw "Server rejected turn with HTTP $($sent.StatusCode): $($sent.Content)"
		}
		Write-Host "`n--- backend trace ---" -ForegroundColor Cyan
		$answer = Watch-Turn -ConversationId $conversationId
		Write-Host "--- end trace ---" -ForegroundColor Cyan
		if ($answer) { Write-Host ("`nAnswer: " + $answer) -ForegroundColor White }
	} catch {
		Write-Host ("Turn failed: " + $_.Exception.Message) -ForegroundColor Red
	}
}

Write-Host "Debugger closed." -ForegroundColor Cyan
