# Contributing

Thanks for helping. A few rules keep Earmark local, private and consistent. More detail is in `CLAUDE.md` and `specs/`.

- **Privacy first:** no cloud ASR or translation, no telemetry. The only network use is model downloads and opt-in update checks.
- **Pull requests only:** `main` is protected. Open a PR; the `static` check must pass. Run `scripts/check.sh unit` (or the affected package with `swift test --no-parallel`) before pushing.
- **Design:** macOS 26 HIG and the DesignSystem tokens; no literal colours or fixed font sizes in feature code. Check UI changes in a real window, light and dark.
- **Contracts:** `AppCore` is frozen; propose changes with a numbered change request in `specs/changes/`.
- **Releases** are made by the maintainer from a local machine (see `specs/qa/release.md`).

Build instructions are in the README.
