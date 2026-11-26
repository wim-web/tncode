#!/usr/bin/env python3
"""Enumerate HOST entries and validate source references at T3 Code v0.1.12."""

import argparse
import csv
from functools import lru_cache
from pathlib import Path
import re
import subprocess


SLICE = Path(__file__).resolve().parent
SOURCE = SLICE.parent.parent / ".source"
PIN = "ca81b7b97a1c4b91e5ac25768d0f6629f37732fd"
FEATURE_FIELDS = "id title preconditions entry action intermediate success recovery effects source gate acceptance".split()
ENTRY_FIELDS = "id kind name source feature_id".split()


def git(*args):
    return subprocess.check_output(["git", "-C", str(SOURCE), *args], text=True)


@lru_cache(maxsize=None)
def lines(path):
    return (SOURCE / path).read_text(encoding="utf-8").splitlines()


def matches(path, pattern):
    regex = re.compile(pattern)
    for number, line in enumerate(lines(path), 1):
        match = regex.search(line)
        if match:
            yield number, match


def mapping(spec):
    return {
        name: f"HOST-{feature}"
        for line in spec.strip().splitlines()
        if line.strip()
        for feature, *names in [line.split()]
        for name in names
    }


def features():
    with (SLICE / "features.tsv").open(encoding="utf-8", newline="") as stream:
        reader = csv.DictReader(stream, delimiter="\t", quoting=csv.QUOTE_NONE)
        if reader.fieldnames != FEATURE_FIELDS:
            raise ValueError("Unexpected features.tsv header")
        result = {}
        for row in reader:
            expected = f"HOST-{len(result) + 1:03d}"
            if row.get("id") != expected or None in row or not all(row.values()):
                raise ValueError(f"Malformed feature row: {row}")
            result[expected] = row
    return result


def source_references(refs, tracked, changed):
    for ref in refs.split("|"):
        path, number = ref.rsplit(":", 1)
        if path not in tracked or path in changed or not 1 <= int(number) <= len(lines(path)):
            raise ValueError(f"Reference does not resolve at the pinned checkout: {ref}")


def mapped(matches_iter, targets, label):
    missing = targets.keys() - matches_iter.keys()
    if missing:
        raise ValueError(f"Missing {label}: {', '.join(sorted(missing))}")
    for key, (name, refs) in matches_iter.items():
        if key in targets:
            yield label, name, refs, targets[key]


def rpc_entries():
    targets = mapping("""
        001 serverGetConfig serverGetSettings subscribeServerConfig
        005 serverUpdateSettings
        010 serverRefreshProviders
        012 serverUpdateProvider
        017 providerAuthStart providerAuthRespond providerAuthComplete providerAuthSubscribe
        018 providerAuthCancel
        019 providerAuthRemoveMethod providerAuthLogout
        022 chatGptReconnectProfile
        023 chatGptImportProfile chatGptHandoffSubscribe
        037 providerInstallStart providerInstallSubscribe
        038 providerInstallCancel
        039 providerInstallRemove
        042 serverSearchAcpRegistry serverPrepareAcpRegistryAgent
        044 serverAcceptAcpRegistryUrlAuth serverLogoutAcpRegistry
        045 serverUninstallAcpRegistryManagedBinary
        046 serverListAcpRegistrySessions
        047 serverListAcpRegistryProviders serverSetAcpRegistryProvider
        058 serverProbe
        059 serverGetNpmRelease serverUpdateServer serverUpdateServerWithProgress serverCommitDesktopUpdate subscribeServerLifecycle
        063 subscribeAuthAccess
        068 cloudGetRelayClientStatus cloudInstallRelayClient
        071 serverReportClientActivity
        079 peerLinksList peerLinksNames peerLinksLink peerLinksPairLink
        080 peerLinksUnlink
        081 peerLinksSubscribeThread peerLinksThreadHistoryPage peerLinksThreadItem peerLinksAnswerRequest
        083 guestShareCreate
        100 getNativeChildWork
        101 launchThread
        105 forceStopThread
        106 scheduledTasksUpsert
        108 scheduledTasksSetEnabled
        109 scheduledTasksRunNow
        110 scheduledTasksDelete
        112 scheduledTasksRotateWebhookToken
        113 scheduledTasksListWebhookDeliveries scheduledTasksGetWebhookDelivery
        115 workflowsGetDefinition workflowsSaveDefinition
        116 workflowsDeleteDefinition
        119 workflowsSubscribe workflowsCounts workflowsGet getWorkflowScript
        120 workflowsAnswer
        121 workflowsResume
        122 workflowsCancel
        127 stopWorkflow
        128 secretsAnswerRequest
        129 agentFeedbackAnswerRequest
        135 serverGetUsageSummary serverRefreshUsageRates
        138 providerConsumeResetCredit
        161 serverListTextGeneratorModels
        165 serverCheckSecretSource
        166 serverDiscoverSourceControl
        167 sourceControlSignInStart sourceControlSignInWait sourceControlSignInCancel sourceControlAppAccess
        168 issueTrackersList issueTrackersConnect issueTrackersBindProject
        169 providerMcpSignInStart providerMcpSignInComplete
        170 deviceConfigure subscribeDeviceState
        173 deviceOpen deviceAction
        175 serverImportAcpRegistrySession
        176 serverDeleteAcpRegistrySession
        177 serverDisableAcpRegistryProvider
        181 peerLinksPairClient
        185 scheduledTasksSubscribe
        195 deviceTestHost
        196 deviceEasAccount
        197 deviceSimlockIdentity
        199 serverGetTraceDiagnostics serverGetProcessDiagnostics serverGetHostResources serverGetProcessResourceHistory serverGetResourceTelemetryHistory serverRetryResourceTelemetry
        200 serverSignalProcess
        201 serverRunStorageCleanup serverGetStorageCleanupReport
        202 serverGetDatabaseStorage serverReclaimDatabaseSpace
        205 mcpAppsCallTool mcpAppsReadResource mcpAppsToolInfo mcpAppsUpdateModelContext
        206 deviceList deviceDetail
        208 deviceClose
        209 deviceShutdown
        215 providerUploadFeedback
    """)
    handlers = {}
    for path, pattern in [
        ("apps/server/src/ws.ts", r"\[(?:ORCHESTRATION_V2_)?WS_METHODS\.(\w+)\]:"),
        ("apps/server/src/auth/RpcAuthorization.ts", r"\[(?:ORCHESTRATION_V2_)?WS_METHODS\.(\w+)\]:"),
        ("packages/contracts/src/clientRpcPermissions.ts", r"\[(?:ORCHESTRATION_V2_)?WS_METHODS\.(\w+)\]:"),
    ]:
        for number, match in matches(path, pattern):
            handlers.setdefault(match[1], []).append(f"{path}:{number}")
    found = {}
    for path in ("packages/contracts/src/rpc.ts", "packages/contracts/src/orchestrationV2.ts"):
        for number, match in matches(path, r'^  (\w+): "([a-zA-Z][\w.-]+)",$'):
            if match[1] in targets:
                refs = [f"{path}:{number}", *handlers.get(match[1], [])]
                if match[1] in found:
                    raise ValueError(f"Ambiguous RPC declaration: {match[1]}")
                found[match[1]] = match[2], "|".join(refs)
    yield from mapped(found, targets, "rpc")


def tool_entries():
    targets = mapping("""
        079 t3_environment_links
        080 t3_environment_unlink
        091 orchestrator_capabilities
        092 delegate_task
        097 task_status
        098 task_cancel
        101 create_threads t3_thread_launch
        102 t3_thread_list t3_thread_read
        103 t3_thread_send
        104 t3_thread_wait
        105 t3_thread_interrupt
        106 schedule_task
        109 run_scheduled_task_now
        110 delete_scheduled_task
        117 t3_workflow
        127 t3_workflow_stop
        128 request_secret
        129 t3_feedback
        173 device_open
        185 list_scheduled_tasks
        206 device_list
        207 device_screenshot
        208 device_close
        211 t3_thread_update t3_thread_organize t3_thread_configure
        213 t3_environment_link
        214 t3_background_wait
    """)
    found = {}
    prefix = "apps/server/src/mcp/toolkits"
    for toolkit in ("orchestrator", "workflow", "thread", "project", "feedback", "device"):
        path = f"{prefix}/{toolkit}/tools.ts"
        for number, match in matches(path, r'Tool\.make\("([^"]+)"'):
            found[match[1]] = match[1], f"{path}:{number}"
    yield from mapped(found, targets, "mcp-tool")
    yield "mcp-tool", "tool_search", "apps/server/src/mcp/McpToolExposure.ts:4", "HOST-204"
    yield "mcp-tool", "send_to_user", f"{prefix}/message/tools.ts:11|packages/shared/src/toolOutput.ts:20", "HOST-210"
    action_targets = mapping("""
        117 start
        119 list read
        121 resume
        122 cancel
        123 signal
        124 withdraw
        125 store
        188 hooks
        189 questions
        190 store_set
        191 store_delete
    """)
    path = f"{prefix}/workflow/tools.ts"
    for action, feature in action_targets.items():
        number = next(
            number
            for number, match in matches(path, rf'"{action}"')
            if number == 11 or 22 <= number <= 32
        )
        yield "mcp-action", f"t3_workflow action={action}", f"{path}:{number}", feature


def http_entries():
    path = "packages/contracts/src/environmentHttp.ts"
    targets = mapping("""
        050 descriptor
        051 session browserSession token webSocketTicket webSocketTicketFor
        063 pairingCredential
        064 revokePairingLink
        065 revokeClient
        066 revokeOtherClients
        068 linkProof relayConfig unlink
        069 t3MintCredential
        071 liveActivityPreference
        072 preferences
        074 approveConnectDevice
        076 revokeConnectDevice
        077 register authorize approval decision protectedResource mcpProtectedResource authorizationServer mcpToken
        146 status prepareModel transcribe
        147 cloudKeys setCloudKey transcribeCloud
        149 models downloadModel
        150 cancelModelDownload
        151 selectModel
        152 removeModel
        153 linkModels
        154 updateAcceleration
        155 updateModelUnloadTimeout
        161 postProcess
        181 clientPairing
        182 linkState checkReachability health
        219 revoke
        221 cloudModels
    """)
    found = {}
    for number, match in matches(path, r'HttpApiEndpoint\.(\w+)\("(\w+)", "([^"]+)"'):
        method, name, endpoint = match.groups()
        if endpoint == "/oauth/mcp/token":
            name = "mcpToken"
        if name == "status" and not endpoint.startswith("/api/voice/"):
            continue
        found[name] = f"{method.upper()} {endpoint}", f"{path}:{number}"
    yield from mapped(found, targets, "http")
    declaration, endpoint = next(matches(path, r'^const WEBHOOK_PATH = "([^"]+)"'))
    for number, match in matches(path, r'HttpApiEndpoint\.(\w+)\("webhook\w+", WEBHOOK_PATH'):
        yield "http", f"{match[1].upper()} {endpoint[1]}", f"{path}:{number}|{path}:{declaration}", "HOST-113"
    guest = "apps/server/src/guest/http.ts"
    guest_targets = {
        "redeem": 85, "submit": 87, "stream": 86, "session": 86,
        "render": 86, "item": 86, "history": 86, "commandOutput": 184,
        "attachment": 86, "media": 86,
    }
    guest_contract = "packages/contracts/src/guestShare.ts"
    guest_prefix = next(
        match[1] for _, match in matches(guest_contract, r'^export const GUEST_ROUTE_PREFIX = "([^"]+)"')
    )
    guest_paths = {
        match[1]: guest_prefix + match[2]
        for _, match in matches(guest_contract, r'^export const (GUEST_\w+_ROUTE) = `\$\{GUEST_ROUTE_PREFIX\}([^`]+)`')
    }
    for number, match in matches(guest, r"^const (\w+)Route = HttpRouter\.add\("):
        name = match[1]
        if name in guest_targets:
            method = lines(guest)[number].strip().strip('",')
            route = lines(guest)[number + 1].strip().rstrip(",")
            endpoint = guest_paths.get(route) or route.strip("`").replace("${GUEST_ROUTE_PREFIX}", guest_prefix)
            if not endpoint.startswith(guest_prefix + "/"):
                raise ValueError(f"Unrecognized guest route: {route}")
            yield "http", f"{method} {endpoint}", f"{guest}:{number + 2}", f"HOST-{guest_targets[name]:03d}"


def cli_entries():
    prefix = "apps/server/src/cli"
    definitions = {
        "auth": [
            (103, "pairing create", 63), (136, "pairing list", 63), (158, "pairing revoke", 64),
            (192, "connect-device list", 73), (219, "connect-device approve", 74),
            (251, "connect-device revoke", 76), (293, "session issue", 179),
            (328, "session list", 65), (348, "session revoke", 65),
        ],
        "connect": [
            (615, "login", 180), (633, "link", 68), (664, "status", 182),
            (738, "publish", 71), (801, "unlink", 68), (810, "logout", 180),
        ],
        "environment": [(208, "link", 79), (279, "list", 79), (294, "unlink", 80)],
        "pair": [(531, "", 63)],
        "workflow": [
            (63, "start", 117), (99, "list", 119), (138, "show", 119), (190, "resume", 121),
            (203, "cancel", 122), (218, "signal", 123), (306, "withdraw", 124),
            (345, "questions", 189), (375, "hooks", 188), (401, "store list", 125),
            (429, "store set", 190), (453, "store delete", 191),
        ],
    }
    for group, entries in definitions.items():
        path = f"{prefix}/{group}.ts"
        for number, command, feature in entries:
            name = f"t3 {group} {command}".rstrip()
            if f'Command.make("{name.split()[-1]}"' not in lines(path)[number - 1]:
                raise ValueError(f"CLI command moved: {name}")
            yield "cli", name, f"{path}:{number}", f"HOST-{feature:03d}"


def provider_entries():
    driver_map = {
        "codex": ("CodexDriver", 20), "claudeAgent": ("ClaudeDriver", 24),
        "cursor": ("CursorDriver", 25), "grok": ("GrokDriver", 27), "fx": ("FxDriver", 28),
        "opencode": ("OpenCodeDriver", 29), "antigravity": ("AntigravityDriver", 37),
        "kiro": ("KiroDriver", 31), "pi": ("PiDriver", 34), "muse": ("MuseDriver", 33),
        "acpRegistry": ("AcpRegistryDriver", 42),
    }
    path = "apps/server/src/provider/builtInDrivers.ts"
    registry = {match[1]: number for number, match in matches(path, r"^  (\w+Driver),$") if 33 <= number <= 45}
    if set(registry) != {name for name, _ in driver_map.values()}:
        raise ValueError("Built-in driver list changed")
    for kind, (symbol, feature) in driver_map.items():
        yield "provider-driver", kind, f"{path}:{registry[symbol]}", f"HOST-{feature:03d}"
    symbol_to_kind = {name: kind for kind, (name, _) in driver_map.items()}
    for number, match in matches(path, r"^  (\w+Driver),$"):
        if 60 <= number <= 69:
            yield "usage-reader", symbol_to_kind[match[1]], f"{path}:{number}", "HOST-135"
    fallback_field_targets = {"enabled": 3, "customModels": 15}
    specific_field_targets = {
        ("codex", "setupMode"): 21, ("pi", "launchArgs"): 36,
        ("claudeAgent", "autoCompactWindow"): 218, ("claudeAgent", "idleCompaction"): 218,
        ("opencode", "serverUrl"): 30, ("opencode", "serverPassword"): 30,
        ("antigravity", "authMethod"): 41, ("antigravity", "apiKey"): 41,
        ("antigravity", "gcpProject"): 217, ("antigravity", "gcpLocation"): 217,
        ("acpRegistry", "source"): 43,
        ("acpRegistry", "agentId"): 42, ("acpRegistry", "distribution"): 42,
        ("acpRegistry", "commandPath"): 43, ("acpRegistry", "commandArgs"): 43,
        ("acpRegistry", "authMethodId"): 44,
    }
    core_path = "packages/contracts/src/settings.ts"
    core = {"codex": (725, 776), "claudeAgent": (804, 867), "antigravity": (886, 946)}
    for kind in driver_map:
        path = core_path if kind in core else f"packages/provider-{kind.replace('acpRegistry', 'acp-registry')}/src/settings.ts"
        begin, end = core.get(kind, (1, len(lines(path))))
        for number, match in matches(path, r"^    (\w+): (?!\[)"):
            field = match[1]
            if begin <= number <= end and field != "order":
                feature = specific_field_targets.get((kind, field), fallback_field_targets.get(field, 5))
                yield "provider-field", f"{kind}.{field}", f"{path}:{number}", f"HOST-{feature:03d}"
    for kind, name, feature in (("cursor", "CURSOR_API_KEY", 26), ("kiro", "KIRO_API_KEY", 32)):
        path = f"packages/provider-{kind}/src/client.ts"
        number = next(number for number, _ in matches(path, f'"{name}"'))
        yield "provider-env-field", name, f"{path}:{number}", f"HOST-{feature:03d}"


def ipc_entries():
    prefix = "apps/desktop/src/ipc"
    channels = f"{prefix}/channels.ts"
    channel_definitions = {
        match[1]: (match[2], number)
        for number, match in matches(channels, r'^export const (\w+_CHANNEL) = "([^"]+)"')
    }
    for file, feature in {
        "appleSpeech": 145, "connectionCatalog": 50, "localEnvironment": 49,
        "notificationBadge": 143, "providerAuth": 21, "sshEnvironment": 52,
    }.items():
        path = f"{prefix}/methods/{file}.ts"
        for number, match in matches(path, r"channel: (?:IpcChannels\.)?(\w+_CHANNEL)"):
            channel, declared_at = channel_definitions[match[1]]
            yield "electron-ipc", channel, f"{path}:{number}|{channels}:{declared_at}", f"HOST-{feature:03d}"


def ui_entries(workflows):
    label = re.compile(r'(?:gt|msg)\("([^"\\{}]+)"|<T>([^<>{}\n]+)</T>')
    client_prefix = "apps/web/src/"
    for feature, row in workflows.items():
        yield "workflow-entry", row["entry"], row["source"].split("|")[0], feature
        seen = set()
        for ref in row["source"].split("|"):
            path, pos = ref.rsplit(":", 1)
            if not path.startswith(client_prefix) or not path.endswith((".tsx", ".ts")):
                continue
            number = int(pos)
            for nearby in range(max(1, number - 2), min(len(lines(path)), number + 2) + 1):
                for match in label.finditer(lines(path)[nearby - 1]):
                    name = next(v for v in match.groups() if v is not None).strip()
                    if name and len(name) <= 64 and name not in seen:
                        seen.add(name)
                        yield "ui-text", name, f"{path}:{nearby}", feature
    path = f"{client_prefix}components/usage/usageShortcuts.ts"
    for number, match in matches(path, r'command: "([^"]+)"'):
        yield "shortcut-command", match[1], f"{path}:{number}", "HOST-133"
    targets = {
        "pair": 51, "connect": 69, "connect-agent": 77, "approve-agent": 77, "guest": 85,
        "_chat.settings.providers": 1, "_chat.settings.connections": 50,
        "_chat.settings.access": 63, "_chat.settings.labs": 82,
        "_chat.settings.scheduled-tasks": 185, "_chat.workflows": 119,
        "_chat.usage": 133, "_chat.settings.voice": 144, "_chat.settings.secrets": 163,
        "_chat.settings.source-control": 166, "_chat.settings.devices": 170,
        "_chat.settings.diagnostics": 199, "_chat.settings.storage": 201,
    }
    for file, feature in targets.items():
        path = f"{client_prefix}routes/{file}.tsx"
        number, match = next(matches(path, r'createFileRoute\("([^"]+)"'))
        yield "route-id", match[1], f"{path}:{number}", f"HOST-{feature:03d}"


def option_entries():
    path = "packages/contracts/src/settings.ts"
    targets = mapping("040 oauth-personal\n216 oauth-business\n041 gemini-api-key\n217 agent-platform")
    for number, match in matches(path, r'^  \{ value: "([^"]+)", label: "([^"]+)"'):
        if match[1] in targets:
            yield "provider-auth-mode", match[1], f"{path}:{number}", targets[match[1]]
    path = "packages/contracts/src/speech.ts"
    for number, match in matches(path, r'^export const CloudSpeechProvider = Schema.Literals\(\[(.+)\]\)'):
        for name in re.findall(r'"([^"]+)"', match[1]):
            yield "cloud-speech-provider", name, f"{path}:{number}", "HOST-147"
    number, match = next(matches(path, r'^export const SPEECH_STREAM_PATH = "([^"]+)"'))
    yield "websocket", match[1], f"{path}:{number}|apps/server/src/speech/stream.ts:121", "HOST-156"
    path = "packages/contracts/src/scheduledTask.ts"
    targets = mapping("186 new_thread\n187 continue\n212 fresh_session")
    number, match = next(matches(path, r'^export const ScheduledTaskThreadMode = Schema.Literals\(\[(.+)\]\)'))
    for name in re.findall(r'"([^"]+)"', match[1]):
        yield "scheduled-task-mode", name, f"{path}:{number}", targets[name]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check existing entries.tsv without writing")
    args = parser.parse_args()
    if git("rev-parse", "HEAD").strip() != PIN:
        raise ValueError(f"Expected source revision {PIN}")
    tracked = set(git("ls-files").splitlines())
    changed = set(git("diff", "HEAD", "--name-only").splitlines())
    workflows = features()
    for row in workflows.values():
        source_references(row["source"], tracked, changed)
    records = [*ui_entries(workflows), *provider_entries(), *option_entries(), *rpc_entries(), *tool_entries(),
               *http_entries(), *cli_entries(), *ipc_entries()]
    result = []
    for index, (kind, name, refs, feature) in enumerate(dict.fromkeys(records), 1):
        source_references(refs, tracked, changed)
        if feature not in workflows:
            raise ValueError(f"Unknown feature {feature}")
        result.append((f"HOST-E{index:04d}", kind, name, refs, feature))
    output = "\n".join("\t".join(row) for row in [ENTRY_FIELDS, *result]) + "\n"
    target = SLICE / "entries.tsv"
    if args.check:
        if target.read_text(encoding="utf-8") != output:
            raise ValueError("entries.tsv differs from the current extraction")
    else:
        target.write_text(output, encoding="utf-8")
    print(f"{len(workflows)} features, {len(result)} entries, source {PIN}")


if __name__ == "__main__":
    main()
