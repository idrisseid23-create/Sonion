-- CarInput
-- Reads keyboard, gamepad and the phone buttons, and turns them into one set of driving
-- inputs: Throttle, Brake, Steer, Handbrake, Boost. Also reports one-off presses
-- (Reset, Camera, Exit, Debug).
--
-- Keyboard: W/Up gas, S/Down brake then reverse, A/D or Left/Right steer, Space handbrake,
--           Shift boost, R back to checkpoint, C camera, F get out, T driving info.
-- Gamepad:  RT gas, LT brake, left stick steer, A handbrake, X boost, Y reset,
--           R3 / DPad up camera, B get out.

local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")

local CarMath = require(script.Parent.CarMath)

local CarInput = {}
CarInput.__index = CarInput

local KEYS = {
	Gas = { Enum.KeyCode.W, Enum.KeyCode.Up },
	Brake = { Enum.KeyCode.S, Enum.KeyCode.Down },
	Left = { Enum.KeyCode.A, Enum.KeyCode.Left },
	Right = { Enum.KeyCode.D, Enum.KeyCode.Right },
	Handbrake = { Enum.KeyCode.Space },
	Boost = { Enum.KeyCode.LeftShift, Enum.KeyCode.RightShift },
}

-- One-off presses.
local PRESS_KEYS = {
	[Enum.KeyCode.R] = "Reset",
	[Enum.KeyCode.C] = "Camera",
	[Enum.KeyCode.F] = "Exit",
	[Enum.KeyCode.T] = "Debug",
	[Enum.KeyCode.ButtonY] = "Reset",
	[Enum.KeyCode.ButtonR3] = "Camera",
	[Enum.KeyCode.DPadUp] = "Camera",
	[Enum.KeyCode.ButtonB] = "Exit",
}

local GAMEPAD = Enum.UserInputType.Gamepad1
local ACTION_NAME = "CarDriving"

local function anyKeyDown(list): boolean
	for _, key in list do
		if UserInputService:IsKeyDown(key) then
			return true
		end
	end
	return false
end

-- settings = tune.Input from CarConfig
function CarInput.new(settings)
	local self = setmetatable({}, CarInput)
	self.Settings = settings
	self.Steer = 0
	self.AutoGas = settings.TouchAutoGas
	self.TouchMode = UserInputService:GetLastInputType() == Enum.UserInputType.Touch
	-- The phone buttons write into this table (see CarHud).
	self.Touch = { Gas = false, Brake = false, Left = false, Right = false, Handbrake = false, Boost = false }
	self.Pressed = {}
	self.State = { Throttle = 0, Brake = 0, Steer = 0, Handbrake = false, Boost = false }

	-- Bind every driving key at high priority and "sink" it, so the default game controls
	-- (jumping with Space, shift lock with Shift) don't also fire while you drive.
	local keys = {}
	for _, list in KEYS do
		for _, key in list do
			table.insert(keys, key)
		end
	end
	for key in PRESS_KEYS do
		table.insert(keys, key)
	end
	table.insert(keys, Enum.KeyCode.ButtonA)
	table.insert(keys, Enum.KeyCode.ButtonX)
	ContextActionService:BindActionAtPriority(ACTION_NAME, function(_, inputState, inputObject)
		if inputState == Enum.UserInputState.Begin then
			local press = PRESS_KEYS[inputObject.KeyCode]
			if press then
				self.Pressed[press] = true
			end
		end
		return Enum.ContextActionResult.Sink
	end, false, Enum.ContextActionPriority.High.Value, table.unpack(keys))

	self.InputTypeConnection = UserInputService.LastInputTypeChanged:Connect(function(inputType)
		if inputType == Enum.UserInputType.Touch then
			self.TouchMode = true
		elseif inputType == Enum.UserInputType.Keyboard or inputType == GAMEPAD then
			self.TouchMode = false
		end
	end)
	return self
end

-- Phone buttons and the HUD call this for Reset / Camera / Exit.
function CarInput:Press(name: string)
	self.Pressed[name] = true
end

-- True once after the key/button was pressed.
function CarInput:ConsumePressed(name: string): boolean
	if self.Pressed[name] then
		self.Pressed[name] = nil
		return true
	end
	return false
end

-- Call once per frame. airborne turns off auto-gas so phone players can tilt in the air.
function CarInput:Update(dt: number, airborne: boolean)
	local settings = self.Settings
	local state = self.State
	local touch = self.Touch

	if UserInputService:GetFocusedTextBox() then
		-- Typing in chat: let go of everything.
		state.Throttle, state.Brake, state.Handbrake, state.Boost = 0, 0, false, false
		self.Steer = CarMath.moveTowards(self.Steer, 0, settings.SteerReturnRate * dt)
		state.Steer = self.Steer
		return state
	end

	local gas = if anyKeyDown(KEYS.Gas) or touch.Gas then 1 else 0
	local brake = if anyKeyDown(KEYS.Brake) or touch.Brake then 1 else 0
	local left = anyKeyDown(KEYS.Left) or touch.Left
	local right = anyKeyDown(KEYS.Right) or touch.Right
	local handbrake = anyKeyDown(KEYS.Handbrake) or touch.Handbrake
	local boost = anyKeyDown(KEYS.Boost) or touch.Boost
	local stick = 0

	if UserInputService.GamepadEnabled and UserInputService:GetGamepadConnected(GAMEPAD) then
		for _, inputObject in UserInputService:GetGamepadState(GAMEPAD) do
			local key = inputObject.KeyCode
			if key == Enum.KeyCode.ButtonR2 then
				gas = math.max(gas, inputObject.Position.Z)
			elseif key == Enum.KeyCode.ButtonL2 then
				brake = math.max(brake, inputObject.Position.Z)
			elseif key == Enum.KeyCode.Thumbstick1 then
				local x = inputObject.Position.X
				local deadzone = settings.StickDeadzone
				if math.abs(x) > deadzone then
					stick = math.sign(x) * (math.abs(x) - deadzone) / (1 - deadzone)
				end
			end
		end
		handbrake = handbrake or UserInputService:IsGamepadButtonDown(GAMEPAD, Enum.KeyCode.ButtonA)
		boost = boost or UserInputService:IsGamepadButtonDown(GAMEPAD, Enum.KeyCode.ButtonX)
	end

	-- Phone auto-gas: on unless you're braking (or in the air).
	if self.TouchMode and self.AutoGas and not airborne and brake == 0 then
		gas = 1
	end

	-- Steering. Keys ramp in smoothly; letting go or switching sides is quicker.
	if math.abs(stick) > 0.01 then
		self.Steer += (stick - self.Steer) * CarMath.approach(20, dt)
	else
		local target = (if right then 1 else 0) - (if left then 1 else 0)
		local rate = settings.SteerRate
		if target == 0 or (self.Steer ~= 0 and math.sign(target) ~= math.sign(self.Steer)) then
			rate = settings.SteerReturnRate
		end
		self.Steer = CarMath.moveTowards(self.Steer, target, rate * dt)
	end

	state.Throttle = gas
	state.Brake = brake
	state.Steer = self.Steer
	state.Handbrake = handbrake
	state.Boost = boost
	return state
end

function CarInput:Destroy()
	ContextActionService:UnbindAction(ACTION_NAME)
	if self.InputTypeConnection then
		self.InputTypeConnection:Disconnect()
	end
end

return CarInput
