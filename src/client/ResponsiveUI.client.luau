--[[
	ResponsiveUI (LocalScript)
	Put this in: StarterPlayer > StarterPlayerScripts

	Makes UI adapt to each device using ATTRIBUTES ONLY. You never need to edit
	this script to lay out a new screen: just add attributes to the UI objects.

	────────────────────────────────────────────────────────────────────────────
	1) PER-DEVICE PROPERTY OVERRIDES
	────────────────────────────────────────────────────────────────────────────
	On any object inside a ScreenGui (Frame, TextLabel, ImageButton, UIPadding,
	UIGridLayout, UIStroke, the ScreenGui itself, ...) add an attribute named

	    <Group>_<PropertyName>

	whose value is what that property should be on that device. Examples:

	    Phone_Size            UDim2    {0.9, 0}, {0.3, 0}
	    Tablet_Position       UDim2    {0.5, 0}, {0.8, 0}
	    Console_Visible       boolean  false
	    Touch_TextSize        number   32
	    PhonePortrait_Size    UDim2    only when a phone is held upright
	    Desktop_AnchorPoint   Vector2  0.5, 1

	Groups, applied in this order (later ones win):
	    Portrait | Landscape                   any device, by screen shape
	    Touch                                  Phone and Tablet
	    Phone | Tablet | Desktop | Console     the device
	    PhonePortrait, TabletLandscape, ...    device + orientation

	The value the property itself has in Studio is the default, used when no
	group matches. Removing an override attribute restores that default.
	The attribute type must match the property type (UDim2 for Size/Position,
	Vector2 for AnchorPoint, number for TextSize/Transparency, etc.).

	Don't add overrides for a property that your own scripts/tweens also change:
	on a device change the override (or the Studio default) is re-applied.

	────────────────────────────────────────────────────────────────────────────
	2) AUTO SCALING (for UI sized with Offset / pixels)
	────────────────────────────────────────────────────────────────────────────
	On a ScreenGui add:
	    ReferenceResolution   Vector2  the screen size you designed at, e.g. 1920, 1080
	    MinScale / MaxScale   number   optional limits, e.g. 0.5 / 1.5
	    ScaleMultiplier       number   optional; also per group, e.g. Phone_ScaleMultiplier = 1.25

	This creates a UIScale named "ResponsiveScale" in that ScreenGui. Don't put
	another UIScale directly in the same ScreenGui. Scale-sized (percentage) UI
	already adapts, so don't use ReferenceResolution on it or it scales twice.

	Tip: leave the ScreenGui's ScreenInsets at its default (CoreUISafeInsets) for
	buttons and menus; it keeps UI clear of phone notches AND the Roblox top bar.
	Use None only for full-screen backgrounds.

	────────────────────────────────────────────────────────────────────────────
	3) READING THE DEVICE FROM OTHER LOCALSCRIPTS
	────────────────────────────────────────────────────────────────────────────
	Players.LocalPlayer gets these attributes (they update live):
	    DeviceType    "Phone" | "Tablet" | "Desktop" | "Console"
	    Orientation   "Portrait" | "Landscape"
	    IsTouch       boolean (true for Phone and Tablet)

	    local player = game:GetService("Players").LocalPlayer
	    if player:GetAttribute("DeviceType") == "Phone" then ... end
	    player:GetAttributeChangedSignal("DeviceType"):Connect(function() ... end)

	────────────────────────────────────────────────────────────────────────────
	4) TESTING
	────────────────────────────────────────────────────────────────────────────
	Studio's device emulator works. You can also set these attributes on this
	script (before Play, or while playing on the copy under
	Players > <you> > PlayerScripts):
	    ForceDevice        "Phone" | "Tablet" | "Desktop" | "Console"
	    ForceOrientation   "Portrait" | "Landscape"

	Attribute changes made while playing apply immediately. Typos in property
	names or wrong attribute types print one warning per object in Output.
]]

local Players = game:GetService("Players")
local GuiService = game:GetService("GuiService")
local UserInputService = game:GetService("UserInputService")

-- Touch screens whose short side is below this (in viewport units) count as phones.
local PHONE_MAX_SHORT_SIDE = 600
local SCALE_NAME = "ResponsiveScale"

local DEVICES = { "Phone", "Tablet", "Desktop", "Console" }
local ORIENTATIONS = { "Portrait", "Landscape" }

local KNOWN_GROUPS = { Touch = true }
for _, orientationName in ORIENTATIONS do
	KNOWN_GROUPS[orientationName] = true
end
for _, deviceName in DEVICES do
	KNOWN_GROUPS[deviceName] = true
	for _, orientationName in ORIENTATIONS do
		KNOWN_GROUPS[deviceName .. orientationName] = true
	end
end

-- Override names handled by this script rather than set as real properties.
local PSEUDO_PROPERTIES = { ScaleMultiplier = true }
-- Plain (ungrouped) ScreenGui attributes that affect auto scaling.
local SCALE_ATTRIBUTES = { ReferenceResolution = true, MinScale = true, MaxScale = true, ScaleMultiplier = true }

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local deviceType = nil
local orientation = nil
local activeGroups = {}

local defaults = setmetatable({}, { __mode = "k" }) -- [Instance] = { [property] = Studio value }
local scaledGuis = setmetatable({}, { __mode = "k" }) -- [ScreenGui] = true
local warned = setmetatable({}, { __mode = "k" }) -- [Instance] = { [message] = true }

local function warnOnce(object, message)
	local seen = warned[object]
	if not seen then
		seen = {}
		warned[object] = seen
	end
	if seen[message] then
		return
	end
	seen[message] = true
	warn(`[ResponsiveUI] {object:GetFullName()}: {message}`)
end

-- "Phone_Size" -> "Phone", "Size". Returns nil for attributes that aren't overrides.
local function parseOverride(attributeName)
	local group, property = string.match(attributeName, "^(%a+)_(%w+)$")
	if group and KNOWN_GROUPS[group] then
		return group, property
	end
	return nil, nil
end

-- Picks the value for `property` from the active groups, falling back to `default`.
local function resolve(attributes, property, default)
	local value = default
	for _, group in activeGroups do
		local override = attributes[group .. "_" .. property]
		if override ~= nil then
			value = override
		end
	end
	return value
end

local function getViewportSize()
	local camera = workspace.CurrentCamera
	return if camera then camera.ViewportSize else Vector2.new(1920, 1080)
end

local function detect()
	local viewport = getViewportSize()

	local forcedOrientation = script:GetAttribute("ForceOrientation")
	local newOrientation
	if typeof(forcedOrientation) == "string" and table.find(ORIENTATIONS, forcedOrientation) then
		newOrientation = forcedOrientation
	else
		newOrientation = if viewport.Y > viewport.X then "Portrait" else "Landscape"
	end

	local forcedDevice = script:GetAttribute("ForceDevice")
	local newDevice
	if typeof(forcedDevice) == "string" and table.find(DEVICES, forcedDevice) then
		newDevice = forcedDevice
	elseif GuiService:IsTenFootInterface() then
		newDevice = "Console"
	elseif UserInputService.TouchEnabled and not UserInputService.MouseEnabled then
		newDevice = if math.min(viewport.X, viewport.Y) < PHONE_MAX_SHORT_SIDE then "Phone" else "Tablet"
	else
		newDevice = "Desktop"
	end

	return newDevice, newOrientation
end

local function applyOverrides(object)
	local attributes = object:GetAttributes()

	local objectDefaults = defaults[object]
	for name in attributes do
		local group, property = parseOverride(name)
		if group and not PSEUDO_PROPERTIES[property] then
			if not objectDefaults then
				objectDefaults = {}
				defaults[object] = objectDefaults
			end
			-- Remember the Studio value the first time a property gets an override.
			if objectDefaults[property] == nil then
				local ok, value = pcall(function()
					return object[property]
				end)
				-- object[name] also finds children, so reject Instances (e.g. a child named "Size").
				if ok and value ~= nil and typeof(value) ~= "Instance" then
					objectDefaults[property] = value
				else
					warnOnce(object, `"{name}": {object.ClassName} has no property "{property}"`)
				end
			end
		end
	end

	if not objectDefaults then
		return
	end

	for property, default in objectDefaults do
		local value = resolve(attributes, property, default)
		if object[property] ~= value then
			local ok, err = pcall(function()
				object[property] = value
			end)
			if not ok then
				warnOnce(object, `can't set {property} to {typeof(value)} {value}: {err}`)
			end
		end
	end
end

local function updateScale(screenGui)
	local reference = screenGui:GetAttribute("ReferenceResolution")
	local uiScale = screenGui:FindFirstChild(SCALE_NAME)

	if typeof(reference) ~= "Vector2" or reference.X <= 0 or reference.Y <= 0 then
		if reference ~= nil then
			warnOnce(screenGui, "ReferenceResolution must be a Vector2 with positive X and Y")
		end
		if uiScale and uiScale:IsA("UIScale") then
			uiScale:Destroy()
		end
		scaledGuis[screenGui] = nil
		return
	end
	scaledGuis[screenGui] = true

	local viewport = getViewportSize()
	local scale = math.min(viewport.X / reference.X, viewport.Y / reference.Y)

	local attributes = screenGui:GetAttributes()
	local multiplier = resolve(attributes, "ScaleMultiplier", attributes.ScaleMultiplier or 1)
	if type(multiplier) == "number" then
		scale *= multiplier
	else
		warnOnce(screenGui, "ScaleMultiplier attributes must be numbers")
	end
	if type(attributes.MinScale) == "number" then
		scale = math.max(scale, attributes.MinScale)
	end
	if type(attributes.MaxScale) == "number" then
		scale = math.min(scale, attributes.MaxScale)
	end

	if not (uiScale and uiScale:IsA("UIScale")) then
		uiScale = Instance.new("UIScale")
		uiScale.Name = SCALE_NAME
		uiScale.Parent = screenGui
	end
	uiScale.Scale = scale
end

local function refresh(object)
	applyOverrides(object)
	if object:IsA("ScreenGui") then
		updateScale(object)
	end
end

local function track(object)
	refresh(object)
	object.AttributeChanged:Connect(function(name)
		if parseOverride(name) or (SCALE_ATTRIBUTES[name] and object:IsA("ScreenGui")) then
			refresh(object)
		end
	end)
end

local function updateEnvironment()
	local newDevice, newOrientation = detect()

	if newDevice ~= deviceType or newOrientation ~= orientation then
		deviceType, orientation = newDevice, newOrientation

		activeGroups = { orientation }
		if deviceType == "Phone" or deviceType == "Tablet" then
			table.insert(activeGroups, "Touch")
		end
		table.insert(activeGroups, deviceType)
		table.insert(activeGroups, deviceType .. orientation)

		player:SetAttribute("DeviceType", deviceType)
		player:SetAttribute("Orientation", orientation)
		player:SetAttribute("IsTouch", deviceType == "Phone" or deviceType == "Tablet")

		for object in defaults do
			applyOverrides(object)
		end
	end

	-- The scale depends on the exact viewport size, so update it on every resize.
	for screenGui in scaledGuis do
		updateScale(screenGui)
	end
end

local viewportConnection = nil
local function watchCamera()
	if viewportConnection then
		viewportConnection:Disconnect()
		viewportConnection = nil
	end
	local camera = workspace.CurrentCamera
	if camera then
		viewportConnection = camera:GetPropertyChangedSignal("ViewportSize"):Connect(updateEnvironment)
	end
	updateEnvironment()
end

watchCamera()
workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)
script.AttributeChanged:Connect(updateEnvironment)

for _, object in playerGui:GetDescendants() do
	track(object)
end
playerGui.DescendantAdded:Connect(track)
