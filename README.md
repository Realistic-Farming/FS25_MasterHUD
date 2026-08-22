# FS25_MasterHUD

**Version:** 1.0.0.0
**Author:** TisonK

The UI renderer bedrock of the Realistic Farming mod ecosystem. MasterHUD is mod 3 in the load order. It owns the single draw loop that renders every companion mod's overlay, in a pull model: companions flip a dirty flag instead of rebuilding HUD strings every frame, and MasterHUD calls their fetch callback only when the data actually changed. It also handles menu-suspend, corner stacking, and unload cleanup once for all of them.

There are no settings and nothing to configure. Install it, keep it loaded, and let the companion mods use it.

## Player controls

| Key | Action |
|-----|--------|
| `Shift+H` | Hide / show every suite HUD at once (`MH_TOGGLE_ALL_HUDS`) |
| *Edit HUD Layout* action | Toggle suite layout edit mode - every registered companion HUD outlines in orange and can be dragged with the mouse; exiting saves positions (`MH_EDIT_HUDS`, no default key - assign one under Options > Controls > Mods) |

## How companion mods use it

Three registration paths, guarded against MasterHUD being absent:

```lua
-- 1. Simple text overlay that MasterHUD renders and lays out:
if g_masterHUD then
    g_masterHUD:registerOverlay("MyMod_Overlay", {
        anchor = "ANCHOR_TOP_RIGHT",   -- or TOP_LEFT / BOTTOM_LEFT / BOTTOM_RIGHT
        width = 0.22, fontSize = 14, bgAlpha = 0.6, priority = 20,
    }, function()
        return { "Line one", { left = "Label", right = "value" } }  -- strings or {left,right}
    end)
end
-- when the displayed values change (not every frame):
if g_masterHUD then g_masterHUD:markDirty("MyMod_Overlay") end

-- 2. Self-drawn element (the mod draws its own content; MasterHUD owns the loop + suspend):
g_masterHUD:subscribe("MyMod_Trail", { draw = function() ... end })

-- 3. Interactive panel (self-draw + input):
g_masterHUD:registerPanel("MyMod_Panel", {
    draw    = function() ... end,
    onMouse = function(posX, posY, isDown, isUp, button) return handled end,
    isFullscreen = false, adminOnly = false,
})
```

Call `g_masterHUD:unregisterOverlay(id)` / `unregisterPanel(id)` in your `delete()`.

- **registerOverlay** is for read-only text stacked in a screen corner. The fetch callback runs inside `pcall`, only when the overlay is dirty, and must be fast (format pre-computed values, no heavy math). Multiple overlays in the same anchor stack vertically by `priority` (lower is closer to the corner).
- **subscribe** is for a self-drawn display element, including world-space or positional drawing (for example spray / harvest / tillage trails) that does not fit the corner-anchored text model. MasterHUD owns draw ordering and menu-suspend; the mod draws its own content.
- **registerPanel** adds mouse (and, reserved, keyboard) input, plus optional `adminOnly` gating so only the server admin sees and drives the panel.

## Suspend and visibility

MasterHUD suspends all drawing and input while any menu or dialog is open, so no companion needs to check menu state. `g_masterHUD:setOverlayVisible(id, bool)` toggles an individual element (a keybind or the settings app can drive this).

## Console

- `mhStatus` - list registered overlays and panels and the suspend state.
