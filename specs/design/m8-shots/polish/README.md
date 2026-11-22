# M8 real-app refinement screenshots

Fifty screenshots of implementation `b17595c` from the deterministic native UI host on macOS 27.2.1 / Xcode 27.2. These supersede the earlier `completion/` screenshots for current visual review. The local [final-v1 boards](../../m8-mockups/README.md) remain the design reference, with the owner's refinements recorded in [SCR-007](../../../changes/SCR-007-cohesive-ui-refinement.md).

`manifest.json` records each image's test, timestamp and result bundle. Captures cover light/dark main routes and editor/export, expanded workspaces, compact editor, all fifteen Settings sections, five onboarding steps, six queue states, reduced accessibility policy rendering and the menu-bar panel. Mock content and a silent local playback fixture keep the user's library and capture permissions untouched.

Review starting points:

- [Expanded Home](home-dark-expanded.png), [Live](live-dark-expanded.png) and [Recently Deleted](recently-deleted-dark-expanded.png)
- [Settings](settings-general.png), [Models](settings-models.png) and [Privacy](settings-privacyPermissions.png)
- [Onboarding](onboarding-step-1.png) and [language selection](onboarding-step-3.png)
- [Queue states](queue-all-states-dark.png), [Editor](editor-dark-1440x900.png) and [menu bar](menu-bar-light.png)

These are visual evidence, not proof of real capture, permission or target-hardware acceptance. See the [validation record](../../../qa/ui-refinement-2026-11-22.md) for tested behaviour and remaining release gates.
