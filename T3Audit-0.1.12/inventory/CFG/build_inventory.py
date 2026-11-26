#!/usr/bin/env python3
"""Regenerate features.tsv and entries.tsv for the pinned settings census."""
import csv
import re
import subprocess

from extract import Checkout, DESKTOP, ENTRY_HEADER, FEATURE_HEADER, FLAGS, REVISION, SEARCH, SETTINGS, SLICE, SOURCE, UI, verify

NATIVE_MENU = "apps/desktop/src/window/DesktopApplicationMenu.ts"
THREAD_DETAILS = "apps/web/src/components/chat/threadDetailsItems.ts"
PROVIDER_FORM = UI + "ProviderSettingsForm.tsx"
KEYBINDINGS = "packages/contracts/src/keybindings.ts"

SEARCH_FILTERS = {
    "cloudOnly": "T3 Connect 対応ビルド",
    "environmentOnly": "設定取得済みの環境",
    "providerSettingsOnly": "プロバイダー設定を利用できる環境",
    "localBackendManagementOnly": "ローカルバックエンド保守権限",
    "localEnvironmentOnly": "ローカル環境有効",
    "primaryEnvironmentOnly": "主環境あり",
    "wslAvailableOnly": "WSL 対応状態",
    "requiresThreadAutoSettlement": "自動整理を設定できる接続環境",
    "managedTunnelOnly": "T3 Connect 管理トンネル有効",
    "peerLinksOnly": "リンクに対応するホスト",
    "fastWorktreeCheckoutOnly": "fastWorktreeCheckout を広告する接続環境あり",
    "agentFeedbackOnly": "agentFeedback を広告する接続環境あり",
    "textGeneratorsOnly": "ドライバー許可リストのない環境",
    "secretProvidersOnly": "secret_providers を広告する環境",
    "releaseChannelOnly": "リリースチャネルがある実行形態",
    "desktopOnly": "Electron デスクトップ",
    "macOnly": "macOS",
    "windowsOnly": "Windows。macOS は対象外",
}


class Inventory:
    def __init__(self, checkout):
        self.checkout = checkout
        self.features = []
        self.entries = []

    def feature(self, title, entry, action, success, refs, *, gate="", keys="", stage="", recovery=""):
        feature_id = f"CFG-{len(self.features) + 1:03d}"
        effect_items = []
        has_server_key = False
        for key in filter(None, keys.split(",")):
            found = self.checkout.schema.get(key)
            namespace, name = key.split(":", 1)
            if found is None and namespace in {"server", "client", "desktop"}:
                found = self.checkout.schema[key.split(".", 1)[0]]
            project_key = name.split(".", 1)[0]
            scope = {
                "client": "このアプリの ClientSettings",
                "desktop": "デスクトップホスト",
                "server": "対象のサーバー",
                "local": "レンダラーのローカル保存",
                "file": "対象環境またはチェックアウトのファイル",
                "env": "サーバーの起動環境",
                "rpc": "対象環境のクラウド構成 API",
            }[namespace]
            if namespace == "server":
                has_server_key = True
                if project_key in self.checkout.project_keys:
                    scope += "または projectSettingsOverrides"
                if project_key in self.checkout.shared_keys:
                    scope += "。全環境スコープで共有対象"
            default = found[1] if key in self.checkout.schema else ""
            effect = f"{scope} の {name}"
            if default:
                effect += f"（スキーマ既定 {default}）"
            effect_items.append(effect)
            if found:
                refs = [*refs, found[0]]
                self.entry("settings-key", f"{namespace}.{name}", found[0], feature_id)
            else:
                kind = {"env": "env-flag", "rpc": "rpc-field"}.get(namespace, "storage-key")
                self.entry(kind, name, refs[0], feature_id)

        gate = gate or "対象ページを利用できるデスクトップセッション"
        if has_server_key:
            gate += "。書き込む場合は該当権限と管理ポリシーの許可"
        self.features.append((
            feature_id, title, gate, entry, action, stage or "記載した行または操作を対象範囲で開く。",
            success + "。", recovery or "固有の復旧動作は未確認。",
            "。".join(effect_items) + "。" if effect_items else "画面または操作対象の状態に反映。",
            "|".join(dict.fromkeys(refs)), gate, f"{action}。{success}ことを確認する。",
        ))
        return feature_id

    def entry(self, kind, name, ref, feature_id):
        self.entries.append((f"CFG-E{len(self.entries) + 1:04d}", kind, name, ref, feature_id))

    def write(self):
        for name, header, rows in [
            ("features.tsv", FEATURE_HEADER, self.features),
            ("entries.tsv", ENTRY_HEADER, self.entries),
        ]:
            with (SLICE / name).open("w", encoding="utf-8", newline="") as fh:
                writer = csv.writer(fh, delimiter="\t", lineterminator="\n", quoting=csv.QUOTE_NONE, quotechar=None)
                writer.writerow(header)
                writer.writerows(rows)


def input_rows(name, width):
    for line in (SLICE / name).read_text(encoding="utf-8").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split("^")
        assert len(fields) <= width, line
        yield fields + [""] * (width - len(fields))


def implementation_refs(source):
    return [ref if "/" in ref else UI + ref for ref in source.split("|") if ref]


def settings_navigation(inv, checkout):
    redirects = {
        "/settings": "/settings/general",
        "/settings/beta": "/settings/labs",
        "/settings/integrations": "/settings/browser",
        "/settings/storage": "/settings/maintenance",
    }
    special = {
        "/settings/diagnostics": ("Diagnostics", "Maintenance から開く。対象環境を選ぶ"),
        "/settings/open-source-licenses": ("Open source licenses", "About から開く"),
        "/settings/secrets": ("Secrets", "少なくとも一つの対象環境が secret_providers を広告"),
        "/settings/projects": ("Projects", "対象プロジェクトまたはチェックアウトを選ぶ"),
        "/settings/snap-shot": ("SnapShots", "機能の操作は macOS の Electron に依存"),
    }
    for route, ref in checkout.routes.items():
        if route in redirects:
            target = redirects[route]
            legacy = route != "/settings"
            redirect_ref = (
                checkout.ref(SEARCH, f'"{route}": "{target}"') if legacy
                else "apps/web/src/routes/_chat.settings.tsx:214"
            )
            title = f"{route} → {target}"
            feature_id = inv.feature(
                title, route, "設定の入口を開く", f"ハッシュに移設先があればそのページへ移動する。ハッシュなしでは {target} に移動する" if legacy else f"{target} に移動する",
                [ref, redirect_ref, f"{SEARCH}:1580"],
                stage="設定の親ルートが入口とハッシュを解決する。",
                recovery="ページを開けない場合は Settings を開いて対象のナビ項目を選ぶ。",
            )
            inv.entry("legacy-route" if legacy else "settings-route", route, ref, feature_id)
            if not legacy:
                inv.entry("mac-menu", "Settings...", f"{NATIVE_MENU}:252", feature_id)
                inv.entry("accelerator", "CmdOrCtrl+,", f"{NATIVE_MENU}:253", feature_id)
                inv.entry("command-palette", "Settings", "apps/web/src/components/CommandPalette.logic.ts:655", feature_id)
                inv.entry("sidebar-action", "Settings", "apps/web/src/components/sidebar/SidebarChrome.tsx:256", feature_id)
            continue
        title, gate = special.get(route, (checkout.labels.get(route, route), "対象ページを開けるセッション"))
        refs = [ref]
        if route in checkout.labels:
            refs.append(checkout.ref(SEARCH, f'  "{route}": msg('))
        else:
            refs.append(f"{UI}SettingsPanels.tsx:2603")
        feature_id = inv.feature(title + " を開く", route, f"{title} を開く", f"{title} の設定パネルが表示される", refs, gate=gate)
        inv.entry("settings-route", route, ref, feature_id)
        if route in checkout.labels:
            kind = "settings-link" if route == "/settings/diagnostics" else "settings-nav"
            inv.entry(kind, title, refs[-1], feature_id)
        else:
            inv.entry("settings-link", title, refs[-1], feature_id)

    settings_route = "apps/web/src/routes/_chat.settings.tsx"
    scope = inv.feature(
        "設定スコープ", "Settings のヘッダー", "プロジェクト、環境、チェックアウトを選ぶ",
        "設定対象と継承元が選択に応じて変わり URL に反映される",
        [f"{UI}SettingsScopeSentence.tsx:71", f"{UI}settingsScope.ts:25", f"{settings_route}:193"],
        gate="スコープ選択があるページ。接続環境とプロジェクトによって選択肢が変わる",
    )
    for key in ("project", "machine", "checkout"):
        inv.entry("scope-axis", key, checkout.ref(settings_route, f"{key}: next.{key}"), scope)
    search = inv.feature(
        "設定を検索", "Settings サイドバー", "設定名またはキーワードを入力して結果を選ぶ",
        "結果のページ、必要なスコープ、設定行のアンカーへ移動する",
        [f"{UI}SettingsSidebarNav.tsx:136", f"{SEARCH}:1714", f"{SEARCH}:1591"],
        gate="対象設定を検索で利用できる環境。機能と OS による絞り込みあり",
    )
    inv.entry("settings-action", "Settings search", f"{UI}SettingsSidebarNav.tsx:136", search)
    advanced = inv.feature(
        "Advanced を開く", "Advanced を含むページ", "Advanced を押すか詳細項目を検索で開く",
        "詳細のコントロールが表示される",
        [f"{UI}AdvancedSettings.tsx:12", f"{UI}AdvancedSettings.tsx:34"],
        gate="対象設定が OS、接続、権限の条件を満たす",
    )
    inv.entry("settings-action", "Advanced", f"{UI}AdvancedSettings.tsx:34", advanced)


def static_controls(inv, checkout):
    descriptions = {row[0]: row[1:] for row in input_rows("workflows.txt", 6)}
    assert descriptions.keys() == checkout.search.keys()
    result = {}
    for key, item in checkout.search.items():
        keys, action, success, gate, extra = descriptions[key]
        anchors = checkout.render_anchors.get(key, [])
        refs = [*implementation_refs(extra), *anchors, item["ref"]]
        assert len(refs) > 1, key
        filters = "、".join(SEARCH_FILTERS.get(name, name) for name in item["filters"]
                            if SEARCH_FILTERS.get(name, name) not in gate)
        if filters:
            gate = "。".join(filter(None, (gate, "検索条件 " + filters)))
        path = item["route"] + "#" + item["target"]
        stage = "検索結果が対象行へ移動する。"
        if item["search_scope"]:
            stage = f"検索の設定範囲は {item['search_scope']}。該当範囲で対象の行を開く。"
        feature_id = inv.feature(item["title"], path, action, success, refs,
                                 keys=keys, gate=gate, stage=stage)
        result[key] = feature_id
        inv.entry("search-id", key, item["ref"], feature_id)
        inv.entry("settings-control", item["title"], refs[0], feature_id)
        if item["route"] == "/settings/labs":
            inv.entry("labs-control", item["title"], anchors[-1], feature_id)
    return result


def startup_flags(inv, checkout):
    flag_data = [
        ("secret_providers", "false", "Secrets ページとシークレットプロバイダーフォーム", "Secrets のナビ項目が表示される",
         f"{UI}useAvailableSettingsSearchItems.ts:22"),
        ("tanstack_source", "false", "TanStack Source ドライバー", "起動後のソース管理ドライバーに TanStack Source が入る",
         "apps/server/src/sourceControl/builtInDrivers.ts:26"),
        ("github_app_client_id", "未設定", "GitHub App サインイン", "対応 GitHub ホストで GitHub App のサインインが有効になる",
         "packages/source-control-github/src/server/GitHubAppSignIn.ts:105"),
    ]
    for key, default, label, success, consumer in flag_data:
        ref = checkout.ref(FLAGS, f'("{key}")')
        user_action = f"T3CODE_FEATURE_FLAGS に {key} を設定して、設定を読むサーバーを再起動する"
        if key == "github_app_client_id":
            user_action = "T3CODE_FEATURE_FLAGS の github_app_client_id に GitHub App の公開クライアント ID を設定してサーバーを再起動する"
        feature_id = inv.feature(
            label, "T3CODE_FEATURE_FLAGS", user_action, success,
            [ref, consumer, f"{FLAGS}:42", "apps/desktop/src/app/DesktopApp.ts:178"],
            keys=f"env:T3CODE_FEATURE_FLAGS.{key}",
            gate="サーバーの起動値を指定できる。既定 " + default,
            stage="コンマ区切りで指定する。値なしの Boolean フラグは true としてデコードされる。",
            recovery="既定へ戻すには項目を外して再起動する。値のデコードに失敗するとレジストリ全体が既定へ戻る。",
        )
        inv.entry("flag-consumer", label, consumer, feature_id)


def dynamic_controls(inv, checkout, families, extras):
    controls = {
        "customModels": extras[("providers", "Add custom model")],
        "enabled": extras[("providers", "Enable provider")],
    }
    for (provider, key), (ref, hidden, declaration) in checkout.provider_fields.items():
        name = f"{provider}.{key}"
        if hidden:
            feature_id = controls.get(key, extras[("providers", "Provider configuration")])
            if key == "commandArgs":
                feature_id = extras[("providers", "Local ACP command arguments")]
            inv.entry("provider-schema-hidden", name, ref, feature_id)
            continue
        label_match = re.search(r'title: "([^"]+)"', declaration)
        title = label_match[1] if label_match else key
        control_match = re.search(r'control: "([^"]+)"', declaration)
        control = control_match[1] if control_match else "text"
        feature_id = inv.feature(
            f"{provider} · {title}", "/settings/providers", f"{title} の {control} コントロールを編集し確定する",
            f"対象インスタンスの {key} が設定値になる",
            [ref, f"{PROVIDER_FORM}:286", f"{PROVIDER_FORM}:295"],
            keys=f"server:providerInstances.config.{key}",
            gate=f"{provider} の対応インスタンス。" + (
                "ローカル ACP では source と Executable のみ汎用欄に表示"
                if provider == "AcpRegistry" else "フォームのドライバー固有条件を満たす"
            ),
            stage="インスタンスを選択するとスキーマ注釈とドライバーの条件からフォームが組み立てられる。",
        )
        inv.entry("provider-form-field", name, ref, feature_id)

    for n, line in enumerate(checkout.lines(KEYBINDINGS)[:121], 1):
        m = re.match(r'^  "([^"]+)",$', line)
        if m:
            command = m[1]
            inv.entry("keybinding-command", command, f"{KEYBINDINGS}:{n}", families["keybindings"])
            inv.entry("generated-search-id", f"keybinding-{command}", f"{SEARCH}:192", families["keybindings"])
    inv.entry("keybinding-pattern", "script.<id>.run", f"{KEYBINDINGS}:123", families["keybindings"])

    for n, line in enumerate(checkout.lines(THREAD_DETAILS)[:30], 1):
        m = re.search(r'id: "(\w+)"', line)
        if m:
            inv.entry("thread-details-item", m[1], f"{THREAD_DETAILS}:{n}", families["thread-details-items"])

    for path in sorted(checkout.root.glob("packages/source-control-*/src/shared/definition.ts")):
        relative = path.relative_to(checkout.root).as_posix()
        source = "\n".join(checkout.lines(relative))
        match = re.search(r'SourceControlProviderKind.make\("([^"]+)"\)', source)
        if match is None or "export const definition" not in source:
            continue
        kind = match[1]
        ref = checkout.ref(relative, f'SourceControlProviderKind.make("{kind}")')
        inv.entry("source-control-kind", kind, ref, families["source-control"])
        settings = re.search(r'^  (?:settings[:,]|\.\.\..*Settings)', source, re.M)
        if settings:
            inv.entry("generated-search-id", f"source-control-host-{kind}", f"{SEARCH}:214", families["source-control"])


def main():
    head = subprocess.check_output(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True).strip()
    assert head == REVISION, head
    checkout = Checkout(SOURCE)
    inv = Inventory(checkout)
    settings_navigation(inv, checkout)
    members = static_controls(inv, checkout)
    extras = {}
    for page, label, keys, action, success, gate, refs in input_rows("controls.txt", 7):
        sources = implementation_refs(refs)
        assert sources, label
        feature_id = inv.feature(label, f"/settings/{page}", action, success, sources, keys=keys, gate=gate)
        inv.entry("settings-action", label, sources[0], feature_id)
        extras[(page, label)] = feature_id
    startup_flags(inv, checkout)
    dynamic_controls(inv, checkout, members, extras)
    inv.write()
    verify(checkout)


if __name__ == "__main__":
    main()
