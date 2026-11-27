# Contributing to Switchboard

Thanks for helping. Switchboard brings Android-style power features to iPhone as modules you can switch on and off, and new modules and fixes are welcome.

## Ground rules

- **Privacy first.** Nothing leaves the device unless the user explicitly sends it. No analytics, no accounts, no third-party SDKs.
- **No background drain.** Prefer system-enforced mechanisms (extensions, ManagedSettings, WidgetKit) over polling or keeping the app alive.
- **One module, one switch.** A module must stop all of its work when it's turned off (see `AppModel.tearDown(_:)`).

## Getting set up

```bash
brew install xcodegen
xcodegen generate
open Switchboard.xcodeproj
```

No Mac? Push to a fork and GitHub Actions builds everything, runs the tests and captures screenshots.

## Where code goes

| What | Where |
|---|---|
| Pure logic (parsing, storage, protocols) | `Packages/SwitchboardKit`, **with unit tests** |
| App screens | `App/Modules/<Module>/` |
| Code shared with extensions | `Shared/` |
| Extensions | `Extensions/<Name>/` plus a target in `project.yml` |

Keep logic out of views where you can. If it can be tested without a simulator, put it in the package.

## Adding a module

1. Add a case to `ModuleID`.
2. Add its title, tagline, icon, tint and Android equivalent in `Shared/ModuleStyle.swift`.
3. Add its screen in `App/Modules/` and route it in `ModuleScreen` and `HomeView`'s status line.
4. Stop its work in `AppModel.tearDown(_:)`.
5. Add it to `UITests/ScreenshotTests.swift` so CI screenshots it.

## Before opening a pull request

- `swift test --package-path Packages/SwitchboardKit` passes
- The app builds (CI checks this)
- New logic has tests
- UI changes include a screenshot (CI attaches them to the run)

## Commit messages

We use [Conventional Commits](https://www.conventionalcommits.org): `feat(qr): …`, `fix(shield): …`, `docs: …`, `test: …`, `ci: …`.
