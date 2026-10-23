# Keyboard/composer occlusion fix — 0.5.1/build 9

The user reported that focusing the bottom input leaves the transcript in place, allowing the keyboard and expanded composer to cover recent messages.

The previous follow logic reacted to transcript/token updates but did not explicitly re-anchor after viewport/safe-area changes. The native scroll view also has a top-anchored scroll-position binding, so the default size-change anchor was insufficient on its own.

The fix observes effective viewport height and bottom insets. If the user was following the conversation end, it re-anchors the existing end sentinel after the new viewport layout is applied (one main-actor yield, no guessed keyboard delay). It does not force scrolling while the user is scrolling/reading history or loading older messages. Native keyboard movement and interactive dismissal remain unchanged.

New UI regression cases check that the entire latest message frame remains above the composer after opening the keyboard and expanding to a four-line draft, and that opening the keyboard while reading older history does not jump to the latest message.

Only layout/follow behavior changed. No prompts/models/approval decisions, Mac/tunnel configuration or transcript data are mutated by validation. Release evidence and installation are recorded after tests complete.
