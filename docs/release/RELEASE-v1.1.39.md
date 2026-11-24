# the veil v1.1.39

When a provider declines a request, the chat keeps working toward its goal instead of ending with an empty reply.

- **A declined request is recognised.** A provider's safety filter can decline a request and send back nothing (`finish_reason` `content_filter`). The chat used to read that as an empty reply: it sent the same request again, re-asked it, and ended the turn with "(no reply — the model returned an empty or malformed response this turn)". Now a declined call is sent once and never repeated.
- **The chat finishes the task another way.** The step the provider would not continue from is set aside. It leaves the conversation the model sees, a short note says which step was set aside, and the chat carries on toward its goal from what it had already established.
- **A declined step stays out of later requests.** Later turns show it only as a ruled-out call, by tool name, without its output. Its results are also taken out of the chat's recall and memory, so the next turn does not open on the content that was declined.
- **An honest end when nothing else is left.** If the provider still declines once all of the turn's own work is set aside, the turn ends with a note that says the provider declined it.

## Limits

- Declines are recognised when the provider reports `content_filter`, or answers with a refusal and nothing else.
- In a long turn, results that an earlier step had already saved to memory stay there.
- Chats whose declined turns happened before this release have no record of them. In such a chat, a request that is declined at the very start of a turn ends that turn.
- Covered by the test suites and a scripted run against a stand-in provider. Not yet measured against a live provider.

## Install or update

Use **Settings → Updates → App updates → Update & restart** in an existing portable installation, or choose your platform on the [download page](https://veil.garrettstimpson.ca/#get). The Desk and local web app update together. Website chat runs directly from the site.
