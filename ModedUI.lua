--[[
	ModedUI  ·  v1.0.0
	A batteries-included UI library built on Fluent by dawid-scripts
	https://github.com/XITHHUB/ModedUI  ·  Fluent: https://github.com/dawid-scripts/Fluent

	local ModedUI = loadstring(game:HttpGet("https://raw.githubusercontent.com/XITHHUB/ModedUI/main/ModedUI.lua"))()
	local Window = ModedUI:CreateWindow({ Title = "My Hub", Folder = "MyHub" })
	local Main = Window:Tab("Main", "home")
	Main:Section("Combat"):Toggle("AutoParry", { Title = "Auto parry", Default = false, Callback = print })

	Features
	  • Background image from a URL (downloaded once, cached to disk, loaded with getcustomasset)
	  • Per-player JSON config: profiles, autosave (on/off + delay), import/export, corrupt-file backup
	  • Search across all tabs, smooth open/close, mobile toggle button + auto-fit, UI scale
	  • Theme / accent / font size / acrylic controls, all saved per profile
	  • Rate-limited notifications (max 3 on screen) with type icons and a mute switch
	  • Watermark (1 Hz), draggable keybind list overlay, Info and Settings tabs
	  • Element wrapper: every element is saved by its id automatically
	  • Maid-based cleanup, double-load protection, every callback pcall'd

	Sections
	  1. Services   2. Utilities   3. Cleanup (Maid)   4. Config System   5. Background
	  6. Window     7. Tabs        8. Overlays         9. Settings       10. Init (public API)
]]

local LIBRARY_VERSION = "1.0.0"
local LIBRARY_CHUNK = debug.info(1, "f") -- lets each additional window run on a fresh library copy
local CONFIG_VERSION = 2 -- saved file format (see MIGRATIONS in section 4)

--══════════════════════════════════════════════════════════════════════════════
-- OPTIONS (defaults for ModedUI:CreateWindow)
--══════════════════════════════════════════════════════════════════════════════
local DEFAULTS = {
	Title = "ModedUI", -- window title
	SubTitle = nil :: string?, -- defaults to "v" .. Version
	Version = "1.0.0", -- your hub's version (shown in the Info tab)
	Folder = "ModedUI", -- config folder inside the executor workspace
	BackgroundUrl = "", -- default background image (direct PNG/JPG link). "" = none
	FallbackAssetId = "", -- optional rbxassetid (digits only) used when the URL can't be loaded
	Theme = "Dark",
	MenuKey = "RightControl",
	Size = Vector2.new(580, 460),
	TabWidth = 160,
	AutoSave = true, -- default for new config files (changeable in Settings → Config)
	AutoSaveDelay = 1, -- seconds after the last change before the file is written
	MaxNotifications = 3, -- never more than this many toasts on screen
	InfoTab = true,
	SettingsTab = true,
	ShowWatermark = true,
	ShowKeybindList = true,
	WelcomeToast = true, -- "Loaded in 0.07s" toast once everything is built
	Changelog = { "v1.0.0", "• First release" },
	Reload = nil :: (() -> ())?, -- re-runs your script; defaults to the function that called CreateWindow
	FluentUrl = "https://github.com/dawid-scripts/Fluent/releases/latest/download/main.lua",
}
local SETTINGS = table.clone(DEFAULTS)

--══════════════════════════════════════════════════════════════════════════════
-- 1. SERVICES
--══════════════════════════════════════════════════════════════════════════════
if not game:IsLoaded() then
	game.Loaded:Wait()
end

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local TweenService = game:GetService("TweenService")
local HttpService = game:GetService("HttpService")
local TeleportService = game:GetService("TeleportService")
local MarketplaceService = game:GetService("MarketplaceService")
local GuiService = game:GetService("GuiService")
local Stats = game:GetService("Stats")
local Workspace = game:GetService("Workspace")

local LocalPlayer = Players.LocalPlayer
if not LocalPlayer then
	Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
	LocalPlayer = Players.LocalPlayer
end

-- Hot-path globals cached as locals (cheaper upvalue access than global lookups).
local os_clock, os_time, os_date = os.clock, os.time, os.date
local math_floor, math_clamp, math_min, math_max, math_abs = math.floor, math.clamp, math.min, math.max, math.abs
local string_format, string_lower, string_find, string_sub, string_gsub, string_match, string_byte =
	string.format, string.lower, string.find, string.sub, string.gsub, string.match, string.byte
local table_remove, table_concat, table_sort, table_clear, table_find, table_clone =
	table.remove, table.concat, table.sort, table.clear, table.find, table.clone
local task_spawn, task_defer, task_delay, task_cancel = task.spawn, task.defer, task.delay, task.cancel
local coroutine_status = coroutine.status
local Color3_fromRGB, UDim2_new, UDim2_fromOffset, UDim2_fromScale, UDim_new =
	Color3.fromRGB, UDim2.new, UDim2.fromOffset, UDim2.fromScale, UDim.new

-- Executor capabilities. Every optional function is feature-detected once; nil means "not available".
local function firstFunction(...: any): any
	for index = 1, select("#", ...) do
		local candidate = select(index, ...)
		if type(candidate) == "function" then
			return candidate
		end
	end
	return nil
end

local Env = {
	getgenv = firstFunction(getgenv),
	writefile = firstFunction(writefile),
	readfile = firstFunction(readfile),
	isfile = firstFunction(isfile),
	isfolder = firstFunction(isfolder),
	makefolder = firstFunction(makefolder),
	delfile = firstFunction(delfile),
	listfiles = firstFunction(listfiles),
	getcustomasset = firstFunction(getcustomasset, getsynasset),
	setclipboard = firstFunction(setclipboard, toclipboard, set_clipboard, Clipboard and Clipboard.set),
	protectgui = firstFunction(protectgui, syn and syn.protect_gui),
	getupvalues = firstFunction(debug and (debug :: any).getupvalues, getupvalues),
	getgc = firstFunction(getgc),
	identifyexecutor = firstFunction(identifyexecutor, getexecutorname),
	CanWrite = false,
	CanUseAssets = false,
}
Env.CanWrite = Env.writefile ~= nil
	and Env.readfile ~= nil
	and Env.isfile ~= nil
	and Env.isfolder ~= nil
	and Env.makefolder ~= nil
Env.CanUseAssets = Env.CanWrite and Env.getcustomasset ~= nil

local GENV = (Env.getgenv and Env.getgenv()) or _G
local CACHE_KEY = "__ModedUICache" -- survives unloads: cached Fluent source for fast reloads
local IsTouch = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
local NOOP = function() end

type NotifyKind = "Info" | "Success" | "Warning" | "Error"

-- Global application state. Subsystem tables are declared up-front so every section can reference
-- every other one regardless of definition order (they are filled in their own sections).
local App = {
	Name = SETTINGS.Title,
	Version = SETTINGS.Version,
	Created = false,
	Finalized = false,
	InstanceKey = "__ModedUI",
	Public = nil :: any,
	StartedAt = os_clock(),
	Unloaded = false,
	Ready = false,
	Fluent = nil :: any,
	Window = nil :: any,
	Options = nil :: any,
	Maid = nil :: any,
	BlurFolder = nil :: Instance?,
	OriginalDestroy = nil :: any,
	AnimationsEnabled = true,
	Self = nil :: any, -- function App.Reload() runs again (your script)
}

-- (typed `any` because their fields are defined in later sections than some of their uses)
local Util: any = {}
local Notifier: any = {}
local Config: any = {}
local Codecs: any = {}
local Background: any = {}
local Internals: any = {}
local Accent: any = {}
local FontSize: any = {}
local Win: any = {}
local Search: any = {}
local UI: any = {}
local Overlays: any = {}
local Tooltip: any = {}
local Watermark: any = {}
local KeybindList: any = {}
local MobileButton: any = {}
local Clock: any = {}
local Perf: any = {}
local ScaleFix: any = {}

--══════════════════════════════════════════════════════════════════════════════
-- 2. UTILITIES
--══════════════════════════════════════════════════════════════════════════════
local TWEEN_OPEN = TweenInfo.new(0.18, Enum.EasingStyle.Quart, Enum.EasingDirection.Out)
local TWEEN_CLOSE = TweenInfo.new(0.12, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
local FONT_REGULAR = Font.new("rbxasset://fonts/families/GothamSSm.json")
local FONT_MEDIUM = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.Medium)
local FONT_BOLD = Font.new("rbxasset://fonts/families/GothamSSm.json", Enum.FontWeight.SemiBold)

local idCounter = 0
function Util.NextId(): number
	idCounter += 1
	return idCounter
end

function Util.Round(value: number, decimals: number?): number
	local factor = 10 ^ (decimals or 0)
	return math_floor(value * factor + 0.5) / factor
end

function Util.IsFiniteNumber(value: any): boolean
	return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

function Util.FormatNumber(value: number): string
	if value == math_floor(value) and math_abs(value) < 1e15 then
		return string_format("%d", value)
	end
	return (string_gsub(string_format("%.4f", value), "%.?0+$", ""))
end

function Util.Trim(text: string): string
	return string_match(text, "^%s*(.-)%s*$") or ""
end

function Util.SanitizeFileName(text: string, fallback: string): string
	local cleaned = Util.Trim((string_gsub(tostring(text or ""), "[^%w%-_]", "_")))
	if cleaned == "" then
		return fallback
	end
	return string_sub(cleaned, 1, 48)
end

-- djb2 (32-bit). Stable, allocation-free hash used for cache file names.
function Util.Hash(text: string): string
	local hash = 5381
	for index = 1, #text do
		hash = (hash * 33 + string_byte(text, index)) % 4294967296
	end
	return string_format("%08x", hash)
end

function Util.DeepCopy<T>(value: T): T
	if type(value) ~= "table" then
		return value
	end
	local copy = {}
	for key, item in pairs(value :: any) do
		copy[key] = Util.DeepCopy(item)
	end
	return copy :: any
end

function Util.DeepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for key, item in pairs(a) do
		if not Util.DeepEqual(item, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

function Util.SortedKeys(map: { [any]: any }): { string }
	local keys = {}
	for key in pairs(map) do
		if type(key) == "string" then
			keys[#keys + 1] = key
		end
	end
	table_sort(keys, function(a, b)
		return string_lower(a) < string_lower(b)
	end)
	return keys
end

function Util.FormatDuration(seconds: number): string
	seconds = math_max(0, math_floor(seconds))
	return string_format(
		"%02d:%02d:%02d",
		math_floor(seconds / 3600),
		math_floor((seconds % 3600) / 60),
		seconds % 60
	)
end

-- Instance factory: sets Parent last (cheaper, avoids replication/layout churn).
function Util.Create(className: string, properties: { [string]: any }?, children: { Instance }?): any
	local instance = Instance.new(className)
	local parent = nil
	if properties then
		for key, value in pairs(properties) do
			if key == "Parent" then
				parent = value
			else
				(instance :: any)[key] = value
			end
		end
	end
	if children then
		for _, child in ipairs(children) do
			child.Parent = instance
		end
	end
	if parent then
		instance.Parent = parent
	end
	return instance
end

function Util.Corner(radius: number): UICorner
	return Util.Create("UICorner", { CornerRadius = UDim_new(0, radius) })
end

function Util.Tween(instance: Instance, info: TweenInfo, goal: { [string]: any }): Tween
	local tween = TweenService:Create(instance, info, goal)
	tween:Play()
	return tween
end

-- Returns "png" / "jpg" when the bytes look like an image Roblox can decode.
function Util.DetectImage(data: any): string?
	if type(data) ~= "string" or #data < 32 then
		return nil
	end
	if string_sub(data, 1, 8) == "\137PNG\r\n\26\n" then
		return "png"
	end
	if string_sub(data, 1, 3) == "\255\216\255" then
		return "jpg"
	end
	return nil
end

function Util.SetClipboard(text: string): boolean
	if not Env.setclipboard then
		return false
	end
	return (pcall(Env.setclipboard, text))
end

local validKeyNames: { [string]: boolean }? = nil
function Util.IsValidKeyName(name: any): boolean
	if type(name) ~= "string" then
		return false
	end
	if name == "MouseLeft" or name == "MouseRight" or name == "None" then
		return true
	end
	if not validKeyNames then
		local names = {}
		for _, item in ipairs(Enum.KeyCode:GetEnumItems()) do
			names[item.Name] = true
		end
		names.Unknown = nil
		validKeyNames = names
	end
	return (validKeyNames :: any)[name] == true
end

function Util.EncodeUDim2(value: UDim2): { number }
	return {
		Util.Round(value.X.Scale, 4),
		math_floor(value.X.Offset + 0.5),
		Util.Round(value.Y.Scale, 4),
		math_floor(value.Y.Offset + 0.5),
	}
end

function Util.DecodeUDim2(raw: any): UDim2?
	if type(raw) ~= "table" then
		return nil
	end
	local xs, xo, ys, yo = raw[1], raw[2], raw[3], raw[4]
	if
		Util.IsFiniteNumber(xs)
		and Util.IsFiniteNumber(xo)
		and Util.IsFiniteNumber(ys)
		and Util.IsFiniteNumber(yo)
	then
		return UDim2_new(xs, xo, ys, yo)
	end
	return nil
end

-- Keeps a GuiObject fully inside its ScreenGui. Positions are measured relative to the ScreenGui
-- itself, because AbsolutePosition is inset-relative while IgnoreGuiInset GUIs start at the top edge.
function Util.ClampToScreen(target: GuiObject, margin: number?)
	local gui = target:FindFirstAncestorWhichIsA("LayerCollector")
	if not gui then
		return
	end
	local edge = margin or 4
	local screen = (gui :: any).AbsoluteSize
	local position, size = target.AbsolutePosition - (gui :: any).AbsolutePosition, target.AbsoluteSize
	local dx, dy = 0, 0
	if position.X < edge then
		dx = edge - position.X
	elseif position.X + size.X > screen.X - edge then
		dx = (screen.X - edge) - (position.X + size.X)
	end
	if position.Y < edge then
		dy = edge - position.Y
	elseif position.Y + size.Y > screen.Y - edge then
		dy = (screen.Y - edge) - (position.Y + size.Y)
	end
	if dx ~= 0 or dy ~= 0 then
		local current = target.Position
		target.Position = UDim2_new(current.X.Scale, current.X.Offset + dx, current.Y.Scale, current.Y.Offset + dy)
	end
end

-- Mouse + touch dragging. The InputChanged listener only exists while a drag is in progress,
-- so idle draggables cost nothing per frame. A press that doesn't move counts as a tap.
function Util.MakeDraggable(
	handle: GuiObject,
	target: GuiObject,
	maid: any,
	options: { OnTap: (() -> ())?, OnDragEnd: ((UDim2) -> ())?, Threshold: number? }?
)
	local settings = options or {}
	local threshold = settings.Threshold or 6
	local key = "Drag" .. Util.NextId()
	maid:Connect(handle.InputBegan, function(input: InputObject)
		local inputType = input.UserInputType
		if inputType ~= Enum.UserInputType.MouseButton1 and inputType ~= Enum.UserInputType.Touch then
			return
		end
		local isTouch = inputType == Enum.UserInputType.Touch
		local startInput = input.Position
		local startPosition = target.Position
		local moved = false
		maid:Set(
			key .. "Move",
			UserInputService.InputChanged:Connect(function(changed: InputObject)
				if isTouch then
					if changed ~= input then
						return
					end
				elseif changed.UserInputType ~= Enum.UserInputType.MouseMovement then
					return
				end
				local delta = changed.Position - startInput
				if not moved and math_abs(delta.X) + math_abs(delta.Y) < threshold then
					return
				end
				moved = true
				target.Position = UDim2_new(
					startPosition.X.Scale,
					startPosition.X.Offset + delta.X,
					startPosition.Y.Scale,
					startPosition.Y.Offset + delta.Y
				)
			end)
		)
		maid:Set(
			key .. "End",
			input.Changed:Connect(function()
				if input.UserInputState ~= Enum.UserInputState.End then
					return
				end
				maid:Set(key .. "Move", nil)
				maid:Set(key .. "End", nil)
				if moved then
					Util.ClampToScreen(target)
					if settings.OnDragEnd then
						settings.OnDragEnd(target.Position)
					end
				elseif settings.OnTap then
					settings.OnTap()
				end
			end)
		)
	end)
end

local function CleanError(err: any): string
	local message = tostring(err)
	return string_match(message, "^[^\n]-:%d+: (.*)$") or message
end

-- Notifications ---------------------------------------------------------------
-- Notify(title, content, duration, kind): rate-limited (max SETTINGS.MaxNotifications on screen),
-- de-duplicated (a message identical to one still on screen is dropped), mutable, with an icon.
local NOTIFY_STYLE = {
	Info = { Icon = "info", Color = Color3_fromRGB(96, 165, 250) },
	Success = { Icon = "check-circle", Color = Color3_fromRGB(74, 222, 128) },
	Warning = { Icon = "alert-triangle", Color = Color3_fromRGB(250, 204, 21) },
	Error = { Icon = "x-circle", Color = Color3_fromRGB(248, 113, 113) },
}

Notifier.Active = {} :: { { Notification: any, Key: string } }
Notifier.Muted = false
Notifier.Create = nil :: any -- Fluent's original Notify (set in Init)

local function DecorateNotification(notification: any, kind: string)
	local style = NOTIFY_STYLE[kind]
	local fluent = App.Fluent
	local icon = fluent and fluent:GetIcon(style.Icon)
	if not icon or not notification.Root or not notification.Title then
		return
	end
	Util.Create("ImageLabel", {
		Name = "KindIcon",
		Image = icon,
		ImageColor3 = style.Color,
		BackgroundTransparency = 1,
		Size = UDim2_fromOffset(16, 16),
		Position = UDim2_fromOffset(14, 15),
		Parent = notification.Root,
	})
	notification.Title.Position = UDim2_new(0, 36, 0, 17)
	notification.Title.Size = UDim2_new(1, -70, 0, 12)
end

local function Notify(title: string?, content: string?, duration: number?, kind: NotifyKind?, subContent: string?): any
	local style = kind and NOTIFY_STYLE[kind] and kind or "Info"
	local header = tostring(title or SETTINGS.Title)
	local body = content ~= nil and tostring(content) or ""
	if Notifier.Muted or App.Unloaded then
		if style == "Error" then
			warn(string_format("[%s] %s: %s", SETTINGS.Title, header, body)) -- never lose errors
		end
		return nil
	end
	local fluent, create = App.Fluent, Notifier.Create
	if not fluent or not create then
		return nil
	end

	local key = string_format("%s\0%s\0%s", style, header, body)
	local active = Notifier.Active
	for index = #active, 1, -1 do
		local record = active[index]
		if record.Notification.Closed then
			table_remove(active, index)
		elseif record.Key == key then
			return record.Notification -- identical toast still on screen: drop the duplicate
		end
	end
	while #active >= SETTINGS.MaxNotifications do
		local oldest = table_remove(active, 1)
		local stale = oldest and oldest.Notification
		if stale then
			pcall(function()
				stale.Holder.Visible = false -- vanish instantly so the stack never exceeds the cap
				stale:Close()
			end)
		end
	end

	local ok, notification = pcall(create, fluent, {
		Title = header,
		Content = body,
		SubContent = subContent,
		Duration = duration or 5,
	})
	if not ok or not notification then
		warn(string_format("[%s] notification failed: %s", SETTINGS.Title, tostring(notification)))
		return nil
	end
	pcall(DecorateNotification, notification, style)
	active[#active + 1] = { Notification = notification, Key = key }
	Internals.SchedulePrune()
	return notification
end

-- pcall wrapper used for every user/element callback; failures become an "Error" toast.
local function SafeCall(context: string?, callback: any, ...: any): (boolean, any)
	if type(callback) ~= "function" then
		return false, nil
	end
	local ok, result = pcall(callback, ...)
	if not ok then
		-- Full message (with line number) goes to the console; the toast gets the short version.
		warn(string_format("[%s] %s: %s", SETTINGS.Title, context or "callback", tostring(result)))
		Notify(context and (context .. " failed") or "Callback error", CleanError(result), 6, "Error")
	end
	return ok, result
end

-- Confirm dialog used before every destructive action.
local function Confirm(title: string, content: string, onConfirm: () -> (), confirmText: string?)
	local window = App.Window
	if not window then
		return
	end
	if not Win.Open then
		Win.Toggle(true) -- dialogs live inside the window, so a hidden window would hide them too
	end
	window:Dialog({
		Title = title,
		Content = content,
		Buttons = {
			{
				Title = confirmText or "Confirm",
				Callback = function()
					SafeCall(title, onConfirm)
				end,
			},
			{ Title = "Cancel" },
		},
	})
end

--══════════════════════════════════════════════════════════════════════════════
-- 3. CLEANUP (MAID)
--══════════════════════════════════════════════════════════════════════════════
-- Tracks connections, instances, threads, cleanup functions and objects with :Destroy().
-- Keyed tasks (Maid:Set) replace and clean their previous value, which keeps repeating work
-- (debounces, drags, downloads) from accumulating entries.
local Maid = {}
Maid.__index = Maid

function Maid.new()
	return setmetatable({ _tasks = {}, _keyed = {} }, Maid)
end

local function cleanupTask(item: any)
	local kind = typeof(item)
	if kind == "RBXScriptConnection" then
		item:Disconnect()
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "thread" then
		if coroutine_status(item) ~= "dead" then
			task_cancel(item)
		end
	elseif kind == "function" then
		item()
	elseif kind == "table" then
		if type(item.Destroy) == "function" then
			item:Destroy()
		elseif type(item.Disconnect) == "function" then
			item:Disconnect()
		end
	end
end

function Maid:Give<T>(item: T): T
	local tasks = self._tasks
	tasks[#tasks + 1] = item
	return item
end

function Maid:Connect(signal: RBXScriptSignal, callback: (...any) -> ()): RBXScriptConnection
	local connection = signal:Connect(callback)
	local tasks = self._tasks
	tasks[#tasks + 1] = connection
	return connection
end

function Maid:Set(key: string, item: any): any
	local keyed = self._keyed
	local previous = keyed[key]
	if previous == item then
		return item
	end
	keyed[key] = item
	if previous ~= nil then
		pcall(cleanupTask, previous)
	end
	return item
end

function Maid:Clean()
	local keyed = self._keyed
	self._keyed = {}
	for _, item in pairs(keyed) do
		pcall(cleanupTask, item)
	end
	local tasks = self._tasks
	self._tasks = {}
	for index = #tasks, 1, -1 do
		pcall(cleanupTask, tasks[index])
		tasks[index] = nil
	end
end
Maid.Destroy = Maid.Clean

--══════════════════════════════════════════════════════════════════════════════
-- 4. CONFIG SYSTEM
--══════════════════════════════════════════════════════════════════════════════
--[[
	File:     <Folder>/<PlayerName>.json   (one file per player, all profiles inside)
	Format:   {
	            ConfigVersion = 2, Player = "Name", AutoLoad = true, LastProfile = "Default",
	            AutoSave = true, AutoSaveDelay = 1,          -- header: shared by every profile
	            Profiles = {
	              Default = { Values = { [id] = value }, Window = {X,Y,W,H}, Overlays = {...}, SavedAt = os.time() }
	            }
	          }
	Values:   Toggle → boolean, Slider → number, Input → string, Dropdown → string|false or {string},
	          Keybind → {Key = "KeyCodeName", Mode = "Toggle|Hold|Always"},
	          Colorpicker → {R = 0-255, G = 0-255, B = 0-255, A = transparency},
	          Paragraph → {Title = string, Content = string}
	Unknown ids are preserved, so removing an element never destroys its saved value.
]]
type Entry = {
	Id: string,
	Type: string,
	Title: string,
	Spec: { [string]: any },
	Codec: any,
	Option: any,
	Frame: GuiObject?,
	Default: any,
	Initial: any,
	Persist: boolean,
	Last: any,
	UserCallback: ((...any) -> ())?,
	AfterChange: ((Entry, any) -> ())?,
}

Config.Folder = "ModedUI" -- set from the Folder option in Config.Init
Config.CacheFolder = "ModedUI/cache"
Config.FilePath = ""
Config.Data = nil :: any
Config.Current = "Default"
Config.Registry = {} :: { [string]: Entry }
Config.Order = {} :: { Entry }
Config.Applying = 0
Config.Ready = false
Config.DirtyAt = 0
Config.SaveThread = nil :: thread?
Config.LastJson = nil :: string?
Config.LoadStatus = "new"
Config.BackupPath = nil :: string?
Config.MetaDirty = false -- header changed while autosave is off (written without element values)
Config.ProfilesChanged = NOOP -- set by the Settings tab (refreshes the profile dropdown/info)
Config.Saved = NOOP -- called after every successful write

local DEFAULT_PROFILE = "Default"
local EXPORT_KIND = "ModedUI.Profile"
local KEYBIND_MODES = { Toggle = true, Hold = true, Always = true }

local function NewProfile(): { [string]: any }
	return { Values = {}, Window = nil, Overlays = {}, SavedAt = 0 }
end

local function clampDelay(value: any): number
	local seconds = tonumber(value)
	if not Util.IsFiniteNumber(seconds) then
		seconds = tonumber(SETTINGS.AutoSaveDelay) or 1
	end
	return Util.Round(math_clamp(seconds :: number, 0.5, 10), 1)
end

local function NewData(): { [string]: any }
	return {
		ConfigVersion = CONFIG_VERSION,
		Player = LocalPlayer.Name,
		AutoLoad = true,
		AutoSave = SETTINGS.AutoSave ~= false,
		AutoSaveDelay = clampDelay(SETTINGS.AutoSaveDelay),
		LastProfile = DEFAULT_PROFILE,
		Profiles = { [DEFAULT_PROFILE] = NewProfile() },
	}
end

-- Migrations: MIGRATIONS[n] upgrades a version-n table to version n+1.
local MIGRATIONS: { [number]: (any) -> any } = {
	-- v1 stored a single flat profile ({ Values, Window }) → v2 wraps it into Profiles.Default.
	[1] = function(old)
		local profile = NewProfile()
		profile.Values = type(old.Values) == "table" and old.Values or {}
		profile.Window = type(old.Window) == "table" and old.Window or nil
		return {
			ConfigVersion = 2,
			Player = old.Player,
			AutoLoad = true,
			LastProfile = DEFAULT_PROFILE,
			Profiles = { [DEFAULT_PROFILE] = profile },
		}
	end,
}

function Config.Migrate(data: any): (any, string?)
	local version = tonumber(data.ConfigVersion) or (type(data.Profiles) == "table" and 2 or 1)
	if version > CONFIG_VERSION then
		return data, "newer" -- written by a newer script version: keep going, values are still validated
	end
	while version < CONFIG_VERSION do
		local step = MIGRATIONS[version]
		if not step then
			return nil, "no migration path"
		end
		data = step(data)
		version = tonumber(data.ConfigVersion) or (version + 1)
	end
	return data, nil
end

-- Normalises a decoded file into the exact shape the script expects (never trusts disk data).
function Config.Sanitize(data: any): any
	if type(data) ~= "table" or type(data.Profiles) ~= "table" then
		return nil
	end
	local profiles = {}
	for name, profile in pairs(data.Profiles) do
		if type(name) == "string" and type(profile) == "table" then
			local clean = NewProfile()
			clean.Values = type(profile.Values) == "table" and profile.Values or {}
			clean.Window = type(profile.Window) == "table" and profile.Window or nil
			clean.Overlays = type(profile.Overlays) == "table" and profile.Overlays or {}
			clean.SavedAt = tonumber(profile.SavedAt) or 0
			profiles[name] = clean
		end
	end
	if next(profiles) == nil then
		profiles[DEFAULT_PROFILE] = NewProfile()
	end
	local last = data.LastProfile
	if type(last) ~= "string" or not profiles[last] then
		last = profiles[DEFAULT_PROFILE] and DEFAULT_PROFILE or Util.SortedKeys(profiles)[1]
	end
	return {
		ConfigVersion = CONFIG_VERSION,
		Player = LocalPlayer.Name,
		AutoLoad = data.AutoLoad ~= false,
		AutoSave = if data.AutoSave == nil then SETTINGS.AutoSave ~= false else data.AutoSave == true,
		AutoSaveDelay = clampDelay(data.AutoSaveDelay),
		LastProfile = last,
		Profiles = profiles,
	}
end

function Config.EnsureFolder(path: string): boolean
	if not Env.CanWrite then
		return false
	end
	local ok = pcall(function()
		if not Env.isfolder(path) then
			Env.makefolder(path)
		end
	end)
	return ok
end

-- Reads + validates the player's file. Returns (data, status, rawText).
function Config.ReadFile(): (any, string, string?)
	if not Env.CanWrite then
		return nil, "nofs", nil
	end
	local okExists, exists = pcall(Env.isfile, Config.FilePath)
	if not okExists or not exists then
		return nil, "missing", nil
	end
	local okRead, raw = pcall(Env.readfile, Config.FilePath)
	if not okRead or type(raw) ~= "string" then
		return nil, "unreadable", nil
	end
	local okDecode, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not okDecode or type(decoded) ~= "table" then
		return nil, "corrupt", raw
	end
	local okMigrate, migrated, why = pcall(Config.Migrate, decoded)
	if not okMigrate or not migrated then
		return nil, "corrupt", raw
	end
	local clean = Config.Sanitize(migrated)
	if not clean then
		return nil, "corrupt", raw
	end
	return clean, why or "ok", raw
end

-- Copies an unreadable file to "<file>.bak" (falls back to ".bak.json" on executors that
-- whitelist extensions) so the user never silently loses data.
function Config.Backup(raw: string): string?
	if not Env.CanWrite then
		return nil
	end
	local candidates = { Config.FilePath .. ".bak", (string_gsub(Config.FilePath, "%.json$", ".bak.json")) }
	for _, path in ipairs(candidates) do
		if pcall(Env.writefile, path, raw) then
			return path
		end
	end
	return nil
end

function Config.Init()
	Config.Folder = Util.SanitizeFileName(SETTINGS.Folder, "ModedUI")
	Config.CacheFolder = Config.Folder .. "/cache"
	local playerFile = Util.SanitizeFileName(LocalPlayer.Name, "Player")
	Config.FilePath = string_format("%s/%s.json", Config.Folder, playerFile)
	Config.EnsureFolder(Config.Folder)

	local data, status, raw = Config.ReadFile()
	if not data then
		if status == "corrupt" and raw then
			Config.BackupPath = Config.Backup(raw)
		end
		data = NewData()
	end
	Config.LoadStatus = status
	Config.Data = data

	local profile = DEFAULT_PROFILE
	if data.AutoLoad and data.Profiles[data.LastProfile] then
		profile = data.LastProfile
	elseif not data.Profiles[DEFAULT_PROFILE] then
		data.Profiles[DEFAULT_PROFILE] = NewProfile()
	end
	Config.Current = profile
	data.LastProfile = profile
end

function Config.CurrentProfile(): { [string]: any }
	local profiles = Config.Data.Profiles
	local profile = profiles[Config.Current]
	if not profile then
		profile = NewProfile()
		profiles[Config.Current] = profile
	end
	return profile
end

-- Raw stored value → validated value for elements that are needed before the window exists.
function Config.Peek(id: string, validate: (any) -> any): any
	local profile = Config.Data and Config.Data.Profiles[Config.Current]
	local raw = profile and profile.Values[id]
	if raw == nil then
		return nil
	end
	local ok, value = pcall(validate, raw)
	if ok then
		return value
	end
	return nil
end

-- Codecs ----------------------------------------------------------------------
-- Every element type converts between three shapes:
--   raw (what Fluent passes to callbacks) → canonical (JSON-safe, compared for changes)
--   canonical → Fluent (Apply / creation Defaults) and → user callback arguments (User)
local function sliderValue(spec: any, value: any): number?
	local number = tonumber(value)
	if not Util.IsFiniteNumber(number) then
		return nil
	end
	return Util.Round(math_clamp(number :: number, spec.Min, spec.Max), spec.Rounding or 0)
end

local function numericText(spec: any, value: any): string?
	local number = tonumber(Util.Trim(tostring(value or "")))
	if not Util.IsFiniteNumber(number) then
		return nil
	end
	local result = Util.Round(number :: number, spec.Decimals or 2)
	if spec.Min then
		result = math_max(result, spec.Min)
	end
	if spec.Max then
		result = math_min(result, spec.Max)
	end
	return Util.FormatNumber(result)
end

local function inputText(spec: any, value: any): string?
	if value == nil then
		return nil
	end
	if spec.Numeric then
		return numericText(spec, value)
	end
	local text = tostring(value)
	if spec.MaxLength and #text > spec.MaxLength then
		text = string_sub(text, 1, spec.MaxLength)
	end
	return text
end

local function dropdownValues(entry: Entry): { string }
	local option = entry.Option
	return (option and option.Values) or entry.Spec.Values or {}
end

-- Accepts a set ({a = true}), an array ({"a"}) or Fluent's mixed table; returns a sorted array.
local function normalizeMulti(entry: Entry, raw: any): { string }
	local list = {}
	if type(raw) == "table" then
		local values = dropdownValues(entry)
		local seen = {}
		for key, value in pairs(raw) do
			local name = nil
			if type(key) == "string" and value == true then
				name = key
			elseif type(key) == "number" and type(value) == "string" then
				name = value
			end
			if name and not seen[name] and table_find(values, name) then
				seen[name] = true
				list[#list + 1] = name
			end
		end
		table_sort(list)
	end
	return list
end

local function toSet(list: { string }): { [string]: boolean }
	local set = {}
	for _, name in ipairs(list) do
		set[name] = true
	end
	return set
end

local function to255(channel: number): number
	return math_clamp(math_floor(channel * 255 + 0.5), 0, 255)
end

local function colorValue(color: Color3, alpha: number): { [string]: number }
	return { R = to255(color.R), G = to255(color.G), B = to255(color.B), A = Util.Round(alpha, 3) }
end

Codecs.Toggle = {
	Default = function(entry: Entry)
		return entry.Spec.Default == true
	end,
	Normalize = function(_entry: Entry, raw: any)
		return raw == true
	end,
	Decode = function(_entry: Entry, raw: any)
		if type(raw) == "boolean" then
			return raw
		end
		return nil
	end,
	Apply = function(entry: Entry, value: any)
		entry.Option:SetValue(value)
	end,
	User = function(_entry: Entry, value: any)
		return value
	end,
	Fluent = function(_entry: Entry, value: any, fluentConfig: any)
		fluentConfig.Default = value
	end,
}

Codecs.Slider = {
	Default = function(entry: Entry)
		return sliderValue(entry.Spec, entry.Spec.Default) or entry.Spec.Min
	end,
	Normalize = function(entry: Entry, raw: any)
		return sliderValue(entry.Spec, raw) or entry.Default
	end,
	Decode = function(entry: Entry, raw: any)
		return sliderValue(entry.Spec, raw)
	end,
	Apply = function(entry: Entry, value: any)
		entry.Option:SetValue(value)
	end,
	User = function(_entry: Entry, value: any)
		return value
	end,
	Fluent = function(entry: Entry, value: any, fluentConfig: any)
		fluentConfig.Default = value
		fluentConfig.Min = entry.Spec.Min
		fluentConfig.Max = entry.Spec.Max
		fluentConfig.Rounding = entry.Spec.Rounding or 0
	end,
}

Codecs.Input = {
	Default = function(entry: Entry)
		local spec = entry.Spec
		return inputText(spec, spec.Default or "")
			or (spec.Numeric and Util.FormatNumber(spec.Min or 0))
			or ""
	end,
	Normalize = function(_entry: Entry, raw: any)
		return tostring(raw or "")
	end,
	Decode = function(entry: Entry, raw: any)
		if type(raw) ~= "string" and type(raw) ~= "number" then
			return nil
		end
		return inputText(entry.Spec, raw)
	end,
	Apply = function(entry: Entry, value: any)
		entry.Option:SetValue(value)
	end,
	User = function(entry: Entry, value: any)
		if entry.Spec.Numeric then
			return tonumber(value)
		end
		return value
	end,
	Fluent = function(entry: Entry, value: any, fluentConfig: any)
		local spec = entry.Spec
		fluentConfig.Default = value
		fluentConfig.Placeholder = spec.Placeholder
		fluentConfig.Numeric = false -- numeric mode is handled (better) by the wrapper
		fluentConfig.Finished = spec.Numeric == true or spec.Finished == true
		fluentConfig.MaxLength = spec.MaxLength
	end,
}

Codecs.Dropdown = {
	Default = function(entry: Entry)
		local spec = entry.Spec
		if spec.Multi then
			return normalizeMulti(entry, spec.Default)
		end
		local default = spec.Default
		if type(default) == "number" then
			default = (spec.Values or {})[default]
		end
		if type(default) == "string" and table_find(spec.Values or {}, default) then
			return default
		end
		return false
	end,
	Normalize = function(entry: Entry, raw: any)
		if entry.Spec.Multi then
			return normalizeMulti(entry, raw)
		end
		if type(raw) == "string" then
			return raw
		end
		return false
	end,
	Decode = function(entry: Entry, raw: any)
		if entry.Spec.Multi then
			if type(raw) ~= "table" then
				return nil
			end
			return normalizeMulti(entry, raw)
		end
		if raw == false or raw == "" then
			return false
		end
		if type(raw) == "string" and table_find(dropdownValues(entry), raw) then
			return raw
		end
		return nil
	end,
	Apply = function(entry: Entry, value: any)
		if entry.Spec.Multi then
			entry.Option:SetValue(toSet(value))
		else
			entry.Option:SetValue(value or nil)
		end
	end,
	User = function(entry: Entry, value: any)
		if entry.Spec.Multi then
			return toSet(value), table_clone(value)
		end
		return value or nil
	end,
	Fluent = function(entry: Entry, _value: any, fluentConfig: any)
		local spec = entry.Spec
		fluentConfig.Values = table_clone(spec.Values or {})
		fluentConfig.Multi = spec.Multi == true
		fluentConfig.AllowNull = spec.AllowNull
		fluentConfig.Default = spec.Multi and {} or nil -- the saved selection is applied after creation
	end,
}

Codecs.Keybind = {
	Default = function(entry: Entry)
		local spec = entry.Spec
		local mode = spec.Mode or "Toggle"
		return {
			Key = Util.IsValidKeyName(spec.Default) and spec.Default or "None",
			Mode = KEYBIND_MODES[mode] and mode or "Toggle",
		}
	end,
	Normalize = function(entry: Entry)
		local option = entry.Option
		return { Key = tostring(option.Value), Mode = option.Mode }
	end,
	Decode = function(_entry: Entry, raw: any)
		if type(raw) == "string" then
			raw = { Key = raw }
		end
		if type(raw) ~= "table" or not Util.IsValidKeyName(raw.Key) then
			return nil
		end
		return { Key = raw.Key, Mode = KEYBIND_MODES[raw.Mode] and raw.Mode or "Toggle" }
	end,
	Apply = function(entry: Entry, value: any)
		entry.Option:SetValue(value.Key, value.Mode)
		Config.OnChanged(entry) -- Fluent's Keybind:SetValue is silent
	end,
	User = function(_entry: Entry, value: any)
		return value.Key, value.Mode
	end,
	Fluent = function(_entry: Entry, value: any, fluentConfig: any)
		fluentConfig.Default = value.Key
		fluentConfig.Mode = value.Mode
	end,
}

Codecs.Colorpicker = {
	Default = function(entry: Entry)
		local spec = entry.Spec
		local color = typeof(spec.Default) == "Color3" and spec.Default or Color3.new(1, 1, 1)
		return colorValue(color, tonumber(spec.Transparency) or 0)
	end,
	Normalize = function(entry: Entry, raw: any)
		local option = entry.Option
		local color = typeof(raw) == "Color3" and raw or (option and option.Value) or Color3.new(1, 1, 1)
		-- During creation the option doesn't exist yet: the transparency Fluent received is Initial.A.
		local alpha = if option then option.Transparency else (entry.Initial and entry.Initial.A)
		return colorValue(color, tonumber(alpha) or 0)
	end,
	Decode = function(entry: Entry, raw: any)
		if type(raw) ~= "table" then
			return nil
		end
		local r, g, b = tonumber(raw.R or raw[1]), tonumber(raw.G or raw[2]), tonumber(raw.B or raw[3])
		if not (Util.IsFiniteNumber(r) and Util.IsFiniteNumber(g) and Util.IsFiniteNumber(b)) then
			return nil
		end
		local alpha = tonumber(raw.A or raw[4]) or 0
		if entry.Spec.Transparency == nil or not Util.IsFiniteNumber(alpha) then
			alpha = 0
		end
		return {
			R = math_clamp(math_floor(r :: number + 0.5), 0, 255),
			G = math_clamp(math_floor(g :: number + 0.5), 0, 255),
			B = math_clamp(math_floor(b :: number + 0.5), 0, 255),
			A = Util.Round(math_clamp(alpha, 0, 1), 3),
		}
	end,
	Apply = function(entry: Entry, value: any)
		entry.Option:SetValueRGB(Color3_fromRGB(value.R, value.G, value.B), value.A)
	end,
	User = function(_entry: Entry, value: any)
		return Color3_fromRGB(value.R, value.G, value.B), value.A
	end,
	Fluent = function(entry: Entry, value: any, fluentConfig: any)
		fluentConfig.Default = Color3_fromRGB(value.R, value.G, value.B)
		fluentConfig.Transparency = entry.Spec.Transparency ~= nil and value.A or nil
	end,
}

Codecs.Paragraph = {
	Default = function(entry: Entry)
		return { Title = tostring(entry.Spec.Title or ""), Content = tostring(entry.Spec.Content or "") }
	end,
	Normalize = function(entry: Entry)
		local option = entry.Option
		return { Title = option.Title, Content = option.Content }
	end,
	Decode = function(_entry: Entry, raw: any)
		if type(raw) ~= "table" or type(raw.Title) ~= "string" or type(raw.Content) ~= "string" then
			return nil
		end
		return { Title = raw.Title, Content = raw.Content }
	end,
	Apply = function(entry: Entry, value: any)
		entry.Option:Set(value.Title, value.Content)
	end,
	User = function(_entry: Entry, value: any)
		return value.Title, value.Content
	end,
}

-- Registration ----------------------------------------------------------------
function Config.Register(kind: string, id: string, spec: { [string]: any }): Entry
	local codec = Codecs[kind]
	assert(codec, "Unknown element type " .. tostring(kind))
	assert(type(id) == "string" and id ~= "", kind .. " elements need a unique string id")
	if Config.Registry[id] then
		error(string_format("Duplicate element id %q", id), 3)
	end
	local entry: Entry = {
		Id = id,
		Type = kind,
		Title = tostring(spec.Title or id),
		Spec = spec,
		Codec = codec,
		Option = nil,
		Frame = nil,
		Default = nil,
		Initial = nil,
		Persist = spec.Save ~= false,
		Last = nil,
		UserCallback = if kind == "Keybind" then spec.ChangedCallback else spec.Callback,
		AfterChange = nil,
	}
	entry.Default = codec.Default(entry)
	local stored = entry.Persist and Config.ReadStored(entry) or nil
	entry.Initial = if stored ~= nil then stored else Util.DeepCopy(entry.Default)
	Config.Registry[id] = entry
	Config.Order[#Config.Order + 1] = entry
	return entry
end

function Config.ReadStored(entry: Entry): any
	local profile = Config.Data and Config.Data.Profiles[Config.Current]
	local raw = profile and profile.Values[entry.Id]
	if raw == nil then
		return nil
	end
	local ok, value = pcall(entry.Codec.Decode, entry, raw)
	if ok then
		return value
	end
	return nil
end

-- Numeric inputs: reject non-numbers (restore the last good value) and clamp to Min/Max.
-- Returns false when the value was corrected (the corrected SetValue re-enters OnChanged).
local function validateNumeric(entry: Entry, raw: any): boolean
	local spec = entry.Spec
	local text = tostring(raw or "")
	local canonical = numericText(spec, text)
	local option = entry.Option
	if canonical == nil then
		if option and entry.Last ~= nil then
			option:SetValue(entry.Last)
			if Util.Trim(text) ~= "" then
				Notify(entry.Title, string_format('"%s" is not a number.', text), 4, "Warning")
			end
		end
		return false
	end
	if canonical ~= text then
		if option then
			local typed = tonumber(Util.Trim(text))
			if typed and tonumber(canonical) ~= Util.Round(typed, spec.Decimals or 2) then
				Notify(
					entry.Title,
					string_format(
						"Allowed range is %s to %s.",
						spec.Min and Util.FormatNumber(spec.Min) or "-∞",
						spec.Max and Util.FormatNumber(spec.Max) or "∞"
					),
					4,
					"Warning"
				)
			end
			option:SetValue(canonical)
		end
		return false
	end
	return true
end

-- Single entry point for every element change (Fluent callbacks, config loads, manual calls).
-- De-duplicates, so the user callback fires exactly once per real change, and schedules autosave.
function Config.OnChanged(entry: Entry, raw: any?)
	if App.Unloaded then
		return
	end
	if entry.Type == "Input" and entry.Spec.Numeric and not validateNumeric(entry, raw) then
		return
	end
	local value = entry.Codec.Normalize(entry, raw)
	if entry.Last ~= nil and Util.DeepEqual(value, entry.Last) then
		return
	end
	entry.Last = value
	if entry.UserCallback then
		SafeCall(entry.Title, entry.UserCallback, entry.Codec.User(entry, value))
	end
	if entry.AfterChange then
		SafeCall(entry.Title, entry.AfterChange, entry, value)
	end
	if entry.Persist then
		Config.MarkDirty()
	end
	if Accent.FallbackActive then
		Accent.ScheduleRecolor()
	end
end

-- Autosave --------------------------------------------------------------------
-- One timer at most: changes only stamp DirtyAt; the timer re-arms itself until the UI has been
-- quiet for AutoSaveDelay seconds. Slider drags therefore never spawn a thread per frame.
-- Autosave on/off and the delay live in the file header, so they are shared by every profile.
function Config.AutoSaveEnabled(): boolean
	return Config.Data == nil or Config.Data.AutoSave ~= false
end

function Config.Delay(): number
	return clampDelay(Config.Data and Config.Data.AutoSaveDelay)
end

local function autosaveTick()
	Config.SaveThread = nil
	if App.Unloaded then
		return
	end
	local delay = Config.Delay()
	local idle = os_clock() - Config.DirtyAt
	if idle < delay then
		Config.SaveThread = task_delay(delay - idle, autosaveTick)
		return
	end
	if Config.AutoSaveEnabled() then
		Config.SaveNow()
	elseif Config.MetaDirty then
		Config.SaveMeta()
	end
end

-- Element changes (metaOnly = false) are only scheduled while autosave is on; header changes
-- (profiles, autosave settings) are always written, but without capturing unsaved element values.
function Config.MarkDirty(metaOnly: boolean?)
	if not Config.Ready or Config.Applying > 0 or App.Unloaded then
		return
	end
	if metaOnly then
		Config.MetaDirty = true
	elseif not Config.AutoSaveEnabled() then
		return
	end
	Config.DirtyAt = os_clock()
	if not Config.SaveThread then
		Config.SaveThread = task_delay(Config.Delay(), autosaveTick)
	end
end

-- Writes the current state of every registered element into the active profile.
function Config.Capture(profile: { [string]: any })
	local values = profile.Values
	for _, entry in ipairs(Config.Order) do
		if entry.Persist and entry.Option then
			-- entry.Last is the canonical value of the last change (never mutated in place).
			local value = entry.Last
			if value == nil then
				local ok, normalized = pcall(entry.Codec.Normalize, entry, entry.Option.Value)
				value = ok and normalized or nil
			end
			if value ~= nil then
				values[entry.Id] = value
			end
		end
	end
	local geometry = Win.GetGeometry()
	if geometry then
		profile.Window = geometry
	end
	profile.Overlays = Overlays.GetPositions(profile.Overlays)
end

local function encodeData(): (boolean, string)
	return pcall(HttpService.JSONEncode, HttpService, Config.Data)
end

-- Saves immediately. Only touches the disk when the encoded JSON actually differs.
function Config.SaveNow(): boolean
	if not Config.Data then
		return false
	end
	local pending = Config.SaveThread
	if pending then
		Config.SaveThread = nil
		if coroutine_status(pending) ~= "dead" then
			pcall(task_cancel, pending)
		end
	end
	Config.MetaDirty = false
	local profile = Config.CurrentProfile()
	Config.Capture(profile)
	local ok, json = encodeData()
	if not ok then
		Notify("Config", "Could not encode settings: " .. CleanError(json), 6, "Error")
		return false
	end
	if json == Config.LastJson then
		return false
	end
	profile.SavedAt = os_time()
	ok, json = encodeData()
	if not ok then
		return false
	end
	Config.LastJson = json
	if not Env.CanWrite then
		return false -- memory-only session
	end
	Config.EnsureFolder(Config.Folder)
	local written, err = pcall(Env.writefile, Config.FilePath, json)
	if not written then
		Notify("Config", "Save failed: " .. CleanError(err), 6, "Error")
		return false
	end
	SafeCall("Config", Config.Saved)
	return true
end

-- Writes the file as it is in memory (header changes) without capturing element values, so
-- unsaved changes stay unsaved while autosave is off.
function Config.SaveMeta(): boolean
	Config.MetaDirty = false
	if not Config.Data or not Env.CanWrite then
		return false
	end
	local ok, json = encodeData()
	if not ok or json == Config.LastJson then
		return false
	end
	Config.EnsureFolder(Config.Folder)
	local written, err = pcall(Env.writefile, Config.FilePath, json)
	if not written then
		Notify("Config", "Save failed: " .. CleanError(err), 6, "Error")
		return false
	end
	Config.LastJson = json
	SafeCall("Config", Config.Saved)
	return true
end

-- Applies a Values table to every registered element (missing ids → defaults). Only elements
-- whose value really differs are touched, and each fires its callback once.
function Config.ApplyValues(values: { [string]: any })
	Config.Applying += 1
	Internals.Batch(function()
		for _, entry in ipairs(Config.Order) do
			if entry.Persist and entry.Option then
				local value = nil
				local raw = values[entry.Id]
				if raw ~= nil then
					local ok, decoded = pcall(entry.Codec.Decode, entry, raw)
					if ok then
						value = decoded
					end
				end
				if value == nil then
					value = Util.DeepCopy(entry.Default)
				end
				if entry.Last == nil or not Util.DeepEqual(entry.Last, value) then
					SafeCall(entry.Title, entry.Codec.Apply, entry, value)
				end
			end
		end
	end)
	Config.Applying -= 1
	-- Fluent repaints once the batch ends, so re-read its colours for our own widgets afterwards.
	Win.ThemeSync()
end

-- Writes everything when autosave is on; otherwise only header changes (keeps unsaved values).
function Config.Persist(): boolean
	if Config.AutoSaveEnabled() then
		return Config.SaveNow()
	end
	return Config.SaveMeta()
end

-- Profiles --------------------------------------------------------------------
function Config.ProfileNames(): { string }
	return Util.SortedKeys(Config.Data.Profiles)
end

function Config.FindProfile(name: string): string?
	local wanted = string_lower(name)
	for existing in pairs(Config.Data.Profiles) do
		if string_lower(existing) == wanted then
			return existing
		end
	end
	return nil
end

function Config.ValidateProfileName(raw: any): (string?, string?)
	local name = Util.Trim(tostring(raw or ""))
	if name == "" then
		return nil, "Type a profile name in the box first."
	end
	if #name > 32 then
		return nil, "Profile names can be at most 32 characters."
	end
	if string_find(name, "[^%w%s%-_%.]") then
		return nil, "Use letters, numbers, spaces, - _ and . only."
	end
	return name, nil
end

function Config.SwitchProfile(name: string, silent: boolean?): boolean
	local data = Config.Data
	local profile = data.Profiles[name]
	if not profile then
		Notify("Profiles", string_format('Profile "%s" does not exist.', tostring(name)), 4, "Error")
		return false
	end
	if name ~= Config.Current then
		if Config.AutoSaveEnabled() then
			Config.SaveNow() -- persist the profile we are leaving (autosave off: unsaved changes are dropped)
		end
		Config.Current = name
	end
	data.LastProfile = name
	Config.ApplyValues(profile.Values)
	Win.ApplyGeometry(profile.Window)
	Overlays.ApplyPositions(profile.Overlays)
	Config.Persist()
	SafeCall("Profiles", Config.ProfilesChanged)
	if not silent then
		Notify("Profiles", string_format('Loaded profile "%s".', name), 3, "Success")
	end
	return true
end

function Config.CreateProfile(rawName: any, duplicate: boolean)
	local name, problem = Config.ValidateProfileName(rawName)
	if not name then
		Notify("Profiles", problem, 4, "Warning")
		return
	end
	if Config.FindProfile(name) then
		Notify("Profiles", string_format('A profile named "%s" already exists.', name), 4, "Warning")
		return
	end
	if Config.AutoSaveEnabled() then
		Config.SaveNow()
	end
	local current = Config.CurrentProfile()
	local profile
	if duplicate then
		-- Stored values (keeps unknown ids) overlaid with what is on screen right now.
		profile = Util.DeepCopy(current)
		Config.Capture(profile)
	else
		profile = NewProfile()
		profile.Window = Util.DeepCopy(current.Window)
		profile.Overlays = Util.DeepCopy(current.Overlays)
	end
	Config.Data.Profiles[name] = profile
	Config.SwitchProfile(name, true)
	Notify(
		"Profiles",
		string_format(duplicate and 'Duplicated into "%s".' or 'Created "%s" with default values.', name),
		3,
		"Success"
	)
end

function Config.RenameProfile(rawName: any)
	local name, problem = Config.ValidateProfileName(rawName)
	if not name then
		Notify("Profiles", problem, 4, "Warning")
		return
	end
	local old = Config.Current
	if name == old then
		return
	end
	local clash = Config.FindProfile(name)
	if clash and clash ~= old then
		Notify("Profiles", string_format('A profile named "%s" already exists.', name), 4, "Warning")
		return
	end
	local profiles = Config.Data.Profiles
	profiles[name] = profiles[old]
	profiles[old] = nil
	Config.Current = name
	Config.Data.LastProfile = name
	Config.Persist()
	SafeCall("Profiles", Config.ProfilesChanged)
	Notify("Profiles", string_format('Renamed "%s" to "%s".', old, name), 3, "Success")
end

function Config.DeleteProfile()
	local profiles = Config.Data.Profiles
	local deleted = Config.Current
	profiles[deleted] = nil
	local nextName = profiles[DEFAULT_PROFILE] and DEFAULT_PROFILE or Util.SortedKeys(profiles)[1]
	if not nextName then
		nextName = DEFAULT_PROFILE
		profiles[nextName] = NewProfile()
	end
	Config.Current = nextName -- switch without capturing into the deleted profile
	Config.SwitchProfile(nextName, true)
	Notify("Profiles", string_format('Deleted "%s". Active profile: "%s".', deleted, nextName), 4, "Success")
end

function Config.ResetProfile()
	local profile = Config.CurrentProfile()
	profile.Values = {}
	Config.ApplyValues(profile.Values)
	Config.SaveNow()
	Notify("Config", string_format('Profile "%s" reset to defaults.', Config.Current), 3, "Success")
end

function Config.LoadFromDisk()
	if not Env.CanWrite then
		Notify("Config", "This executor has no file functions; nothing to load.", 5, "Warning")
		return
	end
	local data, status = Config.ReadFile()
	if not data then
		if status == "missing" then
			Notify("Config", "No saved file yet. It is created on the first change.", 4, "Warning")
		else
			Notify("Config", "The file is unreadable or corrupt; your current settings were kept.", 6, "Error")
		end
		return
	end
	Config.Data = data
	if not data.Profiles[Config.Current] then
		Config.Current = data.Profiles[data.LastProfile] and data.LastProfile or Util.SortedKeys(data.Profiles)[1]
	end
	local ok, json = encodeData()
	Config.LastJson = ok and json or nil
	Config.SwitchProfile(Config.Current, true)
	Notify("Config", string_format('Reloaded "%s" from disk.', Config.Current), 3, "Success")
end

function Config.Export(): string?
	-- Exports what is on screen (a captured copy), without touching the file.
	local profile = Util.DeepCopy(Config.CurrentProfile())
	Config.Capture(profile)
	local ok, json = pcall(HttpService.JSONEncode, HttpService, {
		Kind = EXPORT_KIND,
		ConfigVersion = CONFIG_VERSION,
		Script = SETTINGS.Title,
		Profile = Config.Current,
		Values = profile.Values,
		Window = profile.Window,
		Overlays = profile.Overlays,
	})
	if not ok then
		Notify("Export", "Could not encode the profile: " .. CleanError(json), 5, "Error")
		return nil
	end
	return json
end

-- Validates pasted JSON against the registry, then asks for confirmation before applying.
function Config.Import(text: any)
	local source = Util.Trim(tostring(text or ""))
	if source == "" then
		Notify("Import", "Paste an exported JSON string into the box first.", 4, "Warning")
		return
	end
	local ok, decoded = pcall(HttpService.JSONDecode, HttpService, source)
	if not ok or type(decoded) ~= "table" then
		Notify("Import", "That text is not valid JSON.", 5, "Error")
		return
	end
	local values = decoded
	if type(decoded.Values) == "table" then
		values = decoded.Values -- an export (or a v1 file)
	elseif type(decoded.Profiles) == "table" then
		local whole = Config.Sanitize(decoded) -- a full config file was pasted: use its last profile
		values = whole and whole.Profiles[whole.LastProfile].Values or {}
	end
	if tonumber(decoded.ConfigVersion) and tonumber(decoded.ConfigVersion) > CONFIG_VERSION then
		Notify("Import", "This export comes from a newer version; unknown values will be skipped.", 5, "Warning")
	end

	local accepted, acceptedCount, rejected, unknown = {}, 0, 0, 0
	for id, raw in pairs(values) do
		local entry = type(id) == "string" and Config.Registry[id] or nil
		if not entry or not entry.Persist then
			unknown += 1
		else
			local decodedOk, value = pcall(entry.Codec.Decode, entry, raw)
			if decodedOk and value ~= nil then
				accepted[id] = value
				acceptedCount += 1
			else
				rejected += 1
			end
		end
	end
	if acceptedCount == 0 then
		Notify("Import", "No valid settings were found in that JSON.", 5, "Error")
		return
	end

	Confirm(
		"Import settings?",
		string_format(
			'Apply %d setting(s) to profile "%s"? %d invalid and %d unknown value(s) will be skipped.',
			acceptedCount,
			Config.Current,
			rejected,
			unknown
		),
		function()
			local profile = Config.CurrentProfile()
			for id, value in pairs(accepted) do
				profile.Values[id] = value
			end
			Config.ApplyValues(profile.Values)
			if type(decoded.Window) == "table" then
				Win.ApplyGeometry(decoded.Window)
			end
			Config.SaveNow()
			Notify("Import", string_format("Imported %d setting(s).", acceptedCount), 4, "Success")
		end,
		"Import"
	)
end

--══════════════════════════════════════════════════════════════════════════════
-- 5. BACKGROUND
--══════════════════════════════════════════════════════════════════════════════
-- URL → cached file (<Folder>/cache/bg_<hash>.png|jpg) → getcustomasset → ImageLabel.
-- The cache key is a hash of the URL, so every URL is downloaded exactly once per machine and
-- changing the URL never shows a stale image. Without writefile/getcustomasset the optional
-- rbxassetid fallback is used instead.
Background.Image = nil :: ImageLabel?
Background.Url = ""
Background.Enabled = true
Background.Transparency = 0.4
Background.Dim = 0.3 -- darkens the image (ImageColor3) so light theme text stays readable
Background.ContentId = nil :: string?
Background.Status = "No image set"
Background.Token = 0 -- bumps on every load; stale downloads compare it and discard their result
Background.StatusChanged = NOOP :: (string) -> ()

local IMAGE_EXTENSIONS = { "png", "jpg" }

-- Image layer inside Fluent's window paint: above the acrylic tint, below the window border and
-- every element (they are later siblings of the paint frame), clipped with the window's 8px radius.
function Background.Attach(window: any)
	local paint = window.AcrylicPaint and window.AcrylicPaint.Frame
	if not paint then
		return
	end
	Background.Image = Util.Create("ImageLabel", {
		Name = "CustomBackground",
		BackgroundTransparency = 1,
		Size = UDim2_fromScale(1, 1),
		ScaleType = Enum.ScaleType.Crop,
		Image = "",
		ImageTransparency = Background.Transparency,
		ZIndex = 1,
		Visible = false,
		Parent = paint,
	}, { Util.Corner(8) })
end

function Background.Refresh()
	local image = Background.Image
	if not image then
		return
	end
	local contentId = Background.ContentId
	if image.Image ~= (contentId or "") then
		image.Image = contentId or ""
	end
	image.ImageTransparency = Background.Transparency
	local brightness = 1 - Background.Dim
	image.ImageColor3 = Color3.new(brightness, brightness, brightness)
	image.Visible = Background.Enabled and contentId ~= nil
end

local function setBackgroundStatus(text: string)
	Background.Status = text
	SafeCall("Background", Background.StatusChanged, text)
end

local function backgroundCachePath(url: string, extension: string): string
	return string_format("%s/bg_%s.%s", Config.CacheFolder, Util.Hash(url), extension)
end

-- Yields (HttpGet), so it is only ever called from its own thread.
function Background.Resolve(url: string): (string?, string)
	if not string_find(url, "^https?://") then
		return nil, "The URL must start with http:// or https://"
	end
	if not Env.CanUseAssets then
		return nil, "This executor has no writefile/getcustomasset"
	end
	local path = nil
	for _, extension in ipairs(IMAGE_EXTENSIONS) do
		local candidate = backgroundCachePath(url, extension)
		local ok, exists = pcall(Env.isfile, candidate)
		if ok and exists then
			path = candidate
			break
		end
	end
	local source = "Loaded from cache"
	if not path then
		local ok, data = pcall(function()
			return (game :: any):HttpGet(url)
		end)
		if not ok then
			return nil, "Download failed: " .. CleanError(data)
		end
		local extension = Util.DetectImage(data)
		if not extension then
			return nil, "That URL did not return a PNG or JPG image"
		end
		Config.EnsureFolder(Config.Folder)
		Config.EnsureFolder(Config.CacheFolder)
		path = backgroundCachePath(url, extension)
		local written, err = pcall(Env.writefile, path, data)
		if not written then
			return nil, "Could not cache the image: " .. CleanError(err)
		end
		source = "Downloaded and cached"
	end
	local ok, contentId = pcall(Env.getcustomasset, path)
	if not ok or type(contentId) ~= "string" or contentId == "" then
		return nil, "getcustomasset failed for the cached file"
	end
	return contentId, source
end

-- Loads (or clears) the background without blocking the UI. In-flight downloads are never
-- cancelled mid-request (unsafe on some executors); their results are ignored via the token.
function Background.Load(rawUrl: string?)
	local url = Util.Trim(tostring(rawUrl or ""))
	Background.Url = url
	Background.Token += 1
	local token = Background.Token
	local fallbackId = string_match(tostring(SETTINGS.FallbackAssetId or ""), "%d+")
	local fallback = fallbackId and ("rbxassetid://" .. fallbackId) or nil
	if url == "" then
		Background.ContentId = fallback
		setBackgroundStatus(fallback and "Using the fallback asset id" or "No image set")
		Background.Refresh()
		return
	end
	setBackgroundStatus("Loading…")
	task_spawn(function()
		local contentId, status = Background.Resolve(url)
		if token ~= Background.Token or App.Unloaded then
			return
		end
		local failed = contentId == nil
		if failed and fallback then
			contentId = fallback
			status ..= " (using the fallback asset)"
		end
		Background.ContentId = contentId
		setBackgroundStatus(status)
		Background.Refresh()
		if failed then
			Notify("Background", status, 5, "Warning")
		end
	end)
end

function Background.SetEnabled(enabled: boolean)
	Background.Enabled = enabled
	Background.Refresh()
end

function Background.SetTransparency(value: number)
	Background.Transparency = math_clamp(tonumber(value) or 0, 0, 1)
	Background.Refresh()
end

function Background.SetDim(value: number)
	Background.Dim = math_clamp(tonumber(value) or 0, 0, 0.9)
	Background.Refresh()
end

-- Deletes cached downloads. Returns the number of files removed, or -1 when unsupported.
function Background.ClearCache(): number
	if not (Env.CanWrite and Env.listfiles and Env.delfile) then
		return -1
	end
	local ok, files = pcall(Env.listfiles, Config.CacheFolder)
	if not ok or type(files) ~= "table" then
		return 0
	end
	local removed = 0
	for _, file in ipairs(files) do
		if type(file) == "string" and string_find(file, "bg_%x+%.%a+$") and pcall(Env.delfile, file) then
			removed += 1
		end
	end
	return removed
end

--══════════════════════════════════════════════════════════════════════════════
-- 6. WINDOW
--══════════════════════════════════════════════════════════════════════════════

-- Fluent internals (optional fast paths) -----------------------------------------
-- Fluent re-applies its WHOLE theme registry every time a themed instance is created (O(n²)
-- while building) and never forgets destroyed instances. When debug.getupvalues exists we
-- reach its private Creator module to (1) batch theme passes, (2) prune destroyed instances and
-- dead connections, and (3) patch theme accents for the live accent colour. Without it the
-- script uses Fluent's public API only: same features, just slower builds.
Internals.Creator = nil :: any
Internals.Themes = nil :: any
Internals.Resolved = false
Internals.Batching = false
Internals.SavedUpdate = nil :: any
Internals.PruneThread = nil :: thread?

function Internals.Resolve()
	if Internals.Resolved then
		return
	end
	Internals.Resolved = true
	local readUpvalues, fluent = Env.getupvalues, App.Fluent
	if not readUpvalues or not fluent then
		return
	end
	pcall(function()
		for _, value in pairs(readUpvalues(fluent.SetTheme)) do
			if
				type(value) == "table"
				and type(rawget(value, "UpdateTheme")) == "function"
				and type(rawget(value, "Registry")) == "table"
			then
				Internals.Creator = value
				break
			end
		end
		local creator = Internals.Creator
		if creator and type(creator.GetThemeProperty) == "function" then
			for _, value in pairs(readUpvalues(creator.GetThemeProperty)) do
				if type(value) == "table" and type(rawget(value, "Names")) == "table" then
					Internals.Themes = value
					break
				end
			end
		end
	end)
end

-- While batching, Fluent's per-instance theme pass is disabled; EndBatch does one full pass.
-- CreateWindow begins a batch that Finalize ends, so a whole hub builds in O(n) instead of O(n²).
function Internals.BeginBatch(): boolean
	local creator = Internals.Creator
	if not creator or Internals.Batching then
		return false
	end
	Internals.SavedUpdate = creator.UpdateTheme
	creator.UpdateTheme = NOOP
	Internals.Batching = true
	return true
end

function Internals.EndBatch()
	local creator = Internals.Creator
	if not creator or not Internals.Batching then
		return
	end
	local update = Internals.SavedUpdate
	creator.UpdateTheme = update
	Internals.Batching = false
	Internals.SavedUpdate = nil
	update()
end

-- Runs fn inside a batch (or directly when one is already running).
function Internals.Batch(fn: () -> ())
	if not Internals.BeginBatch() then
		fn()
		return
	end
	local ok, err = pcall(fn)
	Internals.EndBatch()
	if not ok then
		error(err, 0)
	end
end

-- Forgets destroyed instances in Fluent's theme registry and dead entries in its signal list.
function Internals.Prune()
	Internals.PruneThread = nil
	local creator = Internals.Creator
	if not creator or App.Unloaded then
		return
	end
	local registry = creator.Registry
	for instance in pairs(registry) do
		if typeof(instance) == "Instance" and instance.Parent == nil then
			registry[instance] = nil
		end
	end
	local signals = creator.Signals
	if type(signals) == "table" then
		local kept = 0
		for index = 1, #signals do
			local connection = signals[index]
			if connection.Connected then
				kept += 1
				signals[kept] = connection
			end
		end
		for index = #signals, kept + 1, -1 do
			signals[index] = nil
		end
	end
end

-- Coalesced: at most one prune per 10 s, and only while things are being created/destroyed.
function Internals.SchedulePrune()
	if Internals.Creator and not Internals.PruneThread and not App.Unloaded then
		Internals.PruneThread = task_delay(10, Internals.Prune)
	end
end

-- Palette for our own widgets (search bar, overlays). Text/accent are read back from Fluent's
-- themed instances, so custom accents and every built-in theme are followed automatically.
local PANEL_COLORS = {
	Dark = Color3_fromRGB(32, 32, 32),
	Darker = Color3_fromRGB(20, 20, 20),
	Light = Color3_fromRGB(242, 242, 242),
	Aqua = Color3_fromRGB(18, 32, 34),
	Amethyst = Color3_fromRGB(28, 22, 40),
	Rose = Color3_fromRGB(38, 22, 28),
}
local Palette = {
	Text = Color3_fromRGB(240, 240, 240),
	Accent = Color3_fromRGB(96, 205, 255),
	Panel = PANEL_COLORS.Dark,
	Light = false,
}
local Painters: { (typeof(Palette)) -> () } = {}

-- Accent --------------------------------------------------------------------------
local THEME_ACCENTS = {
	Dark = Color3_fromRGB(96, 205, 255),
	Darker = Color3_fromRGB(72, 138, 182),
	Light = Color3_fromRGB(0, 103, 192),
	Aqua = Color3_fromRGB(60, 165, 165),
	Amethyst = Color3_fromRGB(97, 62, 167),
	Rose = Color3_fromRGB(180, 55, 90),
}
Accent.Enabled = false
Accent.Color = THEME_ACCENTS.Dark
Accent.ThemeSets = false :: any -- false = not resolved yet, nil = unavailable
Accent.Originals = {} :: { [any]: Color3 }
Accent.FallbackActive = false
Accent.Applied = nil :: Color3?
Accent.RecolorQueued = false

-- Theme tables via the Creator upvalue (precise) or a one-time getgc scan (fallback).
function Accent.ResolveThemes(): { any }?
	if Accent.ThemeSets ~= false then
		return Accent.ThemeSets
	end
	local sets = nil
	if Internals.Themes then
		sets = { Internals.Themes }
	elseif Env.getgc then
		pcall(function()
			local found = {}
			for _, object in ipairs(Env.getgc(true)) do
				if type(object) == "table" and type(rawget(object, "Names")) == "table" then
					local dark = rawget(object, "Dark")
					if type(dark) == "table" and typeof(rawget(dark, "Accent")) == "Color3" then
						found[#found + 1] = object
					end
				end
			end
			if #found > 0 then
				sets = found
			end
		end)
	end
	Accent.ThemeSets = sets
	return sets
end

local function recolorAccent(from: Color3, to: Color3)
	local fluent = App.Fluent
	if from == to or not fluent then
		return
	end
	for _, instance in ipairs(fluent.GUI:GetDescendants()) do
		if instance:IsA("GuiObject") then
			if instance.BackgroundColor3 == from then
				instance.BackgroundColor3 = to
			end
			if (instance:IsA("ImageLabel") or instance:IsA("ImageButton")) and instance.ImageColor3 == from then
				instance.ImageColor3 = to
			end
		elseif instance:IsA("UIStroke") and instance.Color == from then
			instance.Color = to
		end
	end
end

-- Fallback (no debug access): repaint accent-coloured instances, re-applied (coalesced) whenever
-- Fluent creates instances, because its theme pass would paint the stock accent back.
function Accent.SetFallback(color: Color3?)
	local fluent = App.Fluent
	local stock = THEME_ACCENTS[fluent.Theme] or THEME_ACCENTS.Dark
	if color then
		if Accent.Applied and Accent.Applied ~= color then
			recolorAccent(Accent.Applied, stock)
		end
		Accent.FallbackActive = true
		Accent.Applied = color
		recolorAccent(stock, color)
		App.Maid:Set("AccentWatch", fluent.GUI.DescendantAdded:Connect(Accent.ScheduleRecolor))
	else
		if Accent.Applied then
			recolorAccent(Accent.Applied, stock)
		end
		Accent.FallbackActive = false
		Accent.Applied = nil
		App.Maid:Set("AccentWatch", nil)
	end
end

function Accent.ScheduleRecolor()
	if Accent.RecolorQueued or not Accent.FallbackActive then
		return
	end
	Accent.RecolorQueued = true
	task_delay(0.05, function()
		Accent.RecolorQueued = false
		local fluent = App.Fluent
		if Accent.FallbackActive and Accent.Applied and fluent and not App.Unloaded then
			recolorAccent(THEME_ACCENTS[fluent.Theme] or THEME_ACCENTS.Dark, Accent.Applied)
		end
	end)
end

function Accent.Apply()
	local fluent = App.Fluent
	if not fluent or not App.Window then
		return
	end
	local color = Accent.Enabled and Accent.Color or nil
	local sets = nil
	if Accent.Enabled or next(Accent.Originals) ~= nil then
		sets = Accent.ResolveThemes()
	end
	if sets then
		for _, themes in ipairs(sets) do
			for _, name in ipairs(themes.Names) do
				local theme = rawget(themes, name)
				if type(theme) == "table" then
					if Accent.Originals[theme] == nil then
						Accent.Originals[theme] = theme.Accent
					end
					theme.Accent = color or Accent.Originals[theme]
				end
			end
		end
		fluent:SetTheme(fluent.Theme) -- one theme pass repaints every accent-tagged instance
	elseif color or Accent.FallbackActive then
		Accent.SetFallback(color)
	end
	Win.ThemeSync()
end

function Accent.Set(enabled: boolean?, color: Color3?)
	if enabled ~= nil then
		Accent.Enabled = enabled
	end
	if color then
		Accent.Color = color
	end
	if App.Ready or Accent.Enabled then
		Accent.Apply()
	end
end

-- Font size ------------------------------------------------------------------------
-- Scales TextSize of every text object relative to its original size. New instances (dropdown
-- rebuilds, toasts, dialogs) are picked up via DescendantAdded only while the size isn't Normal,
-- and processed in one deferred batch per frame.
local FONT_MULTIPLIERS = { Small = 0.9, Normal = 1, Large = 1.15 }
FontSize.Multiplier = 1
FontSize.Base = setmetatable({}, { __mode = "k" }) :: any -- weak keys: [TextObject] = original size
FontSize.Pending = {} :: { Instance }
FontSize.Scheduled = false

local function isTextObject(instance: Instance): boolean
	return instance:IsA("TextLabel") or instance:IsA("TextButton") or instance:IsA("TextBox")
end

function FontSize.ApplyTo(instance: any)
	local base = FontSize.Base[instance]
	if base == nil then
		base = instance.TextSize
		FontSize.Base[instance] = base
	end
	local size = math_floor(base * FontSize.Multiplier + 0.5)
	if instance.TextSize ~= size then
		instance.TextSize = size
	end
end

local function flushFontQueue()
	FontSize.Scheduled = false
	local pending = FontSize.Pending
	for index = 1, #pending do
		local instance = pending[index]
		pending[index] = nil
		if instance.Parent then
			FontSize.ApplyTo(instance)
		end
	end
end

local function queueFontObject(instance: Instance)
	if not isTextObject(instance) then
		return
	end
	local pending = FontSize.Pending
	pending[#pending + 1] = instance
	if not FontSize.Scheduled then
		FontSize.Scheduled = true
		task_defer(flushFontQueue)
	end
end

function FontSize.Roots(): { Instance }
	local roots = {}
	if App.Fluent then
		roots[#roots + 1] = App.Fluent.GUI
	end
	if Overlays.Gui then
		roots[#roots + 1] = Overlays.Gui
	end
	return roots
end

function FontSize.Set(name: string)
	local multiplier = FONT_MULTIPLIERS[name] or 1
	if multiplier == FontSize.Multiplier then
		return
	end
	FontSize.Multiplier = multiplier
	for _, root in ipairs(FontSize.Roots()) do
		for _, instance in ipairs(root:GetDescendants()) do
			if isTextObject(instance) then
				FontSize.ApplyTo(instance)
			end
		end
	end
	if multiplier ~= 1 then
		for index, root in ipairs(FontSize.Roots()) do
			App.Maid:Set("FontWatch" .. index, root.DescendantAdded:Connect(queueFontObject))
		end
	else
		App.Maid:Set("FontWatch1", nil)
		App.Maid:Set("FontWatch2", nil)
	end
end

-- Search ---------------------------------------------------------------------------
-- Every element registers its root frame here. Filtering toggles Visible on element frames
-- (UIListLayouts skip invisible children), hides empty sections, and marks tab buttons with
-- their match count so results in other tabs are visible at a glance.
Search.Records = {} :: { any }
Search.Tabs = {} :: { any }
Search.Sections = {} :: { any }
Search.Query = ""

function Search.AddTab(tab: any, name: string): any
	local record = {
		Name = name,
		Tab = tab,
		Label = tab.Frame and tab.Frame:FindFirstChildOfClass("TextLabel"),
		Count = 0,
	}
	Search.Tabs[#Search.Tabs + 1] = record
	return record
end

function Search.AddSection(root: Instance?): any
	local record = { Root = root, Count = 0 }
	Search.Sections[#Search.Sections + 1] = record
	return record
end

function Search.Add(frame: GuiObject?, title: string, keywords: string?, tabRecord: any, sectionRecord: any)
	if not frame or not tabRecord then
		return
	end
	local text = keywords and string_format("%s %s", title, keywords) or title
	Search.Records[#Search.Records + 1] = {
		Frame = frame,
		Text = string_lower(text),
		Tab = tabRecord,
		Section = sectionRecord,
	}
end

function Search.Apply(raw: string?)
	local query = string_lower(Util.Trim(tostring(raw or "")))
	Search.Query = query
	local searching = query ~= ""
	for _, tab in ipairs(Search.Tabs) do
		tab.Count = 0
	end
	for _, section in ipairs(Search.Sections) do
		section.Count = 0
	end
	local total = 0
	for _, record in ipairs(Search.Records) do
		local visible = not searching or string_find(record.Text, query, 1, true) ~= nil
		local frame = record.Frame
		if frame.Visible ~= visible then
			frame.Visible = visible
		end
		if visible then
			total += 1
			record.Tab.Count += 1
			if record.Section then
				record.Section.Count += 1
			end
		end
	end
	for _, section in ipairs(Search.Sections) do
		local root = section.Root
		if root then
			local visible = not searching or section.Count > 0
			if root.Visible ~= visible then
				root.Visible = visible
			end
		end
	end
	for _, tab in ipairs(Search.Tabs) do
		local label = tab.Label
		if label then
			if searching and tab.Count > 0 then
				label.Text = string_format('%s  <font transparency="0.45">%d</font>', tab.Name, tab.Count)
				label.TextTransparency = 0
			else
				label.Text = tab.Name
				label.TextTransparency = searching and 0.6 or 0
			end
		end
	end
	if Win.SearchCount then
		Win.SearchCount.Text = searching and tostring(total) or ""
	end
end

-- Scale fix ------------------------------------------------------------------------
-- Fluent sizes sections and scroll canvases from AbsoluteContentSize and places the tab selector
-- from AbsolutePosition. Those are *scaled* pixels, but Fluent writes them into unscaled offsets,
-- so under any UIScale ≠ 1 (UI scale slider, mobile auto-fit, open/close zoom) sections come out
-- too short (overlapping) or too tall. Each of those properties is re-derived as value / scale
-- whenever Fluent writes it. Event-driven only: nothing runs while the layout is idle.
ScaleFix.Fixers = {} :: { () -> () }

local function currentScale(): number
	local scale = Win.Scale
	local value = scale and scale.Scale or 1
	return if value > 0 then value else 1
end

local function addFixer(fix: () -> ())
	ScaleFix.Fixers[#ScaleFix.Fixers + 1] = fix
	fix()
end

-- Section: Container height = content, Root height = content + 25 (the section title).
function ScaleFix.Section(container: Frame)
	local layout = container:FindFirstChildOfClass("UIListLayout")
	local root = container.Parent :: Frame
	if not layout or not root then
		return
	end
	local function fix()
		local height = layout.AbsoluteContentSize.Y / currentScale()
		if math_abs(container.Size.Y.Offset - height) > 0.5 then
			container.Size = UDim2_new(1, 0, 0, height)
		end
		if math_abs(root.Size.Y.Offset - (height + 25)) > 0.5 then
			root.Size = UDim2_new(1, 0, 0, height + 25)
		end
	end
	App.Maid:Connect(container:GetPropertyChangedSignal("Size"), fix)
	App.Maid:Connect(root:GetPropertyChangedSignal("Size"), fix)
	addFixer(fix)
end

-- Scrolling canvases (tab pages: content + 2, tab list: content).
function ScaleFix.Canvas(scroller: ScrollingFrame, extra: number)
	local layout = scroller:FindFirstChildOfClass("UIListLayout")
	if not layout then
		return
	end
	local function fix()
		local height = layout.AbsoluteContentSize.Y / currentScale() + extra
		if math_abs(scroller.CanvasSize.Y.Offset - height) > 0.5 then
			scroller.CanvasSize = UDim2_new(0, 0, 0, height)
		end
	end
	App.Maid:Connect(scroller:GetPropertyChangedSignal("CanvasSize"), fix)
	addFixer(fix)
end

-- Tab selector: Fluent writes (tab offset in scaled px) + 17 every step of its spring.
function ScaleFix.Selector(selector: Frame)
	local lastSet: UDim2? = nil
	App.Maid:Connect(selector:GetPropertyChangedSignal("Position"), function()
		local position = selector.Position
		if position == lastSet then
			return
		end
		local corrected = UDim2_new(0, 0, 0, (position.Y.Offset - 17) / currentScale() + 17)
		lastSet = corrected
		if corrected ~= position then
			selector.Position = corrected
		end
	end)
end

function ScaleFix.RefreshAll()
	for _, fix in ipairs(ScaleFix.Fixers) do
		fix()
	end
end

-- Window ---------------------------------------------------------------------------
Win.Scale = nil :: UIScale?
Win.UserScale = 1
Win.BaseScale = 1
Win.Selector = nil :: Frame?
Win.OriginalMinimize = nil :: any
Win.Open = true
Win.Tweens = {} :: { Tween }
Win.RestPosition = nil :: UDim2?
Win.LastGeometry = nil :: any
Win.SearchBox = nil :: TextBox?
Win.SearchCount = nil :: TextLabel?
Win.OriginalMaximize = nil :: any

function Win.Paint(painter: (typeof(Palette)) -> ())
	Painters[#Painters + 1] = painter
	SafeCall("Theme", painter, Palette)
end

function Win.ThemeSync()
	local window, fluent = App.Window, App.Fluent
	if window then
		Palette.Text = window.TabDisplay.TextColor3
		if Win.Selector then
			Palette.Accent = Win.Selector.BackgroundColor3
		end
	end
	local theme = fluent and fluent.Theme or "Dark"
	Palette.Panel = PANEL_COLORS[theme] or PANEL_COLORS.Dark
	Palette.Light = theme == "Light"
	for _, painter in ipairs(Painters) do
		SafeCall("Theme", painter, Palette)
	end
end

-- Uniform window scale = min(user scale, what fits on screen). Drives one UIScale.
function Win.UpdateScale()
	local window, scale = App.Window, Win.Scale
	if not window or not scale then
		return
	end
	local screen = App.Fluent.GUI.AbsoluteSize
	local fit = 1
	if screen.X > 0 and screen.Y > 0 then
		local margin = IsTouch and 12 or 24
		local size = window.Size
		fit = math_min((screen.X - margin * 2) / size.X.Offset, (screen.Y - margin * 2) / size.Y.Offset)
	end
	Win.BaseScale = if window.Maximized then 1 else math_clamp(math_min(Win.UserScale, fit), 0.45, 1.25)
	if #Win.Tweens == 0 and scale.Scale ~= Win.BaseScale then
		scale.Scale = Win.BaseScale
		ScaleFix.RefreshAll()
	end
end

function Win.SetUserScale(value: number)
	Win.UserScale = math_clamp(tonumber(value) or 1, 0.75, 1.25)
	Win.UpdateScale()
	Win.KeepOnScreen()
end

function Win.ClampPosition(x: number, y: number, width: number, height: number): (number, number)
	local screen = App.Fluent.GUI.AbsoluteSize
	local scale = Win.BaseScale
	local maxX = math_max(0, screen.X - width * scale)
	local maxY = math_max(0, screen.Y - height * scale)
	return math_floor(math_clamp(x, 0, maxX) + 0.5), math_floor(math_clamp(y, 0, maxY) + 0.5)
end

function Win.GetGeometry(): { [string]: number }?
	local window = App.Window
	if not window then
		return nil
	end
	if window.Maximized then
		return Win.LastGeometry -- keep the last normal geometry while maximized
	end
	-- window.Position is Fluent's logical position (updated while dragging, untouched by our
	-- open/close tween and by its position spring), so it is always the value worth saving.
	local position = window.Position
	local size = window.Root.Size
	local geometry = {
		X = math_floor(position.X.Offset + 0.5),
		Y = math_floor(position.Y.Offset + 0.5),
		W = math_floor(size.X.Offset + 0.5),
		H = math_floor(size.Y.Offset + 0.5),
	}
	Win.LastGeometry = geometry
	return geometry
end

function Win.ApplyGeometry(geometry: any)
	local window = App.Window
	if not window or type(geometry) ~= "table" then
		return
	end
	local width = math_clamp(tonumber(geometry.W) or window.Size.X.Offset, 470, 2048)
	local height = math_clamp(tonumber(geometry.H) or window.Size.Y.Offset, 380, 2048)
	local x, y = tonumber(geometry.X), tonumber(geometry.Y)
	local hasPosition = Util.IsFiniteNumber(x) and Util.IsFiniteNumber(y)
	Win.FinishAnimation()
	window.Size = UDim2_fromOffset(width, height)
	Win.UpdateScale()
	if hasPosition then
		local clampedX, clampedY = Win.ClampPosition(x :: number, y :: number, width, height)
		window.Position = UDim2_fromOffset(clampedX, clampedY)
	end
	-- Fluent keeps size/position in private spring motors; its own Maximize routine is the only
	-- public way to re-sync them (size instantly, position with its usual spring).
	local maximize = Win.OriginalMaximize or window.Maximize
	maximize(true, true, true)
	maximize(false, not hasPosition, true)
end

function Win.KeepOnScreen()
	local window = App.Window
	if not window or window.Maximized then
		return
	end
	local root = window.Root
	local position, size = root.Position, root.Size
	local x, y = Win.ClampPosition(position.X.Offset, position.Y.Offset, size.X.Offset, size.Y.Offset)
	if x ~= math_floor(position.X.Offset + 0.5) or y ~= math_floor(position.Y.Offset + 0.5) then
		Win.ApplyGeometry({ X = x, Y = y, W = size.X.Offset, H = size.Y.Offset })
	end
end

-- Open/close animation: one UIScale tween + one Position tween (native, no per-frame Lua), with
-- the position compensated so the window zooms from its centre.
function Win.FinishAnimation()
	local tweens = Win.Tweens
	if #tweens == 0 then
		return
	end
	for index = #tweens, 1, -1 do
		local tween = tweens[index]
		tweens[index] = nil
		tween:Cancel()
		tween:Destroy()
	end
	local window = App.Window
	if Win.RestPosition then
		window.Root.Position = Win.RestPosition
		Win.RestPosition = nil
	end
	if Win.Scale then
		Win.Scale.Scale = Win.BaseScale
	end
	if not Win.Open and not window.Minimized then
		Win.OriginalMinimize(window)
	end
end

function Win.Toggle(forceOpen: boolean?)
	local window = App.Window
	if not window then
		return
	end
	Win.FinishAnimation()
	local opening = if forceOpen ~= nil then forceOpen else not Win.Open
	if opening == Win.Open and (opening ~= window.Minimized) then
		return
	end
	Win.Open = opening
	if opening and window.Minimized then
		Win.OriginalMinimize(window) -- Fluent shows the root (and its one-time key hint)
	end
	Tooltip.Hide()
	if not App.AnimationsEnabled or not Win.Scale then
		if not opening and not window.Minimized then
			Win.OriginalMinimize(window)
		end
		Overlays.OnWindowToggled(opening)
		return
	end

	local root = window.Root
	local base = Win.BaseScale
	local rest = root.Position
	local size = root.AbsoluteSize
	local shrink = 0.92
	local offset = UDim2_fromOffset(size.X * (1 - shrink) * 0.5, size.Y * (1 - shrink) * 0.5)
	Win.RestPosition = rest
	if opening then
		Win.Scale.Scale = base * shrink
		root.Position = rest + offset
	end
	local info = opening and TWEEN_OPEN or TWEEN_CLOSE
	local scaleTween = TweenService:Create(Win.Scale, info, { Scale = opening and base or base * shrink })
	local moveTween = TweenService:Create(root, info, { Position = opening and rest or rest + offset })
	Win.Tweens[1] = scaleTween
	Win.Tweens[2] = moveTween
	scaleTween.Completed:Connect(function(state: Enum.PlaybackState)
		if state == Enum.PlaybackState.Completed then
			Win.FinishAnimation()
		end
	end)
	scaleTween:Play()
	moveTween:Play()
	Overlays.OnWindowToggled(opening)
end

-- Re-runs Fluent's dialog sizing rules after the font multiplier enlarged the dialog's text.
function Win.RefitDialog(tint: Instance, config: any)
	local dialogRoot = tint:FindFirstChildOfClass("CanvasGroup")
	if not dialogRoot then
		return
	end
	local content: TextLabel? = nil
	for _, descendant in ipairs(dialogRoot:GetDescendants()) do
		if isTextObject(descendant) then
			FontSize.ApplyTo(descendant)
			if descendant:IsA("TextLabel") and descendant.Text == config.Content then
				content = descendant
			end
		end
	end
	if not content then
		return
	end
	local limit = App.Window.Size.X.Offset - 120
	content.TextWrapped = false -- measure the natural single-line width first
	local width = content.TextBounds.X + 40
	if width > limit then
		dialogRoot.Size = UDim2_fromOffset(limit, 165)
		content.TextWrapped = true
		dialogRoot.Size = UDim2_fromOffset(limit, content.TextBounds.Y + 150)
	else
		dialogRoot.Size = UDim2_fromOffset(width, 165)
	end
end

function Win.CreateSearchBar(window: any, tabFrame: Frame)
	local width = SETTINGS.TabWidth
	tabFrame.Position = UDim2_new(0, 12, 0, 92)
	tabFrame.Size = UDim2_new(0, width, 1, -104)

	local stroke = Util.Create("UIStroke", { Transparency = 0.82, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
	local icon = Util.Create("ImageLabel", {
		BackgroundTransparency = 1,
		Image = App.Fluent:GetIcon("search") or "",
		ImageTransparency = 0.35,
		Size = UDim2_fromOffset(14, 14),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2_new(0, 9, 0.5, 0),
	})
	local box = Util.Create("TextBox", {
		Name = "Query",
		BackgroundTransparency = 1,
		ClearTextOnFocus = false,
		Text = "",
		PlaceholderText = IsTouch and "Search…" or "Search…  (Ctrl+F)",
		FontFace = FONT_REGULAR,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextTruncate = Enum.TextTruncate.AtEnd,
		Position = UDim2_fromOffset(29, 0),
		Size = UDim2_new(1, -58, 1, 0),
	})
	local count = Util.Create("TextLabel", {
		BackgroundTransparency = 1,
		Text = "",
		FontFace = FONT_REGULAR,
		TextSize = 11,
		TextTransparency = 0.35,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2_new(1, -9, 0.5, 0),
		Size = UDim2_fromOffset(26, 14),
	})
	local frame = Util.Create("Frame", {
		Name = "SearchBar",
		BackgroundTransparency = 0.94,
		Position = UDim2_fromOffset(12, 52),
		Size = UDim2_fromOffset(width, 32),
		Parent = window.Root,
	}, { Util.Corner(6), stroke, icon, box, count })
	Win.SearchBox = box
	Win.SearchCount = count
	Win.Paint(function(palette)
		frame.BackgroundColor3 = palette.Text
		stroke.Color = palette.Text
		icon.ImageColor3 = palette.Text
		box.TextColor3 = palette.Text
		box.PlaceholderColor3 = palette.Text:Lerp(palette.Panel, 0.5)
		count.TextColor3 = palette.Text
	end)
	App.Maid:Connect(box:GetPropertyChangedSignal("Text"), function()
		Search.Apply(box.Text)
	end)
end

function Win.Create(): any
	local fluent = App.Fluent
	local saved = Config.CurrentProfile().Window
	local width, height = SETTINGS.Size.X, SETTINGS.Size.Y
	if type(saved) == "table" then
		width = math_clamp(tonumber(saved.W) or width, 470, 2048)
		height = math_clamp(tonumber(saved.H) or height, 380, 2048)
	end
	-- Values the window needs before any element exists are peeked straight from the profile.
	local theme = Config.Peek("UI_Theme", function(value)
		return type(value) == "string" and table_find(fluent.Themes, value) and value or nil
	end) or SETTINGS.Theme
	local acrylic = Config.Peek("UI_AcrylicBlur", function(value)
		return value == true
	end) == true
	Win.UserScale = Config.Peek("UI_Scale", function(value)
		return Util.IsFiniteNumber(value) and math_clamp(value, 0.75, 1.25) or nil
	end) or 1

	local okKey, menuKey = pcall(function()
		return (Enum.KeyCode :: any)[SETTINGS.MenuKey]
	end)
	if not okKey or typeof(menuKey) ~= "EnumItem" then
		menuKey = Enum.KeyCode.RightControl
	end
	local window = fluent:CreateWindow({
		Title = SETTINGS.Title,
		SubTitle = SETTINGS.SubTitle or ("v" .. tostring(SETTINGS.Version)),
		TabWidth = SETTINGS.TabWidth,
		Size = UDim2_fromOffset(width, height),
		Acrylic = acrylic,
		Theme = theme,
		MinimizeKey = menuKey,
	})
	assert(window, "Fluent refused to create the window")
	App.Window = window
	local root = window.Root

	Win.Scale = Util.Create("UIScale", { Scale = 1, Parent = root })
	local tabFrame = window.TabHolder.Parent
	-- Tabs sort by LayoutOrder, so the Info/Settings tabs stay last even if tabs are added later.
	local tabLayout = window.TabHolder:FindFirstChildOfClass("UIListLayout")
	if tabLayout then
		tabLayout.SortOrder = Enum.SortOrder.LayoutOrder
	end
	for _, child in ipairs(tabFrame:GetChildren()) do
		if child ~= window.TabHolder and child:IsA("Frame") then
			Win.Selector = child
		end
	end

	Background.Attach(window)
	Win.CreateSearchBar(window, tabFrame)
	ScaleFix.Canvas(window.TabHolder, 0)
	if Win.Selector then
		ScaleFix.Selector(Win.Selector)
	end

	-- Fluent sizes dialogs from TextBounds, which is reported in scaled pixels and measured before
	-- our font multiplier reaches the new labels. Measure at scale 1 (synchronously, so nothing is
	-- rendered in between) and refit with the final font size, then let the UIScale apply again.
	local openDialog = window.Dialog
	window.Dialog = function(self, config)
		local scale = Win.Scale
		local scaled = scale ~= nil and scale.Scale ~= 1
		if not scaled and FontSize.Multiplier == 1 then
			return openDialog(self, config)
		end
		Win.FinishAnimation()
		local previous = scale and scale.Scale
		if scaled then
			scale.Scale = 1
		end
		local existing = {}
		for _, child in ipairs(root:GetChildren()) do
			existing[child] = true
		end
		local ok, result = pcall(openDialog, self, config)
		if ok and FontSize.Multiplier ~= 1 then
			for _, child in ipairs(root:GetChildren()) do
				if not existing[child] then
					pcall(Win.RefitDialog, child, config)
				end
			end
		end
		if scaled then
			scale.Scale = previous
		end
		if not ok then
			error(result, 0)
		end
		return result
	end

	-- Maximized windows fill the screen, so they always render at scale 1.
	Win.OriginalMaximize = window.Maximize
	window.Maximize = function(value: boolean, noPosition: boolean?, instant: boolean?)
		Win.OriginalMaximize(value, noPosition, instant)
		Win.UpdateScale()
	end

	-- Every open/close path (title bar button, menu key, mobile button) goes through Win.Toggle.
	Win.OriginalMinimize = window.Minimize
	window.Minimize = function()
		Win.Toggle()
	end

	-- A drag that starts mid-animation snaps the animation to its end state first.
	App.Maid:Connect(window.TitleBar.Frame.InputBegan, function(input: InputObject)
		local inputType = input.UserInputType
		if inputType == Enum.UserInputType.MouseButton1 or inputType == Enum.UserInputType.Touch then
			Win.FinishAnimation()
		end
	end)

	-- Geometry changes only stamp "dirty"; values are read when the debounced save runs.
	local function geometryChanged()
		if #Win.Tweens == 0 and not window.Maximized then
			Config.MarkDirty()
		end
	end
	App.Maid:Connect(root:GetPropertyChangedSignal("Position"), geometryChanged)
	App.Maid:Connect(root:GetPropertyChangedSignal("Size"), geometryChanged)
	App.Maid:Connect(fluent.GUI:GetPropertyChangedSignal("AbsoluteSize"), function()
		Win.UpdateScale()
		Win.KeepOnScreen()
	end)
	Win.UpdateScale()
	return window
end

--══════════════════════════════════════════════════════════════════════════════
-- 7. TABS
--══════════════════════════════════════════════════════════════════════════════
--[[
	Element wrapper
	  local tab = UI.Tab("Main", "home")              -- Lucide icon name (as supported by Fluent)
	  local section = tab:Section("Combat")
	  section:Toggle("AutoThing", { Title = "Auto thing", Default = false, Callback = function(on) end })

	Every value element takes (id, config). The id is the save key, so adding an element never
	requires touching the config code. Extra config fields on top of Fluent's own:
	  Tooltip       hover text (desktop)          Keywords   extra words for the search bar
	  Save = false  exclude from profiles         Callback   pcall'd; runs once with the loaded
	                                                         value, then once per real change
	  Input:        Numeric, Min, Max, Decimals, Placeholder, Finished, MaxLength
	  Dropdown:     searchable automatically above 10 options; option:Refresh(newValues)
	  Keybind:      Callback(toggled|held), ChangedCallback(key, mode); right-click cycles mode
	  Colorpicker:  Callback(color, transparency); Transparency = number enables the alpha slider
	  Paragraph:    section:Paragraph("Id", {...}) is saved; section:Paragraph({...}) is not
]]
local Builder = {}
Builder.__index = Builder

local captureScratch: { [Instance]: boolean } = {}

-- Fluent doesn't return element frames, so the new child of the container is found by diffing
-- (needed for search, tooltips, right-click handlers and the text box of inputs).
local function captureElement(holder: Instance, create: () -> any): (any, GuiObject?)
	table_clear(captureScratch)
	for _, child in ipairs(holder:GetChildren()) do
		captureScratch[child] = true
	end
	local result = create()
	local frame = nil
	local children = holder:GetChildren()
	for index = #children, 1, -1 do
		local child = children[index]
		if not captureScratch[child] and child:IsA("GuiObject") then
			frame = child
			break
		end
	end
	table_clear(captureScratch)
	return result, frame
end

-- Fires the "loaded value" callback for element types that Fluent doesn't fire on creation.
local function finalizeEntry(entry: Entry)
	if entry.Last == nil then
		Config.OnChanged(entry, entry.Option and entry.Option.Value)
	end
end

UI.TabCount = 0

-- layoutOrder is only passed by the built-in Info/Settings tabs, which always sort last.
function UI.Tab(title: string, icon: string?, layoutOrder: number?): any
	local tab = App.Window:AddTab({ Title = title, Icon = icon or "" })
	UI.TabCount += 1
	if tab.Frame then
		tab.Frame.LayoutOrder = layoutOrder or UI.TabCount
	end
	ScaleFix.Canvas(tab.ContainerFrame, 2)
	return setmetatable({
		Fluent = tab,
		Holder = tab.Container,
		TabRecord = Search.AddTab(tab, title),
		SectionRecord = nil,
		IsTab = true,
	}, Builder)
end

function Builder:Section(title: string): any
	assert(self.IsTab, "Sections can only be created on a tab")
	local section = self.Fluent:AddSection(title)
	ScaleFix.Section(section.Container)
	return setmetatable({
		Fluent = section,
		Holder = section.Container,
		TabRecord = self.TabRecord,
		SectionRecord = Search.AddSection(section.Container.Parent),
		IsTab = false,
	}, Builder)
end

function Builder:_decorate(frame: GuiObject?, spec: any)
	if frame then
		Search.Add(frame, tostring(spec.Title or ""), spec.Keywords, self.TabRecord, self.SectionRecord)
		Tooltip.Attach(frame, spec.Tooltip)
	end
end

function Builder:_value(kind: string, id: string, spec: any): (Entry, any, GuiObject?)
	local entry = Config.Register(kind, id, spec)
	local fluentConfig = { Title = entry.Title, Description = spec.Description }
	entry.Codec.Fluent(entry, entry.Initial, fluentConfig)
	if kind == "Keybind" then
		fluentConfig.Callback = function(toggled)
			KeybindList.OnPressed(entry, toggled)
		end
		fluentConfig.ChangedCallback = function()
			Config.OnChanged(entry)
		end
	else
		fluentConfig.Callback = function(raw)
			Config.OnChanged(entry, raw)
		end
	end
	local container = self.Fluent
	local option, frame = captureElement(self.Holder, function()
		return container["Add" .. kind](container, id, fluentConfig)
	end)
	entry.Option = option
	entry.Frame = frame
	self:_decorate(frame, spec)
	return entry, option, frame
end

function Builder:Toggle(id: string, spec: any): any
	local entry, option = self:_value("Toggle", id, spec)
	finalizeEntry(entry)
	return option
end

function Builder:Slider(id: string, spec: any): any
	assert(type(spec.Min) == "number" and type(spec.Max) == "number", "Slider needs numeric Min and Max")
	local entry, option = self:_value("Slider", id, spec)
	finalizeEntry(entry)
	return option
end

function Builder:Input(id: string, spec: any): any
	local entry, option, frame = self:_value("Input", id, spec)
	-- Fluent commits "Finished" inputs only on Enter; also commit when focus is lost (click-away).
	local box = frame and frame:FindFirstChildWhichIsA("TextBox", true)
	if box and (spec.Numeric or spec.Finished) then
		App.Maid:Connect(box.FocusLost, function(enterPressed: boolean)
			if not enterPressed and box.Text ~= tostring(option.Value) then
				option:SetValue(box.Text)
			end
		end)
	end
	finalizeEntry(entry)
	return option
end

function Builder:Colorpicker(id: string, spec: any): any
	local entry, option = self:_value("Colorpicker", id, spec)
	finalizeEntry(entry)
	return option
end

function Builder:Keybind(id: string, spec: any): any
	local entry, option, frame = self:_value("Keybind", id, spec)
	entry.PressCallback = spec.Callback
	entry.AfterChange = KeybindList.OnKeybindChanged
	if frame and spec.AllowModeChange ~= false then
		App.Maid:Connect((frame :: any).MouseButton2Click, function()
			KeybindList.CycleMode(entry)
		end)
	end
	finalizeEntry(entry)
	return option
end

-- Search box inside a dropdown's list (only while it has more than 10 options), plus batched
-- rebuilds and a live :Refresh(values) helper on the option object.
function UI.PatchDropdown(entry: any)
	local option = entry.Option
	local fluent = App.Fluent
	local canvas = fluent.OpenFrames[#fluent.OpenFrames] -- Fluent appends each dropdown list here
	local holder = canvas and canvas:FindFirstChildOfClass("Frame")
	local scroll = holder and holder:FindFirstChildOfClass("ScrollingFrame")
	local layout = scroll and scroll:FindFirstChildOfClass("UIListLayout")
	local search = { Query = "", Frame = nil :: Frame?, Box = nil :: TextBox? }

	local function applyFilter()
		if not scroll then
			return
		end
		local query = search.Query
		for _, child in ipairs(scroll:GetChildren()) do
			if child:IsA("TextButton") then
				local label = child:FindFirstChild("ButtonLabel")
				local visible = query == ""
					or (label ~= nil and string_find(string_lower(label.Text), query, 1, true) ~= nil)
				if child.Visible ~= visible then
					child.Visible = visible
				end
			end
		end
	end

	local function ensureSearchBox()
		if not (holder and scroll) then
			return
		end
		local needed = #option.Values > 10
		if needed and not search.Frame then
			local stroke = Util.Create("UIStroke", { Transparency = 0.8, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
			local icon = Util.Create("ImageLabel", {
				BackgroundTransparency = 1,
				Image = fluent:GetIcon("search") or "",
				ImageTransparency = 0.35,
				Size = UDim2_fromOffset(13, 13),
				AnchorPoint = Vector2.new(0, 0.5),
				Position = UDim2_new(0, 8, 0.5, 0),
			})
			local box = Util.Create("TextBox", {
				BackgroundTransparency = 1,
				ClearTextOnFocus = false,
				Text = "",
				PlaceholderText = "Search options…",
				FontFace = FONT_REGULAR,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Left,
				Position = UDim2_fromOffset(27, 0),
				Size = UDim2_new(1, -32, 1, 0),
			})
			local frame = Util.Create("Frame", {
				Name = "OptionSearch",
				BackgroundTransparency = 0.92,
				Position = UDim2_fromOffset(6, 6),
				Size = UDim2_new(1, -12, 0, 28),
				Parent = holder,
			}, { Util.Corner(5), stroke, icon, box })
			search.Frame, search.Box = frame, box
			Win.Paint(function(palette)
				frame.BackgroundColor3 = palette.Text
				stroke.Color = palette.Text
				icon.ImageColor3 = palette.Text
				box.TextColor3 = palette.Text
				box.PlaceholderColor3 = palette.Text:Lerp(palette.Panel, 0.5)
			end)
			App.Maid:Connect(box:GetPropertyChangedSignal("Text"), function()
				search.Query = string_lower(Util.Trim(box.Text))
				applyFilter()
			end)
			if layout then
				-- Fluent only sizes the canvas on rebuild; filtering changes the content height too.
				App.Maid:Connect(layout:GetPropertyChangedSignal("AbsoluteContentSize"), function()
					scroll.CanvasSize = UDim2_fromOffset(0, layout.AbsoluteContentSize.Y)
				end)
			end
		end
		if search.Frame then
			search.Frame.Visible = needed
			scroll.Position = needed and UDim2_fromOffset(5, 40) or UDim2_fromOffset(5, 5)
			scroll.Size = needed and UDim2_new(1, -5, 1, -45) or UDim2_new(1, -5, 1, -10)
			if not needed and search.Box and search.Box.Text ~= "" then
				search.Box.Text = ""
			end
		end
	end

	local build = option.BuildDropdownList
	option.BuildDropdownList = function(self)
		Internals.Batch(function()
			build(self)
		end)
		applyFilter()
		Internals.SchedulePrune()
	end
	local close = option.Close
	option.Close = function(self)
		close(self)
		if search.Box and search.Box.Text ~= "" then
			search.Box.Text = ""
		end
	end
	option.Refresh = function(_, values: { any })
		UI.RefreshDropdown(entry, values)
	end
	entry.EnsureSearch = ensureSearchBox
	ensureSearchBox()
end

-- Replaces a dropdown's options live, keeping every selection that is still valid.
function UI.RefreshDropdown(entry: any, values: { any }?)
	local option = entry.Option
	local list = {}
	for _, value in ipairs(values or {}) do
		list[#list + 1] = tostring(value)
	end
	option:SetValues(list)
	if entry.Spec.Multi then
		local kept = normalizeMulti(entry, entry.Last or {})
		if not Util.DeepEqual(kept, entry.Last) then
			entry.Codec.Apply(entry, kept)
		end
	elseif entry.Last and not table_find(list, entry.Last) then
		option:SetValue(nil)
	end
	if entry.EnsureSearch then
		entry.EnsureSearch()
	end
end

function Builder:Dropdown(id: string, spec: any): any
	spec.Values = spec.Values or {}
	local entry, option = self:_value("Dropdown", id, spec)
	UI.PatchDropdown(entry)
	local initial = entry.Initial
	local empty = if spec.Multi then #initial == 0 else not initial
	if not empty then
		entry.Codec.Apply(entry, initial) -- fires the creation callback with the loaded selection
	end
	finalizeEntry(entry)
	return option
end

-- Paragraph: with an id its title/content are saved per profile; returns a small proxy with
-- :Set(title, content), :SetTitle(text), :SetDesc(text) / :SetContent(text).
function Builder:Paragraph(id: any, spec: any?): any
	if type(id) == "table" then
		spec, id = id, nil
	end
	local config = spec or {}
	local entry = if id then Config.Register("Paragraph", id, config) else nil
	local title = entry and entry.Initial.Title or tostring(config.Title or "")
	local content = entry and entry.Initial.Content or tostring(config.Content or "")
	local element = self.Fluent:AddParagraph({ Title = title, Content = content })
	local proxy = { Title = title, Content = content, Element = element, Frame = element.Frame }
	function proxy:Set(newTitle: string?, newContent: string?)
		if newTitle ~= nil and tostring(newTitle) ~= proxy.Title then
			proxy.Title = tostring(newTitle)
			element:SetTitle(proxy.Title)
		end
		if newContent ~= nil and tostring(newContent) ~= proxy.Content then
			proxy.Content = tostring(newContent)
			element:SetDesc(proxy.Content)
		end
		if entry then
			Config.OnChanged(entry)
		end
	end
	function proxy:SetTitle(text: string)
		proxy:Set(text, nil)
	end
	function proxy:SetDesc(text: string)
		proxy:Set(nil, text)
	end
	proxy.SetContent = proxy.SetDesc
	if entry then
		entry.Option = proxy
		entry.Frame = element.Frame
		finalizeEntry(entry)
	end
	self:_decorate(element.Frame, config)
	return proxy
end

function Builder:Button(spec: any): any
	local title = tostring(spec.Title or "Button")
	local callback = spec.Callback
	local button = self.Fluent:AddButton({
		Title = title,
		Description = spec.Description,
		Callback = function()
			SafeCall(title, callback)
		end,
	})
	self:_decorate(button and button.Frame, spec)
	return button
end

-- Info tab --------------------------------------------------------------------------
local function BuildInfoTab()
	local fluent = App.Fluent
	local tab = UI.Tab("Info", "info", 100000)
	local executor = "Unknown"
	if Env.identifyexecutor then
		local ok, name, version = pcall(Env.identifyexecutor)
		if ok and name then
			executor = version and string_format("%s %s", tostring(name), tostring(version)) or tostring(name)
		end
	end

	local about = tab:Section("About")
	about:Paragraph({
		Title = string_format("%s  v%s", tostring(SETTINGS.Title), tostring(SETTINGS.Version)),
		Content = string_format(
			"ModedUI v%s · Fluent v%s · config format v%d\nConfig file: %s",
			LIBRARY_VERSION,
			tostring(fluent.Version),
			CONFIG_VERSION,
			Env.CanWrite and Config.FilePath or "memory only (no file access)"
		),
		Tooltip = "Script and library versions.",
	})
	local changelog = type(SETTINGS.Changelog) == "table" and SETTINGS.Changelog or { tostring(SETTINGS.Changelog) }
	about:Paragraph({
		Title = "Changelog",
		Content = table_concat(changelog, "\n"),
		Tooltip = "Pass Changelog = { ... } to CreateWindow.",
	})

	local server = tab:Section("Game")
	local gameInfo = server:Paragraph({
		Title = "Game",
		Content = string_format("Loading name…\nPlaceId: %d", game.PlaceId),
		Tooltip = "Name comes from MarketplaceService.",
	})
	local jobId = game.JobId ~= "" and game.JobId or "(none – Studio or local test)"
	local serverInfo = server:Paragraph({
		Title = "Server",
		Content = string_format("JobId: %s\nPlayers: %d/%d", jobId, #Players:GetPlayers(), Players.MaxPlayers),
		Tooltip = "JobId identifies this server instance.",
	})
	server:Button({
		Title = "Copy JobId",
		Description = "Copies this server's JobId to the clipboard.",
		Tooltip = "Falls back to showing the JobId if the clipboard is unavailable.",
		Callback = App.CopyJobId,
	})
	task_spawn(function()
		local ok, info = pcall(MarketplaceService.GetProductInfo, MarketplaceService, game.PlaceId)
		if App.Unloaded then
			return
		end
		local name = ok and type(info) == "table" and info.Name or "Unknown game"
		gameInfo:SetDesc(string_format("%s\nPlaceId: %d", tostring(name), game.PlaceId))
	end)

	local session = tab:Section("Session")
	local uptime = session:Paragraph({
		Title = "Session",
		Content = "…",
		Tooltip = "Updated once per second while this tab is open.",
	})
	local function update()
		if not Win.Open then
			return
		end
		uptime:SetDesc(string_format(
			"Script uptime: %s\nTime in server: %s\nExecutor: %s",
			Util.FormatDuration(os_clock() - App.StartedAt),
			Util.FormatDuration(time()),
			executor
		))
		serverInfo:SetDesc(string_format("JobId: %s\nPlayers: %d/%d", jobId, #Players:GetPlayers(), Players.MaxPlayers))
	end
	local container = tab.Fluent.ContainerFrame
	App.Maid:Connect(container:GetPropertyChangedSignal("Visible"), function()
		if container.Visible then
			Clock.Subscribe("InfoTab", update)
		else
			Clock.Unsubscribe("InfoTab")
		end
	end)
end

--══════════════════════════════════════════════════════════════════════════════
-- 8. OVERLAYS
--══════════════════════════════════════════════════════════════════════════════
-- One extra ScreenGui (sibling of Fluent's) holds the tooltip, watermark, keybind list and the
-- mobile toggle button. Nothing here runs per frame: the watermark and info readouts share a
-- 1 Hz clock that only exists while something is subscribed, and drags only listen while active.

-- Clock (1 Hz, self-stopping) -----------------------------------------------------
Clock.Subscribers = {} :: { [string]: () -> () }
Clock.Thread = nil :: thread?

local function clockTick()
	Clock.Thread = nil
	if App.Unloaded or next(Clock.Subscribers) == nil then
		return
	end
	for key, callback in pairs(Clock.Subscribers) do
		SafeCall(key, callback)
	end
	if next(Clock.Subscribers) ~= nil then
		Clock.Thread = task_delay(1, clockTick)
	end
end

function Clock.Subscribe(key: string, callback: () -> ())
	Clock.Subscribers[key] = callback
	SafeCall(key, callback)
	if not Clock.Thread then
		Clock.Thread = task_delay(1, clockTick)
	end
end

function Clock.Unsubscribe(key: string)
	Clock.Subscribers[key] = nil
end

-- Performance readouts (engine stats, no per-frame Lua) --------------------------------
Perf.Resolved = false
Perf.FpsItem = nil :: any
Perf.PingItem = nil :: any

function Perf.Resolve()
	if Perf.Resolved then
		return
	end
	Perf.Resolved = true
	pcall(function()
		Perf.FpsItem = (Stats :: any).FrameRateManager.AverageFPS
	end)
	pcall(function()
		Perf.PingItem = (Stats :: any).Network.ServerStatsItem["Data Ping"]
	end)
end

function Perf.FPS(): number
	Perf.Resolve()
	local item = Perf.FpsItem
	if item then
		local ok, value = pcall(item.GetValue, item)
		if ok and Util.IsFiniteNumber(value) and value > 0 then
			return value
		end
	end
	local ok, frameTime = pcall(function()
		return (Stats :: any).FrameTime
	end)
	if ok and type(frameTime) == "number" and frameTime > 0 then
		return 1 / frameTime
	end
	return Workspace:GetRealPhysicsFPS()
end

function Perf.Ping(): number
	Perf.Resolve()
	local item = Perf.PingItem
	if item then
		local ok, value = pcall(item.GetValue, item)
		if ok and Util.IsFiniteNumber(value) then
			return value
		end
	end
	local ok, seconds = pcall(LocalPlayer.GetNetworkPing, LocalPlayer)
	if ok and type(seconds) == "number" then
		return seconds * 1000
	end
	return 0
end

function Perf.Memory(): number
	local ok, megabytes = pcall(Stats.GetTotalMemoryUsageMb, Stats)
	return ok and megabytes or 0
end

local function escapeRichText(text: string): string
	return (string_gsub(text, "[<>&]", { ["<"] = "&lt;", [">"] = "&gt;", ["&"] = "&amp;" }))
end

-- Tooltip ---------------------------------------------------------------------------
Tooltip.Enabled = true
Tooltip.Frame = nil :: Frame?
Tooltip.Label = nil :: TextLabel?
Tooltip.Token = 0

function Tooltip.Create(parent: Instance)
	local stroke = Util.Create("UIStroke", { Transparency = 0.75 })
	local label = Util.Create("TextLabel", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2_fromOffset(0, 0),
		FontFace = FONT_REGULAR,
		TextSize = 12,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Text = "",
	}, { Util.Create("UISizeConstraint", { MaxSize = Vector2.new(260, math.huge) }) })
	local frame = Util.Create("Frame", {
		Name = "Tooltip",
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2_fromOffset(0, 0),
		BackgroundTransparency = 0.04,
		Visible = false,
		ZIndex = 20,
		Parent = parent,
	}, {
		Util.Corner(6),
		stroke,
		Util.Create("UIPadding", {
			PaddingLeft = UDim_new(0, 9),
			PaddingRight = UDim_new(0, 9),
			PaddingTop = UDim_new(0, 6),
			PaddingBottom = UDim_new(0, 6),
		}),
		label,
	})
	Tooltip.Frame, Tooltip.Label = frame, label
	Win.Paint(function(palette)
		frame.BackgroundColor3 = palette.Panel
		stroke.Color = palette.Text
		label.TextColor3 = palette.Text
	end)
end

function Tooltip.Move()
	local frame = Tooltip.Frame
	local gui = Overlays.Gui
	if not frame or not gui then
		return
	end
	local mouse = UserInputService:GetMouseLocation()
	local screen, size = gui.AbsoluteSize, frame.AbsoluteSize
	local x = math_min(mouse.X + 14, screen.X - size.X - 6)
	local y = mouse.Y + 18
	if y + size.Y > screen.Y - 6 then
		y = mouse.Y - size.Y - 10
	end
	frame.Position = UDim2_fromOffset(math_max(6, x), math_max(6, y))
end

function Tooltip.Show(text: string)
	if not Tooltip.Enabled or not Tooltip.Frame then
		return
	end
	Tooltip.Token += 1
	local token = Tooltip.Token
	App.Maid:Set("TooltipDelay", task_delay(0.35, function()
		if token ~= Tooltip.Token or App.Unloaded or not Win.Open then
			return
		end
		Tooltip.Label.Text = text
		Tooltip.Frame.Visible = true
		Tooltip.Move()
	end))
end

function Tooltip.Hide()
	Tooltip.Token += 1
	if App.Maid then
		App.Maid:Set("TooltipDelay", nil)
	end
	if Tooltip.Frame then
		Tooltip.Frame.Visible = false
	end
end

function Tooltip.Attach(target: GuiObject?, text: string?)
	if not target or type(text) ~= "string" or text == "" or IsTouch then
		return
	end
	App.Maid:Connect(target.MouseEnter, function()
		Tooltip.Show(text)
	end)
	App.Maid:Connect(target.MouseLeave, Tooltip.Hide)
	App.Maid:Connect(target.MouseMoved, function()
		if Tooltip.Frame and Tooltip.Frame.Visible then
			Tooltip.Move()
		end
	end)
end

-- Watermark -------------------------------------------------------------------------
Watermark.Enabled = false
Watermark.Frame = nil :: Frame?
Watermark.Label = nil :: TextLabel?
Watermark.AccentHex = "60cdff"
local WATERMARK_FORMAT = '<font color="#%s"><b>%s</b></font>  <font transparency="0.5">|</font>  %s'
	.. '  <font transparency="0.5">|</font>  %d fps  <font transparency="0.5">|</font>  %d ms'
	.. '  <font transparency="0.5">|</font>  %s'

function Watermark.Create(parent: Instance)
	local inset = GuiService:GetGuiInset()
	local stroke = Util.Create("UIStroke", { Transparency = 0.8 })
	local label = Util.Create("TextLabel", {
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2_fromOffset(0, 0),
		FontFace = FONT_MEDIUM,
		TextSize = 13,
		RichText = true,
		Text = "",
	})
	local frame = Util.Create("Frame", {
		Name = "Watermark",
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2_new(1, -12, 0, inset.Y + 10),
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2_fromOffset(0, 0),
		BackgroundTransparency = 0.12,
		Active = true,
		Visible = false,
		Parent = parent,
	}, {
		Util.Corner(6),
		stroke,
		Util.Create("UIPadding", {
			PaddingLeft = UDim_new(0, 10),
			PaddingRight = UDim_new(0, 10),
			PaddingTop = UDim_new(0, 6),
			PaddingBottom = UDim_new(0, 6),
		}),
		label,
	})
	Watermark.Frame, Watermark.Label = frame, label
	Win.Paint(function(palette)
		frame.BackgroundColor3 = palette.Panel
		stroke.Color = palette.Text
		label.TextColor3 = palette.Text
		Watermark.AccentHex = palette.Accent:ToHex()
		if Watermark.Enabled then
			Watermark.Update()
		end
	end)
	Util.MakeDraggable(frame, frame, App.Maid, {
		OnDragEnd = function()
			Config.MarkDirty()
		end,
	})
end

function Watermark.Update()
	local label = Watermark.Label
	if not label then
		return
	end
	label.Text = string_format(
		WATERMARK_FORMAT,
		Watermark.AccentHex,
		escapeRichText(SETTINGS.Title),
		LocalPlayer.Name,
		math_floor(Perf.FPS() + 0.5),
		math_floor(Perf.Ping() + 0.5),
		os_date("%H:%M:%S")
	)
end

function Watermark.SetEnabled(enabled: boolean)
	Watermark.Enabled = enabled
	if Watermark.Frame then
		Watermark.Frame.Visible = enabled
	end
	if enabled then
		Clock.Subscribe("Watermark", Watermark.Update)
	else
		Clock.Unsubscribe("Watermark")
	end
end

-- Keybind list ----------------------------------------------------------------------
KeybindList.Enabled = false
KeybindList.Frame = nil :: Frame?
KeybindList.Body = nil :: Frame?
KeybindList.Empty = nil :: TextLabel?
KeybindList.Rows = {} :: { any }
KeybindList.HoldMap = {} :: { [string]: { Entry } }
local MODE_ORDER = { Toggle = "Hold", Hold = "Always", Always = "Toggle" }
local MODE_SUFFIX = { Toggle = "", Hold = " hold", Always = " always" }

function KeybindList.Create(parent: Instance)
	local inset = GuiService:GetGuiInset()
	local stroke = Util.Create("UIStroke", { Transparency = 0.8 })
	local icon = Util.Create("ImageLabel", {
		BackgroundTransparency = 1,
		Image = App.Fluent:GetIcon("keyboard") or "",
		Size = UDim2_fromOffset(14, 14),
		Position = UDim2_fromOffset(0, 1),
	})
	local title = Util.Create("TextLabel", {
		BackgroundTransparency = 1,
		Text = "Keybinds",
		FontFace = FONT_BOLD,
		TextSize = 13,
		TextXAlignment = Enum.TextXAlignment.Left,
		Position = UDim2_fromOffset(20, 0),
		Size = UDim2_new(1, -20, 1, 0),
	})
	local header = Util.Create("Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2_new(1, 0, 0, 16),
		LayoutOrder = 0,
		Active = true,
	}, { icon, title })
	local empty = Util.Create("TextLabel", {
		BackgroundTransparency = 1,
		Text = "No keybinds bound",
		FontFace = FONT_REGULAR,
		TextSize = 12,
		TextTransparency = 0.5,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2_new(1, 0, 0, 18),
		LayoutOrder = 1,
		Visible = false,
	})
	local body = Util.Create("Frame", {
		Name = "Rows",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2_new(1, 0, 0, 0),
		LayoutOrder = 2,
	}, { Util.Create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim_new(0, 2) }) })
	local frame = Util.Create("Frame", {
		Name = "KeybindList",
		Position = UDim2_new(0, 14, 0, inset.Y + 10),
		Size = UDim2_fromOffset(220, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 0.12,
		Active = true,
		Visible = false,
		Parent = parent,
	}, {
		Util.Corner(6),
		stroke,
		Util.Create("UIPadding", {
			PaddingLeft = UDim_new(0, 10),
			PaddingRight = UDim_new(0, 10),
			PaddingTop = UDim_new(0, 8),
			PaddingBottom = UDim_new(0, 8),
		}),
		Util.Create("UIListLayout", { SortOrder = Enum.SortOrder.LayoutOrder, Padding = UDim_new(0, 6) }),
		header,
		empty,
		body,
	})
	KeybindList.Frame, KeybindList.Body, KeybindList.Empty = frame, body, empty
	Win.Paint(function(palette)
		frame.BackgroundColor3 = palette.Panel
		stroke.Color = palette.Text
		icon.ImageColor3 = palette.Accent
		title.TextColor3 = palette.Text
		empty.TextColor3 = palette.Text
		if KeybindList.Enabled then
			KeybindList.Refresh()
		end
	end)
	Util.MakeDraggable(header, frame, App.Maid, {
		OnDragEnd = function()
			Config.MarkDirty()
		end,
	})
end

-- Rows are pooled: created on demand, then only their text/colour/visibility change.
function KeybindList.Row(index: number): any
	local row = KeybindList.Rows[index]
	if row then
		return row
	end
	local nameLabel = Util.Create("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT_REGULAR,
		TextSize = 12,
		RichText = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2_new(1, -44, 1, 0),
	})
	local stateLabel = Util.Create("TextLabel", {
		BackgroundTransparency = 1,
		FontFace = FONT_BOLD,
		TextSize = 11,
		TextXAlignment = Enum.TextXAlignment.Right,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2_fromScale(1, 0),
		Size = UDim2_new(0, 36, 1, 0),
	})
	local frame = Util.Create("Frame", {
		BackgroundTransparency = 1,
		Size = UDim2_new(1, 0, 0, 18),
		LayoutOrder = index,
		Parent = KeybindList.Body,
	}, { nameLabel, stateLabel })
	row = { Frame = frame, Name = nameLabel, State = stateLabel }
	KeybindList.Rows[index] = row
	if FontSize.Multiplier ~= 1 then
		FontSize.ApplyTo(nameLabel)
		FontSize.ApplyTo(stateLabel)
	end
	return row
end

local function keybindActive(entry: Entry): boolean
	local option = entry.Option
	if entry.Id == "UI_MenuKeybind" then
		return Win.Open
	end
	if option.Mode == "Always" then
		return true
	elseif option.Mode == "Hold" then
		local ok, held = pcall(option.GetState, option)
		return ok and held == true
	end
	return option.Toggled == true
end

function KeybindList.Refresh()
	if not KeybindList.Enabled or not KeybindList.Frame then
		return
	end
	local count = 0
	for _, entry in ipairs(Config.Order) do
		local option = entry.Option
		if entry.Type == "Keybind" and option then
			local key = tostring(option.Value)
			if key ~= "None" and key ~= "" then
				count += 1
				local active = keybindActive(entry)
				local row = KeybindList.Row(count)
				row.Name.Text = string_format(
					'%s  <font transparency="0.45">[%s]%s</font>',
					escapeRichText(entry.Title),
					key,
					MODE_SUFFIX[option.Mode] or ""
				)
				row.Name.TextColor3 = Palette.Text
				row.State.Text = active and "ON" or "OFF"
				row.State.TextColor3 = active and Palette.Accent or Palette.Text
				row.State.TextTransparency = active and 0 or 0.55
				row.Frame.Visible = true
			end
		end
	end
	local rows = KeybindList.Rows
	for index = count + 1, #rows do
		rows[index].Frame.Visible = false
	end
	if KeybindList.Empty then
		KeybindList.Empty.Visible = count == 0
	end
	KeybindList.FitWidth()
end

-- Grows/shrinks the panel to the widest row so key names are never cut off.
function KeybindList.FitWidth()
	local frame = KeybindList.Frame
	if not frame then
		return
	end
	local widest = 110
	for _, row in ipairs(KeybindList.Rows) do
		if row.Frame.Visible then
			widest = math_max(widest, row.Name.TextBounds.X)
		end
	end
	local width = math_clamp(math.ceil(widest) + 20 + 48, 180, 420) -- padding + ON/OFF column
	if frame.Size.X.Offset ~= width then
		frame.Size = UDim2_fromOffset(width, 0)
	end
end

function KeybindList.RebuildHoldMap()
	local map = KeybindList.HoldMap
	table_clear(map)
	for _, entry in ipairs(Config.Order) do
		local option = entry.Option
		if entry.Type == "Keybind" and option and option.Mode == "Hold" then
			local key = tostring(option.Value)
			local list = map[key]
			if not list then
				list = {}
				map[key] = list
			end
			list[#list + 1] = entry
		end
	end
end

function KeybindList.SetEnabled(enabled: boolean)
	KeybindList.Enabled = enabled
	if KeybindList.Frame then
		KeybindList.Frame.Visible = enabled
	end
	KeybindList.Refresh()
end

function KeybindList.OnPressed(entry: any, toggled: boolean)
	if entry.PressCallback then
		SafeCall(entry.Title, entry.PressCallback, toggled)
	end
	KeybindList.Refresh()
end

function KeybindList.OnKeybindChanged()
	KeybindList.RebuildHoldMap()
	KeybindList.Refresh()
end

function KeybindList.CycleMode(entry: any)
	local option = entry.Option
	local nextMode = MODE_ORDER[option.Mode] or "Toggle"
	option:SetValue(option.Value, nextMode)
	if nextMode ~= "Toggle" then
		option.Toggled = false
	end
	Config.OnChanged(entry)
	Notify(entry.Title, "Keybind mode: " .. nextMode, 2, "Info")
end

-- Mobile toggle button ---------------------------------------------------------------
MobileButton.Enabled = false
MobileButton.Frame = nil :: GuiObject?
MobileButton.Icon = nil :: ImageLabel?

function MobileButton.Create(parent: Instance)
	local stroke = Util.Create("UIStroke", { Thickness = 1.5, Transparency = 0.25 })
	local icon = Util.Create("ImageLabel", {
		BackgroundTransparency = 1,
		Image = App.Fluent:GetIcon("layout-dashboard") or "",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2_fromScale(0.5, 0.5),
		Size = UDim2_fromOffset(22, 22),
	})
	local button = Util.Create("TextButton", {
		Name = "MobileToggle",
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 0.08,
		Size = UDim2_fromOffset(48, 48),
		Position = UDim2_new(0, 14, 0.5, -24),
		Visible = false,
		Parent = parent,
	}, { Util.Corner(24), stroke, icon })
	MobileButton.Frame, MobileButton.Icon = button, icon
	Win.Paint(function(palette)
		button.BackgroundColor3 = palette.Panel
		stroke.Color = palette.Accent
		icon.ImageColor3 = palette.Text
	end)
	Util.MakeDraggable(button, button, App.Maid, {
		Threshold = 8,
		OnTap = function()
			Win.Toggle()
		end,
		OnDragEnd = function()
			Config.MarkDirty()
		end,
	})
end

function MobileButton.SetEnabled(enabled: boolean)
	MobileButton.Enabled = enabled
	if MobileButton.Frame then
		MobileButton.Frame.Visible = enabled
	end
end

-- Overlay GUI + shared input handling ----------------------------------------------------
Overlays.Gui = nil :: ScreenGui?
Overlays.FrameMap = {} :: { [string]: GuiObject }

local function inputKeyName(input: InputObject): string?
	local inputType = input.UserInputType
	if inputType == Enum.UserInputType.Keyboard then
		return input.KeyCode.Name
	elseif inputType == Enum.UserInputType.MouseButton1 then
		return "MouseLeft"
	elseif inputType == Enum.UserInputType.MouseButton2 then
		return "MouseRight"
	end
	return nil
end

function Overlays.Create()
	local fluentGui = App.Fluent.GUI
	local gui = Util.Create("ScreenGui", {
		Name = HttpService:GenerateGUID(false),
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = fluentGui.DisplayOrder + 5,
	})
	if Env.protectgui then
		pcall(Env.protectgui, gui)
	end
	gui.Parent = fluentGui.Parent
	App.Maid:Give(gui)
	Overlays.Gui = gui

	Tooltip.Create(gui)
	Watermark.Create(gui)
	KeybindList.Create(gui)
	MobileButton.Create(gui)
	Overlays.FrameMap = {
		Watermark = Watermark.Frame,
		Keybinds = KeybindList.Frame,
		MobileButton = MobileButton.Frame,
	}

	-- One InputBegan/InputEnded pair serves Hold keybinds, Ctrl+F and the keybind overlay.
	App.Maid:Connect(UserInputService.InputBegan, function(input: InputObject)
		local key = inputKeyName(input)
		if not key or UserInputService:GetFocusedTextBox() then
			return
		end
		if
			key == "F"
			and Win.Open
			and Win.SearchBox
			and (
				UserInputService:IsKeyDown(Enum.KeyCode.LeftControl)
				or UserInputService:IsKeyDown(Enum.KeyCode.RightControl)
			)
		then
			task_defer(function()
				if Win.SearchBox then
					Win.SearchBox:CaptureFocus()
				end
			end)
			return
		end
		local holds = KeybindList.HoldMap[key]
		if holds then
			for _, entry in ipairs(holds) do
				SafeCall(entry.Title, (entry :: any).PressCallback, true)
			end
			KeybindList.Refresh()
		end
	end)
	App.Maid:Connect(UserInputService.InputEnded, function(input: InputObject)
		local key = inputKeyName(input)
		local holds = key and KeybindList.HoldMap[key]
		if holds then
			for _, entry in ipairs(holds) do
				SafeCall(entry.Title, (entry :: any).PressCallback, false)
			end
			KeybindList.Refresh()
		end
	end)
end

function Overlays.OnWindowToggled(open: boolean)
	Tooltip.Hide()
	KeybindList.Refresh()
	if MobileButton.Icon then
		MobileButton.Icon.ImageTransparency = open and 0 or 0.3
	end
end

function Overlays.GetPositions(existing: any): { [string]: any }
	local result = type(existing) == "table" and existing or {}
	for name, frame in pairs(Overlays.FrameMap) do
		result[name] = Util.EncodeUDim2(frame.Position)
	end
	return result
end

function Overlays.ApplyPositions(saved: any)
	if type(saved) ~= "table" then
		return
	end
	for name, frame in pairs(Overlays.FrameMap) do
		local position = Util.DecodeUDim2(saved[name])
		if position then
			frame.Position = position
			Util.ClampToScreen(frame)
		end
	end
end

--══════════════════════════════════════════════════════════════════════════════
-- 9. SETTINGS
--══════════════════════════════════════════════════════════════════════════════
local function BuildSettingsTab()
	local fluent = App.Fluent
	local options = fluent.Options
	local tab = UI.Tab("Settings", "settings", 100001)

	-- Interface -----------------------------------------------------------------
	local interface = tab:Section("Interface")
	interface:Dropdown("UI_Theme", {
		Title = "Theme",
		Description = "Every built-in Fluent theme.",
		Tooltip = "Saved per profile.",
		Values = table_clone(fluent.Themes),
		Default = SETTINGS.Theme,
		Callback = function(theme: string?)
			if theme then
				fluent:SetTheme(theme)
				Accent.Apply() -- re-applies a custom accent (if any) and repaints our own widgets
			end
		end,
	})
	interface:Toggle("UI_CustomAccent", {
		Title = "Custom accent colour",
		Description = "Replace the theme accent with the colour below.",
		Tooltip = "Recolours the whole UI live.",
		Default = false,
		Callback = function(enabled: boolean)
			Accent.Set(enabled, nil)
		end,
	})
	interface:Colorpicker("UI_AccentColor", {
		Title = "Accent colour",
		Description = "Used while the custom accent is on.",
		Tooltip = "Pick a colour, then press Done.",
		Default = THEME_ACCENTS.Dark,
		Callback = function(color: Color3)
			Accent.Set(nil, color)
		end,
	})
	interface:Slider("UI_Scale", {
		Title = "UI scale",
		Description = "Window scale from 0.75 to 1.25.",
		Tooltip = "The window never grows past the screen; small screens shrink it automatically.",
		Min = 0.75,
		Max = 1.25,
		Default = 1,
		Rounding = 2,
		Callback = function(scale: number)
			Win.SetUserScale(scale)
		end,
	})
	interface:Dropdown("UI_FontSize", {
		Title = "Font size",
		Description = "Text size across the whole UI.",
		Tooltip = "Small / Normal / Large.",
		Values = { "Small", "Normal", "Large" },
		Default = "Normal",
		Callback = function(size: string?)
			FontSize.Set(size or "Normal")
		end,
	})
	interface:Toggle("UI_AcrylicBlur", {
		Title = "Acrylic blur",
		Description = "Blurs the game behind the window. Off = better FPS.",
		Tooltip = "Turning it on needs a quick UI reload. Turning it off stops the blur now and frees it on the next reload.",
		Default = false,
		Callback = function(enabled: boolean)
			if fluent.UseAcrylic then
				fluent:ToggleAcrylic(enabled)
			elseif enabled and App.Ready and Config.Applying > 0 then
				-- Loaded from a profile/import: don't interrupt with a dialog.
				Notify("Acrylic blur", "This profile uses blur. Use Settings → Reload UI to apply it.", 6, "Info")
			elseif enabled and App.Ready then
				Confirm(
					"Enable acrylic blur?",
					"The blur needs a quick UI reload (your settings are saved first). Reload now?",
					function()
						Config.SaveNow()
						App.Reload()
					end,
					"Reload"
				)
			end
		end,
	})
	local lastMenuKey = SETTINGS.MenuKey
	interface:Keybind("UI_MenuKeybind", {
		Title = "Menu keybind",
		Description = "Shows / hides the window.",
		Tooltip = "Click the key box, then press a keyboard key.",
		Default = SETTINGS.MenuKey,
		Mode = "Toggle",
		AllowModeChange = false,
		ChangedCallback = function(key: string)
			if key == "MouseLeft" or key == "MouseRight" or key == "None" then
				Notify("Menu keybind", "Pick a keyboard key; mouse buttons can't toggle the menu.", 4, "Warning")
				local entry = Config.Registry.UI_MenuKeybind
				task_defer(function()
					entry.Option:SetValue(lastMenuKey, "Toggle")
					Config.OnChanged(entry)
				end)
				return
			end
			lastMenuKey = key
		end,
	})
	fluent.MinimizeKeybind = options.UI_MenuKeybind
	interface:Toggle("UI_Watermark", {
		Title = "Watermark",
		Description = "Script, player, FPS, ping and time (draggable).",
		Tooltip = "Refreshes once per second; nothing runs per frame.",
		Default = SETTINGS.ShowWatermark ~= false,
		Callback = Watermark.SetEnabled,
	})
	interface:Toggle("UI_KeybindList", {
		Title = "Keybind list",
		Description = "Overlay with every bound key and whether it is on.",
		Tooltip = "Drag it by its header.",
		Default = SETTINGS.ShowKeybindList ~= false,
		Callback = KeybindList.SetEnabled,
	})
	interface:Toggle("UI_MobileButton", {
		Title = "Floating toggle button",
		Description = IsTouch and "Touch device detected, so it is on by default." or "Handy on touch screens.",
		Tooltip = "Tap to open/close the window, drag to move it.",
		Default = IsTouch,
		Callback = MobileButton.SetEnabled,
	})
	interface:Toggle("UI_Tooltips", {
		Title = "Tooltips",
		Description = "Hover hints like this one (desktop).",
		Tooltip = "You found one.",
		Default = true,
		Callback = function(enabled: boolean)
			Tooltip.Enabled = enabled
			if not enabled then
				Tooltip.Hide()
			end
		end,
	})
	interface:Toggle("UI_MuteNotifications", {
		Title = "Mute notifications",
		Description = "Silences every toast (errors still reach the console).",
		Tooltip = "Saved per profile.",
		Default = false,
		Callback = function(muted: boolean)
			Notifier.Muted = muted
		end,
	})

	-- Background ------------------------------------------------------------------
	local background = tab:Section("Background")
	local status = background:Paragraph({
		Title = "Background image",
		Content = Background.Status,
		Tooltip = "Where the current image came from.",
	})
	Background.StatusChanged = function(text: string)
		status:SetDesc(text)
	end
	background:Toggle("UI_BackgroundEnabled", {
		Title = "Show background",
		Description = "Image behind the window content.",
		Tooltip = "Hiding it keeps the image cached.",
		Default = true,
		Callback = Background.SetEnabled,
	})
	background:Slider("UI_BackgroundTransparency", {
		Title = "Image transparency",
		Description = "0 = solid image, 1 = invisible.",
		Tooltip = "Raise it if text becomes hard to read.",
		Min = 0,
		Max = 1,
		Default = 0.4,
		Rounding = 2,
		Callback = Background.SetTransparency,
	})
	background:Slider("UI_BackgroundDim", {
		Title = "Image dim",
		Description = "Darkens the image so text stays readable.",
		Tooltip = "0 = original brightness. Bright images usually need 0.3 – 0.6.",
		Min = 0,
		Max = 0.9,
		Default = 0.3,
		Rounding = 2,
		Callback = Background.SetDim,
	})
	background:Input("UI_BackgroundUrl", {
		Title = "Image URL",
		Description = "Direct PNG/JPG link. Downloaded once, then loaded from the cache.",
		Tooltip = "Press Enter or click away to load it.",
		Placeholder = "https://…/image.png",
		Default = SETTINGS.BackgroundUrl,
		Finished = true,
		Callback = Background.Load,
	})
	background:Button({
		Title = "Reset background",
		Description = "Restores the default URL, transparency, dim and visibility.",
		Tooltip = "The default URL is the BackgroundUrl option of CreateWindow.",
		Callback = function()
			options.UI_BackgroundUrl:SetValue(SETTINGS.BackgroundUrl)
			options.UI_BackgroundTransparency:SetValue(0.4)
			options.UI_BackgroundDim:SetValue(0.3)
			options.UI_BackgroundEnabled:SetValue(true)
			Notify("Background", "Background settings reset.", 3, "Success")
		end,
	})

	-- Config -------------------------------------------------------------------------
	local config = tab:Section("Config")
	local info = config:Paragraph({
		Title = "Profile",
		Content = "…",
		Tooltip = "Profiles live in one JSON file per player.",
	})
	local function describeProfiles()
		local profile = Config.CurrentProfile()
		local saved = profile.SavedAt > 0 and os_date("%Y-%m-%d %H:%M:%S", profile.SavedAt) or "not yet"
		info:SetDesc(string_format(
			"Active: %s · %d profile(s) · auto-load %s\nAutosave: %s · last saved: %s\n%s",
			Config.Current,
			#Config.ProfileNames(),
			Config.Data.AutoLoad and "on" or "off",
			Config.AutoSaveEnabled() and string_format("on (%ss)", Util.FormatNumber(Config.Delay())) or "off",
			saved,
			Env.CanWrite and ("File: " .. Config.FilePath) or "Memory only: this executor has no file access"
		))
	end
	config:Dropdown("UI_ConfigProfile", {
		Title = "Active profile",
		Description = "Switching saves the current profile first (autosave on).",
		Tooltip = "Pick a profile to load it.",
		Values = Config.ProfileNames(),
		Default = Config.Current,
		Save = false,
		Callback = function(name: string?)
			if name and name ~= Config.Current and App.Ready then
				task_defer(Config.SwitchProfile, name)
			end
		end,
	})
	config:Input("UI_ProfileName", {
		Title = "Profile name",
		Description = "Used by Create, Duplicate and Rename.",
		Tooltip = "Letters, numbers, spaces, - _ . (max 32).",
		Placeholder = "e.g. PvP",
		Default = "",
		MaxLength = 32,
		Save = false,
	})
	config:Button({
		Title = "Create profile",
		Description = "New profile with default values.",
		Tooltip = "Uses the name typed above.",
		Callback = function()
			Config.CreateProfile(options.UI_ProfileName.Value, false)
		end,
	})
	config:Button({
		Title = "Duplicate profile",
		Description = "Copies the current profile under the new name.",
		Tooltip = "Uses the name typed above.",
		Callback = function()
			Config.CreateProfile(options.UI_ProfileName.Value, true)
		end,
	})
	config:Button({
		Title = "Rename profile",
		Description = "Renames the current profile.",
		Tooltip = "Uses the name typed above.",
		Callback = function()
			Config.RenameProfile(options.UI_ProfileName.Value)
		end,
	})
	config:Button({
		Title = "Delete profile",
		Description = "Deletes the current profile (asks first).",
		Tooltip = "Deleting the last profile recreates an empty Default.",
		Callback = function()
			Confirm(
				"Delete profile?",
				string_format('Delete "%s"? This cannot be undone.', Config.Current),
				Config.DeleteProfile,
				"Delete"
			)
		end,
	})
	config:Toggle("UI_AutoLoad", {
		Title = "Auto-load this profile",
		Description = "On start, load the last used profile (off = always start on Default).",
		Tooltip = "Stored in the file header, not inside a profile.",
		Default = Config.Data.AutoLoad,
		Save = false,
		Callback = function(enabled: boolean)
			Config.Data.AutoLoad = enabled
			Config.MarkDirty(true)
			describeProfiles()
		end,
	})
	config:Toggle("UI_AutoSave", {
		Title = "Autosave",
		Description = "Save automatically after every change (off = press Save now).",
		Tooltip = "Stored in the file header, shared by every profile.",
		Default = Config.AutoSaveEnabled(),
		Save = false,
		Callback = function(enabled: boolean)
			local changed = Config.Data.AutoSave ~= enabled
			Config.Data.AutoSave = enabled
			if changed and App.Ready then
				-- Turning it on catches up on changes made while it was off; turning it off
				-- flushes what was pending, so the switch itself never loses anything.
				Config.SaveNow()
			end
			describeProfiles()
		end,
	})
	config:Slider("UI_AutoSaveDelay", {
		Title = "Autosave delay",
		Description = "Seconds of no changes before the file is written.",
		Tooltip = "Higher = fewer writes while dragging sliders.",
		Min = 0.5,
		Max = 10,
		Default = Config.Delay(),
		Rounding = 1,
		Save = false,
		Callback = function(seconds: number)
			Config.Data.AutoSaveDelay = seconds
			Config.MarkDirty(true)
			describeProfiles()
		end,
	})
	config:Button({
		Title = "Save now",
		Description = "Writes immediately (use this when autosave is off).",
		Tooltip = "Skips the write when nothing changed.",
		Callback = function()
			if not Env.CanWrite then
				Notify("Config", "This executor has no file access; settings only live in memory.", 4, "Warning")
			elseif Config.SaveNow() then
				Notify("Config", string_format('Saved "%s".', Config.Current), 3, "Success")
			else
				Notify("Config", "Already up to date.", 3, "Info")
			end
		end,
	})
	config:Button({
		Title = "Load from file",
		Description = "Re-reads the file (e.g. after editing it by hand).",
		Tooltip = "Keeps your current settings if the file is invalid.",
		Callback = Config.LoadFromDisk,
	})
	config:Button({
		Title = "Reset to defaults",
		Description = "Resets every value in this profile (asks first).",
		Tooltip = "Other profiles are not touched.",
		Callback = function()
			Confirm(
				"Reset to defaults?",
				string_format('Reset every setting in "%s" to its default value?', Config.Current),
				Config.ResetProfile,
				"Reset"
			)
		end,
	})
	config:Button({
		Title = "Export to clipboard",
		Description = "Copies the current profile as JSON.",
		Tooltip = "Share it or keep it as a backup.",
		Callback = function()
			local json = Config.Export()
			if not json then
				return
			end
			if Util.SetClipboard(json) then
				Notify("Export", string_format("Copied %d characters to the clipboard.", #json), 4, "Success")
			else
				print(json)
				Notify("Export", "Clipboard unavailable: the JSON was printed to the console (F9).", 6, "Warning")
			end
		end,
	})
	config:Input("UI_ImportJson", {
		Title = "Import JSON",
		Description = "Paste an exported profile here, then press Import.",
		Tooltip = "Only values that match an existing element and pass validation are applied.",
		Placeholder = '{"Kind":"ModedUI.Profile", …}',
		Default = "",
		Save = false,
	})
	config:Button({
		Title = "Import",
		Description = "Validates the JSON and applies it to this profile (asks first).",
		Tooltip = "Unknown or invalid values are skipped and reported.",
		Callback = function()
			Config.Import(options.UI_ImportJson.Value)
		end,
	})
	Config.ProfilesChanged = function()
		local entry = Config.Registry.UI_ConfigProfile
		UI.RefreshDropdown(entry, Config.ProfileNames())
		if entry.Option.Value ~= Config.Current then
			entry.Option:SetValue(Config.Current)
		end
		local autoLoad = options.UI_AutoLoad
		if autoLoad and autoLoad.Value ~= Config.Data.AutoLoad then
			autoLoad:SetValue(Config.Data.AutoLoad)
		end
		local autoSave = options.UI_AutoSave
		if autoSave and autoSave.Value ~= Config.AutoSaveEnabled() then
			autoSave:SetValue(Config.AutoSaveEnabled())
		end
		local delay = options.UI_AutoSaveDelay
		if delay and tonumber(delay.Value) ~= Config.Delay() then
			delay:SetValue(Config.Delay())
		end
		describeProfiles()
	end
	Config.Saved = describeProfiles
	describeProfiles()

	-- Performance ------------------------------------------------------------------
	local performance = tab:Section("Performance")
	local stats = performance:Paragraph({
		Title = "Live stats",
		Content = "…",
		Tooltip = "Updated once per second while this tab is open.",
	})
	local fastPath = Internals.Creator and "on (batched theme passes, registry pruning)"
		or "off (debug.getupvalues unavailable)"
	local function updateStats()
		if not Win.Open then
			return
		end
		stats:SetDesc(string_format(
			"%d fps · %d ms ping · %d MB client memory\nFluent fast path: %s",
			math_floor(Perf.FPS() + 0.5),
			math_floor(Perf.Ping() + 0.5),
			math_floor(Perf.Memory() + 0.5),
			fastPath
		))
	end
	local container = tab.Fluent.ContainerFrame
	App.Maid:Connect(container:GetPropertyChangedSignal("Visible"), function()
		if container.Visible then
			Clock.Subscribe("SettingsTab", updateStats)
		else
			Clock.Unsubscribe("SettingsTab")
		end
	end)
	performance:Toggle("UI_Animations", {
		Title = "Animations",
		Description = "Open/close zoom animation.",
		Tooltip = "Off gives the lightest possible UI.",
		Default = true,
		Callback = function(enabled: boolean)
			App.AnimationsEnabled = enabled
		end,
	})
	performance:Button({
		Title = "Clear image cache",
		Description = "Deletes downloaded background images.",
		Tooltip = "The current image stays until you rejoin.",
		Callback = function()
			local removed = Background.ClearCache()
			if removed < 0 then
				Notify("Cache", "This executor can't list or delete files.", 4, "Warning")
			else
				Notify("Cache", string_format("Removed %d cached image(s).", removed), 3, "Success")
			end
		end,
	})
	performance:Button({
		Title = "Rejoin server",
		Description = "Rejoins this server, or a new one if you are alone (asks first).",
		Tooltip = "Settings are saved before teleporting (with autosave off, only Save now saves values).",
		Callback = App.Rejoin,
	})
	performance:Button({
		Title = "Copy JobId",
		Description = "Copies this server's JobId.",
		Tooltip = "Falls back to showing it in a toast.",
		Callback = App.CopyJobId,
	})
	performance:Button({
		Title = "Reload UI",
		Description = "Rebuilds the whole UI (with autosave off, unsaved changes are dropped).",
		Tooltip = "Re-runs your script; Fluent's source is cached, so nothing is re-downloaded.",
		Callback = function()
			Config.Persist()
			App.Reload()
		end,
	})
	performance:Button({
		Title = "Unload UI",
		Description = "Removes the UI and everything it created (asks first).",
		Tooltip = "Disconnects every connection, cancels threads and destroys all instances.",
		Callback = function()
			Confirm("Unload UI?", "Close the UI and clean up everything it created?", App.Unload, "Unload")
		end,
	})
end

--══════════════════════════════════════════════════════════════════════════════
-- 10. INIT (public API)
--══════════════════════════════════════════════════════════════════════════════
function App.CopyJobId()
	local jobId = game.JobId
	if jobId == "" then
		Notify("JobId", "This server has no JobId (Studio or a local test).", 4, "Warning")
	elseif Util.SetClipboard(jobId) then
		Notify("JobId copied", jobId, 4, "Success")
	else
		Notify("Clipboard unavailable", jobId, 10, "Warning") -- still readable in the toast
	end
end

function App.Rejoin()
	local alone = #Players:GetPlayers() <= 1 or game.JobId == ""
	Confirm(
		"Rejoin server?",
		alone and "You are alone here, so a fresh server will be joined." or "You will leave and rejoin this server.",
		function()
			Config.Persist()
			Notify("Teleport", "Rejoining…", 5, "Info")
			local ok, err = pcall(function()
				if alone then
					TeleportService:Teleport(game.PlaceId, LocalPlayer)
				else
					TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer)
				end
			end)
			if not ok then
				Notify("Teleport", CleanError(err), 6, "Error")
			end
		end,
		"Rejoin"
	)
end

local function cancelThread(thread: thread?)
	if thread and coroutine_status(thread) ~= "dead" then
		pcall(task_cancel, thread)
	end
end

-- Full teardown: flush the config, run every Maid task (connections, threads, overlay GUI, your
-- OnUnload callbacks), destroy Fluent (and its acrylic leftovers), then drop references.
function App.Unload()
	if App.Unloaded then
		return
	end
	if Config.Ready then
		pcall(Config.Persist) -- autosave off: only header changes are written
	end
	App.Unloaded = true
	App.Ready = false
	Config.Ready = false
	Background.Token += 1

	if App.Maid then
		pcall(App.Maid.Clean, App.Maid)
	end
	cancelThread(Config.SaveThread)
	cancelThread(Clock.Thread)
	cancelThread(Internals.PruneThread)
	Config.SaveThread, Clock.Thread, Internals.PruneThread = nil, nil, nil
	for index = #Win.Tweens, 1, -1 do
		pcall(Win.Tweens[index].Destroy, Win.Tweens[index])
		Win.Tweens[index] = nil
	end
	pcall(Internals.EndBatch)

	local fluent = App.Fluent
	if fluent then
		pcall(function()
			if fluent.UseAcrylic then
				fluent:ToggleAcrylic(false) -- removes Fluent's DepthOfField effect from Lighting
				-- Open toasts each own a blur part in Workspace; Fluent only removes it on close.
				for _, record in ipairs(Notifier.Active) do
					local paint = record.Notification.AcrylicPaint
					if paint and paint.Model then
						paint.Model:Destroy()
					end
				end
			end
		end)
		pcall(App.OriginalDestroy or fluent.Destroy, fluent)
		pcall(function()
			fluent.GUI:Destroy() -- also covers a failed boot where no window exists
		end)
		if GENV.Fluent == fluent then
			GENV.Fluent = nil
		end
	end
	if App.BlurFolder then
		pcall(App.BlurFolder.Destroy, App.BlurFolder) -- some Fluent builds leave this in the camera
	end

	table_clear(Config.Registry)
	table_clear(Config.Order)
	table_clear(Search.Records)
	table_clear(Search.Tabs)
	table_clear(Search.Sections)
	table_clear(Painters)
	table_clear(Notifier.Active)
	table_clear(Clock.Subscribers)
	table_clear(KeybindList.Rows)
	table_clear(KeybindList.HoldMap)
	table_clear(FontSize.Pending)
	table_clear(Accent.Originals)
	table_clear(Overlays.FrameMap)
	table_clear(ScaleFix.Fixers)
	Config.Data = nil
	Notifier.Create = nil
	Internals.Creator, Internals.Themes, Accent.ThemeSets = nil, nil, nil
	Background.Image, Background.StatusChanged = nil, NOOP
	Win.Scale, Win.Selector, Win.SearchBox, Win.SearchCount = nil, nil, nil, nil
	Win.OriginalMinimize, Win.OriginalMaximize = nil, nil
	Tooltip.Frame, Tooltip.Label, Watermark.Frame, Watermark.Label = nil, nil, nil, nil
	KeybindList.Frame, KeybindList.Body, KeybindList.Empty = nil, nil, nil
	MobileButton.Frame, MobileButton.Icon, Overlays.Gui = nil, nil, nil
	Perf.FpsItem, Perf.PingItem = nil, nil
	App.Fluent, App.Window, App.Options, App.Maid, App.BlurFolder, App.OriginalDestroy = nil, nil, nil, nil, nil, nil
	if GENV[App.InstanceKey] == App then
		GENV[App.InstanceKey] = nil
	end
end

-- Unloads, then runs your script again (Fluent's source is cached, so it's quick).
function App.Reload()
	local chunk = App.Self
	App.Unload()
	if type(chunk) == "function" then
		task_defer(chunk)
	else
		warn(string_format("[%s] Reload is unavailable here; execute your script again.", tostring(SETTINGS.Title)))
	end
end

local function LoadFluent(): any
	local cache = GENV[CACHE_KEY]
	if type(cache) ~= "table" then
		cache = {}
		GENV[CACHE_KEY] = cache
	end
	local source = cache.FluentSource
	if type(source) ~= "string" then
		local ok, result = pcall(function()
			return (game :: any):HttpGet(SETTINGS.FluentUrl)
		end)
		if not ok or type(result) ~= "string" or #result < 1000 then
			error("Could not download Fluent: " .. tostring(result), 0)
		end
		source = result
	end
	local chunk, compileError = loadstring(source)
	if type(chunk) ~= "function" then
		cache.FluentSource = nil
		error("Fluent failed to compile: " .. tostring(compileError), 0)
	end
	cache.FluentSource = source

	-- Some Fluent builds (the GitHub source) create a Folder in the camera at load time and never
	-- remove it; remember anything new so Unload can clean it up. (The release build parents its
	-- blur parts to Workspace and removes them itself.)
	local camera = Workspace.CurrentCamera
	local before = {}
	if camera then
		for _, child in ipairs(camera:GetChildren()) do
			before[child] = true
		end
	end
	local fluent = chunk()
	if camera then
		for _, child in ipairs(camera:GetChildren()) do
			if not before[child] and child:IsA("Folder") then
				App.BlurFolder = child
			end
		end
	end
	return fluent
end

-- The object CreateWindow returns. Tabs come back as builders (see section 7).
local function CreatePublic(): any
	local fluent = App.Fluent
	local public = {
		Fluent = fluent, -- the underlying Fluent library
		FluentWindow = App.Window, -- the underlying Fluent window
		Options = fluent.Options, -- every element by id: Window.Options.MyToggle.Value
		Version = LIBRARY_VERSION,
	}

	public.Config = {
		HasFileAccess = Env.CanWrite, -- false: settings only live in memory this session
		-- true when the file was written; false when nothing changed or there is no file access
		Save = function(): boolean
			return Config.SaveNow()
		end,
		Load = function()
			Config.LoadFromDisk()
		end,
		Reset = function()
			Config.ResetProfile()
		end,
		Switch = function(name: string): boolean
			return Config.SwitchProfile(name)
		end,
		Create = function(name: string)
			Config.CreateProfile(name, false)
		end,
		Duplicate = function(name: string)
			Config.CreateProfile(name, true)
		end,
		Rename = function(name: string)
			Config.RenameProfile(name)
		end,
		Delete = function()
			Config.DeleteProfile()
		end,
		Profiles = function(): { string }
			return Config.ProfileNames()
		end,
		Current = function(): string
			return Config.Current
		end,
		Export = function(): string?
			return Config.Export()
		end,
		Import = function(json: string)
			Config.Import(json)
		end,
		Path = function(): string
			return Config.FilePath
		end,
	}

	function public:Tab(title: string, icon: string?): any
		return UI.Tab(title, icon)
	end

	function public:Notify(title: string?, content: string?, duration: number?, kind: NotifyKind?, subContent: string?): any
		return Notify(title, content, duration, kind, subContent)
	end

	-- Both dialogs open the window first when it is hidden (dialogs live inside the window).
	function public:Confirm(title: string, content: string, onConfirm: () -> (), confirmText: string?)
		Confirm(title, content, onConfirm, confirmText)
	end

	-- { Title, Content, Buttons = { { Title, Callback? }, … } }; button callbacks are pcall'd and
	-- a dialog without buttons gets an "OK" button (Fluent dialogs only close through a button).
	function public:Dialog(config: any)
		local settings = type(config) == "table" and config or {}
		local buttons = {}
		for index, button in ipairs(type(settings.Buttons) == "table" and settings.Buttons or {}) do
			local title = tostring(button.Title or "OK")
			local callback = button.Callback
			buttons[index] = {
				Title = title,
				Callback = function()
					SafeCall(title, callback)
				end,
			}
		end
		if #buttons == 0 then
			buttons[1] = { Title = "OK" }
		end
		if not Win.Open then
			Win.Toggle(true) -- dialogs live inside the window
		end
		App.Window:Dialog({
			Title = tostring(settings.Title or ""),
			Content = tostring(settings.Content or ""),
			Buttons = buttons,
		})
	end

	-- Runs when the UI unloads (restore anything your script changed).
	function public:OnUnload(callback: () -> ())
		App.Maid:Give(function()
			SafeCall("OnUnload", callback)
		end)
	end

	-- Connects a signal that is disconnected automatically on unload; errors become toasts.
	function public:Connect(signal: RBXScriptSignal, callback: (...any) -> ()): RBXScriptConnection
		return App.Maid:Connect(signal, function(...)
			SafeCall("Connection", callback, ...)
		end)
	end

	-- Replaces a dropdown's options, keeping every selection that is still valid.
	function public:RefreshDropdown(id: string, values: { any })
		local entry = Config.Registry[id]
		if entry and entry.Type == "Dropdown" then
			UI.RefreshDropdown(entry, values)
		end
	end

	function public:RefreshKeybinds()
		KeybindList.RebuildHoldMap()
		KeybindList.Refresh()
	end

	function public:SetBackground(url: string?)
		local option = fluent.Options.UI_BackgroundUrl
		if option then
			option:SetValue(tostring(url or "")) -- saved with the profile
		else
			Background.Load(url)
		end
	end

	-- Opens (true), closes (false) or toggles (nil) the window with the usual animation.
	function public:Toggle(open: boolean?)
		Win.Toggle(open)
	end

	function public:IsReady(): boolean
		return App.Ready
	end

	-- Builds the Info/Settings tabs and loads the saved window state. Runs by itself right after
	-- your script finishes building (or first yields); call it yourself if you build tabs later.
	function public:Finalize()
		App.Finalize()
	end

	function public:Unload()
		App.Unload()
	end

	function public:Reload()
		App.Reload()
	end

	return public
end

function App.Finalize()
	if App.Finalized or App.Unloaded or not App.Window then
		return
	end
	App.Finalized = true
	local fluent = App.Fluent

	local built, buildError = pcall(function()
		if SETTINGS.InfoTab ~= false then
			BuildInfoTab()
		end
		if SETTINGS.SettingsTab ~= false then
			BuildSettingsTab()
		else
			-- No Settings tab: apply the option defaults directly.
			Background.Load(SETTINGS.BackgroundUrl)
			Watermark.SetEnabled(SETTINGS.ShowWatermark ~= false)
			KeybindList.SetEnabled(SETTINGS.ShowKeybindList ~= false)
			MobileButton.SetEnabled(IsTouch)
		end
	end)
	Internals.EndBatch() -- one theme pass for everything built since CreateWindow
	if not built then
		warn(string_format("[%s] building the built-in tabs failed: %s", tostring(SETTINGS.Title), tostring(buildError)))
	end

	App.Window:SelectTab(1)
	local profile = Config.CurrentProfile()
	Win.ApplyGeometry(profile.Window)
	Overlays.ApplyPositions(profile.Overlays)
	Win.ThemeSync()
	KeybindList.RebuildHoldMap()
	KeybindList.Refresh()

	-- Snapshot what is on disk so autosave only writes real changes from now on.
	local status = Config.LoadStatus
	if status == "ok" or status == "newer" or status == "unreadable" then
		Config.Capture(profile)
		local ok, json = pcall(HttpService.JSONEncode, HttpService, Config.Data)
		Config.LastJson = ok and json or nil
	end
	Config.Ready = true
	App.Ready = true
	if status == "missing" or status == "corrupt" then
		Config.SaveNow() -- first run, or recovered from a corrupt file: create it now
	end
	Internals.SchedulePrune()

	if not built then
		Notify("ModedUI", CleanError(buildError), 8, "Error")
	end
	if status == "corrupt" then
		Notify(
			"Config recovered",
			Config.BackupPath and ("The file was corrupt. Backup: " .. Config.BackupPath)
				or "The file was corrupt and could not be backed up.",
			8,
			"Warning",
			"Defaults were loaded."
		)
	elseif status == "unreadable" then
		Notify("Config", "The config file could not be read; defaults are in use.", 8, "Warning")
	elseif status == "nofs" then
		Notify("Config", "This executor has no file functions; settings will not persist.", 8, "Warning")
	elseif status == "newer" then
		Notify("Config", "The config was written by a newer version; unknown values are kept.", 6, "Warning")
	end

	if SETTINGS.WelcomeToast == false then
		return
	end
	local menuKey = fluent.Options.UI_MenuKeybind and fluent.Options.UI_MenuKeybind.Value or SETTINGS.MenuKey
	Notify(
		tostring(SETTINGS.Title),
		string_format('Loaded in %.2fs · profile "%s"', os_clock() - App.StartedAt, Config.Current),
		5,
		"Success",
		IsTouch and "Tap the floating button to show or hide the window."
			or string_format("Press %s to show or hide the window.", tostring(menuKey))
	)
end

local function Boot()
	-- Double-load guard: unload the window this script created last time, then claim the slot.
	local key = App.InstanceKey
	local previous = GENV[key]
	if type(previous) == "table" and previous ~= App and type(previous.Unload) == "function" then
		pcall(previous.Unload)
	end
	GENV[key] = App
	App.Maid = Maid.new()

	local fluent = LoadFluent() -- may yield while downloading
	if App.Unloaded or GENV[key] ~= App then
		pcall(function()
			fluent.GUI:Destroy()
		end)
		error("superseded by a newer execution of this script", 0)
	end
	App.Fluent = fluent
	App.Options = fluent.Options

	-- Fluent's own toasts (callback errors, key hint) go through the rate limiter, and its
	-- title-bar close button goes through our full unload.
	Notifier.Create = fluent.Notify
	fluent.Notify = function(_, config: any)
		local settings = type(config) == "table" and config or {}
		local isError = settings.Content == "Callback error"
		local kind: NotifyKind = if isError then "Error" else "Info"
		return Notify(settings.Title, settings.Content, settings.Duration, kind, settings.SubContent)
	end
	App.OriginalDestroy = fluent.Destroy
	fluent.Destroy = function()
		App.Unload()
	end

	Internals.Resolve()
	Config.Init()
	Internals.BeginBatch() -- ended by Finalize, after your tabs are built
	Win.Create()
	Overlays.Create()
	App.Public = CreatePublic()
	task_defer(App.Finalize) -- runs once your script finishes building (or first yields)
end

local ModedUI = { Version = LIBRARY_VERSION }

-- ModedUI:CreateWindow(options) → Window. See OPTIONS at the top of this file for every option.
function ModedUI:CreateWindow(options: { [string]: any }?): any
	-- Reload re-runs whatever called CreateWindow (normally your whole script) unless you pass
	-- options.Reload.
	local reload = type(options) == "table" and options.Reload or nil
	if type(reload) ~= "function" then
		reload = nil
		local caller = debug.info(2, "f")
		if type(caller) == "function" and debug.info(2, "s") ~= "[C]" then
			reload = caller
		end
	end

	if App.Created then
		-- Each window owns its library state, so extra windows run on a fresh copy of the library.
		-- (Give every window its own Folder: the Folder is also its config file and reload slot.)
		local fresh = if type(LIBRARY_CHUNK) == "function" then LIBRARY_CHUNK() else nil
		if type(fresh) ~= "table" or fresh == ModedUI then
			error("ModedUI: could not create another window", 2)
		end
		local forwarded = if type(options) == "table" then table_clone(options) else {}
		forwarded.Reload = reload
		return fresh:CreateWindow(forwarded)
	end
	App.Created = true
	App.StartedAt = os_clock()
	if type(options) == "table" then
		for key, value in pairs(options) do
			SETTINGS[key] = value
		end
		-- Fluent's option names work too.
		if options.MenuKey == nil and options.MinimizeKey ~= nil then
			SETTINGS.MenuKey = options.MinimizeKey
		end
	end
	SETTINGS.Title = tostring(SETTINGS.Title)
	SETTINGS.Version = tostring(SETTINGS.Version)
	local menuKey: any = SETTINGS.MenuKey
	if typeof(menuKey) == "EnumItem" then
		SETTINGS.MenuKey = menuKey.Name -- Enum.KeyCode.LeftControl → "LeftControl"
	end
	local size: any = SETTINGS.Size
	if typeof(size) == "UDim2" then
		SETTINGS.Size = Vector2.new(size.X.Offset, size.Y.Offset) -- UDim2.fromOffset(580, 460)
	elseif typeof(size) ~= "Vector2" then
		SETTINGS.Size = DEFAULTS.Size
	end
	App.Name, App.Version = SETTINGS.Title, SETTINGS.Version
	App.Self = reload
	App.InstanceKey = "__ModedUI_" .. Util.SanitizeFileName(SETTINGS.Folder, "ModedUI")

	local ok, err = pcall(Boot)
	if not ok then
		pcall(App.Unload)
		error(string_format("ModedUI failed to start: %s", tostring(err)), 2)
	end
	return App.Public
end

return ModedUI
