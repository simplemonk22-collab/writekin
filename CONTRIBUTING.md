# Contributing to Writekin

Thanks for your interest! Two things to know before opening a PR:

## Licensing of contributions

Writekin is licensed under PolyForm Noncommercial 1.0.0, and Scott Goci
sells commercial licenses separately. To keep that possible, **all
contributions must assign broad rights to the maintainer**: by submitting
a contribution you agree that Scott Goci may license your contribution
under the project license and under commercial licenses at his
discretion. If you're not comfortable with that, please open an issue
instead of a PR — bug reports and ideas are just as valuable and carry no
paperwork.

## Development setup

- Xcode 16+, macOS 14+ (Apple Silicon strongly recommended — training
  uses MLX/Metal).
- `brew install xcodegen`, then `xcodegen generate` to produce the
  project (the `.xcodeproj` is generated, not checked in).
- Run the test suite before submitting: the full suite must pass.
