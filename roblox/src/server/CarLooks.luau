-- CarLooks
-- Draws each car out of plain parts: chunky, low-poly, flat colours, big wheels.
-- Every part here is for looks only: no mass, no collisions, invisible to raycasts. The
-- physics uses the invisible boxes CarBuilder makes.
--
-- Drawings use studs with the ground at y = 0, the car's front towards -Z and its
-- right side towards +X (Look.DesignRide says how high the body centre sits).
-- Parts in a paintable colour slot get a "PaintSlot" attribute so a paint shop can
-- recolour them later.

local CarLooks = {}

local SLOT_STYLE = {
	Glass = { Material = Enum.Material.Glass, Transparency = 0.35 },
	Light = { Material = Enum.Material.Neon },
	Tail = { Material = Enum.Material.Neon },
	Indicator = { Material = Enum.Material.Neon },
	Tyre = { Material = Enum.Material.Rubber },
	Cardboard = { Material = Enum.Material.Cardboard },
	Chrome = { Material = Enum.Material.Metal },
	Interior = { Material = Enum.Material.Fabric },
	Strap = { Material = Enum.Material.Fabric },
}
local PAINTABLE = { Paint = true, Accent = true, Rim = true, Hub = true }

local function weld(a: BasePart, b: BasePart)
	local w = Instance.new("WeldConstraint")
	w.Part0 = a
	w.Part1 = b
	w.Parent = b
end

local function newPart(className: string, slot: string, colors, shape: Enum.PartType?): BasePart
	local p = Instance.new(className) :: BasePart
	if shape then
		(p :: Part).Shape = shape -- before the size, so the size sticks
	end
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Color = assert(colors[slot], "Look.Colors has no " .. slot)
	local style = SLOT_STYLE[slot]
	p.Material = if style then style.Material else Enum.Material.SmoothPlastic
	p.Transparency = if style and style.Transparency then style.Transparency else 0
	p.Massless = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	if PAINTABLE[slot] then
		p:SetAttribute("PaintSlot", slot)
	end
	return p
end

------------------------------------------------------------------------------------------
-- Kit: drawing helpers. Every position is in drawing space (see the top of the file).
------------------------------------------------------------------------------------------
local Kit = {}
Kit.__index = Kit

function Kit.new(model: Model, chassis: BasePart, tune)
	local self = setmetatable({}, Kit)
	self.Chassis = chassis
	self.Frame = chassis.CFrame * CFrame.new(0, -tune.Look.DesignRide, 0)
	self.Colors = tune.Look.Colors
	self.Folder = Instance.new("Folder")
	self.Folder.Name = "Body"
	self.Folder.Parent = model
	return self
end

function Kit:_place(p: BasePart, size: Vector3, cf: CFrame, name: string?)
	p.Name = name or "Part"
	p.Size = size
	p.CFrame = self.Frame * cf
	p.Parent = self.Folder
	weld(self.Chassis, p)
	return p
end

-- A box from corner to corner.
function Kit:box(slot: string, x0: number, x1: number, y0: number, y1: number, z0: number, z1: number, name: string?)
	local size = Vector3.new(math.abs(x1 - x0), math.abs(y1 - y0), math.abs(z1 - z0))
	local centre = Vector3.new((x0 + x1) / 2, (y0 + y1) / 2, (z0 + z1) / 2)
	return self:_place(newPart("Part", slot, self.Colors), size, CFrame.new(centre), name)
end

-- A right-angled wedge: `corner` is the square corner, leg1 and leg2 run along two of
-- the axes from it, and it is `width` thick along the third axis (centred on the corner).
function Kit:wedge(slot: string, corner: Vector3, leg1: Vector3, leg2: Vector3, width: number, name: string?)
	local yAxis = leg1.Unit
	local zAxis = -leg2.Unit
	local xAxis = yAxis:Cross(zAxis)
	local centre = corner + leg1 / 2 + leg2 / 2
	local size = Vector3.new(width, leg1.Magnitude, leg2.Magnitude)
	return self:_place(newPart("WedgePart", slot, self.Colors), size, CFrame.fromMatrix(centre, xAxis, yAxis, zAxis), name)
end

-- A bar from a to b. `side` is a direction square to the bar: the bar is `across` wide
-- that way and `thick` deep the other way.
function Kit:beam(slot: string, a: Vector3, b: Vector3, side: Vector3, across: number, thick: number, name: string?)
	local yAxis = (b - a).Unit
	local xAxis = (side - yAxis * side:Dot(yAxis)).Unit
	local zAxis = xAxis:Cross(yAxis)
	local size = Vector3.new(across, (b - a).Magnitude, thick)
	return self:_place(newPart("Part", slot, self.Colors), size, CFrame.fromMatrix((a + b) / 2, xAxis, yAxis, zAxis), name)
end

-- A disc or tube lying along `axis`.
function Kit:cylinder(slot: string, centre: Vector3, axis: Vector3, length: number, diameter: number, name: string?)
	local xAxis = axis.Unit
	local helper = if math.abs(xAxis.Y) < 0.99 then Vector3.yAxis else Vector3.zAxis
	local zAxis = xAxis:Cross(helper).Unit
	local yAxis = zAxis:Cross(xAxis)
	local size = Vector3.new(length, diameter, diameter)
	return self:_place(newPart("Part", slot, self.Colors, Enum.PartType.Cylinder), size, CFrame.fromMatrix(centre, xAxis, yAxis, zAxis), name)
end

-- A round tube from a to b.
function Kit:tube(slot: string, a: Vector3, b: Vector3, diameter: number, name: string?)
	return self:cylinder(slot, (a + b) / 2, b - a, (b - a).Magnitude, diameter, name)
end

function Kit:ball(slot: string, centre: Vector3, diameter: number, name: string?)
	local size = Vector3.new(diameter, diameter, diameter)
	return self:_place(newPart("Part", slot, self.Colors, Enum.PartType.Ball), size, CFrame.new(centre), name)
end

-- Runs draw(side) for the left (-1) and right (+1) side.
function Kit:both(draw: (number) -> ())
	draw(-1)
	draw(1)
end

local X = Vector3.xAxis
local Y = Vector3.yAxis
local Z = Vector3.zAxis
local V = Vector3.new

------------------------------------------------------------------------------------------
-- Shared pieces
------------------------------------------------------------------------------------------

-- A bumper across the car with chamfered outer corners. `face` is -1 at the front, 1 at
-- the back; z0 is the side nearer the car, z1 the outer face.
local function bumper(kit, halfWidth: number, y0: number, y1: number, z0: number, z1: number, face: number)
	local chamfer = 0.25
	kit:box("Trim", -halfWidth + chamfer, halfWidth - chamfer, y0, y1, z0, z1, "Bumper")
	kit:both(function(s)
		local zInner = z1 - face * chamfer
		kit:box("Trim", s * (halfWidth - chamfer), s * halfWidth, y0, y1, z0, zInner, "Bumper")
		kit:wedge("Trim", V(s * (halfWidth - chamfer), (y0 + y1) / 2, zInner), X * s * chamfer, Z * face * chamfer, y1 - y0, "Bumper")
	end)
end

-- A parcel: cardboard box with tape over the top and down both ends.
local function parcel(kit, x0, x1, y0, y1, z0, z1, name: string?)
	kit:box("Cardboard", x0, x1, y0, y1, z0, z1, name or "Package")
	local mid = (x0 + x1) / 2
	local tape = 0.2
	kit:box("Tape", mid - tape, mid + tape, y1, y1 + 0.02, z0, z1, "Tape")
	kit:box("Tape", mid - tape, mid + tape, y1 - (y1 - y0) * 0.45, y1 + 0.02, z0 - 0.02, z0, "Tape")
	kit:box("Tape", mid - tape, mid + tape, y1 - (y1 - y0) * 0.45, y1 + 0.02, z1, z1 + 0.02, "Tape")
end

-- A strap over a parcel at depth z, tied down at its sides.
local function strap(kit, halfWidth: number, y0: number, y1: number, z: number)
	local w = 0.1
	kit:box("Strap", -halfWidth - 0.04, halfWidth + 0.04, y1, y1 + 0.05, z - w, z + w, "Strap")
	kit:both(function(s)
		kit:box("Strap", s * halfWidth, s * (halfWidth + 0.04), y0, y1 + 0.05, z - w, z + w, "Strap")
	end)
end

------------------------------------------------------------------------------------------
-- Bolt: courier hatchback. Boxy body, flared arches, round headlights, white roof and a
-- parcel strapped to a roof rack.
------------------------------------------------------------------------------------------
local function hatchback(kit, tune)
	local wheels = tune.Wheels
	local r = wheels.Radius
	local axleF, axleR = -wheels.WheelBase / 2, wheels.WheelBase / 2
	local floor, belt = 0.8, 3.2
	local nose, tail = -5.4, 5.4
	local tub = 1.85 -- half width of the body between the wheels
	local side = 2.65 -- half width of the doors
	local flare = 3.2 -- half width over the wheels
	local archTop = 3.15 -- underside of the arches
	local archHalf = r + 0.3 -- half length of each arch opening

	------------------------------------------------------------------ lower body
	-- Behind the front wheels the body is full width; between the front wheels it is
	-- narrow under the bonnet so the wheels can steer without poking through.
	kit:box("Paint", -tub, tub, floor, belt, axleF + archHalf, axleR + archHalf, "Body")
	kit:box("Paint", -tub, tub, 2.75, belt, axleF - archHalf, axleF + archHalf, "Bonnet")
	kit:box("Paint", -0.9, 0.9, floor, 2.75, axleF - archHalf, axleF + archHalf, "Body")
	kit:box("Trim", -tub, tub, 2.7, 2.75, axleF - archHalf, axleF + archHalf, "WheelWell")
	kit:both(function(s)
		kit:box("Trim", s * 0.9, s * 0.95, floor, 2.7, axleF - archHalf, axleF + archHalf, "WheelWell")
		kit:box("Trim", s * tub, s * (tub + 0.03), floor, archTop, axleR - archHalf + 0.25, axleR + archHalf - 0.25, "WheelWell")
	end)

	-- Nose and tail, with a chamfered top edge between the fenders.
	kit:box("Paint", -side, side, floor, 2.75, nose, axleF - archHalf, "Nose")
	kit:wedge("Paint", V(0, 2.75, axleF - archHalf), Y * 0.45, Z * (nose - (axleF - archHalf)), tub * 2, "Nose")
	kit:box("Paint", -side, side, floor, 2.75, axleR + archHalf, tail, "Tail")
	kit:wedge("Paint", V(0, 2.75, axleR + archHalf), Y * 0.45, Z * (tail - (axleR + archHalf)), tub * 2, "Tail")

	kit:both(function(s)
		-- Doors between the arches, with a lightning bolt down each side.
		kit:box("Paint", s * tub, s * side, floor, belt, axleF + archHalf, axleR - archHalf, "Door")
		kit:box("Trim", s * (side - 0.05), s * (side + 0.07), floor, 1.15, axleF + archHalf, axleR - archHalf, "Sill")
		kit:box("Trim", s * side, s * (side + 0.01), 0.85, belt, 1.2, 1.26, "DoorLine")
		kit:box("Trim", s * side, s * (side + 0.05), 2.65, 2.78, 0.7, 1.05, "Handle")
		-- A stepped "bolt" stripe: high at the front, a sharp drop, low at the back.
		local x0, x1 = s * side, s * (side + 0.03)
		local doorFront, doorBack = axleF + archHalf, axleR - archHalf
		kit:box("Accent", x0, x1, 2.3, 2.6, doorFront, -0.35, "Bolt")
		kit:box("Accent", x0, x1, 1.75, 2.05, 0.35, doorBack, "Bolt")
		kit:beam("Accent", V(x1, 2.45, -0.5), V(x1, 1.9, 0.5), X, 0.03, 0.3, "Bolt")

		-- Fenders: flared over each wheel and running out to the nose and tail.
		for _, axle in { axleF, axleR } do
			local z0, z1 = axle - archHalf, axle + archHalf
			local zStart = if axle == axleF then nose else z0
			local zEnd = if axle == axleR then tail else z1
			kit:box("Paint", s * tub, s * (flare - 0.35), archTop, 3.5, zStart, zEnd, "Fender")
			kit:wedge("Paint", V(s * (flare - 0.35), archTop, (zStart + zEnd) / 2), Y * 0.35, X * s * 0.35, zEnd - zStart, "Fender")
			if axle == axleF then
				kit:box("Paint", s * tub, s * flare, floor, archTop, nose, z0 + 0.25, "Fender")
			else
				kit:box("Paint", s * side, s * flare, floor, archTop, z0, z0 + 0.25, "Fender")
			end
			if axle == axleR then
				kit:box("Paint", s * tub, s * flare, floor, archTop, z1 - 0.25, tail, "Fender")
			else
				kit:box("Paint", s * side, s * flare, floor, archTop, z1 - 0.25, z1, "Fender")
			end
			local mid = s * (tub + flare) / 2
			kit:wedge("Paint", V(mid, archTop, z0 + 0.25), -Y * 0.4, Z * 0.4, flare - tub, "Arch")
			kit:wedge("Paint", V(mid, archTop, z1 - 0.25), -Y * 0.4, -Z * 0.4, flare - tub, "Arch")
			kit:box("Trim", s * tub, s * flare, archTop - 0.04, archTop, z0 + 0.25, z1 - 0.25, "WheelWell")
		end
	end)

	------------------------------------------------------------------ cabin
	local glassHalf = 2.3
	local roofY = 5.9
	local screenBase, screenTop = -1.9, -0.75
	local hatchTop, hatchBase = 4.35, 4.95
	kit:box("Glass", -glassHalf, glassHalf, belt, roofY, screenTop, hatchTop, "Windows")
	kit:wedge("Glass", V(0, belt, screenTop), Y * (roofY - belt), Z * (screenBase - screenTop), glassHalf * 2, "Windscreen")
	kit:wedge("Glass", V(0, belt, hatchTop), Y * (roofY - belt), Z * (hatchBase - hatchTop), glassHalf * 2, "RearWindow")
	kit:box("Accent", -2.45, 2.45, roofY, 6.25, screenTop - 0.15, hatchTop + 0.15, "Roof")
	kit:box("Trim", -glassHalf, glassHalf, belt, belt + 0.12, screenBase - 0.15, screenBase + 0.15, "Cowl")
	kit:box("Accent", -2.4, 2.4, 6.0, 6.2, hatchTop + 0.15, hatchBase, "Spoiler")
	kit:box("Tail", -0.6, 0.6, 6.03, 6.12, hatchBase, hatchBase + 0.03, "BrakeLight")
	kit:both(function(s)
		local x = s * 2.35
		kit:beam("Paint", V(x, belt, screenBase), V(x, roofY, screenTop), X, 0.2, 0.3, "Pillar")
		kit:box("Paint", s * 2.25, s * 2.45, belt, roofY, 1.25, 1.6, "Pillar")
		kit:beam("Paint", V(x, belt, hatchBase), V(x, roofY, hatchTop), X, 0.2, 0.3, "Pillar")
		-- Wipers resting at the bottom of the windscreen.
		local wx = if s < 0 then -1.0 else 0.9
		kit:box("Trim", wx - 0.7, wx + 0.7, belt + 0.12, belt + 0.2, screenBase + 0.0, screenBase + 0.06, "Wiper")
		-- Mirrors.
		kit:box("Trim", s * 2.4, s * 2.6, 3.45, 3.62, -1.5, -1.3, "Mirror")
		kit:box("Paint", s * 2.55, s * 3.05, 3.35, 3.8, -1.55, -1.2, "Mirror")
		kit:box("Chrome", s * 2.6, s * 3.0, 3.4, 3.75, -1.2, -1.18, "Mirror")
	end)

	-- Inside: dashboard, steering wheel and the seat back (the driver sits here).
	kit:box("Trim", -2.25, 2.25, belt - 0.2, 3.6, -1.65, -1.1, "Dashboard")
	kit:beam("Trim", V(0, 3.4, -1.25), V(0, 3.9, -0.85), X, 0.18, 0.18, "SteeringColumn")
	kit:cylinder("Trim", V(0, 3.95, -0.8), V(0, 0.55, 1), 0.12, 1.1, "SteeringWheel")
	kit:box("Interior", -0.95, 0.95, belt - 0.2, 4.4, 1.12, 1.45, "Seat")
	kit:box("Interior", -0.6, 0.6, 4.4, 4.95, 1.15, 1.42, "Headrest")

	------------------------------------------------------------------ front
	bumper(kit, flare + 0.05, 0.7, 1.5, nose - 0.2 + 0.5, nose - 0.2, -1)
	kit:box("Plate", -0.75, 0.75, 0.85, 1.3, nose - 0.23, nose - 0.2, "Plate")
	kit:box("Trim", -0.85, 0.85, 1.65, 2.45, nose - 0.06, nose, "Grille")
	kit:box("Accent", -0.75, 0.75, 1.88, 1.96, nose - 0.08, nose - 0.06, "Grille")
	kit:box("Accent", -0.75, 0.75, 2.14, 2.22, nose - 0.08, nose - 0.06, "Grille")
	kit:both(function(s)
		kit:cylinder("Trim", V(s * 1.8, 2.05, nose - 0.04), Z, 0.08, 1.1, "Headlight")
		kit:cylinder("Light", V(s * 1.8, 2.05, nose - 0.07), Z, 0.06, 0.82, "Headlight")
		kit:box("Indicator", s * 2.4, s * 2.6, 1.6, 1.82, nose - 0.04, nose, "Indicator")
	end)

	------------------------------------------------------------------ back
	bumper(kit, flare + 0.05, 0.9, 1.55, tail + 0.2 - 0.5, tail + 0.2, 1)
	kit:box("Plate", -2.25, -1.15, 1.02, 1.43, tail + 0.2, tail + 0.23, "Plate")
	kit:both(function(s)
		kit:box("Tail", s * 1.75, s * 2.6, 1.95, 2.7, tail, tail + 0.05, "Taillight")
		kit:box("Indicator", s * 1.75, s * 2.6, 1.6, 1.95, tail, tail + 0.05, "Indicator")
	end)
	kit:cylinder("Chrome", V(1.7, 0.72, tail + 0.05), Z, 0.6, 0.36, "Exhaust")
	kit:cylinder("Trim", V(1.7, 0.72, tail + 0.06), Z, 0.6, 0.24, "Exhaust")

	-- Spare wheel on the tailgate: the Bolt's signature from behind.
	local spare = V(0, 2.2, tail + 0.55)
	kit:box("Trim", -0.3, 0.3, 1.95, 2.45, tail, spare.Z - 0.25, "SpareMount")
	kit:cylinder("Tyre", spare, Z, 0.55, 2.1, "SpareWheel")
	kit:cylinder("Tyre", spare, Z, 0.65, 1.86, "SpareWheel")
	kit:cylinder("Rim", spare, Z, 0.68, 1.25, "SpareWheel")
	kit:cylinder("Hub", spare, Z, 0.72, 0.55, "SpareWheel")

	------------------------------------------------------------------ roof rack and parcel
	for _, z in { 0.9, 3.1 } do
		kit:box("Trim", -2.3, 2.3, 6.45, 6.6, z - 0.15, z + 0.15, "RoofRack")
		kit:both(function(s)
			kit:box("Trim", s * 2.0, s * 2.3, 6.25, 6.45, z - 0.15, z + 0.15, "RoofRack")
		end)
	end
	parcel(kit, -1.35, 1.35, 6.6, 7.9, 0.6, 3.4)
	strap(kit, 1.35, 6.6, 7.9, 1.2)
	strap(kit, 1.35, 6.6, 7.9, 2.8)
end

------------------------------------------------------------------------------------------
-- Mule: box van. Short white cab with the same chunky fenders as the Bolt, and a tall
-- cargo box that overhangs the cab roof, with an orange stripe and a big parcel logo.
------------------------------------------------------------------------------------------
local function van(kit, tune)
	local wheels = tune.Wheels
	local r = wheels.Radius
	local axleF, axleR = -wheels.WheelBase / 2, wheels.WheelBase / 2
	local floor, belt = 0.9, 3.4
	local nose, tail = -5.7, 5.7
	local tub, side, flare = 2.0, 2.6, 3.4
	local archTop = 3.35
	local archHalf = r + 0.3
	local cabBack = -1.2
	local boxBottom, boxTop, boxHalf, boxFront = 3.3, 8.2, 3.15, -2.9
	local z0, z1 = axleF - archHalf, axleF + archHalf

	------------------------------------------------------------------ cab
	kit:box("Paint", -1.0, 1.0, floor, 3.0, z0, z1, "Body")
	kit:box("Paint", -tub, tub, 3.0, belt, z0, z1, "Bonnet")
	kit:box("Trim", -tub, tub, 2.95, 3.0, z0, z1, "WheelWell")
	kit:box("Paint", -side, side, floor, belt, z1, cabBack, "Cab")
	kit:box("Paint", -side, side, floor, 3.0, nose, z0, "Nose")
	kit:wedge("Paint", V(0, 3.0, z0), Y * 0.4, Z * (nose - z0), tub * 2, "Nose")
	kit:both(function(s)
		kit:box("Trim", s * 1.0, s * 1.05, floor, 2.95, z0, z1, "WheelWell")
		kit:box("Paint", s * tub, s * (flare - 0.35), archTop, 3.7, nose, z1, "Fender")
		kit:wedge("Paint", V(s * (flare - 0.35), archTop, (nose + z1) / 2), Y * 0.35, X * s * 0.35, z1 - nose, "Fender")
		kit:box("Paint", s * tub, s * flare, floor, archTop, nose, z0 + 0.25, "Fender")
		kit:box("Paint", s * side, s * flare, floor, archTop, z1 - 0.25, z1, "Fender")
		local mid = s * (tub + flare) / 2
		kit:wedge("Paint", V(mid, archTop, z0 + 0.25), -Y * 0.4, Z * 0.4, flare - tub, "Fender")
		kit:wedge("Paint", V(mid, archTop, z1 - 0.25), -Y * 0.4, -Z * 0.4, flare - tub, "Fender")
		kit:box("Trim", s * tub, s * flare, archTop - 0.04, archTop, z0 + 0.25, z1 - 0.25, "WheelWell")
		kit:box("Accent", s * side, s * (side + 0.02), 2.3, 2.6, z1, cabBack, "Stripe")
	end)

	-- Cab windows, roof and pillars.
	local roofY, screenBase, screenTop = 6.2, -4.4, -3.5
	kit:box("Glass", -2.45, 2.45, belt, roofY, screenTop, cabBack, "Windows")
	kit:wedge("Glass", V(0, belt, screenTop), Y * (roofY - belt), Z * (screenBase - screenTop), 4.9, "Windscreen")
	kit:box("Paint", -side, side, roofY, 6.5, screenTop - 0.1, cabBack, "Roof")
	kit:box("Trim", -2.45, 2.45, belt, belt + 0.12, screenBase - 0.15, screenBase + 0.15, "Cowl")
	kit:both(function(s)
		kit:beam("Paint", V(s * 2.5, belt, screenBase), V(s * 2.5, roofY, screenTop), X, 0.2, 0.3, "Pillar")
		kit:box("Paint", s * 2.4, s * 2.6, belt, roofY, -1.6, cabBack, "Pillar")
		kit:box("Paint", s * 2.45, s * side, belt, 3.75, screenTop, cabBack, "Door")
		kit:box("Trim", s * side, s * (side + 0.05), 3.48, 3.6, -2.1, -1.8, "Handle")
		local wx = if s < 0 then -1.1 else 1.0
		kit:box("Trim", wx - 0.75, wx + 0.75, belt + 0.12, belt + 0.2, screenBase, screenBase + 0.06, "Wiper")
		-- Big van mirrors on arms.
		kit:box("Trim", s * 2.5, s * 3.15, 4.2, 4.32, -3.95, -3.83, "Mirror")
		kit:box("Trim", s * 3.05, s * 3.3, 3.75, 4.85, -4.0, -3.75, "Mirror")
		kit:box("Chrome", s * 3.08, s * 3.27, 3.8, 4.8, -3.75, -3.73, "Mirror")
	end)
	kit:box("Trim", -2.4, 2.4, belt - 0.2, 4.0, -4.1, -3.55, "Dashboard")
	kit:beam("Trim", V(0, 3.8, -3.6), V(0, 4.3, -3.2), X, 0.18, 0.18, "SteeringColumn")
	kit:cylinder("Trim", V(0, 4.35, -3.15), V(0, 0.55, 1), 0.12, 1.1, "SteeringWheel")
	kit:box("Interior", -0.95, 0.95, belt, 5.0, -1.75, -1.4, "Seat")
	kit:box("Interior", -0.6, 0.6, 5.0, 5.5, -1.72, -1.45, "Headrest")

	-- Face: big square headlights, chrome grille, chunky bumper with fog lights.
	kit:box("Trim", -1.1, 1.1, 1.6, 2.85, nose - 0.06, nose, "Grille")
	for _, y in { 1.85, 2.2, 2.55 } do
		kit:box("Chrome", -1.0, 1.0, y - 0.05, y + 0.05, nose - 0.08, nose - 0.06, "Grille")
	end
	kit:both(function(s)
		kit:box("Trim", s * 1.3, s * 2.5, 2.1, 2.9, nose - 0.04, nose, "Headlight")
		kit:box("Light", s * 1.4, s * 2.4, 2.2, 2.8, nose - 0.07, nose - 0.04, "Headlight")
		kit:box("Indicator", s * 1.4, s * 2.4, 1.8, 2.0, nose - 0.05, nose, "Indicator")
		kit:cylinder("Light", V(s * 2.55, 1.2, nose - 0.3), Z, 0.08, 0.42, "FogLight")
	end)
	bumper(kit, flare + 0.05, 0.75, 1.6, nose + 0.3, nose - 0.25, -1)
	kit:box("Plate", -0.75, 0.75, 0.9, 1.35, nose - 0.28, nose - 0.25, "Plate")

	------------------------------------------------------------------ cargo box
	kit:box("Paint", -boxHalf, boxHalf, boxBottom, boxTop, cabBack, tail, "CargoBox")
	kit:box("Paint", -boxHalf, boxHalf, roofY + 0.3, boxTop, boxFront + 0.4, cabBack, "CargoBox")
	kit:box("Paint", -boxHalf, boxHalf, roofY + 0.3, boxTop - 0.4, boxFront, boxFront + 0.4, "CargoBox")
	kit:wedge("Paint", V(0, boxTop - 0.4, boxFront + 0.4), Y * 0.4, -Z * 0.4, boxHalf * 2, "CargoBox")
	kit:box("Trim", -boxHalf, boxHalf, roofY + 0.25, roofY + 0.3, boxFront, cabBack, "CargoBox")
	for _, x in { -0.8, 0, 0.8 } do
		kit:box("Indicator", x - 0.2, x + 0.2, 7.55, 7.7, boxFront - 0.03, boxFront, "MarkerLight")
	end
	kit:both(function(s)
		kit:box("Accent", s * boxHalf, s * (boxHalf + 0.02), 4.6, 5.2, cabBack, tail, "Stripe")
		-- Courier logo: a big parcel on each side.
		local x0, x1 = s * boxHalf, s * (boxHalf + 0.03)
		kit:box("Cardboard", x0, x1, 5.6, 7.5, 1.0, 3.1, "Logo")
		kit:box("Tape", x1, s * (boxHalf + 0.04), 5.6, 7.5, 1.88, 2.22, "Logo")
		kit:box("Tape", x1, s * (boxHalf + 0.04), 6.95, 7.12, 1.0, 3.1, "Logo")
	end)

	-- Back: barn doors with lock bars and hinges, lights high on the corners.
	kit:box("Trim", -0.04, 0.04, boxBottom + 0.1, boxTop - 0.1, tail, tail + 0.02, "DoorLine")
	kit:box("Accent", -boxHalf, boxHalf, 4.6, 5.2, tail, tail + 0.02, "Stripe")
	kit:both(function(s)
		for _, x in { 0.55, 2.35 } do
			kit:cylinder("Chrome", V(s * x, (boxBottom + boxTop) / 2, tail + 0.1), Y, boxTop - boxBottom - 0.4, 0.14, "LockBar")
		end
		kit:box("Trim", s * 0.3, s * 0.8, 5.5, 5.65, tail, tail + 0.12, "Handle")
		for _, y in { 3.9, 6.0, 7.7 } do
			kit:box("Trim", s * 2.85, s * 3.15, y - 0.12, y + 0.12, tail, tail + 0.06, "Hinge")
		end
		kit:box("Tail", s * 2.45, s * 3.05, 3.45, 4.15, tail, tail + 0.05, "Taillight")
		kit:box("Indicator", s * 2.45, s * 3.05, 4.15, 4.45, tail, tail + 0.05, "Indicator")
	end)
	for _, x in { -0.8, 0, 0.8 } do
		kit:box("Tail", x - 0.2, x + 0.2, 7.85, 8.0, tail, tail + 0.03, "MarkerLight")
	end

	------------------------------------------------------------------ underneath
	kit:box("Lower", -2.0, 2.0, 1.2, boxBottom, cabBack, tail - 0.3, "Chassis")
	kit:both(function(s)
		kit:box("Lower", s * 2.7, s * 2.85, 1.45, boxBottom, cabBack, axleR - archHalf, "SideSkirt")
		kit:box("Lower", s * 2.0, s * 3.4, boxBottom - 0.1, boxBottom, axleR - archHalf, axleR + archHalf, "Mudguard")
		kit:box("Trim", s * 2.1, s * 3.3, 1.0, boxBottom - 0.1, axleR + archHalf - 0.1, axleR + archHalf, "MudFlap")
	end)
	bumper(kit, boxHalf - 0.1, 1.0, 1.7, tail - 0.4, tail + 0.25, 1)
	kit:box("Plate", -0.75, 0.75, 1.1, 1.55, tail + 0.25, tail + 0.28, "Plate")
	kit:cylinder("Chrome", V(-1.8, 0.85, tail - 0.1), Z, 0.7, 0.36, "Exhaust")
	kit:cylinder("Trim", V(-1.8, 0.85, tail - 0.09), Z, 0.7, 0.24, "Exhaust")
end

------------------------------------------------------------------------------------------
-- Kite: stunt buggy. Low cyan tub, white roll cage with rally lights, open wheels, an
-- exposed engine, a crate strapped behind the seat and a rear wing.
------------------------------------------------------------------------------------------
local function buggy(kit, _tune)
	local floor, top = 1.0, 2.6
	local nose, tail = -4.9, 4.7
	local tub = 1.7

	------------------------------------------------------------------ tub and nose
	kit:box("Trim", -1.6, 1.6, floor, 1.3, nose + 0.5, tail - 0.1, "BellyPan")
	kit:box("Paint", -tub, tub, 1.25, top, -2.2, 2.4, "Tub")
	kit:box("Paint", -1.5, 1.5, 1.25, 1.7, nose, -2.2, "Nose")
	kit:wedge("Paint", V(0, 1.7, -2.2), Y * (top - 1.7), Z * (nose + 2.2), 3.0, "Nose")
	-- Racing stripes down the nose.
	local normal = V(0, -(nose + 2.2), top - 1.7).Unit * 0.02
	kit:both(function(s)
		kit:beam("Accent", V(s * 0.4, 1.7, nose) + normal, V(s * 0.4, top, -2.2) + normal, X, 0.32, 0.03, "Stripe")
		kit:cylinder("Trim", V(s * 1.05, 1.48, nose - 0.02), Z, 0.06, 0.5, "Headlight")
		kit:cylinder("Light", V(s * 1.05, 1.48, nose - 0.05), Z, 0.04, 0.38, "Headlight")
	end)
	kit:tube("Accent", V(-1.4, 1.12, nose - 0.25), V(1.4, 1.12, nose - 0.25), 0.26, "NerfBar")
	kit:both(function(s)
		kit:tube("Accent", V(s * 1.0, 1.12, nose - 0.25), V(s * 1.0, 1.12, nose + 0.3), 0.2, "NerfBar")
		-- Side pods with a racing roundel and a nerf bar.
		kit:box("Paint", s * tub, s * 2.0, 1.25, 2.3, -1.7, 1.6, "SidePod")
		kit:cylinder("Accent", V(s * 2.02, 1.85, -0.1), X, 0.04, 0.85, "Roundel")
		kit:cylinder("Hub", V(s * 2.04, 1.85, -0.1), X, 0.04, 0.45, "Roundel")
		kit:tube("Accent", V(s * 2.05, 1.35, -1.5), V(s * 2.05, 1.35, 1.5), 0.22, "NerfBar")
	end)

	------------------------------------------------------------------ cockpit
	kit:box("Trim", -1.2, 1.2, top - 0.1, 3.05, -2.2, -1.75, "Dashboard")
	kit:beam("Glass", V(0, top + 0.4, -2.1), V(0, 3.75, -1.75), X, 2.5, 0.06, "Windscreen")
	kit:beam("Trim", V(0, 2.9, -1.8), V(0, 3.35, -1.35), X, 0.16, 0.16, "SteeringColumn")
	kit:cylinder("Trim", V(0, 3.4, -1.3), V(0, 0.6, 1), 0.12, 0.95, "SteeringWheel")
	kit:box("Interior", -0.85, 0.85, top - 0.2, 4.3, 0.45, 0.75, "Seat")
	kit:box("Interior", -0.55, 0.55, 4.3, 4.8, 0.48, 0.72, "Headrest")

	------------------------------------------------------------------ roll cage
	local cage = 0.24
	local mainZ, frontZ, hoopTop, frontTop = 0.9, -1.35, 6.0, 5.8
	kit:both(function(s)
		local footMain, topMain = V(s * 1.55, top, mainZ), V(s * 1.35, hoopTop, mainZ)
		local footFront, topFront = V(s * 1.55, top, -1.95), V(s * 1.3, frontTop, frontZ)
		local back = V(s * 1.2, top - 0.1, 3.1)
		kit:tube("Accent", footMain, topMain, cage, "Cage")
		kit:tube("Accent", footFront, topFront, cage, "Cage")
		kit:tube("Accent", topFront, topMain, cage, "Cage")
		kit:tube("Accent", topMain, back, cage, "Cage")
		for _, joint in { topMain, topFront } do
			kit:ball("Accent", joint, cage + 0.08, "Cage")
		end
		-- Rally lights on the front bar.
		kit:cylinder("Trim", V(s * 0.6, frontTop, frontZ - 0.2), Z, 0.35, 0.62, "RallyLight")
		kit:cylinder("Light", V(s * 0.6, frontTop, frontZ - 0.39), Z, 0.04, 0.48, "RallyLight")
	end)
	kit:tube("Accent", V(-1.35, hoopTop, mainZ), V(1.35, hoopTop, mainZ), cage, "Cage")
	kit:tube("Accent", V(-1.3, frontTop, frontZ), V(1.3, frontTop, frontZ), cage, "Cage")

	------------------------------------------------------------------ back: crate, engine, wing
	kit:box("Paint", -1.6, 1.6, 1.25, 2.4, 2.4, tail, "EngineBay")
	parcel(kit, -0.85, 0.85, top - 0.2, 3.7, 1.15, 2.6, "Package")
	strap(kit, 0.85, top - 0.2, 3.7, 1.9)
	kit:box("Chrome", -0.8, 0.8, 2.4, 3.1, 2.9, 4.2, "Engine")
	kit:cylinder("Chrome", V(0, 3.35, 3.55), Y, 0.5, 0.8, "AirFilter")
	kit:both(function(s)
		kit:box("Trim", s * 0.8, s * 1.3, 2.5, 2.95, 3.0, 4.1, "Engine")
		kit:tube("Chrome", V(s * 0.55, 2.9, 4.15), V(s * 0.7, 3.65, 5.0), 0.24, "Exhaust")
		kit:box("Tail", s * 1.0, s * 1.5, 1.9, 2.25, tail, tail + 0.05, "Taillight")
		-- Wing struts and end plates.
		kit:beam("Trim", V(s * 1.0, 2.4, 4.3), V(s * 1.0, 5.0, 4.55), X, 0.16, 0.3, "WingStrut")
		kit:box("Paint", s * 2.5, s * 2.62, 4.65, 5.55, 3.85, 5.3, "Wing")
	end)
	kit:beam("Trim", V(0, 5.15, 3.9), V(0, 4.95, 5.2), X, 5.0, 0.18, "Wing")
	kit:box("Accent", -2.5, 2.5, 5.17, 5.2, 3.95, 4.3, "Wing")
	kit:tube("Accent", V(-1.6, 1.45, tail + 0.25), V(1.6, 1.45, tail + 0.25), 0.26, "NerfBar")
end

local STYLES = {
	Hatchback = hatchback,
	Van = van,
	Buggy = buggy,
}

-- Draws the car's body. Called by CarBuilder.
function CarLooks.Dress(model: Model, chassis: BasePart, tune)
	local draw = STYLES[tune.Look.Style] or hatchback
	draw(Kit.new(model, chassis, tune), tune)
end

------------------------------------------------------------------------------------------
-- Wheels
------------------------------------------------------------------------------------------

-- The tyre itself: the part the Axle joint turns. props sets its Name, Shape, Size, CFrame.
function CarLooks.Tyre(tune, props): Part
	local p = newPart("Part", "Tyre", tune.Look.Colors, props.Shape) :: Part
	p.Name = props.Name
	p.Size = props.Size
	p.CFrame = props.CFrame
	return p
end

-- Adds the tyre wall, rim, spokes and hub to a tyre (they turn with it).
function CarLooks.DressWheel(tune, tyre: Part, _isLeft: boolean)
	local colors = tune.Look.Colors
	local r = tune.Wheels.Radius
	local w = tune.Wheels.Width
	local rim = r * 0.62
	local function add(slot: string, name: string, shape: Enum.PartType?, size: Vector3, rotation: CFrame?)
		local p = newPart("Part", slot, colors, shape)
		p.Name = name
		p.Size = size
		p.CFrame = tyre.CFrame * (rotation or CFrame.identity)
		p.Parent = tyre
		weld(tyre, p)
		return p
	end
	add("Tyre", "Wall", Enum.PartType.Cylinder, Vector3.new(w + 0.2, 2 * r - 0.24, 2 * r - 0.24))
	add("Rim", "Rim", Enum.PartType.Cylinder, Vector3.new(w + 0.24, 2 * rim, 2 * rim))
	add("Spoke", "Spoke", nil, Vector3.new(w + 0.27, 2 * rim * 0.9, 0.3))
	add("Spoke", "Spoke", nil, Vector3.new(w + 0.27, 0.3, 2 * rim * 0.9))
	add("Hub", "Hub", Enum.PartType.Cylinder, Vector3.new(w + 0.31, r * 0.55, r * 0.55))
end

return CarLooks
