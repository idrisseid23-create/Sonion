-- Minimal Roblox mock for offline physics tests: Vector3, CFrame, RaycastParams, Enum,
-- a heightfield world with Raycast/Spherecast, and a rigid-body car chassis.

local Mock = {}

local rawtypeof = typeof
function typeof(v)
	if type(v) == "table" then
		local mt = getmetatable(v)
		if mt and mt.__type then
			return mt.__type
		end
	end
	return rawtypeof(v)
end

---------------------------------------------------------------------------- Vector3
local V = {}
local VMT = { __type = "Vector3" }
local function vec(x, y, z)
	return setmetatable({ X = x, Y = y, Z = z }, VMT)
end
VMT.__index = function(t, k)
	if k == "Magnitude" then
		return math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
	elseif k == "Unit" then
		local m = math.sqrt(t.X * t.X + t.Y * t.Y + t.Z * t.Z)
		if m == 0 then
			return vec(0 / 0, 0 / 0, 0 / 0)
		end
		return vec(t.X / m, t.Y / m, t.Z / m)
	end
	return V[k]
end
VMT.__add = function(a, b)
	return vec(a.X + b.X, a.Y + b.Y, a.Z + b.Z)
end
VMT.__sub = function(a, b)
	return vec(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
end
VMT.__unm = function(a)
	return vec(-a.X, -a.Y, -a.Z)
end
VMT.__mul = function(a, b)
	if type(a) == "number" then
		return vec(a * b.X, a * b.Y, a * b.Z)
	elseif type(b) == "number" then
		return vec(a.X * b, a.Y * b, a.Z * b)
	end
	return vec(a.X * b.X, a.Y * b.Y, a.Z * b.Z)
end
VMT.__div = function(a, b)
	assert(type(b) == "number", "Vector3 / non-number")
	return vec(a.X / b, a.Y / b, a.Z / b)
end
VMT.__eq = function(a, b)
	return a.X == b.X and a.Y == b.Y and a.Z == b.Z
end
VMT.__tostring = function(a)
	return string.format("(%.3f, %.3f, %.3f)", a.X, a.Y, a.Z)
end
function V.Dot(a, b)
	assert(typeof(b) == "Vector3", "Dot needs Vector3")
	return a.X * b.X + a.Y * b.Y + a.Z * b.Z
end
function V.Cross(a, b)
	assert(typeof(b) == "Vector3", "Cross needs Vector3")
	return vec(a.Y * b.Z - a.Z * b.Y, a.Z * b.X - a.X * b.Z, a.X * b.Y - a.Y * b.X)
end
function V.Lerp(a, b, t)
	return a + (b - a) * t
end
Vector3 = {
	new = function(x, y, z)
		return vec(x or 0, y or 0, z or 0)
	end,
	zero = vec(0, 0, 0),
	one = vec(1, 1, 1),
	xAxis = vec(1, 0, 0),
	yAxis = vec(0, 1, 0),
	zAxis = vec(0, 0, 1),
}

---------------------------------------------------------------------------- CFrame
-- Stored as position + rotation columns (right = X column, up = Y column, back = Z column).
local CF = {}
local CFMT = { __type = "CFrame" }
local function cfr(p, xv, yv, zv)
	return setmetatable({ P = p, Xc = xv, Yc = yv, Zc = zv }, CFMT)
end
CFMT.__index = function(t, k)
	if k == "Position" or k == "p" then
		return t.P
	elseif k == "LookVector" then
		return -t.Zc
	elseif k == "RightVector" then
		return t.Xc
	elseif k == "UpVector" then
		return t.Yc
	elseif k == "X" then
		return t.P.X
	elseif k == "Y" then
		return t.P.Y
	elseif k == "Z" then
		return t.P.Z
	elseif k == "Rotation" then
		return cfr(Vector3.zero, t.Xc, t.Yc, t.Zc)
	end
	return CF[k]
end
local function rot(t, v) -- rotate vector
	return t.Xc * v.X + t.Yc * v.Y + t.Zc * v.Z
end
local function irot(t, v)
	return vec(t.Xc:Dot(v), t.Yc:Dot(v), t.Zc:Dot(v))
end
CFMT.__mul = function(a, b)
	if typeof(b) == "Vector3" then
		return a.P + rot(a, b)
	end
	return cfr(a.P + rot(a, b.P), rot(a, b.Xc), rot(a, b.Yc), rot(a, b.Zc))
end
CFMT.__add = function(a, v)
	return cfr(a.P + v, a.Xc, a.Yc, a.Zc)
end
CFMT.__sub = function(a, v)
	return cfr(a.P - v, a.Xc, a.Yc, a.Zc)
end
function CF.PointToWorldSpace(t, v)
	return t.P + rot(t, v)
end
function CF.VectorToWorldSpace(t, v)
	return rot(t, v)
end
function CF.PointToObjectSpace(t, v)
	return irot(t, v - t.P)
end
function CF.VectorToObjectSpace(t, v)
	return irot(t, v)
end
function CF.Inverse(t)
	local xv = vec(t.Xc.X, t.Yc.X, t.Zc.X)
	local yv = vec(t.Xc.Y, t.Yc.Y, t.Zc.Y)
	local zv = vec(t.Xc.Z, t.Yc.Z, t.Zc.Z)
	local inv = cfr(Vector3.zero, xv, yv, zv)
	return cfr(-rot(inv, t.P), xv, yv, zv)
end
function CF.ToObjectSpace(a, b)
	return a:Inverse() * b
end
function CF.Lerp(a, b, t)
	return cfr(a.P:Lerp(b.P, t), a.Xc, a.Yc, a.Zc)
end
local function axisAngle(axis, angle)
	local u = axis.Unit
	local c, s = math.cos(angle), math.sin(angle)
	local function r(v)
		return v * c + u:Cross(v) * s + u * (u:Dot(v) * (1 - c))
	end
	return cfr(Vector3.zero, r(Vector3.xAxis), r(Vector3.yAxis), r(Vector3.zAxis))
end
CFrame = {
	new = function(x, y, z)
		if typeof(x) == "Vector3" then
			return cfr(x, Vector3.xAxis, Vector3.yAxis, Vector3.zAxis)
		end
		return cfr(vec(x or 0, y or 0, z or 0), Vector3.xAxis, Vector3.yAxis, Vector3.zAxis)
	end,
	fromAxisAngle = axisAngle,
	Angles = function(rx, ry, rz)
		local a = axisAngle(Vector3.xAxis, rx)
		local b = axisAngle(Vector3.yAxis, ry)
		local c = axisAngle(Vector3.zAxis, rz)
		return a * b * c
	end,
	lookAt = function(pos, target, upv)
		upv = upv or Vector3.yAxis
		local look = (target - pos).Unit
		local right = look:Cross(upv).Unit
		local up = right:Cross(look)
		return cfr(pos, right, up, -look)
	end,
	fromMatrix = function(pos, xv, yv, zv)
		zv = zv or xv:Cross(yv).Unit
		return cfr(pos, xv, yv, zv)
	end,
}
CFrame.identity = CFrame.new()

---------------------------------------------------------------------------- misc
RaycastParams = {
	new = function()
		return { ExcludeInstances = {}, RespectCanCollide = false, IgnoreWater = false }
	end,
}
Enum = setmetatable({}, {
	__index = function(_, cat)
		return setmetatable({}, {
			__index = function(_, item)
				return { Name = item, EnumType = cat }
			end,
		})
	end,
})
Color3 = {
	fromRGB = function(r, g, b)
		return { R = r / 255, G = g / 255, B = b / 255 }
	end,
	new = function(r, g, b)
		return { R = r, G = g, B = b }
	end,
}
task = {
	spawn = function(f, ...)
		f(...)
	end,
	defer = function(f, ...)
		f(...)
	end,
	wait = function() end,
}

---------------------------------------------------------------------------- world
-- Heightfield: Mock.height(x, z) -> y. Set Mock.height to change the world.
Mock.height = function(_x, _z)
	return 0
end

local function normalAt(x, z)
	local e = 0.05
	local hx = (Mock.height(x + e, z) - Mock.height(x - e, z)) / (2 * e)
	local hz = (Mock.height(x, z + e) - Mock.height(x, z - e)) / (2 * e)
	return vec(-hx, 1, -hz).Unit
end

local groundPart = {
	Name = "Ground",
	Anchored = true,
	IsA = function(_, cls)
		return cls == "BasePart"
	end,
	GetAttribute = function(self, name)
		return Mock.groundAttributes and Mock.groundAttributes[name]
	end,
	GetVelocityAtPosition = function()
		return Vector3.zero
	end,
}
Mock.groundPart = groundPart

local function below(p)
	return p.Y <= Mock.height(p.X, p.Z)
end

Mock.rayCount = 0
local function march(origin, dir, test)
	local len = dir.Magnitude
	local u = dir / len
	local step = 0.04
	if test(origin) then
		return nil -- starts inside: no hit (like Roblox)
	end
	local prev = 0
	local t = step
	while t <= len + 1e-9 do
		if test(origin + u * t) then
			local lo, hi = prev, t
			for _ = 1, 30 do
				local mid = (lo + hi) / 2
				if test(origin + u * mid) then
					hi = mid
				else
					lo = mid
				end
			end
			return hi, u
		end
		prev = t
		t += step
	end
	return nil
end

local material = { Name = "Plastic" }
Mock.material = material

local Workspace = {
	Gravity = 196.2,
	FallenPartsDestroyHeight = -500,
}
function Workspace:Raycast(origin, dir, _params)
	Mock.rayCount += 1
	local t, u = march(origin, dir, below)
	if not t then
		return nil
	end
	local p = origin + u * t
	return { Position = p, Normal = normalAt(p.X, p.Z), Distance = t, Instance = groundPart, Material = Mock.material }
end
function Workspace:Spherecast(origin, radius, dir, _params)
	Mock.rayCount += 1
	local function touching(c)
		local h = Mock.height(c.X, c.Z)
		local n = normalAt(c.X, c.Z)
		return (c.Y - h) * n.Y <= radius
	end
	local t, u = march(origin, dir, touching)
	if not t then
		return nil
	end
	local c = origin + u * t
	local n = normalAt(c.X, c.Z)
	return { Position = c - n * radius, Normal = n, Distance = t, Instance = groundPart, Material = Mock.material }
end
workspace = Workspace

---------------------------------------------------------------------------- rigid body car
-- Box body with given mass and size; comLocal = centre of mass in chassis space.
function Mock.makeCar(tune, startCF)
	local size = tune.Body.Size
	local mass = 300
	local w, h, l = size.X, size.Y + tune.Body.CabinSize.Y, size.Z
	local I = vec(mass / 12 * (h * h + l * l), mass / 12 * (w * w + l * l), mass / 12 * (w * w + h * h))
	local comLocal = tune.CenterOfMass
	local body = {
		mass = mass,
		I = I,
		comLocal = comLocal,
		R = startCF.Rotation,
		p = startCF * comLocal,
		v = Vector3.zero,
		w = Vector3.zero,
	}

	local force = { Force = Vector3.zero, Name = "CarForce" }
	local torque = { Torque = Vector3.zero, Name = "CarTorque" }

	local chassisCF = function()
		local pos = body.p - (body.R * comLocal)
		return cfr(pos, body.R.Xc, body.R.Yc, body.R.Zc)
	end

	local children = { CarForce = force, CarTorque = torque }
	local radius = tune.Wheels.Radius
	local wb, tw, mh = tune.Wheels.WheelBase, tune.Wheels.TrackWidth, tune.Wheels.MountHeight
	for _, name in { "WheelFL", "WheelFR", "WheelRL", "WheelRR" } do
		local front = string.sub(name, 6, 6) == "F"
		local left = string.sub(name, 7, 7) == "L"
		children[name] = {
			Name = name,
			Position = vec(if left then -tw / 2 else tw / 2, mh, if front then -wb / 2 else wb / 2),
		}
	end
	local _ = radius

	local chassis = {}
	local props = {}
	function props.CFrame()
		return chassisCF()
	end
	function props.AssemblyMass()
		return body.mass
	end
	function props.AssemblyCenterOfMass()
		return body.p
	end
	function props.AssemblyLinearVelocity()
		return body.v
	end
	function props.AssemblyAngularVelocity()
		return body.w
	end
	function props.Position()
		return chassisCF().Position
	end
	function props.Size()
		return tune.Body.Size
	end
	local methods = {}
	function methods:FindFirstChild(name)
		return children[name]
	end
	function methods:GetVelocityAtPosition(q)
		return body.v + body.w:Cross(q - body.p)
	end
	function methods:IsA(cls)
		return cls == "BasePart" or cls == "Part"
	end
	setmetatable(chassis, {
		__index = function(_, k)
			if props[k] then
				return props[k]()
			end
			if methods[k] then
				return methods[k]
			end
			if k == "Parent" then
				return workspace
			end
			return nil
		end,
		__newindex = function(_, k, v)
			if k == "CFrame" then
				body.R = v.Rotation
				body.p = v * comLocal
			elseif k == "AssemblyLinearVelocity" then
				body.v = v
			elseif k == "AssemblyAngularVelocity" then
				body.w = v
			else
				error("mock chassis: cannot set " .. tostring(k))
			end
		end,
	})

	local model = {
		Name = tune.Name,
		PrimaryPart = chassis,
		FindFirstChild = function(_, name)
			if name == "Chassis" then
				return chassis
			end
			return nil
		end,
	}

	-- corners for ground collision (body box + cabin top)
	local hx, hy, hz = size.X / 2, size.Y / 2, size.Z / 2
	local corners = {}
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			table.insert(corners, vec(sx * hx, -hy, sz * hz))
			table.insert(corners, vec(sx * hx, hy, sz * hz))
			local cab = tune.Body.CabinSize
			table.insert(corners, vec(sx * cab.X / 2, hy + cab.Y, sz * cab.Z / 2 + tune.Body.CabinOffset.Z))
		end
	end

	local function integrate(h)
		local m = body.mass
		local F = force.Force + vec(0, -workspace.Gravity * m, 0)
		local T = torque.Torque
		-- ground contact on corners (penalty)
		local cf = chassisCF()
		body.contacts = 0
		for _, c in corners do
			local q = cf * c
			local gh = Mock.height(q.X, q.Z)
			if q.Y < gh then
				body.contacts += 1
				local n = normalAt(q.X, q.Z)
				local depth = (gh - q.Y) * n.Y
				local vq = body.v + body.w:Cross(q - body.p)
				local vn = vq:Dot(n)
				local fn = math.max(m * 800 * depth - m * 30 * vn, 0)
				local vt = vq - n * vn
				local ft = Vector3.zero
				if vt.Magnitude > 1e-4 then
					ft = -vt.Unit * math.min(0.3 * fn, vt.Magnitude * m / 8 / h * 0.5)
				end
				local f = n * fn + ft
				F = F + f
				T = T + (q - body.p):Cross(f)
			end
		end
		body.v = body.v + F * (h / m)
		-- world inertia
		local R = body.R
		local wl = R:VectorToObjectSpace(body.w)
		local Iw = vec(body.I.X * wl.X, body.I.Y * wl.Y, body.I.Z * wl.Z)
		local Tl = R:VectorToObjectSpace(T) - wl:Cross(Iw)
		wl = wl + vec(Tl.X / body.I.X, Tl.Y / body.I.Y, Tl.Z / body.I.Z) * h
		body.w = R:VectorToWorldSpace(wl)
		body.p = body.p + body.v * h
		local wm = body.w.Magnitude
		if wm > 1e-9 then
			local dR = axisAngle(body.w, wm * h)
			local nr = dR * R
			-- re-orthonormalise
			local x = nr.Xc.Unit
			local y = (nr.Yc - x * x:Dot(nr.Yc)).Unit
			local z = x:Cross(y)
			body.R = cfr(Vector3.zero, x, y, z)
		end
	end

	local car = { model = model, chassis = chassis, body = body, force = force, torque = torque }
	function car.simulate(dt)
		local sub = 4
		for _ = 1, sub do
			integrate(dt / sub)
		end
	end
	return car
end

return Mock
