-- CarPhysics
-- The driving. Runs once per frame for one car and pushes it around with two constraints
-- on the Chassis: CarForce (a VectorForce) and CarTorque (a Torque).
--
-- How it works (from the Driving blueprint):
--   1. Four wheel casts. Each corner casts down. If it hits ground, a spring pushes up.
--   2. Engine push along the nose, only while wheels touch the ground.
--   3. Sideways grip: every frame cancel part of the sideways sliding. Less = more drift.
--   4. Downforce grows with speed.
--   5. In the air, the steering keys rotate the car instead.
--
-- The driver's computer runs this for the car it drives. The server runs it for empty cars
-- (Driver = false) so parked cars sit on their suspension and keep their brakes on.

local CarMath = require(script.Parent.CarMath)

local clamp = CarMath.clamp
local lerp = CarMath.lerp

local CarPhysics = {}
CarPhysics.__index = CarPhysics

CarPhysics.WheelNames = { "WheelFL", "WheelFR", "WheelRL", "WheelRR" }

-- States from the blueprint's state diagram.
CarPhysics.States = {
	Grounded = "Grounded",
	Drifting = "Drifting",
	Airborne = "Airborne",
	Crashed = "Crashed",
}

local NO_INPUT = { Throttle = 0, Brake = 0, Steer = 0, Handbrake = false, Boost = false }
local PARKED_INPUT = { Throttle = 0, Brake = 1, Steer = 0, Handbrake = false, Boost = false }
local SAFE_SPOT_INTERVAL = 0.25
local SAFE_SPOT_COUNT = 40
local RESPAWN_MIN_AGE = 1.5
local MIN_SLIDE_SPEED = 7 -- studs/s (about 2 m/s); slower than this there is no slide angle
local MAX_CONTACT_TILT = 0.8 -- wheel contacts tilted more than ~37° from the car's up count as flat
local MIN_GROUND_DOT = 0.4 -- surfaces steeper than ~66° from the car's up are walls, not ground
local SIGNS = { -1, 1 }

local function groundVelocity(part: BasePart?, point: Vector3): Vector3
	if part == nil or part:IsA("Terrain") then
		return Vector3.zero
	end
	return part:GetVelocityAtPosition(point)
end

-- options.Driver = true on the driver's computer (air control, drifting, crashes, boost).
function CarPhysics.new(model: Model, tune, options)
	options = options or {}
	local chassis = model.PrimaryPart or model:FindFirstChild("Chassis")
	assert(chassis, "Car model needs a PrimaryPart (the Chassis)")

	local self = setmetatable({}, CarPhysics)
	self.Model = model
	self.Chassis = chassis
	self.Tune = tune
	self.IsDriver = options.Driver == true
	self.ForceConstraint = chassis:FindFirstChild("CarForce")
	self.TorqueConstraint = chassis:FindFirstChild("CarTorque")
	assert(self.ForceConstraint and self.TorqueConstraint, "Chassis needs CarForce and CarTorque (CarBuilder makes them)")

	self.Wheels = {}
	for _, name in CarPhysics.WheelNames do
		local attachment = chassis:FindFirstChild(name)
		if attachment then
			table.insert(self.Wheels, {
				Name = name,
				Mount = attachment.Position,
				IsFront = string.sub(name, 6, 6) == "F",
				IsLeft = string.sub(name, 7, 7) == "L",
				Grounded = false,
				Extension = tune.Suspension.Travel,
				Compression = 0,
				ContactPoint = Vector3.zero,
				Normal = Vector3.yAxis,
				Load = 0,
				Grip = 1,
				SpinSpeed = 0,
				Sliding = false,
				Spinning = false,
				Instance = nil,
				Material = nil,
			})
		end
	end
	assert(#self.Wheels > 0, "Chassis needs wheel attachments named WheelFL, WheelFR, WheelRL, WheelRR")

	-- Left/right partners for the anti-roll bar, and wheel counts per axle.
	self.AxleCount = { Front = 0, Rear = 0 }
	for _, wheel in self.Wheels do
		local axle = if wheel.IsFront then "Front" else "Rear"
		self.AxleCount[axle] += 1
		for _, other in self.Wheels do
			if other ~= wheel and other.IsFront == wheel.IsFront then
				wheel.Partner = other
			end
		end
	end

	self.RayParams = RaycastParams.new()
	self.RayParams.ExcludeInstances = { model }
	self.RayParams.RespectCanCollide = true
	self.RayParams.IgnoreWater = true

	local engine = tune.Engine
	self.EngineAccel = CarMath.accelForTime(engine.TopSpeed, engine.TimeToTopSpeed, engine.CurvePower)
	self.BrakeDecel = engine.TopSpeed / tune.Brakes.TimeFromTopSpeed

	-- How high the body centre sits above flat ground at rest (used when respawning).
	self.RestExtension = CarMath.restExtension(tune)
	local mountY = 0
	for _, wheel in self.Wheels do
		mountY += wheel.Mount.Y
	end
	mountY /= #self.Wheels
	self.RideHeight = -mountY + self.RestExtension + tune.Wheels.Radius
	-- How far above the body centre the top of the car is (roof, or cargo on the roof).
	self.RoofReach = (tune.Body.RoofHeight or tune.Body.Size.Y / 2 + tune.Body.CabinSize.Y) + 0.6

	-- Live state (read these for the HUD, camera and sounds).
	self.State = CarPhysics.States.Grounded
	self.SteerAngle = 0 -- radians, + is right
	self.DriveDirection = 1 -- 1 forward, -1 reverse
	self.Boost = tune.Boost.Start
	self.Boosting = false
	self.Speed = 0
	self.ForwardSpeed = 0
	self.SlideAngle = 0 -- radians, + means you are sliding towards the right of the nose
	self.GroundedWheels = 0
	self.AirTime = 0
	self.Clock = 0

	self.NoContactTime = 0
	self.Holding = false
	self.DriftGrip = tune.Drift.RearGrip
	self.DriftSide = 1
	self.DriftEntrySpeed = 0
	self.AirPitchLock = 0
	self.AirSteerLock = 0
	self.FlipPitch = 0
	self.FlipRoll = 0
	self.SpinYaw = 0
	self.LandingTimer = 0
	self.AbsorbTimer = 0
	self.CrashTimer = 0
	self.StuckTimer = 0
	self.SafeTimer = 0
	self.SafeSpots = {}
	self.Checkpoint = nil
	self.LastGoodSpeed = 0
	self.SettleTimer = 0

	-- Set this to a function(eventName, data) to hear about drifts, landings, flips and crashes.
	self.OnEvent = nil
	return self
end

function CarPhysics:_fire(name: string, data: any?)
	if self.OnEvent then
		self.OnEvent(name, data)
	end
end

-- Things the wheels should never land on (for example player characters).
function CarPhysics:SetIgnoreList(list: { Instance })
	local exclude = { self.Model }
	for _, item in list do
		table.insert(exclude, item)
	end
	self.RayParams.ExcludeInstances = exclude
end

function CarPhysics:AddBoost(amount: number)
	self.Boost = clamp(self.Boost + amount, 0, self.Tune.Boost.Max)
end

-- Maps call this when the car passes a checkpoint. Respawns go here from then on.
function CarPhysics:SetCheckpoint(cframe: CFrame)
	self.Checkpoint = cframe
end

-- Sideways grip of whatever a wheel is touching.
function CarPhysics:_surfaceGrip(hit: RaycastResult): number
	local part = hit.Instance
	local custom = part and part:GetAttribute("Grip")
	if type(custom) == "number" then
		return custom
	end
	local surfaces = self.Tune.Surfaces
	local kind = surfaces.Materials[hit.Material.Name]
	if kind then
		return surfaces[kind]
	end
	return surfaces.Default
end

-- Casts one wheel down from its mount. Returns the hit and how far the wheel hangs below
-- the mount (0 = pushed fully up, Travel = hanging fully down; below 0 = past the bump stop).
function CarPhysics:_castWheel(mount: Vector3, up: Vector3): (RaycastResult?, number)
	local suspension = self.Tune.Suspension
	local radius = self.Tune.Wheels.Radius
	local origin = mount + up * radius
	local reach = suspension.Travel + 2 * radius

	if suspension.CastShape == "Sphere" then
		local sphereRadius = radius * 0.8
		local hit = workspace:Spherecast(origin, sphereRadius, -up * (reach - sphereRadius), self.RayParams)
		if hit and hit.Normal:Dot(up) > MIN_GROUND_DOT then
			-- Where the sphere's centre was when it touched, measured along the cast.
			local centre = hit.Position + hit.Normal * sphereRadius
			local travelled = (origin - centre):Dot(up)
			return hit, travelled - 2 * radius + sphereRadius
		end
	end

	local hit = workspace:Raycast(origin, -up * reach, self.RayParams)
	if hit and hit.Normal:Dot(up) > MIN_GROUND_DOT then
		return hit, hit.Distance - 2 * radius
	end
	return nil, suspension.Travel
end

function CarPhysics:_setForces(force: Vector3, torque: Vector3)
	self.ForceConstraint.Force = force
	self.TorqueConstraint.Torque = torque
end

-- Runs the car for one frame. dt is the frame time in seconds.
-- input = { Throttle = 0..1, Brake = 0..1, Steer = -1..1, Handbrake = bool, Boost = bool }
function CarPhysics:Step(dt: number, input)
	local chassis = self.Chassis
	if chassis.Parent == nil then
		return
	end
	input = if self.IsDriver then (input or NO_INPUT) else PARKED_INPUT
	dt = clamp(dt, 1 / 240, 1 / 20)
	self.Clock += dt

	local tune = self.Tune
	local gravity = tune.Gravity
	local mass = chassis.AssemblyMass
	-- The world pulls with workspace.Gravity; this lifts the car so it feels tune.Gravity.
	local gravityFix = Vector3.new(0, (workspace.Gravity - gravity) * mass, 0)

	if self.State == CarPhysics.States.Crashed then
		self:_setForces(gravityFix, Vector3.zero)
		self.CrashTimer -= dt
		if self.CrashTimer <= 0 then
			self:Respawn()
		end
		return
	end

	local cf = chassis.CFrame
	local up, fwd, right = cf.UpVector, cf.LookVector, cf.RightVector
	local com = chassis.AssemblyCenterOfMass
	local vel = chassis.AssemblyLinearVelocity
	local wheelCount = #self.Wheels
	local wheelMass = mass / wheelCount
	local suspension = tune.Suspension
	local tires = tune.Tires
	local radius = tune.Wheels.Radius

	local omega = 2 * math.pi * suspension.Frequency
	local k = wheelMass * omega * omega
	local c = 2 * suspension.DampingRatio * math.sqrt(k * wheelMass)
	local staticLoad = wheelMass * gravity

	local force = gravityFix
	local torque = Vector3.zero

	------------------------------------------------------------------------------
	-- 1. Suspension
	------------------------------------------------------------------------------
	local grounded = 0
	local groundedFront, groundedRear = 0, 0
	local normalSum = Vector3.zero
	for _, wheel in self.Wheels do
		local mount = cf:PointToWorldSpace(wheel.Mount)
		local hit, extension = self:_castWheel(mount, up)
		wheel.MountWorld = mount
		if hit and extension <= suspension.Travel then
			wheel.Grounded = true
			wheel.Extension = extension
			wheel.Compression = suspension.Travel - extension
			wheel.ContactPoint = hit.Position
			-- A wheel catching a kerb edge gets a slanted normal. Pushing along it would turn
			-- speed along the road into a hard shove upwards, so steep contacts count as flat
			-- (the car's own up) for the springs and tyres.
			wheel.Normal = if hit.Normal:Dot(up) >= MAX_CONTACT_TILT then hit.Normal else up
			wheel.Instance = hit.Instance
			wheel.Material = hit.Material
			wheel.Grip = self:_surfaceGrip(hit)
			grounded += 1
			if wheel.IsFront then
				groundedFront += 1
			else
				groundedRear += 1
			end
			normalSum += wheel.Normal
		else
			wheel.Grounded = false
			wheel.Extension = suspension.Travel
			wheel.Compression = 0
			wheel.Load = 0
			wheel.Instance = nil
			wheel.Sliding = false
			wheel.Spinning = false
		end
	end

	local groundUp = if grounded > 0 then normalSum.Unit else Vector3.yAxis

	-- The most one spring may push: hold its share of the car up and lift it at no more than
	-- MaxRiseSpeed. Without this a car that sank onto its body (getting in, a bad landing)
	-- gets thrown into the air, and every landing after that throws it higher.
	local maxRise = suspension.MaxRiseSpeed
	for _, wheel in self.Wheels do
		if wheel.Grounded then
			-- Past full travel the body takes the hit, so the springs stop pushing harder.
			local x = math.min(wheel.Compression, suspension.Travel)
			local partner = wheel.Partner
			local partnerX = if partner and partner.Grounded then math.min(partner.Compression, suspension.Travel) else 0
			local hub = wheel.MountWorld - up * math.max(wheel.Extension, 0)
			wheel.GroundVelocity = groundVelocity(wheel.Instance, wheel.ContactPoint)
			-- How fast the wheel is leaving the ground (+) or pressing into it (-), measured
			-- along the ground's normal: the car's own up tilts a little with pitch, and at
			-- speed that would read part of the forward motion as the spring stretching.
			local n = wheel.Normal
			local upSpeed = (chassis:GetVelocityAtPosition(hub) - wheel.GroundVelocity):Dot(n) / math.max(n:Dot(up), 0.3)

			local spring = k * x + k * suspension.AntiRoll * (x - partnerX)
			-- Shocks resist bouncing back up more than squashing down, like real ones.
			local damping = c * (if upSpeed > 0 then suspension.ReboundDamping else 1)
			local overBump = math.max(0, x - suspension.Travel * 0.85)
			if overBump > 0 then
				-- Bump stop: very stiff while squashing, gives back only a little on the way up,
				-- so big landings don't bounce you back into the air.
				if upSpeed < 0 then
					spring += k * suspension.BumpStop * overBump
					damping += c * 2
				else
					spring += k * suspension.BumpStop * overBump * 0.3
				end
			end
			damping = math.min(damping, wheelMass / dt) -- stay stable at low frame rates
			local push = math.max(spring - damping * upSpeed, 0)
			push = math.min(push, staticLoad + wheelMass * math.max(maxRise - upSpeed, 0) / dt)
			wheel.Push = push
			wheel.Hub = hub
			wheel.Load = clamp(spring / staticLoad, 0, tires.MaxLoad)
		end
	end

	-- The same limit for the whole car: whatever mix of wheels is touching (say only the back
	-- two, after a nose-first landing), the springs together never lift the body faster than
	-- MaxRiseSpeed.
	local totalPush = 0
	for _, wheel in self.Wheels do
		if wheel.Grounded then
			totalPush += wheel.Push
		end
	end
	local riseSpeed = vel:Dot(up)
	local maxTotal = mass * (gravity + math.max(maxRise - riseSpeed, 0) / dt)
	local pushScale = if totalPush > maxTotal then maxTotal / totalPush else 1
	for _, wheel in self.Wheels do
		if wheel.Grounded then
			local lift = up * (wheel.Push * pushScale)
			force += lift
			torque += (wheel.Hub - com):Cross(lift)
		end
	end

	self.GroundedWheels = grounded
	self.GroundNormal = groundUp

	------------------------------------------------------------------------------
	-- 2. Speeds, slide angle and states
	------------------------------------------------------------------------------
	local forwardSpeed = vel:Dot(fwd)
	local sideSpeed = vel:Dot(right)
	local planarSpeed = math.sqrt(forwardSpeed * forwardSpeed + sideSpeed * sideSpeed)
	local speed = vel.Magnitude
	local slide = if planarSpeed > MIN_SLIDE_SPEED then math.atan2(sideSpeed, forwardSpeed) else 0
	local slideRate = if math.abs(slide) > 0 and math.abs(self.SlideAngle) > 0
		then CarMath.wrapAngle(slide - self.SlideAngle) / dt
		else 0
	self.Speed = speed
	self.ForwardSpeed = forwardSpeed
	self.SlideAngle = slide

	if grounded == 0 then
		self.NoContactTime += dt
	else
		self.NoContactTime = 0
	end

	if self.IsDriver then
		self:_updateStates(dt, input, cf, grounded, groundUp, slide, planarSpeed, speed)
		if self.State == CarPhysics.States.Crashed then
			self:_setForces(gravityFix, Vector3.zero)
			return
		end
	end
	local state = self.State
	local drifting = state == CarPhysics.States.Drifting
	local airborne = state == CarPhysics.States.Airborne

	------------------------------------------------------------------------------
	-- 3. Steering
	------------------------------------------------------------------------------
	local steering = tune.Steering
	local steerInput = clamp(input.Steer or 0, -1, 1)
	local speedFraction = clamp(math.abs(forwardSpeed) / tune.Engine.TopSpeed, 0, 1)
	local targetSteer = steerInput * lerp(steering.MaxAngleSlow, steering.MaxAngleFast, speedFraction)
	if drifting then
		-- Front wheels follow the slide (countersteer for you); your steering adds to that.
		local drift = tune.Drift
		local range = lerp(steering.MaxAngleSlow, steering.MaxAngleFast * 1.5, speedFraction)
		targetSteer = clamp(
			slide * drift.CountersteerAssist + steerInput * range,
			-drift.MaxWheelAngle,
			drift.MaxWheelAngle
		)
	end
	self.SteerAngle = CarMath.moveTowards(self.SteerAngle, targetSteer, steering.WheelTurnSpeed * dt)

	------------------------------------------------------------------------------
	-- 4. Engine, brakes, reverse, boost
	------------------------------------------------------------------------------
	local rawThrottle = clamp(input.Throttle or 0, 0, 1)
	local rawBrake = clamp(input.Brake or 0, 0, 1)
	local throttle, brake = rawThrottle, rawBrake
	local engine = tune.Engine
	local boost = tune.Boost

	self.Boosting = self.IsDriver
		and input.Boost == true
		and self.Boost > 0
		and grounded > 0
		and not airborne
		and self.DriveDirection == 1
	if self.Boosting then
		throttle = 1
		brake = 0
		self.Boost = math.max(0, self.Boost - boost.Use * dt)
	end

	if self.IsDriver then
		local engage = tune.Reverse.EngageSpeed
		if self.DriveDirection == 1 then
			if brake > 0 and throttle == 0 and forwardSpeed < engage then
				self.DriveDirection = -1
			end
		elseif throttle > 0 and forwardSpeed > -engage then
			self.DriveDirection = 1
		end
	end

	local topSpeed = if self.Boosting then boost.TopSpeed else engine.TopSpeed
	local driveAccel = 0
	local brakeAmount
	if self.DriveDirection == 1 then
		brakeAmount = brake
		if throttle > 0 and brake == 0 then
			local accel = self.EngineAccel * (if self.Boosting then boost.PushMultiplier else 1)
			driveAccel = throttle * CarMath.engineAccel(accel, forwardSpeed, topSpeed, engine.CurvePower)
		end
	else
		brakeAmount = throttle
		if brake > 0 and throttle == 0 then
			local reverse = tune.Reverse
			driveAccel = -brake * CarMath.engineAccel(reverse.Accel, -forwardSpeed, reverse.TopSpeed, 2)
		end
	end
	local handbrake = input.Handbrake == true
	local coasting = driveAccel == 0 and brakeAmount == 0 and not handbrake

	-- Parking: once stopped with no gas, the car stays put (even on a hill) until you drive.
	if driveAccel ~= 0 or throttle > 0 or grounded == 0 then
		self.Holding = false
	elseif math.abs(forwardSpeed) < tires.HoldSpeed and planarSpeed < tires.HoldSpeed * 2 then
		self.Holding = true
	end
	local holding = self.Holding

	-- Drifting: rear grip is steered to hold a slide angle. Steering into the turn asks for
	-- a bigger angle, steering out asks for a smaller one (and lets you straighten up).
	local drift = tune.Drift
	local absSlide = math.abs(slide)
	local rearGripScale = 1
	if drifting then
		if absSlide > 5 * math.pi / 180 then
			self.DriftSide = math.sign(slide)
		end
		local side = self.DriftSide
		local growth = slideRate * side -- how fast the slide is getting bigger (rad/s)
		local intoTurn = -steerInput * side
		local target = clamp(drift.TargetAngle + intoTurn * drift.SteerAngleRange, drift.ExitAngle, drift.TargetAngle + drift.SteerAngleRange)
		-- Look a little ahead so the back tyres grab before the slide overshoots.
		local predicted = absSlide + growth * 0.15
		local wantedGrip = clamp(drift.RearGrip + drift.AngleHold * math.deg(predicted - target), drift.MinRearGrip, 1)
		self.DriftGrip += (wantedGrip - self.DriftGrip) * CarMath.approach(12, dt)
		rearGripScale = self.DriftGrip

		-- Spin-out guard: the closer the slide gets to MaxAngle, the slower it may grow.
		local allowed = math.max(drift.MaxAngle - absSlide, 0) * 4
		if growth > allowed then
			chassis.AssemblyAngularVelocity -= groundUp * (side * (growth - allowed))
		end
	else
		self.DriftGrip = drift.RearGrip
		if handbrake then
			rearGripScale = tune.Handbrake.RearGrip
		end
	end

	------------------------------------------------------------------------------
	-- 5. Tyres
	------------------------------------------------------------------------------
	-- While drifting, the gas holds the slide instead of launching you out of it.
	local driveForce = mass * driveAccel * (if drifting then drift.Throttle else 1)
	local brakes = tune.Brakes
	local parkingBlend = clamp(1 - planarSpeed / 5, 0, 1)
	-- Everything pushing the car except the tyres (gravity, springs). Parked tyres cancel it.
	local nonTire = force + Vector3.new(0, -workspace.Gravity * mass, 0)
	local share = if grounded > 0 then 1 / grounded else 0
	for _, wheel in self.Wheels do
		if not wheel.Grounded then
			wheel.SpinSpeed *= 0.98
			continue
		end
		local n = wheel.Normal
		local steer = if wheel.IsFront then self.SteerAngle else 0
		local heading = fwd * math.cos(steer) + right * math.sin(steer)
		local f = CarMath.safeUnit(CarMath.flatten(heading, n), fwd)
		local r = f:Cross(n)
		local contact = wheel.ContactPoint
		local v = chassis:GetVelocityAtPosition(contact) - wheel.GroundVelocity
		local vLong = v:Dot(f)
		local vLat = v:Dot(r)

		-- Grip for this wheel
		local grip = wheel.Grip * (if wheel.IsFront then tires.FrontGrip else tires.RearGrip * rearGripScale)
		local maxForce = tires.Grip * grip * wheel.Load * wheelMass

		-- Forwards / backwards
		local axleShare = if wheel.IsFront then engine.FrontDriveShare else 1 - engine.FrontDriveShare
		local axleGrounded = if wheel.IsFront then groundedFront else groundedRear
		local longForce = driveForce * axleShare / axleGrounded
		local resist = 0
		local brakeShare = if wheel.IsFront then brakes.FrontShare else 1 - brakes.FrontShare
		local perAxle = if wheel.IsFront then self.AxleCount.Front else self.AxleCount.Rear
		resist += mass * self.BrakeDecel * brakeAmount * brakeShare / perAxle
		if handbrake and not wheel.IsFront then
			resist += mass * tune.Handbrake.Decel / perAxle
		end
		if coasting then
			resist += wheelMass * engine.CoastDecel
		end
		if resist > 0 then
			-- Never push past a standstill (that would make the car jitter).
			local maxStop = math.abs(vLong) * wheelMass / dt * 0.5
			longForce -= math.sign(vLong) * math.min(resist, maxStop)
		end
		if holding then
			-- Parked: cancel rolling and lean against the hill.
			longForce = -vLong * wheelMass / dt * 0.5 - nonTire:Dot(f) * share
		end
		wheel.Spinning = false
		if math.abs(longForce) > maxForce then
			wheel.Spinning = driveAccel ~= 0
			longForce = math.sign(longForce) * maxForce
		end

		-- Sideways: cancel part of the slide every frame.
		local rate = math.min(tires.GripRate * grip, 0.5 / dt)
		local wanted = -vLat * wheelMass * rate - nonTire:Dot(r) * share * parkingBlend
		local latForce = clamp(wanted, -maxForce, maxForce)
		wheel.Sliding = math.abs(wanted) > maxForce and planarSpeed > 5
		if drifting and not wheel.IsFront then
			-- Sliding back tyres share their grip between sideways and forwards, so the gas
			-- holds a drift rather than shooting you out of it.
			local total = math.sqrt(longForce * longForce + latForce * latForce)
			if total > maxForce then
				local scale = maxForce / total
				longForce *= scale
				latForce *= scale
			end
		end

		-- Push. Sideways force acts higher up so the car leans less and doesn't trip over.
		local longVec = f * longForce
		local latVec = r * latForce
		local comHeight = (com - contact):Dot(up)
		local latPoint = contact + up * (comHeight * tires.ForceHeight)
		force += longVec + latVec
		torque += (contact - com):Cross(longVec) + (latPoint - com):Cross(latVec)

		-- Wheel spin for the visuals.
		if handbrake and not wheel.IsFront then
			wheel.SpinSpeed = 0
		elseif wheel.Spinning then
			wheel.SpinSpeed = vLong / radius + math.sign(driveAccel) * 12
		else
			wheel.SpinSpeed = vLong / radius
		end
	end

	------------------------------------------------------------------------------
	-- 6. Downforce, drift push, speed limit
	------------------------------------------------------------------------------
	if grounded >= 2 then
		local speedRatio = math.min(speed / engine.TopSpeed, 1.5)
		force -= up * (mass * gravity * tune.Downforce.AtTopSpeed * speedRatio * speedRatio)

		if drifting and throttle > 0 and planarSpeed < math.min(self.DriftEntrySpeed, topSpeed) then
			-- Hold the speed you went into the drift with (not more: the circle would grow).
			local along = CarMath.safeUnit(CarMath.flatten(vel, groundUp), fwd)
			force += along * (mass * drift.Push * throttle)
		end

		if speed > topSpeed then
			force -= vel.Unit * (mass * (speed - topSpeed) * engine.OverSpeedDrag)
		end
	end

	------------------------------------------------------------------------------
	-- 7. Air control and clean-landing straighten
	------------------------------------------------------------------------------
	if airborne then
		self:_airControl(dt, cf, rawThrottle - rawBrake, steerInput, handbrake)
	end
	if not airborne and self.AbsorbTimer > 0 then
		-- Just landed: soak up the bounce so the car stays down (even if a bounce has
		-- briefly lifted the wheels).
		self.AbsorbTimer -= dt
		local landingVel = chassis.AssemblyLinearVelocity
		local away = landingVel:Dot(groundUp)
		if away > 2 then
			chassis.AssemblyLinearVelocity = landingVel - groundUp * (away - 2)
		end
	end
	if self.SettleTimer > 0 then
		-- Just got in: soak up any spin or lift left over from the hand-over, as long as
		-- the driver isn't asking for anything yet.
		self.SettleTimer -= dt
		local idle = rawThrottle == 0 and rawBrake == 0 and math.abs(steerInput) < 0.05 and not handbrake
		if idle and speed < 8 then
			chassis.AssemblyAngularVelocity *= math.exp(-12 * dt)
			local v = chassis.AssemblyLinearVelocity
			if v.Y > 0.5 then
				chassis.AssemblyLinearVelocity = Vector3.new(v.X, 0.5, v.Z)
			end
		end
	end
	if not airborne and self.LandingTimer > 0 and grounded > 0 then
		local remaining = math.max(self.LandingTimer, dt * 2)
		self.LandingTimer -= dt
		local axis = up:Cross(groundUp)
		local sinAngle = math.min(axis.Magnitude, 1)
		local angular = chassis.AssemblyAngularVelocity
		local spin = groundUp * angular:Dot(groundUp)
		if sinAngle > 1e-4 then
			chassis.AssemblyAngularVelocity = spin + axis.Unit * (math.asin(sinAngle) / remaining)
		else
			chassis.AssemblyAngularVelocity = spin
		end
	end

	self:_setForces(force, torque)
end

-- Call when the driver's computer takes the car over: start from a clean, still state and
-- settle for a moment (see SettleTimer in Step).
function CarPhysics:Settle(duration: number?)
	local chassis = self.Chassis
	self.State = CarPhysics.States.Grounded
	self.NoContactTime = 0
	self.AirTime = 0
	self.LandingTimer = 0
	self.AbsorbTimer = 0
	self.StuckTimer = 0
	self.CrashTimer = 0
	self.Holding = false
	if chassis.AssemblyLinearVelocity.Magnitude < 8 then
		chassis.AssemblyLinearVelocity = Vector3.zero
		chassis.AssemblyAngularVelocity = Vector3.zero
	end
	self.SettleTimer = duration or 0.75
end

function CarPhysics:_airControl(dt: number, cf: CFrame, pitchInput: number, steerInput: number, rollMode: boolean)
	local air = self.Tune.Air
	local chassis = self.Chassis

	-- Keys you were already holding when you took off (like W) don't tilt the car until
	-- you let go or press the other way. Otherwise holding gas over every jump would
	-- flip you forward.
	if self.AirPitchLock ~= 0 then
		if math.sign(pitchInput) == self.AirPitchLock then
			pitchInput = 0
		else
			self.AirPitchLock = 0
		end
	end
	if self.AirSteerLock ~= 0 then
		if math.sign(steerInput) == self.AirSteerLock then
			steerInput = 0
		else
			self.AirSteerLock = 0
		end
	end

	local localSpin = cf:VectorToObjectSpace(chassis.AssemblyAngularVelocity)
	local x, y, z = localSpin.X, localSpin.Y, localSpin.Z
	local follow = CarMath.approach(air.Response, dt)
	local damp = math.exp(-air.Damping * dt)
	local pitching = math.abs(pitchInput) > 0.05
	local turning = math.abs(steerInput) > 0.05

	-- Gentle self-levelling when you are roughly upright and not pressing anything, so a
	-- plain jump lands cleanly. Flips are untouched (it only helps within 60 degrees of upright).
	local levelling = air.AutoLevel > 0 and cf.UpVector.Y > 0.5
	local levelFollow = CarMath.approach(6, dt)

	-- W tips the nose down (forward flip), S lifts it (backflip).
	if pitching then
		x += (-pitchInput * air.PitchRate - x) * follow
	elseif levelling then
		-- Aim the nose halfway between level and the direction you are flying.
		local vel = chassis.AssemblyLinearVelocity
		local flightPitch = if vel.Magnitude > 5 then math.asin(clamp(vel.Unit.Y, -1, 1)) * 0.5 else 0
		local carPitch = math.asin(clamp(cf.LookVector.Y, -1, 1))
		x += ((flightPitch - carPitch) * air.AutoLevel - x) * levelFollow
	else
		x *= damp
	end
	if rollMode and turning then
		-- Space + A / D rolls sideways.
		z += (-steerInput * air.RollRate - z) * follow
	elseif levelling then
		local carRoll = math.asin(clamp(cf.RightVector.Y, -1, 1))
		z += (-carRoll * air.AutoLevel - z) * levelFollow
	else
		z *= damp
	end
	if turning and not rollMode then
		-- A / D spins left and right.
		y += (-steerInput * air.YawRate - y) * follow
	else
		y *= damp
	end
	chassis.AssemblyAngularVelocity = cf:VectorToWorldSpace(Vector3.new(x, y, z))
end

function CarPhysics:_updateStates(dt, input, cf: CFrame, grounded: number, groundUp: Vector3, slide: number, planarSpeed: number, speed: number)
	local tune = self.Tune
	local States = CarPhysics.States
	local up = cf.UpVector

	-- Airborne and landing
	if self.State == States.Airborne then
		if grounded == 0 then
			-- Body hits the ground at a bad angle before the wheels do = crash.
			local corner = self:_lowestCorner(cf)
			local bodyHit = workspace:Raycast(corner + Vector3.new(0, 0.5, 0), Vector3.new(0, -1.5, 0), self.RayParams)
			if bodyHit and CarMath.angleBetween(up, bodyHit.Normal) >= tune.Landing.CrashAngle then
				self:Crash("BadLanding")
				return
			end
		end
		if grounded > 0 then
			self:_land(groundUp, up)
			if self.State == States.Crashed then
				return
			end
		else
			self.AirTime += dt
			self:AddBoost(tune.Boost.Airtime * dt)
			local spin = cf:VectorToObjectSpace(self.Chassis.AssemblyAngularVelocity)
			self.FlipPitch += spin.X * dt
			self.FlipRoll += spin.Z * dt
			self.SpinYaw += spin.Y * dt
		end
	elseif self.NoContactTime >= tune.Air.Delay then
		self.State = States.Airborne
		self.AirTime = self.NoContactTime
		self.FlipPitch, self.FlipRoll, self.SpinYaw = 0, 0, 0
		-- Remember keys held at take-off (see _airControl).
		local pitch = (input.Throttle or 0) - (input.Brake or 0)
		self.AirPitchLock = if math.abs(pitch) > 0.05 then math.sign(pitch) else 0
		self.AirSteerLock = if math.abs(input.Steer or 0) > 0.05 then math.sign(input.Steer) else 0
		self:_fire("Airborne")
	end

	-- Drifting
	local drift = tune.Drift
	local absSlide = math.abs(slide)
	if self.State == States.Grounded then
		local handbrakeStart = input.Handbrake and planarSpeed > drift.StartSpeed
		local slideStart = absSlide > drift.EnterAngle and absSlide < math.rad(100) and planarSpeed > drift.MinSpeed
		if grounded >= 2 and (handbrakeStart or slideStart) then
			self.State = States.Drifting
			self.DriftEntrySpeed = planarSpeed
			if input.Handbrake and math.abs(input.Steer or 0) > 0.2 then
				-- A little kick so handbrake turns feel snappy.
				local chassis = self.Chassis
				chassis.AssemblyAngularVelocity -= groundUp * ((input.Steer or 0) * drift.Kick)
			end
			self:_fire("DriftStart")
		end
	elseif self.State == States.Drifting then
		local stop = planarSpeed < drift.MinSpeed
			or (not input.Handbrake and absSlide < drift.ExitAngle)
			or absSlide > math.rad(110)
		if stop then
			self.State = States.Grounded
			self:_fire("DriftEnd")
		else
			self:AddBoost(tune.Boost.Drifting * dt)
		end
	end

	-- Crashes: roof hits, stuck on the roof or side, or falling off the world.
	local crash = tune.Crash
	if up.Y < 0.2 then
		local roofHit = workspace:Raycast(cf.Position, up * self.RoofReach, self.RayParams)
		if roofHit then
			self:Crash("Roof")
			return
		end
	end
	if up.Y < 0.35 and grounded < 2 and speed < 6 then
		self.StuckTimer += dt
		if self.StuckTimer >= crash.UpsideDownTime then
			self:Crash("Stuck")
			return
		end
	else
		self.StuckTimer = 0
	end
	if cf.Position.Y < crash.FallHeight then
		self:Crash("Fell")
		return
	end

	-- Remember safe places to respawn (all wheels down, upright).
	if self.State ~= States.Airborne and grounded == #self.Wheels and up.Y > 0.85 then
		self.SafeTimer += dt
		if self.SafeTimer >= SAFE_SPOT_INTERVAL then
			self.SafeTimer = 0
			local look = CarMath.flatten(cf.LookVector, Vector3.yAxis)
			if look.Magnitude > 0.1 then
				local position = cf.Position
				table.insert(self.SafeSpots, {
					CFrame = CFrame.lookAt(position, position + look.Unit),
					Speed = math.max(self.ForwardSpeed, 0),
					Time = self.Clock,
				})
				if #self.SafeSpots > SAFE_SPOT_COUNT then
					table.remove(self.SafeSpots, 1)
				end
				self.LastGoodSpeed = math.max(self.ForwardSpeed, 0)
			end
		end
	end
end

-- The lowest corner of the Chassis box right now.
function CarPhysics:_lowestCorner(cf: CFrame): Vector3
	local half = self.Chassis.Size / 2
	local lowest = cf.Position
	for _, sx in SIGNS do
		for _, sy in SIGNS do
			for _, sz in SIGNS do
				local point = cf:PointToWorldSpace(Vector3.new(sx * half.X, sy * half.Y, sz * half.Z))
				if point.Y < lowest.Y then
					lowest = point
				end
			end
		end
	end
	return lowest
end

function CarPhysics:_land(groundUp: Vector3, up: Vector3)
	local landing = self.Tune.Landing
	local angle = CarMath.angleBetween(up, groundUp)
	local function countFlips(total: number): number
		return math.floor((math.abs(total) + landing.FlipTolerance) / (2 * math.pi))
	end
	local flips = countFlips(self.FlipPitch) + countFlips(self.FlipRoll)
	local airTime = self.AirTime
	self.State = CarPhysics.States.Grounded
	self.AirTime = 0

	if angle >= landing.CrashAngle then
		self:Crash("BadLanding")
		return
	end
	local bonus = airTime >= landing.MinAirTime
	self.AbsorbTimer = landing.AbsorbTime
	if flips > 0 then
		self:AddBoost(flips * self.Tune.Boost.Flip)
		self:_fire("Flip", flips)
	end
	if angle <= landing.CleanAngle then
		self.LandingTimer = landing.StraightenTime
		if bonus then
			self:AddBoost(self.Tune.Boost.CleanLanding)
			self:_fire("CleanLanding", airTime)
		end
	elseif bonus then
		self:_fire("RoughLanding", angle)
	end
	-- Later: use this for package damage (harder landings hurt more).
	self:_fire("Landed", { AirTime = airTime, Angle = angle, Flips = flips })
end

function CarPhysics:Crash(reason: string)
	if self.State == CarPhysics.States.Crashed then
		return
	end
	self.State = CarPhysics.States.Crashed
	self.CrashTimer = self.Tune.Crash.Wait
	self.Boosting = false
	self:_fire("Crashed", reason)
end

-- Where a respawn would put you: the last checkpoint, or the last safe spot that is a
-- couple of seconds old (so you don't land right back at the edge you fell off).
function CarPhysics:GetRespawnSpot(): (CFrame, number)
	if self.Checkpoint then
		return self.Checkpoint, self.LastGoodSpeed
	end
	for i = #self.SafeSpots, 1, -1 do
		local spot = self.SafeSpots[i]
		if self.Clock - spot.Time >= RESPAWN_MIN_AGE then
			return spot.CFrame, spot.Speed
		end
	end
	local first = self.SafeSpots[1]
	if first then
		return first.CFrame, first.Speed
	end
	local cf = self.Chassis.CFrame
	local look = CarMath.safeUnit(CarMath.flatten(cf.LookVector, Vector3.yAxis), Vector3.new(0, 0, -1))
	return CFrame.lookAt(cf.Position, cf.Position + look), 0
end

-- Puts the car back on the road, facing forward, at 60% of the speed you had there.
function CarPhysics:Respawn()
	local chassis = self.Chassis
	local spot, spotSpeed = self:GetRespawnSpot()
	local look = CarMath.safeUnit(CarMath.flatten(spot.LookVector, Vector3.yAxis), Vector3.new(0, 0, -1))
	local position = spot.Position
	local groundUp = Vector3.yAxis
	local hit = workspace:Raycast(position + Vector3.new(0, 8, 0), Vector3.new(0, -40, 0), self.RayParams)
	if hit then
		-- Sit on the ground, tilted to match it (so slopes don't launch the car).
		if hit.Normal.Y > 0.6 then
			groundUp = hit.Normal
		end
		position = hit.Position + groundUp * (self.RideHeight + 0.3)
	end
	local slopeLook = CarMath.safeUnit(CarMath.flatten(look, groundUp), look)
	chassis.CFrame = CFrame.lookAt(position, position + slopeLook, groundUp)
	chassis.AssemblyLinearVelocity = look * (spotSpeed * self.Tune.Crash.RespawnSpeed)
	chassis.AssemblyAngularVelocity = Vector3.zero

	self.State = CarPhysics.States.Grounded
	self.SteerAngle = 0
	self.DriveDirection = 1
	self.NoContactTime = 0
	self.StuckTimer = 0
	self.LandingTimer = 0
	self.AbsorbTimer = 0
	self.Holding = false
	self.AirTime = 0
	self.CrashTimer = 0
	self:_fire("Respawned")
end

-- R key: back to the last checkpoint right away.
function CarPhysics:RequestRespawn()
	self:Respawn()
end

-- Stops pushing the car (call when the driver gets out).
function CarPhysics:Destroy()
	if self.ForceConstraint.Parent then
		self:_setForces(Vector3.zero, Vector3.zero)
	end
	self.OnEvent = nil
end

return CarPhysics
