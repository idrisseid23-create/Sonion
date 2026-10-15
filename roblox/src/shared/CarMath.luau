-- CarMath
-- Small maths helpers used by the car scripts. Nothing here touches the game world.

local CarMath = {}

function CarMath.clamp(x: number, lo: number, hi: number): number
	if x < lo then
		return lo
	elseif x > hi then
		return hi
	end
	return x
end

function CarMath.lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

-- Fraction to move towards a target this frame so it takes "rate" per second,
-- independent of frame rate. Use as: value += (target - value) * CarMath.approach(rate, dt)
function CarMath.approach(rate: number, dt: number): number
	return 1 - math.exp(-rate * dt)
end

-- Moves current towards target by at most maxStep.
function CarMath.moveTowards(current: number, target: number, maxStep: number): number
	if current < target then
		return math.min(current + maxStep, target)
	end
	return math.max(current - maxStep, target)
end

-- Wraps an angle to -pi..pi.
function CarMath.wrapAngle(a: number): number
	a = (a + math.pi) % (2 * math.pi)
	if a < 0 then
		a += 2 * math.pi
	end
	return a - math.pi
end

-- Engine pull at a given speed: full strength from a standstill, fading to zero at top speed.
-- accel * (1 - (speed / topSpeed) ^ power), never negative.
function CarMath.engineAccel(accel: number, speed: number, topSpeed: number, power: number): number
	if speed <= 0 then
		return accel
	end
	local t = speed / topSpeed
	if t >= 1 then
		return 0
	end
	return accel * (1 - t ^ power)
end

-- Works out the starting push needed to go from 0 to 97% of top speed in timeToTop seconds
-- with the curve above. (Time = topSpeed / accel * integral of 1 / (1 - u^p) du from 0 to 0.97.)
function CarMath.accelForTime(topSpeed: number, timeToTop: number, power: number): number
	local steps = 400
	local upper = 0.97
	local h = upper / steps
	local sum = 0
	for i = 0, steps do
		local u = i * h
		local f = 1 / (1 - u ^ power)
		local weight = if i == 0 or i == steps then 1 elseif i % 2 == 1 then 4 else 2
		sum += weight * f
	end
	local integral = sum * h / 3
	return topSpeed * integral / timeToTop
end

-- Removes the part of a vector that points along a normal (puts it flat on a surface).
function CarMath.flatten(v: Vector3, normal: Vector3): Vector3
	return v - normal * v:Dot(normal)
end

-- Unit vector or a fallback when the vector is too short to normalise safely.
function CarMath.safeUnit(v: Vector3, fallback: Vector3): Vector3
	local m = v.Magnitude
	if m < 1e-6 then
		return fallback
	end
	return v / m
end

-- Angle between two unit vectors, in radians (0..pi).
function CarMath.angleBetween(a: Vector3, b: Vector3): number
	return math.acos(CarMath.clamp(a:Dot(b), -1, 1))
end

-- How far each wheel hangs below its mount when the car sits still on flat ground.
function CarMath.restExtension(tune): number
	local suspension = tune.Suspension
	local omega = 2 * math.pi * suspension.Frequency
	local sag = tune.Gravity / (omega * omega)
	return CarMath.clamp(suspension.Travel - sag, 0, suspension.Travel)
end

-- The wheel mount height that makes the body centre sit rideHeight above flat ground
-- at rest (the reverse of the ride height sum in CarPhysics.new).
function CarMath.mountHeightFor(rideHeight: number, radius: number, travel: number, frequency: number, gravity: number): number
	local omega = 2 * math.pi * frequency
	local rest = CarMath.clamp(travel - gravity / (omega * omega), 0, travel)
	return rest + radius - rideHeight
end

return CarMath
