-- CarServer
-- Spawns cars, lets players get in and out, hands the car's physics to the driver's
-- computer while they drive, and keeps empty cars parked on their suspension.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CarSystem = ReplicatedStorage:WaitForChild("CarSystem")
local CarConfig = require(CarSystem:WaitForChild("CarConfig"))
local CarPhysics = require(CarSystem:WaitForChild("CarPhysics"))
local CarBuilder = require(script.Parent:WaitForChild("CarBuilder"))

local SPAWN_COOLDOWN = 2
local SPAWN_DISTANCE = 16 -- studs in front of the player

local remote = CarSystem:FindFirstChild("CarRemote")
if not remote then
	remote = Instance.new("RemoteEvent")
	remote.Name = "CarRemote"
	remote.Parent = CarSystem
end

local carsFolder = workspace:FindFirstChild("Cars")
if not carsFolder then
	carsFolder = Instance.new("Folder")
	carsFolder.Name = "Cars"
	carsFolder.Parent = workspace
end

local playerCars: { [Player]: Model } = {}
local lastSpawn: { [Player]: number } = {}
local parked: { [Model]: any } = {} -- car -> CarPhysics running on the server while empty

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function setOwner(car: Model, player: Player?)
	local chassis = car.PrimaryPart
	if chassis and chassis:IsDescendantOf(workspace) and not chassis.Anchored then
		local ok, err = pcall(chassis.SetNetworkOwner, chassis, player)
		if not ok then
			warn("[CarServer] could not set network owner:", err)
		end
	end
end

local function groundBelow(position: Vector3): RaycastResult?
	local params = RaycastParams.new()
	local exclude = { carsFolder }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclude, player.Character)
		end
	end
	params.ExcludeInstances = exclude
	params.RespectCanCollide = true
	return workspace:Raycast(position + Vector3.new(0, 40, 0), Vector3.new(0, -120, 0), params)
end

local function watchCar(car: Model, tune)
	local seat = car:WaitForChild("DriverSeat") :: Seat
	local prompt = seat:WaitForChild("DrivePrompt") :: ProximityPrompt
	local physics = CarPhysics.new(car, tune, { Driver = false })
	parked[car] = physics

	prompt.Triggered:Connect(function(player)
		local humanoid = getHumanoid(player)
		if humanoid and seat.Occupant == nil and humanoid.SeatPart == nil then
			seat:Sit(humanoid)
		end
	end)

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant
		local driver = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
		if driver then
			-- The driver's computer runs the physics now (smooth, no lag on their screen).
			parked[car] = nil
			physics:Destroy()
			prompt.Enabled = false
			car:SetAttribute("DriverUserId", driver.UserId)
			setOwner(car, driver)
		else
			-- Empty again: the server keeps it parked on its wheels.
			car:SetAttribute("DriverUserId", nil)
			prompt.Enabled = true
			setOwner(car, nil)
			physics = CarPhysics.new(car, tune, { Driver = false })
			parked[car] = physics
		end
	end)

	car.Destroying:Connect(function()
		parked[car] = nil
	end)
end

local function spawnCar(player: Player, carName: string?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local now = os.clock()
	if lastSpawn[player] and now - lastSpawn[player] < SPAWN_COOLDOWN then
		return
	end
	lastSpawn[player] = now

	local old = playerCars[player]
	if old then
		local seat = old:FindFirstChild("DriverSeat") :: Seat?
		if seat and seat.Occupant and seat.Occupant.Parent ~= character then
			-- Someone else is driving your old car; leave it to them.
			playerCars[player] = nil
		else
			old:Destroy()
		end
	end

	local tune = CarConfig.Get(carName)
	local look = root.CFrame.LookVector * Vector3.new(1, 0, 1)
	look = if look.Magnitude > 0.1 then look.Unit else Vector3.new(0, 0, -1)
	local spot = root.Position + look * SPAWN_DISTANCE
	local hit = groundBelow(spot)
	local groundY = if hit then hit.Position.Y else root.Position.Y - 3

	local car = CarBuilder.Build(tune, CFrame.lookAt(spot, spot + look))
	-- Put it on the ground at its resting height.
	local rideHeight = CarPhysics.new(car, tune, { Driver = false }).RideHeight
	local position = Vector3.new(spot.X, groundY + rideHeight + 0.2, spot.Z)
	car:PivotTo(CFrame.lookAt(position, position + look))
	car:SetAttribute("OwnerUserId", player.UserId)
	car.Parent = carsFolder
	playerCars[player] = car
	setOwner(car, nil)
	watchCar(car, tune)
end

local function exitCar(player: Player)
	local humanoid = getHumanoid(player)
	local seat = humanoid and humanoid.SeatPart
	if not (seat and seat.Name == "DriverSeat") then
		return
	end
	local car = seat:FindFirstAncestorWhichIsA("Model")
	if not (car and CollectionService:HasTag(car, "Car")) then
		return
	end
	local weld = seat:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
	humanoid.Sit = false

	-- Step out on the left side, standing upright.
	local chassis = car.PrimaryPart
	local width = chassis.Size.X
	local out = chassis.CFrame * CFrame.new(-(width / 2 + 3), 2, 0)
	local flatLook = chassis.CFrame.LookVector * Vector3.new(1, 0, 1)
	flatLook = if flatLook.Magnitude > 0.1 then flatLook.Unit else Vector3.new(0, 0, -1)
	task.defer(function()
		local character = player.Character
		if character then
			character:PivotTo(CFrame.lookAt(out.Position, out.Position + flatLook))
		end
	end)
end

remote.OnServerEvent:Connect(function(player, action, arg)
	if action == "Spawn" then
		if type(arg) ~= "string" or CarConfig.Cars[arg] == nil then
			arg = CarConfig.Default
		end
		spawnCar(player, arg)
	elseif action == "Exit" then
		exitCar(player)
	end
end)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function()
		-- First spawn: give them a car to test with.
		if playerCars[player] == nil or playerCars[player].Parent == nil then
			task.wait(1)
			spawnCar(player, CarConfig.Default)
		end
	end)
end)

Players.PlayerRemoving:Connect(function(player)
	local car = playerCars[player]
	if car then
		car:Destroy()
	end
	playerCars[player] = nil
	lastSpawn[player] = nil
end)

-- Empty cars: keep them on their suspension with the brakes on.
RunService.PreSimulation:Connect(function(dt)
	for car, physics in parked do
		if car.Parent == nil then
			parked[car] = nil
		else
			physics:Step(dt)
			local chassis = car.PrimaryPart
			if chassis and chassis.Position.Y < CarConfig.Base.Crash.FallHeight then
				car:Destroy()
			end
		end
	end
end)
