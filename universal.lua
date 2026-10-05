----------------------------------------------------------------------
-- SETTINGS
----------------------------------------------------------------------
-- Where THIS script is hosted (a raw link to universal.lua). "Keep hub after teleport"
-- re-runs the hub from here in the next server, so upload universal.lua to this address
-- or change the link to wherever you host it.
local HUB_URL = "https://raw.githubusercontent.com/sourwisard/cat-universal/main/universal.lua"
----------------------------------------------------------------------

--[[
	UILib - a small, clean UI library for Roblox (Luau)

	Put this whole file in a LocalScript (e.g. StarterPlayer > StarterPlayerScripts).
	The library is defined at the top; the example menu is at the bottom - delete it
	(everything under the EXAMPLE banner) when you build your own UI.

	API
	  UILib.new(config) -> Window
	    config: Title, Size (Vector2), ToggleKey (Enum.KeyCode, default Insert; false = none), Theme (table of overrides), Parent (Instance),
	             Sidebar (bool, default true), Minimizable (bool, default true),
	             Scale (number, default 1; max UI scale, still shrinks to fit small screens)

	  Window:AddTab(name) -> Tab
	  Window:Notify({Title, Text, Duration})
	  Window:Toggle(visible?)
	  Window:SetToggleKey(keyCode|false)  -- change the minimize/restore key at runtime
	  Window:Minimize(state?)      -- collapse to a small square / click the square to reopen
	  Window:SetTheme(overrides)   -- affects elements created afterwards
	  Window:Destroy()

	  Tab:AddSection(text)
	  Tab:AddLabel(text)                                  -> {Set}
	  Tab:AddButton({Text, Callback})                     -> {SetText}
	  Tab:AddToggle({Text, Default, Callback})            -> {Set, Get}
	  Tab:AddSlider({Text, Min, Max, Default, Step, Suffix, Callback}) -> {Set, Get}
	  Tab:AddDropdown({Text, Options, Default, Callback}) -> {Set, Get, SetOptions}
	  Tab:AddTextbox({Text, Placeholder, Default, ClearOnFocus, Callback}) -> {Set, Get}
	  Tab:AddKeybind({Text, Default (Enum.KeyCode), Callback(newKey)}) -> {Set, Get}
	                                                      -- click, then press a key (Esc cancels, Backspace unbinds)
]]


local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local UILib = {}
UILib.__index = UILib

local Window = {}
Window.__index = Window

local Tab = {}
Tab.__index = Tab

local BUBBLE_SIZE = 44 -- side length of the minimized square

local DEFAULT_THEME = {
	Background = Color3.fromRGB(18, 18, 24),
	Surface = Color3.fromRGB(26, 26, 34),
	Element = Color3.fromRGB(36, 36, 47),
	ElementHover = Color3.fromRGB(46, 46, 60),
	Accent = Color3.fromRGB(124, 92, 255),
	Danger = Color3.fromRGB(235, 80, 90),
	Text = Color3.fromRGB(236, 236, 242),
	SubText = Color3.fromRGB(150, 150, 168),
	Stroke = Color3.fromRGB(52, 52, 68),
	Font = Enum.Font.GothamMedium,
	FontBold = Enum.Font.GothamBold,
}

----------------------------------------------------------------------
-- helpers
----------------------------------------------------------------------

local function new(class, props, children)
	local inst = Instance.new(class)
	local parent
	for k, v in pairs(props or {}) do
		if k == "Parent" then
			parent = v
		else
			inst[k] = v
		end
	end
	for _, child in ipairs(children or {}) do
		child.Parent = inst
	end
	inst.Parent = parent
	return inst
end

local function tween(inst, time, props)
	local t = TweenService:Create(inst, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), props)
	t:Play()
	return t
end

local function corner(radius)
	return new("UICorner", { CornerRadius = UDim.new(0, radius or 6) })
end

local function stroke(color, thickness)
	return new("UIStroke", {
		Color = color,
		Thickness = thickness or 1,
		ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
	})
end

local function padding(all)
	return new("UIPadding", {
		PaddingTop = UDim.new(0, all),
		PaddingBottom = UDim.new(0, all),
		PaddingLeft = UDim.new(0, all),
		PaddingRight = UDim.new(0, all),
	})
end

local function isPress(input)
	return input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch
end

local function isMove(input)
	return input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch
end

local function round(n, step)
	if not step or step <= 0 then
		return n
	end
	return math.floor(n / step + 0.5) * step
end

local function hoverEffect(button, target, normal, hover)
	local activeTween = nil
	button.MouseEnter:Connect(function()
		if activeTween then
			activeTween:Cancel()
		end
		activeTween = tween(target, 0.12, { BackgroundColor3 = hover })
	end)
	button.MouseLeave:Connect(function()
		if activeTween then
			activeTween:Cancel()
		end
		activeTween = tween(target, 0.12, { BackgroundColor3 = normal })
	end)
end

-- Fades a plain (non-CanvasGroup) UI tree. CanvasGroups render to a texture, which
-- makes text soft/blurry, so popups fade their pieces individually instead.
local function collectFade(root)
	local items = {}
	local function add(inst)
		if inst:IsA("GuiObject") then
			table.insert(items, { inst, "BackgroundTransparency", inst.BackgroundTransparency })
			if inst:IsA("TextLabel") or inst:IsA("TextButton") or inst:IsA("TextBox") then
				table.insert(items, { inst, "TextTransparency", inst.TextTransparency })
			end
		elseif inst:IsA("UIStroke") then
			table.insert(items, { inst, "Transparency", inst.Transparency })
		end
	end
	add(root)
	for _, d in ipairs(root:GetDescendants()) do
		add(d)
	end
	return items
end

local function fadeItems(items, time, show)
	for _, it in ipairs(items) do
		tween(it[1], time, { [it[2]] = show and it[3] or 1 })
	end
end

----------------------------------------------------------------------
-- window
----------------------------------------------------------------------

function UILib.new(config)
	config = config or {}
	local self = setmetatable({}, Window)

	self.Theme = table.clone(DEFAULT_THEME)
	for k, v in pairs(config.Theme or {}) do
		self.Theme[k] = v
	end
	local theme = self.Theme

	self._connections = {}
	self._tabs = {}
	self._activeTab = nil

	local size = config.Size or Vector2.new(560, 380)
	self._size = size
	self._minimized = false
	self._minimizable = config.Minimizable ~= false
	local parent = config.Parent or Players.LocalPlayer:WaitForChild("PlayerGui")

	self.Gui = new("ScreenGui", {
		Name = "UILib_" .. (config.Title or "Window"),
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		IgnoreGuiInset = true,
		DisplayOrder = 100,
		Parent = parent,
	})

	-- notifications live outside the main frame so they show even when the window is hidden
	self._notifHolder = new("Frame", {
		Name = "Notifications",
		AnchorPoint = Vector2.new(1, 1),
		Position = UDim2.new(1, -16, 1, -16),
		Size = UDim2.new(0, 340, 1, -32),
		BackgroundTransparency = 1,
		Parent = self.Gui,
	}, {
		new("UIListLayout", {
			Padding = UDim.new(0, 8),
			VerticalAlignment = Enum.VerticalAlignment.Bottom,
			HorizontalAlignment = Enum.HorizontalAlignment.Right,
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	local mainCorner = corner(10)
	local clipCorner = corner(10)
	self._corners = { mainCorner, clipCorner }

	-- top-anchored so minimizing keeps the title bar where it is
	self.Main = new("Frame", {
		Name = "Main",
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0.5, -size.Y / 2),
		Size = UDim2.fromOffset(size.X, size.Y),
		BackgroundColor3 = theme.Background,
		BorderSizePixel = 0,
		Parent = self.Gui,
	}, { mainCorner, stroke(theme.Stroke, 1) })

	-- ClipsDescendants ignores UICorner, so square child corners would poke out.
	-- A CanvasGroup with the same UICorner clips its children to the rounded shape.
	self._clip = new("CanvasGroup", {
		Name = "Clip",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = self.Main,
	}, { clipCorner })

	-- scale down on small screens (phones)
	local uiScale = new("UIScale", { Parent = self.Main })
	self._uiScale = uiScale
	-- phones get an extra 20% shrink so the window doesn't fill the whole screen
	-- (change with MobileScale in the window config; 1 = no extra shrink)
	local mobileScale = config.MobileScale or 0.8
	local function isMobile()
		local mobile = game:GetService("UserInputService").TouchEnabled and not game:GetService("UserInputService").KeyboardEnabled
		pcall(function()
			mobile = table.find({ Enum.Platform.Android, Enum.Platform.IOS }, game:GetService("UserInputService"):GetPlatform()) ~= nil
		end)
		return mobile
	end
	local function updateScale()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local vp = cam.ViewportSize
		local fit = math.clamp(math.min(vp.X / (size.X + 40), vp.Y / (size.Y + 40)), 0.5, math.max(config.Scale or 1, 0.5))
		uiScale.Scale = isMobile() and math.max(fit * mobileScale, 0.35) or fit
	end
	updateScale()
	if workspace.CurrentCamera then
		table.insert(self._connections, workspace.CurrentCamera:GetPropertyChangedSignal("ViewportSize"):Connect(updateScale))
	end

	-- title bar
	local titleBar = new("Frame", {
		Name = "TitleBar",
		Size = UDim2.new(1, 0, 0, 40),
		BackgroundColor3 = theme.Surface,
		BorderSizePixel = 0,
		Parent = self._clip,
	})

	new("TextLabel", {
		Text = config.Title or "UILib",
		Font = theme.FontBold,
		TextSize = 15,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(14, 0),
		Size = UDim2.new(1, -84, 1, 0),
		Parent = titleBar,
	})

	self._titleBar = titleBar

	local function titleButton(text, offsetX, textSize)
		local b = new("TextButton", {
			Text = text,
			Font = theme.FontBold,
			TextSize = textSize,
			TextColor3 = theme.SubText,
			AutoButtonColor = false,
			BackgroundColor3 = theme.Surface,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, offsetX, 0.5, 0),
			Size = UDim2.fromOffset(28, 28),
			Parent = titleBar,
		}, { corner(6) })
		hoverEffect(b, b, theme.Surface, theme.ElementHover)
		return b
	end

	local closeBtn = titleButton("×", -8, 20)
	local minBtn = titleButton("–", -40, 18)
	minBtn.Visible = config.Minimizable ~= false

	closeBtn.MouseEnter:Connect(function()
		tween(closeBtn, 0.12, { TextColor3 = theme.Danger })
	end)
	closeBtn.MouseLeave:Connect(function()
		tween(closeBtn, 0.12, { TextColor3 = theme.SubText })
	end)
	closeBtn.MouseButton1Click:Connect(function()
		self:_confirmClose()
	end)
	minBtn.MouseButton1Click:Connect(function()
		self:Minimize()
	end)

	-- the square the window collapses into; click it (without dragging) to reopen
	local bubble = new("TextButton", {
		Name = "Bubble",
		Text = string.upper(string.sub(config.Title or "U", 1, 1)),
		Font = theme.FontBold,
		TextSize = 20,
		TextColor3 = theme.Accent,
		AutoButtonColor = false,
		BackgroundColor3 = theme.Surface,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		ZIndex = 5,
		Parent = self._clip,
	})
	hoverEffect(bubble, bubble, theme.Surface, theme.ElementHover)
	self._bubble = bubble

	-- dragging (mouse + touch). onClick fires if the press ends without moving past `threshold` pixels.
	local function makeDraggable(handle, threshold, onClick)
		local dragging, moved, dragStart, startPos = false, false, nil, nil
		local hovering = false
		local pointer, startAbs = nil, nil
		local isTouch = false
		local gain, lastAbs, lastOff = nil, nil, nil

		-- mouse: read the real cursor position every frame (more reliable than move events);
		-- touch: use the touch's own position updates
		local function mouseNow()
			return UserInputService:GetMouseLocation()
		end

		handle.MouseEnter:Connect(function()
			hovering = true
		end)
		handle.MouseLeave:Connect(function()
			hovering = false
		end)
		handle.InputBegan:Connect(function(input)
			if isPress(input) then
				dragging = true
				moved = false
				isTouch = input.UserInputType == Enum.UserInputType.Touch
				dragStart = isTouch and Vector2.new(input.Position.X, input.Position.Y) or mouseNow()
				pointer = dragStart
				startPos = self.Main.Position
				startAbs = self.Main.AbsolutePosition
				gain, lastAbs, lastOff = nil, nil, nil
				input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End and dragging then
						dragging = false
						-- final check so a real drag can never count as a click
						local now = isTouch and pointer or mouseNow()
						if (now - dragStart).Magnitude > threshold then
							moved = true
						end
						if (self.Main.AbsolutePosition - startAbs).Magnitude > math.max(threshold, 2) then
							moved = true
						end
						if not moved and onClick and (isTouch or hovering) then
							onClick()
						end
					end
				end)
			end
		end)
		table.insert(self._connections, UserInputService.InputChanged:Connect(function(input)
			if dragging and isTouch and input.UserInputType == Enum.UserInputType.Touch then
				pointer = Vector2.new(input.Position.X, input.Position.Y)
			end
		end))
		-- Position is driven by where the window actually is on screen (AbsolutePosition), not by
		-- assumed UIScale math, so it can't drift from the cursor. The px-per-offset gain is measured
		-- from the previous frame's correction.
		table.insert(self._connections, RunService.RenderStepped:Connect(function()
			if not (dragging and pointer and startAbs) then
				return
			end
			if not isTouch then
				pointer = mouseNow()
			end
			if not moved and (pointer - dragStart).Magnitude > threshold then
				moved = true
			end
			if not moved then
				return
			end
			local main = self.Main
			local abs = main.AbsolutePosition
			if lastAbs and lastOff and lastOff.Magnitude > 0.5 then
				local g = (abs - lastAbs).Magnitude / lastOff.Magnitude
				if g > 0.2 and g < 5 then
					gain = g
				end
			end
			local target = startAbs + Vector2.new(pointer.X - dragStart.X, pointer.Y - dragStart.Y)
			local err = target - abs
			local g = gain or uiScale.Scale
			local off = err / g
			lastAbs, lastOff = abs, off
			local p = main.Position
			main.Position = UDim2.new(p.X.Scale, p.X.Offset + off.X, p.Y.Scale, p.Y.Offset + off.Y)
		end))
	end

	makeDraggable(titleBar, 0, nil)
	makeDraggable(bubble, 6, function()
		if not self._minimized then
			return
		end
		self:Minimize(false)
	end)

	-- sidebar + content
	self._hasSidebar = config.Sidebar ~= false
	self._sidebar = new("ScrollingFrame", {
		Name = "Sidebar",
		Visible = self._hasSidebar,
		Position = UDim2.fromOffset(0, 40),
		Size = UDim2.new(0, 132, 1, -40),
		BackgroundColor3 = theme.Surface,
		BorderSizePixel = 0,
		ScrollBarThickness = 0,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Parent = self._clip,
	}, {
		padding(8),
		new("UIListLayout", { Padding = UDim.new(0, 4), SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	self._content = new("Frame", {
		Name = "Content",
		Position = UDim2.fromOffset(self._hasSidebar and 132 or 0, 40),
		Size = UDim2.new(1, self._hasSidebar and -132 or 0, 1, -40),
		BackgroundTransparency = 1,
		Parent = self._clip,
	})

	-- toggle keybind
	self._toggleKey = config.ToggleKey
	if self._toggleKey == nil then
		self._toggleKey = Enum.KeyCode.Insert
	end
	self._listening = false -- true while a keybind element is waiting for a key
	table.insert(self._connections, UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and not self._listening and self._toggleKey and input.KeyCode == self._toggleKey then
			if self._minimizable then
				self:Minimize()
			else
				self:Toggle()
			end
		end
	end))

	return self
end

function Window:SetToggleKey(key)
	self._toggleKey = key or false
end

function Window:SetTheme(overrides)
	for k, v in pairs(overrides) do
		self.Theme[k] = v
	end
end

-- hides/shows the whole UI: window, minimized square, popups and notifications
function Window:Toggle(visible)
	if visible == nil then
		visible = not self.Gui.Enabled
	end
	self.Gui.Enabled = visible
end

function Window:Minimize(state)
	if state == nil then
		state = not self._minimized
	end
	if state == self._minimized then
		return
	end
	self._minimized = state
	self._minToken = (self._minToken or 0) + 1
	local token = self._minToken
	local size = self._size

	if state then
		-- shrink into a rounded square, then swap the contents for the square's button
		tween(self.Main, 0.2, { Size = UDim2.fromOffset(BUBBLE_SIZE, BUBBLE_SIZE) })
		for _, c in ipairs(self._corners) do
			tween(c, 0.2, { CornerRadius = UDim.new(0, 14) })
		end
		task.delay(0.2, function()
			if self._minimized and self._minToken == token and self.Gui.Parent then
				self._titleBar.Visible = false
				self._sidebar.Visible = false
				self._content.Visible = false
				self._bubble.Visible = true
			end
		end)
	else
		self._bubble.Visible = false
		self._titleBar.Visible = true
		self._sidebar.Visible = self._hasSidebar
		self._content.Visible = true

		-- keep the reopened window on screen even if the square was dragged near an edge
		local pos = self.Main.Position
		local cam = workspace.CurrentCamera
		if cam then
			local vp = cam.ViewportSize
			local scale = self._uiScale.Scale
			local w, h = size.X * scale, size.Y * scale
			local cx = self.Main.AbsolutePosition.X + self.Main.AbsoluteSize.X / 2
			local top = self.Main.AbsolutePosition.Y
			local dx = math.clamp(cx, w / 2 + 8, math.max(vp.X - w / 2 - 8, w / 2 + 8)) - cx
			local dy = math.clamp(top, 8, math.max(vp.Y - h - 8, 8)) - top
			pos = UDim2.new(pos.X.Scale, pos.X.Offset + dx / scale, pos.Y.Scale, pos.Y.Offset + dy / scale)
		end

		tween(self.Main, 0.2, { Size = UDim2.fromOffset(size.X, size.Y), Position = pos })
		for _, c in ipairs(self._corners) do
			tween(c, 0.2, { CornerRadius = UDim.new(0, 10) })
		end
	end
end

function Window:_confirmClose()
	if self._confirm then
		return
	end
	local theme = self.Theme

	-- plain Frame (not a CanvasGroup) so text stays sharp
	local overlay = new("Frame", {
		Name = "ConfirmClose",
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		ZIndex = 50,
		Parent = self.Gui,
	})
	self._confirm = overlay

	-- dim layer is a button so it swallows clicks meant for anything behind the popup
	new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		BackgroundColor3 = Color3.new(0, 0, 0),
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Parent = overlay,
	})

	-- fixed, even-numbered size placed on whole pixels: fractional positions/sizes
	-- (AnchorPoint centering, AutomaticSize) are what make Roblox text look blurry
	local CARD_W, CARD_H = 300, 166
	local screen = self.Gui.AbsoluteSize
	local card = new("Frame", {
		Position = UDim2.fromOffset(math.floor((screen.X - CARD_W) / 2), math.floor((screen.Y - CARD_H) / 2)),
		Size = UDim2.fromOffset(CARD_W, CARD_H),
		BackgroundColor3 = theme.Surface,
		BorderSizePixel = 0,
		Parent = overlay,
	}, {
		corner(10),
		stroke(theme.Stroke, 1),
		padding(16),
		new("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	new("TextLabel", {
		Text = "Close this UI?",
		Font = theme.FontBold,
		TextSize = 16,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = 1,
		Parent = card,
	})
	new("TextLabel", {
		Text = "This fully removes the UI. It can't be reopened until the script runs again. "
			.. "Use the minimize button if you just want it out of the way.",
		Font = theme.Font,
		TextSize = 13,
		TextColor3 = theme.SubText,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 64),
		LayoutOrder = 2,
		Parent = card,
	})

	local row = new("Frame", {
		Size = UDim2.new(1, 0, 0, 34),
		BackgroundTransparency = 1,
		LayoutOrder = 3,
		Parent = card,
	}, {
		new("UIListLayout", {
			FillDirection = Enum.FillDirection.Horizontal,
			Padding = UDim.new(0, 8),
			SortOrder = Enum.SortOrder.LayoutOrder,
		}),
	})

	local function popupButton(text, color, order)
		local b = new("TextButton", {
			Text = text,
			Font = theme.FontBold,
			TextSize = 14,
			TextColor3 = theme.Text,
			AutoButtonColor = false,
			BackgroundColor3 = color,
			Size = UDim2.new(0.5, -4, 1, 0),
			LayoutOrder = order,
			Parent = row,
		}, { corner(6) })
		hoverEffect(b, b, color, color:Lerp(Color3.new(1, 1, 1), 0.12))
		return b
	end

	local cancel = popupButton("Cancel", theme.Element, 1)
	local remove = popupButton("Remove UI", theme.Danger, 2)

	-- fade in
	local items = collectFade(overlay)
	for _, it in ipairs(items) do
		it[1][it[2]] = 1
	end
	fadeItems(items, 0.15, true)

	cancel.MouseButton1Click:Connect(function()
		self._confirm = nil
		fadeItems(items, 0.15, false)
		task.delay(0.16, function()
			overlay:Destroy()
		end)
	end)
	remove.MouseButton1Click:Connect(function()
		self:Destroy()
	end)
end

function Window:Destroy()
	for _, c in ipairs(self._connections) do
		c:Disconnect()
	end
	table.clear(self._connections)
	self.Gui:Destroy()
end

function Window:Notify(opts)
	local theme = self.Theme
	local duration = opts.Duration or 4

	local card = new("Frame", {
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = theme.Surface,
		BorderSizePixel = 0,
		Parent = self._notifHolder,
	}, {
		corner(10),
		stroke(theme.Stroke, 1),
		padding(14),
		new("UIListLayout", { Padding = UDim.new(0, 4) }),
	})

	new("TextLabel", {
		Text = opts.Title or "Notice",
		Font = theme.FontBold,
		TextSize = 17,
		TextColor3 = theme.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 20),
		LayoutOrder = 1,
		Parent = card,
	})
	new("TextLabel", {
		Text = opts.Text or "",
		Font = theme.Font,
		TextSize = 15,
		TextColor3 = theme.Text,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = card,
	})

	-- fade the pieces individually (a CanvasGroup would make the text blurry)
	local items = collectFade(card)
	for _, it in ipairs(items) do
		it[1][it[2]] = 1
	end
	fadeItems(items, 0.25, true)
	task.delay(duration, function()
		if card.Parent then
			fadeItems(items, 0.25, false)
			task.wait(0.26)
			card:Destroy()
		end
	end)
end

----------------------------------------------------------------------
-- tabs
----------------------------------------------------------------------

function Window:AddTab(name)
	local theme = self.Theme
	local tab = setmetatable({ Window = self, Theme = theme, Name = name }, Tab)

	tab.Button = new("TextButton", {
		Text = name,
		Font = theme.Font,
		TextSize = 14,
		TextColor3 = theme.SubText,
		TextXAlignment = Enum.TextXAlignment.Left,
		AutoButtonColor = false,
		BackgroundColor3 = theme.Element,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 32),
		LayoutOrder = #self._tabs + 1,
		Parent = self._sidebar,
	}, {
		corner(6),
		new("UIPadding", { PaddingLeft = UDim.new(0, 12) }),
	})

	tab.Indicator = new("Frame", {
		Size = UDim2.new(0, 3, 0, 16),
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, -9, 0.5, 0),
		BackgroundColor3 = theme.Accent,
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Parent = tab.Button,
	}, { corner(2) })

	tab.Page = new("ScrollingFrame", {
		Name = name,
		Size = UDim2.fromScale(1, 1),
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		ScrollBarThickness = 3,
		ScrollBarImageColor3 = theme.Stroke,
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		Visible = false,
		Parent = self._content,
	}, {
		padding(12),
		new("UIListLayout", { Padding = UDim.new(0, 6), SortOrder = Enum.SortOrder.LayoutOrder }),
	})

	tab.Button.MouseButton1Click:Connect(function()
		self:_select(tab)
	end)
	tab.Button.MouseEnter:Connect(function()
		if self._activeTab ~= tab then
			tween(tab.Button, 0.12, { BackgroundTransparency = 0.6 })
		end
	end)
	tab.Button.MouseLeave:Connect(function()
		if self._activeTab ~= tab then
			tween(tab.Button, 0.12, { BackgroundTransparency = 1 })
		end
	end)

	table.insert(self._tabs, tab)
	if not self._activeTab then
		self:_select(tab)
	end
	return tab
end

function Window:_select(tab)
	local theme = self.Theme
	for _, t in ipairs(self._tabs) do
		local active = (t == tab)
		t.Page.Visible = active
		tween(t.Button, 0.15, {
			BackgroundTransparency = active and 0 or 1,
			TextColor3 = active and theme.Text or theme.SubText,
		})
		tween(t.Indicator, 0.15, { BackgroundTransparency = active and 0 or 1 })
	end
	self._activeTab = tab
end

----------------------------------------------------------------------
-- elements
----------------------------------------------------------------------

function Tab:_element(height)
	self._order = (self._order or 0) + 1
	return new("Frame", {
		Size = UDim2.new(1, 0, 0, height or 36),
		BackgroundColor3 = self.Theme.Element,
		BorderSizePixel = 0,
		LayoutOrder = self._order,
		Parent = self.Page,
	}, { corner(6) })
end

function Tab:_label(parent, text, props)
	local theme = self.Theme
	local p = {
		Text = text,
		Font = theme.Font,
		TextSize = 14,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(12, 0),
		Size = UDim2.new(1, -24, 0, 36),
		Parent = parent,
	}
	for k, v in pairs(props or {}) do
		p[k] = v
	end
	return new("TextLabel", p)
end

function Tab:AddSection(text)
	self._order = (self._order or 0) + 1
	new("TextLabel", {
		Text = string.upper(text),
		Font = self.Theme.FontBold,
		TextSize = 11,
		TextColor3 = self.Theme.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 22),
		LayoutOrder = self._order,
		Parent = self.Page,
	}, { new("UIPadding", { PaddingLeft = UDim.new(0, 2), PaddingTop = UDim.new(0, 6) }) })
end

function Tab:AddLabel(text)
	local frame = self:_element(32)
	frame.BackgroundTransparency = 1
	-- wrap long text and grow the row to fit instead of cutting it off
	frame.AutomaticSize = Enum.AutomaticSize.Y
	new("UIPadding", { PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 6), Parent = frame })
	local label = self:_label(frame, text, {
		TextColor3 = self.Theme.SubText,
		TextSize = 13,
		TextWrapped = true,
		TextYAlignment = Enum.TextYAlignment.Top,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, -24, 0, 0),
	})
	return {
		Set = function(_, t)
			label.Text = t
		end,
	}
end

function Tab:AddButton(opts)
	local theme = self.Theme
	local frame = self:_element(36)
	local btn = new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	})
	local label = self:_label(frame, opts.Text or "Button")
	label.Size = UDim2.new(1, -24, 1, 0)

	hoverEffect(btn, frame, theme.Element, theme.ElementHover)
	btn.MouseButton1Down:Connect(function()
		tween(frame, 0.08, { BackgroundColor3 = theme.Accent })
	end)
	btn.MouseButton1Up:Connect(function()
		tween(frame, 0.15, { BackgroundColor3 = theme.ElementHover })
	end)
	btn.MouseButton1Click:Connect(function()
		if opts.Callback then
			task.spawn(opts.Callback)
		end
	end)

	return {
		SetText = function(_, t)
			label.Text = t
		end,
	}
end

function Tab:AddToggle(opts)
	local theme = self.Theme
	local state = opts.Default == true
	local frame = self:_element(36)
	local btn = new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = frame,
	})
	self:_label(frame, opts.Text or "Toggle").Size = UDim2.new(1, -70, 1, 0)

	local track = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -12, 0.5, 0),
		Size = UDim2.fromOffset(38, 20),
		BackgroundColor3 = theme.Stroke,
		Parent = frame,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	local knob = new("Frame", {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 2, 0.5, 0),
		Size = UDim2.fromOffset(16, 16),
		BackgroundColor3 = theme.Text,
		Parent = track,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	local obj = {}
	local function render(animate)
		local props1 = { BackgroundColor3 = state and theme.Accent or theme.Stroke }
		local props2 = { Position = state and UDim2.new(1, -18, 0.5, 0) or UDim2.new(0, 2, 0.5, 0) }
		if animate then
			tween(track, 0.15, props1)
			tween(knob, 0.15, props2)
		else
			track.BackgroundColor3 = props1.BackgroundColor3
			knob.Position = props2.Position
		end
	end
	function obj:Set(v, silent)
		state = v and true or false
		render(true)
		if not silent and opts.Callback then
			task.spawn(opts.Callback, state)
		end
	end
	function obj:Get()
		return state
	end

	hoverEffect(btn, frame, theme.Element, theme.ElementHover)
	btn.MouseButton1Click:Connect(function()
		obj:Set(not state)
	end)
	render(false)
	return obj
end

function Tab:AddSlider(opts)
	local theme = self.Theme
	local min, max = opts.Min or 0, opts.Max or 100
	local step = opts.Step or 1
	local suffix = opts.Suffix or ""
	local value = math.clamp(opts.Default or min, min, max)

	local frame = self:_element(52)
	local label = self:_label(frame, opts.Text or "Slider")
	label.Size = UDim2.new(0.6, -12, 0, 30)
	local valueLabel = self:_label(frame, "", {
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = theme.SubText,
		Position = UDim2.new(0.4, 0, 0, 0),
		Size = UDim2.new(0.6, -12, 0, 30),
	})

	local bar = new("Frame", {
		Position = UDim2.new(0, 12, 0, 36),
		Size = UDim2.new(1, -24, 0, 6),
		BackgroundColor3 = theme.Stroke,
		BorderSizePixel = 0,
		Parent = frame,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })
	local fill = new("Frame", {
		Size = UDim2.fromScale(0, 1),
		BackgroundColor3 = theme.Accent,
		BorderSizePixel = 0,
		Parent = bar,
	}, { new("UICorner", { CornerRadius = UDim.new(1, 0) }) })

	local obj = {}
	local function render()
		local pct = (value - min) / math.max(max - min, 1e-9)
		fill.Size = UDim2.fromScale(pct, 1)
		local shown = (step % 1 == 0) and tostring(math.floor(value + 0.5)) or string.format("%.2f", value)
		valueLabel.Text = shown .. suffix
	end
	function obj:Set(v, silent)
		v = math.clamp(round(v - min, step) + min, min, max)
		if v == value then
			return
		end
		value = v
		render()
		if not silent and opts.Callback then
			task.spawn(opts.Callback, value)
		end
	end
	function obj:Get()
		return value
	end

	local dragging = false
	local function fromInput(input)
		local pct = math.clamp((input.Position.X - bar.AbsolutePosition.X) / bar.AbsoluteSize.X, 0, 1)
		obj:Set(min + (max - min) * pct)
	end

	-- the whole card is grabbable, which is much friendlier on touch
	frame.InputBegan:Connect(function(input)
		if isPress(input) then
			dragging = true
			fromInput(input)
			input.Changed:Connect(function()
				if input.UserInputState == Enum.UserInputState.End then
					dragging = false
				end
			end)
		end
	end)
	table.insert(self.Window._connections, UserInputService.InputChanged:Connect(function(input)
		if dragging and isMove(input) then
			fromInput(input)
		end
	end))

	render()
	return obj
end

function Tab:AddDropdown(opts)
	local theme = self.Theme
	local options = opts.Options or {}
	local selected = opts.Default
	local open = false

	local frame = self:_element(36)
	frame.ClipsDescendants = true

	local header = new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 36),
		Parent = frame,
	})
	self:_label(frame, opts.Text or "Dropdown").Size = UDim2.new(0.5, -12, 0, 36)
	local valueLabel = self:_label(frame, tostring(selected or "Select…"), {
		TextXAlignment = Enum.TextXAlignment.Right,
		TextColor3 = theme.SubText,
		Position = UDim2.new(0.5, 0, 0, 0),
		Size = UDim2.new(0.5, -28, 0, 36),
	})
	local arrow = self:_label(frame, "▾", {
		TextXAlignment = Enum.TextXAlignment.Center,
		TextColor3 = theme.SubText,
		Position = UDim2.new(1, -26, 0, 0),
		Size = UDim2.fromOffset(20, 36),
	})

	local list = new("Frame", {
		Position = UDim2.fromOffset(6, 40),
		Size = UDim2.new(1, -12, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundTransparency = 1,
		Parent = frame,
	}, { new("UIListLayout", { Padding = UDim.new(0, 2) }) })

	local obj = {}
	local function setOpen(v)
		open = v
		local h = 36
		if open then
			h = 36 + 8 + #options * 28 + math.max(#options - 1, 0) * 2
		end
		tween(frame, 0.18, { Size = UDim2.new(1, 0, 0, h) })
		tween(arrow, 0.18, { Rotation = open and 180 or 0 })
	end

	local function rebuild()
		for _, c in ipairs(list:GetChildren()) do
			if c:IsA("TextButton") then
				c:Destroy()
			end
		end
		for _, option in ipairs(options) do
			local item = new("TextButton", {
				Text = tostring(option),
				Font = theme.Font,
				TextSize = 13,
				TextColor3 = (option == selected) and theme.Accent or theme.Text,
				AutoButtonColor = false,
				BackgroundColor3 = theme.ElementHover,
				BackgroundTransparency = 0.5,
				Size = UDim2.new(1, 0, 0, 28),
				Parent = list,
			}, { corner(5) })
			item.MouseEnter:Connect(function()
				tween(item, 0.1, { BackgroundTransparency = 0 })
			end)
			item.MouseLeave:Connect(function()
				tween(item, 0.1, { BackgroundTransparency = 0.5 })
			end)
			item.MouseButton1Click:Connect(function()
				obj:Set(option)
				setOpen(false)
			end)
		end
	end

	function obj:Set(v, silent)
		selected = v
		valueLabel.Text = tostring(v)
		rebuild()
		if not silent and opts.Callback then
			task.spawn(opts.Callback, v)
		end
	end
	function obj:Get()
		return selected
	end
	function obj:SetOptions(newOptions)
		options = newOptions
		if not table.find(options, selected) then
			selected = nil
			valueLabel.Text = "Select…"
		end
		rebuild()
		if open then
			setOpen(true)
		end
	end

	header.MouseButton1Click:Connect(function()
		setOpen(not open)
	end)
	rebuild()
	return obj
end

function Tab:AddTextbox(opts)
	local theme = self.Theme
	local frame = self:_element(36)
	self:_label(frame, opts.Text or "Textbox").Size = UDim2.new(0.5, -12, 1, 0)

	local boxBg = new("Frame", {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.new(0.5, -8, 0, 24),
		BackgroundColor3 = theme.Background,
		Parent = frame,
	}, { corner(5) })
	local boxStroke = stroke(theme.Stroke, 1)
	boxStroke.Parent = boxBg

	local box = new("TextBox", {
		Text = opts.Default or "",
		PlaceholderText = opts.Placeholder or "",
		PlaceholderColor3 = theme.SubText,
		ClearTextOnFocus = opts.ClearOnFocus == true,
		Font = theme.Font,
		TextSize = 13,
		TextColor3 = theme.Text,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -16, 1, 0),
		Position = UDim2.fromOffset(8, 0),
		ClipsDescendants = true,
		Parent = boxBg,
	})

	box.Focused:Connect(function()
		tween(boxStroke, 0.12, { Color = theme.Accent })
	end)
	box.FocusLost:Connect(function(enterPressed)
		tween(boxStroke, 0.12, { Color = theme.Stroke })
		if opts.Callback then
			task.spawn(opts.Callback, box.Text, enterPressed)
		end
	end)

	return {
		Set = function(_, t)
			box.Text = t
		end,
		Get = function()
			return box.Text
		end,
	}
end

function Tab:AddKeybind(opts)
	local theme = self.Theme
	local window = self.Window
	local key = opts.Default or false
	local listening = false
	local frame = self:_element(36)
	self:_label(frame, opts.Text or "Keybind").Size = UDim2.new(1, -110, 1, 0)

	local btn = new("TextButton", {
		Text = "",
		AutoButtonColor = false,
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.new(1, -8, 0.5, 0),
		Size = UDim2.fromOffset(90, 24),
		BackgroundColor3 = theme.Background,
		Parent = frame,
	}, { corner(5) })
	local btnStroke = stroke(theme.Stroke, 1)
	btnStroke.Parent = btn
	local btnLabel = new("TextLabel", {
		Font = theme.Font,
		TextSize = 13,
		TextColor3 = theme.Text,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = btn,
	})

	local obj = {}
	local function render()
		if listening then
			btnLabel.Text = "press a key…"
			btnLabel.TextColor3 = theme.Accent
			btnStroke.Color = theme.Accent
		else
			btnLabel.Text = key and key.Name or "None"
			btnLabel.TextColor3 = key and theme.Text or theme.SubText
			btnStroke.Color = theme.Stroke
		end
	end
	function obj:Set(k, silent)
		key = k or false
		render()
		if not silent and opts.Callback then
			task.spawn(opts.Callback, key)
		end
	end
	function obj:Get()
		return key
	end

	local listenConn
	local function stopListening()
		listening = false
		if listenConn then
			listenConn:Disconnect()
			listenConn = nil
		end
		-- clear the global flag a moment later so the key that was just bound
		-- doesn't also trigger its old action in the same frame
		task.defer(function()
			window._listening = false
		end)
		render()
	end

	hoverEffect(btn, btn, theme.Background, theme.ElementHover)
	btn.MouseButton1Click:Connect(function()
		if listening then
			stopListening()
			return
		end
		listening = true
		window._listening = true
		render()
		listenConn = UserInputService.InputBegan:Connect(function(input)
			if input.UserInputType ~= Enum.UserInputType.Keyboard then
				return
			end
			local k = input.KeyCode
			if k == Enum.KeyCode.Escape then
				stopListening() -- cancel, keep old key
			elseif k == Enum.KeyCode.Backspace then
				stopListening()
				obj:Set(false)
			else
				stopListening()
				obj:Set(k)
			end
		end)
	end)
	table.insert(window._connections, {
		Disconnect = function()
			if listenConn then
				listenConn:Disconnect()
			end
		end,
	})

	render()
	return obj
end

----------------------------------------------------------------------
-- EXAMPLE: delete everything below this line when making your own UI
----------------------------------------------------------------------

----------------------------------------------------------------------
-- Centralized Frame Management System
-- Reduces redundant per-frame work by caching and batching updates
----------------------------------------------------------------------
local FrameCache = {
	-- Player list cache (updated once per frame, shared by all systems)
	players = {},
	playersFrame = 0,
	
	-- Character cache (avoids repeated GetDescendants calls)
	charParts = {}, -- [character] = { parts = {}, frame = n }
	
	-- Humanoid root cache
	localRoot = nil,
	localChar = nil,
	localHum = nil,
	rootFrame = 0,
	
	-- Property change tracking (only write when values actually change)
	lastValues = {}, -- [instance] = { [property] = value }
}

-- Get all players (cached per frame)
function FrameCache:GetPlayers()
	local frame = workspace:GetServerTimeNow()
	if self.playersFrame ~= frame then
		self.players = Players:GetPlayers()
		self.playersFrame = frame
	end
	return self.players
end

-- Get local character components (cached)
function FrameCache:GetLocalCharacter()
	local frame = workspace:GetServerTimeNow()
	if self.rootFrame == frame and self.localRoot and self.localRoot.Parent then
		return self.localChar, self.localHum, self.localRoot
	end
	
	local char = Players.LocalPlayer.Character
	if not char then
		self.localChar, self.localHum, self.localRoot = nil, nil, nil
		return nil, nil, nil
	end
	
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	
	if hum and root then
		self.localChar, self.localHum, self.localRoot = char, hum, root
		self.rootFrame = frame
		return char, hum, root
	end
	
	self.localChar, self.localHum, self.localRoot = nil, nil, nil
	return nil, nil, nil
end

-- Get character parts (cached, reused across multiple systems)
function FrameCache:GetCharacterParts(character, maxAge)
	maxAge = maxAge or 20
	local frame = workspace:GetServerTimeNow()
	local entry = self.charParts[character]
	
	if entry and frame - entry.frame < maxAge and entry.parts[1] and entry.parts[1].Parent then
		return entry.parts
	end
	
	local parts = {}
	for _, d in ipairs(character:GetDescendants()) do
		if d:IsA("BasePart") then
			table.insert(parts, d)
		end
	end
	
	self.charParts[character] = { parts = parts, frame = frame }
	return parts
end

-- Only set a property if it actually changed
function FrameCache:SetProperty(instance, property, value)
	local key = instance
	if not self.lastValues[key] then
		self.lastValues[key] = {}
	end
	
	local last = self.lastValues[key][property]
	if last ~= value then
		instance[property] = value
		self.lastValues[key][property] = value
		return true
	end
	return false
end

-- Clear stale character caches
function FrameCache:CleanCharacterCache()
	for char, entry in pairs(self.charParts) do
		if not char.Parent then
			self.charParts[char] = nil
		end
	end
end

local function loadHub()
	----------------------------------------------------------------------
	-- Keybinds: saved to a file in the executor's workspace folder (like
	-- Infinite Yield's IY_FE.iy) and loaded again on the next run.
	----------------------------------------------------------------------
	local HttpService = game:GetService("HttpService")
	local SAVE_FILE = "cats_universal_hub_keybinds.json"
	local canSave = type(writefile) == "function" and type(readfile) == "function" and type(isfile) == "function"

	local Keys = {
		ToggleUI = Enum.KeyCode.Insert,
		FlyToggle = Enum.KeyCode.F,
		VFlyToggle = Enum.KeyCode.V,
		Sprint = Enum.KeyCode.R,
		SavePlayer = Enum.KeyCode.T,
		Fling = Enum.KeyCode.Z,
		AimbotToggle = Enum.KeyCode.C,
		Forward = Enum.KeyCode.W,
		Back = Enum.KeyCode.S,
		Left = Enum.KeyCode.A,
		Right = Enum.KeyCode.D,
		Up = Enum.KeyCode.E,
		Down = Enum.KeyCode.Q,
	}

	-- other settings kept in the same save file
	local Saved = { Chillax = false, Volumes = {}, KeepHub = false, Aimbot = {}, ESP = {} }

	local function saveKeys()
		if not canSave then
			return
		end
		local data = {}
		for name, key in pairs(Keys) do
			data[name] = key and key.Name or false -- false = unbound
		end
		data.Settings = Saved
		pcall(function()
			writefile(SAVE_FILE, HttpService:JSONEncode(data))
		end)
	end

	-- sliders fire constantly while dragged, so the file is written once things settle
	local saveQueued = false
	local function queueSave()
		if saveQueued then
			return
		end
		saveQueued = true
		task.delay(0.6, function()
			saveQueued = false
			saveKeys()
		end)
	end

	-- copies saved values into a settings table, ignoring anything outside the allowed values
	local function applySaved(target, saved, spec)
		for key, rule in pairs(spec) do
			local v = saved[key]
			if rule.bool then
				if type(v) == "boolean" then
					target[key] = v
				end
			elseif rule.options then
				if table.find(rule.options, v) then
					target[key] = v
				end
			elseif type(v) == "number" then
				target[key] = math.clamp(v, rule.min, rule.max)
			end
		end
	end

	local function loadKeys()
		if not canSave then
			return
		end
		pcall(function()
			if not isfile(SAVE_FILE) then
				return
			end
			local data = HttpService:JSONDecode(readfile(SAVE_FILE))
			if type(data.Settings) == "table" and type(data.Settings.Chillax) == "boolean" then
				Saved.Chillax = data.Settings.Chillax
			end
			if type(data.Settings) == "table" and type(data.Settings.Volumes) == "table" then
				for k, v in pairs(data.Settings.Volumes) do
					if type(k) == "string" and type(v) == "number" then
						Saved.Volumes[k] = math.clamp(v, 0, 200)
					end
				end
			end
			if type(data.Settings) == "table" and type(data.Settings.KeepHub) == "boolean" then
				Saved.KeepHub = data.Settings.KeepHub
			end
			-- Aimbot / ESP settings: checked against the allowed values when each tab is built
			for _, group in ipairs({ "Aimbot", "ESP" }) do
				if type(data.Settings) == "table" and type(data.Settings[group]) == "table" then
					for k, v in pairs(data.Settings[group]) do
						if type(k) == "string" then
							Saved[group][k] = v
						end
					end
				end
			end
			for name in pairs(Keys) do
				local saved = data[name]
				if saved == false then
					Keys[name] = false
				elseif type(saved) == "string" then
					local ok, kc = pcall(function()
						return Enum.KeyCode[saved]
					end)
					if ok and kc then
						Keys[name] = kc
					end
				end
			end
		end)
	end
	loadKeys()

	local window = UILib.new({
		Title = "cat's universal hub",
		ToggleKey = Keys.ToggleUI,
		Scale = 1.3, -- bigger UI (1 = original size)
		Theme = { Accent = Color3.fromRGB(255, 96, 140) }, -- optional overrides
	})

	----------------------------------------------------------------------
	-- Fly / vehicle fly from Infinite Yield (BodyVelocity + BodyGyro).
	-- Vehicle fly skips PlatformStand so you stay seated.
	----------------------------------------------------------------------
	local RunService = game:GetService("RunService")

	local function getCharacter()
		local char = Players.LocalPlayer.Character
		if not char then
			return nil
		end
		local hum = char:FindFirstChildOfClass("Humanoid")
		local root = char:FindFirstChild("HumanoidRootPart")
		if hum and root then
			return char, hum, root
		end
		return nil
	end

	local function getRoot(char)
		if char and char:FindFirstChildOfClass("Humanoid") then
			return char:FindFirstChildOfClass("Humanoid").RootPart
		end
		return nil
	end

	local IsOnMobile = UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled
	pcall(function()
		IsOnMobile = table.find({ Enum.Platform.Android, Enum.Platform.IOS }, UserInputService:GetPlatform()) ~= nil
	end)

	local FLYING = false
	local QEfly = true
	local iyflyspeed = 1
	local vehicleflyspeed = 1
	local flyKeyDown, flyKeyUp
	local mfly1, mfly2
	local velocityHandlerName = "IYFlyBV"
	local gyroHandlerName = "IYFlyBG"
	local flyMode = nil -- "fly" | "vfly" | nil
	local flyToggle -- assigned when the menu toggle is created below
	local vflyToggle

	local function NOFLY()
		FLYING = false
		if flyKeyDown then
			flyKeyDown:Disconnect()
			flyKeyDown = nil
		end
		if flyKeyUp then
			flyKeyUp:Disconnect()
			flyKeyUp = nil
		end
		local _, hum = getCharacter()
		if hum then
			hum.PlatformStand = false
		end
		pcall(function()
			workspace.CurrentCamera.CameraType = Enum.CameraType.Custom
		end)
	end

	local function unmobilefly(speaker)
		pcall(function()
			FLYING = false
			local root = getRoot(speaker.Character)
			if root then
				local bv = root:FindFirstChild(velocityHandlerName)
				local bg = root:FindFirstChild(gyroHandlerName)
				if bv then
					bv:Destroy()
				end
				if bg then
					bg:Destroy()
				end
			end
			local hum = speaker.Character and speaker.Character:FindFirstChildWhichIsA("Humanoid")
			if hum then
				hum.PlatformStand = false
			end
			if mfly1 then
				mfly1:Disconnect()
				mfly1 = nil
			end
			if mfly2 then
				mfly2:Disconnect()
				mfly2 = nil
			end
		end)
	end

	local function sFLY(vfly)
		local plr = Players.LocalPlayer
		local char = plr.Character
		if not char then
			return false
		end
		local humanoid = char:FindFirstChildOfClass("Humanoid")
		if not humanoid then
			return false
		end

		if flyKeyDown or flyKeyUp then
			if flyKeyDown then
				flyKeyDown:Disconnect()
			end
			if flyKeyUp then
				flyKeyUp:Disconnect()
			end
		end

		local T = getRoot(char)
		if not T then
			return false
		end
		local CONTROL = { F = 0, B = 0, L = 0, R = 0, Q = 0, E = 0 }
		local lCONTROL = { F = 0, B = 0, L = 0, R = 0, Q = 0, E = 0 }
		local SPEED = 0

		local function FLY()
			FLYING = true
			local BG = Instance.new("BodyGyro")
			local BV = Instance.new("BodyVelocity")
			BG.P = 9e4
			BG.Parent = T
			BV.Parent = T
			BG.MaxTorque = Vector3.new(9e9, 9e9, 9e9)
			BG.CFrame = T.CFrame
			BV.Velocity = Vector3.new(0, 0, 0)
			BV.MaxForce = Vector3.new(9e9, 9e9, 9e9)
			task.spawn(function()
				repeat
					task.wait()
					local camera = workspace.CurrentCamera
					if not vfly and humanoid then
						humanoid.PlatformStand = true
					end

					if CONTROL.L + CONTROL.R ~= 0 or CONTROL.F + CONTROL.B ~= 0 or CONTROL.Q + CONTROL.E ~= 0 then
						SPEED = 50
					elseif not (CONTROL.L + CONTROL.R ~= 0 or CONTROL.F + CONTROL.B ~= 0 or CONTROL.Q + CONTROL.E ~= 0) and SPEED ~= 0 then
						SPEED = 0
					end
					if (CONTROL.L + CONTROL.R) ~= 0 or (CONTROL.F + CONTROL.B) ~= 0 or (CONTROL.Q + CONTROL.E) ~= 0 then
						BV.Velocity = ((camera.CFrame.LookVector * (CONTROL.F + CONTROL.B)) + ((camera.CFrame * CFrame.new(CONTROL.L + CONTROL.R, (CONTROL.F + CONTROL.B + CONTROL.Q + CONTROL.E) * 0.2, 0).Position) - camera.CFrame.Position)) * SPEED
						lCONTROL = { F = CONTROL.F, B = CONTROL.B, L = CONTROL.L, R = CONTROL.R }
					elseif (CONTROL.L + CONTROL.R) == 0 and (CONTROL.F + CONTROL.B) == 0 and (CONTROL.Q + CONTROL.E) == 0 and SPEED ~= 0 then
						BV.Velocity = ((camera.CFrame.LookVector * (lCONTROL.F + lCONTROL.B)) + ((camera.CFrame * CFrame.new(lCONTROL.L + lCONTROL.R, (lCONTROL.F + lCONTROL.B + CONTROL.Q + CONTROL.E) * 0.2, 0).Position) - camera.CFrame.Position)) * SPEED
					else
						BV.Velocity = Vector3.new(0, 0, 0)
					end
					BG.CFrame = camera.CFrame
				until not FLYING
				CONTROL = { F = 0, B = 0, L = 0, R = 0, Q = 0, E = 0 }
				lCONTROL = { F = 0, B = 0, L = 0, R = 0, Q = 0, E = 0 }
				SPEED = 0
				BG:Destroy()
				BV:Destroy()
				if humanoid then
					humanoid.PlatformStand = false
				end
			end)
		end

		flyKeyDown = UserInputService.InputBegan:Connect(function(input, processed)
			if processed or window._listening then
				return
			end
			local speed = vfly and vehicleflyspeed or iyflyspeed
			local kc = input.KeyCode
			if kc == Keys.Forward then
				CONTROL.F = speed
			elseif kc == Keys.Back then
				CONTROL.B = -speed
			elseif kc == Keys.Left then
				CONTROL.L = -speed
			elseif kc == Keys.Right then
				CONTROL.R = speed
			elseif kc == Keys.Up and QEfly then
				CONTROL.Q = speed * 2
			elseif kc == Keys.Down and QEfly then
				CONTROL.E = -speed * 2
			end
			pcall(function()
				workspace.CurrentCamera.CameraType = Enum.CameraType.Track
			end)
		end)

		flyKeyUp = UserInputService.InputEnded:Connect(function(input, processed)
			if processed then
				return
			end
			local kc = input.KeyCode
			if kc == Keys.Forward then
				CONTROL.F = 0
			elseif kc == Keys.Back then
				CONTROL.B = 0
			elseif kc == Keys.Left then
				CONTROL.L = 0
			elseif kc == Keys.Right then
				CONTROL.R = 0
			elseif kc == Keys.Up then
				CONTROL.Q = 0
			elseif kc == Keys.Down then
				CONTROL.E = 0
			end
		end)
		FLY()
		return true
	end

	local function mobilefly(speaker, vfly)
		unmobilefly(speaker)
		local root = getRoot(speaker.Character)
		if not root then
			return false
		end
		FLYING = true

		local camera = workspace.CurrentCamera
		local v3none = Vector3.new()
		local v3zero = Vector3.new(0, 0, 0)
		local v3inf = Vector3.new(9e9, 9e9, 9e9)

		local ok, controlModule = pcall(function()
			return require(speaker.PlayerScripts:WaitForChild("PlayerModule"):WaitForChild("ControlModule"))
		end)
		if not ok or not controlModule then
			return sFLY(vfly)
		end

		local function attachHandlers(part)
			local bv = Instance.new("BodyVelocity")
			bv.Name = velocityHandlerName
			bv.Parent = part
			bv.MaxForce = v3zero
			bv.Velocity = v3zero

			local bg = Instance.new("BodyGyro")
			bg.Name = gyroHandlerName
			bg.Parent = part
			bg.MaxTorque = v3inf
			bg.P = 1000
			bg.D = 50
		end

		attachHandlers(root)

		mfly1 = speaker.CharacterAdded:Connect(function(char)
			local newRoot = char:WaitForChild("HumanoidRootPart", 5)
			if newRoot then
				attachHandlers(newRoot)
			end
		end)

		mfly2 = RunService.RenderStepped:Connect(function()
			root = getRoot(speaker.Character)
			camera = workspace.CurrentCamera
			if speaker.Character and speaker.Character:FindFirstChildWhichIsA("Humanoid") and root and root:FindFirstChild(velocityHandlerName) and root:FindFirstChild(gyroHandlerName) then
				local humanoid = speaker.Character:FindFirstChildWhichIsA("Humanoid")
				local VelocityHandler = root:FindFirstChild(velocityHandlerName)
				local GyroHandler = root:FindFirstChild(gyroHandlerName)

				VelocityHandler.MaxForce = v3inf
				GyroHandler.MaxTorque = v3inf
				if not vfly then
					humanoid.PlatformStand = true
				end
				GyroHandler.CFrame = camera.CFrame
				VelocityHandler.Velocity = v3none

				local direction = controlModule:GetMoveVector()
				local speed = (vfly and vehicleflyspeed or iyflyspeed) * 50
				if direction.X ~= 0 then
					VelocityHandler.Velocity += camera.CFrame.RightVector * (direction.X * speed)
				end
				if direction.Z ~= 0 then
					VelocityHandler.Velocity -= camera.CFrame.LookVector * (direction.Z * speed)
				end
			end
		end)
		return true
	end

	local function stopFly()
		flyMode = nil
		if IsOnMobile then
			unmobilefly(Players.LocalPlayer)
		else
			NOFLY()
			unmobilefly(Players.LocalPlayer)
		end
	end

	local function startFly(vfly)
		if not getCharacter() then
			return false
		end
		stopFly()
		task.wait()
		local ok
		if IsOnMobile then
			ok = mobilefly(Players.LocalPlayer, vfly)
		else
			ok = sFLY(vfly)
		end
		if ok then
			flyMode = vfly and "vfly" or "fly"
		end
		return ok and true or false
	end

	local function setFly(on)
		if on then
			if vflyToggle and vflyToggle:Get() then
				vflyToggle:Set(false, true)
			end
			if not startFly(false) then
				return false
			end
		elseif flyMode ~= "vfly" then
			stopFly()
		end
		return true
	end

	local function setVehicleFly(on)
		if on then
			if flyToggle and flyToggle:Get() then
				flyToggle:Set(false, true)
			end
			if not startFly(true) then
				return false
			end
		else
			if flyMode == "vfly" or flyMode == nil then
				stopFly()
			end
		end
		return true
	end

	-- keep flying after a respawn
	local respawnConn = Players.LocalPlayer.CharacterAdded:Connect(function(char)
		if flyMode then
			local vfly = flyMode == "vfly"
			char:WaitForChild("Humanoid")
			char:WaitForChild("HumanoidRootPart")
			startFly(vfly)
		end
	end)

	-- toggles flight / vehicle flight (keys set in Settings, default F / V)
	local flyKeyConn = UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and not window._listening and Keys.FlyToggle and input.KeyCode == Keys.FlyToggle and flyToggle then
			flyToggle:Set(not flyToggle:Get())
		end
		if not processed and not window._listening and Keys.VFlyToggle and input.KeyCode == Keys.VFlyToggle and vflyToggle then
			vflyToggle:Set(not vflyToggle:Get())
		end
	end)

	-- removing the UI also stops flying and cleans up
	window.Gui.Destroying:Connect(function()
		stopFly()
		respawnConn:Disconnect()
		flyKeyConn:Disconnect()
	end)

	----------------------------------------------------------------------
	-- Keep hub after teleport (same method as Infinite Yield's "keepiy"):
	-- hooks LocalPlayer.OnTeleport and, once per teleport, uses
	-- queue_on_teleport to queue a loadstring of the hub's raw GitHub URL, so
	-- the hub starts itself again in the next server. Rejoin calls
	-- queueHubReload() too. Only the on/off state is saved to the save file;
	-- the reloaded hub reads it, so it stays on. addKeepHubToggle(tab) adds the
	-- toggle to any tab, and all copies stay in sync.
	----------------------------------------------------------------------
	local queueHubReload, addKeepHubToggle
	do
		local queueTp = queue_on_teleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
		local queued = false -- queue only once, like keepiy's TeleportCheck
		local toggles = {}

		queueHubReload = function()
			if Saved.KeepHub and queueTp and not queued then
				queued = true
				queueTp(
					"local ok, err = pcall(function() loadstring(game:HttpGet('"
						.. HUB_URL
						.. "'))() end) if not ok then warn('Keep hub: could not reload the hub: ' .. tostring(err)) end"
				)
			end
		end

		local tpConn = Players.LocalPlayer.OnTeleport:Connect(queueHubReload)
		window.Gui.Destroying:Connect(function()
			tpConn:Disconnect()
		end)

		addKeepHubToggle = function(tab)
			local toggle
			toggle = tab:AddToggle({
				Text = "Keep hub after teleport / rejoin",
				Default = Saved.KeepHub and queueTp ~= nil,
				Callback = function(on)
					if on and not queueTp then
						Saved.KeepHub = false
						for _, t in ipairs(toggles) do
							t:Set(false, true)
						end
						window:Notify({
							Title = "Keep hub",
							Text = "Your executor has no queue_on_teleport, so this can't work.",
							Duration = 4,
						})
						return
					end
					Saved.KeepHub = on
					for _, t in ipairs(toggles) do
						if t ~= toggle then
							t:Set(on, true)
						end
					end
					saveKeys()
					if on then
						-- make sure HUB_URL really serves the script, otherwise the reload would fail silently
						task.spawn(function()
							local ok, src = pcall(function()
								return game:HttpGet(HUB_URL)
							end)
							if not ok or type(src) ~= "string" or #src < 1000 or src:sub(1, 3) == "404" then
								Saved.KeepHub = false
								for _, t in ipairs(toggles) do
									t:Set(false, true)
								end
								saveKeys()
								window:Notify({
									Title = "Keep hub",
									Text = "Couldn't load the hub from HUB_URL (top of the script). Upload universal.lua there or change the link.",
									Duration = 7,
								})
							end
						end)
					end
				end,
			})
			table.insert(toggles, toggle)
			return toggle
		end
	end

	local main = window:AddTab("Main")
	local player = window:AddTab("Player")

	-- handles filled in further down; Chillax mode drives them
	local antiFlingToggle, gloomToggle, shootingStarsToggle, chillaxToggle
	local function setChillax(on)
		if antiFlingToggle then
			antiFlingToggle:Set(on)
		end
		if gloomToggle then
			gloomToggle:Set(on)
		end
		if shootingStarsToggle then
			shootingStarsToggle:Set(on)
		end
	end

	main:AddSection("Modes")
	chillaxToggle = main:AddToggle({
		Text = "Chillax mode",
		Default = Saved.Chillax,
		Callback = function(on)
			setChillax(on)
			Saved.Chillax = on
			saveKeys()
		end,
	})

	----------------------------------------------------------------------
	-- Save player: while the toggle is on, whoever is under your aim (the mouse,
	-- or the screen centre when the mouse is locked / on touch) gets a box drawn
	-- around them. Press the key to go under them and lift them (speed and height
	-- are sliders), lying
	-- face down so they stand on your back; press it again to let go.
	-- The Put down buttons lower them onto the floor (found with a raycast
	-- straight down) and then let go.
	-- On mobile there's no hotkey: an on-screen button and a centre-screen ring
	-- replace the key and the mouse.
	----------------------------------------------------------------------
	do
		local liftHeight = 250 -- how far above the start point to rise, in studs (slider)
		local liftSpeed = 9 -- studs per second (slider)
		local UNDER = 0.6 -- our back sits this far under their feet
		local LEAD = 1 -- never get more than this far ahead of their feet
		local PREDICT = 0.06 -- seconds of look-ahead so we don't lag behind a moving target
		local MAX_PREDICT = 6 -- cap on that look-ahead, in studs
		local TURN_RATE = 10 -- how quickly we rotate to match their facing (higher = snappier)
		local hovered = nil -- player under the aim
		local carrying = nil -- player being lifted
		local box = nil
		local aimConn, keyConn, stepConn, beatConn, addedConn
		local actionBtn, crosshair -- mobile-only on-screen controls
		local baseY, carryLift, carryTime = 0, 0, 0
		local lowerFloor = nil -- while set, the lift heads for this floor height instead of liftHeight
		local lowerReached = nil -- carryTime at which the lift got to that floor
		local FLOOR_RAY_RANGE = 3000 -- how far down the floor search reaches
		local smoothFwd = nil -- smoothed facing so we don't whip around when they turn
		local lastCF = nil -- latest target CFrame, re-applied right before each physics step
		local myParts = {} -- our own parts, cached so we don't scan the whole character every frame
		local noclipParts = setmetatable({}, { __mode = "k" })

		local function setBox(char)
			if not char then
				if box then
					box.Adornee = nil
				end
				return
			end
			if not box then
				box = Instance.new("SelectionBox")
				box.Name = "SavePlayerBox"
				box.Color3 = window.Theme.Accent
				box.LineThickness = 0.06
				box.SurfaceTransparency = 1
				box.Parent = workspace
			end
			box.Adornee = char
		end

		local function playerFromPart(part)
			local model = part:FindFirstAncestorOfClass("Model")
			while model do
				local plr = Players:GetPlayerFromCharacter(model)
				if plr then
					return plr
				end
				model = model.Parent and model.Parent:FindFirstAncestorOfClass("Model")
			end
			return nil
		end

		local function pickTarget()
			local cam = workspace.CurrentCamera
			if not cam then
				return nil
			end
			local point
			if IsOnMobile or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter then
				point = cam.ViewportSize / 2
			else
				point = UserInputService:GetMouseLocation()
			end
			local ray = cam:ViewportPointToRay(point.X, point.Y)
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			local ignore = {}
			if Players.LocalPlayer.Character then
				table.insert(ignore, Players.LocalPlayer.Character)
			end
			if box then
				table.insert(ignore, box)
			end
			params.FilterDescendantsInstances = ignore
			local hit = workspace:Raycast(ray.Origin, ray.Direction * 600, params)
			local plr = hit and playerFromPart(hit.Instance)
			if plr and plr ~= Players.LocalPlayer and plr.Character then
				local hum = plr.Character:FindFirstChildOfClass("Humanoid")
				if hum and hum.Health > 0 then
					return plr
				end
			end
			return nil
		end

		local function zeroVelocity(root)
			root.AssemblyLinearVelocity = Vector3.zero
			root.AssemblyAngularVelocity = Vector3.zero
		end

		local function stopCarry(silent)
			if not carrying then
				return
			end
			local name = carrying.Name
			carrying = nil
			lowerFloor, lowerReached = nil, nil
			if stepConn then
				stepConn:Disconnect()
				stepConn = nil
			end
			if beatConn then
				beatConn:Disconnect()
				beatConn = nil
			end
			if addedConn then
				addedConn:Disconnect()
				addedConn = nil
			end
			for part, was in pairs(noclipParts) do
				if part.Parent then
					part.CanCollide = was
				end
			end
			table.clear(noclipParts)
			table.clear(myParts)
			smoothFwd, lastCF = nil, nil

			local _, hum, root = getCharacter()
			if hum then
				hum.PlatformStand = false
			end
			if root then
				-- stand back up next to them (not inside them)
				local head = root.CFrame.UpVector
				local fwd = Vector3.new(head.X, 0, head.Z)
				fwd = fwd.Magnitude > 0.01 and fwd.Unit or Vector3.new(0, 0, -1)
				local side = fwd:Cross(Vector3.yAxis) * 3.5
				local p = root.Position + side + Vector3.new(0, 3, 0)
				root.CFrame = CFrame.lookAt(p, p + fwd)
				zeroVelocity(root)
			end
			if not silent then
				window:Notify({ Title = "Save player", Text = "Let go of " .. name, Duration = 3 })
			end
		end

		local function startCarry(plr)
			if FLYING then
				window:Notify({ Title = "Save player", Text = "Turn fly off first.", Duration = 3 })
				return
			end
			local tChar = plr.Character
			local tHum = tChar and tChar:FindFirstChildOfClass("Humanoid")
			local tRoot = tChar and tChar:FindFirstChild("HumanoidRootPart")
			local myChar, hum, root = getCharacter()
			if not (tHum and tRoot and hum and root and myChar) then
				window:Notify({ Title = "Save player", Text = "Can't reach that player.", Duration = 3 })
				return
			end
			carrying = plr
			carryLift, carryTime = 0, 0
			lowerFloor, lowerReached = nil, nil
			smoothFwd, lastCF = nil, nil
			local feet = tRoot.Position.Y - (tHum.HipHeight + tRoot.Size.Y / 2)
			baseY = feet - UNDER
			hum.PlatformStand = true

			-- cache our parts once (and pick up accessories added later) instead of
			-- walking the whole character every physics step
			table.clear(myParts)
			for _, d in ipairs(myChar:GetDescendants()) do
				if d:IsA("BasePart") then
					table.insert(myParts, d)
				end
			end
			addedConn = myChar.DescendantAdded:Connect(function(d)
				if d:IsA("BasePart") then
					table.insert(myParts, d)
				end
			end)

			-- Runs right before each physics step: keep our character no-clip so the floor
			-- doesn't fight us, and re-apply the target position so physics never gets a
			-- frame to push us off it (this is what removes most of the jitter).
			stepConn = RunService.Stepped:Connect(function()
				for _, part in ipairs(myParts) do
					if part.Parent and part.CanCollide then
						noclipParts[part] = true
						part.CanCollide = false
					end
				end
				if lastCF then
					local _, _, r = getCharacter()
					if r then
						r.CFrame = lastCF
						zeroVelocity(r)
					end
				end
			end)

			beatConn = RunService.Heartbeat:Connect(function(dt)
				dt = math.min(dt, 0.1)
				local _, myHum, myRoot = getCharacter()
				local char = carrying and carrying.Character
				local theirRoot = char and char:FindFirstChild("HumanoidRootPart")
				local theirHum = char and char:FindFirstChildOfClass("Humanoid")
				if not (myHum and myRoot and theirRoot and theirHum) or myHum.Health <= 0 or theirHum.Health <= 0 then
					stopCarry()
					return
				end
				if FLYING then
					stopCarry()
					return
				end
				if not myHum.PlatformStand then
					myHum.PlatformStand = true -- something reset it; keep us ragdolled
				end

				-- ease in at the start, ease out near the target height, and move
				-- up or down if the height slider changes mid-lift
				carryTime = carryTime + dt
				-- normally head for the lift height; after a Put down button, head for that floor
				-- (their feet end up on it, the same offset as when the lift started)
				local goal = lowerFloor and (lowerFloor - baseY - UNDER) or liftHeight
				local dist = goal - carryLift
				local ramp = math.clamp(carryTime / 1.0, 0.15, 1) * math.clamp(math.abs(dist) / 5, 0.1, 1)
				local stepAmt = liftSpeed * ramp * dt
				local atGoal = false
				if math.abs(dist) <= stepAmt then
					carryLift = goal
					atGoal = true
				else
					carryLift = carryLift + (dist > 0 and 1 or -1) * stepAmt
				end

				local theirFeet = theirRoot.Position.Y - (theirHum.HipHeight + theirRoot.Size.Y / 2)
				-- Their character reaches us a moment late (network delay), so their feet always trail
				-- behind ours while we rise. A fixed 1 stud leash therefore capped the real speed at
				-- whatever the lag allowed, no matter the slider. Let the leash grow with speed and ping.
				local okPing, ping = pcall(function()
					return Players.LocalPlayer:GetNetworkPing()
				end)
				local lag = math.clamp((okPing and ping or 0.1) * 2 + 0.2, 0.2, 0.8)
				local maxLead = math.max(LEAD, liftSpeed * lag)
				local y = math.min(baseY + carryLift, theirFeet - UNDER + maxLead)
				-- if the leash held us back, don't keep counting lift we didn't make (no sudden leap later)
				carryLift = math.min(carryLift, y - baseY)

				-- stay slightly ahead of where they're walking
				local vel = theirRoot.AssemblyLinearVelocity
				local ahead = Vector3.new(vel.X, 0, vel.Z) * PREDICT
				if ahead.Magnitude > MAX_PREDICT then
					ahead = ahead.Unit * MAX_PREDICT
				end
				local pos = Vector3.new(theirRoot.Position.X + ahead.X, y, theirRoot.Position.Z + ahead.Z)

				-- smoothed facing
				local look = theirRoot.CFrame.LookVector
				local want = Vector3.new(look.X, 0, look.Z)
				if want.Magnitude > 0.01 then
					want = want.Unit
				else
					want = smoothFwd or Vector3.new(0, 0, -1)
				end
				if smoothFwd then
					local blended = smoothFwd:Lerp(want, 1 - math.exp(-TURN_RATE * dt))
					smoothFwd = blended.Magnitude > 0.01 and blended.Unit or want
				else
					smoothFwd = want
				end

				-- face the floor, head pointing the way they face, back up under their feet
				lastCF = CFrame.lookAt(pos, pos + Vector3.new(0, -1, 0), smoothFwd)
				myRoot.CFrame = lastCF
				zeroVelocity(myRoot)

				-- put-down finished once they're standing on the floor: let go automatically
				if lowerFloor then
					if atGoal and not lowerReached then
						lowerReached = carryTime
					end
					if lowerReached and (theirFeet - lowerFloor < 2 or carryTime - lowerReached > 3) then
						local name = carrying.Name
						stopCarry(true)
						window:Notify({ Title = "Save player", Text = "Put " .. name .. " down.", Duration = 3 })
					end
				end
			end)
			window:Notify({ Title = "Save player", Text = "Lifting " .. plr.Name .. " - press the key again to let go.", Duration = 4 })
		end

		-- feet height of whoever we're carrying
		local function carriedFeetY()
			local char = carrying and carrying.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			local root = char and char:FindFirstChild("HumanoidRootPart")
			if hum and root then
				return root.Position.Y - (hum.HipHeight + root.Size.Y / 2)
			end
			return nil
		end

		-- the floor search ignores every character (nobody's head counts as floor)
		local function floorRayParams()
			local params = RaycastParams.new()
			params.FilterType = Enum.RaycastFilterType.Exclude
			params.RespectCanCollide = true
			local filter = {}
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr.Character then
					table.insert(filter, plr.Character)
				end
			end
			params.FilterDescendantsInstances = filter
			return params
		end

		-- lower (or raise) the carried player until their feet are on floorY, then let go
		local function putDownOn(floorY, label)
			if not carrying then
				window:Notify({ Title = "Save player", Text = "Lift a player first.", Duration = 3 })
				return
			end
			lowerFloor, lowerReached = floorY, nil
			window:Notify({
				Title = "Save player",
				Text = string.format("Putting %s down on %s (y %.0f)...", carrying.Name, label, floorY),
				Duration = 3,
			})
		end

		-- raycast straight down from us (we're right under them) to find the floor, and how far to go down
		local function putDownOnFloorBelow()
			if not carrying then
				window:Notify({ Title = "Save player", Text = "Lift a player first.", Duration = 3 })
				return
			end
			local _, _, myRoot = getCharacter()
			local feet = carriedFeetY()
			if not (myRoot and feet) then
				window:Notify({ Title = "Save player", Text = "Can't reach that player.", Duration = 3 })
				return
			end
			local origin = myRoot.Position + Vector3.new(0, 2, 0)
			local result = workspace:Raycast(origin, Vector3.new(0, -FLOOR_RAY_RANGE, 0), floorRayParams())
			if not result then
				window:Notify({
					Title = "Save player",
					Text = string.format("No floor found within %d studs below.", FLOOR_RAY_RANGE),
					Duration = 4,
				})
				return
			end
			if result.Material == Enum.Material.Water then
				window:Notify({
					Title = "Save player",
					Text = string.format("Only water below (surface at y %.1f), not lowering.", result.Position.Y),
					Duration = 4,
				})
				return
			end
			lowerFloor, lowerReached = result.Position.Y, nil
			window:Notify({
				Title = "Save player",
				Text = string.format(
					"Floor at y %.1f, %.1f studs down - lowering %s.",
					result.Position.Y,
					math.max(0, feet - result.Position.Y),
					carrying.Name
				),
				Duration = 4,
			})
		end

		local function trigger()
			if carrying then
				stopCarry()
			elseif hovered then
				startCarry(hovered)
			else
				window:Notify({ Title = "Save player", Text = "Aim at a player first.", Duration = 2 })
			end
		end

		local function destroyMobileUI()
			if actionBtn then
				actionBtn:Destroy()
				actionBtn = nil
			end
			if crosshair then
				crosshair:Destroy()
				crosshair = nil
			end
		end

		-- Touch has no hotkey, so mobile gets an on-screen button plus a crosshair
		-- marking the screen centre (that's where the aim ray is cast on mobile).
		local function buildMobileUI()
			destroyMobileUI()
			local theme = window.Theme

			crosshair = Instance.new("Frame")
			crosshair.Name = "SavePlayerCrosshair"
			crosshair.AnchorPoint = Vector2.new(0.5, 0.5)
			crosshair.Position = UDim2.fromScale(0.5, 0.5)
			crosshair.Size = UDim2.fromOffset(14, 14)
			crosshair.BackgroundTransparency = 1
			crosshair.Active = false
			local cCorner = Instance.new("UICorner")
			cCorner.CornerRadius = UDim.new(1, 0)
			cCorner.Parent = crosshair
			local cStroke = Instance.new("UIStroke")
			cStroke.Name = "Ring"
			cStroke.Thickness = 2
			cStroke.Color = theme.Text
			cStroke.Transparency = 0.4
			cStroke.Parent = crosshair
			crosshair.Parent = window.Gui

			actionBtn = Instance.new("TextButton")
			actionBtn.Name = "SavePlayerButton"
			actionBtn.AnchorPoint = Vector2.new(1, 0.5)
			actionBtn.Position = UDim2.new(1, -24, 0.5, 0)
			actionBtn.Size = UDim2.fromOffset(88, 88)
			actionBtn.AutoButtonColor = false
			actionBtn.BackgroundColor3 = theme.Element
			actionBtn.BorderSizePixel = 0
			actionBtn.Font = theme.FontBold
			actionBtn.TextSize = 16
			actionBtn.TextColor3 = theme.SubText
			actionBtn.Text = "AIM"
			actionBtn.ZIndex = 10
			local bCorner = Instance.new("UICorner")
			bCorner.CornerRadius = UDim.new(1, 0)
			bCorner.Parent = actionBtn
			local bStroke = Instance.new("UIStroke")
			bStroke.Color = theme.Stroke
			bStroke.Thickness = 2
			bStroke.Parent = actionBtn
			actionBtn.Activated:Connect(trigger)
			actionBtn.Parent = window.Gui
		end

		local function updateMobileUI()
			if not (actionBtn and crosshair) then
				return
			end
			local theme = window.Theme
			local ring = crosshair:FindFirstChild("Ring")
			if carrying then
				actionBtn.Text = "LET GO"
				actionBtn.BackgroundColor3 = theme.Danger
				actionBtn.TextColor3 = theme.Text
			elseif hovered then
				actionBtn.Text = "LIFT"
				actionBtn.BackgroundColor3 = theme.Accent
				actionBtn.TextColor3 = theme.Text
			else
				actionBtn.Text = "AIM"
				actionBtn.BackgroundColor3 = theme.Element
				actionBtn.TextColor3 = theme.SubText
			end
			if ring then
				ring.Color = (carrying or hovered) and theme.Accent or theme.Text
				ring.Transparency = (carrying or hovered) and 0 or 0.4
			end
		end

		local function setEnabled(on)
			if aimConn then
				aimConn:Disconnect()
				aimConn = nil
			end
			if keyConn then
				keyConn:Disconnect()
				keyConn = nil
			end
			stopCarry(true)
			hovered = nil
			destroyMobileUI()
			if box then
				box:Destroy()
				box = nil
			end
			if not on then
				return
			end
			if IsOnMobile then
				buildMobileUI()
			end
			aimConn = RunService.RenderStepped:Connect(function()
				if carrying then
					setBox(carrying.Character)
				else
					hovered = pickTarget() -- on mobile this casts from the screen centre
					setBox(hovered and hovered.Character)
				end
				updateMobileUI()
			end)
			-- hotkey is desktop only; mobile uses the on-screen button
			if not IsOnMobile then
				keyConn = UserInputService.InputBegan:Connect(function(input, processed)
					if processed or window._listening or not Keys.SavePlayer or input.KeyCode ~= Keys.SavePlayer then
						return
					end
					trigger()
				end)
			end
		end

		window.Gui.Destroying:Connect(function()
			setEnabled(false)
		end)

		main:AddSection("Rescue")
		main:AddToggle({
			Text = "Save player",
			Default = false,
			Callback = setEnabled,
		})
		main:AddSlider({
			Text = "Lift speed",
			Min = 1, Max = 50, Default = liftSpeed, Step = 1, Suffix = " st/s",
			Callback = function(v)
				liftSpeed = v
			end,
		})
		main:AddSlider({
			Text = "Lift height",
			Min = 10, Max = 500, Default = liftHeight, Step = 10, Suffix = " studs",
			Callback = function(v)
				liftHeight = v
				lowerFloor, lowerReached = nil, nil -- moving the slider goes back to lifting to that height
			end,
		})
		main:AddButton({
			Text = "Put down on floor below",
			Callback = putDownOnFloorBelow,
		})
	end
	-- Sprint: press the sprint key (R by default, change it in Settings > Keybinds)
	-- to switch sprinting on, press it again to switch it off.
	local sprintEnabled = true
	local sprintSpeed = 28
	local sprintOn = false
	local sprintHum, sprintBase = nil, nil

	local function sprintRestore()
		if sprintHum and sprintBase and sprintHum.Parent then
			sprintHum.WalkSpeed = sprintBase
		end
		sprintHum, sprintBase = nil, nil
	end

	local sprintBeat = RunService.Heartbeat:Connect(function()
		if sprintEnabled and sprintOn then
			local _, hum = getCharacter()
			if not hum then
				return
			end
			if hum ~= sprintHum then
				sprintHum, sprintBase = hum, hum.WalkSpeed
			end
			if hum.WalkSpeed ~= sprintSpeed then
				hum.WalkSpeed = sprintSpeed
			end
		elseif sprintHum then
			sprintRestore()
		end
	end)
	local sprintBegan = UserInputService.InputBegan:Connect(function(input, processed)
		if sprintEnabled and not processed and not window._listening and Keys.Sprint and input.KeyCode == Keys.Sprint then
			sprintOn = not sprintOn
		end
	end)
	window.Gui.Destroying:Connect(function()
		sprintBeat:Disconnect()
		sprintBegan:Disconnect()
		sprintOn = false
		sprintRestore()
	end)

	player:AddSection("General")
	player:AddToggle({
		Text = "Sprint enabled",
		Default = true,
		Callback = function(on)
			sprintEnabled = on
			if not on then
				sprintOn = false
			end
		end,
	})
	player:AddSlider({
		Text = "Sprint speed",
		Min = 16, Max = 100, Default = sprintSpeed, Step = 1, Suffix = " st/s",
		Callback = function(v)
			sprintSpeed = v
		end,
	})
	-- Anti fling (from Infinite Yield, made faster): turns off collision on
	-- every other player's character so they can't fling you by touching you.
	-- Parts are tracked live (DescendantAdded) instead of re-scanned from a
	-- cache that could be stale, the check runs every Heartbeat, and a full
	-- rescan of every character happens every few seconds in case someone
	-- switches avatars or something slips past the live tracking.
	local antiFlingConns = {}
	local antiFlingChanged = setmetatable({}, { __mode = "k" })
	local antiFlingTracked = {} -- [player] = { parts = {[part]=true}, conns = {} }
	local ANTI_FLING_RESCAN_EVERY = 3 -- seconds between full rescans
	local antiFlingLastScan = 0
	local function afKill(part)
		if part.CanCollide then
			antiFlingChanged[part] = true
			part.CanCollide = false
		end
	end
	local function afUntrack(plr)
		local t = antiFlingTracked[plr]
		if t then
			for _, c in ipairs(t.conns) do
				c:Disconnect()
			end
			antiFlingTracked[plr] = nil
		end
	end
	local function afTrackCharacter(plr, char)
		afUntrack(plr)
		if not char then
			return
		end
		local t = { parts = {}, conns = {} }
		antiFlingTracked[plr] = t
		local function add(d)
			if d:IsA("BasePart") then
				t.parts[d] = true
				afKill(d) -- instantly, no waiting for the next frame
			end
		end
		for _, d in ipairs(char:GetDescendants()) do
			add(d)
		end
		table.insert(t.conns, char.DescendantAdded:Connect(add))
		table.insert(t.conns, char.DescendantRemoving:Connect(function(d)
			t.parts[d] = nil
		end))
	end
	local function afSweep()
		-- periodic full rescan: catches avatar switches and anything missed
		local now = os.clock()
		if now - antiFlingLastScan >= ANTI_FLING_RESCAN_EVERY then
			antiFlingLastScan = now
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr ~= Players.LocalPlayer and plr.Character then
					afTrackCharacter(plr, plr.Character)
				end
			end
		end
		for _, t in pairs(antiFlingTracked) do
			for part in pairs(t.parts) do
				if part.Parent then
					if part.CanCollide then
						antiFlingChanged[part] = true
						part.CanCollide = false
					end
				else
					t.parts[part] = nil
				end
			end
		end
	end
	local function setAntiFling(on)
		for _, c in ipairs(antiFlingConns) do
			c:Disconnect()
		end
		table.clear(antiFlingConns)
		for plr in pairs(antiFlingTracked) do
			afUntrack(plr)
		end
		if on then
			local function hookPlayer(plr)
				if plr == Players.LocalPlayer then
					return
				end
				afTrackCharacter(plr, plr.Character)
				table.insert(antiFlingConns, plr.CharacterAdded:Connect(function(char)
					afTrackCharacter(plr, char)
				end))
			end
			for _, plr in ipairs(Players:GetPlayers()) do
				hookPlayer(plr)
			end
			table.insert(antiFlingConns, Players.PlayerAdded:Connect(hookPlayer))
			table.insert(antiFlingConns, Players.PlayerRemoving:Connect(afUntrack))
			antiFlingLastScan = os.clock()
			table.insert(antiFlingConns, RunService.Heartbeat:Connect(afSweep))
		else
			-- put back only the parts we turned off
			for part in pairs(antiFlingChanged) do
				if part.Parent then
					part.CanCollide = true
				end
			end
			table.clear(antiFlingChanged)
		end
	end
	window.Gui.Destroying:Connect(function()
		setAntiFling(false)
	end)
	antiFlingToggle = player:AddToggle({
		Text = "Anti fling",
		Default = false,
		Callback = function(on)
			setAntiFling(on)
		end,
	})
	-- walk speed: slider plus a box where any value can be typed
	local function applyWalkSpeed(v)
		local hum = game.Players.LocalPlayer.Character and game.Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
		if hum then
			hum.WalkSpeed = v
		end
		if sprintHum then
			sprintBase = v
		end
	end
	local walkSlider, walkBox
	walkSlider = player:AddSlider({
		Text = "Walk speed",
		Min = 8, Max = 50, Default = 16, Step = 1, Suffix = " st/s",
		Callback = function(v)
			applyWalkSpeed(v)
			if walkBox then
				walkBox:Set(tostring(v))
			end
		end,
	})
	walkBox = player:AddTextbox({
		Text = "Walk speed value",
		Default = "16",
		Placeholder = "any number",
		Callback = function(text)
			local n = tonumber(text)
			if not n or n ~= n or n < 0 or n == math.huge then
				walkBox:Set(tostring(walkSlider:Get()))
				window:Notify({ Title = "Walk speed", Text = "Enter a number (0 or more).", Duration = 3 })
				return
			end
			applyWalkSpeed(n)
			walkBox:Set(tostring(n))
			walkSlider:Set(n, true) -- moves the slider as far as it goes; the typed value is still what's used
		end,
	})

	player:AddSection("Flight")
	flyToggle = player:AddToggle({
		Text = "Fly",
		Default = false,
		Callback = function(on)
			if not setFly(on) then
				flyToggle:Set(false, true)
				window:Notify({ Title = "Fly", Text = "No character to fly with yet.", Duration = 3 })
			end
		end,
	})
	vflyToggle = player:AddToggle({
		Text = "Vehicle fly",
		Default = false,
		Callback = function(on)
			if not setVehicleFly(on) then
				vflyToggle:Set(false, true)
				window:Notify({ Title = "Vehicle fly", Text = "No character to fly with yet.", Duration = 3 })
			end
		end,
	})
	-- a slider (0.1 - 20) plus a box where any positive value can be typed
	local function speedControl(label, getSpeed, setSpeed)
		local slider, box
		slider = player:AddSlider({
			Text = label,
			Min = 0.1, Max = 20, Default = getSpeed(), Step = 0.1,
			Callback = function(v)
				v = math.floor(v * 100 + 0.5) / 100
				setSpeed(v)
				if box then
					box:Set(tostring(v))
				end
			end,
		})
		box = player:AddTextbox({
			Text = label .. " value",
			Default = tostring(getSpeed()),
			Placeholder = "any number",
			Callback = function(text)
				local n = tonumber(text)
				if not n or n ~= n or n <= 0 or n == math.huge then
					box:Set(tostring(getSpeed()))
					window:Notify({ Title = label, Text = "Enter a number above 0.", Duration = 3 })
					return
				end
				setSpeed(n)
				box:Set(tostring(n))
				slider:Set(n, true) -- moves the slider as far as it goes; the typed value is still what's used
			end,
		})
	end
	speedControl("Fly speed", function()
		return iyflyspeed
	end, function(v)
		iyflyspeed = v
	end)
	speedControl("Vehicle fly speed", function()
		return vehicleflyspeed
	end, function(v)
		vehicleflyspeed = v
	end)
	player:AddToggle({
		Text = "Q/E fly (up / down)",
		Default = true,
		Callback = function(on)
			QEfly = on
		end,
	})
	local localPlayer = Players.LocalPlayer

	----------------------------------------------------------------------
	-- Visuals tab: player ESP (executor Drawing library)
	----------------------------------------------------------------------
	do
	local hasDrawing = typeof(Drawing) == "table" and type(Drawing.new) == "function"

	local espCfg = {
		Enabled = false,
		Boxes = false,
		Names = true,
		Health = false,
		Distance = false,
		Tracers = false,
		Skeleton = false,
		MaxDistance = 2000,
		Color = "Red",
	}
	local ESP_COLORS = {
		Red = Color3.fromRGB(255, 70, 70),
		Green = Color3.fromRGB(80, 255, 120),
		Blue = Color3.fromRGB(80, 150, 255),
		Purple = Color3.fromRGB(180, 100, 255),
		Yellow = Color3.fromRGB(255, 230, 80),
		Cyan = Color3.fromRGB(80, 235, 255),
		White = Color3.fromRGB(255, 255, 255),
	}
	local ESP_COLOR_NAMES = { "Red", "Green", "Blue", "Purple", "Yellow", "Cyan", "White" }

	-- saved ESP settings, including whether ESP was switched on
	applySaved(espCfg, Saved.ESP, {
		Enabled = { bool = true },
		Boxes = { bool = true },
		Names = { bool = true },
		Health = { bool = true },
		Distance = { bool = true },
		Tracers = { bool = true },
		Skeleton = { bool = true },
		MaxDistance = { min = 100, max = 5000 },
		Color = { options = ESP_COLOR_NAMES },
	})
	local function setESP(key, value)
		espCfg[key] = value
		Saved.ESP[key] = value
		queueSave()
	end
	local BLACK = Color3.new(0, 0, 0)

	local R15_BONES = {
		{ "Head", "UpperTorso" }, { "UpperTorso", "LowerTorso" },
		{ "UpperTorso", "LeftUpperArm" }, { "LeftUpperArm", "LeftLowerArm" }, { "LeftLowerArm", "LeftHand" },
		{ "UpperTorso", "RightUpperArm" }, { "RightUpperArm", "RightLowerArm" }, { "RightLowerArm", "RightHand" },
		{ "LowerTorso", "LeftUpperLeg" }, { "LeftUpperLeg", "LeftLowerLeg" }, { "LeftLowerLeg", "LeftFoot" },
		{ "LowerTorso", "RightUpperLeg" }, { "RightUpperLeg", "RightLowerLeg" }, { "RightLowerLeg", "RightFoot" },
	}
	local R6_BONES = {
		{ "Head", "Torso" }, { "Torso", "Left Arm" }, { "Torso", "Right Arm" },
		{ "Torso", "Left Leg" }, { "Torso", "Right Leg" },
	}

	local espObjects = {} -- [Player] = { drawings }
	local espConn = nil

	local function newDraw(class, props)
		local d = Drawing.new(class)
		for k, v in pairs(props) do
			d[k] = v
		end
		return d
	end

	local function hideESP(o)
		o.boxOutline.Visible = false
		o.box.Visible = false
		o.name.Visible = false
		o.info.Visible = false
		o.healthOutline.Visible = false
		o.health.Visible = false
		o.tracer.Visible = false
		for _, b in ipairs(o.bones) do
			b.Visible = false
		end
	end

	local function createESP(plr)
		if espObjects[plr] or not hasDrawing then
			return
		end
		local o = {
			hidden = true,
			boxOutline = newDraw("Square", { Thickness = 3, Filled = false, Color = BLACK, Visible = false }),
			box = newDraw("Square", { Thickness = 1, Filled = false, Visible = false }),
			name = newDraw("Text", { Size = 14, Center = true, Outline = true, Font = 2, Visible = false }),
			info = newDraw("Text", { Size = 13, Center = true, Outline = true, Font = 2, Visible = false }),
			healthOutline = newDraw("Line", { Thickness = 4, Color = BLACK, Visible = false }),
			health = newDraw("Line", { Thickness = 2, Visible = false }),
			tracer = newDraw("Line", { Thickness = 1, Visible = false }),
			bones = {},
		}
		for i = 1, #R15_BONES do
			o.bones[i] = newDraw("Line", { Thickness = 1, Visible = false })
		end
		espObjects[plr] = o
	end

	local function removeESP(plr)
		local o = espObjects[plr]
		if not o then
			return
		end
		espObjects[plr] = nil
		local list = { o.boxOutline, o.box, o.name, o.info, o.healthOutline, o.health, o.tracer }
		for _, b in ipairs(o.bones) do
			table.insert(list, b)
		end
		for _, d in ipairs(list) do
			pcall(function()
				d:Remove()
			end)
		end
	end

	local function updateESP()
		-- Early exit when ESP is disabled - don't do any work at all
		if not espCfg.Enabled then
			-- Hide all ESP on first frame after disabling
			for plr, o in pairs(espObjects) do
				if not o.hidden then
					hideESP(o)
					o.hidden = true
				end
			end
			return
		end
		
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local vp = cam.ViewportSize
		local camPos = cam.CFrame.Position

		for plr, o in pairs(espObjects) do
			-- Skip 4 FindFirstChild calls before the enabled check by checking character validity first
			local char = plr.Character
			if not char then
				if not o.hidden then
					hideESP(o)
					o.hidden = true
				end
				continue
			end
			
			local hum = char:FindFirstChildOfClass("Humanoid")
			local root = char:FindFirstChild("HumanoidRootPart")
			local head = char:FindFirstChild("Head")

			local show = hum ~= nil and root ~= nil and head ~= nil and hum.Health > 0
			local dist = 0
			if show then
				dist = (camPos - root.Position).Magnitude
				if dist > espCfg.MaxDistance then
					show = false
				end
			end
			local topV, botV
			if show then
				topV = cam:WorldToViewportPoint(head.Position + Vector3.new(0, head.Size.Y / 2 + 0.2, 0))
				botV = cam:WorldToViewportPoint(root.Position - Vector3.new(0, 3, 0))
				if topV.Z <= 0 or botV.Z <= 0 then
					show = false
				end
			end

			if not show then
				if not o.hidden then
					hideESP(o)
					o.hidden = true
				end
			else
				o.hidden = false
				local col = ESP_COLORS[espCfg.Color] or ESP_COLORS.White

				local top, bottom = topV.Y, botV.Y
				local h = math.max(bottom - top, 4)
				local w = h / 1.8
				local cx = (topV.X + botV.X) / 2
				local left = math.floor(cx - w / 2)
				local boxPos = Vector2.new(left, math.floor(top))
				local boxSize = Vector2.new(math.floor(w), math.floor(h))

				-- Only update properties that are actually visible
				local boxVis = espCfg.Boxes
				if o.boxOutline.Visible ~= boxVis then
					o.boxOutline.Visible = boxVis
				end
				if o.box.Visible ~= boxVis then
					o.box.Visible = boxVis
				end
				if boxVis then
					o.boxOutline.Position, o.boxOutline.Size = boxPos, boxSize
					o.box.Position, o.box.Size, o.box.Color = boxPos, boxSize, col
				end

				local nameVis = espCfg.Names
				if o.name.Visible ~= nameVis then
					o.name.Visible = nameVis
				end
				if nameVis then
					o.name.Text = plr.DisplayName ~= plr.Name and (plr.DisplayName .. " (@" .. plr.Name .. ")") or plr.Name
					o.name.Color = col
					o.name.Position = Vector2.new(cx, top - 18)
				end

				local showInfo = espCfg.Distance
				if o.info.Visible ~= showInfo then
					o.info.Visible = showInfo
				end
				if showInfo then
					o.info.Text = string.format("%d studs", dist)
					o.info.Color = Color3.new(1, 1, 1)
					o.info.Position = Vector2.new(cx, bottom + 2)
				end

				local healthVis = espCfg.Health
				if o.healthOutline.Visible ~= healthVis then
					o.healthOutline.Visible = healthVis
				end
				if o.health.Visible ~= healthVis then
					o.health.Visible = healthVis
				end
				if healthVis then
					local frac = math.clamp(hum.Health / math.max(hum.MaxHealth, 1), 0, 1)
					local x = left - 5
					o.healthOutline.From = Vector2.new(x, bottom + 1)
					o.healthOutline.To = Vector2.new(x, top - 1)
					o.health.From = Vector2.new(x, bottom)
					o.health.To = Vector2.new(x, bottom - h * frac)
					o.health.Color = Color3.fromRGB(255, 60, 60):Lerp(Color3.fromRGB(70, 255, 100), frac)
				end

				local tracerVis = espCfg.Tracers
				if o.tracer.Visible ~= tracerVis then
					o.tracer.Visible = tracerVis
				end
				if tracerVis then
					o.tracer.From = Vector2.new(vp.X / 2, vp.Y)
					o.tracer.To = Vector2.new(cx, bottom)
					o.tracer.Color = col
				end

				-- Skeleton mode adds heavy lookups - only do them if enabled
				if espCfg.Skeleton then
					local bonesList = char:FindFirstChild("UpperTorso") and R15_BONES or R6_BONES
					for i, b in ipairs(o.bones) do
						local pair = bonesList[i]
						local a = pair and char:FindFirstChild(pair[1])
						local c = pair and char:FindFirstChild(pair[2])
						if a and c then
							local av = cam:WorldToViewportPoint(a.Position)
							local cv = cam:WorldToViewportPoint(c.Position)
							if av.Z > 0 and cv.Z > 0 then
								b.From = Vector2.new(av.X, av.Y)
								b.To = Vector2.new(cv.X, cv.Y)
								b.Color = col
								b.Visible = true
							else
								b.Visible = false
							end
						else
							b.Visible = false
						end
					end
				else
					-- Hide all bones when skeleton is off
					for _, b in ipairs(o.bones) do
						if b.Visible then
							b.Visible = false
						end
					end
				end
			end
		end
	end

	local visuals = window:AddTab("Visuals")
	visuals:AddSection("Player ESP")
	if not hasDrawing then
		visuals:AddLabel("Your executor has no Drawing library, so ESP isn't available.")
	else
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= localPlayer then
				createESP(plr)
			end
		end
		local espAdded = Players.PlayerAdded:Connect(function(plr)
			if plr ~= localPlayer then
				createESP(plr)
			end
		end)
		local espRemoving = Players.PlayerRemoving:Connect(removeESP)
		espConn = RunService.RenderStepped:Connect(function()
			pcall(updateESP)
		end)
		window.Gui.Destroying:Connect(function()
			espAdded:Disconnect()
			espRemoving:Disconnect()
			if espConn then
				espConn:Disconnect()
				espConn = nil
			end
			for plr in pairs(espObjects) do
				removeESP(plr)
			end
		end)

		local function espToggle(text, key)
			visuals:AddToggle({
				Text = text,
				Default = espCfg[key],
				Callback = function(on)
					setESP(key, on)
				end,
			})
		end
		espToggle("ESP enabled", "Enabled")
		espToggle("Boxes", "Boxes")
		espToggle("Names", "Names")
		espToggle("Health bar", "Health")
		espToggle("Distance", "Distance")
		espToggle("Tracers", "Tracers")
		espToggle("Skeleton", "Skeleton")
		visuals:AddSlider({
			Text = "Max distance",
			Min = 100,
			Max = 5000,
			Step = 50,
			Default = espCfg.MaxDistance,
			Suffix = " studs",
			Callback = function(v)
				setESP("MaxDistance", v)
			end,
		})
		visuals:AddDropdown({
			Text = "Color",
			Options = ESP_COLOR_NAMES,
			Default = espCfg.Color,
			Callback = function(v)
				setESP("Color", v)
			end,
		})
	end
	end

	----------------------------------------------------------------------
	-- Aimbot tab: turns your camera toward the nearest player inside the FOV circle.
	-- It only moves your own camera; nothing is sent to the game.
	-- Settings, and whether it was on, are saved to the same file as the keybinds.
	-- Press C (rebindable in Settings > Keybinds) to switch it on or off.
	----------------------------------------------------------------------
	do
		local me = Players.LocalPlayer
		local BIND_NAME = "CatsHubAimbot"

		local aim = {
			Enabled = false, -- restored from the save file below
			Activation = IsOnMobile and "Always on" or "Hold right-click",
			Part = "Head",
			AimFrom = "Cursor", -- "Cursor" (screen centre when the mouse is locked) or "Screen center"
			FOV = 150, -- circle radius in pixels
			ShowFov = true,
			MaxDistance = 1000,
			TeamCheck = true,
			WallCheck = true,
			Sticky = true, -- keep the same target until it leaves the circle
			Smooth = 75, -- percent; higher = slower, softer turn (0 = snap instantly)
			Predict = 0, -- milliseconds of target movement to lead by
		}

		-- what each saved value is allowed to be; anything else in the file is ignored
		local SPEC = {
			Enabled = { bool = true },
			Activation = { options = { "Hold right-click", "Always on" } },
			Part = { options = { "Head", "Torso", "HumanoidRootPart" } },
			AimFrom = { options = { "Cursor", "Screen center" } },
			FOV = { min = 20, max = 600 },
			MaxDistance = { min = 50, max = 2000 },
			Smooth = { min = 0, max = 95 },
			Predict = { min = 0, max = 300 },
			ShowFov = { bool = true },
			TeamCheck = { bool = true },
			WallCheck = { bool = true },
			Sticky = { bool = true },
		}
		applySaved(aim, Saved.Aimbot, SPEC)

		local function setOpt(key, value)
			aim[key] = value
			Saved.Aimbot[key] = value
			queueSave()
		end

		local holding = false
		local lockedPlr = nil
		local beganConn = UserInputService.InputBegan:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				holding = true
			end
		end)
		local endedConn = UserInputService.InputEnded:Connect(function(input)
			if input.UserInputType == Enum.UserInputType.MouseButton2 then
				holding = false
			end
		end)

		-- FOV circle (a plain frame, so it works without the Drawing library)
		local circle = Instance.new("Frame")
		circle.Name = "AimbotFov"
		circle.AnchorPoint = Vector2.new(0.5, 0.5)
		circle.BackgroundTransparency = 1
		circle.BorderSizePixel = 0
		circle.Active = false
		circle.Visible = false
		local circleCorner = Instance.new("UICorner")
		circleCorner.CornerRadius = UDim.new(1, 0)
		circleCorner.Parent = circle
		local circleStroke = Instance.new("UIStroke")
		circleStroke.Color = Color3.fromRGB(255, 96, 140)
		circleStroke.Thickness = 1.5
		circleStroke.Parent = circle
		circle.Parent = window.Gui

		local function aimPoint(cam)
			local useCenter = aim.AimFrom == "Screen center"
				or IsOnMobile
				or UserInputService.MouseBehavior == Enum.MouseBehavior.LockCenter
			if useCenter then
				local vp = cam.ViewportSize
				return Vector2.new(vp.X / 2, vp.Y / 2)
			end
			return UserInputService:GetMouseLocation()
		end

		local function targetPart(char)
			local part
			if aim.Part == "Head" then
				part = char:FindFirstChild("Head")
			elseif aim.Part == "Torso" then
				part = char:FindFirstChild("UpperTorso") or char:FindFirstChild("Torso")
			end
			return part or char:FindFirstChild("HumanoidRootPart")
		end

		local rayParams = RaycastParams.new()
		rayParams.FilterType = Enum.RaycastFilterType.Exclude
		rayParams.IgnoreWater = true

		local function canSee(origin, part, char)
			local filter = { char }
			if me.Character then
				table.insert(filter, me.Character)
			end
			rayParams.FilterDescendantsInstances = filter
			return workspace:Raycast(origin, part.Position - origin, rayParams) == nil
		end

		-- the target part for this player if they can be aimed at, plus how far it is
		-- from the aim point in pixels (nil when they can't be)
		local function evaluate(plr, cam, camPos, center, fovLimit)
			local char = plr.Character
			local hum = char and char:FindFirstChildOfClass("Humanoid")
			if not hum or hum.Health <= 0 then
				return nil
			end
			if aim.TeamCheck and me.Team ~= nil and plr.Team == me.Team then
				return nil
			end
			local part = targetPart(char)
			if not part or (part.Position - camPos).Magnitude > aim.MaxDistance then
				return nil
			end
			local pos, onScreen = cam:WorldToViewportPoint(part.Position)
			if not onScreen then
				return nil
			end
			local d = (Vector2.new(pos.X, pos.Y) - center).Magnitude
			if d > fovLimit then
				return nil
			end
			if aim.WallCheck and not canSee(camPos, part, char) then
				return nil
			end
			return part, d
		end

		local function findTarget(cam, camPos, center)
			local bestPart, bestPlr, bestDist = nil, nil, math.huge
			for _, plr in ipairs(Players:GetPlayers()) do
				if plr ~= me then
					local part, d = evaluate(plr, cam, camPos, center, math.min(aim.FOV, bestDist))
					if part and d < bestDist then
						bestPart, bestPlr, bestDist = part, plr, d
					end
				end
			end
			return bestPart, bestPlr
		end

		local function step(dt)
			local cam = workspace.CurrentCamera
			if not cam then
				return
			end
			local center = aimPoint(cam)
			circle.Visible = aim.ShowFov
			circle.Position = UDim2.fromOffset(center.X, center.Y)
			circle.Size = UDim2.fromOffset(aim.FOV * 2, aim.FOV * 2)

			if aim.Activation ~= "Always on" and not holding then
				lockedPlr = nil
				return
			end

			local camPos = cam.CFrame.Position
			local part
			-- keep the current target while it stays reasonably close to the circle,
			-- so the aim doesn't flick between players as the camera moves
			if aim.Sticky and lockedPlr and lockedPlr.Parent then
				part = evaluate(lockedPlr, cam, camPos, center, aim.FOV * 1.5)
			end
			if not part then
				part, lockedPlr = findTarget(cam, camPos, center)
			end
			if not part then
				return
			end

			local targetPos = part.Position + part.AssemblyLinearVelocity * (aim.Predict / 1000)
			local alpha = 1 - (aim.Smooth / 100) ^ (dt * 60) -- same feel at any frame rate
			cam.CFrame = cam.CFrame:Lerp(CFrame.lookAt(camPos, targetPos), alpha)
		end

		-- switches the aimbot on or off without touching the save file
		local bound = false
		local function applyAimbot(on)
			aim.Enabled = on
			if on and not bound then
				bound = true
				RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, step)
			elseif not on and bound then
				bound = false
				RunService:UnbindFromRenderStep(BIND_NAME)
				circle.Visible = false
				lockedPlr = nil
			end
		end

		-- what the toggle and the hotkey call: switch it and remember the choice
		local function setAimbot(on)
			applyAimbot(on)
			Saved.Aimbot.Enabled = on
			queueSave()
		end

		local aimToggle -- created below; the hotkey flips it

		-- hotkey (C by default, change it in Settings > Keybinds)
		local aimKeyConn = UserInputService.InputBegan:Connect(function(input, processed)
			if processed or window._listening then
				return
			end
			if Keys.AimbotToggle and input.KeyCode == Keys.AimbotToggle and aimToggle then
				aimToggle:Set(not aimToggle:Get())
				window:Notify({
					Title = "Aimbot",
					Text = aimToggle:Get() and "On" or "Off",
					Duration = 1.5,
				})
			end
		end)

		window.Gui.Destroying:Connect(function()
			applyAimbot(false) -- only stops it; the saved on/off choice is left alone
			beganConn:Disconnect()
			endedConn:Disconnect()
			aimKeyConn:Disconnect()
			circle:Destroy()
		end)

		local aimTab = window:AddTab("Aimbot")
		aimTab:AddSection("Aimbot")
		aimToggle = aimTab:AddToggle({
			Text = "Enable aimbot",
			Default = aim.Enabled,
			Callback = setAimbot,
		})
		if aim.Enabled then
			applyAimbot(true) -- it was on last time
		end
		aimTab:AddDropdown({
			Text = "Activation",
			Options = SPEC.Activation.options,
			Default = aim.Activation,
			Callback = function(v)
				setOpt("Activation", v)
			end,
		})
		aimTab:AddDropdown({
			Text = "Target part",
			Options = SPEC.Part.options,
			Default = aim.Part,
			Callback = function(v)
				setOpt("Part", v)
			end,
		})

		aimTab:AddSection("Targeting")
		aimTab:AddDropdown({
			Text = "Aim from",
			Options = SPEC.AimFrom.options,
			Default = aim.AimFrom,
			Callback = function(v)
				setOpt("AimFrom", v)
			end,
		})
		aimTab:AddSlider({
			Text = "FOV radius",
			Min = SPEC.FOV.min, Max = SPEC.FOV.max, Default = aim.FOV, Step = 10, Suffix = " px",
			Callback = function(v)
				setOpt("FOV", v)
			end,
		})
		aimTab:AddToggle({
			Text = "Show FOV circle",
			Default = aim.ShowFov,
			Callback = function(on)
				setOpt("ShowFov", on)
				if not on then
					circle.Visible = false
				end
			end,
		})
		aimTab:AddSlider({
			Text = "Max distance",
			Min = SPEC.MaxDistance.min, Max = SPEC.MaxDistance.max, Default = aim.MaxDistance, Step = 50, Suffix = " studs",
			Callback = function(v)
				setOpt("MaxDistance", v)
			end,
		})
		aimTab:AddToggle({
			Text = "Stick to target",
			Default = aim.Sticky,
			Callback = function(on)
				setOpt("Sticky", on)
				if not on then
					lockedPlr = nil
				end
			end,
		})
		aimTab:AddToggle({
			Text = "Team check (skip teammates)",
			Default = aim.TeamCheck,
			Callback = function(on)
				setOpt("TeamCheck", on)
			end,
		})
		aimTab:AddToggle({
			Text = "Wall check (only visible players)",
			Default = aim.WallCheck,
			Callback = function(on)
				setOpt("WallCheck", on)
			end,
		})

		aimTab:AddSection("Feel")
		aimTab:AddSlider({
			Text = "Smoothness (higher = slower)",
			Min = SPEC.Smooth.min, Max = SPEC.Smooth.max, Default = aim.Smooth, Step = 5, Suffix = "%",
			Callback = function(v)
				setOpt("Smooth", v)
			end,
		})
		aimTab:AddSlider({
			Text = "Prediction",
			Min = SPEC.Predict.min, Max = SPEC.Predict.max, Default = aim.Predict, Step = 10, Suffix = " ms",
			Callback = function(v)
				setOpt("Predict", v)
			end,
		})
	end

	----------------------------------------------------------------------
	-- World tab: gloomy night preset
	----------------------------------------------------------------------
	do
		local Lighting = game:GetService("Lighting")
		local terrain = workspace:FindFirstChildOfClass("Terrain")

		local gloomOn = false
		local gloomAmount = 1 -- 0..1, blends from the original look to the full preset
		local gloomConn = nil
		local entries = {} -- { inst, orig = {prop=value}, target = {prop=value}, created = bool }

		-- custom night skybox (applied to the map's Sky, or to our own if the map has none)
		local SKY_FACES = {
			SkyboxBk = "rbxassetid://154185004",
			SkyboxDn = "rbxassetid://154184960",
			SkyboxFt = "rbxassetid://154185021",
			SkyboxLf = "rbxassetid://154184943",
			SkyboxRt = "rbxassetid://154184972",
			SkyboxUp = "rbxassetid://154185031",
		}
		local skyInst = nil
		local skyOrig = nil -- original face ids, restored when gloomy night is switched off

		local function mix(a, b, t)
			if typeof(a) == "Color3" then
				return a:Lerp(b, t)
			end
			return a + (b - a) * t
		end

		local function differs(a, b)
			if typeof(a) == "Color3" then
				return math.abs(a.R - b.R) + math.abs(a.G - b.G) + math.abs(a.B - b.B) > 0.002
			end
			return math.abs(a - b) > 0.001
		end

		-- reuses an existing instance (restored later) or creates one of our own (removed later)
		local function ensure(class, parent, neutral, target, reuse)
			local inst = reuse and parent:FindFirstChildOfClass(class)
			if inst then
				local orig = {}
				for p in pairs(target) do
					orig[p] = inst[p]
				end
				table.insert(entries, { inst = inst, orig = orig, target = target, created = false })
				return
			end
			inst = Instance.new(class)
			inst.Name = "Gloom" .. class
			for p, v in pairs(neutral) do
				inst[p] = v
			end
			inst.Parent = parent
			table.insert(entries, { inst = inst, orig = neutral, target = target, created = true })
		end

		local function build()
			table.clear(entries)

			local lightTarget = {
				ClockTime = 20,
				Brightness = 1,
				ExposureCompensation = -0.1,
				Ambient = Color3.fromRGB(74, 62, 72),
				OutdoorAmbient = Color3.fromRGB(92, 78, 88),
				ColorShift_Top = Color3.fromRGB(255, 120, 92),
				ColorShift_Bottom = Color3.fromRGB(40, 30, 45),
				EnvironmentDiffuseScale = 0.5,
				EnvironmentSpecularScale = 0.5,
			}
			local lightOrig = {}
			for p in pairs(lightTarget) do
				lightOrig[p] = Lighting[p]
			end
			table.insert(entries, { inst = Lighting, orig = lightOrig, target = lightTarget, created = false })

			-- soft rose haze that starts off in the distance
			ensure("Atmosphere", Lighting, {
				Density = 0, Offset = 0, Glare = 0, Haze = 0,
				Color = Color3.fromRGB(199, 170, 107), Decay = Color3.fromRGB(92, 60, 13),
			}, {
				Density = 0.22, Offset = 0.4, Glare = 0, Haze = 1.3,
				Color = Color3.fromRGB(200, 125, 122), Decay = Color3.fromRGB(168, 78, 86),
			}, true)

			-- stars (the real moon is hidden; a custom one is drawn below)
			ensure("Sky", Lighting, { StarCount = 0, MoonAngularSize = 11 }, { StarCount = 2500, MoonAngularSize = 0 }, true)
			skyInst = entries[#entries].inst
			skyOrig = {}
			for face in pairs(SKY_FACES) do
				skyOrig[face] = skyInst[face]
			end

			-- heavy, dusky clouds, only if the map has them
			local clouds = terrain and terrain:FindFirstChildOfClass("Clouds")
			if clouds then
				ensure("Clouds", terrain, {}, {
					Cover = 0.8, Density = 0.55, Color = Color3.fromRGB(125, 80, 85),
				}, true)
			end

			-- screen effects (always our own, stacked on top of whatever the map has)
			ensure("ColorCorrectionEffect", Lighting, {
				Saturation = 0, Contrast = 0, Brightness = 0, TintColor = Color3.new(1, 1, 1),
			}, {
				Saturation = -0.12, Contrast = 0.1, Brightness = 0.01, TintColor = Color3.fromRGB(255, 214, 206),
			}, false)
			ensure("BloomEffect", Lighting, { Intensity = 0, Size = 28, Threshold = 2 }, { Intensity = 0.6, Size = 32, Threshold = 1 }, false)
			ensure("DepthOfFieldEffect", Lighting, {
				FarIntensity = 0, NearIntensity = 0, FocusDistance = 80, InFocusRadius = 50,
			}, {
				FarIntensity = 0.15, NearIntensity = 0, FocusDistance = 80, InFocusRadius = 50,
			}, false)
		end

		local function apply()
			-- skybox: swap faces in/out with the slider (strings can't be blended)
			if skyInst and skyInst.Parent then
				for face, id in pairs(SKY_FACES) do
					local want = gloomAmount >= 0.5 and id or skyOrig[face]
					FrameCache:SetProperty(skyInst, face, want)
				end
			end
			for _, e in ipairs(entries) do
				if e.inst.Parent then
					for prop, target in pairs(e.target) do
						local v = mix(e.orig[prop], target, gloomAmount)
						if prop == "StarCount" then
							v = math.floor(v + 0.5)
						end
						FrameCache:SetProperty(e.inst, prop, v)
					end
				end
			end
		end

		-- custom moon: a billboard drawn from frames (no image assets needed), parked far out in the
		-- direction of the real moon and following the camera
		local MOON_TEXTURE = "rbxassetid://6444320592"
		local MOON_DIST = 1000
		local MOON_DIAMETER = 115 -- studs at MOON_DIST (~6.5 degrees)
		local GLOW_SPAN = 2.4 -- billboard is this many moon-widths wide so the glow has room
		local moonPart, moonRoot, moonGui, moonConn
		local moonFade = {} -- { {instance, baseTransparency, "bg"|"img"} } so the moon can fade with the slider

		local function circle(parent, cx, cy, d, color, transparency)
			local f = Instance.new("Frame")
			f.AnchorPoint = Vector2.new(0.5, 0.5)
			f.Position = UDim2.fromScale(cx, cy)
			f.Size = UDim2.fromScale(d, d)
			f.BackgroundColor3 = color
			f.BackgroundTransparency = transparency
			f.BorderSizePixel = 0
			local c = Instance.new("UICorner")
			c.CornerRadius = UDim.new(1, 0)
			c.Parent = f
			f.Parent = parent
			table.insert(moonFade, { f, transparency, "bg" })
			return f
		end

		local function destroyMoon()
			if moonConn then
				moonConn:Disconnect()
				moonConn = nil
			end
			if moonPart then
				moonPart:Destroy()
			end
			moonPart, moonRoot, moonGui = nil, nil, nil
			table.clear(moonFade)
		end

		local function buildMoon()
			destroyMoon()
			local cam = workspace.CurrentCamera
			if not cam then
				return
			end
			moonPart = Instance.new("Part")
			moonPart.Name = "GloomMoon"
			moonPart.Anchored = true
			moonPart.CanCollide = false
			moonPart.CanQuery = false
			moonPart.CanTouch = false
			moonPart.Transparency = 1
			moonPart.Size = Vector3.one
			moonPart.Parent = cam

			local span = MOON_DIAMETER * GLOW_SPAN
			moonGui = Instance.new("BillboardGui")
			moonGui.Adornee = moonPart
			moonGui.Size = UDim2.fromScale(span, span)
			moonGui.LightInfluence = 0
			moonGui.AlwaysOnTop = false
			moonGui.Parent = moonPart

			moonRoot = Instance.new("Frame")
			moonRoot.Size = UDim2.fromScale(1, 1)
			moonRoot.BackgroundTransparency = 1
			moonRoot.BorderSizePixel = 0
			moonRoot.Parent = moonGui

			local u = 1 / GLOW_SPAN
			local DISC_FRACTION = 0.985 -- this texture's moon fills nearly its full width
			local imgSize = u / DISC_FRACTION

			-- the texture has a black margin around the moon. Instead of fighting it, gently darken the
			-- sky in a soft halo behind the moon so the margin blends in (faint black rings, no edge)
			local VIGNETTE = 18
			for k = 1, VIGNETTE do
				local f = (k - 1) / (VIGNETTE - 1)
				local d = imgSize * 0.985 + (1 - imgSize * 0.985) * (f ^ 1.3)
				circle(moonRoot, 0.5, 0.5, d, Color3.new(0, 0, 0), 0.975)
			end

			-- the moon texture (real craters and maria), cropped to a circle
			local tex = MOON_TEXTURE
			local img = Instance.new("ImageLabel")
			img.AnchorPoint = Vector2.new(0.5, 0.5)
			img.Position = UDim2.fromScale(0.5, 0.5)
			img.Size = UDim2.fromScale(imgSize, imgSize)
			img.BackgroundTransparency = 1
			img.BorderSizePixel = 0
			img.Image = tex
			local ic = Instance.new("UICorner")
			ic.CornerRadius = UDim.new(1, 0)
			ic.Parent = img
			img.Parent = moonRoot
			table.insert(moonFade, { img, 0, "img" })

			-- red wash over the texture: keeps the surface detail, swaps grey for a deep red
			circle(moonRoot, 0.5, 0.5, u * 1.012, Color3.fromRGB(215, 60, 55), 0.28)

			-- light from the upper left: darken toward the lower right so it reads as a sphere
			local shade = circle(moonRoot, 0.5, 0.5, u, Color3.fromRGB(80, 30, 20), 0)
			local sg = Instance.new("UIGradient")
			sg.Rotation = 40
			sg.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 1),
				NumberSequenceKeypoint.new(0.5, 1),
				NumberSequenceKeypoint.new(1, 0.45),
			})
			sg.Parent = shade
			moonFade[#moonFade][2] = 0.45

			-- soft glow drawn OVER everything (so the texture's black margin blends into the sky):
			-- many very faint rings, so there are no visible bands
			local glow = Color3.fromRGB(255, 95, 80)
			local RINGS = 28
			for k = 1, RINGS do
				local f = (k - 1) / (RINGS - 1)
				local d = u * 0.98 + (1 - u * 0.98) * (f ^ 1.6)
				circle(moonRoot, 0.5, 0.5, d, glow, 0.985)
			end

			moonConn = RunService.RenderStepped:Connect(function()
				local c = workspace.CurrentCamera
				if not (c and moonPart and moonPart.Parent) then
					return
				end
				local dir = Lighting:GetMoonDirection()
				moonPart.CFrame = CFrame.new(c.CFrame.Position + dir * MOON_DIST)
				local enabled = dir.Y > -0.03 -- hide once it sets below the horizon
				if moonGui.Enabled ~= enabled then
					moonGui.Enabled = enabled
				end
				
				-- Only update transparency values when gloomAmount actually changed
				-- (avoiding 50+ property writes per frame when the slider isn't moving)
				if enabled then
					for _, item in ipairs(moonFade) do
						local inst, base, kind = item[1], item[2], item[3]
						if kind == "img" then
							FrameCache:SetProperty(inst, "ImageTransparency", 1 - gloomAmount)
						else
							FrameCache:SetProperty(inst, "BackgroundTransparency", 1 - (1 - base) * gloomAmount)
						end
					end
				end
			end)
		end

		----------------------------------------------------------------------
		-- No fog / no clouds (gloomy night forces clouds off and overrides no fog)
		----------------------------------------------------------------------
		local noFogOn, noCloudsOn = false, false
		local worldConn = nil
		local origFog = nil -- { Start, End } saved before we override fog
		local stashedClouds = {} -- { { inst = Clouds, enabled = bool } } terrain clouds we switched off
		local FOG_DISTANCE = 4000

		local function restoreFog()
			if origFog then
				Lighting.FogStart = origFog.Start
				Lighting.FogEnd = origFog.End
				origFog = nil
			end
		end

		local function restoreClouds()
			for _, c in ipairs(stashedClouds) do
				if c.inst and c.inst.Parent then
					c.inst.Enabled = c.enabled
				end
			end
			table.clear(stashedClouds)
		end

		local function enforceWorld()
			-- fog: hold it at 4000 (gloomy night takes priority, see refreshWorld)
			if noFogOn and not gloomOn then
				if not origFog then
					origFog = { Start = Lighting.FogStart, End = Lighting.FogEnd }
				end
				if Lighting.FogStart ~= FOG_DISTANCE then
					Lighting.FogStart = FOG_DISTANCE
				end
				if Lighting.FogEnd ~= FOG_DISTANCE then
					Lighting.FogEnd = FOG_DISTANCE
				end
			end

			-- clouds: the terrain's Clouds object (works in any game that uses it)
			if noCloudsOn or gloomOn then
				local clouds = workspace.Terrain:FindFirstChildOfClass("Clouds")
				if clouds and clouds.Enabled then
					table.insert(stashedClouds, { inst = clouds, enabled = true })
					clouds.Enabled = false
				end
			end
		end

		-- call after any of the flags (or gloomOn) change
		local function refreshWorld()
			local fogWanted = noFogOn and not gloomOn
			local cloudWanted = noCloudsOn or gloomOn

			if not fogWanted then
				restoreFog()
			end
			if not cloudWanted then
				restoreClouds()
			end

			if fogWanted or cloudWanted then
				if not worldConn then
					worldConn = RunService.Heartbeat:Connect(enforceWorld)
				end
				enforceWorld()
			elseif worldConn then
				worldConn:Disconnect()
				worldConn = nil
			end
		end

		local function setGloom(on)
			if on == gloomOn then
				return
			end
			gloomOn = on
			if on then
				build()
				apply()
				buildMoon()
				-- the map may change lighting on its own, so keep re-applying
				gloomConn = RunService.Heartbeat:Connect(apply)
			else
				if gloomConn then
					gloomConn:Disconnect()
					gloomConn = nil
				end
				destroyMoon()
				if skyInst and skyInst.Parent and skyOrig then
					for face, v in pairs(skyOrig) do
						pcall(function()
							skyInst[face] = v
						end)
					end
				end
				skyInst, skyOrig = nil, nil
				for _, e in ipairs(entries) do
					if e.created then
						e.inst:Destroy()
					elseif e.inst.Parent then
						for prop, v in pairs(e.orig) do
							pcall(function()
								e.inst[prop] = v
							end)
						end
					end
				end
				table.clear(entries)
			end
			refreshWorld()
		end

		window.Gui.Destroying:Connect(function()
			noFogOn, noCloudsOn = false, false
			setGloom(false)
			refreshWorld()
		end)

		----------------------------------------------------------------------
		-- Shooting stars: only spawn where you can see them (inside the camera view,
		-- above the horizon, line of sight clear, whole path on screen)
		----------------------------------------------------------------------
		local STAR = {
			MinDelay = 0.6, MaxDelay = 3, SkyDistance = 600, Size = 3.5, Width = 5,
			TrailLifetime = 0.8, MinTravel = 200, MaxTravel = 400, MinElevation = 10,
			ViewFraction = 0.75, MaxAttempts = 12,
		}
		local STAR_RED = Color3.fromRGB(255, 70, 70)
		local STAR_WHITE = Color3.fromRGB(255, 255, 255)
		local STAR_BLUE = Color3.fromRGB(150, 205, 255)
		local starFolder = nil
		local starToken = 0

		local function randomStarColor()
			local t = math.random()
			if t < 0.5 then
				return STAR_RED:Lerp(STAR_WHITE, t * 2)
			end
			return STAR_WHITE:Lerp(STAR_BLUE, (t - 0.5) * 2)
		end

		local function randomRange(limit)
			return (math.random() * 2 - 1) * limit
		end

		local function findVisiblePath(cam)
			local viewport = cam.ViewportSize
			if viewport.Y <= 0 then
				return nil
			end
			local vHalf = math.rad(cam.FieldOfView / 2)
			local hHalf = math.atan(math.tan(vHalf) * (viewport.X / viewport.Y))
			local minY = math.sin(math.rad(STAR.MinElevation))

			local rayParams = RaycastParams.new()
			rayParams.FilterType = Enum.RaycastFilterType.Exclude
			local exclude = { starFolder }
			local character = Players.LocalPlayer and Players.LocalPlayer.Character
			if character then
				table.insert(exclude, character)
			end
			rayParams.FilterDescendantsInstances = exclude

			local camPos = cam.CFrame.Position
			for _ = 1, STAR.MaxAttempts do
				local frame = cam.CFrame * CFrame.Angles(
					randomRange(vHalf * STAR.ViewFraction),
					randomRange(hHalf * STAR.ViewFraction),
					0
				)
				local dir = frame.LookVector
				if dir.Y >= minY then
					local startPos = camPos + dir * STAR.SkyDistance
					local sign = math.random() < 0.5 and 1 or -1
					local travelDir = (frame.RightVector * sign + Vector3.new(0, -0.4, 0)).Unit
					local endPos = startPos + travelDir * math.random(STAR.MinTravel, STAR.MaxTravel)
					local _, startOnScreen = cam:WorldToViewportPoint(startPos)
					local _, endOnScreen = cam:WorldToViewportPoint(endPos)
					if startOnScreen and endOnScreen then
						if not workspace:Raycast(camPos, startPos - camPos, rayParams) then
							return startPos, endPos
						end
					end
				end
			end
			return nil
		end

		local function spawnStar()
			local cam = workspace.CurrentCamera
			if not (cam and starFolder) then
				return
			end
			local startPos, endPos = findVisiblePath(cam)
			if not startPos then
				return
			end

			local duration = math.random(8, 14) / 10
			local color = randomStarColor()

			local star = Instance.new("Part")
			star.Shape = Enum.PartType.Ball
			star.Size = Vector3.new(STAR.Size, STAR.Size, STAR.Size)
			star.Material = Enum.Material.Neon
			star.Color = color
			star.Anchored = true
			star.CanCollide = false
			star.CanQuery = false
			star.CanTouch = false
			star.CastShadow = false
			star.Position = startPos

			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, STAR.Width / 2, 0)
			a0.Parent = star
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(0, -STAR.Width / 2, 0)
			a1.Parent = star

			local trail = Instance.new("Trail")
			trail.Attachment0 = a0
			trail.Attachment1 = a1
			trail.Color = ColorSequence.new(color)
			trail.Transparency = NumberSequence.new({
				NumberSequenceKeypoint.new(0, 0),
				NumberSequenceKeypoint.new(1, 1),
			})
			trail.LightEmission = 1
			trail.FaceCamera = true
			trail.Lifetime = STAR.TrailLifetime
			trail.Parent = star

			star.Parent = starFolder
			TweenService:Create(star, TweenInfo.new(duration, Enum.EasingStyle.Linear), {
				Position = endPos,
			}):Play()
			task.delay(duration + STAR.TrailLifetime, function()
				star:Destroy()
			end)
		end

		local function setShootingStars(on)
			starToken += 1
			if starFolder then
				starFolder:Destroy()
				starFolder = nil
			end
			if not on then
				return
			end
			local token = starToken
			starFolder = Instance.new("Folder")
			starFolder.Name = "ShootingStars"
			starFolder.Parent = workspace
			task.spawn(function()
				while starToken == token do
					task.wait(STAR.MinDelay + math.random() * (STAR.MaxDelay - STAR.MinDelay))
					if starToken ~= token then
						break
					end
					spawnStar()
				end
			end)
		end

		local world = window:AddTab("World")
		world:AddSection("Atmosphere")
		gloomToggle = world:AddToggle({
			Text = "Gloomy night",
			Default = false,
			Callback = setGloom,
		})
		world:AddSlider({
			Text = "Gloom intensity",
			Min = 0,
			Max = 100,
			Step = 5,
			Default = 100,
			Suffix = "%",
			Callback = function(v)
				gloomAmount = v / 100
				if gloomOn then
					apply()
				end
			end,
		})

		world:AddSection("Sky")
		shootingStarsToggle = world:AddToggle({
			Text = "Shooting stars",
			Default = false,
			Callback = setShootingStars,
		})

		world:AddSection("Environment")
		world:AddToggle({
			Text = "No fog",
			Default = false,
			Callback = function(on)
				noFogOn = on
				refreshWorld()
			end,
		})
		world:AddToggle({
			Text = "No clouds",
			Default = false,
			Callback = function(on)
				noCloudsOn = on
				refreshWorld()
			end,
		})
	end

	----------------------------------------------------------------------
	-- Teleports tab
	----------------------------------------------------------------------
	local function teleportTo(cf, label)
		local _, _, root = getCharacter()
		if not root then
			window:Notify({ Title = "Teleport", Text = "No character to teleport.", Duration = 3 })
			return
		end
		root.CFrame = cf
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
		window:Notify({ Title = "Teleport", Text = "Teleported to " .. label, Duration = 2 })
	end

	local function otherPlayerNames(exclude)
		local names = {}
		for _, plr in ipairs(Players:GetPlayers()) do
			if plr ~= Players.LocalPlayer and plr ~= exclude then
				table.insert(names, plr.Name)
			end
		end
		table.sort(names, function(a, b)
			return a:lower() < b:lower()
		end)
		return names
	end

	local teleports = window:AddTab("Teleports")
	teleports:AddSection("Players")
	local playerDropdown = teleports:AddDropdown({
		Text = "Player",
		Options = otherPlayerNames(),
	})
	teleports:AddButton({
		Text = "Teleport to selected player",
		Callback = function()
			local name = playerDropdown:Get()
			local target = name and Players:FindFirstChild(name)
			local targetChar = target and target:IsA("Player") and target.Character
			local targetRoot = targetChar and targetChar:FindFirstChild("HumanoidRootPart")
			if not targetRoot then
				window:Notify({ Title = "Teleport", Text = "Pick a player with a loaded character first.", Duration = 3 })
				return
			end
			-- land a few studs behind them instead of inside them
			teleportTo(targetRoot.CFrame * CFrame.new(0, 0, 4), target.Name)
		end,
	})

	-- keep the player list current as people join and leave
	local addedConn = Players.PlayerAdded:Connect(function()
		playerDropdown:SetOptions(otherPlayerNames())
	end)
	local removingConn = Players.PlayerRemoving:Connect(function(leaving)
		playerDropdown:SetOptions(otherPlayerNames(leaving))
	end)
	window.Gui.Destroying:Connect(function()
		addedConn:Disconnect()
		removingConn:Disconnect()
	end)

	----------------------------------------------------------------------
	-- Misc tab: Fling and Walk fling (from Infinite Yield).
	-- Fling: heavy physical properties + a fast spin (pulsed on / off) with
	--   noclip, so anything you touch gets thrown.
	-- Walk fling: no spinning; every frame your velocity is spiked and then
	--   put back, so you fling whatever you walk into. Also uses noclip.
	-- The two are mutually exclusive. Everything they change (collision,
	-- mass, physical properties) is put back when they are switched off,
	-- when you die, or when the hub is closed.
	----------------------------------------------------------------------
	do
		local LocalPlayer = Players.LocalPlayer
		local misc = window:AddTab("Misc")

		local flingToken = nil -- a fresh table per run; loops stop when it is replaced / cleared
		local walkToken = nil
		local flingBody = nil
		local flingDied = nil
		local walkDied = nil
		local flingOrig = setmetatable({}, { __mode = "k" }) -- [part] = { props, massless }
		local flingToggle, walkFlingToggle

		-- noclip shared by both modes; only parts it turned off are turned back on
		local noclipConn = nil
		local noclipChanged = setmetatable({}, { __mode = "k" })
		local function startNoclip()
			if noclipConn then
				return
			end
			noclipConn = RunService.Stepped:Connect(function()
				local char = LocalPlayer.Character
				if not char then
					return
				end
				-- Use cached character parts instead of GetDescendants every step
				local parts = FrameCache:GetCharacterParts(char, 15)
				for _, d in ipairs(parts) do
					if d.CanCollide then
						noclipChanged[d] = true
						d.CanCollide = false
					end
				end
			end)
		end
		local function stopNoclip()
			if noclipConn then
				noclipConn:Disconnect()
				noclipConn = nil
			end
			for part in pairs(noclipChanged) do
				if part.Parent then
					part.CanCollide = true
				end
			end
			table.clear(noclipChanged)
		end

		local function stopFling()
			flingToken = nil
			if flingDied then
				flingDied:Disconnect()
				flingDied = nil
			end
			if flingBody then
				flingBody:Destroy()
				flingBody = nil
			end
			for part, orig in pairs(flingOrig) do
				if part.Parent then
					part.CustomPhysicalProperties = orig.props
					part.Massless = orig.massless
					part.AssemblyLinearVelocity = Vector3.zero
				end
			end
			table.clear(flingOrig)
			stopNoclip()
		end

		local function stopWalkFling()
			walkToken = nil
			if walkDied then
				walkDied:Disconnect()
				walkDied = nil
			end
			stopNoclip()
		end

		local function startFling()
			stopWalkFling()
			stopFling()
			local char, hum, root = getCharacter()
			if not root then
				window:Notify({ Title = "Fling", Text = "No character to fling with.", Duration = 3 })
				flingToggle:Set(false, true)
				return
			end
			local token = {}
			flingToken = token

			for _, d in ipairs(char:GetDescendants()) do
				if d:IsA("BasePart") then
					flingOrig[d] = { props = d.CustomPhysicalProperties, massless = d.Massless }
					d.CustomPhysicalProperties = PhysicalProperties.new(100, 0.3, 0.5)
				end
			end
			startNoclip()
			task.wait(0.1)
			if flingToken ~= token or not root.Parent then
				return
			end

			local spin = Instance.new("BodyAngularVelocity")
			spin.Name = tostring(math.random(100000000, 999999999))
			spin.AngularVelocity = Vector3.new(0, 99999, 0)
			spin.MaxTorque = Vector3.new(0, math.huge, 0)
			spin.P = math.huge
			spin.Parent = root
			flingBody = spin

			for part in pairs(flingOrig) do
				if part.Parent then
					part.Massless = true
					part.AssemblyLinearVelocity = Vector3.zero
				end
			end
			flingDied = hum.Died:Connect(function()
				flingToggle:Set(false)
			end)

			while flingToken == token do
				spin.AngularVelocity = Vector3.new(0, 99999, 0)
				task.wait(0.2)
				if flingToken ~= token then
					break
				end
				spin.AngularVelocity = Vector3.zero
				task.wait(0.1)
			end
		end

		local function startWalkFling()
			stopFling()
			stopWalkFling()
			local _, hum, root = getCharacter()
			if not root then
				window:Notify({ Title = "Walk fling", Text = "No character to fling with.", Duration = 3 })
				walkFlingToggle:Set(false, true)
				return
			end
			local token = {}
			walkToken = token
			walkDied = hum.Died:Connect(function()
				walkFlingToggle:Set(false)
			end)
			startNoclip()

			-- Optimized: use connections instead of yielding in a loop
			local movel = 0.1
			local savedVel = nil
			local phase = 1 -- 1=heartbeat, 2=render, 3=stepped
			
			local function cycle()
				if walkToken ~= token then
					return
				end
				local _, _, r = getCharacter()
				if not r then
					return
				end
				
				if phase == 1 then
					-- Heartbeat: spike velocity
					savedVel = r.AssemblyLinearVelocity
					r.AssemblyLinearVelocity = savedVel * 10000 + Vector3.new(0, 10000, 0)
					phase = 2
				elseif phase == 2 then
					-- RenderStepped: restore velocity
					if r.Parent and savedVel then
						r.AssemblyLinearVelocity = savedVel
					end
					phase = 3
				elseif phase == 3 then
					-- Stepped: add oscillation
					if r.Parent and savedVel then
						r.AssemblyLinearVelocity = savedVel + Vector3.new(0, movel, 0)
						movel = -movel
					end
					phase = 1
				end
			end
			
			local hb = RunService.Heartbeat:Connect(function()
				if phase == 1 then
					cycle()
				end
			end)
			local rs = RunService.RenderStepped:Connect(function()
				if phase == 2 then
					cycle()
				end
			end)
			local st = RunService.Stepped:Connect(function()
				if phase == 3 then
					cycle()
				end
			end)
			
			-- Clean up connections when stopped
			local oldStop = stopWalkFling
			stopWalkFling = function()
				hb:Disconnect()
				rs:Disconnect()
				st:Disconnect()
				savedVel = nil
				oldStop()
				stopWalkFling = oldStop
			end
		end

		-- toggles fling with its key (set in Settings, default Z)
		local flingKeyConn = UserInputService.InputBegan:Connect(function(input, processed)
			if not processed and not window._listening and Keys.Fling and input.KeyCode == Keys.Fling then
				flingToggle:Set(not flingToggle:Get())
			end
		end)

		window.Gui.Destroying:Connect(function()
			flingKeyConn:Disconnect()
			stopFling()
			stopWalkFling()
		end)

		misc:AddSection("Fling")
		flingToggle = misc:AddToggle({
			Text = "Fling",
			Default = false,
			Callback = function(on)
				if on then
					walkFlingToggle:Set(false, true)
					startFling()
				else
					stopFling()
				end
			end,
		})
		walkFlingToggle = misc:AddToggle({
			Text = "Walk fling",
			Default = false,
			Callback = function(on)
				if on then
					flingToggle:Set(false, true)
					startWalkFling()
				else
					stopWalkFling()
				end
			end,
		})

		------------------------------------------------------------------
		-- Heart: builds a heart out of loose (unanchored) parts at
		-- (0, 250, 0). Parts are claimed the same way as Super Ring Parts
		-- (simulation radius 1000, math.huge doesn't stick + replication focus) so your client owns them,
		-- and every frame each part is steered to its spot on the outline, with the
		-- whole heart slowly turning and bobbing, so it is never still and keeps
		-- its network ownership. The parts are non-solid while in the heart; that,
		-- and their collision, is put back when the toggle goes off.
		-- Character parts, anchored parts and big / welded-together pieces are skipped.
		------------------------------------------------------------------
		do
			local HEART_CENTER = Vector3.new(0, 250, 0)
			local ROT_SPEED = 0.6 -- rad/s the heart turns around the Y axis
			local BOB = 4 -- studs up / down
			local PULL = 12 -- velocity per stud of error
			local MAX_VEL = 250 -- studs/s ceiling for the steering
			local TELEPORT_DIST = 60 -- farther than this from its spot: jump straight there
			local MAX_PIECE_PARTS = 8 -- skip assemblies bigger than this
			local MAX_PIECE_SIZE = 30 -- studs; skip huge pieces
			local PICK_EVERY = 1.5 -- seconds between searches for more parts
			local SIM_RADIUS = 1000 -- the simulation radius to claim parts with
			local partSpin = 500 -- rad/s each part spins on its own axes (keeps ownership); set by the Part spin slider

			local heartOn = false
			local heartConn = nil
			local heartCount = 100 -- parts in use right now (auto: follows what is available; manual: the slider)
			local autoCount = true -- true: part count follows how many owned parts are available
			local manualCount = 100 -- the Heart parts slider, used when autoCount is off
			local AUTO_MAX = 1250 -- ceiling for the automatic part count
			local heartScale = 4
			local slots = {} -- [i] = { asm = part, parts = {...} }
			local changed = {} -- [part] = original CanCollide
			local layout = {} -- [i] = Vector3 point on the heart (unscaled)
			local lastPick = 0
			local origFocus, haveFocus = nil, false

			local hasOwnerCheck = type(isnetworkowner) == "function"
			local function owns(part)
				if not hasOwnerCheck then
					return true
				end
				local ok, res = pcall(isnetworkowner, part)
				return not ok or res
			end

			local overlap = OverlapParams.new()
			overlap.FilterType = Enum.RaycastFilterType.Exclude

			local function claim()
				pcall(function()
					if type(sethiddenproperty) == "function" then
						sethiddenproperty(LocalPlayer, "SimulationRadius", SIM_RADIUS)
						pcall(sethiddenproperty, LocalPlayer, "MaxSimulationRadius", SIM_RADIUS)
					end
					LocalPlayer.MaximumSimulationRadius = SIM_RADIUS
				end)
			end

			-- classic heart curve, t in [0, 2pi)
			local function heartPoint(t)
				local x = 16 * math.sin(t) ^ 3
				local y = 13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t)
				return x, y
			end

			-- concentric heart outlines, outermost first. More parts means more rings
			-- (one per ~50 parts, 2 to 25), each ring getting parts in proportion to its
			-- size, so a big count makes a full, evenly filled heart.
			local function buildLayout()
				table.clear(layout)
				if heartCount < 1 then
					return
				end
				local rings = math.clamp(math.ceil(heartCount / 50), 2, 25)
				local scales, total = {}, 0
				for r = 1, rings do
					scales[r] = 1 - (r - 1) * (0.75 / rings) -- 1.0 down to about 0.3-0.6
					total += scales[r]
				end
				local left = heartCount
				for r = 1, rings do
					local n = (r == rings) and left or math.max(1, math.floor(heartCount * scales[r] / total + 0.5))
					n = math.min(n, left)
					left -= n
					-- offset every other ring by half a step so parts don't line up in spokes
					local phase = (r % 2 == 0) and 0.5 or 0
					for i = 0, n - 1 do
						local x, y = heartPoint(2 * math.pi * (i + phase) / n)
						table.insert(layout, Vector3.new(x * scales[r], y * scales[r] + 2.5, 0))
					end
				end
			end

			local function releaseSlot(i)
				local slot = slots[i]
				slots[i] = nil
				if slot then
					for _, part in ipairs(slot.parts) do
						local orig = changed[part]
						changed[part] = nil
						if orig ~= nil and part.Parent then
							part.CanCollide = orig
						end
					end
				end
			end

			-- takes a piece for slot i: all its connected parts go non-solid
			local function claimPiece(i, asm)
				local ok, list = pcall(asm.GetConnectedParts, asm, true)
				list = ok and list or { asm }
				if #list > MAX_PIECE_PARTS then
					return false
				end
				for _, part in ipairs(list) do
					if changed[part] == nil then
						changed[part] = part.CanCollide
					end
					part.CanCollide = false
				end
				slots[i] = { asm = asm, parts = list }
				return true
			end

			-- loose pieces your client owns (anywhere in the map) that the heart isn't
			-- using yet, nearest first. Only owned pieces are ever returned.
			local function gatherCandidates()
				local used = {}
				for _, slot in pairs(slots) do
					used[slot.asm] = true
				end
				local char = LocalPlayer.Character
				local root = char and char:FindFirstChild("HumanoidRootPart")
				local from = root and root.Position or HEART_CENTER
				local cand, seen = {}, {}
				local exclude = {}
				for _, plr in ipairs(Players:GetPlayers()) do
					if plr.Character then
						table.insert(exclude, plr.Character)
					end
				end
				overlap.FilterDescendantsInstances = exclude
				-- no distance cutoff: any loose part anywhere that your client owns can be used,
				-- including ones outside the simulation radius that you still own
				for _, d in ipairs(workspace:GetDescendants()) do
					if d:IsA("BasePart") and not d.Anchored then
						local asm = d.AssemblyRootPart
						if asm and not seen[asm] and not used[asm] and not asm.Anchored then
							seen[asm] = true
							if asm.Size.Magnitude <= MAX_PIECE_SIZE then
								local model = asm:FindFirstAncestorOfClass("Model")
								if not (model and model:FindFirstChildOfClass("Humanoid")) then
									if owns(asm) then
										table.insert(cand, { asm = asm, dist = (asm.Position - from).Magnitude })
									end
								end
							end
						end
					end
				end
				table.sort(cand, function(a, b)
					return a.dist < b.dist
				end)
				return cand
			end

			-- squeezes the pieces in use together at slots 1..n (no holes)
			local function compactSlots()
				local maxI = 0
				for i in pairs(slots) do
					maxI = math.max(maxI, i)
				end
				local list = {}
				for i = 1, maxI do
					if slots[i] then
						table.insert(list, slots[i])
					end
				end
				for i = 1, maxI do
					slots[i] = list[i]
				end
				return #list
			end

			local function pick()
				if autoCount then
					-- automatic: use every owned piece that is available (up to AUTO_MAX); the
					-- heart's part count and layout follow however many that turns out to be
					local filled = compactSlots()
					local cand = gatherCandidates()
					for _, c in ipairs(cand) do
						if filled >= AUTO_MAX then
							break
						end
						if claimPiece(filled + 1, c.asm) then
							filled += 1
						end
					end
					if filled ~= heartCount then
						heartCount = filled
						buildLayout()
					end
					return
				end

				-- manual: fill the empty slots of the fixed-size heart
				local missing = 0
				for i = 1, heartCount do
					if not slots[i] then
						missing += 1
					end
				end
				if missing == 0 then
					return
				end
				local cand = gatherCandidates()
				local ci = 1
				for i = 1, heartCount do
					if not slots[i] then
						while cand[ci] do
							local asm = cand[ci].asm
							ci += 1
							if claimPiece(i, asm) then
								break
							end
						end
						if not cand[ci] and not slots[i] then
							break -- nothing left to use
						end
					end
				end
			end

			local function step()
				claim()
				local now = os.clock()

				-- drop pieces that vanished, got anchored, or are no longer owned by you
				local needPick = autoCount -- automatic mode keeps looking for newly available parts
				for i = 1, heartCount do
					local slot = slots[i]
					if slot then
						local asm = slot.asm
						if not asm.Parent or asm.Anchored or not owns(asm) then
							releaseSlot(i)
						end
					end
					if not slots[i] then
						needPick = true
					end
				end
				if needPick and now - lastPick >= PICK_EVERY then
					lastPick = now
					pcall(pick)
				end

				-- steer every piece to its spot; the heart turns and bobs so nothing is ever still
				local rot = CFrame.Angles(0, now * ROT_SPEED, 0)
				local center = HEART_CENTER + Vector3.new(0, math.sin(now * 1.5) * BOB, 0)
				for i = 1, heartCount do
					local slot = slots[i]
					local lp = layout[i]
					if slot and lp then
						local asm = slot.asm
						local target = center + rot:VectorToWorldSpace(lp * heartScale)
						local diff = target - asm.Position
						if diff.Magnitude > TELEPORT_DIST then
							asm.CFrame = CFrame.new(target)
							asm.AssemblyLinearVelocity = Vector3.zero
						else
							local v = diff * PULL
							if v.Magnitude > MAX_VEL then
								v = v.Unit * MAX_VEL
							end
							asm.AssemblyLinearVelocity = v
						end
						-- fast spin on the part's own axes (this is the part rotating, not the heart)
						asm.AssemblyAngularVelocity = Vector3.new(partSpin * 0.6, partSpin, partSpin * 0.8)
					end
				end
			end

			local function setHeart(on)
				if on == heartOn then
					return
				end
				heartOn = on
				if heartConn then
					heartConn:Disconnect()
					heartConn = nil
				end
				if on then
					heartCount = autoCount and 0 or manualCount
					buildLayout()
					lastPick = 0
					pcall(function()
						origFocus = LocalPlayer.ReplicationFocus
						haveFocus = true
						LocalPlayer.ReplicationFocus = workspace
					end)
					local okSig, preSim = pcall(function()
						return RunService.PreSimulation
					end)
					heartConn = (okSig and preSim or RunService.Stepped):Connect(step)
				else
					for i in pairs(slots) do
						local slot = slots[i]
						if slot and slot.asm.Parent then
							slot.asm.AssemblyLinearVelocity = Vector3.zero
							slot.asm.AssemblyAngularVelocity = Vector3.zero
						end
						releaseSlot(i)
					end
					for part, orig in pairs(changed) do
						if part.Parent then
							part.CanCollide = orig
						end
					end
					table.clear(changed)
					if haveFocus then
						pcall(function()
							LocalPlayer.ReplicationFocus = origFocus
						end)
						haveFocus = false
					end
				end
			end

			-- changing the size or part count rebuilds the heart; surplus parts are let go
			local function rebuild()
				buildLayout()
				for i in pairs(slots) do
					if i > heartCount then
						releaseSlot(i)
					end
				end
				lastPick = 0
			end

			window.Gui.Destroying:Connect(function()
				setHeart(false)
			end)

			misc:AddSection("Heart")
			misc:AddToggle({
				Text = "Network heart",
				Default = false,
				Callback = setHeart,
			})
			misc:AddToggle({
				Text = "Auto part count",
				Default = true,
				Callback = function(on)
					autoCount = on
					if heartOn then
						if not on then
							heartCount = manualCount
						end
						rebuild()
					end
				end,
			})
			misc:AddSlider({
				Text = "Heart parts (manual)",
				Min = 10, Max = 1250, Default = 100, Step = 10, Suffix = " parts",
				Callback = function(v)
					manualCount = v
					if heartOn and not autoCount then
						heartCount = v
						rebuild()
					end
				end,
			})
			misc:AddSlider({
				Text = "Heart size",
				Min = 1, Max = 10, Default = 4, Step = 0.5, Suffix = "x",
				Callback = function(v)
					heartScale = v
				end,
			})
			misc:AddSlider({
				Text = "Part spin speed",
				Min = 0, Max = 10000, Default = 500, Step = 50, Suffix = " rad/s",
				Callback = function(v)
					partSpin = v
				end,
			})
		end

		------------------------------------------------------------------
		-- Rejoin (same method as Infinite Yield's "rejoin" command):
		--   * other players in the server -> teleport back into this exact server
		--   * you're alone -> kick yourself and teleport to a fresh server of the
		--     same place (teleporting into your own empty server would fail)
		-- "Rejoin at my position" saves your CFrame as teleport data and queues a
		-- tiny script that moves you back there once you load in (needs
		-- queue_on_teleport, so it only works if your executor has it).
		------------------------------------------------------------------
		do
			local TeleportService = game:GetService("TeleportService")
			local queueTp = queue_on_teleport or (syn and syn.queue_on_teleport) or (fluxus and fluxus.queue_on_teleport)
			local keepSpot = false
			local rejoining = false
			local hopping = false

			local RESPAWN_HANDLER = [==[
local ok, data = pcall(function() return game:GetService("TeleportService"):GetLocalPlayerTeleportData() end)
if ok and typeof(data) == "CFrame" then
	local Players = game:GetService("Players")
	local ME = Players.LocalPlayer
	while not ME do
		Players:GetPropertyChangedSignal("LocalPlayer"):Wait()
		ME = Players.LocalPlayer
	end
	local Character = ME.Character or ME.CharacterAdded:Wait()
	Character:WaitForChild("HumanoidRootPart")
	local t = tick()
	while (tick() - t) <= 0.3 do
		Character:PivotTo(data)
		task.wait()
	end
end
]==]

			local function rejoin()
				if rejoining or hopping then
					return
				end
				rejoining = true

				local data = nil
				if keepSpot then
					if queueTp then
						local char = LocalPlayer.Character
						if char then
							data = char:GetPivot()
							queueTp(RESPAWN_HANDLER)
						end
					else
						window:Notify({
							Title = "Rejoin",
							Text = "Your executor has no queue_on_teleport, so it can't restore your position.",
							Duration = 4,
						})
					end
				end

				queueHubReload() -- no-op unless "Keep hub" is on

				window:Notify({ Title = "Rejoin", Text = "Rejoining...", Duration = 3 })
				if #Players:GetPlayers() <= 1 then
					LocalPlayer:Kick("\nRejoining...")
					task.wait(0.3)
					TeleportService:Teleport(game.PlaceId, LocalPlayer, data)
				else
					TeleportService:TeleportToPlaceInstance(game.PlaceId, game.JobId, LocalPlayer, nil, data)
				end

				-- if the teleport failed, let the button work again
				task.delay(10, function()
					rejoining = false
				end)
			end

			----------------------------------------------------------------
			-- Server hop (same method as Infinite Yield's "serverhop"): asks
			-- Roblox's public servers list for this place, drops full servers and
			-- the one you're in, then teleports to a random one of the rest.
			----------------------------------------------------------------
			local function fetch(url)
				local ok, res = pcall(function()
					return game:HttpGet(url)
				end)
				if ok and type(res) == "string" then
					return res
				end
				-- fall back to the executor's request function
				local req = (syn and syn.request) or http_request or request or (fluxus and fluxus.request)
				if req then
					local ok2, r = pcall(req, { Url = url, Method = "GET" })
					if ok2 and type(r) == "table" and type(r.Body) == "string" then
						return r.Body
					end
				end
				return nil
			end

			local function serverHop()
				if hopping or rejoining then
					return
				end
				hopping = true
				window:Notify({ Title = "Server hop", Text = "Looking for a server...", Duration = 3 })

				task.spawn(function()
					local url = "https://games.roblox.com/v1/games/" .. game.PlaceId
						.. "/servers/Public?sortOrder=Desc&limit=100&excludeFullGames=true"
					local servers = {}
					local raw = fetch(url)
					if raw then
						local ok, body = pcall(function()
							return HttpService:JSONDecode(raw)
						end)
						if ok and type(body) == "table" and type(body.data) == "table" then
							for _, v in ipairs(body.data) do
								if type(v) == "table" and tonumber(v.playing) and tonumber(v.maxPlayers)
									and v.playing < v.maxPlayers and v.id ~= game.JobId then
									table.insert(servers, v.id)
								end
							end
						end
					end

					if #servers == 0 then
						window:Notify({
							Title = "Server hop",
							Text = "Couldn't find a server. Try again in a moment.",
							Duration = 4,
						})
						hopping = false
						return
					end

					queueHubReload() -- no-op unless "Keep hub" is on
					window:Notify({ Title = "Server hop", Text = "Joining a new server...", Duration = 3 })
					local ok, err = pcall(function()
						TeleportService:TeleportToPlaceInstance(game.PlaceId, servers[math.random(1, #servers)], LocalPlayer)
					end)
					if not ok then
						warn("Server hop failed:", err)
					end

					-- if the teleport failed, let the button work again
					task.delay(10, function()
						hopping = false
					end)
				end)
			end

			misc:AddSection("Server")
			misc:AddButton({
				Text = "Rejoin server",
				Callback = rejoin,
			})
			misc:AddButton({
				Text = "Server hop",
				Callback = serverHop,
			})
			misc:AddToggle({
				Text = "Rejoin at my position",
				Default = false,
				Callback = function(on)
					keepSpot = on
				end,
			})
			addKeepHubToggle(misc)
		end
	end

	local settings = window:AddTab("Settings")
	settings:AddSection("Display")
	settings:AddDropdown({
		Text = "Quality",
		Options = { "Low", "Medium", "High" },
		Default = "Medium",
		Callback = function(choice)
			print("Quality:", choice)
		end,
	})
	settings:AddTextbox({
		Text = "Nickname",
		Placeholder = "type here…",
		Callback = function(text, enter)
			if enter then
				window:Notify({ Title = "Saved", Text = "Nickname: " .. text })
			end
		end,
	})

	settings:AddSection("Teleport")
	addKeepHubToggle(settings)
	settings:AddLabel("The hub will run again after you teleport, rejoin or server hop.")

	settings:AddSection("Keybinds")
	settings:AddKeybind({
		Text = "Minimize / restore UI",
		Default = Keys.ToggleUI,
		Callback = function(k)
			Keys.ToggleUI = k
			window:SetToggleKey(k)
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Toggle fly",
		Default = Keys.FlyToggle,
		Callback = function(k)
			Keys.FlyToggle = k
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Save player (select / lift / release)",
		Default = Keys.SavePlayer,
		Callback = function(k)
			Keys.SavePlayer = k
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Toggle sprint",
		Default = Keys.Sprint,
		Callback = function(k)
			Keys.Sprint = k
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Toggle vehicle fly",
		Default = Keys.VFlyToggle,
		Callback = function(k)
			Keys.VFlyToggle = k
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Toggle fling",
		Default = Keys.Fling,
		Callback = function(k)
			Keys.Fling = k
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Toggle aimbot",
		Default = Keys.AimbotToggle,
		Callback = function(k)
			Keys.AimbotToggle = k
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Fly forward",
		Default = Keys.Forward,
		Callback = function(k)
			Keys.Forward = k
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Fly back",
		Default = Keys.Back,
		Callback = function(k)
			Keys.Back = k
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Fly left",
		Default = Keys.Left,
		Callback = function(k)
			Keys.Left = k
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Fly right",
		Default = Keys.Right,
		Callback = function(k)
			Keys.Right = k
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Fly up",
		Default = Keys.Up,
		Callback = function(k)
			Keys.Up = k
			saveKeys()
		end,
	})
	settings:AddKeybind({
		Text = "Fly down",
		Default = Keys.Down,
		Callback = function(k)
			Keys.Down = k
			saveKeys()
		end,
	})
	settings:AddLabel("Click a keybind, then press a key · Esc cancels · Backspace unbinds.")
	settings:AddLabel(
		canSave and ("Keybinds, volumes, Chillax mode and the keep-hub setting are saved to workspace/" .. SAVE_FILE)
			or "Your executor has no file access, so keybinds, volumes, Chillax mode and the keep-hub setting won't be saved."
	)

	-- Docs tab: explanations of the options, kept out of the other tabs
	do
		local docs = window:AddTab("Docs")
		docs:AddSection("Chillax mode")
		docs:AddLabel("Turns anti fling, gloomy night and shooting stars on together, and off again when you switch it off. Off by default; if you turn it on it stays on next time.")
		docs:AddSection("Save player")
		docs:AddLabel(
			IsOnMobile
						and "Line the ring in the middle of your screen up with a player and the box shows who's selected. Tap the button on the right to go under them and lift them, tap it again to let go. Speed and height can be changed at any time, even mid-lift; the lift eases in and out and stops at the height you set. While lifting, the Put down buttons in the menu lower them onto the floor and let go automatically; the lift speed slider sets the lowering speed too."
						or "Aim at a player with the mouse (or the screen centre when the mouse is locked) and a box shows who's selected. Press T to go under them and lift them, press T again to let go. Speed and height can be changed at any time, even mid-lift; the lift eases in and out and stops at the height you set. While lifting, the Put down buttons in the menu lower them onto the floor and let go automatically; the lift speed slider sets the lowering speed too. Change the key in Settings > Keybinds."
		)
		docs:AddSection("Sprint")
		docs:AddLabel("Press the sprint key to turn sprinting on and off (R by default, change it in Settings > Keybinds).")
		docs:AddSection("Fly")
		docs:AddLabel("Flies where you look · keys can be changed in Settings  (Infinite Yield)")
		docs:AddSection("Saved settings")
		docs:AddLabel("Aimbot and ESP settings (and your keybinds) are saved to cats_universal_hub_keybinds.json in your executor's workspace folder and come back next time. This includes whether ESP and the aimbot were switched on.")
		docs:AddSection("Aimbot")
		docs:AddLabel("Turns your camera toward the player closest to the aim point inside the FOV circle. Hold right-click to aim on PC, or set Activation to Always on. Aim from: Cursor uses the mouse (the screen centre when the mouse is locked or on touch), Screen center always uses the middle of the screen. Stick to target keeps the same player until they leave the circle. Team check skips teammates, wall check only picks players you can see, higher smoothness turns more slowly, and prediction leads moving targets. It only moves your own camera. Press C to switch it on or off (change the key in Settings > Keybinds). Your settings, and whether it was on, are saved and come back next time.")
		docs:AddSection("Gloomy night")
		docs:AddLabel("Warm dusky night: soft orange haze, a glowing amber moon, stars and gentle color grading. Also hides clouds, and overrides No fog. Turning it off restores the map's lighting.")
		docs:AddSection("Shooting stars")
		docs:AddLabel("Shooting stars only appear where you can see them (red, white and light blue streaks). It switches on with Chillax mode.")
		docs:AddSection("No fog")
		docs:AddLabel("No fog saves the current fog, sets it to 4000 / 4000 and keeps it there (Gloomy night overrides it). Turning it off restores the original fog.")
		docs:AddSection("Fling")
		docs:AddLabel("Spins you at high speed with noclip on, flinging anyone you touch. Press the fling key to toggle it (Z by default, change it in Settings > Keybinds). Turns off when you die.")
		docs:AddSection("Walk fling")
		docs:AddLabel("Like fling but without the spinning: walk into someone to fling them. Uses noclip too, and turns off when you die.")
		docs:AddSection("Network heart")
		docs:AddLabel("Builds a slowly turning heart out of loose parts at (0, 250, 0). The parts are claimed with a simulation radius of 1000, steered every frame, and each part spins fast on its own axes so your client keeps ownership; they are non-solid while in the heart. With Auto part count on, the heart uses every owned loose part it can find (up to 1250, even ones outside the simulation radius) and resizes itself as parts come and go; turn it off to use the Heart parts slider instead. Needs unanchored parts on the map and only ever uses parts your client already owns; a part is let go the moment it stops being yours. Collision is restored when you switch it off.")
		docs:AddSection("Rejoin and server hop")
		docs:AddLabel("Rejoin goes back into the same server (or a new one if you're alone). Server hop joins a different public server. Turn on Keep hub to have the hub start itself again after you load in. Keep hub reloads the script from HUB_URL at the very top of the script, so that link has to point at wherever universal.lua is hosted.")
	end

	-- if Chillax mode was left on last time, switch its features on now that they all exist
	task.defer(function()
		if Saved.Chillax then
			setChillax(true)
		end
	end)
end

loadHub()
