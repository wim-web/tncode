# Verify project scope in the signed Mac app

Run from `PiWorkspace` in a dedicated macOS desktop session with Accessibility and keyboard permissions for the AX driver. The verifier creates a disposable workspace and uses a named pasteboard.

```sh
./scripts/build-app.sh
codesign --verify --deep --strict "dist/Pi Workspace.app"
swiftc -module-cache-path .build/ax-cache scripts/ax.swift -o .build/ax
node scripts/verify-app.mjs "$PWD/.build/ax" --sidebar-and-checks-only
```

Find the report in `dist/verification-*/logs/report.txt`. The fixture starts with Alpha and Beta threads, Gamma's active unsent draft, and an empty project.

1. Open **Thread filters** (`thread-filters`). Enable **Group by Project**. Click Alpha to select its scope, then reopen the picker. Search for an unmatched title in **Search projects** (`project-filter-search`). Confirm **No matching projects** (`project-filter-no-results`) appears and Return keeps the picker open.
2. Replace the query with `a`. Press Down to highlight Beta. Press Shift-Return to add Beta to Alpha. Press it again to remove Beta. Check the native checkboxes and confirm the query stays in the field.
3. Add Beta again with its checkbox. Collapse Alpha, quit, and reopen the fixture. Confirm the saved scope contains exactly Alpha and Beta, Alpha stays collapsed, and Gamma's unsent draft is still active.
4. Choose **All Projects** (`project-filter-all`). Reopen the picker, search for `EMPTY`, and press Return. Confirm the picker closes and the sidebar offers **Show All Projects** (`sidebar-clear-project-scope`). Press it to restore the full scope.
5. Open the context menu on Beta's inactive thread. Choose **Filter by Beta**, then reopen the menu and choose **Show All Projects** (`thread-project-scope`). Confirm both actions keep Gamma's draft active.

Run `swift test --filter SidebarPersistenceTests` for the offscreen AppKit check that sends Shift-Return while the search field contains marked text.
