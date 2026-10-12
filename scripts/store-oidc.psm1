# Every Store command gets a new GitHub assertion; no assertion is saved to disk.
Set-StrictMode -Version Latest

function Get-StoreOidcAssertion {
    if ([string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_URL) -or
        [string]::IsNullOrWhiteSpace($env:ACTIONS_ID_TOKEN_REQUEST_TOKEN)) {
        throw 'GitHub identity access is missing. This job needs id-token: write.'
    }
    $requestUri = [uri]$env:ACTIONS_ID_TOKEN_REQUEST_URL
    if ($requestUri.Scheme -ne 'https' -or
        -not $requestUri.Host.EndsWith('.actions.githubusercontent.com', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The GitHub identity endpoint is invalid.'
    }
    $separator = if ($requestUri.Query) { '&' } else { '?' }
    $tokenUri = $requestUri.AbsoluteUri + $separator + 'audience=' + [uri]::EscapeDataString('api://AzureADTokenExchange')
    try {
        $result = Invoke-RestMethod -Method Get -Uri $tokenUri -Headers @{
            Authorization = 'Bearer ' + $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN
        } -TimeoutSec 30 -ErrorAction Stop
    } catch {
        # Never include the response or authorization header in a diagnostic.
        throw 'GitHub could not issue the Store identity token.'
    }
    $assertion = [string]$result.value
    if ([string]::IsNullOrWhiteSpace($assertion) -or $assertion -match '[\r\n]') {
        throw 'GitHub returned an invalid Store identity token.'
    }
    try {
        $parts = $assertion.Split('.')
        if ($parts.Count -ne 3) { throw 'Invalid JWT' }
        $encoded = $parts[1].Replace('-', '+').Replace('_', '/')
        $encoded = $encoded.PadRight($encoded.Length + ((4 - $encoded.Length % 4) % 4), '=')
        $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($encoded)) | ConvertFrom-Json
        $expectedSubject = 'repo:gary23w@61893883/nl-veil@1280825877:environment:microsoft-store-publishing'
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        if ($claims.iss -ne 'https://token.actions.githubusercontent.com' -or
            $claims.aud -ne 'api://AzureADTokenExchange' -or
            $claims.sub -ne $expectedSubject -or
            [string]$claims.repository_id -ne '1280825877' -or
            [string]$claims.repository_owner_id -ne '61893883' -or
            $claims.repository -ne 'gary23w/nl-veil' -or
            $claims.environment -ne 'microsoft-store-publishing' -or
            $claims.ref -ne $env:GITHUB_REF -or
            $env:GITHUB_REPOSITORY -ne 'gary23w/nl-veil' -or
            $claims.ref -notmatch '^refs/(heads/main|tags/v[1-9][0-9]*\.[0-9]+\.[0-9]+)$' -or
            $claims.event_name -notin @('push', 'workflow_dispatch', 'schedule') -or
            [long]$claims.exp -le ($now + 30) -or [long]$claims.nbf -gt ($now + 30)) {
            throw 'Unexpected claims'
        }
    } catch {
        throw 'The Store identity token is expired or outside the approved repository, environment, or release refs.'
    }
    # Microsoft validates the signature and trust relationship during token exchange.
    return $assertion
}

function Invoke-MicrosoftStoreWithOidc {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Arguments)
    $previousAssertion = $env:MSSTORE_CLIENT_ASSERTION
    $previousFile = $env:MSSTORE_CLIENT_ASSERTION_FILE
    try {
        $assertion = Get-StoreOidcAssertion
        Write-Output ('::add-mask::' + $assertion)
        $env:MSSTORE_CLIENT_ASSERTION_FILE = $null
        $env:MSSTORE_CLIENT_ASSERTION = $assertion
        $LASTEXITCODE = 0
        & msstore @Arguments
        $exitCode = $LASTEXITCODE
        $global:LASTEXITCODE = $exitCode
        if ($exitCode -ne 0) { throw 'Microsoft Store command failed.' }
    } finally {
        $env:MSSTORE_CLIENT_ASSERTION = $previousAssertion
        $env:MSSTORE_CLIENT_ASSERTION_FILE = $previousFile
        $assertion = $null
    }
}

Export-ModuleMember -Function Invoke-MicrosoftStoreWithOidc
