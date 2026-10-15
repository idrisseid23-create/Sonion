-- CarBuilder
-- Builds a car: the invisible physics body, the seat, the wheels, and (through CarLooks)
-- everything you see. The driving only needs these names, so a real model can replace
-- the looks later:
--
--   Car (Model, tagged "Car", attribute CarType)
--     Chassis (Part, PrimaryPart)       the physics body (an invisible box)
--       WheelFL / WheelFR / WheelRL / WheelRR (Attachments)  suspension top of each wheel
--       ForceAttachment, CarForce (VectorForce), CarTorque (Torque)
--     Cabin (Part)                      invisible box so roof landings are real
--     DriverSeat (Seat)
--     Wheels (Folder) with WheelFL... parts, each joined to the Chassis by a Motor6D "Axle"
--     Body (Folder)                     the parts you see (no mass, no collisions)

local CollectionService = game:GetService("CollectionService")

local CarLooks = require(script.Parent:WaitForChild("CarLooks"))

local CarBuilder = {}

local function part(props): Part
	local p = Instance.new("Part")
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Material = Enum.Material.SmoothPlastic
	if props.Shape then
		p.Shape = props.Shape -- set the shape before the size so the size sticks
	end
	for key, value in props do
		if key ~= "Shape" then
			p[key] = value
		end
	end
	return p
end

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = b
end

-- tune: a table from CarConfig.Get. cframe: where the body centre goes (upright).
function CarBuilder.Build(tune, cframe: CFrame): Model
	local body = tune.Body
	local wheels = tune.Wheels
	local look = tune.Look
	local size = body.Size
	-- Look positions are drawn with the ground at y = 0; this turns them into body space.
	local function fromDrawing(v: Vector3): Vector3
		return v - Vector3.new(0, look.DesignRide, 0)
	end

	local model = Instance.new("Model")
	model.Name = tune.Name
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic

	-- The physics body. Low friction so scraping walls or sliding on the roof doesn't grab.
	local chassis = part({
		Name = "Chassis",
		Size = size,
		CFrame = cframe,
		Transparency = 1,
		CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.25, 0, 1, 1),
		RootPriority = 127, -- stays the root even with a driver sitting in it
	})
	chassis.Parent = model
	model.PrimaryPart = chassis

	-- Hidden weight that pulls the centre of mass low and a little forward.
	-- It weighs the same as the body, so it sits twice as far out as the target point.
	local chassisMass = 0.7 * size.X * size.Y * size.Z
	local ballastSize = Vector3.new(2, 1, 2)
	local ballastDensity = math.clamp(chassisMass / (ballastSize.X * ballastSize.Y * ballastSize.Z), 0.01, 100)
	local ballast = part({
		Name = "Ballast",
		Size = ballastSize,
		CFrame = cframe * CFrame.new(tune.CenterOfMass * 2),
		Transparency = 1,
		CanCollide = false,
		CanQuery = false,
		CanTouch = false,
		CustomPhysicalProperties = PhysicalProperties.new(ballastDensity, 0.3, 0, 1, 1),
	})
	ballast.Parent = model
	weld(chassis, ballast)

	-- Cabin collision box. It collides, so roof landings are real.
	local cabinSize = body.CabinSize
	local cabin = part({
		Name = "Cabin",
		Size = cabinSize,
		CFrame = cframe * CFrame.new(body.CabinOffset + Vector3.new(0, size.Y / 2 + cabinSize.Y / 2, 0)),
		Transparency = 1,
		Massless = true,
		CanTouch = false,
		CustomPhysicalProperties = PhysicalProperties.new(0.7, 0.25, 0, 1, 1),
	})
	cabin.Parent = model
	weld(chassis, cabin)

	-- Seat where the drawing puts it. Drive with the prompt (E) instead of walking into it.
	local seat = Instance.new("Seat")
	seat.Name = "DriverSeat"
	seat.Size = Vector3.new(2, 1, 2)
	seat.CFrame = cframe * CFrame.new(fromDrawing(look.Seat))
	seat.Transparency = 1
	seat.CanCollide = false
	seat.CanTouch = false -- get in with the prompt only (stops re-sitting by bumping it when you get out)
	seat.Massless = true
	seat.Parent = model
	weld(chassis, seat)

	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "DrivePrompt"
	prompt.ActionText = "Drive"
	prompt.ObjectText = tune.Name
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.GamepadKeyCode = Enum.KeyCode.ButtonX
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = 14
	prompt.RequiresLineOfSight = false
	prompt.Parent = seat

	-- Forces the driving script sets every frame.
	local forceAttachment = Instance.new("Attachment")
	forceAttachment.Name = "ForceAttachment"
	forceAttachment.Parent = chassis

	local vectorForce = Instance.new("VectorForce")
	vectorForce.Name = "CarForce"
	vectorForce.Attachment0 = forceAttachment
	vectorForce.ApplyAtCenterOfMass = true
	vectorForce.RelativeTo = Enum.ActuatorRelativeTo.World
	vectorForce.Force = Vector3.zero
	vectorForce.Parent = chassis

	local torque = Instance.new("Torque")
	torque.Name = "CarTorque"
	torque.Attachment0 = forceAttachment
	torque.RelativeTo = Enum.ActuatorRelativeTo.World
	torque.Torque = Vector3.zero
	torque.Parent = chassis

	-- Everything you see.
	CarLooks.Dress(model, chassis, tune)

	-- Wheels: an attachment marks where each suspension starts; the wheel part is only
	-- for looks (it spins and steers on every player's screen).
	local wheelFolder = Instance.new("Folder")
	wheelFolder.Name = "Wheels"
	wheelFolder.Parent = model
	local radius = wheels.Radius
	for _, name in { "WheelFL", "WheelFR", "WheelRL", "WheelRR" } do
		local front = string.sub(name, 6, 6) == "F"
		local left = string.sub(name, 7, 7) == "L"
		local mount = Vector3.new(
			(if left then -1 else 1) * wheels.TrackWidth / 2,
			wheels.MountHeight,
			(if front then -1 else 1) * wheels.WheelBase / 2
		)
		local attachment = Instance.new("Attachment")
		attachment.Name = name
		attachment.Position = mount
		attachment.Parent = chassis

		-- Roblox cylinders lie along their X axis, which is the axle here.
		local wheel = CarLooks.Tyre(tune, {
			Name = name,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(wheels.Width, radius * 2, radius * 2),
			CFrame = cframe * CFrame.new(mount),
		})
		wheel.Parent = wheelFolder
		CarLooks.DressWheel(tune, wheel, left)

		local axle = Instance.new("Motor6D")
		axle.Name = "Axle"
		axle.Part0 = chassis
		axle.Part1 = wheel
		axle.C0 = CFrame.new(mount)
		axle.C1 = CFrame.identity
		axle.Parent = wheel
	end

	model:SetAttribute("CarType", tune.Name)
	CollectionService:AddTag(model, "Car")
	return model
end

return CarBuilder
