# ModedUI

A batteries-included Roblox UI library built on [Fluent](https://github.com/dawid-scripts/Fluent) by dawid-scripts.
You build tabs and elements like in Fluent; ModedUI saves every element automatically and adds profiles,
autosave, a player profile card, animations, a URL background, search, overlays, rate-limited
notifications and a full Settings tab.

```lua
local ModedUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/XITHHUB/ModedUI/main/ModedUI.lua"))()

local Window = ModedUI:CreateWindow({
	Title = "My Hub",
	Folder = "MyHub", -- configs are saved to MyHub/<PlayerName>.json
})

local Main = Window:Tab("Main", "home")
local Combat = Main:Section("Combat")

Combat:Toggle("AutoParry", {
	Title = "Auto parry",
	Description = "Parries automatically.",
	Default = false,
	Callback = function(enabled)
		print("Auto parry:", enabled)
	end,
})
```

Run the full example (one of every element plus the Window API):

```lua
loadstring(game:HttpGet("https://raw.githubusercontent.com/XITHHUB/ModedUI/main/Example.lua"))()
```

## Files

| File | What it is |
| --- | --- |
| `ModedUI.lua` | The library |
| `Example.lua` | Example hub: a Main tab with every element type and an API tab |
| `Standalone/FluentModded.lua` | The original all-in-one script from v1.0 (runs on its own; no profile card or new animations) |

## Features

- **Config**: one JSON file per player (`<Folder>/<PlayerName>.json`) holding all profiles. Create, duplicate, rename, delete and reset profiles; export/import JSON with validation; confirm dialogs for destructive actions.
- **Autosave**: on/off and delay (0.5–10 s) in Settings → Config, stored in the file header. Writes only when something changed; a slider drag causes one write, not hundreds.
- **Safety**: a corrupt file is backed up to `.bak` and defaults are loaded; the format is versioned with migrations; bad values are rejected per element.
- **Images**: background image and a title bar logo from a link, downloaded once and cached (`writefile` + `getcustomasset`). Discord links, WebP/GIF/AVIF (converted to PNG), GitHub and imgur pages all work; optional `rbxassetid` fallback; transparency/dim/visibility controls for the background.
- **Window**: player profile card (avatar, display name, @username) above the search bar, menu key (RightControl by default), floating toggle button + auto-fit on mobile, remembered position and size, search across all tabs (Ctrl+F), Lucide tab icons.
- **Animations**: open/close styles (Zoom, Fade, Slide, Pop or None), smooth fade when the theme or accent changes, a moving gradient on the window border and the profile ring, and a rainbow accent with a speed slider.
- **Appearance**: theme, live accent colour, UI scale 0.75–1.25, font size (Small/Normal/Large), acrylic blur toggle (off by default).
- **Notifications**: Info/Success/Warning/Error icons, never more than 3 on screen, mute switch.
- **Overlays**: watermark (refreshed once per second), draggable keybind list, Info tab (game, server, session, changelog).
- **Hide & lock**: hide/show and lock/unlock any tab, section or element. Locked things stay visible but dimmed, can't be clicked (a click or hover shows the reason), and locked keybinds don't fire.
- **Empty tabs**: a tab with no sections or elements shows a "Coming Soon" card with a sad face instead of a blank page. The text and image can be changed per tab, and the card disappears as soon as you add something.
- **Elements**: tooltips, search keywords, searchable dropdowns (more than 10 options) with `:Refresh(values)`, numeric inputs with Min/Max, every callback wrapped in `pcall` (errors become Error toasts).
- **Settings tab**: Interface, Animations, Background, Config and Performance (Rejoin, Copy JobId, Reload UI, Unload).
- **Performance**: the whole build is themed in one pass, services and globals are cached, one timer for autosave, everything is cleaned up by a Maid, and executing the script twice replaces the old window. The moving gradient and window animations are native tweens; the rainbow accent recolours only accent parts 20 times per second; both pause while the window is hidden, and the theme fade only runs while colours change.

## CreateWindow options

Every option is optional.

| Option | Default | Description |
| --- | --- | --- |
| `Title` | `"ModedUI"` | Window title (also used in the watermark and toasts) |
| `SubTitle` | `"v" .. Version` | Text next to the title |
| `Version` | `"1.0.0"` | Your hub's version, shown in the Info tab |
| `Folder` | `"ModedUI"` | Config folder in the executor workspace (letters, digits, `-`, `_`). It also identifies the window, so give every hub its own |
| `BackgroundUrl` | `""` | Default background image (image link, Discord link or asset id) |
| `Logo` | `""` | Image in front of the window title (image link, Discord link or asset id) |
| `ImageConverter` | `"https://wsrv.nl/?url=%s&output=png"` | Converts WebP/GIF/AVIF… to PNG (`false` = never) |
| `FallbackAssetId` | `""` | `rbxassetid` (digits only) used when the URL can't be loaded |
| `Theme` | `"Dark"` | Default theme |
| `MenuKey` | `"RightControl"` | Default menu key (name or `Enum.KeyCode`) |
| `Size` | `Vector2.new(580, 460)` | Default window size (`Vector2` or `UDim2.fromOffset`) |
| `TabWidth` | `160` | Width of the tab list |
| `AutoSave` | `true` | Autosave setting for new config files |
| `AutoSaveDelay` | `1` | Seconds without changes before a write (0.5–10) |
| `MaxNotifications` | `3` | Toasts on screen at once |
| `InfoTab` | `true` | Add the Info tab |
| `SettingsTab` | `true` | Add the Settings tab |
| `ShowWatermark` | `true` | Watermark default |
| `ShowKeybindList` | `true` | Keybind list default |
| `PlayerCard` | `true` | Player profile card above the search bar |
| `AnimationStyle` | `"Zoom"` | Open/close animation: `"Zoom"`, `"Fade"`, `"Slide"`, `"Pop"` or `"None"` |
| `ThemeFade` | `true` | Fade theme and accent changes instead of snapping |
| `MovingGradient` | `true` | Animated gradient on the window border and profile ring |
| `RainbowAccent` | `false` | Accent colour cycles through the rainbow |
| `RainbowSpeed` | `3` | 1 (20 s per cycle) to 10 (2 s per cycle) |
| `EmptyTab` | `{ Title = "Coming Soon", Text = "Nothing here yet. Check back later!", Image = "frown" }` | Card for tabs with no sections or elements (`false` turns it off) |
| `WelcomeToast` | `true` | "Loaded in 0.07s" toast |
| `Changelog` | `{ "v1.0.0", "• First release" }` | Lines shown in the Info tab |
| `Reload` | your script | Function that Reload UI runs; defaults to the script that called `CreateWindow` |
| `FluentUrl` | Fluent's latest release | Where Fluent is downloaded from (cached for reloads) |

## Elements

Value elements take `(id, config)`. The id is the save key, and `Window.Options[id]` is the element.
Callbacks run once with the loaded value when the element is created, then once per real change.

```lua
local Section = Tab:Section("Title") -- elements can also go straight on a tab

Section:Toggle(id, { Title, Description, Default = false, Callback = function(value) end })
Section:Slider(id, { Title, Min = 0, Max = 100, Default = 50, Rounding = 0, Callback = function(number) end })
Section:Input(id, { Title, Default = "", Placeholder, MaxLength, Finished, Callback = function(text) end })
Section:Input(id, { Title, Numeric = true, Min = 1, Max = 15, Decimals = 0, Default = "5", Callback = function(number) end })
Section:Dropdown(id, { Title, Values = { "A", "B" }, Default = "A", AllowNull, Callback = function(value) end })
Section:Dropdown(id, { Title, Values = { "A", "B" }, Multi = true, Default = { "A" }, Callback = function(set, list) end })
Section:Colorpicker(id, { Title, Default = Color3.new(1, 1, 1), Transparency = 0, Callback = function(color, transparency) end })
Section:Keybind(id, { Title, Default = "E", Mode = "Toggle", Callback = function(state) end, ChangedCallback = function(key, mode) end })
Section:Paragraph(id, { Title, Content }) -- saved; returns :Set(title, content), :SetTitle(text), :SetDesc(text)
Section:Paragraph({ Title, Content })     -- not saved
Section:Button({ Title, Description, Callback = function() end })
```

Extra fields on every element:

| Field | What it does |
| --- | --- |
| `Tooltip` | Hover text (desktop) |
| `Keywords` | Extra words for the search bar |
| `Save = false` | Don't save this element (e.g. a player list) |

Keybinds: `Mode` is `"Toggle"`, `"Hold"` (callback gets `true` on press and `false` on release) or `"Always"`; right-click the row to cycle the mode.
Dropdowns: `Window.Options[id]:Refresh(newValues)` replaces the options and keeps every selection that still exists.

## Window API

```lua
Window:Tab(title, icon, options)                 -- icon: Lucide name, e.g. "home", "code", "user"
Window:GetTab(title)                             -- the tab object, or nil
Window:SelectTab(title)                          -- also accepts a tab object
Window:HideTab(title) / Window:ShowTab(title)
Window:LockTab(title, reason) / Window:UnlockTab(title)
Window:Notify(title, content, duration, type)    -- type: "Info" | "Success" | "Warning" | "Error"
Window:Confirm(title, content, onConfirm, confirmText) -- dialogs open the window first if it is hidden
Window:Dialog({ Title, Content, Buttons = { { Title = "OK", Callback = function() end } } })
Window:Connect(signal, callback)                 -- disconnected on unload; errors become toasts
Window:OnUnload(callback)                        -- undo what your script changed
Window:RefreshDropdown(id, values)
Window:RefreshKeybinds()                         -- after changing a keybind's Toggled state yourself
Window:SetBackground(url)
Window:SetLogo(url)                              -- "" removes it
Window:Toggle(open)                              -- true = open, false = close, nil = flip
Window:IsReady()                                 -- false while building and after unload
Window:Finalize()                                -- optional, see below
Window:Unload()
Window:Reload()

Window.Options                                   -- every element by id
Window.Config.Save()                             -- true when the file was written
Window.Config.Load() / .Reset() / .Delete()
Window.Config.Switch(name) / .Create(name) / .Duplicate(name) / .Rename(name)
Window.Config.Profiles() / .Current() / .Path() / .HasFileAccess
Window.Config.Export() / .Import(json)
Window.Fluent, Window.FluentWindow, Window.Version
```

The Info and Settings tabs, the saved window position and the welcome toast are added right after your
script finishes building (or first yields). Tabs you add later still work and still sort above Info and
Settings; call `Window:Finalize()` yourself if you want that step to happen at a specific point.

The built-in settings are elements too, so your script can read or change them through `Window.Options`:

```lua
Window.Options.UI_AnimationStyle:SetValue("Pop")
Window.Options.UI_RainbowAccent:SetValue(true)
Window.Options.UI_Theme:SetValue("Rose")
```

Calling `ModedUI:CreateWindow` again creates another independent window (give it a different `Folder`).
Every window has its own watermark and keybind list, so turn those off on extra windows with
`ShowWatermark = false` and `ShowKeybindList = false` if one set is enough.

## Images (background and logo)

```lua
local Window = ModedUI:CreateWindow({
	Title = "My Hub",
	Logo = "https://raw.githubusercontent.com/you/repo/main/logo.png", -- 20 px, in front of the title
	BackgroundUrl = "https://i.imgur.com/abc123.webp",
})
Window:SetLogo("rbxassetid://1234567890") -- change it later ("" removes it)
```

Accepted: direct image links (PNG and JPG load directly; WebP, GIF, AVIF, BMP and SVG are converted to PNG
through `ImageConverter`), Discord attachment links, GitHub `blob` pages, `imgur.com/<id>` pages, Dropbox
links, `rbxassetid://…` and plain asset ids. Every image is downloaded once and loaded from
`<Folder>/cache` after that.

Discord links stop working after about a day. A logo or background that already loaded keeps working
from the cache on that PC, but for a script you share, put the image somewhere permanent (for example
your GitHub repo) and use that link.

## Hide and lock

Tabs, sections and elements share the same methods. Elements are reached through
`Window.Options[id]` (or the value an element call returns); buttons and paragraphs return their own object.

```lua
Tab:Hide()                Tab:Show()                Tab:SetVisible(true)       Tab:IsVisible()
Tab:Lock("VIP only")      Tab:Unlock()              Tab:SetLocked(true, why)   Tab:IsLocked()
Tab:Select()              -- tabs only
```

```lua
local Chapter2 = Window:Tab("Book 1 Chapter 2", "home")
Chapter2:Lock("Finish Chapter 1 first!")         -- the tab opens a lock screen with the reason
Window:HideTab("Book 2 Chapter 3")               -- gone from the tab list until ShowTab

local Farm = Main:Section("Auto farm")
Farm:Lock("Coming in the next update")           -- dims the whole section

Window.Options.AutoParry:Lock("Unlocks at level 10") -- one element
Window.Options.AutoParry:Hide()
```

- Hiding is visual only: hidden elements keep their values and keybinds, and the search bar skips them.
  Hiding the selected tab switches to the first visible one.
- Locking blocks mouse input with a dimmed overlay: clicking it shows the reason in a toast, and hovering
  shows it as a tooltip. A locked keybind doesn't fire, and the keybind list shows it as `LOCK`.
- Scripts can still change locked values with `:SetValue()`. Locks and hidden states aren't saved in the
  config, so set them from your script each time it runs.

## Empty tabs

A tab without sections or elements shows a card with a sad face until you add something to it:

```lua
Window:Tab("Book 1 Chapter 2", "home") -- shows "Coming Soon"

local Chapter3 = Window:Tab("Book 1 Chapter 3", "home", {
	EmptyTitle = "Not Supported",
	EmptyText = "This chapter isn't supported yet.",
	EmptyImage = "frown", -- Lucide icon name, asset id or rbxassetid:// URL
})

Chapter3:SetEmpty("Coming Soon", "Being worked on right now!") -- change it later
```

Set `EmptyTab = { Title = …, Text = …, Image = … }` in `CreateWindow` to change the default for every
tab, or `EmptyTab = false` to turn the card off.

## Config file

```json
{
  "ConfigVersion": 2,
  "Player": "PlayerName",
  "AutoLoad": true,
  "AutoSave": true,
  "AutoSaveDelay": 1,
  "LastProfile": "Default",
  "Profiles": {
    "Default": {
      "Values": {
        "AutoParry": true,
        "FieldOfView": 90,
        "FavoriteFruit": "Mango",
        "AlertEvents": ["A player joins"],
        "HighlightColor": { "R": 96, "G": 205, "B": 255, "A": 0.5 },
        "ZoomKey": { "Key": "LeftAlt", "Mode": "Hold" }
      },
      "Window": { "X": 120, "Y": 80, "W": 580, "H": 460 },
      "Overlays": {},
      "SavedAt": 1790000000
    }
  }
}
```

Colours are stored as `{R, G, B}` (0–255, plus `A` for transparency) and keys by their `KeyCode` name.
With autosave off, changes are written only by Save now (switching profiles or reloading drops unsaved changes).

## Executor support

ModedUI feature-detects every optional function once and falls back safely:

| Function | Used for | Without it |
| --- | --- | --- |
| `writefile`, `readfile`, `isfile`, `isfolder`, `makefolder` | Config file | Settings work but only live in memory (a warning toast says so) |
| `getcustomasset` | Background and logo from links | `FallbackAssetId` / asset ids still work; links don't |
| `listfiles`, `delfile` | Clearing the image cache | The Clear cache button reports it is unavailable |
| `setclipboard` | Copy JobId, Export | The text is shown in a toast or printed to the console (F9) |
| `getgenv` | Double-load guard, Fluent cache | `_G` is used |
| `debug.getupvalues`, `getgc` | Fast theme and accent updates | A slower recolour pass is used |
| `protectgui` | Protecting the overlay GUI | The overlays are parented next to Fluent's GUI unprotected |
| `identifyexecutor` | Info tab | Shows "Unknown" |

## Credits

UI components by [Fluent](https://github.com/dawid-scripts/Fluent) (MIT) by dawid-scripts.
ModedUI downloads Fluent at runtime; it does not include Fluent's code.
