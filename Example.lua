--[[
	ModedUI · Example
	A "Main" tab with one of every element type (each one saved per profile automatically) and an
	"API" tab that shows the Window helpers. The Info and Settings tabs are added by the library.

	loadstring(game:HttpGet("https://raw.githubusercontent.com/XITHHUB/ModedUI/main/Example.lua"))()

	Everything this example changes is local to you and is undone when the UI unloads
	(Settings → Performance → Unload, or the X button in the title bar).
]]

local ModedUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/XITHHUB/ModedUI/main/ModedUI.lua"))()

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")
local LocalPlayer = Players.LocalPlayer

local Window = ModedUI:CreateWindow({
	Title = "ModedUI Example",
	Version = "1.0.0",
	Folder = "ModedUIExample", -- config file: ModedUIExample/<YourName>.json
	Changelog = { "v1.0.0", "• Example hub for ModedUI" },
})
local Options = Window.Options -- every element by id, e.g. Options.FieldOfView.Value

--════════════════════════════════════════════════════════════════════════════
-- State and helpers
--════════════════════════════════════════════════════════════════════════════
local State = {
	Highlight = false,
	Color = Color3.fromRGB(96, 205, 255),
	Alpha = 0.5,
	Mode = "Fill + Outline",
	FovEnabled = false,
	Fov = 70,
	ToastSeconds = 5,
	Alerts = {} :: { [string]: boolean },
}

local ZOOM = TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local KINDS = { "Info", "Success", "Warning", "Error" }
local FRUITS = {
	"Apple", "Apricot", "Avocado", "Banana", "Blackberry", "Blueberry", "Cherry", "Coconut",
	"Cranberry", "Dragonfruit", "Durian", "Fig", "Grape", "Grapefruit", "Guava", "Kiwi",
	"Lemon", "Lime", "Lychee", "Mango", "Melon", "Orange", "Papaya", "Peach", "Pear",
	"Pineapple", "Plum", "Pomegranate", "Raspberry", "Strawberry",
}

local highlight: Highlight? = nil
local originalFov: number? = nil -- camera FOV before "Custom field of view" was turned on
local zoomRestore: number? = nil -- camera FOV before "Hold to zoom" was pressed
local zooming = false
local zoomTween: Tween? = nil
local rosterThread: thread? = nil
local testIndex = 0

local function updateHighlight()
	local character = LocalPlayer.Character
	if not State.Highlight or not character then
		if highlight then
			highlight:Destroy()
			highlight = nil
		end
		return
	end
	if not highlight or highlight.Parent ~= character then
		if highlight then
			highlight:Destroy()
		end
		local created = Instance.new("Highlight")
		created.Name = "ModedUIExampleHighlight"
		created.DepthMode = Enum.HighlightDepthMode.Occluded
		created.Parent = character
		highlight = created
	end
	local target = highlight :: Highlight
	target.FillColor = State.Color
	target.OutlineColor = State.Color
	target.FillTransparency = if State.Mode == "Outline only" then 1 else State.Alpha
	target.OutlineTransparency = if State.Mode == "Fill only" then 1 else 0
end

local function applyFov()
	local camera = Workspace.CurrentCamera
	if not camera or zooming then
		return
	end
	if State.FovEnabled then
		originalFov = originalFov or camera.FieldOfView
		camera.FieldOfView = State.Fov
	elseif originalFov then
		camera.FieldOfView = originalFov
		originalFov = nil
	end
end

local function setZoom(active: boolean)
	local camera = Workspace.CurrentCamera
	if not camera or active == zooming then
		return
	end
	zooming = active
	if zoomTween then
		zoomTween:Cancel()
	end
	if active then
		zoomRestore = camera.FieldOfView
	end
	local tween = TweenService:Create(camera, ZOOM, { FieldOfView = if active then 30 else (zoomRestore or 70) })
	zoomTween = tween
	tween:Play()
end

local function otherPlayerNames(): { string }
	local names = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= LocalPlayer then
			table.insert(names, player.Name)
		end
	end
	table.sort(names)
	return names
end

-- Runs when the UI unloads: put everything back the way it was.
Window:OnUnload(function()
	if zoomTween then
		zoomTween:Cancel()
		zoomTween = nil
	end
	if rosterThread and coroutine.status(rosterThread) == "suspended" then
		task.cancel(rosterThread)
	end
	rosterThread = nil
	if highlight then
		highlight:Destroy()
		highlight = nil
	end
	local camera = Workspace.CurrentCamera
	local restore = originalFov or (if zooming then zoomRestore else nil)
	if camera and restore then
		camera.FieldOfView = restore
	end
	zooming, originalFov = false, nil
end)

--════════════════════════════════════════════════════════════════════════════
-- Main tab: one of every element. The first argument is the element's id, which is also its
-- save key; callbacks run once with the loaded value, then once per real change.
--════════════════════════════════════════════════════════════════════════════
local Main = Window:Tab("Main", "home")

-- Character ------------------------------------------------------------------
local Character = Main:Section("Character")

Character:Toggle("HighlightSelf", {
	Title = "Highlight my character",
	Description = "Adds a local-only Highlight to your avatar.",
	Tooltip = "Only you can see it. It is removed when the UI unloads.",
	Default = false,
	Callback = function(enabled: boolean)
		State.Highlight = enabled
		updateHighlight()
		local key = Options.HighlightKey
		if key then
			key.Toggled = enabled -- keeps the keybind list's ON/OFF in sync
			Window:RefreshKeybinds()
		end
	end,
})

Character:Colorpicker("HighlightColor", {
	Title = "Highlight colour",
	Description = "Fill and outline colour (with transparency).",
	Tooltip = "Click to open the colour picker. Changes apply when you press Done.",
	Default = Color3.fromRGB(96, 205, 255),
	Transparency = 0.5, -- a number here enables the transparency slider
	Callback = function(color: Color3, transparency: number)
		State.Color = color
		State.Alpha = transparency
		updateHighlight()
	end,
})

Character:Dropdown("HighlightMode", {
	Title = "Highlight style",
	Description = "What part of the highlight is drawn.",
	Tooltip = "Single-choice dropdown.",
	Values = { "Fill + Outline", "Fill only", "Outline only" },
	Default = "Fill + Outline",
	Callback = function(mode: string?)
		State.Mode = mode or "Fill + Outline"
		updateHighlight()
	end,
})

Character:Keybind("HighlightKey", {
	Title = "Toggle highlight",
	Description = "Press to flip the highlight on/off.",
	Tooltip = "Click the key box to rebind. Right-click the row to cycle Toggle/Hold/Always.",
	Default = "H",
	Mode = "Toggle",
	Callback = function()
		local toggle = Options.HighlightSelf
		toggle:SetValue(not toggle.Value)
	end,
})

Window:Connect(LocalPlayer.CharacterAdded, function()
	task.defer(updateHighlight) -- re-apply after respawning
end)

-- Camera ---------------------------------------------------------------------
local Camera = Main:Section("Camera")

Camera:Toggle("FovEnabled", {
	Title = "Custom field of view",
	Description = "Overrides the camera FOV while enabled.",
	Tooltip = "The original FOV is restored when you turn this off or unload.",
	Default = false,
	Callback = function(enabled: boolean)
		State.FovEnabled = enabled
		applyFov()
	end,
})

Camera:Slider("FieldOfView", {
	Title = "Field of view",
	Description = "Degrees (used while the toggle above is on).",
	Tooltip = "Drag or click the rail.",
	Min = 30,
	Max = 120,
	Default = 70,
	Rounding = 0,
	Callback = function(value: number)
		State.Fov = value
		applyFov()
	end,
})

Camera:Keybind("ZoomKey", {
	Title = "Hold to zoom",
	Description = "Zooms in while the key is held.",
	Tooltip = "Hold-mode keybind: the callback gets true on press and false on release.",
	Default = "LeftAlt",
	Mode = "Hold",
	Callback = function(held: boolean)
		setZoom(held)
	end,
})

-- Inputs & lists -------------------------------------------------------------
local Inputs = Main:Section("Inputs & lists")

local notes = Inputs:Paragraph("NotesParagraph", { -- with an id, a paragraph is saved too
	Title = "Notes",
	Content = "Nothing written yet.",
	Tooltip = "Paragraph whose text is saved per profile.",
})

Inputs:Input("NotesInput", {
	Title = "Note",
	Description = "Text typed here is copied into the Notes paragraph.",
	Tooltip = "Live text input (saved).",
	Placeholder = "Type a note…",
	Default = "",
	MaxLength = 120,
	Callback = function(text: string)
		notes:SetDesc(if text ~= "" then text else "Nothing written yet.")
	end,
})

Inputs:Input("ToastSeconds", {
	Title = "Toast duration",
	Description = "Seconds, 1–15 (numeric-only input).",
	Tooltip = "Letters are rejected and values are clamped to the range. Press Enter or click away.",
	Numeric = true,
	Min = 1,
	Max = 15,
	Decimals = 0,
	Default = "5",
	Callback = function(seconds: number) -- numeric inputs pass a number
		State.ToastSeconds = seconds
	end,
})

Inputs:Dropdown("FavoriteFruit", {
	Title = "Favourite fruit",
	Description = "30 options, so it gets a search box.",
	Tooltip = "Open it and type to filter.",
	Values = FRUITS,
	Default = "Mango",
	Keywords = "item list searchable", -- extra words for the window's search bar
})

Inputs:Dropdown("AlertEvents", {
	Title = "Alert me when",
	Description = "Multi-select: pick any combination.",
	Tooltip = "Shows a toast for the selected events.",
	Values = { "A player joins", "A player leaves", "I respawn" },
	Multi = true,
	Default = { "A player joins" },
	Callback = function(selected: { [string]: boolean })
		State.Alerts = selected
	end,
})

Inputs:Dropdown("TargetPlayer", {
	Title = "Player",
	Description = "Refreshes itself when players join or leave.",
	Tooltip = "Not saved (Save = false): player lists change between servers.",
	Values = otherPlayerNames(),
	Save = false,
	AllowNull = true,
	Callback = function(name: string?)
		if name and Window:IsReady() then -- skip the call made while the UI is being built
			Window:Notify("Player", "Selected " .. name, 3, "Info")
		end
	end,
})

Inputs:Button({
	Title = "Refresh player list",
	Description = "Calls option:Refresh(values) on the dropdown above.",
	Tooltip = "Keeps the current selection when that player is still here.",
	Callback = function()
		Options.TargetPlayer:Refresh(otherPlayerNames())
		Window:Notify("Player list", string.format("%d other player(s).", #Options.TargetPlayer.Values), 3, "Success")
	end,
})

local function onRoster(player: Player, joined: boolean)
	-- Debounced refresh: a burst of joins rebuilds the list once.
	if rosterThread and coroutine.status(rosterThread) == "suspended" then
		task.cancel(rosterThread)
	end
	rosterThread = task.delay(0.5, function()
		rosterThread = nil
		Window:RefreshDropdown("TargetPlayer", otherPlayerNames())
	end)
	local label = string.format("%s (@%s)", player.DisplayName, player.Name)
	if joined and State.Alerts["A player joins"] then
		Window:Notify("Player joined", label, 4, "Info")
	elseif not joined and State.Alerts["A player leaves"] then
		Window:Notify("Player left", label, 4, "Info")
	end
end

Window:Connect(Players.PlayerAdded, function(player)
	onRoster(player, true)
end)
Window:Connect(Players.PlayerRemoving, function(player)
	onRoster(player, false)
end)
Window:Connect(LocalPlayer.CharacterAdded, function()
	if State.Alerts["I respawn"] then
		Window:Notify("Respawned", "Welcome back.", 3, "Info")
	end
end)

-- Notifications --------------------------------------------------------------
local Toasts = Main:Section("Notifications")

Toasts:Button({
	Title = "Send test notification",
	Description = "Cycles Info → Success → Warning → Error.",
	Tooltip = "Window:Notify(title, content, duration, type).",
	Callback = function()
		testIndex = testIndex % #KINDS + 1
		local kind = KINDS[testIndex]
		Window:Notify(kind .. " notification", "This is what a " .. kind:lower() .. " toast looks like.", State.ToastSeconds, kind)
	end,
})

Toasts:Button({
	Title = "Spam 10 notifications",
	Description = "Shows the rate limiter: never more than 3 on screen.",
	Tooltip = "The oldest toast is dismissed to make room for the newest.",
	Callback = function()
		for index = 1, 10 do
			Window:Notify("Spam test", string.format("Toast #%d of 10", index), State.ToastSeconds, KINDS[(index - 1) % 4 + 1])
		end
	end,
})

Toasts:Button({
	Title = "Trigger a callback error",
	Description = "Errors are caught and shown as an Error toast.",
	Tooltip = "The UI keeps working after the error.",
	Callback = function()
		error("Intentional test error from the Main tab")
	end,
})

--════════════════════════════════════════════════════════════════════════════
-- API tab: the Window helpers
--════════════════════════════════════════════════════════════════════════════
local Api = Window:Tab("API", "code")

local Dialogs = Api:Section("Dialogs & window")

Dialogs:Button({
	Title = "Confirm dialog",
	Description = "Window:Confirm(title, content, onConfirm, confirmText)",
	Tooltip = "Clears the Note on the Main tab after you confirm.",
	Callback = function()
		Window:Confirm("Clear the note?", "This empties the Note box on the Main tab.", function()
			Options.NotesInput:SetValue("")
			Window:Notify("Note cleared", "The Notes paragraph was reset too.", 3, "Success")
		end, "Clear")
	end,
})

Dialogs:Button({
	Title = "Custom dialog",
	Description = "Window:Dialog({ Title, Content, Buttons })",
	Tooltip = "Button callbacks are pcall'd like every other callback.",
	Callback = function()
		Window:Dialog({
			Title = "Hello!",
			Content = "Dialogs scale with the window and wrap long text.",
			Buttons = {
				{
					Title = "Say hi",
					Callback = function()
						Window:Notify("Hi", "Button callbacks work.", 3, "Success")
					end,
				},
				{ Title = "Close" },
			},
		})
	end,
})

Dialogs:Button({
	Title = "Hide the window for 3 seconds",
	Description = "Window:Toggle(false) … Window:Toggle(true)",
	Tooltip = "Window:Toggle() with no argument flips it, like the menu key.",
	Callback = function()
		Window:Toggle(false)
		task.delay(3, function()
			if Window:IsReady() then -- false once the UI has been unloaded
				Window:Toggle(true)
			end
		end)
	end,
})

local ConfigApi = Api:Section("Config")

local configInfo = ConfigApi:Paragraph({ -- no id: not saved
	Title = "Config file",
	Content = "…",
	Tooltip = "Window.Config.Path() and Window.Config.Current().",
})

local function showConfigInfo()
	configInfo:SetDesc(string.format(
		"%s\nProfile: %s (%d total)",
		Window.Config.Path(),
		Window.Config.Current(),
		#Window.Config.Profiles()
	))
end
showConfigInfo()

ConfigApi:Button({
	Title = "Save now",
	Description = "Window.Config.Save()",
	Tooltip = "Autosave already does this; useful when autosave is turned off.",
	Callback = function()
		if not Window.Config.HasFileAccess then
			Window:Notify("Config", "This executor has no file access; settings only live in memory.", 4, "Warning")
		elseif Window.Config.Save() then
			Window:Notify("Config", "Saved.", 3, "Success")
		else
			Window:Notify("Config", "Already up to date.", 3, "Info")
		end
		showConfigInfo()
	end,
})

ConfigApi:Button({
	Title = "Refresh info",
	Description = "Re-reads the path, profile and profile count.",
	Callback = showConfigInfo,
})

-- That's it: the Info and Settings tabs, the saved window position and the welcome toast are
-- added automatically right after this script finishes.
