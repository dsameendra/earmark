# SCR-017: MeetingApp gains meet, discord and browser
Status: Applied (1.1.2).
Reason: Earmark 1.1.2 adds Google Meet and Discord, and lets the user pick any call that a browser is carrying (SCR-003 anticipated this).
Change: `MeetingApp` gains `meet`, `discord` and `browser`. `allCases` is now written out and lists only the apps Earmark watches by itself (`zoom, teams, meet, discord`); `browser` is manual only (chosen from Detect meetings), so no settings, policy or notification list shows it. `bundleIDs` returns `com.hnc.Discord` for Discord and no IDs for the browser cases. `MeetingPolicy.autoStopGraceSeconds` becomes an optional initialiser argument whose default is 15 s, or 30 s for Discord; the stored property is unchanged.
Persistence: raw values are strings, so existing data decodes. A build older than 1.1.2 cannot decode a meeting saved as `meet`, `discord` or `browser`: release notes say not to downgrade after recording one.
Impact: exhaustive switches over `MeetingApp` (titles, capture target, folder names) gained the new cases.
