# Screenshot walkthrough

The public `index.html` now uses an accessible image slideshow instead of the legacy video players.
It includes actual cropped Veil screenshots of setup, Cloudflare login, and the SignalDesk build rehearsal.
The login arrow is an HTML/CSS annotation over an actual signed-out Settings capture.
See `rehearsal.md` for the substantial project brief, presentation sequence and follow-up prompt.
Build screenshots exclude the account header, profile sidebar and console paths by hard cropping before publication.
The generated illustration experiment is not used in the public presentation.

## Legacy video assets

The files below remain for historical reference and are no longer embedded or linked by the demo page.

- `download-and-run.mp4`: 50-second Windows installation walkthrough.
- `cloudflare-ai.mp4`: 62-second Cloudflare Workers AI walkthrough.
- Each includes on-screen instructions, an English WebVTT caption track and a text transcript.
- These are edited screenshot tutorials with instructional cards, not continuous screen recordings.

## Evidence and privacy

The Windows v1.1.3 desktop ZIP was downloaded from the project's published release, extracted and
launched. Its SHA-256 matched the GitHub asset digest:
`805c02c95d390fa81ce18c3a5a06d0b536904b9b380e7b8009e39bc18351409a`.

App screenshots came from an empty, isolated demo profile. Public copies contain only cropped
content areas: account headers, machine details, personal paths and existing conversations are
excluded. Image metadata is stripped. Runtime folders and credentials are not part of this page.
The browser login and consent flow is omitted and explained with labeled instruction cards.
The tutorial does not claim a newly completed OAuth login.

The example reply was obtained on 19 September 2026 through the running Veil chat service and an
already connected Cloudflare account, using `@cf/meta/llama-3.3-70b-instruct-fp8-fast`. Its exact prompt:

> This is a public product tutorial. Do not use tools, memory, files or personal context. In one short friendly sentence, suggest a first project for someone learning to build software.

Exact reply:

> Why not start by building a simple to-do list app to get familiar with coding and see your progress come to life.

The reply is typeset in the video, with the shorter task portion of the prompt, to avoid recording
the connected account's UI. Cloudflare pricing was checked against its official pricing page on
the same date. This is a single observed reply, not a quality or speed benchmark.

## Build

`scripts/build-onboarding-demos.py` uses Pillow and FFmpeg. It takes a private input directory with
three explicitly reviewed screenshots (`desktop.png`, `cloudflare-login.png`, `chat.png`) and crops
them before copying pixels into public output. Original captures are not committed. Cropping
coordinates are specific to the reviewed 1220 × 820 capture; review new images before rebuilding.

All thirteen scene images were visually reviewed, and both videos were fully decoded with FFmpeg.
Browser inspection confirmed durations of 50 and 62 seconds and no media errors.

## Current desktop navigation

The screenshots above were captured on v1.1.3. In v1.1.4, provider setup and Cloudflare
login are under **Settings → Models**, and app updates are under **Settings → Updates**.
See the [desktop guide](../DESK-UI.md) for progress feedback, starter prompts, and code formatting.
