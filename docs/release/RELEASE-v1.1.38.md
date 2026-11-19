# the veil v1.1.38

NL-Veil Desk runs several chats at the same time.

- **Tools from different chats run together.** Desk used to run every chat's tools one after another, so one chat waiting in a two-minute `poll` held every other chat's `read_file` behind it. Now up to eight tools run at once, one per chat. Browser tools still take turns, because every chat drives the same browser.
- **Up to 64 chats keep working after you leave them.** It was three, and a finished chat kept its place until you opened it again.
- **No per-account limit on Desk.** One person on their own machine can use every turn the server runs (64 by default, `NL_MAX_TURNS`). A shared server keeps its per-account share, and `NL_MAX_TURNS_PER_USER` still sets it on either.
- **The built-in local model keeps its machine-sized limit.** It runs one to three chats at once, depending on memory and cores. When that limit or the server's turn limit is reached, the chat says so and your message stays yours to resend. Desk used to answer on its own engine instead, which held it to a single chat.
- **Pick the model in the chat.** The model name beside **Send** opens the same list as Settings. The next message is sent on the model you pick.
- **A chat and its sub-chats work as a family by default.** Each tab shows its status, a chat sees what its sub-chats found, and the two can message each other: a chat steers or asks a sub-chat with `message_subchat`, and a sub-chat answers with `report_to_primary`. Set `NL_FAMILY_VIEW`, `NL_FAMILY_STATUS`, `NL_FAMILY_NET` or `NL_FAMILY_MSG` to `0` to switch a piece off.

## Limits

- One chat still runs its own tools one at a time.
- Messaging is between a chat and its sub-chats (up to five). Two unrelated chats cannot message each other.
- The model picker lists the current provider's models. The choice applies to every chat, and a turn that is already running keeps the model it started with.
- Running tools together and the family defaults are covered by the test suites. They have not been measured on a long live session.

## Install or update

Use **Settings → Updates → App updates → Update & restart** in an existing portable installation, or choose your platform on the [download page](https://veil.garrettstimpson.ca/#get). The Desk and local web app update together. Website chat runs directly from the site.
