import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { readFileSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { basename, dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const directory = dirname(fileURLToPath(import.meta.url));
const { values: options } = parseArgs({
  options: { repo: { type: "string" }, typescript: { type: "string" }, check: { type: "boolean" } },
});
const repo = resolve(options.repo ?? resolve(directory, "../../.source"));
const sha = "ca81b7b97a1c4b91e5ac25768d0f6629f37732fd";
const git = (args, input) => execFileSync("git", ["-C", repo, ...args], {
  input,
  maxBuffer: 64 * 1024 * 1024,
});
assert.equal(git(["rev-parse", "HEAD"]).toString().trim(), sha, "Expected the pinned checkout");
const require = createRequire(import.meta.url);
const ts = options.typescript ? require(resolve(options.typescript)) : require("typescript");
assert.equal(ts.version, "5.9.3", "Use TypeScript 5.9.3 to reproduce this inventory");

function scope(path) {
  if (!/^apps\/(?:web|desktop)\//.test(path)) return "other-product-tree";
  if (/(?:^|\/)(?:__tests__|tests?|__mocks__|fixtures?|storybook|stories)(?:\/|$)/i.test(path) ||
      /\.(?:test|spec|stories|story|fixture|renders)\.tsx$/i.test(path)) return "test-or-story";
  if (!/^apps\/(?:web|desktop)\/src\//.test(path)) return "outside-renderer-src";
  return "scanned";
}

const tree = git(["ls-tree", "-rz", "--full-tree", sha]).toString().split("\0");
const files = tree.filter((entry) => entry.endsWith(".tsx")).map((entry) => {
  const [metadata, path] = entry.split("\t");
  const [, type, blob] = metadata.split(" ");
  assert.equal(type, "blob");
  return { path, blob, status: scope(path), jsx: 0, entries: 0 };
});
const scanned = files.filter((file) => file.status === "scanned");
const blobs = git(["cat-file", "--batch"], scanned.map(({ blob }) => blob).join("\n") + "\n");
let byte = 0;
const sources = new Map();
for (const file of scanned) {
  const end = blobs.indexOf(10, byte);
  const [object, type, size] = blobs.toString("ascii", byte, end).split(" ");
  assert.equal(object, file.blob);
  assert.equal(type, "blob");
  byte = end + 1;
  const code = blobs.toString("utf8", byte, byte + Number(size));
  byte += Number(size) + 1;
  const source = ts.createSourceFile(file.path, code, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
  assert.equal(source.parseDiagnostics.length, 0, file.path + " failed to parse");
  sources.set(file.path, source);
}
assert.equal(byte, blobs.length);

// Bind local names for menu-array tracing. Imports outside the snapshot are left unresolved.
const settings = { noLib: true, noResolve: true, jsx: ts.JsxEmit.Preserve };
const host = ts.createCompilerHost(settings);
host.getSourceFile = (path) => sources.get(path);
const checker = ts.createProgram([...sources.keys()], settings, host).getTypeChecker();

const groups = [
  [/^components\/ui\//, "汎用UI"],
  [/^(?:browser\/|components\/preview\/)/, "統合ブラウザー・プレビュー"],
  [/^(?:cloud\/|components\/cloud\/)/, "クラウド・トンネル"],
  [/^components\/desktop\/|^components\/(?:desktopUpdate|QuitHold|InstallT3)/, "デスクトップ連携"],
  [/^(?:onboarding\/|components\/(?:auth|clerk|onboarding)\/|components\/HostedEmptyState|routes\/(?:pair|connect|approve-agent|welcome))/, "認証・初期設定"],
  [/^components\/guest\/|^routes\/guest|GuestShare/, "ゲスト共有"],
  [/^components\/device\//, "デバイス"],
  [/^components\/diffs\/|^components\/Diff/, "差分"],
  [/^components\/files\//, "ファイル・ドキュメント"],
  [/^components\/(?:pullRequest)\/|PullRequest|pull-requests/, "プルリクエスト"],
  [/^components\/issue\/|_chat\.issues/, "イシュー"],
  [/^components\/mcp\/|McpAppFrame|McpSignIn/, "MCP"],
  [/^components\/media\//, "メディア"],
  [/^components\/settings\/|^routes\/_chat\.settings|ManagedPolicy|KeybindingsConfigWarning/, "設定"],
  [/^components\/sidebar\/|^components\/(?:Sidebar|AppSidebar|SavedViews)/, "サイドバー・保存ビュー"],
  [/^components\/usage\/|UsageToggle|_chat\.usage/, "利用状況"],
  [/^components\/workflows\/|_chat\.workflows/, "ワークフロー"],
  [/^components\/terminal\/|ThreadTerminalDrawer|PersistentThreadTerminal|ChatTerminalDrawers/, "ターミナル"],
  [/^components\/RightPanel|RightPanelSurface/, "右ペイン"],
  [/^components\/CommandPalette/, "コマンドパレット"],
  [/^components\/(?:Branch|GitActions|Worktree|PreviousWorktree)/, "ブランチ・ワークツリー・Git"],
  [/^components\/(?:AddProject|Project|NoProjects|projectScript)/, "プロジェクト・スクリプト"],
  [/^components\/(?:chat\/|Chat|Composer|Thread|ContextChip|CustomSnooze)|^routes\/(?:threads|_chat)/, "チャット・スレッド"],
  [/^components\/search\//, "検索"],
  [/^speech\//, "音声入力"],
];

const intrinsic = new Map(Object.entries({
  a: "link", area: "link", button: "button", details: "disclosure", summary: "disclosure",
  form: "form", input: "input", option: "option", select: "select", textarea: "input",
}));
const roles = new Map(Object.entries({
  button: "button", link: "link", switch: "toggle", checkbox: "toggle",
  radio: "toggle", menuitem: "menu-item", menuitemcheckbox: "menu-item",
  menuitemradio: "menu-item", tab: "tab", tablist: "tab-group", combobox: "select",
  option: "option", textbox: "input", searchbox: "input", spinbutton: "input",
  slider: "input", treeitem: "option", listbox: "select", radiogroup: "select",
}));
const labels = new Set([
  "aria-label", "aria-labelledby", "ariaLabel", "alt", "label", "labelText", "title", "tooltip",
  "tooltipText", "placeholder", "text", "children", "description", "buttonLabel",
  "triggerLabel", "actionLabel", "name", "data-tooltip", "data-tooltip-content",
]);
const targeting = new Set([
  "to", "href", "download", "value", "id", "key", "type", "role", "tabIndex",
  "aria-checked", "aria-pressed", "aria-expanded", "aria-selected", "aria-controls",
  "open", "checked", "selected", "pressed", "controls", "draggable", "asChild", "render",
  "contentEditable", "nativeButton",
]);
const gateNames = new Set([
  "disabled", "aria-disabled", "readOnly", "hidden", "available", "enabled",
  "disabledReason", "requiredScope", "canOperate",
]);
const nativeInput = /^(?:auxclick|click|dblclick|contextmenu|keydown|keypress|keyup|(?:lost|got)pointercapture|pointer\w*|mouse\w*|wheel|touch\w*|drag\w*|drop|beforeinput|input|change|submit|reset|composition\w*|cut|copy|paste|focus(?:in|out)?|blur|selectionchange|scroll|scrollend|toggle|beforetoggle)$/;
const gestureHook = /^use(?:[A-Z]\w*)?(?:Draggable|Droppable|Drag|Gesture|Sortable|Hotkey|Hotkeys|Shortcut|Swipe|PointerCapture)$/;
const callback = /^on[A-Z][A-Za-z0-9]*$/;
const interactionObject = /^(?:on(?:Action|Activate|AuxClick|BeforeInput|Blur|Cancel|Change|CheckedChange|Click|Close|Command|Commit|Confirm|ContextMenu|Copy|Cut|Data|DoubleClick|Drag\w*|Drop\w*|Edit|Focus\w*|Input|Key\w*|Mouse\w*|Open|OpenChange|Paste|Pointer\w*|Press\w*|Reset|Resize\w*|Retry|Save|Scroll\w*|Select\w*|Submit\w*|Toggle\w*|Touch\w*|ValueChange|Wheel\w*)|handle(?:Click|DOMEvents|Drop|KeyDown|Paste|TextInput))$/;
const repeated = new Set(["map", "flatMap", "forEach", "reduce", "Array.from"]);
const optionFields = new Set(["action", "id", "href", "mode", "url", "value", "shortcut", "shortcutCommand"]);
const actionFields = new Set(["action", "activate", "execute", "handler", "run", "select", "set"]);
const conditionalOperators = new Set([
  ts.SyntaxKind.AmpersandAmpersandToken, ts.SyntaxKind.BarBarToken, ts.SyntaxKind.QuestionQuestionToken,
]);
const lexical = (a, b) => a < b ? -1 : a > b ? 1 : 0;
const pad = (number, length) => String(number).padStart(length, "0");
const short = (text, limit = 170) => {
  const compact = text.replace(/\s+/g, " ").trim();
  return compact.length <= limit ? compact : compact.slice(0, limit - 1) + "…";
};
const location = (node) => {
  const source = node.getSourceFile();
  const { line, character } = source.getLineAndCharacterOfPosition(node.getStart(source));
  return { path: source.fileName, line: line + 1, column: character + 1 };
};
const pointer = ({ path, line }) => path + ":" + line;
const raw = (node) => node?.getText() ?? "";
const tail = (node) => ts.isPropertyAccessExpression(node)
  ? node.name.text : ts.isIdentifier(node) ? node.text : raw(node);
const nameOf = (node) => node && (ts.isIdentifier(node) || ts.isStringLiteralLike(node))
  ? node.text : raw(node);
const unwrap = (node) => {
  while (node && (ts.isParenthesizedExpression(node) || ts.isAsExpression(node) ||
      ts.isSatisfiesExpression(node) || ts.isNonNullExpression(node) ||
      ts.isTypeAssertionExpression(node) || ts.isJsxExpression(node))) node = node.expression;
  return node;
};
const verbatim = (node) => {
  const expression = unwrap(node);
  return expression && ts.isStringLiteralLike(expression) ? expression.text : undefined;
};
const expression = (node) => {
  if (!node) return "true";
  const literal = verbatim(node);
  return literal === undefined ? short(raw(unwrap(node))) : JSON.stringify(literal);
};

function labelValue(node) {
  const value = unwrap(node);
  if (!value) return null;
  if (ts.isStringLiteralLike(value)) return ["static", JSON.stringify(value.text)];
  if (ts.isCallExpression(value)) {
    const localized = /^(?:gt|msg|t|m|messages|i18n\.t|translate)$/;
    let arg = value;
    while (arg && ts.isCallExpression(arg) && localized.test(raw(arg.expression))) {
      arg = unwrap(arg.arguments[0]);
    }
    if (arg && ts.isStringLiteralLike(arg)) return ["localized", short(raw(value))];
  }
  return ["dynamic", short(raw(value))];
}

function childLabels(element) {
  const out = [];
  if (!element || !ts.isJsxElement(element)) return out;
  const useChild = (child, depth) => {
    if (out.length >= 5) return;
    if (ts.isJsxText(child)) {
      const value = short(child.text);
      if (value) out.push(["static", JSON.stringify(value)]);
    } else if (ts.isJsxExpression(child)) {
      const label = labelValue(child);
      if (label && child.expression && child.expression.kind !== ts.SyntaxKind.NullKeyword &&
        !ts.isJsxElement(child.expression) && !ts.isJsxSelfClosingElement(child.expression) &&
        (label[0] !== "dynamic" || !/<\/?[A-Za-z][\w.]*[\s>/]/.test(label[1]))) out.push(label);
    } else if (depth < 4 && ts.isJsxElement(child)) {
      const tag = raw(child.openingElement.tagName);
      if (/^(?:T|Trans|Var|span|strong|em|small|b|i|kbd|code|MenuItemLabel|SelectItemLabel|[A-Z]\w*Label)$/.test(tag)) {
        const before = out.length;
        for (const nested of child.children) useChild(nested, depth + 1);
        if (out.length > before && /^(?:T|Trans)$/.test(tag)) {
          for (const label of out.slice(before)) if (label[0] === "static") label[0] = "localized";
        } else if (out.length === before && /^[A-Z]/.test(tag)) {
          out.push(["dynamic", short(raw(child), 110)]);
        }
      }
    } else if (ts.isJsxSelfClosingElement(child) && /^(?:T|Trans|Var|[A-Z]\w*Label)$/.test(raw(child.tagName))) {
      out.push(["dynamic", short(raw(child), 110)]);
    }
  };
  for (const child of element.children) useChild(child, 0);
  return out.map(([mode, value]) => ["children", mode, value]);
}

function adjacentTooltip(node) {
  for (let current = node; current.parent && !ts.isSourceFile(current.parent); current = current.parent) {
    if (!ts.isJsxElement(current.parent) || !current.parent.children.includes(current)) continue;
    const siblings = current.parent.children;
    const tag = raw(current.parent.openingElement.tagName);
    if (/^(?:Tooltip|SharedTooltip)$/.test(tag)) {
      const popup = siblings.find((sibling) => ts.isJsxElement(sibling) &&
        /^(?:TooltipPopup|TooltipContent)$/.test(raw(sibling.openingElement.tagName)));
      return childLabels(popup).map(([, mode, value]) => ["tooltip-sibling", mode, value]);
    }
    if (!/^(?:TooltipTrigger|SharedTooltipTrigger)$/.test(tag)) break;
  }
  return [];
}

function lineage(node) {
  const declarations = [];
  let generated = false;
  let conditional = false;
  let dev = false;
  for (let current = node.parent; current && !ts.isSourceFile(current); current = current.parent) {
    if ((ts.isFunctionDeclaration(current) || ts.isFunctionExpression(current) ||
         ts.isClassDeclaration(current) || ts.isMethodDeclaration(current)) && current.name) {
      declarations.push({ name: nameOf(current.name), node: current });
    }
    if (ts.isVariableDeclaration(current) && ts.isIdentifier(current.name)) {
      declarations.push({ name: current.name.text, node: current });
    }
    if (ts.isConditionalExpression(current) || ts.isIfStatement(current) ||
        ts.isCaseClause(current) || ts.isDefaultClause(current) ||
        (ts.isBinaryExpression(current) && conditionalOperators.has(current.operatorToken.kind))) {
      conditional = true;
    }
    if (ts.isBinaryExpression(current) && current.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken &&
      /\bimport\.meta\.env\.DEV\b/.test(raw(current.left))) dev = true;
    if (ts.isForStatement(current) || ts.isForInStatement(current) || ts.isForOfStatement(current) ||
        ts.isWhileStatement(current) || ts.isDoStatement(current) ||
        (ts.isCallExpression(current) && repeated.has(raw(current.expression) === "Array.from"
          ? "Array.from" : tail(current.expression)))) generated = true;
  }
  const owner = declarations.find(({ name, node: declaration }) =>
    /^[A-Z][A-Za-z0-9]*$/.test(name) &&
    (!ts.isVariableDeclaration(declaration) || (declaration.initializer &&
      !ts.isArrayLiteralExpression(unwrap(declaration.initializer)) &&
      !ts.isObjectLiteralExpression(unwrap(declaration.initializer))))) ??
    declarations.at(-1) ?? { name: basename(node.getSourceFile().fileName, ".tsx"), node: node.getSourceFile() };
  return { owner, declarations, generated, conditional, dev };
}

function jsxKind(tag, props) {
  const name = tag.split(".").at(-1);
  const type = verbatim(props.get("type")?.value);
  const role = verbatim(props.get("role")?.value);
  if (roles.has(role)) return roles.get(role);
  if (intrinsic.has(tag)) {
    if (tag === "a" && !props.has("href") && !props.has("onClick") && !role) return null;
    if (tag === "input" && type === "hidden") return "form-hidden";
    if (tag === "input" && ["checkbox", "radio"].includes(type)) return "toggle";
    if (tag === "input" && ["submit", "reset", "button", "image"].includes(type)) return "button";
    return intrinsic.get(tag);
  }
  if ((tag === "audio" || tag === "video") && props.has("controls") &&
    raw(unwrap(props.get("controls").value)) !== "false") return "media-control";
  if (props.has("contentEditable") || /^(?:EditorContent|CodeMirror|MonacoEditor)$/.test(name)) return "editor";
  if (/^DndContext$|(?:ResizeHandle|RestoreHandle|DragHandle)$/.test(name)) return "gesture";
  if (/^(?:TabsList|ToggleGroup|SortableTabList)$/.test(name)) return "tab-group";
  if (/^(?:TooltipTrigger|SharedTooltipTrigger)$|^TooltipPrimitive\.Trigger$/.test(tag)) return "tooltip-trigger";
  if (/^(?:ContextMenu|DropdownMenu|Menu)(?:Sub|Radio)?Trigger$/.test(name)) return "menu-trigger";
  if (/^(?:Combobox|Select|Autocomplete)Item$/.test(name) || /^(?:Combobox|Select|Autocomplete)Primitive\.Item$/.test(tag)) return "option";
  if (/^(?:Select|Combobox|Autocomplete)Trigger$/.test(name) || /^(?:Select|Combobox|Autocomplete)Primitive\.Trigger$/.test(tag)) return "select-trigger";
  if (/^(?:ContextMenu|DropdownMenu|SidebarMenu|Menu|Command)(?:Sub|Radio|Checkbox)?Item$/.test(name) ||
      /(?:MenuItem|CommandItem)$/.test(name)) return "menu-item";
  if (/^(?:Item|RadioItem|CheckboxItem|SubmenuTrigger|Trigger)$/.test(name) &&
      /(?:Menu|Command|Combobox|Select|Autocomplete)Primitive\./.test(tag)) {
    return name.includes("Trigger") ? "menu-trigger" : "menu-item";
  }
  if (name === "PullRequestDetailTabBar") return "tab-group";
  if (/^(?:Tab|TabsTrigger|TabTrigger|RightPanelTab)$/.test(name)) return "tab";
  if (/(?:Tab|TabPanel)$/.test(name)) return null; // panel bodies attach their own controls
  if (/^(?:Dialog|AlertDialog|Popover|Collapsible|Sheet)Trigger$/.test(name) ||
      /^(?:Dialog|AlertDialog|Popover|Collapsible|Sheet)Primitive\.Trigger$/.test(tag)) return "popup-trigger";
  if (/^(?:NumberField|ExpandableSearch|FileSearchField)$/.test(name)) return "input";
  if (/(?:Button|Trigger|DialogClose|PopoverClose|AppRouteModalClose|FileSurfaceAction|SettingsAction)$/.test(name) ||
      /^Close$/.test(name) && /(?:Dialog|Popover|Sheet)Primitive\./.test(tag)) return "button";
  if (/(?:Link)$/.test(name)) return "link";
  if (/(?:Switch|Checkbox|Radio|Toggle)$/.test(name) || /(?:Checkbox|Switch|Toggle|Radio)Primitive\.Root$/.test(tag)) return "toggle";
  if (/(?:Input|Textarea|TextArea|Slider|Editable|SearchField)$/.test(name)) return "input";
  if (/(?:Picker|Select|Combobox|RadioGroup|Listbox)$/.test(name) ||
      /^(?:Select|Combobox|Autocomplete|RadioGroup)Primitive\.Root$/.test(tag)) return "select";
  if (/^(?:Form|FieldControl|Control)$/.test(name) && /(?:Form|Field)Primitive\./.test(tag)) return "form";
  if (props.has("draggable")) return "gesture";
  if (props.has("aria-pressed") || props.has("aria-checked") || props.has("aria-expanded") ||
    props.has("aria-selected")) return "aria-state";
  if (props.has("tabIndex")) return "focus-target";
  return null;
}

function objectProperties(node) {
  const data = new Map();
  const spreads = [];
  for (const property of node.properties) {
    if (ts.isSpreadAssignment(property)) spreads.push(short(raw(property.expression)));
    else if (ts.isPropertyAssignment(property)) data.set(nameOf(property.name), { node: property, value: property.initializer });
    else if (ts.isShorthandPropertyAssignment(property)) data.set(property.name.text, { node: property, value: property.name });
    else if (ts.isMethodDeclaration(property)) data.set(nameOf(property.name), { node: property, value: property.name });
  }
  return { data, spreads };
}

const processLabels = (data) => [...data].filter(([name]) => labels.has(name)).flatMap(([name, { value }]) => {
  const label = labelValue(value);
  return label ? [[name, name === "aria-labelledby" ? "reference" : label[0], label[1]]] : [];
});
const propText = (data, names) => [...data].filter(([name]) => names.has(name))
  .map(([name, { value }]) => name + "=" + expression(value));

function contextCall(node) {
  const callee = node.expression;
  return ts.isPropertyAccessExpression(callee) && callee.name.text === "show" &&
    tail(callee.expression) === "contextMenu";
}

function dynamicTag(symbol) {
  if (!symbol) return true;
  return symbol.declarations?.some((declaration) =>
    ts.isBindingElement(declaration) || ts.isParameter(declaration) ||
    (ts.isVariableDeclaration(declaration) && declaration.initializer &&
      (ts.isConditionalExpression(unwrap(declaration.initializer)) ||
       ts.isElementAccessExpression(unwrap(declaration.initializer))))) ?? false;
}

function inspectSource(source) {
  const sites = [];
  const seen = new Map();
  const menuRoots = [];
  const arrayWrites = new Map();
  let jsx = 0;

  function record(node, kind, tag, info = {}) {
    const key = node.getStart(source) + ":" + kind;
    if (seen.has(key)) return;
    seen.set(key, true);
    const where = location(node);
    const { owner, declarations, generated, conditional, dev: devCondition } = lineage(node);
    const path = source.fileName.replace(/^apps\/(?:web|desktop)\/src\//, "");
    const primitive = path.startsWith("components/ui/");
    const dev = devCondition || path === "components/DevReplayHost.tsx";
    const family = groups.find(([pattern]) => pattern.test(path))?.[1] ?? "アプリ共通";
    const contextOwner = kind.startsWith("context-menu")
      ? declarations.find(({ name }) => /^(?:handle|show|open)[A-Z].*(?:menu|context)/i.test(name) && name !== owner.name)
      : null;
    const workflow = primitive || dev || !contextOwner ? owner.name : owner.name + " › " + contextOwner.name;
    const flags = [
      primitive && "primitive",
      dev && "dev",
      (generated || info.generated) && "generated",
      (conditional || info.gates?.length) && "conditional",
      info.spreads?.length && "spread",
      info.labels?.some(([, mode]) => mode === "dynamic" || mode === "reference") && "dynamic-label",
      info.delegated && "delegated",
      info.opaque && "opaque",
      info.candidate && "candidate",
    ].filter(Boolean);
    sites.push({ where, owner: owner.name, ownerWhere: location(owner.node), family, workflow, primitive, dev,
      key: source.fileName + "#" + workflow + (dev ? "#dev" : ""), kind, tag, flags, ...info });
  }

  function visit(node) {
    if (ts.isJsxOpeningElement(node) || ts.isJsxSelfClosingElement(node)) {
      jsx++;
      const tag = short(raw(node.tagName));
      const symbol = checker.getSymbolAtLocation(node.tagName);
      const importSpecifier = symbol?.declarations?.find(ts.isImportSpecifier);
      const declaredTag = importSpecifier?.propertyName?.text ?? tag;
      const data = new Map();
      const spreads = [];
      for (const attr of node.attributes.properties) {
        if (ts.isJsxSpreadAttribute(attr)) spreads.push(short(raw(attr.expression)));
        else data.set(raw(attr.name), { node: attr, value: attr.initializer });
      }
      const handlers = [...data].filter(([name]) => callback.test(name));
      const semantic = jsxKind(declaredTag, data);
      const kind = semantic ? "jsx-" + semantic : handlers.length ? "jsx-callback" : spreads.length ? "jsx-spread" : null;
      const knownInteraction = handlers.some(([name]) => interactionObject.test(name));
      if (kind) record(node, kind, tag, {
        labels: processLabels(data)
          .concat(childLabels(ts.isJsxOpeningElement(node) ? node.parent : null), adjacentTooltip(node)),
        bindings: handlers.map(([name, { value, node: attr }]) => name + "@" + location(attr).line + "=" + expression(value)),
        props: propText(data, targeting),
        gates: propText(data, gateNames),
        spreads,
        candidate: ["jsx-spread", "jsx-form-hidden", "jsx-tooltip-trigger"].includes(kind) ||
          (!semantic || ["jsx-focus-target", "jsx-aria-state"].includes(kind)) && !knownInteraction,
        generated: /^[A-Z]/.test(tag) && dynamicTag(symbol),
        delegated: data.has("render") || data.has("asChild"),
      });
    }
    if (ts.isCallExpression(node)) {
      const callee = node.expression;
      const method = tail(callee);
      if (contextCall(node)) {
        const items = node.arguments[0];
        record(node, "context-menu-open", raw(callee).replace(/\s*\.\s*/g, "."), {
          bindings: ["items=" + expression(items)],
          generated: items && !ts.isArrayLiteralExpression(unwrap(items)),
        });
        if (items) menuRoots.push(items);
      } else if (ts.isPropertyAccessExpression(callee) && ["push", "unshift"].includes(method)) {
        const symbol = checker.getSymbolAtLocation(callee.expression);
        if (symbol) arrayWrites.set(symbol, (arrayWrites.get(symbol) ?? []).concat([...node.arguments]));
      } else if (ts.isPropertyAccessExpression(callee) && method === "addEventListener") {
        const event = verbatim(node.arguments[0]);
        if (event === undefined || nativeInput.test(event) || /^(?:ipc-message|resize)$/.test(event)) {
          record(node, "event-listener", short(raw(callee)), {
            props: ["event=" + expression(node.arguments[0])],
            bindings: ["listener=" + expression(node.arguments[1])],
            candidate: event === undefined || /^(?:focus|focusin|focusout|blur|resize|ipc-message|scroll|scrollend)$/.test(event),
            opaque: event === undefined,
          });
        }
      } else if (gestureHook.test(method) || /^(?:attachCustomKeyEventHandler|setPointerCapture|releasePointerCapture|useSensor|useSensors)$/.test(method)) {
        record(node, "gesture-binding", short(raw(callee)), {
          bindings: node.arguments.slice(0, 2).map((arg) => expression(arg)),
        });
      } else if (/^(?:register|bind)(?:[A-Z]\w*)?(?:Command|Commands|Shortcut|Shortcuts|Keybinding|Hotkey)$/.test(method)) {
        record(node, "shortcut-registration", short(raw(callee)), {
          bindings: node.arguments.slice(0, 3).map((arg) => expression(arg)),
        });
      } else if (method === "useRender") {
        const argument = unwrap(node.arguments[0]);
        if (argument && ts.isObjectLiteralExpression(argument)) {
          const { data, spreads } = objectProperties(argument);
          const tag = verbatim(data.get("defaultTagName")?.value);
          record(node, "element-factory", tag ?? "useRender", {
            labels: processLabels(data),
            props: propText(data, new Set([...targeting, "defaultTagName"])),
            bindings: ["useRender", "props=" + expression(data.get("props")?.value)],
            spreads, delegated: data.has("render"), candidate: !intrinsic.has(tag),
          });
        }
      } else if (method === "createElement" && (ts.isIdentifier(callee) || /^(?:React|document|ownerDocument)$/.test(raw(callee.expression)))) {
        const target = node.arguments[0];
        const tag = verbatim(target) ?? short(raw(target));
        const propsNode = unwrap(node.arguments[1]);
        const { data, spreads } = propsNode && ts.isObjectLiteralExpression(propsNode)
          ? objectProperties(propsNode) : { data: new Map(), spreads: [] };
        const kind = jsxKind(tag, data);
        const domAnchor = tag === "a" && method === "createElement";
        if (kind || domAnchor || [...data.keys()].some((name) => callback.test(name))) {
          const children = node.arguments.slice(2, 7).map(labelValue).filter(Boolean)
            .map(([mode, value]) => ["children", mode, value]);
          record(node, "element-factory", tag, {
            labels: processLabels(data).concat(children), props: propText(data, targeting), spreads,
            bindings: [short(raw(callee))], generated: domAnchor, candidate: domAnchor,
          });
        }
      }
    }
    if (ts.isObjectLiteralExpression(node)) {
      const { data, spreads } = objectProperties(node);
      const labelled = ["label", "title", "children", "aria-label", "ariaLabel"].some((key) => data.has(key));
      const editorEvents = ts.isPropertyAssignment(node.parent) && nameOf(node.parent.name) === "handleDOMEvents";
      const handlers = [...data].filter(([name, { value }]) =>
        interactionObject.test(name) || (editorEvents && nativeInput.test(name)) || (labelled && callback.test(name)) ||
        (labelled && actionFields.has(name) && verbatim(value) === undefined));
      const option = labelled && (data.has("label") || data.has("kind")) &&
        [...optionFields].some((key) => data.has(key));
      if (handlers.length || option) record(node, handlers.length ? "object-callback" : "object-option", "Object", {
        labels: processLabels(data),
        bindings: handlers.map(([name, { value, node: member }]) => name + "@" + location(member).line + "=" + expression(value)),
        gates: propText(data, gateNames),
        props: propText(data, new Set([...targeting, ...optionFields])),
        spreads,
        candidate: !editorEvents && (!labelled || !handlers.length),
      });
    }
    ts.forEachChild(node, visit);
  }

  // Follow array expressions, local declarations, returns and mutations. Preserve opaque builders as evidence.
  const followed = new Set();
  function traceMenu(input) {
    const node = unwrap(input);
    if (!node || followed.has(node)) return;
    followed.add(node);
    if (ts.isArrayLiteralExpression(node)) {
      for (const item of node.elements) traceMenu(ts.isSpreadElement(item) ? item.expression : item);
      return;
    }
    if (ts.isConditionalExpression(node)) {
      traceMenu(node.whenTrue);
      traceMenu(node.whenFalse);
      return;
    }
    if (ts.isBinaryExpression(node) && conditionalOperators.has(node.operatorToken.kind)) {
      if (node.operatorToken.kind !== ts.SyntaxKind.AmpersandAmpersandToken) traceMenu(node.left);
      traceMenu(node.right);
      return;
    }
    if (ts.isObjectLiteralExpression(node)) {
      const { data, spreads } = objectProperties(node);
      const known = data.has("id") || data.has("label") || data.has("separator");
      if (!known && !spreads.length) return; // Object fragments such as { disabled: true } add no menu item.
      const key = data.get("id") ?? data.get("action");
      record(node, known ? "context-menu-item" : "context-menu-source", key ? expression(key.value) : "Object", {
        labels: processLabels(data).filter(([name]) => name !== "children"),
        props: propText(data, new Set(["id", "action", "type", "shortcut", "icon", "separator", "checked"])),
        gates: propText(data, gateNames),
        spreads,
        generated: spreads.length > 0 || !known,
        opaque: !known || spreads.length > 0,
      });
      for (const property of node.properties) {
        if (ts.isSpreadAssignment(property)) traceMenu(property.expression);
        if (ts.isPropertyAssignment(property) &&
            ["items", "children", "submenu", "subItems"].includes(nameOf(property.name))) traceMenu(property.initializer);
      }
      return;
    }
    if (ts.isCallExpression(node) && ts.isPropertyAccessExpression(node.expression) &&
        ["map", "flatMap", "filter", "slice", "concat"].includes(node.expression.name.text)) {
      traceMenu(node.expression.expression);
      for (const arg of node.arguments) {
        if (ts.isArrowFunction(arg) || ts.isFunctionExpression(arg)) traceReturns(arg.body);
        else if (node.expression.name.text === "concat") traceMenu(arg);
      }
      return;
    }
    const target = ts.isCallExpression(node) ? node.expression : node;
    if (ts.isIdentifier(target)) {
      const symbol = checker.getSymbolAtLocation(target);
      const declarations = symbol?.declarations?.filter((declaration) => declaration.getSourceFile() === source) ?? [];
      let found = false;
      for (const declaration of declarations) {
        if (ts.isVariableDeclaration(declaration) && declaration.initializer) {
          const initializer = unwrap(declaration.initializer);
          if (ts.isArrowFunction(initializer) || ts.isFunctionExpression(initializer)) traceReturns(initializer.body);
          else traceMenu(initializer);
          found = true;
        }
        if (ts.isFunctionDeclaration(declaration) && declaration.body) {
          traceReturns(declaration.body);
          found = true;
        }
      }
      for (const arg of arrayWrites.get(symbol) ?? []) {
        traceMenu(ts.isSpreadElement(arg) ? arg.expression : arg);
        found = true;
      }
      if (found) return;
    }
    if (node.kind !== ts.SyntaxKind.NullKeyword && node.kind !== ts.SyntaxKind.FalseKeyword &&
        node.kind !== ts.SyntaxKind.UndefinedKeyword) {
      record(node, "context-menu-source", expression(node), { generated: true, opaque: true });
    }
  }

  function traceReturns(body) {
    if (!ts.isBlock(body)) {
      traceMenu(body);
      return;
    }
    function walk(node) {
      if (ts.isReturnStatement(node)) {
        traceMenu(node.expression);
      } else if (!ts.isFunctionLike(node)) ts.forEachChild(node, walk);
    }
    walk(body);
  }

  visit(source);
  for (const root of menuRoots) traceMenu(root);
  sites.sort((a, b) => a.where.line - b.where.line || a.where.column - b.where.column || lexical(a.kind, b.kind));
  return { sites, jsx };
}

const allSites = [];
for (const file of scanned) {
  const { sites, jsx } = inspectSource(sources.get(file.path));
  file.jsx = jsx;
  const menuItems = new Set(sites.filter(({ kind }) => kind === "context-menu-item")
    .map(({ where }) => where.line + ":" + where.column));
  const distinct = sites.filter(({ kind, where }) => kind !== "object-option" ||
    !menuItems.has(where.line + ":" + where.column));
  file.entries = distinct.length;
  allSites.push(...distinct);
}

function describeSite(site) {
  const details = [
    ...(site.labels ?? []).map(([name, mode, value]) => name + "[" + mode + "]=" + value),
    ...(site.props ?? []),
    ...(site.bindings ?? []),
    ...(site.gates ?? []),
    ...(site.spreads ?? []).map((spread) => "..." + spread),
  ];
  const flags = site.flags.length ? " [" + site.flags.join(",") + "]" : "";
  return [site.owner + " › " + site.tag + " (col " + site.where.column + ")" + flags, ...details].join(" | ");
}

function evidence(site) {
  const word = site.labels?.find(([name, mode]) =>
    ["aria-label", "ariaLabel", "label", "title", "children", "tooltip-sibling"].includes(name) &&
    mode !== "reference");
  return word ? word[2] : site.tag;
}

const featureGroups = Map.groupBy(allSites, (site) => site.key);
const features = [];
const ids = new Map();
for (const [key, sites] of featureGroups) {
  const id = "UI-" + pad(features.length + 1, 3);
  ids.set(key, id);
  const subject = sites[0];
  const { family, workflow, primitive, dev, ownerWhere } = subject;
  const menu = sites.some(({ kind }) => kind === "context-menu-open" || kind === "context-menu-item");
  const onlyCandidates = sites.every(({ candidate }) => candidate);
  const scored = [...sites].sort((a, b) => score(b) - score(a));
  function score(site) {
    const label = site.labels?.some(([, mode]) => mode === "static" || mode === "localized");
    return (site.candidate ? 0 : 16) + (menu && site.kind === "context-menu-item" ? 8 : 0) +
      (label ? 4 : 0) + (site.bindings?.length ? 2 : 0) + (site.props?.length ? 1 : 0);
  }
  const anchors = scored.slice(0, 2);
  const source = [...new Set([pointer(ownerWhere), ...anchors.map((site) => pointer(site.where))])].join("|");
  const examples = [...new Set(anchors.map((site) => short(evidence(site), 100)))].join("、");
  const route = ownerWhere.path.includes("/routes/") ? "（" + basename(ownerWhere.path, ".tsx") + "）" : "";
  const title = family + "・" + workflow + route + (dev ? "（開発用）" : onlyCandidates ? "（操作候補）" : "");
  const preconditions = primitive ? "この汎用コンポーネントを使う呼び出し元を表示する" :
    dev ? "DevReplay が使える開発用の構成を用意する" : "対象を表示できる画面と必要なデータを用意する";
  const entry = menu ? "対象のコンテキストメニュー" : workflow + " を表示する画面";
  const action = menu ? "対象を右クリックし、" + examples + " に相当する項目を選ぶ" :
    examples + " に相当するコントロールで、宣言に対応する入力を行う";
  const outcome = menu ? "選んだ項目に対応する分岐に進む" : "対応するイベント、遷移、または入力の結果が発生する";
  const gate = onlyCandidates ? "呼び出し元で実際にユーザー操作を受ける構成か確認する" :
    primitive ? "呼び出し元の表示条件、ラベル、ハンドラーを確認する" :
      "表示条件、権限、無効状態、実行環境を該当する宣言ごとに確認する";
  const target = anchors[0].bindings?.[0]?.split("=")[0] ?? anchors[0].props?.find((prop) => /^(?:href|to)=/.test(prop));
  const acceptance = onlyCandidates
    ? "実際に提示される対象を特定し、対応する入力で宣言の処理が呼ばれることを確認する"
    : menu
      ? "メニューを開いて宣言された有効な項目を選び、同じ項目 ID の処理に進むことを確認する"
      : target
        ? "宣言の対象を一度操作し、" + short(target, 100) + " の処理またはリンク先に到達することを確認する"
        : "宣言の対象を一度操作し、対応する入力・状態変更・遷移が発生することを確認する";
  features.push([id, title, preconditions, entry, action,
    "対象の項目・入力・トリガーが利用できる状態になる", outcome,
    "回復手順は個別の操作宣言と呼び出し先で確認する", "操作別の副作用は実装側の確認が必要", source, gate, acceptance]);
}
const entries = allSites.map((site, index) => [
  "UI-E" + pad(index + 1, 4), site.kind, describeSite(site), pointer(site.where), ids.get(site.key),
]);

function counts(list) {
  return Object.fromEntries([...Map.groupBy(list, (value) => value)].sort(([a], [b]) => lexical(a, b))
    .map(([key, values]) => [key, values.length]));
}
const summary = {
  commit: sha, typescript: ts.version,
  filesByScope: counts(files.map(({ status }) => status)),
  tsxByTree: counts(files.map(({ path }) => path.split("/").slice(0, 2).join("/"))),
  scannedByApp: counts(scanned.map(({ path }) => path.split("/")[1])),
  scannedFilesWithEntries: scanned.filter(({ entries }) => entries > 0).length,
  scannedFilesWithoutEntries: scanned.filter(({ entries }) => entries === 0).length,
  jsxOpenings: scanned.reduce((sum, { jsx }) => sum + jsx, 0),
  entries: entries.length,
  entriesWithLabelEvidence: allSites.filter(({ labels }) => labels?.length > 0).length,
  entriesByKind: counts(allSites.map(({ kind }) => kind)),
  entriesByFlag: counts(allSites.flatMap(({ flags }) => flags)),
  sourceWorkflowGroups: features.length,
  groupsByClass: counts([...featureGroups.values()].map(([first, ...rest]) =>
    first.primitive ? "primitive" : first.dev ? "dev" : [first, ...rest].every(({ candidate }) => candidate)
      ? "candidate-only" : "product-source")),
  groupsByFamily: counts([...featureGroups.values()].map(([{ family }]) => family)),
};

function write(name, data) {
  const path = resolve(directory, name);
  if (options.check) assert(readFileSync(path, "utf8") === data, name + " differs from the pinned extraction");
  else writeFileSync(path, data);
}
function tsv(name, header, rows) {
  for (const row of rows) {
    assert.equal(row.length, header.length, name);
    assert(row.every((cell) => cell !== undefined && !/[\t\r\n]/.test(String(cell))),
      name + " contains a broken cell at " + row[0]);
  }
  write(name, [header, ...rows].map((row) => row.join("\t")).join("\n") + "\n");
}

tsv("entries.tsv", ["id", "kind", "name", "source", "feature_id"], entries);
tsv("features.tsv", ["id", "title", "preconditions", "entry", "action", "intermediate", "success", "recovery",
  "effects", "source", "gate", "acceptance"], features);
tsv("files.tsv", ["path", "status", "jsx_openings", "entries"], files.map((file) =>
  [file.path, file.status, file.jsx, file.entries]));
write("summary.json", JSON.stringify(summary, null, 2) + "\n");
console.log(JSON.stringify(summary, null, 2));
