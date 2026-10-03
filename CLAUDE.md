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
