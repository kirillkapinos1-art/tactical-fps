--!strict
-- Sub-stepped damped harmonic oscillator for procedural FPS animation,
-- viewmodel sway/bobbing, camera recoil recovery, and movement smoothing.

local MAX_DELTA_TIME = 0.1
local MAX_SUBSTEP_DT = 1 / 240
local MAX_SUBSTEPS = 24

local function isFiniteNumber(value: number): boolean
	return value == value and math.abs(value) ~= math.huge
end

local function isFiniteVector3(vec: Vector3): boolean
	return isFiniteNumber(vec.X) and isFiniteNumber(vec.Y) and isFiniteNumber(vec.Z)
end

--// Vector3 Spring

local Vector3SpringMethods = {}
Vector3SpringMethods.__index = Vector3SpringMethods

export type Vector3SpringData = {
	Target: Vector3,
	Position: Vector3,
	Velocity: Vector3,
	Mass: number,
	Force: number,
	Damping: number,
	Speed: number,
}

export type Vector3Spring = typeof(setmetatable({} :: Vector3SpringData, Vector3SpringMethods))

function Vector3SpringMethods.Shove(self: Vector3Spring, impulse: Vector3): ()
	if not isFiniteVector3(impulse) then
		return
	end
	local invMass = 1 / math.max(self.Mass, 0.001)
	self.Velocity += impulse * invMass
end

function Vector3SpringMethods.SetTarget(self: Vector3Spring, target: Vector3): ()
	if not isFiniteVector3(target) then
		return
	end
	self.Target = target
end

function Vector3SpringMethods.SnapTo(self: Vector3Spring, value: Vector3): ()
	if not isFiniteVector3(value) then
		return
	end
	self.Target = value
	self.Position = value
	self.Velocity = Vector3.zero
end

function Vector3SpringMethods.Reset(self: Vector3Spring): ()
	self.Target = Vector3.zero
	self.Position = Vector3.zero
	self.Velocity = Vector3.zero
end

function Vector3SpringMethods.Update(self: Vector3Spring, dt: number): Vector3
	if not isFiniteNumber(dt) or dt <= 0 then
		return self.Position
	end

	local clampedDt = math.min(dt, MAX_DELTA_TIME) * math.max(self.Speed, 0)
	if clampedDt <= 0 then
		return self.Position
	end

	local steps = math.clamp(math.ceil(clampedDt / MAX_SUBSTEP_DT), 1, MAX_SUBSTEPS)
	local stepDt = clampedDt / steps
	local invMass = 1 / math.max(self.Mass, 0.001)

	for _ = 1, steps do
		local displacement = self.Target - self.Position
		local acceleration = (displacement * self.Force - self.Velocity * self.Damping) * invMass
		self.Velocity += acceleration * stepDt
		self.Position += self.Velocity * stepDt
	end

	return self.Position
end

--// Scalar Spring

local ScalarSpringMethods = {}
ScalarSpringMethods.__index = ScalarSpringMethods

export type ScalarSpringData = {
	Target: number,
	Position: number,
	Velocity: number,
	Mass: number,
	Force: number,
	Damping: number,
	Speed: number,
}

export type ScalarSpring = typeof(setmetatable({} :: ScalarSpringData, ScalarSpringMethods))

function ScalarSpringMethods.Shove(self: ScalarSpring, impulse: number): ()
	if not isFiniteNumber(impulse) then
		return
	end
	local invMass = 1 / math.max(self.Mass, 0.001)
	self.Velocity += impulse * invMass
end

function ScalarSpringMethods.SetTarget(self: ScalarSpring, target: number): ()
	if not isFiniteNumber(target) then
		return
	end
	self.Target = target
end

function ScalarSpringMethods.SnapTo(self: ScalarSpring, value: number): ()
	if not isFiniteNumber(value) then
		return
	end
	self.Target = value
	self.Position = value
	self.Velocity = 0
end

function ScalarSpringMethods.Reset(self: ScalarSpring): ()
	self.Target = 0
	self.Position = 0
	self.Velocity = 0
end

function ScalarSpringMethods.Update(self: ScalarSpring, dt: number): number
	if not isFiniteNumber(dt) or dt <= 0 then
		return self.Position
	end

	local clampedDt = math.min(dt, MAX_DELTA_TIME) * math.max(self.Speed, 0)
	if clampedDt <= 0 then
		return self.Position
	end

	local steps = math.clamp(math.ceil(clampedDt / MAX_SUBSTEP_DT), 1, MAX_SUBSTEPS)
	local stepDt = clampedDt / steps
	local invMass = 1 / math.max(self.Mass, 0.001)

	for _ = 1, steps do
		local displacement = self.Target - self.Position
		local acceleration = (displacement * self.Force - self.Velocity * self.Damping) * invMass
		self.Velocity += acceleration * stepDt
		self.Position += self.Velocity * stepDt
	end

	return self.Position
end

--// Module Constructors

local Spring = {}

function Spring.new(
	mass: number?,
	force: number?,
	damping: number?,
	speed: number?,
	initialTarget: Vector3?
): Vector3Spring
	local target = initialTarget or Vector3.zero
	local data: Vector3SpringData = {
		Target = target,
		Position = target,
		Velocity = Vector3.zero,
		Mass = mass or 5,
		Force = force or 50,
		Damping = damping or 4,
		Speed = speed or 4,
	}
	return setmetatable(data, Vector3SpringMethods)
end

function Spring.fromFrequency(
	dampingRatio: number,
	frequencyHz: number,
	speed: number?,
	initialTarget: Vector3?
): Vector3Spring
	local omega = 2 * math.pi * math.max(frequencyHz, 0.01)
	local force = omega * omega
	local damping = 2 * math.max(dampingRatio, 0) * omega
	return Spring.new(1, force, damping, speed or 1, initialTarget)
end

function Spring.newScalar(
	mass: number?,
	force: number?,
	damping: number?,
	speed: number?,
	initialTarget: number?
): ScalarSpring
	local target = initialTarget or 0
	local data: ScalarSpringData = {
		Target = target,
		Position = target,
		Velocity = 0,
		Mass = mass or 1,
		Force = force or 120,
		Damping = damping or 16,
		Speed = speed or 1,
	}
	return setmetatable(data, ScalarSpringMethods)
end

function Spring.scalarFromFrequency(
	dampingRatio: number,
	frequencyHz: number,
	speed: number?,
	initialTarget: number?
): ScalarSpring
	local omega = 2 * math.pi * math.max(frequencyHz, 0.01)
	local force = omega * omega
	local damping = 2 * math.max(dampingRatio, 0) * omega
	return Spring.newScalar(1, force, damping, speed or 1, initialTarget)
end

return Spring
