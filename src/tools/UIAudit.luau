--[[
	UIAudit: static, per-device audit of ScreenGui layouts.

	It computes where every GuiObject lands on each simulated device, from the
	properties alone (Position, Size, AnchorPoint, UIScale, UIPadding,
	constraints, layouts) plus the ResponsiveUI attribute overrides
	(src/client/ResponsiveUI.client.luau), and reports problems with a fix
	phrased as a ResponsiveUI attribute. Studio's AbsoluteSize only reflects the
	current Studio window, so it can't be used for this.

	────────────────────────────────────────────────────────────────────────────
	HOW TO RUN (Roblox Studio MCP, edit mode, no Play needed)
	────────────────────────────────────────────────────────────────────────────
	This file must not use require() or script-relative paths. Paste the WHOLE
	file into the MCP run_code tool (or execute_luau with datamodel_type "Edit"
	on Studio's built-in MCP server), wrapped like this:

	    local UIAudit = (function()
	        <contents of src/tools/UIAudit.luau>
	    end)()
	    print(UIAudit.runText({ screenGuis = { "HUD" } }))   -- compact text, best for reading
	    -- or: print(UIAudit.runJSON())                     -- full report as JSON

	Workflow: audit, then fix by setting attributes through run_code
	(e.g. game.StarterGui.HUD.Panel:SetAttribute("Phone_Size", UDim2.fromScale(0.9, 0.3))),
	then audit again until it's clean. Start with one ScreenGui at a time.

	────────────────────────────────────────────────────────────────────────────
	API
	────────────────────────────────────────────────────────────────────────────
	UIAudit.run(options?)     -> report table
	UIAudit.runJSON(options?) -> JSON string of the report (plain numbers/strings only);
	                             maxIssues defaults to 60 here to stay under ~10k tokens
	UIAudit.runText(options?) -> one line per issue, plus a summary line
	UIAudit.format(report)    -> the same text for a report you already have
	UIAudit.find(path, root?) -> the Instance for a report path (handles "#n" and dotted names)
	UIAudit.DEVICES           -> built-in device profiles
	UIAudit.CONSTANTS         -> thresholds (edit them before calling run)

	options = {
	    root        = Instance?,   default StarterGui. It can also be one ScreenGui or one
	                               GuiObject (then only issues under it are reported).
	    screenGuis  = { string }?, only audit ScreenGuis with these names
	    devices     = { string | DeviceProfile }?, built-in names (see DEVICES below), a
	                               device type ("Phone", "Tablet", "Desktop", "Console")
	                               meaning all built-ins of that type, or custom profiles.
	                               Default: all built-ins, skipping portrait profiles when
	                               StarterGui.ScreenOrientation is landscape-only (and
	                               landscape phone/tablet profiles when it is Portrait).
	    maxIssues   = number?,     default 150 (60 for runJSON); report.truncated = how many
	                               were dropped. Every ScreenGui and device keeps at least one
	                               entry; the rest is picked round-robin, most severe first.
	    minSeverity = "info" | "warning" | "error"?, default "warning"
	    perDevice   = boolean?,    one entry per device instead of one per element + kind
	    includeRects = boolean?,   also return report.rects[device][path] = { x, y, w, h }
	                               for every visible GuiObject (big; use with a filter)
	}

	DeviceProfile = {
	    name       = string,
	    size       = Vector2,      FULL screen size in Roblox UI units (points on iOS)
	    device     = "Phone" | "Tablet" | "Desktop" | "Console",
	    safeInsets = { left, top, right, bottom }?  notch / home-bar insets, default 0
	    topbar     = number?,      topbar height, default CONSTANTS.TOPBAR_HEIGHT
	    tvSafe     = number?,      fraction per edge, default 0.05 on Console
	}
	The orientation and the ResponsiveUI groups come from the device-safe
	viewport (what Camera.ViewportSize would be), exactly like ResponsiveUI.

	report = {
	    devices      = { names },
	    screenGuis   = { { name, issueCount } },
	    issues       = { { screenGui, device, devices, path, kind, severity, detail,
	                       rect = { x, y, w, h }, hint } },   (+ alsoOn with perDevice)
	    counts       = { error, warning, info },
	    truncated    = number,
	    truncatedByScreenGui = { [name] = n }?, truncatedByDevice = { [device] = n }?
	                   (only when truncated > 0: re-run with screenGuis / devices to see them)
	    approximations = { strings },  what was estimated for THIS run
	    notes        = { strings },    unknown device names, instances that errored, etc.
	}
	Paths are relative to StarterGui, starting with the ScreenGui name, e.g.
	"HUD.Panel.Buy". When siblings share a name, the 2nd, 3rd... get "#2", "#3"
	("HUD.TextButton#2" = the 2nd child named TextButton in GetChildren order);
	UIAudit.find(path) resolves them. Rects are in screen units for that device,
	origin at the top-left of the full screen (including the notch area).
	By default each element + kind is ONE entry: `devices` lists every failing
	device, `device` / rect / detail are from the most cramped one, severity is
	the worst. With perDevice = true it's listed once per device instead: the
	primary entry has the full hint and `alsoOn`, the others say "same fix as
	<device>". The suggested attribute group is the narrowest ResponsiveUI group
	covering every failing device (Touch, Phone, PhonePortrait, ...) that is not
	masked by a later override the element already has; "update existing
	attribute X" means edit that one. When no single group works, the hint has
	one fix per group. A plain "set Size = ..." means every device failed and no
	override is in the way, so change the property itself.

	ISSUE KINDS
	    offscreen       partly or fully outside the screen (outside the device-safe area
	                    when the ScreenGui clips to it)
	    offscreen_parked (info) entirely outside the screen on EVERY audited device: looks
	                    parked for a slide-in tween, so no fix is suggested and its
	                    descendants aren't checked
	    unsafe_area     text or buttons under the Roblox topbar buttons, a notch or home
	                    bar, or outside the console TV-safe area (only the part not
	                    clipped or scrolled out of view)
	    overlap         sibling buttons or TextBoxes overlapping each other (not a button
	                    inside an invisible or near-full-screen backdrop button)
	    touch_target    button or TextBox smaller than 44x44 on Phone or Tablet
	    text_too_small  effective text size below CONSTANTS.MIN_TEXT for the device,
	                    after UIScale. TextScaled sizes are estimated.
	    text_overflow   text doesn't fit its box (TextService:GetTextSize). Skips TextScaled,
	                    TextTruncate and TextBox.
	    clipped         cut off by a ClipsDescendants ancestor, or outside a ScrollingFrame's
	                    canvas
	    zero_size       visible content with 0 width or height (only the topmost such
	                    element; a UIScale with Scale 0 is audited at Scale 1)
	    bad_override    a ResponsiveUI attribute names a missing property, has the wrong
	                    type, or uses a misspelled group ("Mobile_Size", "phone_Size")
	    aspect          (info) a stretched image whose shape differs a lot from its shape
	                    on CONSTANTS.REFERENCE_PROFILE

	APPROXIMATIONS (report.approximations lists the ones that applied)
	    UIListLayout/UIGridLayout placement, without Flex/UIFlexItem (grid cells honour
	    constraints parented to the UIGridLayout and MinSize spans); UIPageLayout and
	    UITableLayout aren't laid out; AutomaticSize uses direct children (one pass);
	    TextScaled size is estimated; custom FontFace is measured as SourceSans;
	    Rotation is ignored; ScrollingFrame is assumed scrolled to 0,0; UIScale on a
	    ScreenGui scales each child around its own AnchorPoint (layouts directly in it
	    are scaled as a whole); UIScale 0 is audited as 1; RichText <br> is a line
	    break and <font size> skips text_overflow; the topbar button zones and the
	    notch sizes are estimates (see CONSTANTS).
]]

local UIAudit = {}

local CONSTANTS = {
	TOPBAR_HEIGHT = 58, -- current Roblox topbar (legacy topbar was 36)
	TOPBAR_LEFT_RESERVED = 170, -- width of the Roblox buttons at the left of the topbar (estimate)
	TOPBAR_RIGHT_RESERVED = 70, -- width of the Roblox buttons at the right of the topbar (estimate)
	CONSOLE_TV_SAFE = 0.05, -- fraction of the screen per edge kept clear on console
	PHONE_MAX_SHORT_SIDE = 600, -- same rule as ResponsiveUI, for custom profiles without a device
	TOUCH_MIN = 44, -- minimum touch target (Apple HIG 44pt)
	TOUCH_ERROR = 32, -- below this a touch target is an error
	MIN_TEXT = { Phone = 12, Tablet = 12, Desktop = 10, Console = 18 },
	TEXT_ERROR_RATIO = 0.75, -- text below MIN_TEXT * this is an error
	TEXT_OVERFLOW_ERROR_RATIO = 1.5, -- text needing this much more room than it has is an error
	TOLERANCE = 2, -- pixels of slack before something counts as offscreen / clipped / overflowing
	OVERLAP_MIN = 4, -- overlaps narrower than this (px) are ignored
	OVERLAP_MIN_FRACTION = 0.1, -- ...or covering less than this fraction of the smaller element
	OVERLAP_ERROR_FRACTION = 0.5,
	ASPECT_DISTORTION = 1.35, -- stretched images whose aspect changes by more than this factor
	REFERENCE_PROFILE = "Desktop1080p", -- the "design" device for the aspect check
	MAX_ISSUES = 150,
	MAX_ISSUES_JSON = 60, -- runJSON default: keeps the JSON under ~10k tokens
	MIN_SEVERITY = "warning",
	SCALE_NAME = "ResponsiveScale", -- UIScale created by ResponsiveUI
	MAX_TEXT_SIZE = 100, -- Roblox's TextSize / TextScaled ceiling
	MAX_OVERLAP_SIBLINGS = 200, -- skip the O(n^2) overlap test above this many siblings
	FIT_MARGIN = 0.04, -- suggested sizes leave this fraction of the available space free
}
UIAudit.CONSTANTS = CONSTANTS

-- ─── Built-in device profiles ───────────────────────────────────────────────
-- size = full screen in Roblox UI units; safeInsets = notch / home bar (left, top, right, bottom).
local function makeProfile(name, device, w, h, insets)
	return {
		name = name,
		device = device,
		size = Vector2.new(w, h),
		safeInsets = insets or { 0, 0, 0, 0 },
	}
end

UIAudit.DEVICES = {
	makeProfile("AndroidSmall", "Phone", 640, 360),
	makeProfile("iPhoneSE", "Phone", 667, 375),
	makeProfile("iPhone15", "Phone", 852, 393, { 59, 0, 59, 21 }),
	makeProfile("iPhone15ProMax", "Phone", 932, 430, { 59, 0, 59, 21 }),
	makeProfile("iPhone15Portrait", "Phone", 393, 852, { 0, 59, 0, 34 }),
	makeProfile("iPad", "Tablet", 1180, 820, { 0, 0, 0, 20 }),
	makeProfile("iPadPro", "Tablet", 1366, 1024, { 0, 0, 0, 20 }),
	makeProfile("iPadPortrait", "Tablet", 820, 1180, { 0, 24, 0, 20 }),
	makeProfile("Laptop", "Desktop", 1366, 768),
	makeProfile("Desktop1080p", "Desktop", 1920, 1080),
	makeProfile("Desktop1440p", "Desktop", 2560, 1440),
	makeProfile("Ultrawide", "Desktop", 3440, 1440),
	makeProfile("Console", "Console", 1920, 1080),
}

-- ─── ResponsiveUI parity ────────────────────────────────────────────────────
local DEVICE_TYPES = { "Phone", "Tablet", "Desktop", "Console" }
local ORIENTATIONS = { "Portrait", "Landscape" }
local KNOWN_GROUPS = { Touch = true }
local KNOWN_GROUPS_LOWER = { touch = "Touch" }
for _, o in ORIENTATIONS do
	KNOWN_GROUPS[o] = true
	KNOWN_GROUPS_LOWER[string.lower(o)] = o
end
for _, d in DEVICE_TYPES do
	KNOWN_GROUPS[d] = true
	KNOWN_GROUPS_LOWER[string.lower(d)] = d
	for _, o in ORIENTATIONS do
		KNOWN_GROUPS[d .. o] = true
		KNOWN_GROUPS_LOWER[string.lower(d .. o)] = d .. o
	end
end
local GROUP_ALIASES = {
	mobile = "Touch",
	touchscreen = "Touch",
	pc = "Desktop",
	computer = "Desktop",
	mouse = "Desktop",
	keyboard = "Desktop",
	xbox = "Console",
	playstation = "Console",
	ps = "Console",
	ps4 = "Console",
	ps5 = "Console",
	gamepad = "Console",
	tv = "Console",
	ipad = "Tablet",
	iphone = "Phone",
	android = "Touch",
	vertical = "Portrait",
	horizontal = "Landscape",
}
local PSEUDO_PROPERTIES = { ScaleMultiplier = true }

-- Same pattern as ResponsiveUI.parseOverride.
local function parseOverride(attributeName)
	local group, property = string.match(attributeName, "^(%a+)_(%w+)$")
	if group and KNOWN_GROUPS[group] then
		return group, property
	end
	return nil, nil
end

-- Same order as ResponsiveUI.updateEnvironment: later wins.
local function groupsFor(deviceType, orientation)
	local groups = { orientation }
	if deviceType == "Phone" or deviceType == "Tablet" then
		table.insert(groups, "Touch")
	end
	table.insert(groups, deviceType)
	table.insert(groups, deviceType .. orientation)
	return groups
end
UIAudit._groupsFor = groupsFor

-- ─── Run state (one run at a time) ──────────────────────────────────────────
local S = nil

local function approx(text)
	if S and not S.approxSet[text] then
		S.approxSet[text] = true
		table.insert(S.approximations, text)
	end
end

local function note(text)
	if S and not S.noteSet[text] and #S.notes < 30 then
		S.noteSet[text] = true
		table.insert(S.notes, text)
	end
end

-- ─── Small helpers ──────────────────────────────────────────────────────────
local function tryGet(obj, prop)
	local ok, value = pcall(function()
		return obj[prop]
	end)
	if ok and value ~= nil and typeof(value) ~= "Instance" then
		return value
	end
	return nil
end

local function isA(obj, className)
	local ok, result = pcall(function()
		return obj:IsA(className)
	end)
	return ok and result == true
end

local function enumName(value)
	local t = typeof(value)
	if t == "EnumItem" then
		return value.Name
	elseif t == "string" then
		return value
	end
	return nil
end

local function num(value, default)
	if type(value) == "number" and value == value then
		return value
	end
	return default
end

local function udimParts(u)
	if typeof(u) ~= "UDim" then
		return 0, 0
	end
	return num(u.Scale, 0), num(u.Offset, 0)
end

local function udim2Parts(u)
	if typeof(u) ~= "UDim2" then
		return 0, 0, 0, 0
	end
	local xs, xo = udimParts(u.X)
	local ys, yo = udimParts(u.Y)
	return xs, xo, ys, yo
end

local function vec2Parts(v, dx, dy)
	if typeof(v) == "Vector2" then
		return num(v.X, dx), num(v.Y, dy)
	end
	return dx, dy
end

local function rect(x, y, w, h)
	return { x = x, y = y, w = w, h = h }
end

local function intersect(a, b)
	local x1 = math.max(a.x, b.x)
	local y1 = math.max(a.y, b.y)
	local x2 = math.min(a.x + a.w, b.x + b.w)
	local y2 = math.min(a.y + a.h, b.y + b.h)
	if x2 <= x1 or y2 <= y1 then
		return nil
	end
	return rect(x1, y1, x2 - x1, y2 - y1)
end

-- How far `r` sticks out of `b` on each side (positive = outside).
local function excess(r, b)
	return b.x - r.x, b.y - r.y, (r.x + r.w) - (b.x + b.w), (r.y + r.h) - (b.y + b.h)
end

local function round1(n)
	return math.floor(n * 10 + 0.5) / 10
end

local function fmt(n, decimals)
	local s = string.format("%." .. (decimals or 3) .. "f", n)
	if string.find(s, "%.") then
		s = string.gsub(s, "0+$", "")
		s = string.gsub(s, "%.$", "")
	end
	if s == "-0" then
		s = "0"
	end
	return s
end

local function clamp(v, lo, hi)
	if hi < lo then
		return lo
	end
	return math.max(lo, math.min(hi, v))
end

-- ─── Attributes, overrides and components ───────────────────────────────────
local function getAttrs(obj)
	local cached = S.attrs[obj]
	if cached then
		return cached
	end
	local ok, attrs = pcall(function()
		return obj:GetAttributes()
	end)
	cached = (ok and type(attrs) == "table") and attrs or {}
	S.attrs[obj] = cached
	return cached
end

-- Returns the value ResponsiveUI would end up assigning, or nil if the assignment would fail.
local function coerce(base, value)
	local tb, tv = typeof(base), typeof(value)
	if tb == tv then
		if tb == "EnumItem" then
			local ok, same = pcall(function()
				return value.EnumType == base.EnumType
			end)
			return (ok and same) and value or nil
		end
		return value
	end
	if tb == "EnumItem" and (tv == "string" or tv == "number") then
		local ok, items = pcall(function()
			return base.EnumType:GetEnumItems()
		end)
		if ok and type(items) == "table" then
			for _, item in items do
				if (tv == "string" and item.Name == value) or (tv == "number" and item.Value == value) then
					return item
				end
			end
		end
	end
	return nil
end

-- Last non-nil override across the active groups (ResponsiveUI.resolve), no type check.
local function resolveRaw(attrs, prop, default)
	local value = default
	for _, group in S.groups do
		local override = attrs[group .. "_" .. prop]
		if override ~= nil then
			value = override
		end
	end
	return value
end

-- Effective property value on the current device.
local function eff(obj, prop)
	local base = tryGet(obj, prop)
	if base == nil then
		return nil
	end
	local attrs = getAttrs(obj)
	if next(attrs) == nil then
		return base
	end
	local value = resolveRaw(attrs, prop, nil)
	if value == nil then
		return base
	end
	-- ResponsiveUI assigns the winning value; if that assignment fails, the property keeps its default.
	local coerced = coerce(base, value)
	if coerced == nil then
		return base
	end
	return coerced
end

local LAYOUT_CLASSES = { UIListLayout = true, UIGridLayout = true, UIPageLayout = true, UITableLayout = true }

-- Path segment for `child`: its Name, plus "#n" when it is the nth (n >= 2) child of its parent
-- with that Name in GetChildren() order. The first one keeps the plain name, so FindFirstChild
-- still finds it; UIAudit.find resolves the "#n" form.
local function segmentsOf(children)
	local seen, out = {}, {}
	for _, child in children do
		local name = tostring(tryGet(child, "Name") or "?")
		seen[name] = (seen[name] or 0) + 1
		out[child] = seen[name] > 1 and (name .. "#" .. seen[name]) or name
	end
	return out
end

local function segmentOf(obj)
	local parent = obj.Parent
	if parent == nil then
		return tostring(obj.Name)
	end
	local ok, children = pcall(function()
		return parent:GetChildren()
	end)
	if not ok then
		return tostring(obj.Name)
	end
	return segmentsOf(children)[obj] or tostring(obj.Name)
end

local function getComps(obj)
	local cached = S.comps[obj]
	if cached then
		return cached
	end
	cached = { kids = {} }
	local function scan(container, prefix)
		local ok, children = pcall(function()
			return container:GetChildren()
		end)
		if not ok then
			return
		end
		local segs = segmentsOf(children)
		for _, child in children do
			local className = tryGet(child, "ClassName") or ""
			if isA(child, "GuiObject") then
				table.insert(cached.kids, { obj = child, rel = prefix .. segs[child] })
			elseif className == "Folder" then
				scan(child, prefix .. segs[child] .. ".")
			elseif container == obj then
				if className == "UIScale" then
					if child.Name == CONSTANTS.SCALE_NAME then
						cached.responsiveScale = child
					elseif not cached.scale then
						cached.scale = child
					end
				elseif className == "UIPadding" and not cached.padding then
					cached.padding = child
				elseif className == "UIAspectRatioConstraint" and not cached.aspect then
					cached.aspect = child
				elseif className == "UISizeConstraint" and not cached.sizeC then
					cached.sizeC = child
				elseif className == "UITextSizeConstraint" and not cached.textC then
					cached.textC = child
				elseif LAYOUT_CLASSES[className] and not cached.layout then
					cached.layout = child
					cached.layoutClass = className
				end
			end
		end
	end
	scan(obj, "")
	S.comps[obj] = cached
	return cached
end

-- ─── Text measurement ───────────────────────────────────────────────────────
local function plainText(obj, text)
	if eff(obj, "RichText") == true then
		text = string.gsub(text, "<[bB][rR]%s*/?%s*>", "\n")
		text = string.gsub(text, "<[^>]->", "")
		text = string.gsub(text, "&lt;", "<")
		text = string.gsub(text, "&gt;", ">")
		text = string.gsub(text, "&quot;", '"')
		text = string.gsub(text, "&apos;", "'")
		text = string.gsub(text, "&amp;", "&")
		approx("RichText measured with tags stripped (<br> as a line break)")
	end
	return text
end

local function getFont(obj)
	local font = eff(obj, "Font")
	if typeof(font) ~= "EnumItem" or font.Name == "Unknown" then
		approx("Custom FontFace text measured with Enum.Font.SourceSans")
		local ok, fallback = pcall(function()
			return Enum.Font.SourceSans
		end)
		return ok and fallback or font
	end
	return font
end

local function measureText(text, size, font, maxWidth)
	if size <= 0 or text == "" then
		return 0, 0
	end
	local factor = 1
	if size > CONSTANTS.MAX_TEXT_SIZE then
		factor = size / CONSTANTS.MAX_TEXT_SIZE
		size = CONSTANTS.MAX_TEXT_SIZE
		maxWidth = maxWidth / factor
	end
	local key = table.concat({ text, tostring(size), tostring(font), tostring(maxWidth) }, "\0")
	local hit = S.textCache[key]
	if not hit then
		local ok, bounds = pcall(function()
			return S.TextService:GetTextSize(text, size, font, Vector2.new(maxWidth, 1e6))
		end)
		if ok and typeof(bounds) == "Vector2" then
			hit = { bounds.X, bounds.Y }
		else
			approx("TextService unavailable; text width estimated as 0.5 * TextSize per character")
			hit = { math.min(#text * size * 0.5, maxWidth), size * math.ceil(#text * size * 0.5 / math.max(maxWidth, 1)) }
		end
		S.textCache[key] = hit
	end
	return hit[1] * factor, hit[2] * factor
end

-- ─── Classification ─────────────────────────────────────────────────────────
local function isTextObject(obj)
	return isA(obj, "TextLabel") or isA(obj, "TextButton") or isA(obj, "TextBox")
end

local function getText(obj)
	local text = eff(obj, "Text")
	if isA(obj, "TextBox") and (type(text) ~= "string" or text == "") then
		text = eff(obj, "PlaceholderText")
	end
	if type(text) ~= "string" then
		return ""
	end
	return plainText(obj, text)
end

local function classify(obj)
	local c = {}
	c.interactive = isA(obj, "GuiButton") or isA(obj, "TextBox")
	c.textObject = isTextObject(obj)
	if c.textObject then
		c.text = getText(obj)
		c.hasText = c.text ~= "" and num(eff(obj, "TextTransparency"), 0) < 1
	end
	if isA(obj, "ImageLabel") or isA(obj, "ImageButton") then
		local image = eff(obj, "Image")
		c.hasImage = type(image) == "string" and image ~= "" and num(eff(obj, "ImageTransparency"), 0) < 1
	end
	c.hasBg = num(eff(obj, "BackgroundTransparency"), 1) < 1
	c.important = c.interactive or c.hasText or c.hasImage
	c.visibleContent = c.important or c.hasBg
	return c
end

-- ─── Layout math ────────────────────────────────────────────────────────────
local function sizeClamp(c, w, h, s)
	if not c then
		return w, h
	end
	local minX, minY = vec2Parts(eff(c, "MinSize"), 0, 0)
	local maxX, maxY = vec2Parts(eff(c, "MaxSize"), math.huge, math.huge)
	w = clamp(w, minX * s, maxX * s)
	h = clamp(h, minY * s, maxY * s)
	return w, h
end

local function applySizeConstraint(obj, w, h, s)
	return sizeClamp(getComps(obj).sizeC, w, h, s)
end

local function aspectFit(c, w, h, pc)
	if not c then
		return w, h
	end
	local r = num(eff(c, "AspectRatio"), 1)
	if r <= 0 then
		return w, h
	end
	local aspectType = enumName(eff(c, "AspectType")) or "FitWithinMaxSize"
	local dominant = enumName(eff(c, "DominantAxis")) or "Width"
	if aspectType == "ScaleWithParentSize" then
		approx("UIAspectRatioConstraint ScaleWithParentSize approximated (dominant axis kept, capped to parent)")
		if dominant == "Height" then
			w = h * r
		else
			h = w / r
		end
		if w > pc.w and pc.w > 0 then
			w = pc.w
			h = w / r
		end
		if h > pc.h and pc.h > 0 then
			h = pc.h
			w = h * r
		end
	else
		if h > 0 and w / h > r then
			w = h * r
		else
			h = w / r
		end
	end
	return w, h
end

local function applyAspect(obj, w, h, pc)
	return aspectFit(getComps(obj).aspect, w, h, pc)
end

local function paddingOf(obj, w, h, s)
	local p = getComps(obj).padding
	if not p then
		return 0, 0, 0, 0
	end
	local ls, lo = udimParts(eff(p, "PaddingLeft"))
	local rs, ro = udimParts(eff(p, "PaddingRight"))
	local ts, to = udimParts(eff(p, "PaddingTop"))
	local bs, bo = udimParts(eff(p, "PaddingBottom"))
	return ls * w + lo * s, ts * h + to * s, rs * w + ro * s, bs * h + bo * s
end

local layoutChildren -- forward

-- Measures a GuiObject's size against its parent content box `pc`.
-- s = offset multiplier from ancestor UIScales; extra = ScreenGui-level scale (direct children only).
local function measure(obj, pc, s, extra)
	local comps = getComps(obj)
	local size = eff(obj, "Size")
	local xs, xo, ys, yo = udim2Parts(size)
	local refW, refH = pc.w, pc.h
	local sizeConstraint = enumName(eff(obj, "SizeConstraint"))
	if sizeConstraint == "RelativeXX" then
		refH = pc.w
	elseif sizeConstraint == "RelativeYY" then
		refW = pc.h
	end
	local w = refW * xs + xo * s
	local h = refH * ys + yo * s

	local auto = enumName(eff(obj, "AutomaticSize")) or "None"
	if auto ~= "None" then
		local growX = auto == "X" or auto == "XY"
		local growY = auto == "Y" or auto == "XY"
		local pl, pt, pr, pb = paddingOf(obj, w, h, s)
		local needW, needH = 0, 0
		if isTextObject(obj) then
			approx("AutomaticSize on text estimated from TextService bounds")
			local text = getText(obj)
			local ts = num(eff(obj, "TextSize"), 14) * s
			local wrapped = eff(obj, "TextWrapped") == true and not growX
			needW, needH = measureText(text, ts, getFont(obj), wrapped and math.max(w - pl - pr, 1) or 1e5)
		end
		local okKids, kids = pcall(layoutChildren, obj, rect(0, 0, math.max(w - pl - pr, 0), math.max(h - pt - pb, 0)), s, 1, "")
		if okKids and #kids > 0 then
			approx("AutomaticSize containers grown from their direct children in one pass")
			local minX, minY, maxX, maxY = 0, 0, 0, 0
			for _, k in kids do
				minX = math.min(minX, k.x)
				minY = math.min(minY, k.y)
				maxX = math.max(maxX, k.x + k.w)
				maxY = math.max(maxY, k.y + k.h)
			end
			needW = math.max(needW, maxX - minX)
			needH = math.max(needH, maxY - minY)
		end
		if growX then
			w = math.max(w, needW + pl + pr)
		end
		if growY then
			h = math.max(h, needH + pt + pb)
		end
	end

	w, h = applySizeConstraint(obj, w, h, s)
	w, h = applyAspect(obj, w, h, pc)

	local u = extra
	if comps.scale then
		local scale = num(eff(comps.scale, "Scale"), 1)
		if math.abs(scale) < 1e-3 then
			-- "tween UIScale 0 -> 1 on open": audit the open state
			approx("UIScale with Scale 0 (pop-in animation) audited at Scale 1")
			scale = 1
		end
		u *= scale
	end
	w, h = math.max(w, 0) * u, math.max(h, 0) * u

	local apX, apY = vec2Parts(eff(obj, "AnchorPoint"), 0, 0)
	local rotation = num(eff(obj, "Rotation"), 0)
	if rotation ~= 0 then
		approx("Rotation ignored (rects are unrotated, like AbsolutePosition/AbsoluteSize)")
	end
	return {
		obj = obj,
		pc = pc,
		s = s,
		u = u,
		sChild = s * u,
		w = w,
		h = h,
		x = 0,
		y = 0,
		apX = apX,
		apY = apY,
		sizeParts = { xs, xo, ys, yo },
		refW = refW,
		refH = refH,
		rotation = rotation,
	}
end

local function place(node)
	local pxs, pxo, pys, pyo = udim2Parts(eff(node.obj, "Position"))
	local pc = node.pc
	node.x = pc.x + pc.w * pxs + pxo * node.s - node.apX * node.w
	node.y = pc.y + pc.h * pys + pyo * node.s - node.apY * node.h
end

local function alignOffset(name, free)
	if name == "Center" then
		return free / 2
	elseif name == "Right" or name == "Bottom" then
		return free
	end
	return 0
end

local function sortForLayout(layout, nodes)
	local sortOrder = enumName(eff(layout, "SortOrder")) or "LayoutOrder"
	for _, n in nodes do
		n.layoutOrder = num(eff(n.obj, "LayoutOrder"), 0)
		n.name = tostring(tryGet(n.obj, "Name") or "")
	end
	table.sort(nodes, function(a, b)
		if sortOrder == "Name" then
			if a.name ~= b.name then
				return a.name < b.name
			end
		elseif sortOrder == "LayoutOrder" then
			if a.layoutOrder ~= b.layoutOrder then
				return a.layoutOrder < b.layoutOrder
			end
		end
		return a.order < b.order
	end)
end

-- s = offset multiplier of the container's UIScales; mul = extra scale applied to everything the
-- layout places (the ScreenGui's UIScale / ResponsiveScale when the layout sits directly in it).
local function listLayout(layout, nodes, pc, s, mul)
	approx("UIListLayout positions estimated (Flex / UIFlexItem ignored)")
	sortForLayout(layout, nodes)
	local vertical = (enumName(eff(layout, "FillDirection")) or "Vertical") ~= "Horizontal"
	local hAlign = enumName(eff(layout, "HorizontalAlignment")) or "Left"
	local vAlign = enumName(eff(layout, "VerticalAlignment")) or "Top"
	local mainAlign, crossAlign = hAlign, vAlign
	if vertical then
		mainAlign, crossAlign = vAlign, hAlign
	end
	local mainSpace = vertical and pc.h or pc.w
	local crossSpace = vertical and pc.w or pc.h
	local padS, padO = udimParts(eff(layout, "Padding"))
	local pad = (padS * mainSpace + padO * s) * mul
	local wraps = eff(layout, "Wraps") == true
	local hf, vf = enumName(eff(layout, "HorizontalFlex")), enumName(eff(layout, "VerticalFlex"))
	if (hf and hf ~= "None") or (vf and vf ~= "None") then
		approx("UIListLayout HorizontalFlex/VerticalFlex ignored: items keep their own size")
	end

	local function mainOf(n)
		return vertical and n.h or n.w
	end
	local function crossOf(n)
		return vertical and n.w or n.h
	end

	-- Break into lines.
	local lines = {}
	local current = { items = {}, main = 0, cross = 0 }
	for _, n in nodes do
		local add = mainOf(n) + (#current.items > 0 and pad or 0)
		if wraps and #current.items > 0 and current.main + add > mainSpace + 0.5 then
			table.insert(lines, current)
			current = { items = {}, main = 0, cross = 0 }
			add = mainOf(n)
		end
		table.insert(current.items, n)
		current.main += add
		current.cross = math.max(current.cross, crossOf(n))
	end
	if #current.items > 0 then
		table.insert(lines, current)
	end
	if wraps then
		approx("UIListLayout Wraps: lines spaced by Padding")
	end

	local totalCross = 0
	for i, line in lines do
		totalCross += line.cross + (i > 1 and pad or 0)
	end
	local crossCursor = wraps and alignOffset(crossAlign, crossSpace - totalCross) or 0
	for _, line in lines do
		local mainCursor = alignOffset(mainAlign, mainSpace - line.main)
		local lineCross = wraps and line.cross or crossSpace
		for _, n in line.items do
			local crossPos = crossCursor + alignOffset(crossAlign, lineCross - crossOf(n))
			if vertical then
				n.x, n.y = pc.x + crossPos, pc.y + mainCursor
			else
				n.x, n.y = pc.x + mainCursor, pc.y + crossPos
			end
			mainCursor += mainOf(n) + pad
		end
		crossCursor += line.cross + pad
	end
end

local function gridLayout(layout, nodes, pc, s, mul)
	approx("UIGridLayout cell positions estimated")
	sortForLayout(layout, nodes)
	local cs = eff(layout, "CellSize")
	local cxs, cxo, cys, cyo = 0, 100, 0, 100
	if typeof(cs) == "UDim2" then
		cxs, cxo, cys, cyo = udim2Parts(cs)
	end
	local cp = eff(layout, "CellPadding")
	local pxs, pxo, pys, pyo = 0, 5, 0, 5
	if typeof(cp) == "UDim2" then
		pxs, pxo, pys, pyo = udim2Parts(cp)
	end
	-- Cell size before the ScreenGui-level scale (`mul`), so constraints use their own units.
	local cw0, ch0 = cxs * pc.w + cxo * s, cys * pc.h + cyo * s
	-- UISizeConstraint / UIAspectRatioConstraint parented to the UIGridLayout constrain every cell.
	local okKids, layoutKids = pcall(function()
		return layout:GetChildren()
	end)
	if okKids then
		local sizeC, aspectC
		for _, k in layoutKids do
			local className = tryGet(k, "ClassName")
			if className == "UISizeConstraint" and not sizeC then
				sizeC = k
			elseif className == "UIAspectRatioConstraint" and not aspectC then
				aspectC = k
			end
		end
		cw0, ch0 = sizeClamp(sizeC, cw0, ch0, s)
		if aspectC then
			local r = num(eff(aspectC, "AspectRatio"), 1)
			if r > 0 then
				-- UIGridLayout fits the cell inside CellSize (FitWithinMaxSize)
				cw0 = math.min(cw0, ch0 * r)
				ch0 = cw0 / r
			end
		end
	end
	local cw, ch = cw0 * mul, ch0 * mul
	local px, py = (pxs * pc.w + pxo * s) * mul, (pys * pc.h + pyo * s) * mul
	local horizontal = (enumName(eff(layout, "FillDirection")) or "Horizontal") == "Horizontal"
	local maxCells = num(eff(layout, "FillDirectionMaxCells"), 0)
	local perLine
	if horizontal then
		perLine = math.floor((pc.w + px + 0.01) / math.max(cw + px, 1e-6))
	else
		perLine = math.floor((pc.h + py + 0.01) / math.max(ch + py, 1e-6))
	end
	perLine = math.max(1, perLine)
	if maxCells > 0 then
		perLine = math.min(perLine, maxCells)
	end

	-- Sizes, and how many cells each child spans (a UISizeConstraint MinSize above CellSize spans cells).
	local cellIndex = 0
	local spans = false
	for _, node in nodes do
		local w, h = applySizeConstraint(node.obj, cw0, ch0, s)
		w, h = applyAspect(node.obj, w, h, rect(0, 0, cw0, ch0))
		local span = 1
		if horizontal then
			span = math.max(1, math.ceil((w * mul + px) / math.max(cw + px, 1e-6) - 1e-6))
		else
			span = math.max(1, math.ceil((h * mul + py) / math.max(ch + py, 1e-6) - 1e-6))
		end
		span = math.min(span, perLine)
		if span > 1 then
			spans = true
			local inLine = cellIndex % perLine
			if inLine + span > perLine then
				cellIndex += perLine - inLine -- wrap to the next line
			end
		end
		node.w, node.h = w * node.u, h * node.u -- node.u = ScreenGui scale * the child's own UIScale
		node.cell = cellIndex
		node.span = span
		cellIndex += span
	end
	if spans then
		approx("UIGridLayout cells spanned by a UISizeConstraint MinSize estimated")
	end
	local lineCount = math.ceil(cellIndex / perLine)
	local cols = horizontal and math.min(cellIndex, perLine) or lineCount
	local rows = horizontal and lineCount or math.min(cellIndex, perLine)
	local blockW = cols * cw + math.max(cols - 1, 0) * px
	local blockH = rows * ch + math.max(rows - 1, 0) * py
	local x0 = pc.x + alignOffset(enumName(eff(layout, "HorizontalAlignment")) or "Left", pc.w - blockW)
	local y0 = pc.y + alignOffset(enumName(eff(layout, "VerticalAlignment")) or "Top", pc.h - blockH)
	local corner = enumName(eff(layout, "StartCorner")) or "TopLeft"
	for _, node in nodes do
		local line = node.cell // perLine
		local index = node.cell % perLine
		local col, row = index, line
		local spanX, spanY = node.span, 1
		if not horizontal then
			col, row = line, index
			spanX, spanY = 1, node.span
		end
		if string.find(corner, "Right") then
			col = cols - col - spanX
		end
		if string.find(corner, "Bottom") then
			row = rows - row - spanY
		end
		node.x = x0 + col * (cw + px)
		node.y = y0 + row * (ch + py)
		node.cell, node.span = nil, nil
	end
end

-- Measures and positions the visible GuiObject children of `container` (no recursion).
function layoutChildren(container, pc, s, extra, parentPath)
	local comps = getComps(container)
	local nodes = {}
	for i, entry in comps.kids do
		local obj = entry.obj
		if eff(obj, "Visible") ~= false then
			local ok, node = pcall(measure, obj, pc, s, extra)
			if ok and node then
				node.path = parentPath == "" and entry.rel or (parentPath .. "." .. entry.rel)
				node.order = i
				table.insert(nodes, node)
			elseif not ok then
				note("skipped " .. tostring(entry.rel) .. ": " .. tostring(node))
			end
		end
	end
	local layoutClass = comps.layoutClass
	if layoutClass == "UIListLayout" then
		listLayout(comps.layout, nodes, pc, s, extra)
	elseif layoutClass == "UIGridLayout" then
		gridLayout(comps.layout, nodes, pc, s, extra)
	else
		if layoutClass then
			approx(layoutClass .. " not laid out: children placed by their own Position")
		end
		for _, node in nodes do
			place(node)
		end
	end
	for _, node in nodes do
		node.layoutClass = layoutClass
	end
	return nodes, layoutClass
end

-- ─── Fix suggestions ────────────────────────────────────────────────────────
local function udim2Text(xs, xo, ys, yo)
	if xo == 0 and yo == 0 then
		return "UDim2.fromScale(" .. fmt(xs) .. ", " .. fmt(ys) .. ")"
	elseif xs == 0 and ys == 0 then
		return "UDim2.fromOffset(" .. fmt(xo, 0) .. ", " .. fmt(yo, 0) .. ")"
	end
	return "UDim2.new(" .. fmt(xs) .. ", " .. fmt(xo, 0) .. ", " .. fmt(ys) .. ", " .. fmt(yo, 0) .. ")"
end

-- A Size value that makes the node w x h pixels on this device, keeping its Scale/Offset style.
local function suggestSize(node, w, h)
	local xs, _, ys = table.unpack(node.sizeParts)
	local useScaleX = math.abs(xs) > 0 and node.refW > 0
	local useScaleY = math.abs(ys) > 0 and node.refH > 0
	local u = node.u > 0 and node.u or 1
	local sc = node.sChild > 0 and node.sChild or 1
	local nxs, nxo, nys, nyo = 0, 0, 0, 0
	if useScaleX then
		nxs = math.floor(w / u / node.refW * 1000 + 0.5) / 1000
	else
		nxo = math.ceil(w / sc - 0.001)
	end
	if useScaleY then
		nys = math.floor(h / u / node.refH * 1000 + 0.5) / 1000
	else
		nyo = math.ceil(h / sc - 0.001)
	end
	return udim2Text(nxs, nxo, nys, nyo)
end

-- A Position value that puts the node's top-left at x, y (same AnchorPoint).
local function suggestPosition(node, x, y, w, h)
	local pc = node.pc
	local ax = x + node.apX * w - pc.x
	local ay = y + node.apY * h - pc.y
	local sx = pc.w > 0 and math.floor(ax / pc.w * 1000 + 0.5) / 1000 or 0
	local sy = pc.h > 0 and math.floor(ay / pc.h * 1000 + 0.5) / 1000 or 0
	return udim2Text(sx, 0, sy, 0)
end

-- Fixes that move/shrink node so it fits inside `bounds` (with an optional margin).
local function fitFixes(node, bounds, margin)
	margin = margin or 0
	local fixes = {}
	local maxW = math.max(bounds.w - 2 * margin, 1)
	local maxH = math.max(bounds.h - 2 * margin, 1)
	local w, h = node.w, node.h
	if w > maxW or h > maxH then
		-- shrink to (1 - FIT_MARGIN) of the space so it doesn't touch the edges
		local room = 1 - CONSTANTS.FIT_MARGIN
		local f = math.min(maxW * room / math.max(w, 1e-6), maxH * room / math.max(h, 1e-6), 1)
		w, h = w * f, h * f -- keep the shape
		table.insert(fixes, { prop = "Size", value = suggestSize(node, w, h) })
		fixes.fit = f -- how much it had to shrink; the most-shrunk device gives the shared hint
	end
	if node.layoutClass then
		return fixes, "it is placed by a " .. node.layoutClass .. ": shrink it or its siblings, or reduce the layout's Padding"
	end
	-- top-left after resizing around the same AnchorPoint, then pushed inside the bounds
	local keptX = node.x + node.apX * (node.w - w)
	local keptY = node.y + node.apY * (node.h - h)
	local x = clamp(keptX, bounds.x + margin, bounds.x + bounds.w - margin - w)
	local y = clamp(keptY, bounds.y + margin, bounds.y + bounds.h - margin - h)
	if math.abs(x - keptX) > 0.5 or math.abs(y - keptY) > 0.5 then
		table.insert(fixes, { prop = "Position", value = suggestPosition(node, x, y, w, h) })
	end
	return fixes, nil
end

-- ─── Issue collection ───────────────────────────────────────────────────────
local function addIssue(gctx, node, kind, severity, detail, fixes, extraNote, r, flags)
	if S.refMode then
		return
	end
	if S.filterPath then
		local p = node and node.path or ""
		if p ~= S.filterPath and string.sub(p, 1, #S.filterPath + 1) ~= S.filterPath .. "." then
			return
		end
	end
	r = r or (node and rect(node.x, node.y, node.w, node.h)) or rect(0, 0, 0, 0)
	local env = gctx.env
	table.insert(S.raw, {
		screenGui = gctx.name,
		device = env.profile.name,
		deviceType = env.deviceType,
		orientation = env.orientation,
		area = env.viewport[1] * env.viewport[2],
		path = node and node.path or gctx.name,
		kind = kind,
		severity = severity,
		detail = detail,
		rect = { x = round1(r.x), y = round1(r.y), w = round1(r.w), h = round1(r.h) },
		fixes = fixes or {},
		fit = fixes and fixes.fit or 1,
		note = extraNote,
		obj = node and node.obj or gctx.gui, -- issues are grouped per instance, never per path string
		gui = gctx.gui,
		env = env,
		flags = flags,
	})
end

local function size2(w, h)
	return fmt(w, 0) .. "x" .. fmt(h, 0)
end

-- ─── Per-node checks ────────────────────────────────────────────────────────
local function checkText(node, gctx, c, content)
	local obj = node.obj
	local env = gctx.env
	local minText = CONSTANTS.MIN_TEXT[env.deviceType] or 12
	local font = getFont(obj)
	local textC = getComps(obj).textC
	local minTS, maxTS = 1, math.huge
	if textC then
		minTS = num(eff(textC, "MinTextSize"), 1)
		maxTS = num(eff(textC, "MaxTextSize"), math.huge)
	end
	local cw, ch = math.max(content.w, 0), math.max(content.h, 0)
	local scaled = eff(obj, "TextScaled") == true
	local wrapped = eff(obj, "TextWrapped") == true
	local effective
	if scaled then
		approx("TextScaled text size estimated from the box size")
		local w100 = measureText(c.text, 100, font, 1e5)
		local est
		if w100 <= 0 then
			est = ch
		elseif wrapped then
			est = math.min(ch, math.sqrt(cw * ch * 100 / w100))
		else
			est = math.min(ch, 100 * cw / w100)
		end
		est = math.min(est, CONSTANTS.MAX_TEXT_SIZE * node.sChild)
		effective = clamp(est, minTS * node.sChild, maxTS * node.sChild)
	else
		effective = clamp(num(eff(obj, "TextSize"), 14), minTS, maxTS) * node.sChild
	end

	if effective < minText - 0.01 then
		local severity = effective < minText * CONSTANTS.TEXT_ERROR_RATIO and "error" or "warning"
		local fixes, extra = {}, nil
		if scaled then
			local needH = node.h * minText / math.max(effective, 0.1)
			if not wrapped and ch > 0 and effective < ch * 0.9 then
				-- Width-limited: the box is too narrow for this much text.
				local needW = node.w * minText / math.max(effective, 0.1)
				table.insert(fixes, { prop = "Size", value = suggestSize(node, needW, node.h) })
			else
				table.insert(fixes, { prop = "Size", value = suggestSize(node, node.w, needH) })
			end
			extra = "or shorten the text; a UITextSizeConstraint MinTextSize only helps if the box has room"
		else
			table.insert(fixes, { prop = "TextSize", value = tostring(math.ceil(minText / math.max(node.sChild, 1e-3))) })
			if node.sChild < 1 then
				extra = "UI is scaled by " .. fmt(node.sChild, 2) .. " here; raising the ScreenGui's MinScale or ScaleMultiplier also works"
			end
		end
		addIssue(gctx, node, "text_too_small", severity,
			(scaled and "TextScaled text about " or "text size ") .. fmt(effective, 1) .. "px, minimum " .. minText .. " on " .. env.deviceType,
			fixes, extra)
	end

	if scaled or isA(obj, "TextBox") then
		return
	end
	local truncate = enumName(eff(obj, "TextTruncate"))
	if truncate and truncate ~= "None" then
		return
	end
	if eff(obj, "RichText") == true then
		local raw = eff(obj, "Text")
		if type(raw) == "string" and string.find(string.lower(raw), "<font[^>]-size") then
			approx("text_overflow not checked for RichText with <font size=...> (inline sizes not modeled)")
			return
		end
	end
	local auto = enumName(eff(obj, "AutomaticSize")) or "None"
	local bx, by = measureText(c.text, effective, font, wrapped and math.max(cw, 1) or 1e5)
	local overX = not wrapped and auto ~= "X" and auto ~= "XY" and bx > cw + CONSTANTS.TOLERANCE
	local overY = auto ~= "Y" and auto ~= "XY" and by > ch + CONSTANTS.TOLERANCE
	if overX or overY then
		local ratio = math.max(overX and bx / math.max(cw, 1) or 1, overY and by / math.max(ch, 1) or 1)
		local severity = ratio >= CONSTANTS.TEXT_OVERFLOW_ERROR_RATIO and "error" or "warning"
		local fit = wrapped and math.sqrt(1 / ratio) or (1 / ratio)
		local newSize = math.floor(num(eff(obj, "TextSize"), 14) * fit)
		local fixes, extra
		if newSize * node.sChild >= (CONSTANTS.MIN_TEXT[env.deviceType] or 12) then
			fixes = { { prop = "TextSize", value = tostring(newSize) } }
			extra = "or enable TextScaled with a UITextSizeConstraint"
		else
			local padW, padH = node.w - cw, node.h - ch
			fixes = { { prop = "Size", value = suggestSize(node, overX and bx + padW or node.w, overY and by + padH or node.h) } }
			extra = "shrinking TextSize would make it unreadable; or shorten the text"
		end
		addIssue(gctx, node, "text_overflow", severity,
			"text needs " .. size2(bx, by) .. " but the box is " .. size2(cw, ch),
			fixes, extra)
	end
end

local function checkNode(node, pctx, c)
	local gctx = pctx.gctx
	local env = gctx.env
	local obj = node.obj
	local r = rect(node.x, node.y, node.w, node.h)
	local reported = {}
	local tol = CONSTANTS.TOLERANCE

	-- aspect bookkeeping (images that stretch)
	if c.hasImage and not getComps(obj).aspect and node.h > 0 and node.w > 0 then
		local scaleType = enumName(eff(obj, "ScaleType")) or "Stretch"
		if scaleType == "Stretch" then
			if S.refMode then
				S.refAspect[obj] = node.w / node.h
			else
				local ref = S.refAspect[obj]
				if ref then
					local ratio = (node.w / node.h) / ref
					if ratio > CONSTANTS.ASPECT_DISTORTION or ratio < 1 / CONSTANTS.ASPECT_DISTORTION then
						addIssue(gctx, node, "aspect", "info",
							"stretched image is " .. fmt(node.w / node.h, 2) .. ":1 here vs " .. fmt(ref, 2) .. ":1 on " .. CONSTANTS.REFERENCE_PROFILE,
							{}, "add a UIAspectRatioConstraint (AspectRatio " .. fmt(ref, 2) .. ") or set ScaleType = Fit")
					end
				end
			end
		end
	end
	if S.refMode then
		return reported
	end
	-- Under an ancestor that is entirely offscreen on this device (e.g. a menu parked for a
	-- slide-in tween) nothing is visible: moving that ancestor is the only relevant fix.
	if pctx.hiddenOff then
		return reported
	end

	-- zero_size (only the topmost zero-size element is reported)
	if node.w < 0.5 or node.h < 0.5 then
		if c.visibleContent and not pctx.zeroReported then
			local xs, xo, ys, yo = table.unpack(node.sizeParts)
			local why
			if (xs == 0 and xo == 0) or (ys == 0 and yo == 0) then
				why = "its Size is 0 on this axis; if a script tweens it open from Size 0, ignore this or set Visible = false while closed"
			else
				why = "check its Size (and any " .. env.deviceType .. "_Size / Touch_Size override) against its parent's size"
			end
			addIssue(gctx, node, "zero_size", c.important and "warning" or "info",
				"resolves to " .. size2(node.w, node.h) .. " on this device", {}, why)
		end
		reported.zero = true
		return reported
	end

	-- offscreen (only outside clipping/scrolling ancestors; those are covered by `clipped`)
	if not pctx.clip and not pctx.offReported then
		local b = gctx.bounds
		local l, t, rr, bb = excess(r, b)
		local inter = intersect(r, b)
		if not inter then
			if c.visibleContent then
				local fixes, extra = fitFixes(node, gctx.container, 0)
				addIssue(gctx, node, "offscreen", "warning", "entirely outside the " .. size2(b.w, b.h) .. " screen",
					fixes, extra or "if it's parked offscreen for a tween, set Visible = false while hidden",
					nil, { entirelyOff = true })
				reported.offscreen = true
				reported.entirelyOff = true
			end
		elseif math.max(l, t, rr, bb) > tol and c.visibleContent then
			local cut = 1 - (inter.w * inter.h) / math.max(r.w * r.h, 1e-6)
			local severity = "info"
			if c.important then
				severity = (c.interactive or c.hasText) and "error" or "warning"
			elseif cut > 0.1 then
				severity = "warning"
			end
			local sides = {}
			if l > tol then table.insert(sides, "left " .. fmt(l, 0)) end
			if t > tol then table.insert(sides, "top " .. fmt(t, 0)) end
			if rr > tol then table.insert(sides, "right " .. fmt(rr, 0)) end
			if bb > tol then table.insert(sides, "bottom " .. fmt(bb, 0)) end
			local fixes, extra = fitFixes(node, gctx.container, 0)
			local xs, _, ys = table.unpack(node.sizeParts)
			if xs == 0 and ys == 0 and not gctx.autoscaled and (rr > tol or bb > tol or l > tol or t > tol) and #fixes > 0 and fixes[1].prop == "Size" then
				extra = (extra and (extra .. "; ") or "") .. "it is sized in Offset: setting ReferenceResolution on ScreenGui " .. gctx.name .. " would scale it on every device"
			end
			addIssue(gctx, node, "offscreen", severity,
				fmt(cut * 100, 0) .. "% outside the screen (" .. table.concat(sides, ", ") .. "px)", fixes, extra)
			reported.offscreen = true
		end
	end

	-- clipped
	if pctx.clip and not pctx.clipReported and c.visibleContent then
		local clip = pctx.clip
		local l, t, rr, bb = excess(r, clip.rect)
		if math.max(l, t, rr, bb) > tol then
			local inter = intersect(r, clip.rect)
			local cut = inter and (1 - (inter.w * inter.h) / math.max(r.w * r.h, 1e-6)) or 1
			local what = clip.scroll and ("outside the canvas of ScrollingFrame " .. clip.path)
				or ("cut off by ClipsDescendants on " .. clip.path)
			local severity = c.important and "warning" or "info"
			local fixes, extra = fitFixes(node, clip.content or clip.rect, 0)
			if clip.scroll then
				extra = (extra and (extra .. "; ") or "") .. "or set the ScrollingFrame's AutomaticCanvasSize / CanvasSize"
			end
			addIssue(gctx, node, "clipped", severity, fmt(cut * 100, 0) .. "% " .. what, fixes, extra)
			reported.clipped = true
		end
	end

	-- unsafe_area
	-- (skipped under an offscreen ancestor: moving/shrinking that ancestor is the real fix)
	-- Only the part that can be seen counts: content scrolled or clipped out of view is tested
	-- where its ScrollingFrame / clipping ancestor is.
	local seen = r
	if pctx.visible then
		seen = intersect(r, pctx.visible)
	end
	if seen and c.important and not reported.offscreen and not pctx.offReported and not pctx.unsafeReported then
		for _, zone in gctx.zones do
			local inter = intersect(seen, zone.rect)
			if inter and inter.w > tol and inter.h > tol then
				local severity = (c.interactive and zone.kind ~= "tv") and "error" or "warning"
				local fixes, extra
				if zone.kind == "tv" then
					fixes, extra = fitFixes(node, gctx.tvSafeRect, 0)
				elseif zone.kind == "notch" then
					fixes = { { prop = "ScreenInsets", value = '"DeviceSafeInsets"', target = "ScreenGui " .. gctx.name } }
					extra = "or keep only full-screen backgrounds in a ScreenInsets=None ScreenGui"
				else
					local safe = gctx.coreRect
					fixes, extra = fitFixes(node, safe, 0)
					if gctx.insets ~= "CoreUISafeInsets" then
						extra = (extra and (extra .. "; ") or "")
							.. "or set ScreenGui " .. gctx.name .. " ScreenInsets = CoreUISafeInsets (IgnoreGuiInset = false)"
					end
				end
				addIssue(gctx, node, "unsafe_area", severity, "overlaps the " .. zone.label, fixes, extra)
				reported.unsafe = true
				break
			end
		end
	end

	-- touch_target
	if env.touch and c.interactive then
		local m = CONSTANTS.TOUCH_MIN
		if node.w < m - 0.01 or node.h < m - 0.01 then
			local severity = math.min(node.w, node.h) < CONSTANTS.TOUCH_ERROR and "error" or "warning"
			local fixes, extra = {}, nil
			if node.layoutClass == "UIGridLayout" then
				extra = "it is a UIGridLayout cell: raise the layout's " .. env.deviceType .. "_CellSize"
			else
				fixes = { { prop = "Size", value = suggestSize(node, math.max(node.w, m), math.max(node.h, m)) } }
				extra = "or keep the icon small and put it inside a larger transparent button"
			end
			addIssue(gctx, node, "touch_target", severity,
				size2(node.w, node.h) .. " is below the " .. m .. "x" .. m .. " touch minimum", fixes, extra)
		end
	end

	-- text
	if c.hasText then
		local pl, pt, pr, pb = paddingOf(obj, node.w, node.h, node.sChild)
		checkText(node, gctx, c, rect(node.x + pl, node.y + pt, node.w - pl - pr, node.h - pt - pb))
	end
	return reported
end

local function checkOverlap(kids, layoutClass, gctx)
	if S.refMode or layoutClass == "UIPageLayout" then
		return
	end
	local list = {}
	for _, k in kids do
		if (isA(k.obj, "GuiButton") or isA(k.obj, "TextBox")) and k.w > 0 and k.h > 0 then
			table.insert(list, k)
		end
	end
	if #list > CONSTANTS.MAX_OVERLAP_SIBLINGS then
		note("overlap check skipped for a container with " .. #list .. " buttons")
		return
	end
	local tol = CONSTANTS.TOLERANCE
	local function contains(outer, inner)
		return inner.x >= outer.x - tol and inner.y >= outer.y - tol
			and inner.x + inner.w <= outer.x + outer.w + tol and inner.y + inner.h <= outer.y + outer.h + tol
	end
	-- A button that fully contains the other and is either invisible (no background, text or image:
	-- a click catcher) or nearly as big as its parent (a modal backdrop) overlaps on purpose.
	local function isBackdrop(outer, inner)
		if not contains(outer, inner) then
			return false
		end
		local c = outer.c or classify(outer.obj)
		if not c.hasBg and not c.hasText and not c.hasImage then
			return true
		end
		local pc = outer.pc
		return pc and pc.w > 0 and pc.h > 0 and outer.w * outer.h >= 0.9 * pc.w * pc.h
	end
	for i = 2, #list do
		local b = list[i]
		for j = 1, i - 1 do
			local a = list[j]
			local inter = intersect(rect(a.x, a.y, a.w, a.h), rect(b.x, b.y, b.w, b.h))
			if inter and (isBackdrop(a, b) or isBackdrop(b, a)) then
				inter = nil
			end
			if inter and inter.w >= CONSTANTS.OVERLAP_MIN and inter.h >= CONSTANTS.OVERLAP_MIN then
				local frac = (inter.w * inter.h) / math.max(math.min(a.w * a.h, b.w * b.h), 1e-6)
				if frac >= CONSTANTS.OVERLAP_MIN_FRACTION then
					local severity = frac >= CONSTANTS.OVERLAP_ERROR_FRACTION and "error" or "warning"
					local otherName = tostring(tryGet(a.obj, "Name"))
					local fixes, extra = {}, nil
					if layoutClass then
						extra = "they are in a " .. layoutClass .. ": check its Padding and the children's sizes"
					else
						-- Suggest moving b just past a along the axis with the smaller overlap.
						-- Try both sides on both axes, smallest move first, and only suggest a spot
						-- that stays on screen and clear of a.
						local bounds = gctx.bounds
						local options = {
							{ a.x + a.w + 4, b.y }, { a.x - b.w - 4, b.y },
							{ b.x, a.y + a.h + 4 }, { b.x, a.y - b.h - 4 },
						}
						table.sort(options, function(p, q)
							return math.abs(p[1] - b.x) + math.abs(p[2] - b.y) < math.abs(q[1] - b.x) + math.abs(q[2] - b.y)
						end)
						for _, o in options do
							local nx, ny = o[1], o[2]
							if nx >= bounds.x and ny >= bounds.y and nx + b.w <= bounds.x + bounds.w and ny + b.h <= bounds.y + bounds.h then
								fixes = { { prop = "Position", value = suggestPosition(b, nx, ny, b.w, b.h) } }
								break
							end
						end
						if #fixes > 0 then
							extra = "or give " .. otherName .. " its own override, or put both in a UIListLayout"
						else
							extra = "no on-screen spot next to " .. otherName .. "; shrink one of them or put both in a UIListLayout"
						end
					end
					addIssue(gctx, b, "overlap", severity,
						"overlaps sibling button " .. otherName .. " by " .. size2(inter.w, inter.h) .. " (" .. fmt(frac * 100, 0) .. "% of the smaller)",
						fixes, extra)
				end
			end
		end
	end
end

local function visit(node, pctx)
	local obj = node.obj
	local c = classify(obj)
	node.c = c
	local reported = checkNode(node, pctx, c)
	if not S.refMode and not pctx.hiddenOff then
		-- devices on which this instance was audited (for the "parked offscreen" test)
		S.seen[obj] = S.seen[obj] or {}
		S.seen[obj][pctx.gctx.env.profile.name] = true
	end
	if S.rects and not S.refMode then
		local device = pctx.gctx.env.profile.name
		S.rects[device] = S.rects[device] or {}
		S.rects[device][node.path] = { x = round1(node.x), y = round1(node.y), w = round1(node.w), h = round1(node.h) }
	end

	local cctx = {
		gctx = pctx.gctx,
		clip = pctx.clip,
		offReported = pctx.offReported or reported.offscreen,
		clipReported = pctx.clipReported or reported.clipped,
		unsafeReported = pctx.unsafeReported or reported.unsafe,
		hiddenOff = pctx.hiddenOff or reported.entirelyOff,
		zeroReported = pctx.zeroReported or reported.zero,
		visible = pctx.visible,
	}
	local function narrowVisible(clipRect)
		if cctx.visible then
			-- nothing left visible -> an empty rect, so every intersect() with it fails
			cctx.visible = intersect(cctx.visible, clipRect) or rect(-1e9, -1e9, 0, 0)
		else
			cctx.visible = clipRect
		end
	end
	local pl, pt, pr, pb = paddingOf(obj, node.w, node.h, node.sChild)
	local content = rect(node.x + pl, node.y + pt, node.w - pl - pr, node.h - pt - pb)
	local pc = content

	if isA(obj, "ScrollingFrame") then
		approx("ScrollingFrame assumed scrolled to CanvasPosition 0,0")
		local xs, xo, ys, yo = udim2Parts(eff(obj, "CanvasSize"))
		local thickness = num(eff(obj, "ScrollBarThickness"), 0) * node.sChild
		local frameW = node.w
		if enumName(eff(obj, "VerticalScrollBarInset")) == "Always" then
			frameW -= thickness
		end
		local cw = math.max(frameW * xs + xo * node.sChild, frameW)
		local ch = math.max(node.h * ys + yo * node.sChild, node.h)
		local autoCanvas = enumName(eff(obj, "AutomaticCanvasSize")) or "None"
		local canvasPl, canvasPt, canvasPr, canvasPb = paddingOf(obj, cw, ch, node.sChild)
		if autoCanvas ~= "None" then
			approx("AutomaticCanvasSize grown from direct children")
			local base = rect(0, 0, frameW - canvasPl - canvasPr, node.h - canvasPt - canvasPb)
			local ok, kids = pcall(layoutChildren, obj, base, node.sChild, 1, "")
			if ok then
				local maxX, maxY = 0, 0
				for _, k in kids do
					maxX = math.max(maxX, k.x + k.w)
					maxY = math.max(maxY, k.y + k.h)
				end
				if autoCanvas == "X" or autoCanvas == "XY" then
					cw = math.max(cw, maxX + canvasPl + canvasPr)
				end
				if autoCanvas == "Y" or autoCanvas == "XY" then
					ch = math.max(ch, maxY + canvasPt + canvasPb)
				end
			end
		end
		local canvas = rect(node.x, node.y, cw, ch)
		pc = rect(canvas.x + canvasPl, canvas.y + canvasPt, cw - canvasPl - canvasPr, ch - canvasPt - canvasPb)
		cctx.clip = { rect = canvas, content = pc, path = node.path, scroll = true }
		narrowVisible(rect(node.x, node.y, node.w, node.h))
	elseif eff(obj, "ClipsDescendants") == true then
		if node.rotation ~= 0 then
			approx("ClipsDescendants ignored on rotated elements")
		else
			cctx.clip = { rect = rect(node.x, node.y, node.w, node.h), content = content, path = node.path, scroll = false }
			narrowVisible(cctx.clip.rect)
		end
	end

	local kids, layoutClass = layoutChildren(obj, pc, node.sChild, 1, node.path)
	for _, kid in kids do
		local ok, err = pcall(visit, kid, cctx)
		if not ok then
			note("error auditing " .. tostring(kid.path) .. ": " .. tostring(err))
		end
	end
	if not cctx.hiddenOff then
		checkOverlap(kids, layoutClass, pctx.gctx)
	end
end

-- ─── Devices ────────────────────────────────────────────────────────────────
local function normalizeProfile(p)
	if type(p) ~= "table" then
		return nil
	end
	local w, h
	local size = p.size
	if typeof(size) == "Vector2" then
		w, h = size.X, size.Y
	elseif type(size) == "table" then
		w = size.X or size.x or size[1]
		h = size.Y or size.y or size[2]
	end
	if type(w) ~= "number" or type(h) ~= "number" or w <= 0 or h <= 0 then
		return nil
	end
	local insets = p.safeInsets or p.insets or {}
	local l = num(insets.left or insets[1], 0)
	local t = num(insets.top or insets[2], 0)
	local r = num(insets.right or insets[3], 0)
	local b = num(insets.bottom or insets[4], 0)
	local vw, vh = w - l - r, h - t - b
	local device = p.device
	if not KNOWN_GROUPS[device or ""] or not table.find(DEVICE_TYPES, device) then
		if p.touch then
			device = math.min(vw, vh) < CONSTANTS.PHONE_MAX_SHORT_SIDE and "Phone" or "Tablet"
		else
			device = "Desktop"
		end
	end
	return {
		name = tostring(p.name or (device .. "_" .. w .. "x" .. h)),
		device = device,
		w = w,
		h = h,
		insets = { l, t, r, b },
		topbar = num(p.topbar, CONSTANTS.TOPBAR_HEIGHT),
		tvSafe = num(p.tvSafe, device == "Console" and CONSTANTS.CONSOLE_TV_SAFE or 0),
	}
end

local function buildEnv(profile)
	local w, h = profile.w, profile.h
	local l, t, r, b = table.unpack(profile.insets)
	local full = rect(0, 0, w, h)
	local ds = rect(l, t, w - l - r, h - t - b)
	local tb = profile.topbar
	local core = rect(ds.x, ds.y + tb, ds.w, ds.h - tb)
	local strip = rect(ds.x + CONSTANTS.TOPBAR_LEFT_RESERVED, ds.y, math.max(ds.w - CONSTANTS.TOPBAR_LEFT_RESERVED - CONSTANTS.TOPBAR_RIGHT_RESERVED, 0), tb)
	-- ResponsiveUI reads Camera.ViewportSize = the device-safe area.
	local orientation = ds.h > ds.w and "Portrait" or "Landscape"
	local zonesNotch = {}
	if l > 0 then table.insert(zonesNotch, { kind = "notch", label = "left notch / cutout area", rect = rect(0, 0, l, h) }) end
	if r > 0 then table.insert(zonesNotch, { kind = "notch", label = "right notch / cutout area", rect = rect(w - r, 0, r, h) }) end
	if t > 0 then table.insert(zonesNotch, { kind = "notch", label = "top notch / status bar area", rect = rect(0, 0, w, t) }) end
	if b > 0 then table.insert(zonesNotch, { kind = "notch", label = "bottom home-indicator area", rect = rect(0, h - b, w, b) }) end
	local zonesTopbar = {}
	if tb > 0 then
		table.insert(zonesTopbar, { kind = "topbar", label = "Roblox topbar buttons (top-left)", rect = rect(ds.x, ds.y, CONSTANTS.TOPBAR_LEFT_RESERVED, tb) })
		table.insert(zonesTopbar, { kind = "topbar", label = "Roblox topbar buttons (top-right)", rect = rect(ds.x + ds.w - CONSTANTS.TOPBAR_RIGHT_RESERVED, ds.y, CONSTANTS.TOPBAR_RIGHT_RESERVED, tb) })
	end
	local zonesTv = {}
	local tvRect = full
	if profile.tvSafe > 0 then
		local mx, my = w * profile.tvSafe, h * profile.tvSafe
		tvRect = rect(mx, my, w - 2 * mx, h - 2 * my)
		local label = "TV-safe margin (" .. fmt(profile.tvSafe * 100, 1) .. "% per edge)"
		table.insert(zonesTv, { kind = "tv", label = label, rect = rect(0, 0, mx, h) })
		table.insert(zonesTv, { kind = "tv", label = label, rect = rect(w - mx, 0, mx, h) })
		table.insert(zonesTv, { kind = "tv", label = label, rect = rect(0, 0, w, my) })
		table.insert(zonesTv, { kind = "tv", label = label, rect = rect(0, h - my, w, my) })
	end
	return {
		profile = profile,
		deviceType = profile.device,
		orientation = orientation,
		groups = groupsFor(profile.device, orientation),
		touch = profile.device == "Phone" or profile.device == "Tablet",
		viewport = { ds.w, ds.h },
		full = full,
		deviceSafe = ds,
		core = core,
		topbarStrip = strip,
		tvRect = tvRect,
		zonesNotch = zonesNotch,
		zonesTopbar = zonesTopbar,
		zonesTv = zonesTv,
	}
end

local function resolveDevices(requested)
	local builtins = {}
	for _, p in UIAudit.DEVICES do
		builtins[p.name] = p
	end
	local out, seen = {}, {}
	local function add(p)
		local np = normalizeProfile(p)
		if np and not seen[np.name] then
			seen[np.name] = true
			table.insert(out, np)
		elseif not np then
			note("ignored an invalid device profile")
		end
	end
	if type(requested) == "table" and #requested > 0 then
		for _, d in requested do
			if type(d) == "string" then
				if builtins[d] then
					add(builtins[d])
				elseif table.find(DEVICE_TYPES, d) then
					for _, p in UIAudit.DEVICES do
						if p.device == d then
							add(p)
						end
					end
				else
					note('unknown device "' .. d .. '" (built-ins: see UIAudit.DEVICES)')
				end
			else
				add(d)
			end
		end
		return out
	end
	local orientationSetting = nil
	pcall(function()
		orientationSetting = enumName(game:GetService("StarterGui").ScreenOrientation)
	end)
	local landscapeOnly = orientationSetting == "LandscapeLeft" or orientationSetting == "LandscapeRight" or orientationSetting == "LandscapeSensor"
	local portraitOnly = orientationSetting == "Portrait"
	for _, p in UIAudit.DEVICES do
		local np = normalizeProfile(p)
		local portrait = np and buildEnv(np).orientation == "Portrait"
		local touch = np and (np.device == "Phone" or np.device == "Tablet")
		if np and landscapeOnly and portrait then
			continue
		end
		if np and portraitOnly and touch and not portrait then
			continue
		end
		add(p)
	end
	return out
end

-- ─── ScreenGui per device ───────────────────────────────────────────────────
local function auditGui(gui, env)
	S.groups = env.groups
	if eff(gui, "Enabled") == false then
		return
	end
	local insets = enumName(eff(gui, "ScreenInsets")) or "CoreUISafeInsets"
	if eff(gui, "IgnoreGuiInset") == true and insets == "CoreUISafeInsets" then
		insets = "DeviceSafeInsets"
	end
	local container
	if insets == "None" then
		container = env.full
	elseif insets == "DeviceSafeInsets" then
		container = env.deviceSafe
	elseif insets == "TopbarSafeInsets" then
		approx("TopbarSafeInsets area estimated from CONSTANTS.TOPBAR_*_RESERVED")
		container = env.topbarStrip
	else
		container = env.core
	end
	local clipToSafe = eff(gui, "ClipToDeviceSafeArea") ~= false
	local bounds = (insets == "None" or not clipToSafe) and env.full or env.deviceSafe

	local zones = {}
	if insets == "None" or not clipToSafe then
		for _, z in env.zonesNotch do
			table.insert(zones, z)
		end
	end
	if insets ~= "TopbarSafeInsets" then
		for _, z in env.zonesTopbar do
			table.insert(zones, z)
		end
	end
	for _, z in env.zonesTv do
		table.insert(zones, z)
	end

	-- ResponsiveUI auto scale.
	local attrs = getAttrs(gui)
	local comps = getComps(gui)
	local guiScale = 1
	local reference = attrs.ReferenceResolution
	if typeof(reference) == "Vector2" and reference.X > 0 and reference.Y > 0 then
		local vx, vy = env.viewport[1], env.viewport[2]
		local scale = math.min(vx / reference.X, vy / reference.Y)
		local multiplier = resolveRaw(attrs, "ScaleMultiplier", attrs.ScaleMultiplier or 1)
		if type(multiplier) == "number" then
			scale *= multiplier
		end
		if type(attrs.MinScale) == "number" then
			scale = math.max(scale, attrs.MinScale)
		end
		if type(attrs.MaxScale) == "number" then
			scale = math.min(scale, attrs.MaxScale)
		end
		guiScale = scale
	elseif comps.scale then
		guiScale = num(eff(comps.scale, "Scale"), 1)
		if math.abs(guiScale) < 1e-3 then
			approx("UIScale with Scale 0 (pop-in animation) audited at Scale 1")
			guiScale = 1
		end
	end
	if guiScale ~= 1 then
		approx("UIScale on a ScreenGui: each child scaled around its own AnchorPoint, Position offsets unscaled (a UIListLayout/UIGridLayout directly in it is scaled as a whole)")
	end

	local pl, pt, pr, pb = paddingOf(gui, container.w, container.h, 1)
	local pc = rect(container.x + pl, container.y + pt, container.w - pl - pr, container.h - pt - pb)
	local name = S.guiNames[gui] or tostring(tryGet(gui, "Name") or "ScreenGui")
	local gctx = {
		gui = gui,
		name = name,
		env = env,
		insets = insets,
		container = container,
		bounds = bounds,
		zones = zones,
		coreRect = env.core,
		tvSafeRect = env.tvRect,
		scale = guiScale,
		autoscaled = typeof(reference) == "Vector2",
	}
	local kids, layoutClass = layoutChildren(gui, pc, 1, guiScale, name)
	local pctx = { gctx = gctx }
	for _, kid in kids do
		local ok, err = pcall(visit, kid, pctx)
		if not ok then
			note("error auditing " .. tostring(kid.path) .. ": " .. tostring(err))
		end
	end
	checkOverlap(kids, layoutClass, gctx)
end

-- ─── bad_override (device independent) ──────────────────────────────────────
local function relPath(obj, gui)
	local parts = {}
	local cur = obj
	while cur and cur ~= gui do
		table.insert(parts, 1, segmentOf(cur))
		cur = cur.Parent
	end
	table.insert(parts, 1, (S and S.guiNames and S.guiNames[gui]) or tostring(gui.Name))
	return table.concat(parts, ".")
end

local function checkOverrides(gui)
	local objects = { gui }
	local ok, desc = pcall(function()
		return gui:GetDescendants()
	end)
	if ok then
		for _, d in desc do
			table.insert(objects, d)
		end
	end
	local guiName = S.guiNames[gui] or tostring(gui.Name)
	for _, obj in objects do
		local okObj, err = pcall(function()
			local attrs = getAttrs(obj)
			local names = {}
			for attrName in attrs do
				table.insert(names, attrName)
			end
			table.sort(names)
			for _, attrName in names do
				local value = attrs[attrName]
				local function report(severity, detail, hint)
					table.insert(S.raw, {
						screenGui = guiName,
						device = "all",
						path = relPath(obj, gui),
						kind = "bad_override",
						severity = severity,
						detail = '"' .. attrName .. '": ' .. detail,
						rect = { x = 0, y = 0, w = 0, h = 0 },
						fixes = {},
						note = hint,
						obj = obj,
						gui = gui,
					})
				end
				local group, prop = parseOverride(attrName)
				if group then
					if PSEUDO_PROPERTIES[prop] then
						if not obj:IsA("ScreenGui") then
							report("warning", "ScaleMultiplier overrides only work on a ScreenGui", "move it to the ScreenGui that has ReferenceResolution")
						elseif type(value) ~= "number" then
							report("error", "must be a number, got " .. typeof(value), "recreate it as a number attribute")
						end
					else
						local base = tryGet(obj, prop)
						if base == nil then
							local hint = "check the property name (case-sensitive)"
							local fixedCase = string.upper(string.sub(prop, 1, 1)) .. string.sub(prop, 2)
							if fixedCase ~= prop and tryGet(obj, fixedCase) ~= nil then
								hint = "rename it to " .. group .. "_" .. fixedCase
							end
							report("error", tostring(obj.ClassName) .. ' has no property "' .. prop .. '"', hint)
						elseif coerce(base, value) == nil then
							local expected = typeof(base)
							if expected == "EnumItem" then
								expected = "EnumItem / string name of " .. tostring(base.EnumType)
							end
							report("error", "wrong type: " .. prop .. " is " .. expected .. ", attribute is " .. typeof(value) .. " (" .. tostring(value) .. ")",
								"delete it and re-add it as a " .. typeof(base) .. " attribute")
						end
					end
				else
					local g, p = string.match(attrName, "^(%a+)_(%w+)$")
					if g then
						local lower = string.lower(g)
						local suggestion = KNOWN_GROUPS_LOWER[lower] or GROUP_ALIASES[lower]
						if suggestion and tryGet(obj, p) ~= nil then
							report("warning", 'unknown group "' .. g .. '", so ResponsiveUI ignores it', "rename it to " .. suggestion .. "_" .. p)
						end
					end
					if attrName == "ReferenceResolution" then
						if not obj:IsA("ScreenGui") then
							report("warning", "only works on a ScreenGui", "move it to the ScreenGui")
						elseif typeof(value) ~= "Vector2" or value.X <= 0 or value.Y <= 0 then
							report("error", "must be a Vector2 with positive X and Y", "e.g. Vector2.new(1920, 1080)")
						end
					elseif (attrName == "MinScale" or attrName == "MaxScale" or attrName == "ScaleMultiplier") and obj:IsA("ScreenGui") and type(value) ~= "number" then
						report("error", "must be a number, got " .. typeof(value), "recreate it as a number attribute")
					end
				end
			end
		end)
		if not okObj then
			note("error checking attributes: " .. tostring(err))
		end
	end
end

-- ─── Grouping, hints, report ────────────────────────────────────────────────
local SEVERITY_RANK = { error = 1, warning = 2, info = 3 }

local function groupMembers(group, profiles, envs)
	local members = {}
	for i, p in profiles do
		local env = envs[i]
		for _, g in env.groups do
			if g == group then
				members[p.name] = true
			end
		end
	end
	return members
end

-- The object a fix is applied to (fixes with a target go on the ScreenGui).
local function fixObject(issue, f)
	return f.target and issue.gui or issue.obj
end

-- On this device, the index into env.groups of the last group that already has an override
-- attribute for one of the fixed properties (0 = none). A new override only takes effect if its
-- group is at least this late in ResponsiveUI's order.
local function overrideFloor(issue, env)
	local floor = 0
	for _, f in ipairs(issue.fixes or {}) do
		local target = fixObject(issue, f)
		if target and f.prop then
			local attrs = getAttrs(target)
			for i, g in env.groups do
				if attrs[g .. "_" .. f.prop] ~= nil then
					floor = math.max(floor, i)
				end
			end
		end
	end
	return floor
end

-- The narrowest ResponsiveUI group whose audited devices include every failing device and that
-- would not be outranked by an override the element already has on any of them.
-- nil = change the property itself; false = no single group works (use one per device).
local function chooseGroup(failing, floors, envByName, profiles, envs)
	local allFail = true
	local types = {}
	for _, p in profiles do
		types[p.device] = true
		if not failing[p.name] then
			allFail = false
		end
	end
	local typeCount = 0
	for _ in types do
		typeCount += 1
	end
	local anyOverride = false
	for name in failing do
		if (floors[name] or 0) > 0 then
			anyOverride = true
		end
	end
	if allFail and typeCount >= 3 and not anyOverride then
		return nil
	end
	-- Ties go to the earlier (simpler) group: Phone before PhoneLandscape.
	local candidates = {}
	for _, d in DEVICE_TYPES do
		table.insert(candidates, d)
	end
	table.insert(candidates, "Touch")
	for _, d in DEVICE_TYPES do
		for _, o in ORIENTATIONS do
			table.insert(candidates, d .. o)
		end
	end
	table.insert(candidates, "Landscape")
	table.insert(candidates, "Portrait")
	local best, bestCount = nil, math.huge
	for _, g in candidates do
		local members = groupMembers(g, profiles, envs)
		local ok = true
		for name in failing do
			local env = envByName[name]
			local idx = env and table.find(env.groups, g)
			if not members[name] or not idx or idx < (floors[name] or 0) then
				ok = false
				break
			end
		end
		if ok then
			local count = 0
			for _ in members do
				count += 1
			end
			if count < bestCount then
				best, bestCount = g, count
			end
		end
	end
	return best or false
end

-- Group for one device when no shared group works: its device type, unless an existing,
-- later override would mask that; then device + orientation (always applied last).
local function deviceGroup(env, floor)
	local groups = env.groups
	local typeIdx = table.find(groups, env.deviceType) or #groups
	if typeIdx >= floor then
		return env.deviceType
	end
	return groups[#groups]
end

local function fixText(issue, group)
	local parts = {}
	for _, f in ipairs(issue.fixes or {}) do
		local where = f.target and ("on " .. f.target .. " ") or ""
		if group then
			local name = group .. "_" .. f.prop
			local target = fixObject(issue, f)
			local exists = target and getAttrs(target)[name] ~= nil
			table.insert(parts, where .. (exists and "update existing attribute " or "set attribute ") .. name .. " = " .. f.value)
		else
			table.insert(parts, where .. "set " .. f.prop .. " = " .. f.value)
		end
	end
	return table.concat(parts, "; ")
end

local PARKED_NOTE = "entirely offscreen on every audited device, so it looks parked for a tween: no fix suggested."
	.. " To audit it, temporarily move it on screen (or audit with root = it at its open Position);"
	.. " if it is NOT tweened in, move it on screen"

-- Picks entries to keep when there are more than maxIssues: first the most severe entry of every
-- ScreenGui and every device, then round-robin over (ScreenGui, device) buckets, severity tier by tier.
local function selectIssues(out, maxIssues, profiles)
	local keep, kept = {}, 0
	local function take(e)
		if not keep[e] and kept < maxIssues then
			keep[e] = true
			kept += 1
		end
	end
	local guiSeen = {}
	for _, e in out do
		if not guiSeen[e.screenGui] then
			guiSeen[e.screenGui] = true
			take(e)
		end
	end
	for _, p in profiles do
		local covered = false
		for e in keep do
			if table.find(e._devs, p.name) then
				covered = true
				break
			end
		end
		if not covered then
			for _, e in out do
				if table.find(e._devs, p.name) then
					take(e)
					break
				end
			end
		end
	end
	for _, tier in { "error", "warning", "info" } do
		local buckets, order = {}, {}
		for _, e in out do
			if e.severity == tier and not keep[e] then
				local key = e.screenGui .. "|" .. e.device
				if not buckets[key] then
					buckets[key] = {}
					table.insert(order, key)
				end
				table.insert(buckets[key], e)
			end
		end
		local round = 1
		local more = true
		while more and kept < maxIssues do
			more = false
			for _, key in order do
				local e = buckets[key][round]
				if e then
					more = true
					take(e)
				end
			end
			round += 1
		end
	end
	local selected, byGui, byDevice = {}, {}, {}
	for _, e in out do
		if keep[e] then
			table.insert(selected, e)
		else
			byGui[e.screenGui] = (byGui[e.screenGui] or 0) + 1
			for _, d in e._devs do
				byDevice[d] = (byDevice[d] or 0) + 1
			end
		end
	end
	return selected, byGui, byDevice
end

local function buildIssues(profiles, envs, minSeverity, maxIssues, perDevice)
	local envByName = {}
	for i, p in profiles do
		envByName[p.name] = envs[i]
	end
	-- Group raw issues per INSTANCE + kind (two siblings with the same name never share a fix).
	local objIds, nextId = {}, 0
	local groupsByKey, order = {}, {}
	for _, issue in S.raw do
		local obj = issue.obj
		local id = obj and objIds[obj]
		if obj and not id then
			nextId += 1
			id = nextId
			objIds[obj] = id
		end
		local key = issue.screenGui .. "|" .. tostring(id or issue.path) .. "|" .. issue.kind .. "|" .. (issue.device == "all" and issue.detail or "")
		if not groupsByKey[key] then
			groupsByKey[key] = {}
			table.insert(order, key)
		end
		table.insert(groupsByKey[key], issue)
	end

	local deviceIndex = { all = 0 }
	for i, p in profiles do
		deviceIndex[p.name] = i
	end
	local passes = function(severity)
		return (SEVERITY_RANK[severity] or 3) <= (SEVERITY_RANK[minSeverity] or 2)
	end

	local out = {}
	for _, key in order do
		local list = groupsByKey[key]
		-- Parked for a tween: entirely offscreen on every device it was audited on.
		if list[1].kind == "offscreen" and list[1].obj then
			local parked = true
			local failingSet = {}
			for _, issue in list do
				if not (issue.flags and issue.flags.entirelyOff) then
					parked = false
				end
				failingSet[issue.device] = true
			end
			for device in S.seen[list[1].obj] or {} do
				if not failingSet[device] then
					parked = false
				end
			end
			if parked then
				for _, issue in list do
					issue.kind = "offscreen_parked"
					issue.severity = "info"
					issue.fixes = {}
					issue.fit = 1
					issue.note = PARKED_NOTE
				end
			end
		end

		-- The primary entry carries the shared hint: the device that needed the most shrinking,
		-- then the smallest screen.
		local primary = list[1]
		for _, issue in list do
			local fi, fp = issue.fit or 1, primary.fit or 1
			if fi < fp - 1e-9 or (math.abs(fi - fp) <= 1e-9 and issue.area and primary.area and issue.area < primary.area) then
				primary = issue
			end
		end
		local failing, failingNames, floors = {}, {}, {}
		for _, issue in list do
			if issue.device ~= "all" and not failing[issue.device] then
				failing[issue.device] = true
				table.insert(failingNames, issue.device)
				floors[issue.device] = issue.env and overrideFloor(issue, issue.env) or 0
			end
		end
		table.sort(failingNames, function(a, b)
			return (deviceIndex[a] or 999) < (deviceIndex[b] or 999)
		end)
		local group = nil
		if primary.device ~= "all" and #(primary.fixes or {}) > 0 then
			group = chooseGroup(failing, floors, envByName, profiles, envs)
		end
		local function groupOf(issue)
			if group == false then
				return issue.env and deviceGroup(issue.env, floors[issue.device] or 0) or issue.deviceType
			end
			return group
		end
		local primaryGroup = groupOf(primary)
		local primaryFix = fixText(primary, primaryGroup)
		local function hintFor(issue)
			local g = groupOf(issue)
			if g == primaryGroup then
				return primaryFix, true
			end
			return fixText(issue, g), false
		end
		local function withNote(fix, issue)
			if issue.note then
				fix = (fix ~= "" and (fix .. "; ") or "") .. issue.note
			end
			return fix ~= "" and fix or "see detail"
		end

		if perDevice then
			for _, issue in list do
				local fix, same = hintFor(issue)
				local hint
				local alsoOn = nil
				if issue == primary then
					hint = withNote(fix, issue)
					if #failingNames > 1 then
						alsoOn = {}
						for _, n in failingNames do
							if n ~= issue.device then
								table.insert(alsoOn, n)
							end
						end
					end
				elseif same then
					hint = "same fix as " .. primary.device .. (fix ~= "" and (": " .. fix) or "")
				else
					hint = fix ~= "" and fix or "see detail"
				end
				if passes(issue.severity) then
					table.insert(out, {
						screenGui = issue.screenGui,
						device = issue.device,
						path = issue.path,
						kind = issue.kind,
						severity = issue.severity,
						detail = issue.detail,
						rect = issue.rect,
						hint = hint,
						alsoOn = alsoOn,
						_devs = { issue.device },
					})
				end
			end
		else
			-- One entry per instance + kind: the primary device's rect and detail, every failing
			-- device, the worst severity, and every distinct fix (one per group when no group fits all).
			local severity = primary.severity
			for _, issue in list do
				if (SEVERITY_RANK[issue.severity] or 3) < (SEVERITY_RANK[severity] or 3) then
					severity = issue.severity
				end
			end
			if passes(severity) then
				local fixes, seenFix = {}, {}
				local function addFix(f)
					if f ~= "" and not seenFix[f] then
						seenFix[f] = true
						table.insert(fixes, f)
					end
				end
				addFix(primaryFix)
				if group == false then
					for _, name in failingNames do
						for _, issue in list do
							if issue.device == name then
								addFix((hintFor(issue)))
								break
							end
						end
					end
				end
				local devices = #failingNames > 0 and failingNames or { primary.device }
				table.insert(out, {
					screenGui = primary.screenGui,
					device = primary.device,
					devices = devices,
					path = primary.path,
					kind = primary.kind,
					severity = severity,
					detail = primary.detail,
					rect = primary.rect,
					hint = withNote(table.concat(fixes, "; "), primary),
					_devs = devices,
				})
			end
		end
	end

	table.sort(out, function(a, b)
		local ra, rb = SEVERITY_RANK[a.severity] or 3, SEVERITY_RANK[b.severity] or 3
		if ra ~= rb then
			return ra < rb
		end
		if a.screenGui ~= b.screenGui then
			return a.screenGui < b.screenGui
		end
		local da, db = deviceIndex[a.device] or 999, deviceIndex[b.device] or 999
		if da ~= db then
			return da < db
		end
		if a.path ~= b.path then
			return a.path < b.path
		end
		if a.kind ~= b.kind then
			return a.kind < b.kind
		end
		return a.detail < b.detail
	end)

	local counts = { error = 0, warning = 0, info = 0 }
	local perGui = {}
	for _, issue in out do
		counts[issue.severity] = (counts[issue.severity] or 0) + 1
		perGui[issue.screenGui] = (perGui[issue.screenGui] or 0) + 1
	end
	local truncated, byGui, byDevice = 0, nil, nil
	if #out > maxIssues then
		truncated = #out - maxIssues
		out, byGui, byDevice = selectIssues(out, maxIssues, profiles)
	end
	for _, e in out do
		e._devs = nil
	end
	return out, counts, perGui, truncated, byGui, byDevice
end

local function collectGuis(root, nameFilter)
	local guis = {}
	local filterPath = nil
	if isA(root, "ScreenGui") then
		guis = { root }
	elseif isA(root, "GuiObject") then
		local cur = root.Parent
		while cur and not isA(cur, "ScreenGui") do
			cur = cur.Parent
		end
		if cur then
			guis = { cur }
			S.guiNames[cur] = segmentOf(cur)
			filterPath = relPath(root, cur)
		end
	else
		local ok, desc = pcall(function()
			return root:GetDescendants()
		end)
		if ok then
			for _, d in desc do
				if isA(d, "ScreenGui") then
					-- skip ScreenGuis nested in another ScreenGui under root
					local nested = false
					local cur = d.Parent
					while cur and cur ~= root do
						if isA(cur, "ScreenGui") then
							nested = true
							break
						end
						cur = cur.Parent
					end
					if not nested then
						table.insert(guis, d)
					end
				end
			end
		end
	end
	if type(nameFilter) == "table" and #nameFilter > 0 then
		local filtered = {}
		for _, g in guis do
			if table.find(nameFilter, g.Name) then
				table.insert(filtered, g)
			end
		end
		guis = filtered
	end
	for _, g in guis do
		S.guiNames[g] = S.guiNames[g] or segmentOf(g) -- "HUD#2" for a second ScreenGui named HUD
	end
	return guis, filterPath
end

function UIAudit.run(options)
	options = options or {}
	S = {
		attrs = {},
		comps = {},
		textCache = {},
		approximations = {},
		approxSet = {},
		notes = {},
		noteSet = {},
		raw = {},
		refAspect = {},
		seen = {},
		guiNames = {},
		groups = {},
		refMode = false,
		rects = options.includeRects and {} or nil,
	}
	local okText, textService = pcall(function()
		return game:GetService("TextService")
	end)
	S.TextService = okText and textService or nil

	approx("Rects computed from properties (Position/Size/AnchorPoint/UIScale/UIPadding/constraints), not read from the engine")
	approx("Insets: topbar " .. CONSTANTS.TOPBAR_HEIGHT .. "px, Roblox topbar buttons assumed in the left "
		.. CONSTANTS.TOPBAR_LEFT_RESERVED .. "px / right " .. CONSTANTS.TOPBAR_RIGHT_RESERVED
		.. "px of it, iPhone notch 59px + home bar 21px, console TV-safe " .. fmt(CONSTANTS.CONSOLE_TV_SAFE * 100, 1) .. "%")

	local root = options.root
	if root == nil then
		local ok, sg = pcall(function()
			return game:GetService("StarterGui")
		end)
		root = ok and sg or nil
	end
	local maxIssues = num(options.maxIssues, CONSTANTS.MAX_ISSUES)
	local minSeverity = SEVERITY_RANK[options.minSeverity or ""] and options.minSeverity or CONSTANTS.MIN_SEVERITY

	local profiles = resolveDevices(options.devices)
	local envs = {}
	local deviceNames = {}
	for i, p in profiles do
		envs[i] = buildEnv(p)
		deviceNames[i] = p.name
	end

	local guis, filterPath = {}, nil
	if root then
		guis, filterPath = collectGuis(root, options.screenGuis)
	else
		note("no root: StarterGui not found")
	end
	S.filterPath = filterPath

	local refProfile = nil
	for _, p in UIAudit.DEVICES do
		if p.name == CONSTANTS.REFERENCE_PROFILE then
			refProfile = normalizeProfile(p)
		end
	end
	local refEnv = refProfile and buildEnv(refProfile)

	for _, gui in guis do
		local ok, err = pcall(checkOverrides, gui)
		if not ok then
			note("error checking overrides on " .. tostring(gui.Name) .. ": " .. tostring(err))
		end
		if refEnv then
			S.refMode = true
			pcall(auditGui, gui, refEnv)
			S.refMode = false
		end
		for _, env in envs do
			local okGui, errGui = pcall(auditGui, gui, env)
			if not okGui then
				note("error auditing " .. tostring(gui.Name) .. " on " .. env.profile.name .. ": " .. tostring(errGui))
			end
		end
	end

	local issues, counts, perGui, truncated, byGui, byDevice = buildIssues(profiles, envs, minSeverity, maxIssues, options.perDevice == true)
	local screenGuis = {}
	for _, gui in guis do
		local name = S.guiNames[gui] or tostring(gui.Name)
		table.insert(screenGuis, { name = name, issueCount = perGui[name] or 0 })
	end
	local report = {
		devices = deviceNames,
		screenGuis = screenGuis,
		issues = issues,
		counts = counts,
		truncated = truncated,
		truncatedByScreenGui = byGui,
		truncatedByDevice = byDevice,
		approximations = S.approximations,
		notes = S.notes,
		rects = S.rects,
	}
	S = nil
	return report
end

function UIAudit.runJSON(options)
	options = options or {}
	if options.maxIssues == nil then
		-- keep the default JSON under ~10k tokens (MCP tool output limit); pass maxIssues for more
		options = table.clone(options)
		options.maxIssues = CONSTANTS.MAX_ISSUES_JSON
	end
	local report = UIAudit.run(options)
	return game:GetService("HttpService"):JSONEncode(report)
end

function UIAudit.format(report)
	local lines = {}
	table.insert(lines, string.format("UIAudit: %d error, %d warning, %d info on %d devices (%s)%s",
		report.counts.error, report.counts.warning, report.counts.info, #report.devices,
		table.concat(report.devices, ", "),
		report.truncated > 0 and (", " .. report.truncated .. " more not shown") or ""))
	for _, i in report.issues do
		local r = i.rect
		local others = i.alsoOn
		if not others and i.devices and #i.devices > 1 then
			others = {}
			for _, d in i.devices do
				if d ~= i.device then
					table.insert(others, d)
				end
			end
		end
		table.insert(lines, string.format("[%s] %s %s %s: %s @(%s,%s %sx%s) -> %s%s",
			i.severity, i.device, i.path, i.kind, i.detail, fmt(r.x, 0), fmt(r.y, 0), fmt(r.w, 0), fmt(r.h, 0), i.hint,
			others and (" [also: " .. table.concat(others, ", ") .. "]") or ""))
	end
	if report.truncated > 0 then
		local parts = {}
		for _, d in report.devices do
			local n = report.truncatedByDevice and report.truncatedByDevice[d]
			if n then
				table.insert(parts, d .. " " .. n)
			end
		end
		for _, g in report.screenGuis do
			local n = report.truncatedByScreenGui and report.truncatedByScreenGui[g.name]
			if n then
				table.insert(parts, g.name .. " " .. n)
			end
		end
		table.insert(lines, "not shown: " .. table.concat(parts, ", ") .. " (re-run with screenGuis / devices / root to see them)")
	end
	if #report.notes > 0 then
		table.insert(lines, "notes: " .. table.concat(report.notes, " | "))
	end
	table.insert(lines, "approximations: " .. table.concat(report.approximations, " | "))
	return table.concat(lines, "\n")
end

function UIAudit.runText(options)
	return UIAudit.format(UIAudit.run(options))
end

-- Resolves a report path ("HUD.Panel.Buy", "HUD.TextButton#2") to the instance. Names may contain
-- dots; "#n" means the nth child with that name in GetChildren() order. root defaults to StarterGui.
function UIAudit.find(path, root)
	local node = root or game:GetService("StarterGui")
	local parts = string.split(path, ".")
	local i = 1
	local function child(parent, segment)
		local name, n = string.match(segment, "^(.*)#(%d+)$")
		n = tonumber(n)
		if not name or not n or n < 2 then
			name, n = segment, 1
		end
		local count = 0
		for _, c in parent:GetChildren() do
			if c.Name == name then
				count += 1
				if count == n then
					return c
				end
			end
		end
		return nil
	end
	while i <= #parts do
		local found
		for j = #parts, i, -1 do -- longest match first, for names containing dots
			found = child(node, table.concat(parts, ".", i, j))
			if found then
				i = j + 1
				break
			end
		end
		if not found then
			return nil
		end
		node = found
	end
	return node
end

-- Test hook: the value ResponsiveUI would give obj[prop] on deviceType + orientation.
function UIAudit._effective(obj, deviceType, orientation, prop)
	local saved = S
	S = { attrs = {}, comps = {}, approxSet = {}, approximations = {}, noteSet = {}, notes = {}, groups = groupsFor(deviceType, orientation) }
	local value = eff(obj, prop)
	S = saved
	return value
end

return UIAudit
