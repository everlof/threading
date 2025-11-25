Run SwiftLint on the codebase to check for style issues.

```bash
swiftlint lint --config .swiftlint.yml 2>&1 || swiftlint lint 2>&1
```

Report any violations found and suggest fixes for serious issues.
