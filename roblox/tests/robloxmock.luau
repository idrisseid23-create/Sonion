-- API-checking Roblox mock: every property set/get, method call and Enum item is checked
-- against the real Roblox API list (generated from @rbxts/types). Unknown names error.
local HERE = "./"
assert(__loadfile(HERE .. "mock.luau"))() -- Vector3, CFrame, typeof
local API = assert(__loadfile(HERE .. "api.luau"))()

local R = { log = {}, errors = {} }

---------------------------------------------------------------- Enum
local enumItemMT = { __type = "EnumItem" }
enumItemMT.__index = function(t, k)
	error("EnumItem has no member " .. tostring(k), 2)
end
local enumCache = {}
Enum = setmetatable({}, {
	__index = function(_, enumName)
		local items = API.enums[enumName]
		if not items then
			error("Unknown Enum." .. tostring(enumName), 2)
		end
		if not enumCache[enumName] then
			enumCache[enumName] = setmetatable({}, {
				__index = function(t, itemName)
					local value = items[itemName]
					if value == nil then
						error("Unknown Enum." .. enumName .. "." .. tostring(itemName), 2)
					end
					local item = setmetatable({ Name = itemName, Value = value, EnumType = enumName }, enumItemMT)
					rawset(t, itemName, item)
					return item
				end,
			})
		end
		return enumCache[enumName]
	end,
})

---------------------------------------------------------------- datatypes
local function datatype(typeName, fields)
	return setmetatable(fields, { __type = typeName })
end
UDim = { new = function(s, o) return datatype("UDim", { Scale = s, Offset = o }) end }
UDim2 = {
	new = function(xs, xo, ys, yo) return datatype("UDim2", { X = UDim.new(xs, xo), Y = UDim.new(ys, yo) }) end,
	fromOffset = function(x, y) return datatype("UDim2", { X = UDim.new(0, x), Y = UDim.new(0, y) }) end,
	fromScale = function(x, y) return datatype("UDim2", { X = UDim.new(x, 0), Y = UDim.new(y, 0) }) end,
}
Vector2 = { new = function(x, y) return datatype("Vector2", { X = x, Y = y }) end }
Color3 = {
	fromRGB = function(r, g, b)
		assert(type(r) == "number" and type(g) == "number" and type(b) == "number", "Color3.fromRGB needs numbers")
		return datatype("Color3", { R = r / 255, G = g / 255, B = b / 255 })
	end,
	new = function(r, g, b) return datatype("Color3", { R = r, G = g, B = b }) end,
}
PhysicalProperties = {
	new = function(d, f, e, fw, ew)
		assert(type(d) == "number" and type(f) == "number" and type(e) == "number" and type(fw) == "number" and type(ew) == "number", "PhysicalProperties.new needs 5 numbers")
		assert(d >= 0.0001 and d <= 100, "density out of range")
		return datatype("PhysicalProperties", { Density = d, Friction = f, Elasticity = e })
	end,
}
TweenInfo = { new = function(...) return datatype("TweenInfo", { args = { ... } }) end }
local rayFields = { ExcludeInstances = true, IncludeInstances = true, FilterDescendantsInstances = true, FilterType = true, IgnoreWater = true, CollisionGroup = true, RespectCanCollide = true, BruteForceAllSlow = true }
RaycastParams = {
	new = function()
		local store = {}
		return setmetatable({}, {
			__type = "RaycastParams",
			__index = function(_, k)
				assert(rayFields[k], "RaycastParams has no " .. tostring(k))
				return store[k]
			end,
			__newindex = function(_, k, v)
				assert(rayFields[k], "RaycastParams has no " .. tostring(k))
				store[k] = v
			end,
		})
	end,
}

---------------------------------------------------------------- signals
local function newSignal(name)
	local handlers = {}
	local signal = { Name = name }
	function signal:Connect(fn)
		assert(type(fn) == "function", "Connect needs a function")
		local entry = { fn = fn }
		table.insert(handlers, entry)
		return { Disconnect = function() entry.dead = true end, Connected = true }
	end
	function signal:Once(fn)
		return self:Connect(fn)
	end
	function signal:Fire(...)
		for _, h in handlers do
			if not h.dead then
				h.fn(...)
			end
		end
	end
	function signal:Wait() end
	return setmetatable(signal, { __type = "RBXScriptSignal" })
end

---------------------------------------------------------------- instances
local classes = API.classes
local function findProp(className, prop)
	local queue = { className }
	local seen = {}
	while #queue > 0 do
		local c = table.remove(queue, 1)
		if not seen[c] then
			seen[c] = true
			local info = classes[c]
			if info then
				if info.props[prop] then
					return info.props[prop]
				end
				for _, e in info.ext do
					table.insert(queue, e)
				end
			end
		end
	end
	return nil
end
local function hasMethod(className, m)
	local queue = { className }
	local seen = {}
	while #queue > 0 do
		local c = table.remove(queue, 1)
		if not seen[c] then
			seen[c] = true
			local info = classes[c]
			if info then
				if info.methods[m] then
					return true
				end
				for _, e in info.ext do
					table.insert(queue, e)
				end
			end
		end
	end
	return false
end
local function isA(className, target)
	if target == "Instance" then
		return true
	end
	local queue = { className }
	local seen = {}
	while #queue > 0 do
		local c = table.remove(queue, 1)
		if c == target then
			return true
		end
		if not seen[c] then
			seen[c] = true
			local info = classes[c]
			if info then
				for _, e in info.ext do
					table.insert(queue, e)
				end
			end
		end
	end
	return false
end
R.isA = isA

local SPECIAL_DEFAULTS = { AssemblyMass = 300, Health = 100, MaxActivationDistance = 10 }

local InstanceMT = {}
local methodImpl = {}

local function checkType(kind, v, className, k)
	local t = typeof(v)
	local ok = true
	if kind == "number" then
		ok = t == "number"
	elseif kind == "boolean" then
		ok = t == "boolean"
	elseif kind == "string" then
		ok = t == "string"
	elseif kind == "Vector3" then
		ok = t == "Vector3"
	elseif kind == "CFrame" then
		ok = t == "CFrame"
	elseif kind == "enum" then
		ok = t == "EnumItem"
	end
	if not ok then
		error(string.format("%s.%s expects %s, got %s", className, k, kind, t), 3)
	end
end

local function new(className)
	assert(classes[className], "Instance.new: unknown class " .. tostring(className))
	local inst = {
		__class = className,
		__props = { Name = className },
		__children = {},
		__attrs = {},
		__signals = {},
		__propSignals = {},
	}
	return setmetatable(inst, InstanceMT)
end
R.new = new

InstanceMT.__type = "Instance"
InstanceMT.__tostring = function(self)
	return rawget(self, "__props").Name
end
InstanceMT.__index = function(self, k)
	local className = rawget(self, "__class")
	if k == "Parent" then
		return rawget(self, "__parent")
	elseif k == "ClassName" then
		return className
	end
	local custom = rawget(self, "__custom")
	if custom and custom[k] ~= nil then
		return custom[k]
	end
	local prop = findProp(className, k)
	if prop then
		local kind = prop[1]
		if kind == "signal" then
			local signals = rawget(self, "__signals")
			signals[k] = signals[k] or newSignal(k)
			return signals[k]
		end
		local v = rawget(self, "__props")[k]
		if v ~= nil then
			return v
		end
		if SPECIAL_DEFAULTS[k] then
			return SPECIAL_DEFAULTS[k]
		end
		if kind == "number" then
			return 0
		elseif kind == "boolean" then
			return false
		elseif kind == "string" then
			return ""
		elseif kind == "Vector3" then
			return Vector3.zero
		elseif kind == "CFrame" then
			return CFrame.identity
		end
		return nil
	end
	if hasMethod(className, k) or methodImpl[k] then
		local impl = methodImpl[k]
		if impl then
			return impl
		end
		return function()
			table.insert(R.log, "stub " .. className .. ":" .. k)
			return nil
		end
	end
	for _, child in rawget(self, "__children") do
		if rawget(child, "__props").Name == k then
			return child
		end
	end
	error(string.format("%s is not a valid member of %s", tostring(k), className), 2)
end
InstanceMT.__newindex = function(self, k, v)
	local className = rawget(self, "__class")
	if k == "Parent" then
		local old = rawget(self, "__parent")
		if old then
			local list = rawget(old, "__children")
			for i, c in list do
				if c == self then
					table.remove(list, i)
					break
				end
			end
		end
		rawset(self, "__parent", v)
		if v then
			table.insert(rawget(v, "__children"), self)
			if R.onParented then
				R.onParented(self, v)
			end
		end
		return
	end
	local prop = findProp(className, k)
	if not prop then
		error(string.format("cannot set %s: not a property of %s", tostring(k), className), 2)
	end
	if prop[2] then
		error(string.format("%s.%s is read-only", className, k), 2)
	end
	checkType(prop[1], v, className, k)
	rawget(self, "__props")[k] = v
	local ps = rawget(self, "__propSignals")[k]
	if ps then
		ps:Fire()
	end
end

-- internal set (bypasses read-only)
function R.set(inst, k, v)
	rawget(inst, "__props")[k] = v
	local ps = rawget(inst, "__propSignals")[k]
	if ps then
		ps:Fire()
	end
end

local function descendants(inst, out)
	for _, c in rawget(inst, "__children") do
		table.insert(out, c)
		descendants(c, out)
	end
	return out
end

function methodImpl.FindFirstChild(self, name, recursive)
	for _, c in (if recursive then descendants(self, {}) else rawget(self, "__children")) do
		if rawget(c, "__props").Name == name then
			return c
		end
	end
	return nil
end
function methodImpl.WaitForChild(self, name)
	local c = methodImpl.FindFirstChild(self, name)
	if not c then
		error("WaitForChild would wait forever: " .. tostring(name) .. " in " .. tostring(self), 2)
	end
	return c
end
function methodImpl.GetChildren(self)
	return table.clone(rawget(self, "__children"))
end
function methodImpl.GetDescendants(self)
	return descendants(self, {})
end
function methodImpl.FindFirstChildOfClass(self, className)
	for _, c in rawget(self, "__children") do
		if rawget(c, "__class") == className then
			return c
		end
	end
	return nil
end
function methodImpl.FindFirstChildWhichIsA(self, className)
	for _, c in rawget(self, "__children") do
		if isA(rawget(c, "__class"), className) then
			return c
		end
	end
	return nil
end
function methodImpl.IsA(self, className)
	assert(classes[className] or className == "Instance", "IsA: unknown class " .. tostring(className))
	return isA(rawget(self, "__class"), className)
end
function methodImpl.SetAttribute(self, name, value)
	rawget(self, "__attrs")[name] = value
end
function methodImpl.GetAttribute(self, name)
	return rawget(self, "__attrs")[name]
end
function methodImpl.Destroy(self)
	local parent = rawget(self, "__parent")
	if rawget(self, "__props").Name == "SeatWeld" and parent and rawget(parent, "__class") == "Seat" then
		local hum = rawget(parent, "__props").Occupant
		R.set(parent, "Occupant", nil)
		if hum then
			R.set(hum, "SeatPart", nil)
		end
	end
	local sig = rawget(self, "__signals").Destroying
	if sig then
		sig:Fire()
	end
	self.Parent = nil
	rawset(self, "__destroyed", true)
end
function methodImpl.IsDescendantOf(self, other)
	local p = rawget(self, "__parent")
	while p do
		if p == other then
			return true
		end
		p = rawget(p, "__parent")
	end
	return false
end
function methodImpl.FindFirstAncestorWhichIsA(self, className)
	local p = rawget(self, "__parent")
	while p do
		if isA(rawget(p, "__class"), className) then
			return p
		end
		p = rawget(p, "__parent")
	end
	return nil
end
function methodImpl.GetPropertyChangedSignal(self, prop)
	assert(findProp(rawget(self, "__class"), prop), "GetPropertyChangedSignal: no property " .. tostring(prop))
	local ps = rawget(self, "__propSignals")
	ps[prop] = ps[prop] or newSignal(prop)
	return ps[prop]
end
function methodImpl.PivotTo(self, cf)
	assert(typeof(cf) == "CFrame", "PivotTo needs a CFrame")
	if rawget(self, "__class") == "Model" then
		local primary = rawget(self, "__props").PrimaryPart
		if primary then
			rawget(primary, "__props").CFrame = cf
		end
	else
		rawget(self, "__props").CFrame = cf
	end
end
function methodImpl.GetVelocityAtPosition(self, p)
	assert(typeof(p) == "Vector3")
	return Vector3.zero
end
function methodImpl.SetNetworkOwner(self, player)
	table.insert(R.log, "SetNetworkOwner " .. tostring(player))
end
function methodImpl.Sit(self, humanoid)
	R.set(self, "Occupant", humanoid)
	R.set(humanoid, "SeatPart", self)
	local weld = new("Weld")
	weld.Name = "SeatWeld"
	weld.Parent = self
	local seatedSignal = humanoid.Seated
	seatedSignal:Fire(true, self)
end
function methodImpl.Clone(self)
	error("Clone not mocked")
end

Instance = { new = function(className, parent)
	local inst = new(className)
	if parent then
		inst.Parent = parent
	end
	return inst
end }

---------------------------------------------------------------- services
local function service(className, custom)
	local s = new(className)
	rawset(s, "__custom", custom or {})
	return s
end

local tags = {}
local tagAdded, tagRemoved = {}, {}
local function tagSignal(list, tag)
	list[tag] = list[tag] or newSignal("tag " .. tag)
	return list[tag]
end
R.CollectionService = service("CollectionService", {
	AddTag = function(_, inst, tag)
		tags[tag] = tags[tag] or {}
		tags[tag][inst] = true
		tagSignal(tagAdded, tag):Fire(inst)
	end,
	HasTag = function(_, inst, tag)
		return tags[tag] ~= nil and tags[tag][inst] == true
	end,
	GetTagged = function(_, tag)
		local out = {}
		for inst in tags[tag] or {} do
			table.insert(out, inst)
		end
		return out
	end,
	GetInstanceAddedSignal = function(_, tag)
		return tagSignal(tagAdded, tag)
	end,
	GetInstanceRemovedSignal = function(_, tag)
		return tagSignal(tagRemoved, tag)
	end,
})

R.renderSteps = {}
R.RunService = service("RunService", {
	BindToRenderStep = function(_, name, priority, fn)
		assert(type(name) == "string" and type(priority) == "number" and type(fn) == "function", "BindToRenderStep args")
		R.renderSteps[name] = fn
	end,
	UnbindFromRenderStep = function(_, name)
		R.renderSteps[name] = nil
	end,
	IsServer = function()
		return R.isServer
	end,
	IsClient = function()
		return not R.isServer
	end,
})

R.keysDown = {}
R.UserInputService = service("UserInputService", {
	IsKeyDown = function(_, key)
		assert(typeof(key) == "EnumItem" and key.EnumType == "KeyCode", "IsKeyDown needs a KeyCode")
		return R.keysDown[key.Name] == true
	end,
	GetFocusedTextBox = function()
		return nil
	end,
	GetLastInputType = function()
		return Enum.UserInputType.Keyboard
	end,
	GetGamepadConnected = function()
		return false
	end,
	IsMouseButtonPressed = function()
		return false
	end,
})

R.casBindings = {}
R.ContextActionService = service("ContextActionService", {
	BindActionAtPriority = function(_, name, fn, createTouch, priority, ...)
		assert(type(name) == "string" and type(fn) == "function" and type(createTouch) == "boolean" and type(priority) == "number", "BindActionAtPriority args")
		for _, key in { ... } do
			assert(typeof(key) == "EnumItem", "BindActionAtPriority input must be an Enum")
		end
		R.casBindings[name] = { fn = fn, keys = { ... } }
	end,
	UnbindAction = function(_, name)
		R.casBindings[name] = nil
	end,
})

R.TweenService = service("TweenService", {
	Create = function(_, inst, info, goals)
		assert(typeof(info) == "TweenInfo", "TweenService:Create needs TweenInfo")
		for k, v in goals do
			inst[k] = v -- validates the property
		end
		return { Play = function() end, Cancel = function() end }
	end,
})

R.Players = service("Players", {
	GetPlayers = function()
		return R.players or {}
	end,
	GetPlayerFromCharacter = function(_, character)
		for _, p in R.players or {} do
			if p.Character == character then
				return p
			end
		end
		return nil
	end,
})

R.ReplicatedStorage = service("ReplicatedStorage")
R.ServerScriptService = service("ServerScriptService")

local ws = service("Workspace", {
	Raycast = function(_, origin, dir, params)
		assert(typeof(origin) == "Vector3" and typeof(dir) == "Vector3", "Raycast args")
		assert(params == nil or typeof(params) == "RaycastParams", "Raycast params")
		if origin.Y > 0 and dir.Y < 0 then
			local t = origin.Y / -dir.Unit.Y
			if t <= dir.Magnitude then
				return { Position = origin + dir.Unit * t, Normal = Vector3.yAxis, Distance = t, Instance = R.baseplate, Material = Enum.Material.Plastic }
			end
		end
		return nil
	end,
	Spherecast = function(_, origin, radius, dir, params)
		assert(typeof(origin) == "Vector3" and type(radius) == "number" and typeof(dir) == "Vector3", "Spherecast args")
		assert(params == nil or typeof(params) == "RaycastParams", "Spherecast params")
		local lowest = origin.Y - radius
		if lowest > 0 and dir.Y < 0 then
			local t = lowest / -dir.Unit.Y
			if t <= dir.Magnitude then
				local c = origin + dir.Unit * t
				return { Position = c - Vector3.yAxis * radius, Normal = Vector3.yAxis, Distance = t, Instance = R.baseplate, Material = Enum.Material.Plastic }
			end
		end
		return nil
	end,
})
R.set(ws, "Gravity", 196.2)
workspace = ws
R.workspace = ws
local camera = new("Camera")
R.set(ws, "CurrentCamera", camera)
camera.Parent = ws
R.baseplate = new("Part")
R.baseplate.Name = "Baseplate"
R.baseplate.Parent = ws

local services = {
	CollectionService = R.CollectionService,
	RunService = R.RunService,
	UserInputService = R.UserInputService,
	ContextActionService = R.ContextActionService,
	TweenService = R.TweenService,
	Players = R.Players,
	ReplicatedStorage = R.ReplicatedStorage,
	ServerScriptService = R.ServerScriptService,
	Workspace = ws,
}
game = service("Folder", {
	GetService = function(_, name)
		return assert(services[name], "GetService: not mocked " .. tostring(name))
	end,
})

task = {
	spawn = function(f, ...)
		f(...)
	end,
	defer = function(f, ...)
		f(...)
	end,
	delay = function(_, f, ...)
		f(...)
	end,
	wait = function() end,
}

---------------------------------------------------------------- scripts and modules
local moduleCache = {}
local function runFile(path, scriptInst)
	local fn, err = __loadfile(path)
	assert(fn, err)
	setfenv(fn, setmetatable({ script = scriptInst }, { __index = _G }))
	return fn()
end
local realRequire = require
function require(target)
	if typeof(target) == "Instance" then
		local path = rawget(target, "__path")
		assert(path, "require: module has no source " .. tostring(target))
		if moduleCache[target] == nil then
			moduleCache[target] = runFile(path, target)
		end
		return moduleCache[target]
	end
	return realRequire(target)
end
function R.module(name, path, parent)
	local m = new("ModuleScript")
	m.Name = name
	rawset(m, "__path", path)
	m.Parent = parent
	return m
end
function R.runScript(className, name, path, parent)
	local s = new(className)
	s.Name = name
	s.Parent = parent
	return runFile(path, s)
end

return R
