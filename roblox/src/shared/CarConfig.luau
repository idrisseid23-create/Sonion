-- CarConfig
-- Every tuning number for the driving lives here. The starting values come from the
-- "Driving blueprint" sheet. Change numbers here, press Play, drive, repeat.
--
-- Units: Roblox works in studs. 1 metre is about 3.57 studs (1 stud = 0.28 m), so
-- values are written as "metres * M" where that keeps them readable.

local M = 1 / 0.28 -- studs per metre
local DEG = math.pi / 180

local CarConfig = {}

CarConfig.M = M
CarConfig.DEG = DEG

-- The base car. Other cars only list what they change (see CarConfig.Cars below).
local Base = {
	Name = "Bolt",

	-- How strong gravity feels for the car only (studs/s^2). The world keeps its own gravity.
	-- Roblox's default world gravity (196.2) makes jumps very short. 60 gives about
	-- 1 s of air off a medium ramp and makes a backflip off a big ramp possible but hard.
	Gravity = 60,

	----------------------------------------------------------------------------------
	-- Shape of the placeholder car (CarBuilder uses these; the physics reads the
	-- wheel positions from the attachments the builder makes).
	----------------------------------------------------------------------------------
	Body = {
		Size = Vector3.new(1.9 * M, 0.62 * M, 4.0 * M), -- width, height, length of the main box
		CabinSize = Vector3.new(1.7 * M, 0.7 * M, 2.0 * M),
		CabinOffset = Vector3.new(0, 0, 0.25 * M), -- + is towards the back
		Color = Color3.fromRGB(255, 122, 26),
		CabinColor = Color3.fromRGB(143, 211, 234),
		RoofBox = true, -- the package box on the roof
	},

	Wheels = {
		Radius = 0.4 * M,
		Width = 0.3 * M,
		WheelBase = 2.5 * M, -- front axle to rear axle
		TrackWidth = 1.95 * M, -- left wheel centre to right wheel centre
		MountHeight = -0.1 * M, -- where the suspension top sits, relative to the body centre
	},

	-- Where the centre of mass sits relative to the body centre. Low and a little forward
	-- (negative Z is forward). The builder adds a hidden weight to get it there.
	CenterOfMass = Vector3.new(0, -0.15 * M, -0.15 * M),

	----------------------------------------------------------------------------------
	-- Engine, brakes, reverse
	----------------------------------------------------------------------------------
	Engine = {
		TopSpeed = 32 * M, -- about 115 km/h
		TimeToTopSpeed = 3.5, -- seconds from 0 to (nearly) top speed on flat ground
		CurvePower = 2, -- higher = pulls harder near top speed, lower = punchier launch
		FrontDriveShare = 0.3, -- 0 = rear-wheel drive, 1 = front-wheel drive
		CoastDecel = 6, -- slowing down when you let go of everything (studs/s^2)
		OverSpeedDrag = 0.8, -- how fast you drop back to top speed after a boost (per second)
	},

	Brakes = {
		TimeFromTopSpeed = 1.5, -- seconds to stop from top speed
		FrontShare = 0.6,
	},

	Reverse = {
		TopSpeed = 8 * M,
		Accel = 40,
		EngageSpeed = 1 * M, -- below this, holding brake starts reversing
	},

	----------------------------------------------------------------------------------
	-- Steering
	----------------------------------------------------------------------------------
	Steering = {
		MaxAngleSlow = 30 * DEG,
		MaxAngleFast = 10 * DEG, -- at top speed
		WheelTurnSpeed = 6, -- radians per second the front wheels can turn
	},

	----------------------------------------------------------------------------------
	-- Suspension (one spring and damper per wheel)
	----------------------------------------------------------------------------------
	Suspension = {
		Travel = 0.3 * M, -- how far each wheel can move up and down
		Frequency = 2.6, -- spring bounce speed in Hz. Higher = stiffer
		DampingRatio = 0.75, -- 1 = no bounce, lower = bouncier. 0.75 settles in about 0.3 s
		ReboundDamping = 2, -- shocks are this many times stiffer bouncing back up than squashing
		AntiRoll = 0.5, -- resists leaning in corners (fraction of spring strength)
		BumpStop = 8, -- extra stiffness when a wheel is nearly fully pushed in
		MaxRiseSpeed = 1.5 * M, -- springs never lift the car faster than this (stops it being thrown up)
		CastShape = "Sphere", -- "Sphere" rolls over edges smoothly, "Ray" is the simple version
	},

	----------------------------------------------------------------------------------
	-- Tyres: "every frame, cancel part of the sideways sliding"
	----------------------------------------------------------------------------------
	Tires = {
		Grip = 100, -- the most sideways push the tyres can give, in studs/s^2 (about 2.9 g)
		GripRate = 18, -- how quickly sideways sliding is cancelled (per second)
		FrontGrip = 1.0,
		RearGrip = 1.05, -- a little more at the back keeps the car stable
		ForceHeight = 0.55, -- 0 = push at the ground (leans a lot), 1 = at the centre of mass (no lean)
		MaxLoad = 2.0, -- a heavily pressed wheel grips at most this many times normal
		HoldSpeed = 1.5, -- below this with no input, the car parks itself (no creeping on hills)
	},

	-- Sideways grip on different ground. Set a part's "Grip" attribute (a number) to override.
	Surfaces = {
		Default = 1.0,
		Dirt = 0.8,
		Ice = 0.6,
		Materials = {
			Ice = "Ice",
			Glacier = "Ice",
			Snow = "Dirt",
			Grass = "Dirt",
			Ground = "Dirt",
			Sand = "Dirt",
			Mud = "Dirt",
			LeafyGrass = "Dirt",
			Pebble = "Dirt",
		},
	},

	----------------------------------------------------------------------------------
	-- Drifting
	----------------------------------------------------------------------------------
	Drift = {
		StartSpeed = 12 * M, -- handbrake above this starts a drift
		EnterAngle = 15 * DEG, -- sliding more than this starts a drift too
		ExitAngle = 8 * DEG, -- drift ends when the slide drops under this (and handbrake is up)
		MinSpeed = 5 * M, -- drift ends below this speed
		RearGrip = 0.45, -- back tyre grip while drifting at the target angle
		TargetAngle = 30 * DEG, -- the slide angle a drift settles at
		SteerAngleRange = 15 * DEG, -- steering into the turn adds this much, steering out takes it away
		AngleHold = 0.04, -- how hard the back tyres fight to keep that angle (grip per degree off)
		MinRearGrip = 0.2,
		MaxAngle = 55 * DEG, -- the slide is not allowed past this (no spin-outs while drifting)
		CountersteerAssist = 1.0, -- front wheels follow your slide (1 = fully), so drifts are easy to hold
		MaxWheelAngle = 45 * DEG,
		Kick = 0.8, -- extra turn (rad/s) when you pull the handbrake while steering
		Push = 14, -- holds your entry speed while drifting on the gas (studs/s^2)
		Throttle = 0.5, -- engine strength while drifting (lets go fully when the drift ends)
	},

	Handbrake = {
		RearGrip = 0.6, -- back tyre grip when the handbrake is pulled at low speed
		Decel = 20, -- how much the handbrake slows you (studs/s^2)
	},

	Downforce = {
		AtTopSpeed = 0.5, -- extra push down at top speed, as a fraction of the car's weight
	},

	----------------------------------------------------------------------------------
	-- Air, landings and crashes
	----------------------------------------------------------------------------------
	Air = {
		Delay = 0.15, -- all wheels off the ground this long = airborne
		PitchRate = 180 * DEG, -- W / S flip forward and back
		RollRate = 180 * DEG, -- Space + A / D
		YawRate = 120 * DEG, -- A / D
		Response = 10, -- how quickly the car reaches those spin speeds
		Damping = 0.3, -- slows spinning a little when you let go
		AutoLevel = 2, -- gently levels the car in the air when you're not pressing anything (0 = off)
	},

	Landing = {
		CleanAngle = 25 * DEG, -- land within this of level = clean landing
		CrashAngle = 60 * DEG, -- land worse than this = crash
		StraightenTime = 0.2, -- clean landings auto-straighten over this long
		AbsorbTime = 0.25, -- after any landing, stop the car bouncing back into the air for this long
		FlipTolerance = 30 * DEG, -- a flip counts if you got within this of a full turn
		MinAirTime = 0.5, -- shorter hops (road bumps) don't give landing bonuses
	},

	Crash = {
		UpsideDownTime = 1.0, -- stuck on the roof or side this long = crash
		Wait = 1.0, -- seconds before you respawn
		RespawnSpeed = 0.6, -- respawn at this fraction of your earlier speed
		FallHeight = -150, -- falling below this Y = crash
	},

	----------------------------------------------------------------------------------
	-- Boost meter (0 to 100)
	----------------------------------------------------------------------------------
	Boost = {
		Start = 50,
		Max = 100,
		Drifting = 10, -- per second
		Airtime = 8, -- per second
		Flip = 25,
		CleanLanding = 10,
		NearMiss = 5, -- for later (call AddBoost from a near-miss check)
		Use = 35, -- per second while boosting
		PushMultiplier = 1.4, -- about 40% more engine push
		TopSpeed = 45 * M,
	},

	----------------------------------------------------------------------------------
	-- Controls feel
	----------------------------------------------------------------------------------
	Input = {
		SteerRate = 5, -- keyboard steering reaches full lock in 0.2 s
		SteerReturnRate = 8, -- and comes back to straight a bit faster
		StickDeadzone = 0.15,
		TouchAutoGas = true, -- phones drive forward on their own; press BRAKE to slow down
	},

	----------------------------------------------------------------------------------
	-- Camera
	----------------------------------------------------------------------------------
	Camera = {
		Distance = 6 * M,
		Height = 2.2 * M,
		FocusHeight = 0.5 * M,
		LookAhead = 4 * M,
		Lag = 0.15, -- seconds
		FovSlow = 70,
		FovFast = 85,
		BoostFov = 5,
		DriftSwing = 0.3, -- swings to the outside of drifts so you see the corner
		SpeedPullBack = 1.2 * M, -- camera sits a bit further back at top speed
		OrbitReturnDelay = 1.2,
		Modes = {
			{ Name = "Chase", Distance = 6 * M, Height = 2.2 * M },
			{ Name = "Far", Distance = 9 * M, Height = 3.2 * M },
			{ Name = "Hood", Hood = true },
		},
	},
}

----------------------------------------------------------------------------------------
-- The three cars from the Cars sheet. Each one only lists what it changes from Base.
-- Bolt is the middle. Mule trades speed for safety. Kite trades safety for speed and air.
----------------------------------------------------------------------------------------
CarConfig.Cars = {
	Bolt = {},

	Mule = {
		Name = "Mule",
		Body = {
			Size = Vector3.new(2.1 * M, 0.8 * M, 4.6 * M),
			CabinSize = Vector3.new(2.0 * M, 1.2 * M, 2.9 * M),
			CabinOffset = Vector3.new(0, 0, 0.5 * M),
			Color = Color3.fromRGB(69, 196, 234),
			CabinColor = Color3.fromRGB(240, 236, 226),
			RoofBox = false,
		},
		Wheels = { Radius = 0.42 * M, WheelBase = 2.9 * M, TrackWidth = 2.1 * M },
		CenterOfMass = Vector3.new(0, -0.1 * M, -0.1 * M),
		Engine = { TopSpeed = 27 * M, TimeToTopSpeed = 4.3 },
		Brakes = { TimeFromTopSpeed = 1.7 },
		Steering = { MaxAngleSlow = 28 * DEG, MaxAngleFast = 9 * DEG },
		Suspension = { Travel = 0.35 * M, Frequency = 2.2, DampingRatio = 0.8 },
		Tires = { Grip = 90, GripRate = 16 },
		Air = { PitchRate = 120 * DEG, RollRate = 120 * DEG, YawRate = 90 * DEG },
		Boost = { TopSpeed = 38 * M },
	},

	Kite = {
		Name = "Kite",
		Body = {
			Size = Vector3.new(1.8 * M, 0.5 * M, 3.8 * M),
			CabinSize = Vector3.new(1.4 * M, 0.75 * M, 1.6 * M),
			CabinOffset = Vector3.new(0, 0, 0.2 * M),
			Color = Color3.fromRGB(255, 184, 31),
			CabinColor = Color3.fromRGB(60, 64, 74),
			RoofBox = false,
		},
		Wheels = { Radius = 0.45 * M, WheelBase = 2.4 * M, TrackWidth = 1.95 * M },
		Engine = { TopSpeed = 35 * M, TimeToTopSpeed = 3.2 },
		Suspension = { Travel = 0.4 * M, Frequency = 2.3, DampingRatio = 0.65 },
		Tires = { Grip = 95, GripRate = 17 },
		Drift = { RearGrip = 0.4, TargetAngle = 34 * DEG },
		Air = { PitchRate = 240 * DEG, RollRate = 240 * DEG, YawRate = 160 * DEG },
		Boost = { TopSpeed = 48 * M },
	},
}

CarConfig.Default = "Bolt"
CarConfig.Base = Base

local function deepMerge(base, changes)
	local out = {}
	for key, value in base do
		out[key] = value
	end
	for key, value in changes do
		-- Merge plain settings tables; replace everything else (numbers, Vector3s, lists).
		if typeof(value) == "table" and typeof(out[key]) == "table" and #value == 0 and next(value) ~= nil then
			out[key] = deepMerge(out[key], value)
		else
			out[key] = value
		end
	end
	return out
end

local cache = {}

-- Returns the full tuning table for a car name ("Bolt", "Mule" or "Kite").
-- Unknown names fall back to the default car.
function CarConfig.Get(carName: string?)
	local name = if carName and CarConfig.Cars[carName] then carName else CarConfig.Default
	if not cache[name] then
		cache[name] = deepMerge(Base, CarConfig.Cars[name])
	end
	return cache[name]
end

return CarConfig
