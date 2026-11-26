# RPC and bridge source inventory

T3 Code v0.1.12 at `ca81b7b97a1c4b91e5ac25768d0f6629f37732fd`. [entries.tsv](entries.tsv) has 899 source entries. Each entry points to one of the 87 Japanese workflow or internal processing rows in [features.tsv](features.tsv). The acceptance column describes a future replay with test data. This slice uses static evidence.

## Audited registries

| Registry | Coverage | Primary evidence in the pinned source |
| --- | --- | --- |
| WebSocket RPC | 259 methods, including 5 support methods | `packages/contracts/src/rpc.ts:489`, `packages/contracts/src/orchestrationV2.ts:4100`, `packages/contracts/src/rpc.ts:2478`, `apps/server/src/ws.ts:2044` |
| Environment HTTP contract | 59 declared method, route, and endpoint-name combinations | `packages/contracts/src/environmentHttp.ts:589`. Includes the HTTP snapshot and project mutation paths used alongside WebSocket RPC. |
| Capability declarations | 88 environment fields, 2 WebSocket client flags, and 7 MCP capability values | `packages/contracts/src/environment.ts:19`, `packages/contracts/src/environment.ts:88`, `apps/server/src/environment/ServerEnvironment.ts:222`, `apps/server/src/ws.ts:822`, `apps/server/src/mcp/McpInvocationContext.ts:20` |
| Orchestration commands | 58 WebSocket dispatch discriminants, 17 server-only V2 command discriminants, 3 internal project commands, and 3 HTTP project mutation discriminants | `packages/contracts/src/rpc.ts:2118`, `packages/contracts/src/orchestrationV2.ts:3307`, `packages/contracts/src/orchestrationV2.ts:3843`, `apps/server/src/orchestration-v2/ProjectCommands.ts:21`, `packages/contracts/src/project.ts:242` |
| Orchestration events and stream variants | 49 domain event discriminants with both schema locations, 3 stored project event discriminants, 7 shell stream kinds, 11 shell status values, 3 thread stream kinds, 1 decode-only kind, 3 guest stream types, and 26 turn-item types | `packages/contracts/src/orchestrationV2.ts:2189`, `packages/contracts/src/orchestrationV2.ts:2590`, `packages/contracts/src/orchestrationV2.ts:3149`, `packages/contracts/src/orchestrationV2.ts:4448`, `packages/contracts/src/applicationEvent.ts:89`, `packages/contracts/src/guestStream.ts:37` |
| Desktop IPC | 164 declared channels, including 20 event channels, 1 duplex channel, 21 internal channels and 5 WSL channels. The 164 total includes 117 request channels. Also records 19 selected payload tags, 2 literal menu actions, 1 dynamic menu-action family, and 3 local preload functions. | `apps/desktop/src/ipc/channels.ts:1`, `apps/desktop/src/preview/GuestProtocol.ts:1`, `apps/desktop/src/preload.ts:106`, `apps/desktop/src/preview-pip-preload.ts:6`, `apps/desktop/src/ipc/DesktopIpcHandlers.ts:187`, `packages/contracts/src/ipc.ts:1112` |
| T3 MCP | 95 tool names in mounted toolkits, 12 milestone events, 3 tool-name families, and 1 independently configured app-tool family | `apps/server/src/mcp/toolkits/`, `apps/server/src/mcp/McpHttpServer.ts:1391`, `apps/server/src/mcp/McpHttpServer.ts:1572`, `apps/server/src/mcp/McpHttpServer.ts:1617`, `packages/contracts/src/milestones.ts:62` |

The WebSocket cross-check requires agreement among the wire-name maps, the `Rpc.make` declarations, `WsRpcGroup`, and the WebSocket handler map. The extractor retains permission-table references when they exist. The server makes its authorization decision for each request. Some scopes also depend on the payload. `apps/server/src/auth/RpcAuthorization.ts:317`.

Each MCP tool row points to the tool declaration, the mounted toolkit, and its registration. The extractor resolves the three tool-name constants used by `Tool.make`. It checks the specialized Preview snapshot, device screenshot, and HTML preview registrations alongside the standard toolkit mounts. `apps/server/src/mcp/McpHttpServer.ts:701`, `apps/server/src/mcp/McpHttpServer.ts:968`, `apps/server/src/mcp/McpHttpServer.ts:1000`.

## Internal and gated entries

- `command-internal` identifies the V2 commands excluded from `orchestration.dispatchCommand` and the commands behind the project mutation handler. `event-internal` identifies stored project events whose visible changes reach the client through the shell projection. `thread-stream-client` identifies `unknown-event`, which the client decoder creates while advancing its cursor. `packages/contracts/src/orchestrationV2.ts:3842`, `packages/contracts/src/orchestrationV2.ts:4415`, `apps/server/src/orchestration-v2/ProjectCommands.ts:150`.
- `rpc-support` identifies registered wire methods used to report client activity, report Preview profiles and state, and report or invalidate PR state. The public command schema also contains bookkeeping tags such as `prepared-run.progress` and `thread.title.regeneration.complete`. These retain their `command` kind because the wire schema declares them. `apps/server/src/ws.ts:2058`, `apps/server/src/orchestration-v2/ThreadLaunchService.ts:728`, `apps/server/src/orchestration-v2/ThreadTitleRegenerationService.ts:94`.
- `ipc-internal` identifies Preview guest channels and the permission-helper and HTML fullscreen channels. PiP frame events have a dedicated preload. WSL channels are retained as `ipc-platform` with a Windows gate. App settings, macOS permissions, provider availability and transport support can change what a macOS user sees. `apps/desktop/src/wsl/DesktopWslEnvironment.ts:1167`, `apps/desktop/src/preview-pip-preload.ts:6`, `apps/desktop/src/permissions/MacPermissionHelper.ts:184`.
- `serverUpdateThreadContinuation` is declared in the capability schema. The pinned descriptor producer omits it. Other environment fields depend on platform, architecture, install mode, or current settings. `packages/contracts/src/environment.ts:163`, `apps/server/src/environment/ServerEnvironment.ts:222`, `apps/server/src/environment/ServerEnvironment.ts:317`.
- MCP availability depends on the caller, access and runtime modes, provider, and feature settings. Forge operations depend on the relevant forge. The server also gates links, feedback, background wait, and some actions by caller context. Outside MCP clients can subscribe to milestones. Workflow milestones also require Workflows in Labs. `apps/server/src/mcp/McpInvocationContext.ts:196`, `apps/server/src/mcp/McpToolAccess.ts:461`, `apps/server/src/mcp/McpHttpServer.ts:1617`.

## Dynamic names and scope limits

- Deferred MCP listings start with the direct tools and add names found through `tool_search`. Names come from the registered catalog and follow caller visibility. Other clients list the tools allowed by their context and omit `tool_search`. This changes the listing for a session. The same tool remains a single catalog member. `apps/server/src/mcp/McpToolExposure.ts:4`, `apps/server/src/mcp/McpHttpServer.ts:1531`, `apps/server/src/mcp/McpHttpServer.ts:1554`.
- Pi registers `mcp__t3-code__<server-tool>` and, where deferred exposure is supported, `mcp__t3_code__<server-tool>`. Claude uses the `mcp__<server>__<tool>` naming convention, including the T3 server prefix. The configured MCP App proxy resolves names from a configured server's tool list. External servers and provider-native tools have runtime-owned catalogs. Their concrete names require a configured test session. `packages/provider-pi/src/server/mcpExtensionSource.ts:400`, `packages/provider-pi/src/server/mcpExtensionSource.ts:417`, `apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts:1091`, `apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts:2822`, `apps/server/src/mcpApps/McpAppRequests.ts:122`.
- Desktop menu events have a fixed channel. Native menu actions can supply literal names. Preview also forwards commands from the current shortcuts. The forwarded payload can vary with configuration. `apps/desktop/src/window/DesktopApplicationMenu.ts:216`, `apps/desktop/src/preview/Manager.ts:1614`, `apps/web/src/shortcuts/dispatcher.ts:148`.
- HTTP coverage is the named `EnvironmentHttp` contract. Provider JSON-RPC schemas, standalone HTTP route registrations, other RPC payload fields, and provider test fixture transcripts are outside this registry. IPC coverage includes both declared channel lists and selected event payload discriminants. Browser DOM events and Electron framework events are outside these lists.

## Reproduce

Run from `T3Audit-0.1.12`. Python 3.9 or later and Git are enough. The default command checks the pinned HEAD, regenerates entries in memory, validates source pointers and row relationships, and compares the result byte for byte with `entries.tsv`. [entry-families.tsv](entry-families.tsv) holds the ordered matching rules. [extract.py](extract.py) reads the checkout without loading T3 packages.

```sh
python3 inventory/RPC/extract.py
python3 inventory/RPC/extract.py --list
python3 inventory/RPC/extract.py --write
```

`--list` emits the extracted identifiers and pointers before workflow matching. Use `--write` to rebuild the generated table after an inventory change.
