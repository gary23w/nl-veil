# Desktop updates and Cloudflare connectivity

In v1.1.3, use Settings → App updates; v1.1.4 groups it on the Updates page.

Starting with **v1.1.3**, official desktop bundles check GitHub for stable releases at startup.
Choose **Settings → Updates → App updates → Update & restart** after finishing active work. Git is not required.
The app verifies downloads, stages both native components, keeps backups and restarts without replacing
your data. Install v1.1.4 (or another current full bundle) manually once if you are coming from an older version.

Keep the complete bundle in a writable folder, including `veil-install.txt` and the memory engine in
`bin/`. Windows/macOS supply the curl executable used for HTTPS; Linux needs curl installed. Source
checkouts and the standalone development `veil-desk` executable do not self-update.

Cloudflare Tunnel connects outbound on **UDP 7844 (QUIC)** or **TCP 7844 (HTTP/2)**. An assigned hostname
alone does not prove that connection succeeded. Check `cf_tunnel.log` if the app reports a timeout.
Corporate firewall, VPN and endpoint policies may need an exception for the actual `cloudflared`
executable. No blanket inbound exception or router port-forward is required.

OS approval of an unsigned executable is separate from networking. This release does not add signing
or notarization and does not bypass those protections.

The [full update and recovery guide](https://github.com/gary23w/nl-veil/blob/main/docs/UPDATES.md)
documents the asset contract, preserved data, backup recovery, network destinations and test limits.
The [updater source sheet](#doc=desk/updater) describes the implementation.
