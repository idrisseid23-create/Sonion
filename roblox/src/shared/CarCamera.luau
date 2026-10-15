-- CarCamera
-- Chase camera from the Driving blueprint:
--   * 6 m behind and 2.2 m up, following with a small lag (about 0.15 s)
--   * field of view widens from 70 at rest to 85 at top speed
--   * swings a little to the outside of drifts so you see the corner
--   * in the air the horizon stays level: the car spins, the camera does not
--   * after a crash it cuts straight back (Snap)
-- Hold the right mouse button (or drag on a phone, or use the right stick) to look around.
-- It drifts back behind the car when you let go. C switches Chase / Far / Hood.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local CarMath = require(script.Parent.CarMath)

local CarCamera = {}
CarCamera.__index = CarCamera

local BIND_NAME = "CarChaseCamera"
local MOUSE_SENSITIVITY = 0.004
local TOUCH_SENSITIVITY = 0.008
local STICK_SPEED = 3 -- radians per second
local MAX_ORBIT_PITCH = 0.9

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function yawOf(direction: Vector3): number
	return math.atan2(-direction.X, -direction.Z)
end

function CarCamera.new(car: Model, tune, physics)
	local self = setmetatable({}, CarCamera)
	self.Car = car
	self.Chassis = car.PrimaryPart
	self.Tune = tune
	self.Settings = tune.Camera
	self.Physics = physics
	self.Camera = workspace.CurrentCamera
	self.ModeIndex = 1
	self.OrbitYaw = 0
	self.OrbitPitch = 0
	self.LastOrbit = 0
	self.Fov = self.Settings.FovSlow
	self.Yaw = 0
	self.FocusY = 0
	self.NeedsSnap = true
	self.Connections = {}

	self.RayParams = RaycastParams.new()
	self.RayParams.RespectCanCollide = true
	self.RayParams.IgnoreWater = true
	self:_refreshIgnore()

	self.Camera.CameraType = Enum.CameraType.Scriptable

	table.insert(self.Connections, UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and input.UserInputType == Enum.UserInputType.MouseButton2 then
			UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition
		end
	end))
	table.insert(self.Connections, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton2 then
			UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		end
	end))
	table.insert(self.Connections, UserInputService.InputChanged:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement
			and UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton2) then
			self:_orbit(input.Delta.X * MOUSE_SENSITIVITY, input.Delta.Y * MOUSE_SENSITIVITY)
		elseif input.UserInputType == Enum.UserInputType.Touch then
			self:_orbit(input.Delta.X * TOUCH_SENSITIVITY, input.Delta.Y * TOUCH_SENSITIVITY)
		end
	end))

	RunService:BindToRenderStep(BIND_NAME, Enum.RenderPriority.Camera.Value + 1, function(dt)
		self:Update(dt)
	end)
	return self
end

function CarCamera:_refreshIgnore()
	local exclude = { self.Car }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	self.RayParams.ExcludeInstances = exclude
end

function CarCamera:_orbit(dx: number, dy: number)
	self.OrbitYaw -= dx
	self.OrbitPitch = CarMath.clamp(self.OrbitPitch + dy, -0.3, MAX_ORBIT_PITCH)
	self.LastOrbit = os.clock()
end

function CarCamera:NextMode()
	self.ModeIndex = self.ModeIndex % #self.Settings.Modes + 1
	self.NeedsSnap = true
	return self.Settings.Modes[self.ModeIndex].Name
end

-- Jump straight to the right place (after respawning).
function CarCamera:Snap()
	self.NeedsSnap = true
end

function CarCamera:Update(dt: number)
	local chassis = self.Chassis
	if not chassis or chassis.Parent == nil then
		return
	end
	local settings = self.Settings
	local physics = self.Physics
	local camera = self.Camera
	local mode = settings.Modes[self.ModeIndex]
	local cf = chassis.CFrame
	local position = cf.Position
	local speedFraction = math.min(physics.Speed / self.Tune.Engine.TopSpeed, 1)

	-- Gamepad right stick looks around.
	if UserInputService.GamepadEnabled and UserInputService:GetGamepadConnected(Enum.UserInputType.Gamepad1) then
		for _, input in UserInputService:GetGamepadState(Enum.UserInputType.Gamepad1) do
			if input.KeyCode == Enum.KeyCode.Thumbstick2 and input.Position.Magnitude > 0.2 then
				self:_orbit(input.Position.X * STICK_SPEED * dt, -input.Position.Y * STICK_SPEED * dt)
			end
		end
	end

	-- Field of view: wider when fast, a bit more while boosting.
	local fovTarget = CarMath.lerp(settings.FovSlow, settings.FovFast, speedFraction)
		+ (if physics.Boosting then settings.BoostFov else 0)
	self.Fov += (fovTarget - self.Fov) * CarMath.approach(4, dt)
	camera.FieldOfView = self.Fov

	if mode.Hood then
		local body = self.Tune.Body
		local eye = Vector3.new(0, body.Size.Y / 2 + body.CabinSize.Y * 0.75, body.CabinOffset.Z - body.CabinSize.Z / 2 - 0.4)
		camera.CFrame = cf * CFrame.new(eye)
		camera.Focus = cf
		self.NeedsSnap = true
		return
	end

	-- Which way the camera should face.
	local direction
	if physics.State == "Airborne" then
		-- In the air follow where you're flying, not how the car is spinning.
		local travel = flat(chassis.AssemblyLinearVelocity)
		direction = if travel.Magnitude > 10 then travel.Unit else nil
	else
		local heading = flat(cf.LookVector)
		if heading.Magnitude > 0.2 then
			direction = heading.Unit
			if physics.State == "Drifting" then
				-- Swing outward so the corner stays in view.
				local swing = physics.SlideAngle * settings.DriftSwing
				direction = CFrame.Angles(0, swing, 0):VectorToWorldSpace(direction)
			end
		end
	end
	local desiredYaw = if direction then yawOf(direction) else self.Yaw

	if self.NeedsSnap then
		self.Yaw = desiredYaw
		self.FocusY = position.Y
		self.OrbitYaw, self.OrbitPitch = 0, 0
		self.NeedsSnap = false
		self:_refreshIgnore()
	else
		self.Yaw += CarMath.wrapAngle(desiredYaw - self.Yaw) * CarMath.approach(1 / settings.Lag, dt)
		self.FocusY += (position.Y - self.FocusY) * CarMath.approach(12, dt)
	end

	-- Let go of the mouse / stick / screen: drift back behind the car.
	if os.clock() - self.LastOrbit > settings.OrbitReturnDelay then
		local back = CarMath.approach(4, dt)
		self.OrbitYaw -= CarMath.wrapAngle(self.OrbitYaw) * back
		self.OrbitPitch -= self.OrbitPitch * back
	end

	local yaw = self.Yaw + self.OrbitYaw
	local look = Vector3.new(-math.sin(yaw), 0, -math.cos(yaw))
	local distance = mode.Distance + settings.SpeedPullBack * speedFraction
	local height = mode.Height + self.OrbitPitch * distance
	local focus = Vector3.new(position.X, self.FocusY + settings.FocusHeight, position.Z)
	local cameraPosition = focus - look * distance + Vector3.new(0, height, 0)
	local lookAt = focus + look * settings.LookAhead

	-- Don't go through walls.
	local offset = cameraPosition - focus
	local hit = workspace:Raycast(focus, offset, self.RayParams)
	if hit then
		cameraPosition = hit.Position - offset.Unit * 0.6
	end

	camera.CFrame = CFrame.lookAt(cameraPosition, lookAt)
	camera.Focus = CFrame.new(focus) -- Roblox loads detail and lighting around this point
end

function CarCamera:Destroy()
	RunService:UnbindFromRenderStep(BIND_NAME)
	for _, connection in self.Connections do
		connection:Disconnect()
	end
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	local camera = self.Camera
	camera.CameraType = Enum.CameraType.Custom
	camera.FieldOfView = 70
	local character = Players.LocalPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		camera.CameraSubject = humanoid
	end
end

return CarCamera
