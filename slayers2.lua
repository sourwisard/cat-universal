--[[
	UILib - a small, clean UI library for Roblox (Luau)

	Put this whole file in a LocalScript (e.g. StarterPlayer > StarterPlayerScripts).
	The library is defined at the top; the example menu is at the bottom - delete it
	(everything under the EXAMPLE banner) when you build your own UI.

	API
	  UILib.new(config) -> Window
	    config: Title, Size (Vector2), ToggleKey (Enum.KeyCode, default Insert; false = none), Theme (table of overrides), Parent (Instance),
	             Sidebar (bool, default true), Minimizable (bool, default true)

	  Window:AddTab(name) -> Tab
	  Window:Notify({Title, Text, Duration})
	  Window:Toggle(visible?)
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
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

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
	button.MouseEnter:Connect(function()
		tween(target, 0.12, { BackgroundColor3 = hover })
	end)
	button.MouseLeave:Connect(function()
		tween(target, 0.12, { BackgroundColor3 = normal })
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
		Size = UDim2.new(0, 260, 1, -32),
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
	local function updateScale()
		local cam = workspace.CurrentCamera
		if not cam then
			return
		end
		local vp = cam.ViewportSize
		uiScale.Scale = math.clamp(math.min(vp.X / (size.X + 40), vp.Y / (size.Y + 40)), 0.5, 1)
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
		handle.InputBegan:Connect(function(input)
			if isPress(input) then
				dragging = true
				moved = false
				dragStart = input.Position
				startPos = self.Main.Position
				input.Changed:Connect(function()
					if input.UserInputState == Enum.UserInputState.End then
						dragging = false
						if not moved and onClick then
							onClick()
						end
					end
				end)
			end
		end)
		table.insert(self._connections, UserInputService.InputChanged:Connect(function(input)
			if dragging and isMove(input) then
				local delta = input.Position - dragStart
				if not moved and delta.Magnitude > threshold then
					moved = true
				end
				if moved then
					local d = delta / uiScale.Scale
					self.Main.Position = UDim2.new(
						startPos.X.Scale, startPos.X.Offset + d.X,
						startPos.Y.Scale, startPos.Y.Offset + d.Y
					)
				end
			end
		end))
	end

	makeDraggable(titleBar, 0, nil)
	makeDraggable(bubble, 6, function()
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
	local toggleKey = config.ToggleKey
	if toggleKey == nil then
		toggleKey = Enum.KeyCode.Insert
	end
	if toggleKey then
		table.insert(self._connections, UserInputService.InputBegan:Connect(function(input, processed)
			if not processed and input.KeyCode == toggleKey then
				self:Toggle()
			end
		end))
	end

	return self
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
		corner(8),
		stroke(theme.Stroke, 1),
		padding(10),
		new("UIListLayout", { Padding = UDim.new(0, 2) }),
	})

	new("TextLabel", {
		Text = opts.Title or "Notice",
		Font = theme.FontBold,
		TextSize = 14,
		TextColor3 = theme.Accent,
		TextXAlignment = Enum.TextXAlignment.Left,
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 16),
		LayoutOrder = 1,
		Parent = card,
	})
	new("TextLabel", {
		Text = opts.Text or "",
		Font = theme.Font,
		TextSize = 13,
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
	local label = self:_label(frame, text, { TextColor3 = self.Theme.SubText, TextSize = 13, Size = UDim2.new(1, -24, 1, 0) })
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

----------------------------------------------------------------------
-- EXAMPLE: delete everything below this line when making your own UI
----------------------------------------------------------------------

-- The hub itself. It only runs once the key below has been accepted.
local function loadHub()
	local window = UILib.new({
		Title = "cat's universal hub",
		ToggleKey = Enum.KeyCode.Insert,
		Theme = { Accent = Color3.fromRGB(255, 96, 140) }, -- optional overrides
	})

	----------------------------------------------------------------------
	-- Fly: velocity is lerped every frame, so takeoff, turning and stopping all
	-- ease in and out instead of snapping. The character always faces the camera.
	----------------------------------------------------------------------
	local RunService = game:GetService("RunService")

	-- shared with the NPC travel code further down
	local Travel = {
		Active = false,
		Speed = 150, -- studs/second (sets how long the lerp takes)
		Distance = 4, -- how far short of the NPC to stop
	}

	local Fly = {
		Enabled = false,
		Speed = 60, -- studs/second at full input
		Smoothness = 8, -- higher = snappier, lower = floatier
	}

	local flyParts = {} -- Attachment, LinearVelocity, AlignOrientation
	local flyConn = nil
	local flyVelocity = Vector3.zero
	local flyToggle -- assigned when the menu toggle is created below

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

	local function clearFly()
		if flyConn then
			flyConn:Disconnect()
			flyConn = nil
		end
		for _, part in ipairs(flyParts) do
			part:Destroy()
		end
		table.clear(flyParts)
	end

	local function stopFly()
		Fly.Enabled = false
		clearFly()
		local _, hum = getCharacter()
		if hum then
			hum.PlatformStand = false
			hum:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
	end

	local function startFly()
		local _, hum, root = getCharacter()
		if not hum then
			return false
		end
		clearFly()

		local attachment = Instance.new("Attachment")
		attachment.Name = "FlyAttachment"
		attachment.Parent = root

		local lv = Instance.new("LinearVelocity")
		lv.Attachment0 = attachment
		lv.RelativeTo = Enum.ActuatorRelativeTo.World
		lv.VelocityConstraintMode = Enum.VelocityConstraintMode.Vector
		lv.MaxForce = math.huge
		lv.VectorVelocity = Vector3.zero
		lv.Parent = root

		local ao = Instance.new("AlignOrientation")
		ao.Attachment0 = attachment
		ao.Mode = Enum.OrientationAlignmentMode.OneAttachment
		ao.RigidityEnabled = false
		ao.MaxTorque = math.huge
		ao.Responsiveness = 40
		ao.CFrame = root.CFrame.Rotation
		ao.Parent = root

		flyParts = { attachment, lv, ao }
		flyVelocity = root.AssemblyLinearVelocity
		hum.PlatformStand = true

		flyConn = RunService.RenderStepped:Connect(function(dt)
			if Travel.Active then
				flyVelocity = Vector3.zero -- travelling to an NPC: hold still
				return
			end
			local _, h = getCharacter()
			local cam = workspace.CurrentCamera
			if not h or not cam then
				return
			end

			local look, right = cam.CFrame.LookVector, cam.CFrame.RightVector
			local flatLook = Vector3.new(look.X, 0, look.Z)
			flatLook = flatLook.Magnitude > 1e-3 and flatLook.Unit or Vector3.new(0, 0, -1)
			local flatRight = Vector3.new(right.X, 0, right.Z)
			flatRight = flatRight.Magnitude > 1e-3 and flatRight.Unit or Vector3.new(1, 0, 0)

			-- MoveDirection already merges WASD, gamepad and the mobile thumbstick
			local move = h.MoveDirection
			local fwd = move:Dot(flatLook)
			local strafe = move:Dot(flatRight)

			local vert = 0
			if not UserInputService:GetFocusedTextBox() then
				if UserInputService:IsKeyDown(Enum.KeyCode.Space) or UserInputService:IsKeyDown(Enum.KeyCode.E) then
					vert += 1
				end
				if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.Q) then
					vert -= 1
				end
			end

			-- forward/back follow the camera pitch, so looking up and pressing W climbs
			local dir = look * fwd + right * strafe + Vector3.yAxis * vert
			if dir.Magnitude > 1 then
				dir = dir.Unit
			end

			-- frame-rate independent lerp factor: same feel at 30 or 240 FPS
			local alpha = 1 - math.exp(-Fly.Smoothness * dt)

			flyVelocity = flyVelocity:Lerp(dir * Fly.Speed, alpha)
			lv.VectorVelocity = flyVelocity

			-- always face exactly where the camera looks, up and down included;
			-- moving sideways or backwards never turns or tilts the character.
			-- Pitch is clamped short of straight up/down to avoid a flipped orientation.
			local pitch = math.clamp(math.asin(math.clamp(look.Y, -1, 1)), -math.rad(80), math.rad(80))
			ao.CFrame = CFrame.lookAt(Vector3.zero, flatLook) * CFrame.Angles(pitch, 0, 0)
		end)

		return true
	end

	local function setFly(on)
		if on then
			if not startFly() then
				return false
			end
			Fly.Enabled = true
		else
			stopFly()
		end
		return true
	end

	-- keep flying after a respawn
	local respawnConn = Players.LocalPlayer.CharacterAdded:Connect(function(char)
		if Fly.Enabled then
			char:WaitForChild("Humanoid")
			char:WaitForChild("HumanoidRootPart")
			startFly()
		end
	end)

	-- F toggles flight
	local flyKeyConn = UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.KeyCode == Enum.KeyCode.F and flyToggle then
			flyToggle:Set(not flyToggle:Get())
		end
	end)

	-- removing the UI also stops flying and cleans up
	window.Gui.Destroying:Connect(function()
		stopFly()
		respawnConn:Disconnect()
		flyKeyConn:Disconnect()
	end)

	----------------------------------------------------------------------
	-- NPC travel: smoothly lerp to any NPC in workspace.Humanoids.Regions.Misc.ActiveNpcs
	-- (path to a root: ActiveNpcs.<Name>.<Name>.HumanoidRootPart). The NPC's position is
	-- re-read every frame, so it still works if the NPC walks while you travel.
	----------------------------------------------------------------------
	local npcDropdown -- created with the NPCs tab below
	local npcMap = {} -- display name -> NPC entry under ActiveNpcs
	local npcConns = {}
	local travelToken = 0

	local function getNpcFolder()
		local node = workspace
		for _, name in ipairs({ "Humanoids", "Regions", "Misc", "ActiveNpcs" }) do
			node = node and node:FindFirstChild(name)
		end
		return node
	end

	local function getNpcRoot(entry)
		local inner = entry:FindFirstChild(entry.Name)
		local hrp = inner and inner:FindFirstChild("HumanoidRootPart")
		return hrp or entry:FindFirstChild("HumanoidRootPart", true)
	end

	local function refreshNpcs()
		table.clear(npcMap)
		local names = {}
		local folder = getNpcFolder()
		if folder then
			for _, entry in ipairs(folder:GetChildren()) do
				local name, n = entry.Name, 2
				while npcMap[name] do -- keep duplicate names distinct
					name = entry.Name .. " (" .. n .. ")"
					n += 1
				end
				npcMap[name] = entry
				table.insert(names, name)
			end
		end
		table.sort(names)
		if npcDropdown then
			npcDropdown:SetOptions(names)
		end
		return #names
	end

	local refreshQueued = false
	local function queueRefresh()
		if refreshQueued then
			return
		end
		refreshQueued = true
		task.delay(0.2, function()
			refreshQueued = false
			refreshNpcs()
		end)
	end

	local function watchNpcFolder()
		for _, c in ipairs(npcConns) do
			c:Disconnect()
		end
		table.clear(npcConns)
		local folder = getNpcFolder()
		if folder then
			table.insert(npcConns, folder.ChildAdded:Connect(queueRefresh))
			table.insert(npcConns, folder.ChildRemoved:Connect(queueRefresh))
		end
	end

	local function stopTravel()
		travelToken += 1
		if Travel.Active then
			Travel.Active = false
			local _, _, root = getCharacter()
			if root then
				root.Anchored = false
			end
		end
	end

	local function smoothstep(t)
		return t * t * (3 - 2 * t)
	end

	local function travelTo(entry)
		local _, _, root = getCharacter()
		if not root then
			window:Notify({ Title = "NPCs", Text = "No character to move yet.", Duration = 3 })
			return
		end
		local npcRoot = getNpcRoot(entry)
		if not npcRoot then
			window:Notify({ Title = "NPCs", Text = entry.Name .. " has no HumanoidRootPart.", Duration = 3 })
			return
		end

		stopTravel() -- cancels any travel already running
		local token = travelToken
		Travel.Active = true
		root.Anchored = true -- we drive the position directly; physics stays out of the way
		root.AssemblyLinearVelocity = Vector3.zero

		local startPos = root.Position

		-- stop a little short of the NPC, on the side we came from
		local function goalPos()
			local target = npcRoot.Position
			local away = Vector3.new(startPos.X - target.X, 0, startPos.Z - target.Z)
			if away.Magnitude < 0.1 then
				away = Vector3.new(0, 0, 1)
			end
			return target + away.Unit * Travel.Distance
		end

		local duration = math.clamp((goalPos() - startPos).Magnitude / math.max(Travel.Speed, 1), 0.25, 8)
		local t = 0

		task.spawn(function()
			while Travel.Active and travelToken == token do
				t = math.min(t + RunService.Heartbeat:Wait() / duration, 1)
				if not root.Parent or not npcRoot.Parent then
					break
				end

				-- the lerp: start -> live NPC position, eased in and out
				local pos = startPos:Lerp(goalPos(), smoothstep(t))

				-- face the NPC (heading only); keep current rotation if we're right on top of it
				local lookAt = Vector3.new(npcRoot.Position.X, pos.Y, npcRoot.Position.Z)
				if (lookAt - pos).Magnitude > 0.05 then
					root.CFrame = CFrame.lookAt(pos, lookAt)
				else
					root.CFrame = CFrame.new(pos) * root.CFrame.Rotation
				end
				root.AssemblyLinearVelocity = Vector3.zero

				if t >= 1 then
					break
				end
			end
			if travelToken == token then
				Travel.Active = false
				if root.Parent then
					root.Anchored = false
				end
			end
		end)
	end

	window.Gui.Destroying:Connect(function()
		stopTravel()
		for _, c in ipairs(npcConns) do
			c:Disconnect()
		end
	end)

	local main = window:AddTab("Main")
	main:AddSection("Player")
	main:AddButton({
		Text = "Say hello",
		Callback = function()
			window:Notify({ Title = "Hello", Text = "Button clicked!", Duration = 3 })
		end,
	})
	main:AddToggle({
		Text = "Sprint enabled",
		Default = true,
		Callback = function(on)
			print("Sprint:", on)
		end,
	})
	main:AddSlider({
		Text = "Walk speed",
		Min = 8, Max = 50, Default = 16, Step = 1, Suffix = " st/s",
		Callback = function(v)
			local hum = game.Players.LocalPlayer.Character and game.Players.LocalPlayer.Character:FindFirstChildOfClass("Humanoid")
			if hum then
				hum.WalkSpeed = v
			end
		end,
	})

	main:AddSection("Flight")
	flyToggle = main:AddToggle({
		Text = "Fly (F)",
		Default = false,
		Callback = function(on)
			if not setFly(on) then
				flyToggle:Set(false, true)
				window:Notify({ Title = "Fly", Text = "No character to fly with yet.", Duration = 3 })
			end
		end,
	})
	main:AddSlider({
		Text = "Fly speed",
		Min = 10, Max = 200, Default = Fly.Speed, Step = 5, Suffix = " st/s",
		Callback = function(v)
			Fly.Speed = v
		end,
	})
	main:AddSlider({
		Text = "Fly smoothness",
		Min = 1, Max = 20, Default = Fly.Smoothness, Step = 1,
		Callback = function(v)
			Fly.Smoothness = v
		end,
	})
	main:AddLabel("WASD flies where you look · Space/E up · Ctrl/Q down")

	local npcTab = window:AddTab("NPCs")
	npcTab:AddSection("Go to NPC")
	npcDropdown = npcTab:AddDropdown({
		Text = "NPC",
		Options = {},
		Callback = function(name)
			local entry = npcMap[name]
			if entry then
				travelTo(entry)
			end
		end,
	})
	npcTab:AddButton({
		Text = "Refresh list",
		Callback = function()
			watchNpcFolder()
			local count = refreshNpcs()
			window:Notify({
				Title = "NPCs",
				Text = count > 0 and (count .. " NPCs found.") or "ActiveNpcs folder is empty or missing.",
				Duration = 2,
			})
		end,
	})
	npcTab:AddButton({ Text = "Stop travelling", Callback = stopTravel })
	npcTab:AddSection("Travel")
	npcTab:AddSlider({
		Text = "Travel speed",
		Min = 25, Max = 500, Default = Travel.Speed, Step = 25, Suffix = " st/s",
		Callback = function(v)
			Travel.Speed = v
		end,
	})
	npcTab:AddSlider({
		Text = "Stop distance",
		Min = 2, Max = 20, Default = Travel.Distance, Step = 1, Suffix = " st",
		Callback = function(v)
			Travel.Distance = v
		end,
	})

	-- fill the list once the folder exists (it may stream in after the script starts)
	task.spawn(function()
		for _ = 1, 20 do
			if getNpcFolder() then
				break
			end
			task.wait(0.5)
		end
		watchNpcFolder()
		refreshNpcs()
	end)

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
	settings:AddLabel("Press Insert to hide/show the whole UI.")
end

loadHub()
