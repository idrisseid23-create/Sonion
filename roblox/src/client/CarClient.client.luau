-- CarClient
-- Runs on each player's computer. When you sit in a car's DriverSeat it starts the
-- driving (physics, controls, camera, HUD). It also animates the wheels of every car.

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local CarSystem = ReplicatedStorage:WaitForChild("CarSystem")
local CarConfig = require(CarSystem:WaitForChild("CarConfig"))
local CarPhysics = require(CarSystem:WaitForChild("CarPhysics"))
local CarInput = require(CarSystem:WaitForChild("CarInput"))
local CarCamera = require(CarSystem:WaitForChild("CarCamera"))
local CarHud = require(CarSystem:WaitForChild("CarHud"))
local WheelVisuals = require(CarSystem:WaitForChild("WheelVisuals"))
local remote = CarSystem:WaitForChild("CarRemote")

local player = Players.LocalPlayer
local playerModule = require(player:WaitForChild("PlayerScripts"):WaitForChild("PlayerModule"))
local controls = playerModule:GetControls()

local hud = CarHud.new(player)
hud.OnSpawnRequest = function(carName)
	remote:FireServer("Spawn", carName)
end

------------------------------------------------------------------------------------------
-- Wheels on every car
------------------------------------------------------------------------------------------
local visuals = {}

local function addCar(car: Instance)
	if not car:IsA("Model") or visuals[car] then
		return
	end
	task.spawn(function()
		-- Wait for the parts to arrive (they stream in together).
		if not car:WaitForChild("Wheels", 10) or not car.PrimaryPart then
			return
		end
		visuals[car] = WheelVisuals.new(car, CarConfig.Get(car:GetAttribute("CarType")))
	end)
end

CollectionService:GetInstanceAddedSignal("Car"):Connect(addCar)
CollectionService:GetInstanceRemovedSignal("Car"):Connect(function(car)
	visuals[car] = nil
end)
for _, car in CollectionService:GetTagged("Car") do
	addCar(car)
end

------------------------------------------------------------------------------------------
-- Driving
------------------------------------------------------------------------------------------
local session = nil

local function characterList()
	local list = {}
	for _, other in Players:GetPlayers() do
		if other.Character then
			table.insert(list, other.Character)
		end
	end
	return list
end

local function stopDriving()
	if not session then
		return
	end
	local current = session
	session = nil
	current.Physics:Destroy()
	current.Input:Destroy()
	current.Camera:Destroy()
	hud:SetDriving(false)
	controls:Enable()
end

local function startDriving(car: Model)
	stopDriving()
	local tune = CarConfig.Get(car:GetAttribute("CarType"))
	local physics = CarPhysics.new(car, tune, { Driver = true })
	local input = CarInput.new(tune.Input)
	local camera = CarCamera.new(car, tune, physics)
	physics:SetIgnoreList(characterList())
	physics.OnEvent = function(name, data)
		hud:OnCarEvent(name, data)
		if name == "Respawned" then
			camera:Snap()
		end
	end

	controls:Disable() -- our own driving keys and phone buttons take over
	hud:SetDriving(true, input)
	session = {
		Car = car,
		Tune = tune,
		Physics = physics,
		Input = input,
		Camera = camera,
		LastCheckpoint = nil,
		CheckTimer = 0,
		IgnoreTimer = 0,
	}
end

-- Map pieces: parts tagged "CarCheckpoint" (front face pointing along the road) set your
-- respawn point; parts tagged "CarKillZone" (water, gaps) count as a crash.
local function checkZones(current)
	local position = current.Physics.Chassis.Position
	local function inside(part: BasePart): boolean
		local localPoint = part.CFrame:PointToObjectSpace(position)
		local half = part.Size / 2
		return math.abs(localPoint.X) <= half.X and math.abs(localPoint.Y) <= half.Y and math.abs(localPoint.Z) <= half.Z
	end
	for _, part in CollectionService:GetTagged("CarCheckpoint") do
		if part:IsA("BasePart") and part ~= current.LastCheckpoint and inside(part) then
			current.LastCheckpoint = part
			current.Physics:SetCheckpoint(part.CFrame)
			hud:OnCarEvent("Checkpoint")
		end
	end
	if current.Physics.State ~= "Crashed" then
		for _, part in CollectionService:GetTagged("CarKillZone") do
			if part:IsA("BasePart") and inside(part) then
				current.Physics:Crash("KillZone")
				break
			end
		end
	end
end

RunService.PreSimulation:Connect(function(dt)
	local current = session
	if current then
		if current.Car.Parent == nil or current.Physics.Chassis.Parent == nil then
			stopDriving()
		else
			local physics = current.Physics
			local input = current.Input
			local state = input:Update(dt, physics.State == "Airborne")
			if input:ConsumePressed("Reset") then
				physics:RequestRespawn()
			end
			if input:ConsumePressed("Camera") then
				current.Camera:NextMode()
			end
			if input:ConsumePressed("Exit") then
				remote:FireServer("Exit")
			end
			if input:ConsumePressed("Debug") then
				hud:ToggleDebug()
			end

			physics:Step(dt, state)
			hud:Update(physics)

			current.CheckTimer += dt
			if current.CheckTimer >= 0.1 then
				current.CheckTimer = 0
				checkZones(current)
			end
			current.IgnoreTimer += dt
			if current.IgnoreTimer >= 2 then
				current.IgnoreTimer = 0
				physics:SetIgnoreList(characterList())
			end
		end
	end

	local driving = session
	for car, wheelVisuals in visuals do
		if car.Parent == nil then
			visuals[car] = nil
		else
			wheelVisuals:Update(dt, if driving and driving.Car == car then driving.Physics else nil)
		end
	end
end)

------------------------------------------------------------------------------------------
-- Getting in and out
------------------------------------------------------------------------------------------
local function onCharacter(character: Model)
	stopDriving()
	local humanoid = character:WaitForChild("Humanoid") :: Humanoid
	humanoid.Seated:Connect(function(active, seatPart)
		if active and seatPart and seatPart.Name == "DriverSeat" then
			local car = seatPart:FindFirstAncestorWhichIsA("Model")
			if car and CollectionService:HasTag(car, "Car") then
				startDriving(car)
				return
			end
		end
		stopDriving()
	end)
	humanoid.Died:Connect(stopDriving)
end

player.CharacterAdded:Connect(onCharacter)
if player.Character then
	onCharacter(player.Character)
end
