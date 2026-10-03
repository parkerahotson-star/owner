export const meta = {
  name: 'fix-ui',
  description: 'Audit every ScreenGui on all device sizes using Roblox Studio MCP, fix the problems with ResponsiveUI attributes, then adversarially verify',
  whenToUse: 'Use when UI looks wrong on phones, tablets, consoles or some desktop sizes, or as the last step of any UI change. Needs Roblox Studio open in EDIT mode with the Studio MCP server connected. Optional args: {screenGuis: ["HUD"], devices: ["iPhone SE", ...], maxRounds: 3, playtest: false}.',
  phases: [
    { title: 'Preflight', detail: 'check Studio MCP + edit mode, install auditor, back up ScreenGuis, audit all devices' },
    { title: 'Fix', detail: 'one fixer per ScreenGui with issues, loops audit -> edit -> re-audit up to maxRounds' },
    { title: 'Verify', detail: 'independent skeptic per ScreenGui re-audits and reviews the edits for harm; one repair round on reject' },
    { title: 'Finish', detail: 'remove the temporary auditor module, optional play-mode spot check' },
  ],
}

// ---------------------------------------------------------------------------
// Args
// ---------------------------------------------------------------------------
const A = args && typeof args === 'object' ? args : {}
const ONLY_GUIS = Array.isArray(A.screenGuis) && A.screenGuis.length ? A.screenGuis.map(String) : null
const DEVICES = Array.isArray(A.devices) && A.devices.length ? A.devices.map(String) : null
const MAX_ROUNDS = Number.isFinite(Number(A.maxRounds)) && Number(A.maxRounds) >= 1 ? Math.min(6, Math.floor(Number(A.maxRounds))) : 3
const PLAYTEST = A.playtest === true

// ---------------------------------------------------------------------------
// Lua helpers (strings pasted into run_code / execute_luau)
// ---------------------------------------------------------------------------
function luaStr(s) {
  return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/\n/g, '\\n').replace(/\r/g, '\\r') + '"'
}
function luaList(xs) {
  return '{' + xs.map(luaStr).join(', ') + '}'
}
function luaOpts(guiNames, extra) {
  const parts = []
  if (guiNames && guiNames.length) parts.push('screenGuis = ' + luaList(guiNames))
  if (DEVICES) parts.push('devices = ' + luaList(DEVICES))
  parts.push('minSeverity = "warning"')
  if (extra) parts.push(extra)
  return '{ ' + parts.join(', ') + ' }'
}

const WORK = 'game:GetService("ServerStorage").FixUI_Work'

const TOOLS = `STUDIO ACCESS
The Roblox Studio MCP tools are deferred; load them with ToolSearch. First try the query "run_code" (the open-source studio-rust-mcp-server: run_code{command}, get_studio_mode, get_console_output, start_stop_play, run_script_in_play_mode). If that finds nothing, try "execute_luau" (Studio's built-in MCP server: call list_roblox_studios first and pass that studio_id on every call; execute_luau takes datamodel_type "Edit"; get_studio_state reports the mode). The server name prefix varies (e.g. mcp__Roblox_Studio__run_code), so use whatever ToolSearch returns. Below, "RUN" means: run this Luau in the EDIT DataModel with that tool. print() output comes back in the tool result.
- Never start or stop play mode (other agents share this Studio; run_code does not work during play).
- If a RUN fails because Studio is disconnected or in play mode, do not retry in a loop: stop and say so in your result (notes / critique).
- Do not edit files in the repo. Studio edits only, and only where your instructions allow.
- Wrap risky reads in pcall. Keep printed output compact (JSON via HttpService:JSONEncode, no giant dumps).
- Read src/tools/UIAudit.luau and the header of src/client/ResponsiveUI.client.luau from the repo before you start if you need to understand the issue kinds or the attribute rules.`

// How every agent loads the auditor: the preflight installs it as a ModuleScript; fall back to pasting the source.
const AUDIT_LOAD = `LOADING THE AUDITOR
Preferred (installed by the preflight step):
    local UIAudit = require(${WORK}.UIAudit)
If that errors (module missing), read src/tools/UIAudit.luau from the repo and paste its full source into the command as:
    local UIAudit = (function()
    <entire file contents>
    end)()
(The wrapper must surround the WHOLE file, which ends with "return UIAudit". Do not paste it as a separate statement before your code.)`

const RESPONSIVE_RULES = `RESPONSIVEUI RULES (this project's per-device system, see CLAUDE.md)
- Per-device values are attributes named <Group>_<Property> on the object, e.g. Phone_Size (UDim2), Touch_TextSize (number), PhonePortrait_Position (UDim2), Console_Visible (boolean), Tablet_AnchorPoint (Vector2). Overrides work on any object inside the ScreenGui, including constraints and layouts (e.g. Touch_MinSize on a UISizeConstraint, Phone_CellSize on a UIGridLayout).
- Groups apply in this order, later wins: Portrait|Landscape, then Touch (Phone+Tablet), then Phone|Tablet|Desktop|Console, then device+orientation (PhonePortrait, TabletLandscape, ...). Before adding an override, check that a later group on the same object does not already mask it; if one does, edit that one instead.
- The property's own Studio value is the default for every device with no matching override. The attribute TYPE must equal the property type (UDim2 for Size/Position, Vector2 for AnchorPoint, number for TextSize, boolean for Visible, EnumItem for Enum properties, e.g. SetAttribute("Touch_AutomaticSize", Enum.AutomaticSize.Y)). Read the value back with GetAttribute after setting it; if SetAttribute rejected the type, change the property another way.
- ScreenGui auto scaling: attributes ReferenceResolution (Vector2), MinScale, MaxScale, ScaleMultiplier and <Group>_ScaleMultiplier (numbers) create a UIScale named "ResponsiveScale" = min(vp.X/ref.X, vp.Y/ref.Y) * multiplier, clamped. Use it ONLY for ScreenGuis laid out mostly in Offset pixels; never on Scale-sized UI (it would scale twice) and never add another UIScale directly in that ScreenGui.
- Attributes set in edit mode persist in the place; ResponsiveUI applies them at runtime.`

const FIX_RULES = `HOW TO FIX
- Decide per issue whether it is device-specific or universal. If the same problem shows on EVERY audited device (including the Desktop ones), change the base property. Otherwise add ResponsiveUI override attributes for the narrowest group that covers exactly the failing devices (Touch for phone+tablet, Phone, PhonePortrait, Console, ...). Desktop must keep its current look unless Desktop itself has the issue.
- Good tools, roughly in order of preference: Scale-based Size/Position instead of raw Offset; AnchorPoint + Position fixes for offscreen; UIAspectRatioConstraint for shapes that distort; UISizeConstraint for minimum touch sizes; UITextSizeConstraint + TextScaled, or TextWrapped, or a bigger box for text_overflow; Touch_/Console_ TextSize overrides for text_too_small; UIListLayout/UIGridLayout padding or CellSize tweaks for overlaps; ReferenceResolution only for Offset-built ScreenGuis.
- unsafe_area: keep interactive UI on ScreenInsets = CoreUISafeInsets (the default) and IgnoreGuiInset = false; only full-bleed non-interactive backgrounds may use None/DeviceSafeInsets. Move elements away from the top strip (topbar) and the console TV-safe margin rather than shrinking them.
- touch_target: grow the button (or its hit area) to at least ~44x44 effective pixels on Phone/Tablet (Touch_Size, or a UISizeConstraint whose base MinSize keeps the current desktop size and whose Touch_MinSize attribute is Vector2.new(44, 44); a plain MinSize would also change Desktop). Never shrink a touch target, and keep sibling buttons in the same row/grid consistently sized.
- bad_override: fix the attribute name or value type (e.g. "Phone_size" -> "Phone_Size", number -> UDim2); delete a bad override only if it is clearly a typo duplicate.
- NEVER "fix" an issue by hiding (Visible=false, Transparency=1), deleting, reparenting out of the ScreenGui, setting Enabled=false, renaming, or shrinking content below readable/tappable limits. Do not edit scripts. Do not touch any other ScreenGui, StarterGui's own properties (e.g. ScreenOrientation), the ResponsiveUI script, or ServerStorage.FixUI_Work.
- Script check: before overriding a property, look for code that also drives it. Grep the repo (src/ and any *.lua/*.luau) for the element's Name, and RUN a search of in-place scripts:
    local hits = {}
    for _, svc in {"Workspace","ReplicatedStorage","ReplicatedFirst","ServerScriptService","ServerStorage","StarterGui","StarterPlayer","StarterPack"} do
      local ok, s = pcall(function() return game:GetService(svc) end)
      if ok then for _, d in s:GetDescendants() do
        if d:IsA("LuaSourceContainer") then
          local ok2, src = pcall(function() return d.Source end)
          if ok2 and string.find(src, "ELEMENT_NAME", 1, true) then table.insert(hits, d:GetFullName()) end
        end end end
    end
    print(table.concat(hits, "\\n"))
  If a script tweens/sets that property (Position for slide-in panels, Size for pop animations, Visible for menus), do NOT add an override for that property (ResponsiveUI re-applies it on device change and fights the script). Fix it another way (constraint, parent container, UIScale on a wrapper Frame, AnchorPoint) or mark the issue accepted.
- Some findings are intentional or approximations (e.g. a panel parked offscreen that a script tweens in, a decorative image deliberately cropped by ClipsDescendants, list positions the auditor only estimated). Put those in "accepted" with a concrete reason instead of changing anything.
- Make edits with RUN calls, then call pcall(function() game:GetService("ChangeHistoryService"):SetWaypoint("fix-ui: <gui name>") end) so the user can undo them.
- Paths: the auditor reports paths relative to StarterGui, e.g. "HUD.Panel.Buy" -> game:GetService("StarterGui").HUD.Panel.Buy. Names may contain dots, and siblings that share a name get "#2", "#3"... ("HUD.TextButton#2" = 2nd child named TextButton). Always resolve paths with the auditor: load UIAudit (see LOADING THE AUDITOR) and call UIAudit.find(path); it returns nil if the path no longer exists.
- Record EVERY change: path, kind ("attribute" or "property"), name (attribute or property name), old and new values as short strings (old = "nil" when the attribute did not exist), and the reason (which issue/devices it fixes).`

const ISSUE = {
  type: 'object',
  properties: {
    device: { type: 'string' },
    path: { type: 'string' },
    kind: { type: 'string' },
    severity: { type: 'string' },
    detail: { type: 'string' },
  },
  required: ['path', 'kind', 'detail'],
}
const CHANGE = {
  type: 'object',
  properties: {
    path: { type: 'string' },
    kind: { type: 'string', enum: ['attribute', 'property'] },
    name: { type: 'string' },
    old: { type: 'string' },
    new: { type: 'string' },
    reason: { type: 'string' },
  },
  required: ['path', 'kind', 'name', 'old', 'new', 'reason'],
}
const ACCEPTED = {
  type: 'object',
  properties: { path: { type: 'string' }, kind: { type: 'string' }, devices: { type: 'string' }, reason: { type: 'string' } },
  required: ['path', 'kind', 'reason'],
}

const PREFLIGHT_SCHEMA = {
  type: 'object',
  properties: {
    ok: { type: 'boolean', description: 'false if Studio MCP is unreachable, Studio is not in edit mode, or the auditor failed' },
    stopReason: { type: 'string', description: 'clear user-facing message when ok=false' },
    server: { type: 'string', description: 'which MCP flavour and execution tool was used, e.g. "rust run_code" or "builtin execute_luau"' },
    auditorInstalled: { type: 'boolean' },
    devices: { type: 'array', items: { type: 'string' } },
    approximations: { type: 'array', items: { type: 'string' } },
    backedUp: { type: 'array', items: { type: 'string' } },
    screenGuis: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          name: { type: 'string' },
          errors: { type: 'number' },
          warnings: { type: 'number' },
          kinds: { type: 'string', description: 'kind=count summary, e.g. "offscreen=4, touch_target=2"' },
          sample: { type: 'array', items: { type: 'string' } },
        },
        required: ['name', 'errors', 'warnings'],
      },
    },
  },
  required: ['ok', 'screenGuis'],
}

const FIX_SCHEMA = {
  type: 'object',
  properties: {
    changes: { type: 'array', items: CHANGE },
    accepted: { type: 'array', items: ACCEPTED },
    remainingErrors: { type: 'number', description: 'errors left after your edits, excluding accepted ones' },
    remainingWarnings: { type: 'number', description: 'warnings left after your edits, excluding accepted ones' },
    remainingIssues: { type: 'array', items: ISSUE, description: 'up to 25 unresolved, non-accepted issues' },
    notes: { type: 'string' },
  },
  required: ['changes', 'remainingErrors', 'remainingWarnings'],
}

const VERIFY_SCHEMA = {
  type: 'object',
  properties: {
    verdict: { type: 'string', enum: ['approve', 'reject'] },
    critique: { type: 'string', description: 'concrete, actionable problems for a repair round (empty when approving)' },
    problems: {
      type: 'array',
      items: {
        type: 'object',
        properties: { path: { type: 'string' }, problem: { type: 'string' }, suggestedFix: { type: 'string' } },
        required: ['path', 'problem'],
      },
    },
    auditErrors: { type: 'number', description: 'raw error count from your own audit run' },
    auditWarnings: { type: 'number', description: 'raw warning count from your own audit run' },
    openErrors: { type: 'number', description: 'errors still open, excluding accepted issues you agree are legitimate' },
    openWarnings: { type: 'number', description: 'warnings still open, excluding accepted issues you agree are legitimate' },
    unreportedChanges: { type: 'array', items: { type: 'string' }, description: 'differences vs the backup that the fixer did not report' },
    remainingIssues: { type: 'array', items: ISSUE, description: 'up to 25 open issues (not legitimately accepted)' },
    illegitimateAccepts: { type: 'array', items: { type: 'string' }, description: 'accepted issues you think are real and fixable' },
  },
  required: ['verdict', 'auditErrors', 'auditWarnings', 'openErrors', 'openWarnings'],
}

// Read-only diff of the live ScreenGui against the preflight backup (catches unreported edits).
function diffSnippet(name) {
  return `    local NAME = ${luaStr(name)}
    local work = game:GetService("ServerStorage"):FindFirstChild("FixUI_Work")
    local orig = work and work:FindFirstChild("Backup") and work.Backup:FindFirstChild(NAME)
    local cur = game:GetService("StarterGui"):FindFirstChild(NAME)
    if not orig or not cur then print("diff unavailable: backup=" .. tostring(orig ~= nil) .. " live=" .. tostring(cur ~= nil)) return end
    local PROPS = {"Size","Position","AnchorPoint","Visible","Enabled","ZIndex","LayoutOrder","Rotation","ClipsDescendants","AutomaticSize","BackgroundTransparency","Transparency","ImageTransparency","TextTransparency","TextSize","TextScaled","TextWrapped","Text","ScreenInsets","IgnoreGuiInset","Scale","AspectRatio","AspectType","DominantAxis","MinSize","MaxSize","MinTextSize","MaxTextSize","Padding","CellSize","CellPadding","PaddingLeft","PaddingRight","PaddingTop","PaddingBottom","CanvasSize","FillDirection","HorizontalAlignment","VerticalAlignment"}
    local function key(inst, root) local p = {} while inst and inst ~= root do table.insert(p, 1, inst.Name .. "<" .. inst.ClassName .. ">") inst = inst.Parent end return table.concat(p, "/") end
    local function index(root) local t = { [""] = root } for _, d in root:GetDescendants() do local k = key(d, root) while t[k] do k ..= "+" end t[k] = d end return t end
    local function read(inst, prop) local ok, v = pcall(function() return inst[prop] end) if ok and typeof(v) ~= "Instance" then return v end return nil end
    local a, b, out = index(orig), index(cur), {}
    for k, o in a do
      local c = b[k]
      if not c then table.insert(out, "REMOVED " .. k) else
        for _, p in PROPS do local x, y = read(o, p), read(c, p) if x ~= y then table.insert(out, k .. " ." .. p .. ": " .. tostring(x) .. " -> " .. tostring(y)) end end
        local ao, ac = o:GetAttributes(), c:GetAttributes()
        for n, v in ac do if ao[n] ~= v then table.insert(out, k .. " @" .. n .. ": " .. tostring(ao[n]) .. " -> " .. typeof(v) .. " " .. tostring(v)) end end
        for n, v in ao do if ac[n] == nil then table.insert(out, k .. " @" .. n .. " removed (was " .. tostring(v) .. ")") end end
      end
    end
    for k in b do if not a[k] then table.insert(out, "ADDED " .. k) end end
    print(#out .. " difference(s)") print(table.concat(out, "\\n"))`
}

function auditOneGui(name) {
  return `RUN this to audit only this ScreenGui (full JSON report; each issue is one element + kind with screenGui, device (most cramped), devices (every failing device), path, kind, severity, detail, rect, hint; kind "offscreen_parked" = likely parked offscreen for a tween-in, usually accept rather than move):
    <load UIAudit as described above>
    print(UIAudit.runJSON(${luaOpts([name], 'maxIssues = 300')}))`
}

function compactChanges(changes) {
  return changes.map(c => `- ${c.path} ${c.kind} ${c.name}: ${c.old} -> ${c.new} (${c.reason})`).join('\n') || '(none)'
}
function compactAccepted(accepted) {
  return (accepted || []).map(a => `- ${a.path} ${a.kind} ${a.devices || ''}: ${a.reason}`).join('\n') || '(none)'
}
// Accepted issues accumulate across rounds; a later round may re-list or refine one (same path+kind wins).
function mergeAccepted(history) {
  const m = new Map()
  for (const h of history) for (const a of h.accepted || []) m.set(a.path + '|' + a.kind, a)
  return [...m.values()]
}
function compactIssues(issues) {
  return (issues || []).slice(0, 25).map(i => `- [${i.severity || '?'}] ${i.device || '?'} ${i.path} ${i.kind}: ${i.detail}`).join('\n') || '(none)'
}

// ---------------------------------------------------------------------------
// 1. Preflight
// ---------------------------------------------------------------------------
phase('Preflight')
const pre = await agent(`You are the preflight step of the fix-ui workflow for a Roblox project (repo = current directory).

${TOOLS}

STEPS
1. Load the Studio MCP tools. If none load or a call fails because Studio is not connected, return ok=false with stopReason explaining: open the place in Roblox Studio, make sure the MCP plugin/server is enabled and connected to Claude Code, then retry.
2. Check the mode (get_studio_mode must be "stop", or get_studio_state must say edit). If Studio is playing/running, return ok=false, stopReason "Stop the playtest in Studio (edit mode is required), then run fix-ui again." Do not stop it yourself.
3. Install the auditor: read src/tools/UIAudit.luau from the repo (if the file does not exist, return ok=false with that reason). RUN code that gets Folder ServerStorage.FixUI_Work, creating it only if missing (NEVER destroy or replace an existing FixUI_Work: it may hold the user's backups from an earlier run), and inside it creates or replaces a ModuleScript named "UIAudit" whose Source is the file's exact contents. The source is long; put it in the Luau command as a long-bracket string with enough = signs that it cannot collide with anything inside the file (e.g. [=====[ ... ]=====], check the file does not contain that closing sequence). Then RUN: local UIAudit = require(${WORK}.UIAudit) print(type(UIAudit.run)). If require or installing fails, set auditorInstalled=false and use the paste fallback below for the remaining steps.
   Then validate the arguments. RUN: <load UIAudit> local names = {} for _, d in UIAudit.DEVICES do table.insert(names, d.name) end print(table.concat(names, " | "))${DEVICES ? `
   Requested devices: ${DEVICES.join(', ')}. If any requested name is not in UIAudit.DEVICES (exact match), return ok=false with stopReason listing the unknown names and every valid device name.` : ''}${ONLY_GUIS ? `
   Requested ScreenGuis: ${ONLY_GUIS.join(', ')}. RUN a check that each exists as a ScreenGui directly under StarterGui; if any is missing, return ok=false with stopReason listing the missing names and the ScreenGuis that do exist.` : ''}
4. Set an undo waypoint: pcall(function() game:GetService("ChangeHistoryService"):SetWaypoint("Before fix-ui") end).
5. Audit everything and summarise IN STUDIO (so you don't pull the full report into context). RUN:
    <load UIAudit>
    local opts = ${luaOpts(ONLY_GUIS, 'maxIssues = 100000')}
    local report = UIAudit.run(opts)
    local by, order = {}, {}
    for _, i in report.issues do
      local gk = tostring(i.screenGui or "?")
      local g = by[gk]
      if not g then g = { name = gk, errors = 0, warnings = 0, kindCounts = {}, sample = {} }; by[gk] = g; table.insert(order, g) end
      if i.severity == "error" then g.errors += 1 elseif i.severity == "warning" then g.warnings += 1 end
      g.kindCounts[i.kind] = (g.kindCounts[i.kind] or 0) + 1
      if #g.sample < 12 then table.insert(g.sample, tostring(i.device) .. " | " .. tostring(i.path) .. " | " .. tostring(i.kind) .. " | " .. tostring(i.detail)) end
    end
    for _, g in order do local parts = {} for k, n in g.kindCounts do table.insert(parts, k .. "=" .. n) end g.kinds = table.concat(parts, ", ") g.kindCounts = nil end
    print(game:GetService("HttpService"):JSONEncode({ devices = report.devices, approximations = report.approximations, truncated = report.truncated, guis = order }))
   ${AUDIT_LOAD.split('\n').join('\n   ')}
   If the auditor errors, return ok=false with the error text in stopReason.
6. If there are issues: back up every ScreenGui that has issues. RUN code that, inside ${WORK}: if a Folder "Backup" already exists (from an earlier fix-ui run), destroys any old "Backup_previous" and renames "Backup" to "Backup_previous"; then creates a new Folder "Backup" and puts game:GetService("StarterGui")[name]:Clone() in it for each such ScreenGui (skip and report any that fail to clone). Report their names in backedUp.
   If there are NO issues: destroy ${WORK}.UIAudit (leave any existing Backup folder alone) and return ok=true with an empty screenGuis list.
7. Return ok=true, server, auditorInstalled, devices, approximations (include "report truncated by N" if truncated > 0), backedUp, and screenGuis = one entry per ScreenGui WITH issues: name, errors, warnings, kinds, sample.${ONLY_GUIS ? `\n\nOnly the ScreenGuis ${ONLY_GUIS.join(', ')} are in scope.` : ''}${DEVICES ? `\nDevices restricted to: ${DEVICES.join(', ')}.` : ''}`,
  { label: 'preflight', phase: 'Preflight', schema: PREFLIGHT_SCHEMA })

if (!pre) {
  return { ok: false, message: 'Preflight agent failed. Check that Roblox Studio is open in edit mode with the MCP server connected, then run fix-ui again.' }
}
if (!pre.ok) {
  log('Stopped: ' + (pre.stopReason || 'preflight failed'))
  return { ok: false, message: pre.stopReason || 'Preflight failed.' }
}

const targets = (pre.screenGuis || [])
  .filter(g => g && g.name && (g.errors || 0) + (g.warnings || 0) > 0)
  .filter(g => !ONLY_GUIS || ONLY_GUIS.includes(g.name))
  .filter((g, i, all) => all.findIndex(o => o.name === g.name) === i)
if (!targets.length) {
  log('Audit is clean on every device')
  return {
    ok: true,
    message: 'No warnings or errors on any audited device. Nothing to fix.',
    devices: pre.devices || [],
    approximations: pre.approximations || [],
  }
}
log(`${targets.length} ScreenGui(s) need work: ` + targets.map(g => `${g.name} (${g.errors}E/${g.warnings}W)`).join(', '))
const DEVICE_LINE = `Audited devices: ${(pre.devices || []).join(', ') || 'all built-in profiles'}.`
const APPROX_LINE = (pre.approximations || []).length ? `Auditor approximations (findings that depend on these may be false positives): ${(pre.approximations || []).join('; ')}` : ''

// ---------------------------------------------------------------------------
// 2-3. Fix loop then verify, pipelined per ScreenGui
// ---------------------------------------------------------------------------
function fixPrompt(gui, round, history, critique) {
  const prior = history.length
    ? `PREVIOUS ROUNDS (already applied in Studio; build on them, revert one only if it caused harm):\n${compactChanges(history.flatMap(h => h.changes || []))}\nStill open after the last round:\n${compactIssues(history[history.length - 1].remainingIssues)}\nAlready accepted in earlier rounds (keep them in your "accepted" list unless the critique says otherwise, and keep excluding them from remainingErrors/remainingWarnings):\n${compactAccepted(mergeAccepted(history))}`
    : `Preflight summary for this ScreenGui: ${gui.errors} errors, ${gui.warnings} warnings (${gui.kinds || ''}).\nSample:\n${(gui.sample || []).map(s => '- ' + s).join('\n')}`
  return `You are fixing the Roblox ScreenGui "${gui.name}" (game.StarterGui["${gui.name}"]) so it is correct on every device. Round ${round}. Work ONLY on this ScreenGui. Other agents are editing other ScreenGuis in the same Studio at the same time.

${TOOLS}

${AUDIT_LOAD}

${auditOneGui(gui.name)}

${DEVICE_LINE}
${APPROX_LINE}

${RESPONSIVE_RULES}

${FIX_RULES}
${critique ? `\nA REVIEWER REJECTED THE PREVIOUS EDITS. Address every point below first (revert or redo edits as needed):\n${critique}\n` : ''}
${prior}

PROCESS
1. Audit this ScreenGui (command above) and read the issues. Inspect the relevant objects (properties, attributes, children, constraints, layouts) with RUN before editing.
2. Make the edits. Group related issues: one root cause (e.g. an Offset-sized panel) often explains many issues across devices.
3. Set the waypoint, then re-audit and return: every change you made this round, accepted issues with reasons, remainingErrors/remainingWarnings (not counting accepted ones) and up to 25 remainingIssues.`
}

function verifyPrompt(gui, changes, accepted) {
  return `You are an adversarial reviewer for UI edits an automated fixer made to the Roblox ScreenGui "${gui.name}" (game.StarterGui["${gui.name}"]). Assume the fixer cut corners. Do NOT edit anything in Studio (read-only RUN calls only).

${TOOLS}

${AUDIT_LOAD}

${auditOneGui(gui.name)}

${DEVICE_LINE}
${APPROX_LINE}

${RESPONSIVE_RULES}

CHANGES THE FIXER REPORTS:
${compactChanges(changes)}

ISSUES THE FIXER MARKED AS ACCEPTED (not fixed):
${compactAccepted(accepted)}

CHECK
1. Re-run the audit yourself; report the raw auditErrors/auditWarnings, then openErrors/openWarnings excluding accepted issues you agree are legitimate, and up to 25 remainingIssues (open ones only). Do not trust the fixer's counts.
2. Read the current values of every changed object in Studio and confirm the reported changes are really there and the attribute types match the property types. Then RUN this read-only diff against the preflight backup and list in unreportedChanges every difference the fixer did not report (judge those for harm too):
${diffSnippet(gui.name)}
3. Look for harm: content hidden or made invisible/transparent; elements deleted or moved out of the ScreenGui; Desktop layout changed although Desktop had no issue (a base property change that should have been an override); touch targets or text shrunk; sibling buttons in the same row/grid now inconsistently sized or misaligned; overrides on properties a script or tween also drives (grep the repo and search in-place script Source for the element names, as described below); a later-group override masking a new one; ReferenceResolution added to Scale-based UI; a second UIScale directly in the ScreenGui; ScreenInsets/IgnoreGuiInset changes that put buttons under the topbar.
   In-place script search: RUN a loop over Workspace, ReplicatedStorage, ReplicatedFirst, ServerScriptService, ServerStorage, StarterGui, StarterPlayer, StarterPack descendants that are LuaSourceContainers, pcall-reading .Source and printing the full names of scripts whose source contains the element name (string.find(src, name, 1, true)).
4. Judge the accepted issues: list in illegitimateAccepts any that are real and fixable.
5. verdict = "reject" if you found any harm (including harmful unreported changes), an open error that is not legitimately accepted, or an illegitimate accept that matters; otherwise "approve". critique must be concrete and actionable (object path, what is wrong, what to do).`
}

async function fixLoop(gui) {
  const history = []
  let prevOpen = null
  for (let round = 1; round <= MAX_ROUNDS; round++) {
    const r = await agent(fixPrompt(gui, round, history, null), {
      label: `fix ${gui.name} r${round}`,
      phase: 'Fix',
      schema: FIX_SCHEMA,
    })
    if (!r) break
    history.push(r)
    const open = (r.remainingErrors || 0) + (r.remainingWarnings || 0)
    log(`${gui.name} round ${round}: ${(r.changes || []).length} change(s), ${open} open`)
    if (open === 0) break
    if (!(r.changes || []).length) {
      log(`${gui.name}: no progress in round ${round}, stopping its fix loop`)
      break
    }
    if (prevOpen !== null && open >= prevOpen) {
      log(`${gui.name}: open count did not drop in round ${round} (${prevOpen} -> ${open}), stopping its fix loop`)
      break
    }
    prevOpen = open
  }
  const last = history[history.length - 1]
  if (last && history.length === MAX_ROUNDS && (last.remainingErrors || 0) + (last.remainingWarnings || 0) > 0) {
    log(`${gui.name}: issues still open after ${MAX_ROUNDS} round(s), handing to the reviewer`)
  }
  return { gui, history }
}

async function verifyStage(res) {
  const gui = res.gui
  const history = res.history.slice()
  const allChanges = () => history.flatMap(h => h.changes || [])
  const lastAccepted = () => mergeAccepted(history)

  if (!history.length) {
    return {
      name: gui.name,
      changes: [],
      accepted: [],
      remainingErrors: gui.errors,
      remainingWarnings: gui.warnings,
      remaining: (gui.sample || []).map(s => ({ path: gui.name, kind: 'preflight-sample', detail: String(s) })),
      verdict: 'not-fixed',
      repaired: false,
      critique: 'All fix agents failed.',
      problems: [],
    }
  }

  let v = await agent(verifyPrompt(gui, allChanges(), lastAccepted()), { label: `verify ${gui.name}`, phase: 'Verify', schema: VERIFY_SCHEMA })
  let repaired = false
  if (v && v.verdict === 'reject') {
    log(`${gui.name}: reviewer rejected, running one repair round`)
    const critique = [v.critique || '']
      .concat((v.problems || []).map(p => `- ${p.path}: ${p.problem}${p.suggestedFix ? ' -> ' + p.suggestedFix : ''}`))
      .concat((v.illegitimateAccepts || []).map(s => `- accepted but should be fixed: ${s}`))
      .join('\n')
    const r = await agent(fixPrompt(gui, history.length + 1, history, critique), {
      label: `repair ${gui.name}`,
      phase: 'Fix',
      schema: FIX_SCHEMA,
    })
    if (r) {
      history.push(r)
      repaired = true
      const v2 = await agent(verifyPrompt(gui, allChanges(), lastAccepted()), { label: `re-verify ${gui.name}`, phase: 'Verify', schema: VERIFY_SCHEMA })
      // A failed re-verify must not leave the stale pre-repair verdict in place.
      v = v2 || null
    }
  }

  const last = history[history.length - 1]
  const remaining = v ? v.remainingIssues || [] : last.remainingIssues || []
  return {
    name: gui.name,
    changes: allChanges(),
    accepted: lastAccepted(),
    remainingErrors: v ? v.openErrors : last.remainingErrors,
    remainingWarnings: v ? v.openWarnings : last.remainingWarnings,
    rawAuditErrors: v ? v.auditErrors : undefined,
    rawAuditWarnings: v ? v.auditWarnings : undefined,
    unreportedChanges: v ? v.unreportedChanges || [] : [],
    remaining,
    verdict: v ? v.verdict : repaired ? 'unverified-after-repair' : 'unverified',
    repaired,
    critique: v && v.verdict === 'reject' ? v.critique || '' : '',
    problems: v && v.verdict === 'reject' ? v.problems || [] : [],
  }
}

phase('Fix')
const results = (await pipeline(targets, gui => fixLoop(gui), res => verifyStage(res))).filter(Boolean)

// ---------------------------------------------------------------------------
// 4. Finish: cleanup (+ optional playtest)
// ---------------------------------------------------------------------------
phase('Finish')
const finish = await agent(`Final step of the fix-ui workflow for this Roblox project.

${TOOLS}

1. RUN: local w = game:GetService("ServerStorage"):FindFirstChild("FixUI_Work") if w and w:FindFirstChild("UIAudit") then w.UIAudit:Destroy() end
   Keep ServerStorage.FixUI_Work.Backup (it is the user's undo copy). Then set a waypoint: pcall(function() game:GetService("ChangeHistoryService"):SetWaypoint("After fix-ui") end).
${PLAYTEST ? `2. PLAYTEST SPOT CHECK (report only, change nothing). You are the only agent using Studio now, so play mode is allowed.
   Find the ResponsiveUI LocalScript under StarterPlayer.StarterPlayerScripts. For each of "Phone", "Tablet", "Console" (and Desktop with no ForceDevice): in edit mode set its attribute ForceDevice to that value (ForceOrientation "Landscape"), start a playtest, then:
   - with the built-in server: execute_luau with datamodel_type "Client" to read Players.LocalPlayer.PlayerGui ScreenGui descendants' AbsolutePosition/AbsoluteSize vs workspace.CurrentCamera.ViewportSize for elements outside the viewport, and use screen_capture if it is available;
   - with the rust server: use run_script_in_play_mode (server-side) and get_console_output; at least collect every "[ResponsiveUI]" warning (bad override names/types).
   Stop the playtest after each device. Note: ForceDevice only switches which overrides apply; the viewport stays the Studio window size, so judge positions with that in mind.
   ALWAYS finish by removing the ForceDevice/ForceOrientation attributes you set (set to nil) and making sure Studio is back in edit mode.
   Return a short text report of what you saw per device.` : '2. Do not start a playtest.'}
Return a short plain-text summary.`,
  PLAYTEST ? { label: 'cleanup + playtest', phase: 'Finish' } : { label: 'cleanup', phase: 'Finish', effort: 'low' })

// ---------------------------------------------------------------------------
// Report
// ---------------------------------------------------------------------------
const doneNames = new Set(results.map(r => r.name))
const lost = targets.filter(g => !doneNames.has(g.name)).map(g => g.name)
const unresolved = []
for (const r of results) {
  for (const i of r.remaining || []) unresolved.push(Object.assign({ screenGui: r.name }, i))
  const openCount = (r.remainingErrors || 0) + (r.remainingWarnings || 0)
  if (openCount > (r.remaining || []).length) {
    unresolved.push({ screenGui: r.name, path: r.name, kind: 'summary', detail: `${openCount} audit issue(s) still open (${(r.remaining || []).length} listed); re-run the auditor for details` })
  }
  for (const p of r.problems || []) unresolved.push({ screenGui: r.name, path: p.path, kind: 'review', detail: p.problem })
  if (r.verdict === 'unverified' || r.verdict === 'unverified-after-repair') {
    unresolved.push({ screenGui: r.name, path: r.name, kind: 'review', detail: `edits were not independently reviewed (${r.verdict}); check them by hand or re-run fix-ui on this ScreenGui` })
  } else if (r.verdict === 'reject' && !(r.problems || []).length) {
    unresolved.push({ screenGui: r.name, path: r.name, kind: 'review', detail: 'reviewer rejected: ' + (r.critique || '(no critique given)') })
  }
}
for (const name of lost) unresolved.push({ screenGui: name, path: name, kind: 'workflow', detail: 'fix/verify agents failed for this ScreenGui' })

const totalChanges = results.reduce((n, r) => n + (r.changes || []).length, 0)
log(`Done: ${totalChanges} change(s) across ${results.length} ScreenGui(s); ${unresolved.length} unresolved item(s)`)

return {
  ok: true,
  devices: pre.devices || [],
  approximations: pre.approximations || [],
  perScreenGui: results.map(r => ({
    name: r.name,
    verdict: r.verdict,
    repaired: r.repaired,
    remainingErrors: r.remainingErrors,
    remainingWarnings: r.remainingWarnings,
    changes: r.changes,
    accepted: r.accepted,
    unreportedChanges: r.unreportedChanges,
    remaining: r.remaining,
    critique: r.critique,
  })),
  unresolved,
  finish: finish || 'cleanup agent failed; delete ServerStorage.FixUI_Work.UIAudit by hand',
  howToUndo: [
    'All edits were made in edit mode and are not saved until you save/publish the place.',
    'Quick undo: Ctrl+Z in Studio back to the "Before fix-ui" waypoint (each MCP call is one undo step, so this can take many presses).',
    'Full restore of the original ScreenGuis (backed up: ' + ((pre.backedUp || []).join(', ') || 'none') + '): run in the Command Bar or via run_code:',
    'local SG = game:GetService("StarterGui") for _, b in game:GetService("ServerStorage").FixUI_Work.Backup:GetChildren() do local cur = SG:FindFirstChild(b.Name) if cur then cur:Destroy() end b:Clone().Parent = SG end',
    'If an earlier fix-ui run left a backup, it was moved to ServerStorage.FixUI_Work.Backup_previous (the state before that run).',
    'When you are happy with the result, delete ServerStorage.FixUI_Work so the backup copies are not saved with the place.',
  ].join('\n'),
}
