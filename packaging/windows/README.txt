MICROSOFT STORE RELEASE

Route: x64 Win32 desktop in MSIX, uploaded to Partner Center. Microsoft
provides Store signing and delivery. A developer account and reserved app
identity are required to produce the final upload package.

1. Start at https://storedeveloper.microsoft.com/ and enroll. Choose the
   account type matching your publishing activity. Microsoft currently
   advertises free registration through this new onboarding flow. Complete
   identity/business verification yourself.
2. Partner Center > Apps and games > New product > MSIX or PWA app.
   Reserve the product name "nl-veil".
3. Product management > Product identity: copy the exact
   Package.Identity.Name, Package.Identity.Publisher and
   Package.Properties.PublisherDisplayName into store-identity.json, using
   store-identity.example.json as the starting point. Set displayName to the
   reserved name. The real identity file is ignored by Git.
4. Build the desktop app from current source into dist/windows-store/build.
   Example from the repository root (ZIG is the installed compiler path):
     & $env:ZIG build --prefix dist/windows-store/build
   Keep the default GUI, built-in inference and Vulkan options for release.
   Use a current Neuron engine built from the same pinned revision as the
   release workflow. Do not package an older portable app: the packaging
   script verifies MSIX runtime support before continuing.
5. With Windows SDK MakeAppx available, run:
     .\scripts\package-store.ps1
   Or pass -MakeAppxPath with the path to Microsoft's makeappx.exe.
   The Microsoft.Windows.SDK.BuildTools NuGet package also supplies this
   tool; preserve its DLLs and schemas next to the executable.
   Output: dist/windows-store/packages/nl-veil-<version>.0-x64.msix
   Build report: adjacent .msix.json, including component/package SHA256.
   No local databases, API keys, app config or model weights are included.
6. Sign a separate test copy for sideload testing. Do not distribute or
   trust a development certificate as a production signing identity. Run
   the Windows App Certification Kit and the clean-machine checks in
   certification-notes.txt. MakeAppx validates the package schema; it does
   not replace installed-app certification or hardware tests.
7. Review docs/privacy.html, publish it using the existing docs-site
   release process, and verify the public URL in store-listing.json.
   Capture at least one current desktop screenshot at 1366 x 768 or larger
   (four recommended). Use demo projects and omit keys/personal data.
   The staged Assets/ListingIcon.png is the optional 300 x 300 listing icon.
8. Start a submission. Use store-listing.json for listing text, choose
   pricing/markets, answer the IARC age-rating questionnaire, explain the
   runFullTrust capability using certification-notes.txt, upload the real
   identity MSIX and screenshots, and submit for certification.

LOCAL DEVELOPMENT PACKAGE
  .\scripts\package-store.ps1 -Development
  .\scripts\package-store.ps1 -Development -StageOnly
These use a clearly marked test identity and never qualify as a final Store
upload. StageOnly creates files without invoking MakeAppx. Package output is
never overwritten; use -OutputDirectory for another packaging attempt.
The script copies only explicitly listed release files. It does not scan
the workspace or dependency caches, and never signs or installs packages.

STORE RUNTIME
MSIX identity is detected using GetCurrentPackageFamilyName. Data defaults
to %LOCALAPPDATA%\Packages\<family>\LocalState\data. Main app/server CWD is
LocalState; CLI commands and workers keep their caller-provided CWD. The
NEURON_LOOPS_DATA environment override remains available. Portable installs
keep the existing data-next-to-app behavior and GitHub updater.
Portable data is not silently migrated; export/import it separately. Close
the portable app before launching the Store version to avoid port conflicts.

MICROSOFT REFERENCES (checked 2026-10-11)
https://learn.microsoft.com/en-us/windows/apps/publish/get-started
https://learn.microsoft.com/en-us/windows/apps/publish/partner-center/open-a-developer-account
https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/app-package-requirements
https://learn.microsoft.com/en-us/windows/apps/publish/publish-your-app/msix/screenshots-and-images

CI PACKAGING
The "Windows Store package" GitHub workflow builds and tests the app
and pinned Neuron engine, then uploads the unsigned MSIX as a reviewable
artifact. Set repository variables STORE_IDENTITY_NAME, STORE_PUBLISHER,
STORE_PUBLISHER_DISPLAY_NAME and STORE_DISPLAY_NAME to the reserved product's
exact values. STORE_DISPLAY_NAME is "nl-veil". The manual workflow defaults
to packaging only; its publish input also submits an update when enabled.

CONNECT MICROSOFT TO THE EXISTING GITHUB REPOSITORY
Repository: https://github.com/gary23w/nl-veil
Microsoft's submission automation needs an Entra tenant linked to Partner
Center, an Entra app registered as a Partner Center Manager, and an already
published Store product. The first app submission must establish the listing,
content rating and publication in Partner Center before automated updates.
Create the dedicated publisher application, then add these GitHub Actions
secrets using Settings > Secrets and variables > Actions:
  AZURE_AD_TENANT_ID
  AZURE_AD_APPLICATION_CLIENT_ID
  AZURE_AD_APPLICATION_SECRET
  SELLER_ID
Keep secret values out of source files and chat. Store them directly in
GitHub's secret fields. Add the product's Store ID as STORE_PRODUCT_ID and
set STORE_AUTOPUBLISH=true after the first Store version is live and the
connection is tested. The four package identity variables above are also
required; product ID and package identity name are different values.

After setup, pushing a stable vX.Y.Z tag runs the existing release workflow.
It tests/builds the cross-platform bundles and publishes the GitHub release.
Only after that job succeeds does the reusable Store workflow build/test an
MSIX at the same commit, check the version and package digest, and submit it
using Microsoft's official publishing action. Microsoft then certifies the
update and delivers it to Store users. Prereleases and ordinary main pushes
do not submit a Store update. Store submissions are serialized, with an
in-progress submission never cancelled by a newer run. Existing listing,
pricing and ratings are carried forward by the Microsoft CLI.

The docs site already publishes the repository's main/docs directory through
GitHub Pages. Merging docs/privacy.html makes its privacy URL available there.
Monitor workflow results in GitHub Actions and certification in Partner
Center; a workflow failure or certification rejection is not a published app.
https://learn.microsoft.com/en-us/windows/apps/publish/msstore-dev-cli/github-actions

AUTOMATIC CREDENTIAL REFRESH (GITHUB IDENTITY)
Microsoft Store CLI v0.4.3 supports --clientAssertion and the
MSSTORE_CLIENT_ASSERTION environment variable. The Store workflows use
scripts/store-oidc.psm1 to request a fresh GitHub assertion immediately
before each command, mask it in logs, and clear it after the command.
No expiring client secret is needed when STORE_AUTH_MODE=oidc.

One-time setup for the existing nl-veil GitHub publisher Entra application:
  Issuer: https://token.actions.githubusercontent.com
  Audience: api://AzureADTokenExchange
  Subject: repo:gary23w@61893883/nl-veil@1280825877:environment:microsoft-store-publishing
Create this exact federated credential using the Other issuer scenario.
The immutable owner/repository IDs match the repository's existing OIDC
configuration. Keep the existing Partner Center Manager role. No new Graph
permissions or Azure subscription are needed.

Create GitHub environment microsoft-store-publishing with selected deployment
branches/tags: branch main and tags v*.*.*. Do not add PR refs, other branches,
or wildcard branches. The helper independently rejects PRs and prereleases.
The reusable release caller must grant id-token: write, as does its Store
publishing job. Packaging and pull-request tests do not receive tokens.

First run Microsoft Store connection on main with use_oidc=true. Only after
it succeeds, set STORE_AUTH_MODE=oidc, run it again with the default inputs,
and retire AZURE_AD_APPLICATION_SECRET and its original Entra client secret.
Keep the tenant ID, client ID, and seller ID secrets, plus product variables.
The connection workflow checks access weekly and can also be run manually;
it never changes a Store submission. GitHub's usual workflow failure
notifications apply. Publishing no longer depends on a scheduled rotation
or a stored token expiry; each release obtains its own short-lived identity.

Tests: ./scripts/test-store-oidc.ps1 (mocked network and Store command).
Live verification: Microsoft Store connection, use_oidc=true (no submission).
https://github.com/microsoft/msstore-cli/blob/v0.4.3/MSStore.CLI/Commands/ReconfigureCommand.cs
https://github.com/microsoft/msstore-cli/blob/v0.4.3/MSStore.CLI/Services/EnvironmentInfo.cs
https://docs.github.com/en/actions/reference/security/oidc
https://learn.microsoft.com/en-us/entra/workload-id/workload-identity-federation-create-trust
