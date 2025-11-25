Build and run AnotherTerminal.

```bash
xcodebuild -scheme AnotherTerminal -configuration Debug build && open "$(xcodebuild -scheme AnotherTerminal -configuration Debug -showBuildSettings 2>/dev/null | grep -m 1 'BUILT_PRODUCTS_DIR' | awk '{print $3}')/AnotherTerminal.app"
```

If the app fails to launch, check Console.app for crash logs.
