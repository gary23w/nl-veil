$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'store-oidc.psm1') -Force
$storeModule = Get-Module store-oidc
$saved = @{}
foreach ($name in @('ACTIONS_ID_TOKEN_REQUEST_URL','ACTIONS_ID_TOKEN_REQUEST_TOKEN','GITHUB_REF','GITHUB_REPOSITORY','MSSTORE_CLIENT_ASSERTION','MSSTORE_CLIENT_ASSERTION_FILE')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name)
}
function Assert-StoreTest($condition, $message) { if (-not $condition) { throw $message } }
try {
    $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://vstoken.actions.githubusercontent.com/example/idtoken?api-version=2.0'
    $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'fixture-request-token'
    $env:GITHUB_REF = 'refs/heads/main'
    $env:GITHUB_REPOSITORY = 'gary23w/nl-veil'
    $env:MSSTORE_CLIENT_ASSERTION = 'previous-assertion'
    $env:MSSTORE_CLIENT_ASSERTION_FILE = 'previous-file'
    & $storeModule {
        $script:testRequests = 0
        $script:testCalls = [Collections.Generic.List[string]]::new()
        $script:testOverride = @{}
        $script:testCliThrows = $false
        function script:Invoke-RestMethod {
            param($Method, $Uri, $Headers, $TimeoutSec, $ErrorAction)
            if ($Uri -notmatch 'audience=api%3A%2F%2FAzureADTokenExchange$') { throw 'Wrong audience' }
            $script:testRequests++
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $claims = @{
                iss='https://token.actions.githubusercontent.com'; aud='api://AzureADTokenExchange'
                sub='repo:gary23w@61893883/nl-veil@1280825877:environment:microsoft-store-publishing'
                repository_id='1280825877'; repository_owner_id='61893883'; repository='gary23w/nl-veil'
                environment='microsoft-store-publishing'; ref=$env:GITHUB_REF
                event_name='workflow_dispatch'; exp=$now+300; nbf=$now-5; jti=$script:testRequests
            }
            foreach ($key in $script:testOverride.Keys) { $claims[$key] = $script:testOverride[$key] }
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($claims | ConvertTo-Json -Compress))).TrimEnd('=').Replace('+','-').Replace('/','_')
            return @{ value = 'fixture.' + $payload + '.signature' }
        }
        function script:msstore {
            if ($env:MSSTORE_CLIENT_ASSERTION_FILE) { throw 'Assertion file was not cleared' }
            $script:testCalls.Add($env:MSSTORE_CLIENT_ASSERTION)
            if ($script:testCliThrows) { throw 'CLI fixture failure' }
        }
    }
    Invoke-MicrosoftStoreWithOidc -Arguments @('apps','get','fixture-product') | Out-Null
    Invoke-MicrosoftStoreWithOidc -Arguments @('submission','status','fixture-product') | Out-Null
    $snapshot = & $storeModule { @{requests=$script:testRequests; calls=$script:testCalls.ToArray()} }
    Assert-StoreTest ($snapshot.requests -eq 2 -and $snapshot.calls.Count -eq 2 -and $snapshot.calls[0] -ne $snapshot.calls[1]) 'Store commands did not receive fresh, separate assertions.'
    Assert-StoreTest ($env:MSSTORE_CLIENT_ASSERTION -eq 'previous-assertion' -and $env:MSSTORE_CLIENT_ASSERTION_FILE -eq 'previous-file') 'Assertions remained in the environment after success.'
    foreach ($override in @(
        @{repository_id='other-repository'}, @{sub='repo:someone/else:environment:microsoft-store-publishing'},
        @{exp=1}, @{event_name='pull_request'}, @{environment='unprotected'}
    )) {
        & $storeModule { param($override) $script:testOverride=$override } $override
        $failed=$false
        try { Invoke-MicrosoftStoreWithOidc -Arguments @('apps','get','fixture-product') | Out-Null } catch { $failed=$true }
        Assert-StoreTest $failed 'An expired or unauthorized identity reached the Store command.'
    }
    & $storeModule { $script:testOverride=@{} }
    $env:GITHUB_REF='refs/pull/1/merge'
    $failed=$false
    try { Invoke-MicrosoftStoreWithOidc -Arguments @('apps','get','fixture-product') | Out-Null } catch { $failed=$true }
    Assert-StoreTest $failed 'A pull request ref was accepted.'
    $env:GITHUB_REF='refs/tags/v1.2.3'
    Invoke-MicrosoftStoreWithOidc -Arguments @('apps','get','fixture-product') | Out-Null
    $env:GITHUB_REF='refs/tags/v1.2.3-beta'
    $failed=$false
    try { Invoke-MicrosoftStoreWithOidc -Arguments @('apps','get','fixture-product') | Out-Null } catch { $failed=$true }
    Assert-StoreTest $failed 'A prerelease ref was accepted.'
    $env:GITHUB_REF='refs/heads/main'
    $env:ACTIONS_ID_TOKEN_REQUEST_URL='https://example.com/idtoken'
    $failed=$false
    try { Invoke-MicrosoftStoreWithOidc -Arguments @('apps','get','fixture-product') | Out-Null } catch { $failed=$true }
    Assert-StoreTest $failed 'A non-GitHub token endpoint was accepted.'
    $env:ACTIONS_ID_TOKEN_REQUEST_URL='https://vstoken.actions.githubusercontent.com/example/idtoken?api-version=2.0'
    & $storeModule { $script:testCliThrows=$true }
    $failed=$false
    try { Invoke-MicrosoftStoreWithOidc -Arguments @('apps','get','fixture-product') | Out-Null } catch { $failed=$true }
    Assert-StoreTest $failed 'CLI failures were swallowed.'
    Assert-StoreTest ($env:MSSTORE_CLIENT_ASSERTION -eq 'previous-assertion' -and $env:MSSTORE_CLIENT_ASSERTION_FILE -eq 'previous-file') 'Assertions remained in the environment after failure.'
    Write-Output 'Store identity tests passed: per-command refresh, expiry, repository/environment/ref restrictions, and cleanup.'
} finally {
    foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name,$saved[$name]) }
    Remove-Module store-oidc
}
