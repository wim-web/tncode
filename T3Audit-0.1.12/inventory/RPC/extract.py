#!/usr/bin/env python3
"""Inventory T3's pinned source without importing or running the application."""
import argparse
import csv
import io
import re
import subprocess
from collections import Counter, defaultdict
from functools import cache
from pathlib import Path

HERE = Path(__file__).resolve().parent
SOURCE = HERE.parent.parent / ".source"
COMMIT = "ca81b7b97a1c4b91e5ac25768d0f6629f37732fd"
CONTRACT = "packages/contracts/src/"
DESKTOP = "apps/desktop/src/"
SERVER = "apps/server/src/"
V2 = CONTRACT + "orchestrationV2.ts"
RPC = CONTRACT + "rpc.ts"
WS = SERVER + "ws.ts"
ENV = CONTRACT + "environment.ts"
FEATURE_HEADER = "id title preconditions entry action intermediate success recovery effects source gate acceptance".split()
ENTRY_HEADER = "id kind name source feature_id".split()


@cache
def read(path):
    return (SOURCE / path).read_text(encoding="utf-8")


def matches(path, pattern, section=None):
    raw = read(path)
    start, end = 0, len(raw)
    if section:
        opening, closing = section
        start = raw.index(opening)
        end = raw.index(closing, start + len(opening))
    for match in re.finditer(pattern, raw[start:end], re.MULTILINE):
        line = raw.count("\n", 0, start + match.start()) + 1
        yield match, f"{path}:{line}"


def literal_tags(path, prefix, section=None):
    for match, pointer in matches(path, prefix + r'\("([^"]+)"\)', section):
        yield match[1], pointer
    for match, pointer in matches(path, prefix + r's\(\[([^\]]+)\]', section):
        path, line = pointer.rsplit(":", 1)
        for member in re.finditer(r'"([^"]+)"', match[1]):
            offset = match[1][:member.start()].count("\n")
            yield member[1], f"{path}:{int(line) + offset}"


def discriminants(path, schema, field, indent):
    section = (f"const {schema} =", "\nexport type")
    prefix = "^" + " " * indent + field + r": Schema\.Literal"
    yield from literal_tags(path, prefix, section)


def rpc_entries():
    registered = {}
    for match, pointer in matches(RPC, r"(\w+)\s*=\s*Rpc\.make\(\s*(\w+_METHODS)\.(\w+)"):
        registered[match[2], match[3]] = (match[1], pointer)
    group = {m[1]: ptr for m, ptr in matches(
        RPC, r"^  (\w+Rpc),", ("export const WsRpcGroup = RpcGroup.make(", ").middleware(")
    )}
    handlers = {(m[1], m[2]): ptr for m, ptr in matches(
        WS, r"^[ \t]*\[(\w+_METHODS)\.(\w+)\]:(?=\s)"
    )}
    guarded = {(m[1], m[2]): ptr for m, ptr in matches(
        CONTRACT + "clientRpcPermissions.ts", r"^  \[(\w+_METHODS)\.(\w+)\]:"
    )}
    server_scopes = {(m[1], m[2]): ptr for m, ptr in matches(
        SERVER + "auth/RpcAuthorization.ts", r"^  \[(\w+_METHODS)\.(\w+)\]:"
    )}
    support_methods = {
        "server.reportClientActivity",
        "preview.reportProfiles",
        "preview.reportStatus",
        "pullRequests.invalidate",
        "pullRequests.reportState",
    }
    declared = set()
    for path, registry in [(RPC, "WS_METHODS"), (V2, "ORCHESTRATION_V2_WS_METHODS")]:
        for match, pointer in matches(
            path, r'^  (\w+): "([^"]+)"', (f"const {registry} = {{", "} as const")
        ):
            key = (registry, match[1])
            declared.add(key)
            symbol, payload = registered[key]
            extra = [table[key] for table in (guarded, server_scopes) if key in table]
            kind = "rpc-support" if match[2] in support_methods else "rpc"
            yield kind, match[2], [pointer, payload, group[symbol], *extra, handlers[key]]
    if declared != set(registered) or declared != set(handlers):
        raise ValueError(f"WebSocket method mismatch: registered {set(registered) ^ declared}, handlers {set(handlers) ^ declared}")
    if set(group) != {name for name, _ in registered.values()}:
        raise ValueError("WsRpcGroup differs from Rpc.make declarations")


def orchestra_entries():
    json_events = dict(discriminants(V2, "OrchestrationV2DomainEventJson", "type", 4))
    for kind, schema, field in [
        ("command", "OrchestrationV2Command", "type"),
        ("command-internal", "OrchestrationV2InternalCommand", "type"),
        ("event", "OrchestrationV2DomainEvent", "type"),
        ("shell-stream", "OrchestrationV2ShellStreamItem", "kind"),
        ("thread-stream", "OrchestrationV2ThreadStreamItem", "kind"),
        ("turn-item", "OrchestrationV2TurnItem", "type"),
    ]:
        for name, ptr in discriminants(V2, schema, field, 6 if kind == "thread-stream" else 4):
            yield kind, name, [ptr, json_events.pop(name)] if kind == "event" else [ptr]
    if json_events:
        raise ValueError(f"Unmatched JSON domain events: {json_events}")
    for path, pattern, kind in [
        (CONTRACT + "applicationEvent.ts", r'^  type: Schema\.Literal\("(project\.[^"]+)"\)', "event-internal"),
        (SERVER + "orchestration-v2/ProjectCommands.ts", r'^  readonly type: "(project\.[^"]+)"', "command-internal"),
        (V2, r'kind: Schema\.Literal\("(unknown-event)"\)', "thread-stream-client"),
    ]:
        for match, pointer in matches(path, pattern):
            yield kind, match[1], [pointer]
    for name, ptr in discriminants(CONTRACT + "project.ts", "ProjectMutation", "type", 4):
        yield "project-mutation", name, [ptr]
    for name, ptr in (
        (m[1], p) for m, p in matches(V2, r'^  type: Schema\.Literal\("((?:secret|link|feedback)_request)"\)')
    ):
        yield "turn-item", name, [ptr]
    for match, pointer in matches(CONTRACT + "milestones.ts", r'^    type: Schema\.Literal\("([^"]+)"\)'):
        yield "mcp-event", match[1], [pointer, SERVER + "milestones/MilestoneEvents.ts:135"]
    for name, ptr in literal_tags(CONTRACT + "guestStream.ts", r"Schema\.Struct\(\{ type: Schema\.Literal"):
        yield "guest-stream", name, [ptr]
    for schema in ("OrchestrationV2ShellThreadStatus", "OrchestrationV2RunStatus"):
        for name, ptr in literal_tags(V2, r"Schema\.Literal", (f"const {schema} =", "\nexport type")):
            yield "shell-status", name, [ptr]


def ipc_entries():
    channels = dict()
    for file in ["ipc/channels.ts", "preview/GuestProtocol.ts"]:
        for m, ptr in matches(DESKTOP + file, r'^export const (\w+_CHANNEL) =\s*"([^"]+)";'):
            channels[file, m[1]] = (m[2], ptr)
    use_paths = [
        "preload.ts", "preview-pip-preload.ts", "mac-permission-preload.ts", "preview/PickPreload.ts",
        "preview/PasskeyBridge.ts", "preview/Passkeys.ts",
    ]
    uses = defaultdict(list)
    host_uses = defaultdict(list)
    for file in use_paths:
        for m, ptr in matches(
            DESKTOP + file, r"(?:ipcRenderer\.(invoke|sendSync|send|on|sendToHost)\(\s*(?:IpcChannels\.)?(\w+_CHANNEL)|\brun\((PASSKEY_\w+_CHANNEL))"
        ):
            uses[m[2] or m[3]].append((m[1] or "invoke", ptr))
    for file in sorted((SOURCE / DESKTOP).rglob("*.ts")):
        relative = file.relative_to(SOURCE).as_posix()
        if file.name.endswith(".test.ts") or relative in {DESKTOP + path for path in use_paths}:
            continue
        for match, pointer in matches(
            relative,
            r"(?:channel:\s*|(?:\.send|\.on|\.handle|dispatchRendererEvent)\(\s*)(?:IpcChannels\.)?(\w+_CHANNEL)\b",
        ):
            host_uses[match[1]].append(pointer)
    for (file, symbol), (name, pointer) in channels.items():
        evidence = uses.pop(symbol, [])
        ops = {op for op, _ in evidence}
        if file == "preview/GuestProtocol.ts" or symbol in {
            "MAC_PERMISSION_HELPER_CHANNEL", "SYNC_HTML_FULLSCREEN_CHANNEL"
        }:
            kind = "ipc-internal"
        elif name.startswith("desktop:set-wsl-") or name in {
            "desktop:get-wsl-state", "desktop:to-local-backend-path",
        }:
            kind = "ipc-platform"
        elif ops == {"on"}:
            kind = "ipc-event"
        elif ops == {"on", "invoke"}:
            kind = "ipc-duplex"
        elif ops:
            kind = "ipc-method"
        else:
            raise ValueError(f"Unclassified IPC channel: {name}")
        yield kind, name, [pointer, *(ptr for _, ptr in evidence), *host_uses[symbol]]
    if uses:
        raise ValueError(f"Unresolved preload channels: {uses}")
    file = CONTRACT + "ipc.ts"
    for m, ptr in matches(file, r'^  \| \{ readonly state: "([^"]+)"', ("export type QuitShortcutHintEvent =", "\nexport ")):
        yield "ipc-payload", "QuitShortcutHintEvent." + m[1], [ptr]
    for m, ptr in matches(file, r'(?:kind|type): Schema\.Literal\("([^"]+)"\)', ("const DesktopSnapShotEvent =", "\nexport type")):
        yield "ipc-payload", "DesktopSnapShotEvent." + m[1], [ptr]
    for name, ptr in discriminants(file, "DesktopPreviewRecordingInputSchema", "type", 4):
        yield "ipc-payload", "DesktopPreviewRecordingInput." + name, [ptr]
    for name, ptr in discriminants(file, "DesktopPreviewAnnotationVoiceEventSchema", "action", 2):
        yield "ipc-payload", "DesktopPreviewAnnotationVoiceEvent." + name, [ptr]
    for name, ptr in literal_tags(
        CONTRACT + "desktopAppActivation.ts", r"^  type: Schema\.Literal",
    ):
        yield "ipc-payload", "DesktopAppActivationRequest." + name, [ptr]
    for match, pointer in matches(
        DESKTOP + "preload.ts", r"^  (getClientPlatform|getPathForFile|getWindowZoomFactor):",
    ):
        yield "bridge-local", "desktopBridge." + match[1], [pointer]
    for m, ptr in matches(
        DESKTOP + "window/DesktopApplicationMenu.ts", r'dispatchMenuAction\("([^"]+)"\)',
    ):
        yield "ipc-menu-action", m[1], [ptr]
    for _, ptr in matches(DESKTOP + "preview/Manager.ts", r"host\.send\(MENU_ACTION_CHANNEL, forwarded\.command\)"):
        yield "ipc-name-family", "desktop:menu-action <forwarded.command>", [ptr]
        break


def mcp_entries():
    base = SERVER + "mcp/"
    http = base + "McpHttpServer.ts"
    mounted = {m[1]: ptr for m, ptr in matches(
        http, r"(?:toolkitRegistration\(|decodeAsAdvertised\()\s*(\w+Toolkit)\s*[,)]"
    )}
    constants = {}
    for file, symbol in [
        ("packages/shared/src/htmlRender.ts", "HTML_RENDER_TOOL_NAME"),
        ("packages/shared/src/toolOutput.ts", "SEND_TO_USER_TOOL_NAME"),
        (base + "McpToolExposure.ts", "TOOL_SEARCH"),
    ]:
        (m, pointer), = matches(file, rf'^export const {symbol} = "([^"]+)";')
        constants[symbol] = (m[1], pointer)
    for file in sorted((SOURCE / base / "toolkits").glob("*/tools.ts")):
        path = file.relative_to(SOURCE).as_posix()
        handler = file.with_name("handlers.ts").relative_to(SOURCE).as_posix()
        toolkits = []
        for match, pointer in matches(path, r"export const (\w+Toolkit) = Toolkit\.make\((?s:(.*?))\);"):
            if match[1] in mounted:
                toolkits.append((match[2], pointer, mounted[match[1]]))
        for m, pointer in matches(
            path, r'(?:const (\w+) = (?:\w+\(\s*)?)?\bTool\.make\(\s*(?:"([^"]+)"|([\w.]+))\s*,',
        ):
            extra = []
            name = m[2]
            if name is None:
                name, constant_pointer = constants[m[3].split(".")[-1]]
                extra.append(constant_pointer)
            member = rf"\b{m[1]}\b" if m[1] else rf'Tool\.make\("{name}"'
            registration = [ptr for body, *refs in toolkits if re.search(member, body) for ptr in refs]
            if not registration:
                raise ValueError(f"MCP tool lacks a mounted toolkit: {name}")
            extra.extend(ptr for _, ptr in matches(handler, rf'^[ \t]*{name}:'))
            yield "mcp-tool", name, [pointer, *registration, *extra]
    pi = "packages/provider-pi/src/server/mcpExtensionSource.ts"
    for m, ptr in matches(pi, r'^  +const (?:ALIAS_PREFIX|prefixes) = [^\n]*?"(mcp__t3(?:-|_)code__)"'):
        yield "mcp-name-family", m[1] + "<server-tool>", [ptr]
    for _, ptr in matches(
        "apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts",
        r'^export const CLAUDE_T3_MCP_TOOL_WILDCARD\s*=',
    ):
        yield "mcp-name-family", "mcp__<server>__<tool>", [ptr]
    for _, ptr in matches(SERVER + "mcpApps/McpAppRequests.ts", r"tools\.find\(\(tool\) => tool\.name === name\)"):
        yield "mcp-proxy-family", "<configured-server>/<tool.name>", [ptr]


def capability_entries():
    descriptor = SERVER + "environment/ServerEnvironment.ts"
    for m, ptr in matches(ENV, r"^  (\w+):", ("const ExecutionEnvironmentCapabilities =", "\nexport type")):
        declarations = [p for _, p in matches(
            descriptor, rf"\b{m[1]}(?:\s*:|\s*\}})",
            ("    capabilities: {", "\n    },"),
        )]
        if m[1] == "agentActivityPublishing":
            declarations = [p for _, p in matches(descriptor, r"\.\.\.descriptor\.capabilities, agentActivityPublishing")]
        kind = "environment-capability" if declarations else "environment-capability-declared"
        yield kind, m[1], [ptr, *declarations]
    for m, ptr in matches(ENV, r'^export const \w+_CAPABILITY = "([^"]+)";'):
        yield "client-capability", m[1], [ptr, WS + ":822"]
    path = SERVER + "mcp/McpInvocationContext.ts"
    for m, ptr in matches(path, r'^  "([^"]+)",', ("const ALL_MCP_CAPABILITIES =", "] as const")):
        yield "mcp-capability", m[1], [ptr]
    for m, ptr in matches(
        CONTRACT + "environmentHttp.ts", r'HttpApiEndpoint\.(\w+)\("([^"]+)",\s*("[^"]+"|WEBHOOK_PATH)'
    ):
        route = "/api/hooks/:hookId/:token" if m[3] == "WEBHOOK_PATH" else m[3].strip('"')
        yield "http-method", f"{m[1].upper()} {route} [{m[2]}]", [ptr]


def tsv(rows):
    buffer = io.StringIO()
    csv.writer(buffer, delimiter="\t", lineterminator="\n").writerows(rows)
    return buffer.getvalue()


def load_tsv(file):
    with (HERE / file).open(encoding="utf-8", newline="") as handle:
        return list(csv.reader(handle, delimiter="\t"))


def validate_source(pointers):
    for pointer in pointers:
        path, line = pointer.rsplit(":", 1)
        lines = read(path).splitlines()
        if not 1 <= int(line) <= len(lines) or not lines[int(line) - 1].strip():
            raise ValueError(f"Invalid source pointer: {pointer}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--list", action="store_true", help="print the extracted inventory before feature mapping")
    parser.add_argument("--write", action="store_true", help="replace entries.tsv with the extracted inventory")
    args = parser.parse_args()
    head = subprocess.check_output(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True).strip()
    if head != COMMIT:
        raise ValueError(f"Expected {COMMIT}, got {head}")
    entries = sorted(
        item for extract in [rpc_entries, orchestra_entries, ipc_entries, mcp_entries, capability_entries]
        for item in extract()
    )
    keys = [(kind, name) for kind, name, _ in entries]
    if len(keys) != len(set(keys)):
        raise ValueError(f"Duplicate entries: {[key for key, count in Counter(keys).items() if count > 1]}")
    for _, _, pointers in entries:
        validate_source(pointers)
    if args.list:
        print(tsv([[kind, name, "|".join(pointers)] for kind, name, pointers in entries]), end="")
        return
    header, *features = load_tsv("features.tsv")
    ids = {row[0] for row in features}
    if header != FEATURE_HEADER or len(ids) != len(features):
        raise ValueError("Invalid feature header or duplicate feature ID")
    for index, feature in enumerate(features, 1):
        if len(feature) != len(FEATURE_HEADER) or feature[0] != f"RPC-{index:03d}" or not all(feature):
            raise ValueError(f"Invalid feature row: {feature}")
        validate_source(feature[9].split("|"))
    header, *mapping = load_tsv("entry-families.tsv")
    if header != ["feature_id", "kind", "name_regex"]:
        raise ValueError("Invalid entry mapping header")
    rules = [(feature, kind, re.compile(pattern)) for feature, kind, pattern in mapping]
    if {feature for feature, _, _ in rules} != ids:
        raise ValueError("Feature mapping IDs and features.tsv differ")
    # Earlier rules claim narrower entries before a later family catch-all.
    rows = [ENTRY_HEADER]
    hit = Counter()
    for i, (kind, name, pointers) in enumerate(entries, 1):
        try:
            index, feature = next(
                (index, feature) for index, (feature, pattern_kind, pattern) in enumerate(rules)
                if kind == pattern_kind and pattern.fullmatch(name)
            )
        except StopIteration:
            raise ValueError(f"Unmapped registry entry: {kind} {name}") from None
        hit[index] += 1
        rows.append([f"RPC-E{i:04d}", kind, name, "|".join(dict.fromkeys(pointers)), feature])
    if set(hit) != set(range(len(rules))):
        raise ValueError(f"Unused rules: {[mapping[i] for i in set(range(len(rules))) - set(hit)]}")
    output = tsv(rows)
    path = HERE / "entries.tsv"
    if args.write:
        path.write_text(output, encoding="utf-8")
    elif path.read_text(encoding="utf-8") != output:
        raise ValueError("entries.tsv differs from extracted inventory. Run extract.py --write.")
    print(f"{len(rows) - 1} entries, {len(features)} features ({COMMIT})")
    for name, count in sorted(Counter(kind for kind, _ in keys).items()):
        print(f"{name}\t{count}")


if __name__ == "__main__":
    main()
