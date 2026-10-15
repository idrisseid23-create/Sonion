-- Builds every car with the real CarBuilder (inside the API-checking mock) and writes the
-- visible parts to preview/cars.json, so preview/render.mjs can draw them.
-- Run from the tests folder: ./luaurun preview/export.luau > preview/cars.json
local R = assert(__loadfile("./robloxmock.luau"))()
local SRC = "../src"

local carSystem = R.new("Folder")
carSystem.Name = "CarSystem"
carSystem.Parent = R.ReplicatedStorage
for _, name in { "CarConfig", "CarMath", "CarPhysics" } do
	R.module(name, SRC .. "/shared/" .. name .. ".luau", carSystem)
end
local serverFolder = R.new("Folder")
serverFolder.Name = "CarSystem"
serverFolder.Parent = R.ServerScriptService
R.module("CarLooks", SRC .. "/server/CarLooks.luau", serverFolder)
local builderModule = R.module("CarBuilder", SRC .. "/server/CarBuilder.luau", serverFolder)

local CarConfig = require(carSystem.CarConfig)
local CarPhysics = require(carSystem.CarPhysics)
local CarBuilder = require(builderModule)

local function json(v)
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then
			return "0"
		end
		return string.format("%.4f", v)
	elseif t == "string" then
		return '"' .. v:gsub('[%c"\\]', function(c)
			return string.format("\\u%04x", string.byte(c))
		end) .. '"'
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		if #v > 0 or next(v) == nil then
			local out = {}
			for _, item in v do
				table.insert(out, json(item))
			end
			return "[" .. table.concat(out, ",") .. "]"
		end
		local keys = {}
		for k in v do
			table.insert(keys, k)
		end
		table.sort(keys)
		local out = {}
		for _, k in keys do
			table.insert(out, json(k) .. ":" .. json(v[k]))
		end
		return "{" .. table.concat(out, ",") .. "}"
	end
	return "null"
end

local function vec(v)
	return { v.X, v.Y, v.Z }
end

local BASE_PARTS = { Part = true, WedgePart = true, CornerWedgePart = true, Seat = true }

local function isPart(inst)
	return BASE_PARTS[inst.ClassName] == true
end

local function partsUnder(inst, out)
	for _, child in inst:GetChildren() do
		if isPart(child) then
			table.insert(out, child)
		end
		partsUnder(child, out)
	end
	return out
end

-- Put a wheel where WheelVisuals would at rest (hanging at RestExtension), optionally steered.
local function poseWheels(model, chassis, extension, steer)
	for _, inst in model:GetDescendants() do
		if inst.ClassName == "Motor6D" and inst.Name == "Axle" then
			local wheel = inst.Part1
			local isFront = string.sub(wheel.Name, 6, 6) == "F"
			local transform = CFrame.new(0, -extension, 0) * CFrame.Angles(0, if isFront then -steer else 0, 0)
			local target = chassis.CFrame * inst.C0 * transform * inst.C1:Inverse()
			local delta = target * wheel.CFrame:Inverse()
			local moved = partsUnder(wheel, { wheel })
			for _, p in moved do
				p.CFrame = delta * p.CFrame
			end
		end
	end
end

local cars = {}
for _, carName in { "Bolt", "Mule", "Kite" } do
	for _, pose in { { Name = "rest", Steer = 0 }, { Name = "steer", Steer = math.rad(20) } } do
		local tune = CarConfig.Get(carName)
		local model = CarBuilder.Build(tune, CFrame.new(0, 10, 0))
		local physics = CarPhysics.new(model, tune, { Driver = false })
		local chassis = model.PrimaryPart
		-- Stand it on the ground (y = 0) at its resting height.
		local shift = CFrame.new(0, physics.RideHeight - 10, 0)
		for _, p in partsUnder(model, {}) do
			p.CFrame = shift * p.CFrame
		end
		poseWheels(model, chassis, physics.RestExtension, pose.Steer)

		local parts = {}
		local seat
		for _, p in partsUnder(model, {}) do
			if p.Name == "DriverSeat" then
				seat = { cframe = { vec(p.CFrame.Position), vec(p.CFrame.Xc), vec(p.CFrame.Yc), vec(p.CFrame.Zc) }, size = vec(p.Size) }
			end
			if p.Transparency < 1 then
				local shape = "Block"
				if p.ClassName == "WedgePart" then
					shape = "Wedge"
				elseif p.ClassName == "CornerWedgePart" then
					shape = "CornerWedge"
				elseif p.ClassName == "Part" and p.Shape then
					shape = p.Shape.Name
				end
				local color = p.Color or Color3.new(0.64, 0.64, 0.64)
				table.insert(parts, {
					name = p.Name,
					shape = shape,
					size = vec(p.Size),
					cframe = { vec(p.CFrame.Position), vec(p.CFrame.Xc), vec(p.CFrame.Yc), vec(p.CFrame.Zc) },
					color = { color.R, color.G, color.B },
					material = if p.Material then p.Material.Name else "Plastic",
					transparency = p.Transparency,
					reflectance = p.Reflectance,
				})
			end
		end
		table.insert(cars, {
			name = carName,
			pose = pose.Name,
			rideHeight = physics.RideHeight,
			chassisSize = vec(chassis.Size),
			seat = seat,
			partCount = #parts,
			parts = parts,
		})
	end
end

print(json({ cars = cars }))
