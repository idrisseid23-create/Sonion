-- WheelVisuals
-- Moves the wheel parts so they spin, steer and follow the suspension. Every player's
-- computer runs this for every car it can see. For the car you drive it copies the
-- physics exactly; for other cars it works the wheels out from how the car is moving.

local CarMath = require(script.Parent.CarMath)

local WheelVisuals = {}
WheelVisuals.__index = WheelVisuals

local MAX_REMOTE_STEER = math.rad(35)

function WheelVisuals.new(car: Model, tune)
	local self = setmetatable({}, WheelVisuals)
	self.Car = car
	self.Chassis = car.PrimaryPart
	self.Tune = tune
	self.Wheels = {}
	self.SteerEstimate = 0

	local folder = car:FindFirstChild("Wheels")
	local frontZ, rearZ = 0, 0
	if folder and self.Chassis then
		for _, wheelPart in folder:GetChildren() do
			local motor = wheelPart:FindFirstChild("Axle")
			local attachment = self.Chassis:FindFirstChild(wheelPart.Name)
			if motor and motor:IsA("Motor6D") and attachment then
				local isFront = string.sub(wheelPart.Name, 6, 6) == "F"
				table.insert(self.Wheels, {
					Name = wheelPart.Name,
					Motor = motor,
					Mount = attachment.Position,
					IsFront = isFront,
					Spin = 0,
					Extension = tune.Suspension.Travel * 0.7,
				})
				if isFront then
					frontZ = attachment.Position.Z
				else
					rearZ = attachment.Position.Z
				end
			end
		end
	end
	self.WheelBase = math.max(math.abs(rearZ - frontZ), 1)

	self.RayParams = RaycastParams.new()
	self.RayParams.ExcludeInstances = { car }
	self.RayParams.RespectCanCollide = true
	self.RayParams.IgnoreWater = true
	return self
end

-- physics: the CarPhysics you are driving with (nil for other people's cars).
function WheelVisuals:Update(dt: number, physics)
	local chassis = self.Chassis
	if not chassis or chassis.Parent == nil or #self.Wheels == 0 then
		return
	end
	local tune = self.Tune
	local travel = tune.Suspension.Travel
	local radius = tune.Wheels.Radius

	if physics then
		local byName = {}
		for _, wheel in physics.Wheels do
			byName[wheel.Name] = wheel
		end
		for _, wheel in self.Wheels do
			local source = byName[wheel.Name]
			if source then
				wheel.Extension = CarMath.clamp(source.Extension, 0, travel)
				wheel.SpinSpeed = source.SpinSpeed
				wheel.Steer = if wheel.IsFront then physics.SteerAngle else 0
			end
		end
	else
		local cf = chassis.CFrame
		local up = cf.UpVector
		local forwardSpeed = chassis.AssemblyLinearVelocity:Dot(cf.LookVector)
		local yawRate = chassis.AssemblyAngularVelocity:Dot(up)
		local steerTarget = 0
		if math.abs(forwardSpeed) > 3 then
			steerTarget = CarMath.clamp(math.atan(self.WheelBase * -yawRate / forwardSpeed), -MAX_REMOTE_STEER, MAX_REMOTE_STEER)
		end
		self.SteerEstimate += (steerTarget - self.SteerEstimate) * CarMath.approach(10, dt)

		local follow = CarMath.approach(25, dt)
		for _, wheel in self.Wheels do
			local origin = cf:PointToWorldSpace(wheel.Mount) + up * radius
			local hit = workspace:Raycast(origin, -up * (travel + 2 * radius), self.RayParams)
			local target = if hit then CarMath.clamp(hit.Distance - 2 * radius, 0, travel) else travel
			wheel.Extension += (target - wheel.Extension) * follow
			wheel.SpinSpeed = forwardSpeed / radius
			wheel.Steer = if wheel.IsFront then self.SteerEstimate else 0
		end
	end

	for _, wheel in self.Wheels do
		-- Rolling forward turns the wheel backwards around its axle (the X axis).
		wheel.Spin = (wheel.Spin - (wheel.SpinSpeed or 0) * dt) % (2 * math.pi)
		wheel.Motor.Transform = CFrame.new(0, -wheel.Extension, 0)
			* CFrame.Angles(0, -(wheel.Steer or 0), 0)
			* CFrame.Angles(wheel.Spin, 0, 0)
	end
end

return WheelVisuals
