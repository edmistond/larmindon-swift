@/Users/edmistond/.codex/RTK.md

- Use `./scripts/check.sh` for the full local quality gate; `lint`, `format`,
  `test`, and `build` run focused subsets. See README for prerequisites and reports.
- `all`/`lint`/`format` check Swift formatting without writing files. Use the
  pinned Xcode's `swift-format` and `.swift-format` for deliberate formatting;
  keep broad mechanical sweeps in separate checkpoints. The local test/build
  commands treat Swift compiler warnings as errors; retain Swift 6 checking.
- Tool versions live in `scripts/checks-toolchain.json`. Missing tools are an
  error; install them explicitly. `./scripts/check.sh setup` installs only the
  pinned, checksum-verified SwiftLint binary into ignored `.build/` storage.
- Keep `.swiftlint-baseline.json` changes deliberate and reviewed. It contains
  four existing complexity exceptions; do not regenerate it to hide new findings.
  Length metrics are advisory. CI remains deferred.
- After each turn that changes repository files, stage only the files changed in
  that turn and create a Git checkpoint with `git commit -m "<brief summary>"`
  before the final response so changes can be rolled back if needed. Never stage
  unrelated working-tree changes.
