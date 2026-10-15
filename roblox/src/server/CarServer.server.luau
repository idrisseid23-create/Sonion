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
local ABANDONED_CAR_LIFETIME = 30 -- seconds an empty car nobody owns any more stays around
local HANDOVER_TIMEOUT = 2 -- seconds the server keeps holding a car for a driver who hasn't said "Ready"

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
-- Cars whose new driver's computer hasn't taken over yet: car -> { Player, deadline }.
-- The server keeps holding them still until then.
local handingOver: { [Model]: { Player: Player, Deadline: number } } = {}

local function getHumanoid(player: Player): Humanoid?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health > 0 then
		return humanoid
	end
	return nil
end

local function characterList(): { Instance }
	local list = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	return list
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
	local exclude = characterList()
	table.insert(exclude, carsFolder)
	params.ExcludeInstances = exclude
	params.RespectCanCollide = true
	return workspace:Raycast(position + Vector3.new(0, 40, 0), Vector3.new(0, -120, 0), params)
end

------------------------------------------------------------------------------------------
-- The driver's avatar while seated: weightless, and not colliding with car bodies (it sits
-- inside one). Weightless parts can never become the part Roblox keeps still when the seat
-- welds the avatar in (which would move the car to the avatar), and the avatar's weight
-- can't tip the car. It still stands on floors.
------------------------------------------------------------------------------------------
local isolated: { [Model]: { Saved: { [BasePart]: { any } }, Connection: RBXScriptConnection } } = {}

local function isolateDriver(character: Model)
	if isolated[character] then
		return
	end
	local saved = {}
	local function apply(item: Instance)
		if item:IsA("BasePart") and saved[item] == nil then
			-- (Still in the driver group from a moment ago? Its own group was the default.)
			local group = if item.CollisionGroup == CarBuilder.DriverGroup then "Default" else item.CollisionGroup
			saved[item] = { group, item.Massless }
			item.CollisionGroup = CarBuilder.DriverGroup
			item.Massless = true
		end
	end
	for _, item in character:GetDescendants() do
		apply(item)
	end
	isolated[character] = { Saved = saved, Connection = character.DescendantAdded:Connect(apply) }
end

-- Gives the avatar its weight back straight away, and its collisions with car bodies a
-- moment later (once it's clear of the car), unless it has got back into a car by then.
local function restoreDriver(character: Model)
	local entry = isolated[character]
	if not entry then
		return
	end
	isolated[character] = nil
	entry.Connection:Disconnect()
	for part, old in entry.Saved do
		if part.Parent then
			part.Massless = old[2]
		end
	end
	task.delay(0.5, function()
		if isolated[character] then
			return -- back in a car
		end
		for part, old in entry.Saved do
			if part.Parent then
				part.CollisionGroup = old[1]
			end
		end
	end)
end

-- Where the avatar should stand after getting out: beside the driver's door, upright, on
-- the ground (even if the car is on its side or upside down).
local function exitSpot(car: Model): CFrame
	local chassis = car.PrimaryPart
	local flatLook = chassis.CFrame.LookVector * Vector3.new(1, 0, 1)
	flatLook = if flatLook.Magnitude > 0.1 then flatLook.Unit else Vector3.new(0, 0, -1)
	local left = Vector3.new(flatLook.Z, 0, -flatLook.X)
	local out = chassis.Position + left * (chassis.Size.X / 2 + 3)
	local ground = groundBelow(out)
	local stand = if ground then Vector3.new(out.X, ground.Position.Y + 3, out.Z) else out + Vector3.new(0, 2, 0)
	return CFrame.lookAt(stand, stand + flatLook)
end

------------------------------------------------------------------------------------------
-- Cars
------------------------------------------------------------------------------------------
local function watchCar(car: Model, tune)
	local seat = car:WaitForChild("DriverSeat") :: Seat
	local prompt = seat:WaitForChild("DrivePrompt") :: ProximityPrompt
	local physics = CarPhysics.new(car, tune, { Driver = false })
	physics:SetIgnoreList(characterList())
	parked[car] = physics
	local driverCharacter: Model? = nil

	prompt.Triggered:Connect(function(player)
		local humanoid = getHumanoid(player)
		if not (humanoid and seat.Occupant == nil and humanoid.SeatPart == nil) then
			return
		end
		local character = humanoid.Parent :: Model
		-- Weightless first, so the car is what stays put when the seat pulls the avatar in.
		isolateDriver(character)
		seat:Sit(humanoid)
		task.delay(0.5, function()
			if seat.Occupant ~= humanoid and humanoid.SeatPart == nil then
				-- The seat refused (Roblox has a short re-sit cooldown): undo.
				restoreDriver(character)
			end
		end)
	end)

	local driverConnections: { RBXScriptConnection } = {}
	local function unwatchDriver()
		for _, connection in driverConnections do
			connection:Disconnect()
		end
		table.clear(driverConnections)
	end

	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		unwatchDriver()
		local occupant = seat.Occupant
		local driver = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
		if driver then
			local character = occupant.Parent :: Model
			driverCharacter = character
			isolateDriver(character) -- in case they got in some other way

			-- The driver's computer runs the physics from now on (smooth, no lag on their
			-- screen). The server keeps holding the car still until that computer says it has
			-- taken over (the "Ready" remote), so the car never sits there with no one driving
			-- its springs.
			handingOver[car] = { Player = driver, Deadline = os.clock() + HANDOVER_TIMEOUT }
			prompt.Enabled = false
			car:SetAttribute("DriverUserId", driver.UserId)
			setOwner(car, driver)

			-- If the driver dies, resets or leaves, free the seat so the car comes back.
			local function freeSeat()
				local weld = seat:FindFirstChild("SeatWeld")
				if weld then
					weld:Destroy()
				end
			end
			table.insert(driverConnections, occupant.Died:Connect(freeSeat))
			table.insert(driverConnections, character.AncestryChanged:Connect(function(_, parent)
				if parent == nil then
					freeSeat()
				end
			end))
		else
			-- Empty again: the server keeps it parked on its wheels.
			handingOver[car] = nil
			car:SetAttribute("DriverUserId", nil)
			prompt.Enabled = true
			setOwner(car, nil)
			physics = CarPhysics.new(car, tune, { Driver = false })
			physics:SetIgnoreList(characterList())
			parked[car] = physics

			-- Stand the last driver beside the car, still, and give their avatar back its
			-- weight (and, a moment later, its collisions with cars).
			local character = driverCharacter
			driverCharacter = nil
			if character and character.Parent then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				if humanoid and humanoid.Health > 0 then
					humanoid.Sit = false
					character:PivotTo(exitSpot(car))
					local root = character:FindFirstChild("HumanoidRootPart") :: BasePart?
					if root then
						root.AssemblyLinearVelocity = Vector3.zero
						root.AssemblyAngularVelocity = Vector3.zero
					end
				end
			end
			if character then
				restoreDriver(character)
			end

			-- A car its owner has given up on goes away if nobody gets back in.
			if car:GetAttribute("Abandoned") then
				task.delay(ABANDONED_CAR_LIFETIME, function()
					if car.Parent and seat.Occupant == nil then
						car:Destroy()
					end
				end)
			end
		end
	end)

	car.Destroying:Connect(function()
		parked[car] = nil
		handingOver[car] = nil
		unwatchDriver()
		if driverCharacter then
			restoreDriver(driverCharacter)
		end
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
			-- Someone else is driving your old car; leave it to them (it goes away once
			-- they get out and nobody gets back in).
			old:SetAttribute("Abandoned", true)
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
	-- Freeing the seat runs the "empty" branch above, which stands the avatar beside the car.
	local weld = seat:FindFirstChild("SeatWeld")
	if weld then
		weld:Destroy()
	end
	humanoid.Sit = false
end

remote.OnServerEvent:Connect(function(player, action, arg)
	if action == "Spawn" then
		if type(arg) ~= "string" or CarConfig.Cars[arg] == nil then
			arg = CarConfig.Default
		end
		spawnCar(player, arg)
	elseif action == "Exit" then
		exitCar(player)
	elseif action == "Ready" then
		-- The driver's computer is running this car now: stop holding it here.
		local car = arg
		local waiting = typeof(car) == "Instance" and handingOver[car]
		if waiting and waiting.Player == player then
			handingOver[car] = nil
			parked[car] = nil
		end
	end
end)

local function onPlayer(player: Player)
	local function onCharacter()
		-- First spawn: give them a car to test with.
		if playerCars[player] == nil or playerCars[player].Parent == nil then
			task.wait(1)
			spawnCar(player, CarConfig.Default)
		end
	end
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter)
	end
end

Players.PlayerAdded:Connect(onPlayer)
for _, player in Players:GetPlayers() do
	onPlayer(player)
end

Players.PlayerRemoving:Connect(function(player)
	local car = playerCars[player]
	if car then
		car:Destroy()
	end
	playerCars[player] = nil
	lastSpawn[player] = nil
end)

-- Empty cars: keep them on their suspension with the brakes on. Their wheels ignore
-- avatars (so standing under one doesn't hold the car up).
local ignoreTimer = 0
RunService.PreSimulation:Connect(function(dt)
	ignoreTimer += dt
	local refresh = ignoreTimer >= 1
	if refresh then
		ignoreTimer = 0
	end
	local characters = if refresh then characterList() else nil
	local now = os.clock()
	for car, waiting in handingOver do
		if now > waiting.Deadline then
			-- The driver's computer never said it was ready: hand over anyway.
			handingOver[car] = nil
			parked[car] = nil
		end
	end
	for car, physics in parked do
		if car.Parent == nil then
			parked[car] = nil
		else
			if characters then
				physics:SetIgnoreList(characters)
			end
			physics:Step(dt)
			local chassis = car.PrimaryPart
			if chassis and chassis.Position.Y < CarConfig.Base.Crash.FallHeight then
				car:Destroy()
			end
		end
	end
end)
