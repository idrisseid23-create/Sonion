-- CarHud
-- Speedometer, boost meter, stunt pop-ups, the phone buttons, a "spawn a car" panel for
-- when you're on foot, and a driving-info panel for tuning (T key).

local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local CarHud = {}
CarHud.__index = CarHud

local COLORS = {
	Panel = Color3.fromRGB(30, 33, 40),
	Stroke = Color3.fromRGB(52, 57, 68),
	Text = Color3.fromRGB(243, 240, 232),
	Muted = Color3.fromRGB(167, 173, 184),
	Orange = Color3.fromRGB(255, 122, 26),
	Blue = Color3.fromRGB(69, 196, 234),
	Gold = Color3.fromRGB(255, 184, 31),
	Red = Color3.fromRGB(255, 77, 77),
}

local KMH_PER_STUD = 0.28 * 3.6 -- studs per second to km/h

local function create(className: string, props, children)
	local instance = Instance.new(className)
	for key, value in props do
		if key ~= "Parent" then
			instance[key] = value
		end
	end
	for _, child in children or {} do
		child.Parent = instance
	end
	if props.Parent then
		instance.Parent = props.Parent
	end
	return instance
end

local function corner(radius: number)
	return create("UICorner", { CornerRadius = UDim.new(0, radius) })
end

local function stroke(color: Color3, thickness: number?)
	return create("UIStroke", { Color = color, Thickness = thickness or 2, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

local function label(props)
	local defaults = {
		BackgroundTransparency = 1,
		Font = Enum.Font.GothamBold,
		TextColor3 = COLORS.Text,
		TextScaled = false,
	}
	for key, value in props do
		defaults[key] = value
	end
	return create("TextLabel", defaults)
end

local function button(props)
	local defaults = {
		BackgroundColor3 = COLORS.Panel,
		BackgroundTransparency = 0.15,
		Font = Enum.Font.GothamBlack,
		TextColor3 = COLORS.Text,
		TextSize = 18,
		AutoButtonColor = true,
		Active = true,
	}
	for key, value in props do
		defaults[key] = value
	end
	return create("TextButton", defaults, { corner(16), stroke(COLORS.Stroke) })
end

-- Makes a button that counts as held while any finger (or the mouse) is on it.
local function holdable(guiButton: GuiButton, onChange: (boolean) -> ())
	local active = {}
	local function refresh()
		onChange(next(active) ~= nil)
	end
	guiButton.InputBegan:Connect(function(input)
		local kind = input.UserInputType
		if kind == Enum.UserInputType.Touch or kind == Enum.UserInputType.MouseButton1 then
			active[input] = true
			refresh()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if active[input] then
			active[input] = nil
			refresh()
		end
	end)
	return function()
		table.clear(active)
		refresh()
	end
end

function CarHud.new(player: Player)
	local self = setmetatable({}, CarHud)
	self.ShowDebug = false
	self.Input = nil
	self.OnSpawnRequest = nil -- function(carName)

	local gui = create("ScreenGui", {
		Name = "CarHud",
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	self.Gui = gui

	------------------------------------------------------------------------ driving HUD
	local driving = create("Frame", {
		Name = "Driving",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = gui,
	})
	self.Driving = driving

	local speedPanel = create("Frame", {
		Name = "Speed",
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -20),
		Size = UDim2.fromOffset(210, 92),
		BackgroundColor3 = COLORS.Panel,
		BackgroundTransparency = 0.2,
		Parent = driving,
	}, { corner(14), stroke(COLORS.Stroke) })
	self.SpeedLabel = label({
		Position = UDim2.fromOffset(0, 6),
		Size = UDim2.new(1, 0, 0, 48),
		Font = Enum.Font.GothamBlack,
		TextSize = 46,
		Text = "0",
		Parent = speedPanel,
	})
	self.UnitLabel = label({
		Position = UDim2.fromOffset(0, 50),
		Size = UDim2.new(1, 0, 0, 14),
		TextSize = 12,
		TextColor3 = COLORS.Muted,
		Text = "KM/H",
		Parent = speedPanel,
	})
	local boostBack = create("Frame", {
		Name = "BoostBar",
		Position = UDim2.new(0, 14, 1, -18),
		Size = UDim2.new(1, -28, 0, 8),
		BackgroundColor3 = Color3.fromRGB(52, 57, 68),
		Parent = speedPanel,
	}, { corner(4) })
	self.BoostFill = create("Frame", {
		Size = UDim2.fromScale(0.5, 1),
		BackgroundColor3 = COLORS.Orange,
		Parent = boostBack,
	}, { corner(4) })

	self.StateLabel = label({
		AnchorPoint = Vector2.new(0.5, 1),
		Position = UDim2.new(0.5, 0, 1, -118),
		Size = UDim2.fromOffset(300, 30),
		Font = Enum.Font.GothamBlack,
		TextSize = 24,
		TextColor3 = COLORS.Orange,
		TextStrokeTransparency = 0.5,
		Text = "",
		Parent = driving,
	})

	self.PopupLabel = label({
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.28),
		Size = UDim2.fromOffset(600, 50),
		Font = Enum.Font.GothamBlack,
		TextSize = 36,
		TextStrokeTransparency = 0.4,
		TextTransparency = 1,
		Text = "",
		Parent = driving,
	})

	-- Top-right buttons (work with mouse and touch; keys shown for keyboard players).
	local topRight = create("Frame", {
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -16, 0, 60),
		Size = UDim2.fromOffset(120, 220),
		BackgroundTransparency = 1,
		Parent = driving,
	}, {
		create("UIListLayout", { Padding = UDim.new(0, 8), HorizontalAlignment = Enum.HorizontalAlignment.Right }),
	})
	local function topButton(name: string, text: string, order: number)
		local b = button({ Name = name, Text = text, Size = UDim2.fromOffset(120, 44), TextSize = 15, LayoutOrder = order, Parent = topRight })
		b.Activated:Connect(function()
			if self.Input then
				self.Input:Press(name)
			end
		end)
		return b
	end
	topButton("Reset", "RESET  [R]", 1)
	topButton("Camera", "CAMERA  [C]", 2)
	topButton("Exit", "GET OUT  [F]", 3)
	self.AutoGasButton = button({ Name = "AutoGas", Text = "AUTO-GAS ON", Size = UDim2.fromOffset(120, 44), TextSize = 13, LayoutOrder = 4, Visible = false, Parent = topRight })
	self.AutoGasButton.Activated:Connect(function()
		if self.Input then
			self.Input.AutoGas = not self.Input.AutoGas
		end
	end)

	------------------------------------------------------------------------ phone buttons
	local touch = create("Frame", {
		Name = "Touch",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Visible = false,
		Parent = driving,
	})
	self.TouchFrame = touch
	self.TouchButtons = {}
	self.TouchReleases = {}
	local function touchButton(name: string, text: string, size: number, position: UDim2, anchor: Vector2, color: Color3?)
		local b = button({
			Name = name,
			Text = text,
			Size = UDim2.fromOffset(size, size),
			Position = position,
			AnchorPoint = anchor,
			TextSize = 20,
			BackgroundColor3 = color or COLORS.Panel,
			AutoButtonColor = false,
			Parent = touch,
		})
		local release = holdable(b, function(down)
			if self.Input then
				self.Input.Touch[name] = down
			end
			b.BackgroundTransparency = if down then 0 else 0.15
		end)
		self.TouchButtons[name] = b
		table.insert(self.TouchReleases, release)
		return b
	end
	-- Left thumb steers. Right thumb: gas, brake, drift, boost. Middle stays clear.
	touchButton("Left", "◀", 112, UDim2.new(0, 24, 1, -24), Vector2.new(0, 1))
	touchButton("Right", "▶", 112, UDim2.new(0, 150, 1, -24), Vector2.new(0, 1))
	touchButton("Gas", "GAS", 132, UDim2.new(1, -24, 1, -24), Vector2.new(1, 1), Color3.fromRGB(60, 120, 60))
	touchButton("Brake", "BRAKE", 104, UDim2.new(1, -170, 1, -24), Vector2.new(1, 1), Color3.fromRGB(130, 50, 50))
	touchButton("Handbrake", "DRIFT", 96, UDim2.new(1, -174, 1, -142), Vector2.new(1, 1))
	local boostButton = touchButton("Boost", "BOOST", 96, UDim2.new(1, -42, 1, -170), Vector2.new(1, 1))
	boostButton.ClipsDescendants = true
	self.TouchBoostFill = create("Frame", {
		AnchorPoint = Vector2.new(0, 1),
		Position = UDim2.fromScale(0, 1),
		Size = UDim2.fromScale(1, 0.5),
		BackgroundColor3 = COLORS.Orange,
		BackgroundTransparency = 0.45,
		ZIndex = 0,
		Parent = boostButton,
	})

	------------------------------------------------------------------------ spawn panel
	local garage = create("Frame", {
		Name = "Garage",
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, 16, 0.5, 0),
		Size = UDim2.fromOffset(190, 220),
		BackgroundColor3 = COLORS.Panel,
		BackgroundTransparency = 0.15,
		Parent = gui,
	}, {
		corner(14),
		stroke(COLORS.Stroke),
		create("UIPadding", {
			PaddingTop = UDim.new(0, 12),
			PaddingBottom = UDim.new(0, 12),
			PaddingLeft = UDim.new(0, 12),
			PaddingRight = UDim.new(0, 12),
		}),
		create("UIListLayout", { Padding = UDim.new(0, 8), SortOrder = Enum.SortOrder.LayoutOrder }),
	})
	self.Garage = garage
	label({ Text = "SPAWN A CAR", Size = UDim2.new(1, 0, 0, 18), TextSize = 14, TextColor3 = COLORS.Orange, LayoutOrder = 0, Parent = garage })
	for index, carName in { "Bolt", "Mule", "Kite" } do
		local b = button({ Name = carName, Text = string.upper(carName), Size = UDim2.new(1, 0, 0, 38), TextSize = 16, LayoutOrder = index, Parent = garage })
		b.Activated:Connect(function()
			if self.OnSpawnRequest then
				self.OnSpawnRequest(carName)
			end
		end)
	end
	label({
		Text = "Walk up to your car and press E to drive.",
		Size = UDim2.new(1, 0, 0, 34),
		TextSize = 12,
		TextWrapped = true,
		TextColor3 = COLORS.Muted,
		LayoutOrder = 10,
		Parent = garage,
	})

	------------------------------------------------------------------------ driving info (T)
	self.DebugLabel = label({
		Name = "DrivingInfo",
		Position = UDim2.fromOffset(16, 60),
		Size = UDim2.fromOffset(380, 300),
		BackgroundTransparency = 0.3,
		BackgroundColor3 = Color3.fromRGB(10, 10, 12),
		Font = Enum.Font.Code,
		TextSize = 14,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		Visible = false,
		Text = "",
		Parent = driving,
	})

	return self
end

function CarHud:SetDriving(on: boolean, input)
	self.Driving.Visible = on
	self.Garage.Visible = not on
	self.Input = if on then input else nil
	if not on then
		for _, release in self.TouchReleases do
			release()
		end
	end
end

function CarHud:ToggleDebug()
	self.ShowDebug = not self.ShowDebug
	self.DebugLabel.Visible = self.ShowDebug
end

function CarHud:Popup(text: string, color: Color3?)
	local popup = self.PopupLabel
	if self.PopupTween then
		self.PopupTween:Cancel()
	end
	popup.Text = text
	popup.TextColor3 = color or COLORS.Text
	popup.TextTransparency = 0
	popup.TextStrokeTransparency = 0.4
	self.PopupTween = TweenService:Create(
		popup,
		TweenInfo.new(0.8, Enum.EasingStyle.Quad, Enum.EasingDirection.In, 0, false, 0.7),
		{ TextTransparency = 1, TextStrokeTransparency = 1 }
	)
	self.PopupTween:Play()
end

function CarHud:OnCarEvent(name: string, data: any)
	if name == "CleanLanding" then
		self:Popup("CLEAN LANDING  +10", COLORS.Blue)
	elseif name == "Flip" then
		local text = if data == 1 then "FLIP!" else ("FLIP x" .. data .. "!")
		self:Popup(text .. "  +" .. (25 * data), COLORS.Gold)
	elseif name == "RoughLanding" then
		self:Popup("ROUGH LANDING", COLORS.Muted)
	elseif name == "Crashed" then
		self:Popup("CRASHED!", COLORS.Red)
	elseif name == "Checkpoint" then
		self:Popup("CHECKPOINT", COLORS.Blue)
	end
end

function CarHud:Update(physics)
	local input = self.Input
	local kmh = math.floor(physics.Speed * KMH_PER_STUD + 0.5)
	self.SpeedLabel.Text = tostring(kmh)
	self.UnitLabel.Text = if physics.DriveDirection == -1 then "KM/H  ·  REVERSE" else "KM/H"

	local fraction = physics.Boost / physics.Tune.Boost.Max
	self.BoostFill.Size = UDim2.fromScale(fraction, 1)
	self.BoostFill.BackgroundColor3 = if physics.Boosting then COLORS.Blue else COLORS.Orange
	self.TouchBoostFill.Size = UDim2.fromScale(1, fraction)

	local state = physics.State
	if state == "Drifting" then
		self.StateLabel.Text = "DRIFT"
		self.StateLabel.TextColor3 = COLORS.Orange
	elseif state == "Airborne" then
		self.StateLabel.Text = string.format("AIR  %.1fs", physics.AirTime)
		self.StateLabel.TextColor3 = COLORS.Blue
	elseif physics.Boosting then
		self.StateLabel.Text = "BOOST"
		self.StateLabel.TextColor3 = COLORS.Blue
	else
		self.StateLabel.Text = ""
	end

	-- Phone buttons: show them for touch players, and relabel them in the air.
	if input then
		local showTouch = input.TouchMode or (UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled)
		self.TouchFrame.Visible = showTouch
		self.AutoGasButton.Visible = showTouch
		self.AutoGasButton.Text = if input.AutoGas then "AUTO-GAS ON" else "AUTO-GAS OFF"
		if showTouch then
			local air = state == "Airborne"
			local buttons = self.TouchButtons
			buttons.Gas.Text = if air then "NOSE\n▼" else "GAS"
			buttons.Brake.Text = if air then "NOSE\n▲" else "BRAKE"
			buttons.Left.Text = if air then "SPIN\n◀" else "◀"
			buttons.Right.Text = if air then "SPIN\n▶" else "▶"
			buttons.Handbrake.Text = if air then "ROLL" else "DRIFT"
		end
	end

	if self.ShowDebug then
		local lines = {
			string.format("state     %s", state),
			string.format("speed     %.1f studs/s  (%d km/h)", physics.Speed, kmh),
			string.format("forward   %.1f   gear %s", physics.ForwardSpeed, if physics.DriveDirection == 1 then "D" else "R"),
			string.format("slide     %.1f deg", math.deg(physics.SlideAngle)),
			string.format("steer     %.1f deg", math.deg(physics.SteerAngle)),
			string.format("boost     %.0f", physics.Boost),
			string.format("rear grip %.2f (drift)", physics.DriftGrip),
			string.format("wheels down %d / %d", physics.GroundedWheels, #physics.Wheels),
			"",
			"wheel  squash  load  grip  slide",
		}
		for _, wheel in physics.Wheels do
			table.insert(lines, string.format("%-6s %5.2f  %4.2f  %4.2f  %s", string.sub(wheel.Name, 6), wheel.Compression, wheel.Load, wheel.Grip, if wheel.Sliding then "yes" else ""))
		end
		self.DebugLabel.Text = table.concat(lines, "\n")
	end
end

return CarHud
