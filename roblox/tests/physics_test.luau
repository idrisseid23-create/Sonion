-- Offline driving tests (see tests/README.md). Run from this folder: ./luaurun physics_test.luau
local SHARED = "../src/shared"
local here = "./"

local function loadWithScript(path, scriptObj)
	local fn, err = __loadfile(path)
	assert(fn, err)
	setfenv(fn, setmetatable({ script = scriptObj }, { __index = _G }))
	return fn()
end

local Mock = assert(__loadfile(here .. "mock.luau"))()

-- module tree: script.Parent.<Name>
local folder = {}
local cache = {}
local realRequire = require
function require(obj)
	if type(obj) == "table" and obj.__path then
		if cache[obj] == nil then
			cache[obj] = loadWithScript(obj.__path, obj)
		end
		return cache[obj]
	end
	return realRequire(obj)
end
for _, name in { "CarConfig", "CarMath", "CarPhysics" } do
	folder[name] = { __path = SHARED .. "/" .. name .. ".luau", Name = name, Parent = folder }
end

local CarConfig = require(folder.CarConfig)
local CarPhysics = require(folder.CarPhysics)
local M = CarConfig.M
local DEG = CarConfig.DEG

local failures = 0
local function check(cond, msg)
	if cond then
		print("  PASS  " .. msg)
	else
		print("  FAIL  " .. msg)
		failures += 1
	end
end

local function newCar(carName, startCF, driver)
	local tune = CarConfig.Get(carName or "Bolt")
	local car = Mock.makeCar(tune, startCF or CFrame.new(0, 3, 0))
	local phys = CarPhysics.new(car.model, tune, { Driver = driver ~= false })
	car.phys = phys
	car.tune = tune
	car.events = {}
	phys.OnEvent = function(name, data)
		table.insert(car.events, { name = name, data = data, t = phys.Clock })
	end
	-- place at ride height
	local cf = startCF or CFrame.new(0, 0, 0)
	local h = Mock.height(cf.X, cf.Z)
	local e = 0.05
	local n = Vector3.new(-(Mock.height(cf.X + e, cf.Z) - Mock.height(cf.X - e, cf.Z)) / (2 * e), 1,
		-(Mock.height(cf.X, cf.Z + e) - Mock.height(cf.X, cf.Z - e)) / (2 * e)).Unit
	local look = cf.LookVector
	look = (look - n * look:Dot(n)).Unit
	local pos = Vector3.new(cf.X, h, cf.Z) + n * phys.RideHeight
	car.chassis.CFrame = CFrame.lookAt(pos, pos + look, n)
	return car
end

local function input(t)
	return {
		Throttle = t.Throttle or 0,
		Brake = t.Brake or 0,
		Steer = t.Steer or 0,
		Handbrake = t.Handbrake or false,
		Boost = t.Boost or false,
	}
end

local function run(car, seconds, inp, dt, each)
	dt = dt or 1 / 60
	local n = math.floor(seconds / dt + 0.5)
	for i = 1, n do
		local useInput = if type(inp) == "function" then inp(i * dt) else inp
		car.phys:Step(dt, useInput)
		car.simulate(dt)
		if each then
			each(i * dt)
		end
	end
end

local function heading(car)
	local look = car.chassis.CFrame.LookVector
	return math.atan2(-look.X, -look.Z) -- 0 = facing -Z, + = turned left
end

local function hasEvent(car, name)
	for _, e in car.events do
		if e.name == name then
			return e
		end
	end
	return nil
end

local function flatWorld()
	Mock.height = function()
		return 0
	end
end

----------------------------------------------------------------------------------------
print("1. Resting on flat ground")
flatWorld()
do
	local car = newCar()
	local ys = {}
	run(car, 3, input({}), 1 / 60, function(t)
		if t > 2 then
			table.insert(ys, car.chassis.Position.Y)
		end
	end)
	local minY, maxY = math.huge, -math.huge
	for _, y in ys do
		minY = math.min(minY, y)
		maxY = math.max(maxY, y)
	end
	local p = car.chassis.Position
	p = p - Vector3.new(0, 0, 0)
	print(string.format("     ride height %.3f (expected %.3f), jitter %.5f, drift %.4f, contacts %d",
		p.Y, car.phys.RideHeight, maxY - minY, math.sqrt(p.X * p.X + p.Z * p.Z), car.body.contacts))
	check(math.abs(p.Y - car.phys.RideHeight) < 0.25, "settles near ride height")
	check(maxY - minY < 0.01, "no bouncing after 2 s")
	check(math.sqrt(p.X * p.X + p.Z * p.Z) < 0.05, "does not creep")
	check(car.body.contacts == 0, "body never touches the ground")
	check(car.phys.State == "Grounded", "state Grounded")
end

print("2. Acceleration to top speed")
do
	local car = newCar()
	local top = car.tune.Engine.TopSpeed
	local t97
	run(car, 8, input({ Throttle = 1 }), 1 / 60, function(t)
		if not t97 and car.phys.ForwardSpeed >= top * 0.97 then
			t97 = t
		end
	end)
	print(string.format("     97%% of top speed at %.2f s, final %.1f / %.1f studs/s", t97 or -1, car.phys.ForwardSpeed, top))
	check(t97 and math.abs(t97 - 3.5) < 0.6, "0 to top speed in about 3.5 s")
	check(car.phys.ForwardSpeed <= top * 1.01, "does not pass top speed")
	local lateral = car.chassis.Position.X
	check(math.abs(lateral) < 0.5, string.format("drives straight (sideways drift %.3f)", lateral))
	check(car.body.contacts == 0, "body never scrapes")

	print("3. Braking from top speed")
	local tStop
	run(car, 4, input({ Brake = 1 }), 1 / 60, function(t)
		if not tStop and car.phys.ForwardSpeed < 1 then
			tStop = t
		end
	end)
	print(string.format("     stopped in %.2f s", tStop or -1))
	check(tStop and math.abs(tStop - 1.5) < 0.4, "brakes from top speed in about 1.5 s")

	print("4. Reverse (keep holding brake)")
	print(string.format("     reverse speed %.1f (max %.1f)", car.phys.ForwardSpeed, -car.tune.Reverse.TopSpeed))
	check(car.phys.ForwardSpeed < -car.tune.Reverse.TopSpeed * 0.8, "reverses after stopping")
	check(car.phys.ForwardSpeed > -car.tune.Reverse.TopSpeed * 1.02, "reverse top speed respected")
	run(car, 1.5, input({ Throttle = 1 }))
	check(car.phys.ForwardSpeed > 0 and car.phys.DriveDirection == 1, "gas brakes then drives forward again")
end

print("5. Steering direction and turning")
do
	local car = newCar()
	run(car, 1.0, input({ Throttle = 1 }))
	local h0 = heading(car)
	run(car, 1.0, input({ Throttle = 0.6, Steer = 1 }))
	local turned = heading(car) - h0
	local look = car.chassis.CFrame.LookVector
	print(string.format("     heading change %.1f deg (negative = right), look %s", turned / DEG, tostring(look)))
	check(turned < -20 * DEG, "steer right turns right")
	local car2 = newCar()
	run(car2, 1.0, input({ Throttle = 1 }))
	h0 = heading(car2)
	run(car2, 1.0, input({ Throttle = 0.6, Steer = -1 }))
	check(heading(car2) - h0 > 20 * DEG, "steer left turns left")
	check(car.chassis.CFrame.UpVector.Y > 0.9, "stays upright in a hard turn")

	-- body roll direction: turning right should lean the body left (outward)
	local car3 = newCar()
	run(car3, 1.5, input({ Throttle = 1 }))
	run(car3, 0.6, input({ Throttle = 1, Steer = 1 }))
	local rightY = car3.chassis.CFrame.RightVector.Y
	print(string.format("     lean (right vector Y) %.3f", rightY))
	check(rightY > -0.02, "leans outward (or stays flat) in a right turn")
end

print("6. Top speed cornering stays stable")
do
	local car = newCar()
	run(car, 5, input({ Throttle = 1 }))
	local minUp = 1
	run(car, 3, input({ Throttle = 1, Steer = 1 }), 1 / 60, function()
		minUp = math.min(minUp, car.chassis.CFrame.UpVector.Y)
	end)
	print(string.format("     min up %.3f, speed %.1f, state %s", minUp, car.phys.Speed, car.phys.State))
	check(minUp > 0.85, "full lock at top speed does not roll over")
end

print("7. Handbrake drift")
do
	local car = newCar()
	run(car, 4, input({ Throttle = 1 }))
	local maxSlide = 0
	run(car, 0.5, input({ Throttle = 1, Steer = -1, Handbrake = true }), 1 / 60, function()
		maxSlide = math.max(maxSlide, math.abs(car.phys.SlideAngle))
	end)
	check(car.phys.State == "Drifting", "handbrake at speed starts a drift (state " .. car.phys.State .. ")")
	-- hold the drift with gas and steering into the turn
	local driftTime, h0 = 0, heading(car)
	local total = 0
	local last = heading(car)
	local spunOut = false
	run(car, 6, input({ Throttle = 1, Steer = -0.6 }), 1 / 60, function()
		if car.phys.State == "Drifting" then
			driftTime += 1 / 60
		end
		maxSlide = math.max(maxSlide, math.abs(car.phys.SlideAngle))
		local hNow = heading(car)
		local d = (hNow - last + math.pi) % (2 * math.pi) - math.pi
		total += d
		last = hNow
		if math.abs(car.phys.SlideAngle) > 100 * DEG then
			spunOut = true
		end
	end)
	local _ = h0
	print(string.format("     drifting for %.2f s, max slide %.1f deg, turned %.0f deg, speed %.1f, boost %.1f",
		driftTime, maxSlide / DEG, total / DEG, car.phys.Speed, car.phys.Boost))
	check(maxSlide > 15 * DEG, "back end swings out past 15 deg")
	check(not spunOut, "does not spin out")
	check(driftTime > 3, "drift can be held for several seconds")
	check(math.abs(total) > 360 * DEG, "a full circle can be drifted")
	check(car.chassis.CFrame.UpVector.Y > 0.85, "stays upright while drifting")
	-- let go: drift should end
	run(car, 2.5, input({ Throttle = 0.5 }))
	check(car.phys.State == "Grounded", "drift ends when you straighten up (state " .. car.phys.State .. ")")
end

print("8. Ramp jump, air control and landing")
do
	-- kicker ramp: rises 6 studs over 24 studs, then drops
	Mock.height = function(_x, z)
		if z < -120 and z > -144 then
			return (-120 - z) / 24 * 6
		end
		return 0
	end
	local car = newCar()
	local airborneAt, maxAir = nil, 0
	run(car, 4, input({ Throttle = 1 }), 1 / 60, function(t)
		if car.phys.State == "Airborne" and not airborneAt then
			airborneAt = t
		end
	end)
	local e = hasEvent(car, "Airborne")
	check(e ~= nil, "goes airborne off the ramp")
	local landed = hasEvent(car, "Landed")
	if landed then
		maxAir = landed.data.AirTime
		print(string.format("     air time %.2f s, landing angle %.1f deg", landed.data.AirTime, landed.data.Angle / DEG))
	end
	check(landed ~= nil and landed.data.Angle < 25 * DEG, "lands cleanly with no input")
	check(car.phys.State ~= "Crashed", "no crash on a straight jump")
	check(car.body.contacts == 0, "body not scraping after landing")
	local _ = maxAir
end

print("9. Air control rates")
do
	flatWorld()
	local car = newCar(nil, CFrame.new(0, 0, 0))
	car.chassis.CFrame = CFrame.new(0, 200, 0)
	car.chassis.AssemblyLinearVelocity = Vector3.new(0, 80, -60)
	run(car, 0.3, input({}))
	check(car.phys.State == "Airborne", "high in the air = Airborne")
	run(car, 0.5, input({ Throttle = 1 }))
	local spin = car.chassis.CFrame:VectorToObjectSpace(car.chassis.AssemblyAngularVelocity)
	print(string.format("     pitch rate %.0f deg/s (want -180)", spin.X / DEG))
	check(math.abs(spin.X / DEG + 180) < 15, "W pitches nose down at 180 deg/s")
	run(car, 0.5, input({ Steer = 1 }))
	spin = car.chassis.CFrame:VectorToObjectSpace(car.chassis.AssemblyAngularVelocity)
	print(string.format("     yaw rate %.0f deg/s (want -120)", spin.Y / DEG))
	check(math.abs(spin.Y / DEG + 120) < 15, "D spins right at 120 deg/s")
	run(car, 0.5, input({ Steer = 1, Handbrake = true }))
	spin = car.chassis.CFrame:VectorToObjectSpace(car.chassis.AssemblyAngularVelocity)
	print(string.format("     roll rate %.0f deg/s (want -180)", spin.Z / DEG))
	check(math.abs(spin.Z / DEG + 180) < 15, "Space + D rolls right at 180 deg/s")
	local rv = car.chassis.CFrame.RightVector
	local _ = rv
end

print("10. Backflip: counted, landed, boost awarded")
do
	flatWorld()
	local car = newCar()
	run(car, 3, input({ Throttle = 1 }))
	-- launch: 2.4 s of air (like a 40 degree kicker at speed)
	local p = car.chassis.Position
	car.chassis.CFrame = CFrame.new(p.X, p.Y + 1.5, p.Z) * car.chassis.CFrame.Rotation
	car.chassis.AssemblyLinearVelocity = Vector3.new(0, 72, -80)
	local boostBefore
	run(car, 4, function()
		if car.phys.State == "Airborne" then
			boostBefore = boostBefore or car.phys.Boost
			if car.phys.FlipPitch < 2 * math.pi - 0.5 then
				return input({ Brake = 1 })
			end
			return input({})
		end
		return input({})
	end)
	local flip = hasEvent(car, "Flip")
	local landed = hasEvent(car, "Landed")
	local crashed = hasEvent(car, "Crashed")
	if landed then
		print(string.format("     air %.2f s, flips %d, landing angle %.1f deg", landed.data.AirTime, landed.data.Flips, landed.data.Angle / DEG))
	end
	for _, e in car.events do print("       event", string.format("%.2f", e.t), e.name, typeof(e.data) == "table" and "" or tostring(e.data)) end
	check(flip ~= nil and flip.data == 1, "one backflip counted")
	check(crashed == nil, "backflip landed without crashing")
	check(hasEvent(car, "CleanLanding") ~= nil, "auto-level helps make it a clean landing")
	check(car.phys.Boost >= math.min(100, (boostBefore or 0) + 25 + 10), "flip and clean landing add boost")

	-- big jump with no input lands cleanly (the 9 out of 10 rule, best case)
	local car2 = newCar()
	run(car2, 3, input({ Throttle = 1 }))
	p = car2.chassis.Position
	car2.chassis.CFrame = CFrame.new(p.X, p.Y + 1.5, p.Z) * CFrame.Angles(math.rad(20), 0, 0)
	car2.chassis.AssemblyLinearVelocity = Vector3.new(0, 50, -90)
	car2.chassis.AssemblyAngularVelocity = Vector3.new(-0.6, 0, 0.3)
	run(car2, 3, input({ Throttle = 1 }))
	local l2 = hasEvent(car2, "Landed")
	if l2 then
		print(string.format("     no-input jump: air %.2f s, landing angle %.1f deg", l2.data.AirTime, l2.data.Angle / DEG))
	end
	check(l2 ~= nil and l2.data.Angle < 25 * DEG, "tumbling take-off with W held still lands cleanly")
end

print("11. Upside down = crash, then respawn upright")
do
	flatWorld()
	local car = newCar()
	run(car, 2, input({ Throttle = 1 }))
	run(car, 1, input({}))
	-- flip it over
	local p = car.chassis.Position
	car.chassis.CFrame = CFrame.new(p.X, p.Y + 3, p.Z) * CFrame.Angles(0, 0, math.pi)
	car.chassis.AssemblyLinearVelocity = Vector3.zero
	local crashT, respawnT
	run(car, 4, input({}), 1 / 60, function(t)
		if not crashT and car.phys.State == "Crashed" then
			crashT = t
		end
		if crashT and not respawnT and hasEvent(car, "Respawned") then
			respawnT = t
		end
	end)
	print(string.format("     crash at %.2f s, respawn at %.2f s", crashT or -1, respawnT or -1))
	check(crashT ~= nil, "crash detected")
	check(respawnT and respawnT - crashT < 1.2, "respawned about 1 s after the crash")
	check(car.chassis.CFrame.UpVector.Y > 0.95, "respawned upright")
	check(car.phys.State == "Grounded", "driving again after respawn")
end

print("12. Parks on a 15 degree hill without creeping")
do
	local slope = math.tan(15 * DEG)
	Mock.height = function(_x, z)
		return -z * slope
	end
	local car = newCar(nil, CFrame.new(0, 0, 0) * CFrame.Angles(0, math.rad(90), 0))
	run(car, 2, input({}))
	local p0 = car.chassis.Position
	run(car, 3, input({}))
	local p1 = car.chassis.Position
	print(string.format("     moved %.4f studs in 3 s (sideways on slope)", (p1 - p0).Magnitude))
	check((p1 - p0).Magnitude < 0.05, "sideways on a hill: no creep")
	local car2 = newCar(nil, CFrame.new(0, 0, 0))
	run(car2, 2, input({}))
	p0 = car2.chassis.Position
	run(car2, 3, input({}))
	p1 = car2.chassis.Position
	print(string.format("     moved %.4f studs in 3 s (facing uphill)", (p1 - p0).Magnitude))
	check((p1 - p0).Magnitude < 0.05, "facing up a hill: no creep")
	local car3 = newCar(nil, CFrame.new(0, 0, 0), false)
	run(car3, 2, nil)
	p0 = car3.chassis.Position
	run(car3, 3, nil)
	p1 = car3.chassis.Position
	check((p1 - p0).Magnitude < 0.05, "parked (no driver) car holds on a hill")
	flatWorld()
end

print("13. Frame rate independence")
do
	local results = {}
	for _, fps in { 30, 60, 144 } do
		local car = newCar()
		local t97
		run(car, 6, input({ Throttle = 1 }), 1 / fps, function(t)
			if not t97 and car.phys.ForwardSpeed >= car.tune.Engine.TopSpeed * 0.97 then
				t97 = t
			end
		end)
		local h0 = heading(car)
		run(car, 1, input({ Throttle = 1, Steer = 1 }), 1 / fps)
		local turn = heading(car) - h0
		-- rest jitter
		local car2 = newCar()
		local ys = {}
		run(car2, 3, input({}), 1 / fps, function(t)
			if t > 2 then
				table.insert(ys, car2.chassis.Position.Y)
			end
		end)
		local mn, mx = math.huge, -math.huge
		for _, y in ys do
			mn = math.min(mn, y)
			mx = math.max(mx, y)
		end
		results[fps] = { t97 = t97 or -1, turn = turn, jitter = mx - mn }
		print(string.format("     %3d fps: top speed at %.2f s, 1 s turn %.1f deg, rest jitter %.5f", fps, t97 or -1, turn / DEG, mx - mn))
	end
	check(math.abs(results[30].t97 - results[144].t97) < 0.3, "acceleration same at 30 and 144 fps")
	check(math.abs(results[30].turn - results[144].turn) < 6 * DEG, "turning same at 30 and 144 fps")
	check(results[30].jitter < 0.02 and results[144].jitter < 0.02, "no jitter at rest at 30 or 144 fps")
end

print("14. Boost")
do
	local car = newCar()
	run(car, 5, input({ Throttle = 1 }))
	local before = car.phys.ForwardSpeed
	local boost0 = car.phys.Boost
	run(car, 1.2, input({ Throttle = 1, Boost = true }))
	print(string.format("     %.1f -> %.1f studs/s, meter %.0f -> %.0f", before, car.phys.ForwardSpeed, boost0, car.phys.Boost))
	check(car.phys.ForwardSpeed > before + 8, "boost pushes past normal top speed")
	check(math.abs((boost0 - car.phys.Boost) - 35 * 1.2) < 2, "boost uses 35 per second")
	run(car, 5, input({ Throttle = 1 }))
	check(car.phys.ForwardSpeed < car.tune.Engine.TopSpeed * 1.05, "drops back to top speed after boost")
end

print("15. All three cars settle and drive")
for _, name in { "Bolt", "Mule", "Kite" } do
	flatWorld()
	local car = newCar(name)
	run(car, 2, input({}))
	local y = car.chassis.Position.Y
	run(car, 4, input({ Throttle = 1 }))
	local up = car.chassis.CFrame.UpVector.Y
	print(string.format("     %s: ride %.2f (expect %.2f), speed %.1f / %.1f, up %.3f", name, y, car.phys.RideHeight, car.phys.ForwardSpeed, car.tune.Engine.TopSpeed, up))
	check(math.abs(y - car.phys.RideHeight) < 0.3 and up > 0.98 and car.phys.ForwardSpeed > car.tune.Engine.TopSpeed * 0.9, name .. " settles and reaches top speed")
end

print("16. Tight drift around a cone at moderate speed")
do
	flatWorld()
	for _, fps in { 60, 30 } do
		local car = newCar()
		run(car, 1.0, input({ Throttle = 1 }), 1 / fps) -- about 17 m/s
		local startSpeed = car.phys.Speed
		run(car, 0.35, input({ Throttle = 1, Steer = -1, Handbrake = true }), 1 / fps)
		local total, last = 0, heading(car)
		local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
		local driftT, spun = 0, false
		run(car, 8, input({ Throttle = 1, Steer = -1 }), 1 / fps, function()
			local h = heading(car)
			total += (h - last + math.pi) % (2 * math.pi) - math.pi
			last = h
			local p = car.chassis.Position
			minX, maxX, minZ, maxZ = math.min(minX, p.X), math.max(maxX, p.X), math.min(minZ, p.Z), math.max(maxZ, p.Z)
			if car.phys.State == "Drifting" then driftT += 1 / fps end
			if math.abs(car.phys.SlideAngle) > math.rad(100) then spun = true end
		end)
		local diameter = math.max(maxX - minX, maxZ - minZ)
		print(string.format("     %d fps: start %.0f studs/s, drifting %.1f s, turned %.0f deg, circle about %.0f studs (%.1f m) wide, end speed %.0f", fps, startSpeed, driftT, total / DEG, diameter, diameter * 0.28, car.phys.Speed))
		check(driftT > 4 and math.abs(total) > 360 * DEG and not spun, fps .. " fps: holds a drift all the way round")
		check(diameter * 0.28 < 40, fps .. " fps: drift circle is tight enough to go round a cone (< 40 m)")
	end
end

print("17. Ice is slippery, dirt a bit less grippy")
do
	flatWorld()
	local results = {}
	for _, mat in { "Plastic", "Grass", "Ice" } do
		Mock.material = { Name = mat }
		local car = newCar()
		run(car, 2, input({ Throttle = 1 }))
		local h0 = heading(car)
		run(car, 1.5, input({ Throttle = 1, Steer = 1 }))
		results[mat] = math.abs(heading(car) - h0)
		print(string.format("     %s: turned %.1f deg in 1.5 s", mat, results[mat] / DEG))
	end
	Mock.material = { Name = "Plastic" }
	check(results.Ice < results.Plastic * 0.85, "ice turns noticeably less than road")
	check(results.Grass < results.Plastic, "dirt turns a little less than road")
end

print("18. Slalom at 20 m/s: no spin, no roll, no surprise drifts")
do
	flatWorld()
	local car = newCar()
	run(car, 2.2, input({ Throttle = 1 }))
	local minUp, drifted, spun = 1, false, false
	run(car, 6, function(t)
		local s = if math.floor(t / 0.8) % 2 == 0 then 0.7 else -0.7
		return input({ Throttle = 0.6, Steer = s })
	end, 1 / 60, function()
		minUp = math.min(minUp, car.chassis.CFrame.UpVector.Y)
		if car.phys.State == "Drifting" then drifted = true end
		if math.abs(car.phys.SlideAngle) > math.rad(60) then spun = true end
	end)
	print(string.format("     min up %.3f, drifted %s, speed %.0f", minUp, tostring(drifted), car.phys.Speed))
	check(minUp > 0.9 and not spun, "slalom stays upright and in control")
	check(not drifted, "normal steering doesn't start a drift by itself")
end

print("19. Curbs: drives over a 1 stud step without launching")
do
	Mock.height = function(_x, z)
		if z < -150 then
			return 1
		end
		return 0
	end
	local car = newCar()
	local maxVy, airborne = 0, false
	run(car, 4, input({ Throttle = 1 }), 1 / 60, function()
		maxVy = math.max(maxVy, car.chassis.AssemblyLinearVelocity.Y)
		if car.phys.State == "Airborne" then airborne = true end
	end)
	print(string.format("     max upward speed %.1f studs/s, airborne %s, final y %.2f", maxVy, tostring(airborne), car.chassis.Position.Y))
	check(not airborne, "curb doesn't throw the car into the air")
	check(math.abs(car.chassis.Position.Y - (1 + car.phys.RideHeight)) < 0.3, "ends up riding on the higher level")
	flatWorld()
end

print("20. Nose-high landing (40 deg) is rough but not a crash; 70 deg is a crash")
do
	flatWorld()
	for _, deg in { 40, 70 } do
		local car = newCar()
		run(car, 1, input({}))
		local p = car.chassis.Position
		car.chassis.CFrame = CFrame.new(p.X, 12, p.Z) * CFrame.Angles(math.rad(deg), 0, 0)
		car.chassis.AssemblyLinearVelocity = Vector3.new(0, -5, -40)
		car.phys.State = "Airborne"
		run(car, 2, input({}))
		local crashed = hasEvent(car, "Crashed")
		local rough = hasEvent(car, "Landed")
		print(string.format("     %d deg: landed angle %s, crashed %s", deg, rough and string.format("%.0f", rough.data.Angle / DEG) or "-", tostring(crashed and crashed.data)))
		if deg == 40 then
			check(crashed == nil, "40 degree landing is not a crash")
		else
			check(crashed ~= nil, "70 degree landing is a crash")
		end
	end
end

print("21. Parked car stops after the driver jumps out at speed")
do
	flatWorld()
	local car = newCar()
	run(car, 3, input({ Throttle = 1 }))
	local parkedPhys = CarPhysics.new(car.model, car.tune, { Driver = false })
	car.phys = parkedPhys
	run(car, 4, nil)
	print(string.format("     speed after 4 s: %.2f", car.chassis.AssemblyLinearVelocity.Magnitude))
	check(car.chassis.AssemblyLinearVelocity.Magnitude < 0.2, "empty car brakes to a stop")
	check(car.chassis.CFrame.UpVector.Y > 0.99, "and stays level")
end

print("22. Mule and Kite: drift, jump, flip upright")
for _, name in { "Mule", "Kite" } do
	flatWorld()
	local car = newCar(name)
	run(car, 1.2, input({ Throttle = 1 }))
	run(car, 0.35, input({ Throttle = 1, Steer = -1, Handbrake = true }))
	local total, last, spun, minUp = 0, heading(car), false, 1
	run(car, 8, input({ Throttle = 1, Steer = -1 }), 1 / 60, function()
		local h = heading(car)
		total += (h - last + math.pi) % (2 * math.pi) - math.pi
		last = h
		if math.abs(car.phys.SlideAngle) > math.rad(100) then spun = true end
		minUp = math.min(minUp, car.chassis.CFrame.UpVector.Y)
	end)
	print(string.format("     %s drift: turned %.0f deg, spun %s, min up %.2f", name, total / DEG, tostring(spun), minUp))
	check(math.abs(total) > 360 * DEG and not spun and minUp > 0.85, name .. " drifts a full circle")

	Mock.height = function(_x, z)
		if z < -120 and z > -144 then
			return (-120 - z) / 24 * 6
		end
		return 0
	end
	local car2 = newCar(name)
	run(car2, 5, input({ Throttle = 1 }))
	local landed = hasEvent(car2, "Landed")
	print(string.format("     %s jump: %s", name, landed and string.format("air %.2f s, angle %.1f deg", landed.data.AirTime, landed.data.Angle / DEG) or "no landing"))
	check(landed ~= nil and landed.data.Angle < 25 * DEG and hasEvent(car2, "Crashed") == nil, name .. " lands the medium ramp cleanly")
end
flatWorld()

print("23. Getting in: the car had sunk onto its belly before the driver's computer took over")
-- In Studio the server stops holding the car up a moment before the driver's computer
-- gets control, so the car can drop onto its body. Taking over must not launch it.
for _, case in {
	{ name = "resting on its belly", drop = 0, speed = 0 },
	{ name = "still sinking at 15 studs/s", drop = 0, speed = -15 },
	{ name = "dropped from 8 studs", drop = 8, speed = 0 },
} do
	flatWorld()
	local car = newCar()
	local belly = car.tune.Body.Size.Y / 2 + 0.05
	local pos = Vector3.new(0, belly + case.drop, 0)
	car.chassis.CFrame = CFrame.lookAt(pos, pos + Vector3.new(0, 0, -1))
	car.chassis.AssemblyLinearVelocity = Vector3.new(0, case.speed, 0)
	-- Measure from the moment a wheel touches (straight away unless it was dropped).
	local touchedAt = nil
	local maxY, maxUp = -math.huge, 0
	run(car, 4, input({}), 1 / 60, function(t)
		if not touchedAt and car.phys.GroundedWheels > 0 then
			touchedAt = car.phys.Clock
		end
		if touchedAt then
			maxY = math.max(maxY, car.chassis.Position.Y)
			maxUp = math.max(maxUp, car.chassis.AssemblyLinearVelocity.Y)
		end
	end)
	local leftGround = false
	for _, e in car.events do
		if e.name == "Airborne" and touchedAt and e.t > touchedAt then
			leftGround = true
		end
	end
	local finalY = car.chassis.Position.Y
	local overshoot = maxY - car.phys.RideHeight
	print(string.format("     %s: after touching, highest %.2f above ride height, fastest rise %.1f studs/s, ends at %.3f (ride %.3f)",
		case.name, overshoot, maxUp, finalY, car.phys.RideHeight))
	check(overshoot < 0.6, case.name .. ": not thrown up")
	check(not leftGround, case.name .. ": never leaves the ground again")
	check(math.abs(finalY - car.phys.RideHeight) < 0.1, case.name .. ": settles at ride height")
end

print("")
print(if failures == 0 then "ALL PASSED" else failures .. " FAILED")
