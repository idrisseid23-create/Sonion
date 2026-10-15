-- Runs the real server and client scripts against the API-checking mock.
-- Run from this folder: ./luaurun api_test.luau (needs api.luau from gen_api.py)
local HERE = "./"
local SRC = "../src"
local R = assert(__loadfile(HERE .. "robloxmock.luau"))()
local fakeClock = 0
local fakeOs = setmetatable({ clock = function() return fakeClock end }, { __index = os })
os = fakeOs

local function step(msg)
	print("== " .. msg)
end

-- ReplicatedStorage.CarSystem with the shared modules
local carSystem = R.new("Folder")
carSystem.Name = "CarSystem"
carSystem.Parent = R.ReplicatedStorage
for _, name in { "CarConfig", "CarMath", "CarPhysics", "CarInput", "CarCamera", "CarHud", "WheelVisuals" } do
	R.module(name, SRC .. "/shared/" .. name .. ".luau", carSystem)
end

-- ServerScriptService.CarSystem
local serverFolder = R.new("Folder")
serverFolder.Name = "CarSystem"
serverFolder.Parent = R.ServerScriptService
R.module("CarLooks", SRC .. "/server/CarLooks.luau", serverFolder)
R.module("CarBuilder", SRC .. "/server/CarBuilder.luau", serverFolder)

-- A player with a character
local player = R.new("Player")
R.set(player, "Name", "Tester")
R.set(player, "UserId", 1)
R.players = { player }
local character = R.new("Model")
character.Name = "Tester"
local hrp = R.new("Part")
hrp.Name = "HumanoidRootPart"
hrp.CFrame = CFrame.new(0, 3, 0)
hrp.Parent = character
local humanoid = R.new("Humanoid")
humanoid.Parent = character
character.Parent = R.workspace
R.set(player, "Character", character)
local playerGui = R.new("PlayerGui")
playerGui.Parent = player
local playerScripts = R.new("PlayerScripts")
playerScripts.Parent = player
local controlState = { enabled = true }
local playerModule = R.module("PlayerModule", HERE .. "fake_playermodule.luau", playerScripts)
local _ = playerModule
R.set(R.Players, "LocalPlayer", player)

step("server script starts")
R.isServer = true
R.runScript("Script", "CarServer", SRC .. "/server/CarServer.server.luau", serverFolder)
R.Players.PlayerAdded:Fire(player)
player.CharacterAdded:Fire(character)

local cars = R.workspace:FindFirstChild("Cars")
assert(cars, "Cars folder")
local car = cars:GetChildren()[1]
assert(car, "a car was spawned")
print("   spawned " .. car.Name .. " with " .. #car:GetDescendants() .. " parts/objects")
assert(car.PrimaryPart and car.PrimaryPart.Name == "Chassis")
assert(R.CollectionService:HasTag(car, "Car"))

step("server: parked physics frames")
for _ = 1, 5 do
	R.RunService.PreSimulation:Fire(1 / 60)
end

step("server: spawn each car type via remote")
local remote = carSystem:FindFirstChild("CarRemote")
for _, name in { "Mule", "Kite", "Bolt", "NotACar" } do
	fakeClock += 3 -- past the spawn cooldown
	remote.OnServerEvent:Fire(player, "Spawn", name)
	local spawned = cars:GetChildren()
	print("   cars in world: " .. #spawned .. ", newest " .. spawned[#spawned].Name)
end

step("client script starts")
R.isServer = false
R.runScript("LocalScript", "CarClient", SRC .. "/client/CarClient.client.luau", playerScripts)
assert(playerGui:FindFirstChild("CarHud"), "HUD created")

car = cars:GetChildren()[1]
local seat = car:FindFirstChild("DriverSeat")
step("prompt triggered -> sit -> start driving")
seat.DrivePrompt.Triggered:Fire(player)
assert(seat.Occupant == humanoid, "seated")
assert(R.casBindings.CarDriving, "driving keys bound")
assert(R.renderSteps.CarChaseCamera, "camera bound")

step("drive 3 seconds holding W, then D, with debug panel")
R.casBindings.CarDriving.fn("CarDriving", Enum.UserInputState.Begin, { KeyCode = Enum.KeyCode.T })
for i = 1, 180 do
	R.keysDown.W = true
	R.keysDown.D = i > 90
	R.RunService.PreSimulation:Fire(1 / 60)
	R.renderSteps.CarChaseCamera(1 / 60)
end
R.keysDown = {}

step("camera modes and reset")
for _, key in { Enum.KeyCode.C, Enum.KeyCode.C, Enum.KeyCode.C, Enum.KeyCode.R } do
	R.casBindings.CarDriving.fn("CarDriving", Enum.UserInputState.Begin, { KeyCode = key })
	R.RunService.PreSimulation:Fire(1 / 60)
	R.renderSteps.CarChaseCamera(1 / 60)
end

step("HUD events")
local hudGui = playerGui.CarHud
local _ = hudGui

step("exit via F")
R.casBindings.CarDriving.fn("CarDriving", Enum.UserInputState.Begin, { KeyCode = Enum.KeyCode.F })
R.RunService.PreSimulation:Fire(1 / 60)
-- the client fires the remote; deliver it to the server handler
remote.OnServerEvent:Fire(player, "Exit")
humanoid.Seated:Fire(false, nil)
assert(R.casBindings.CarDriving == nil, "keys unbound after exit")
assert(R.renderSteps.CarChaseCamera == nil, "camera unbound after exit")
assert(R.workspace.CurrentCamera.CameraType == Enum.CameraType.Custom, "camera restored")
R.RunService.PreSimulation:Fire(1 / 60)

local stubs = {}
for _, line in R.log do
	stubs[line] = (stubs[line] or 0) + 1
end
print("== calls handled by generic stubs (exist in API, not simulated):")
for line, count in stubs do
	print("   " .. line .. "  x" .. count)
end
print("API CHECK PASSED")
