# Roblox project notes for Claude

## UI layout across devices: use ResponsiveUI attributes

`src/client/ResponsiveUI.client.luau` is a LocalScript in StarterPlayerScripts.
It handles per-device UI layout. **Don't write device-detection code or
per-device layout scripts.** Set attributes on the UI objects instead. The
script header has the full reference.

With Studio MCP access, set the attributes in edit mode (they persist in the place):

```lua
local panel = game.StarterGui.HUD.Panel
panel:SetAttribute("Phone_Size", UDim2.fromScale(0.9, 0.3))          -- phones
panel:SetAttribute("PhonePortrait_Position", UDim2.fromScale(0.5, 0.9))
panel:SetAttribute("Touch_TextSize", 32)                              -- phones + tablets
panel:SetAttribute("Console_Visible", false)
game.StarterGui.HUD:SetAttribute("ReferenceResolution", Vector2.new(1920, 1080)) -- Offset-based UI only
```

- Attribute name: `<Group>_<Property>`. Groups, applied in order with later
  ones winning: `Portrait`/`Landscape`, `Touch`, `Phone`/`Tablet`/`Desktop`/`Console`,
  then device + orientation (`PhonePortrait`, `TabletLandscape`, ...).
- The property's own value is the default for devices with no override.
- The attribute type must match the property type.
- To check a layout, set the `ForceDevice` / `ForceOrientation` attributes on
  the ResponsiveUI script. Watch Output for `[ResponsiveUI]` warnings.
- In other LocalScripts, read `Players.LocalPlayer:GetAttribute("DeviceType")`,
  `"Orientation"` and `"IsTouch"`. Don't detect the device again.

## Fixing UI across devices

`src/tools/UIAudit.luau` checks every StarterGui ScreenGui against phone, tablet,
desktop and console viewport sizes. It reports offscreen elements, notch and
topbar overlap, overlapping buttons, small touch targets, small or overflowing
text, clipping and bad ResponsiveUI overrides. It uses the same override rules
as ResponsiveUI. To run it by hand through Studio MCP (`run_code` /
`execute_luau`, edit mode), paste the file's full source into the wrapper:

```lua
local UIAudit = (function()
	-- paste the full contents of src/tools/UIAudit.luau here
end)()
print(UIAudit.runJSON({ screenGuis = { "HUD" }, minSeverity = "warning" })) -- all options are optional
```

To fix everything automatically, ask Claude to **"run the fix-ui workflow"**
(`.claude/workflows/fix-ui.js`). It takes optional args, for example
`{screenGuis: ["HUD"], devices: [...], maxRounds: 3, playtest: false}`. Device
names must match `UIAudit.DEVICES` exactly (the workflow stops and lists the
valid names otherwise); `maxRounds` is capped at 6. Studio must be open in edit
mode. The workflow:

- backs up each ScreenGui it edits to `ServerStorage.FixUI_Work.Backup`
  (a backup left by an earlier run is moved to `Backup_previous`)
- fixes problems with ResponsiveUI attributes
- has an independent reviewer check the edits
- reports what changed and how to undo it

Delete `ServerStorage.FixUI_Work` once you are happy with the result.

**Rule:** UI work is only done when the audit is clean, meaning no errors or
warnings on any device. Anything left over is explicitly accepted with a
reason, such as a panel that a script tweens in from offscreen.
