# Contributing to lães

Thanks for wanting to help. lães is a small, opinionated app, so the best first step is usually a conversation.

## Reporting a bug

Open an issue with the **Bug report** form: https://github.com/jkrenge/laes/issues/new/choose. Say which app (Mac or iPhone), which version, what you did and what happened. Screenshots help, but check them for meetings, tasks or notes you don't want to share first.

Security problems are different: please report them privately as described in [SECURITY.md](SECURITY.md).

## Suggesting an idea

Use the **Idea** form. lães deliberately does a few things one way (two weeks, Saturday to Friday, Microsoft 365 only), so explain the problem you have rather than only the feature you want. That makes it easier to find something that fits.

## Changing the code

1. Open an issue first for anything bigger than a small fix, so we can agree on the approach.
2. Set up the project as described in the [README](README.md#build-it-yourself).
3. Keep changes small and focused. Follow the style around you:
   - Swift 6 with strict concurrency; SwiftUI, and only Apple's frameworks (no third-party dependencies).
   - Light mode first, dark mode supported; text meets WCAG AA contrast; controls work with the keyboard and VoiceOver.
   - Comments explain *why*, in plain sentences. Interface text is short and specific.
4. Add or update a test for logic you change (`LaesTests/`), and run the tests:
   `xcodebuild -project Laes.xcodeproj -scheme Laes -destination 'platform=macOS' test`
5. Check the change in the running app, on Mac and iPhone if it touches shared code.
6. Open a pull request that says what changed, why, and how you checked it.

## Things to know

- **Your data in tests and screenshots.** Use the sample data (`-demo` on the Mac) for screenshots, and never commit real calendar, task or note content.
- **Saved data.** Files the app keeps on the device carry a format version (`Disk.version` in `Laes/Offline.swift`). If you change a type that is saved, make sure older files still load, or raise the version and read the old one.
- **Icons.** Don't edit the generated icon images by hand; change `Scripts/make-icon.swift` and run it.

By contributing you agree that your contribution is licensed under the [MIT License](LICENSE), and that you follow the [code of conduct](CODE_OF_CONDUCT.md).
