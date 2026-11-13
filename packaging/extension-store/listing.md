# nl-veil browser link: store listing material

Everything here is written from the code in `extension/` (manifest 0.2.1, `background.js`, `bridge.js`,
`popup.html`, `popup.js`). Nothing describes a feature the code does not have.

Upload package: `nl-veil-browser-link-0.2.1.zip` (built by `make-zip.py`; the contents of `extension/` with
`manifest.json` at the zip's root).

## Name

nl-veil browser link

## Category

Chrome Web Store: Developer Tools. Edge Add-ons: Developer tools.

## Short description (manifest `description`, 123 of 132 characters)

Lets a local nl-veil server, or the nl-veil web chat when you allow it, drive one tab in this browser with your own logins.

## Long description

nl-veil browser link connects nl-veil, the open-source agent app, to this browser, so the veil can open and work in
one tab of its own using your own profile and logins.

What it does
- It opens one tab of its own, pinned and in the background, and drives only that tab. It never takes over the tab you are reading.
- It drives that tab through the browser's debugger (the DevTools protocol), so clicks and typing behave like a person's.
- It holds no automation logic of its own: it passes the commands it is sent to its tab and sends back the replies, plus that tab's console messages and network requests.

Who can drive it
- A veil server running on your own computer. The extension looks for one on 127.0.0.1 (ports 8787, 8788, 8080 and 3000, or the port you type in the popup) and pairs with it. Pairing works only from the same machine.
- The nl-veil web chat at https://gary23w.github.io/nl-veil/chat/, only after you tick "Let the web chat drive a tab" in the popup. Unticking it closes the veil's tab.

The popup shows whether the link is connected, and has Connect, Pause, Disconnect and the web chat tick. Pausing or
disconnecting closes the veil's tab. Closing the tab yourself, or opening DevTools on it, ends the veil's hold on it.

The extension sends nothing to any server of the project's. It talks only to the veil on your own computer and to
the web chat page open in this browser.

Source: https://github.com/gary23w/nl-veil/tree/main/extension

## Single purpose

Let the nl-veil agent, running on the user's own computer or in the nl-veil web chat page, drive one browser tab that
the extension opens for it, using the user's own browser profile.

## Permission justifications

- `debugger`: the extension's whole job. It attaches the debugger to the one tab it opened itself and passes
  DevTools-protocol commands from the veil to that tab (`chrome.debugger.attach` / `sendCommand`, background.js
  `openTab` and `execute`), and collects that tab's console and network events for the veil (`chrome.debugger.onEvent`).
  Input sent this way is trusted input, which a content script cannot produce. It never attaches to any other tab.
- `storage`: keeps the paired port and token, the pause state and the "Let the web chat drive a tab" choice
  (`chrome.storage.local`), and the id of the veil's tab across service-worker restarts (`chrome.storage.session`).
- `alarms`: one 30-second alarm (`veil-poll`) restarts the connection loop to the local veil if the browser stopped the
  service worker; it is the only timer that survives that.
- Host permission `http://127.0.0.1/*`: the extension reaches the veil server on the user's own computer at
  `http://127.0.0.1:<port>/api/v1/browser/ext/...` (hello, pair, poll, result, bye). Nothing off the machine.
- Content script on `https://gary23w.github.io/nl-veil/chat/*` (`bridge.js`): the nl-veil web chat cannot reach the
  extension by itself. The script only relays `window.postMessage` messages between that page and the background worker,
  which refuses every command until the user has ticked the web chat box in the popup.
- Remote code: No. All code is in the package. The commands the extension relays are DevTools-protocol messages (data),
  sent to the veil's own tab; the extension never evaluates them itself.

The code opens and closes the veil's tab with `chrome.tabs.create` / `chrome.tabs.remove` and listens to
`chrome.tabs.onRemoved`; none of these needs the `tabs` permission, so the manifest does not ask for it.

## Data use (Chrome Web Store "Privacy practices" tab; Edge asks the same in prose)

What the code does with data:
- It reads what the veil asks for from the one tab it opened (page content through the commands it relays, plus that
  tab's console messages and network requests: URLs, status, headers as the DevTools protocol reports them) and hands
  it to whoever drives the tab: the veil server on 127.0.0.1, or the web chat page in the same browser.
- It stores locally only: the paired port and token, the pause flag, the web chat choice, and the veil tab's id.
- It sends nothing to the developer or any server of the project's. There is no analytics or telemetry.
- The web chat itself sends what it reads to the model and harness in the user's own Cloudflare account; that is the
  web chat's doing, covered by its own page.

Answers given:
- Data types handled: "Website content" (pages, console and network data of the veil's tab) and "Web history" (the
  addresses that tab visits and requests). Nothing else: no personal identifiers, health, financial, authentication
  information, personal communications, location or user activity outside the veil's tab are collected by the extension.
- Certifications (all true for this code): not sold to third parties; not used or transferred for purposes unrelated
  to the single purpose; not used or transferred to determine creditworthiness or for lending.

## Privacy policy address

https://gary23w.github.io/nl-veil/privacy.html

## Images

In `images/`:
- `store-icon-128.png`: 128x128 store icon (96x96 mark, 16 px transparent border, as the Chrome Web Store asks).
- `screenshot-1-1280x800.png`, `screenshot-2-1280x800.png` (and 640x400 copies; the repo's .gitignore keeps `screenshot*.png` out of git, so they are uploaded from a local copy): 1 is the real popup with the web chat
  box ticked; 2 is the web chat's "Your browser" panel showing the extension linked. Both were captured in a throwaway
  Chrome profile with this package loaded. For 2, the page only draws that panel after a Cloudflare login, so the
  harness state was stubbed in the page and the image is cropped to the panel alone; the panel's text and the
  "Linked (extension 0.2.1)" state are real.
- `small-promo-440x280.png`: the mark on the site background (Chrome small promo tile, Edge small tile).
- `store-logo-300x300.png`: Edge Add-ons store logo.
