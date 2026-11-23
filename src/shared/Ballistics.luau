--!strict
-- Shared projectile ballistics simulation, bullet drop, air drag, hitbox classification,
-- exit-raycast wallbang thickness probing, and suppression geometry helpers.

local Workspace = game:GetService("Workspace")

local NetworkTypes = require(script.Parent.NetworkTypes)
local WeaponConfig = require(script.Parent.WeaponConfig)

export type HitZone = NetworkTypes.HitZone

export type Segment = {
	Start: Vector3,
	End: Vector3,
}

export type ImpactKind = "Character" | "Surface" | "Wallbang"

export type ImpactEvent = {
	Kind: ImpactKind,
	Position: Vector3,
	Normal: Vector3,
	ExitPosition: Vector3?,
	ExitNormal: Vector3?,
	Instance: BasePart,
	Material: Enum.Material,
	Character: Model?,
	Humanoid: Humanoid?,
	HitZone: HitZone?,
	Damage: number,
	IsWallbang: boolean,
	Distance: number,
}

export type ProjectileParams = {
	WeaponId: string,
	Origin: Vector3,
	Velocity: Vector3,
	BaseDamage: number,
	MinDamageMultiplier: number,
	DamageDropStart: number,
	DamageDropEnd: number,
	GravityMultiplier: number,
	DragCoefficient: number,
	MaxRange: number,
	PenetrationPower: number,
	ExcludeInstances: { Instance }?,
}

export type ProjectileState = {
	WeaponId: string,
	Position: Vector3,
	Velocity: Vector3,
	BaseDamage: number,
	MinDamageMultiplier: number,
	DamageDropStart: number,
	DamageDropEnd: number,
	GravityMultiplier: number,
	DragCoefficient: number,
	MaxRange: number,
	InitialPenetration: number,
	RemainingPenetration: number,
	DamageMultiplier: number,
	DistanceTraveled: number,
	Age: number,
	WallbangCount: number,
	Alive: boolean,
	ExcludeInstances: { Instance },
	HitHumanoids: { [Humanoid]: boolean },
}

export type StepResult = {
	Segments: { Segment },
	Impacts: { ImpactEvent },
	Alive: boolean,
}

local Ballistics = {}

Ballistics.GRAVITY = 196.2
Ballistics.MAX_WALLBANG_CHECK_DISTANCE = 8.0
Ballistics.MAX_PENETRATION_THICKNESS = 6.0
Ballistics.MAX_IMPACTS_PER_STEP = 4
Ballistics.MAX_TRANSPARENT_SKIPS = 8
Ballistics.WALLBANG_EXIT_OFFSET = 0.05
Ballistics.CHARACTER_PENETRATION_COST = 3.0

local HEAD_PARTS: { [string]: boolean } = {
	Head = true,
}

local TORSO_PARTS: { [string]: boolean } = {
	UpperTorso = true,
	LowerTorso = true,
	Torso = true,
	HumanoidRootPart = true,
}

local LIMB_PARTS: { [string]: boolean } = {
	LeftUpperArm = true,
	LeftLowerArm = true,
	LeftHand = true,
	RightUpperArm = true,
	RightLowerArm = true,
	RightHand = true,
	LeftUpperLeg = true,
	LeftLowerLeg = true,
	LeftFoot = true,
	RightUpperLeg = true,
	RightLowerLeg = true,
	RightFoot = true,
	["Left Arm"] = true,
	["Right Arm"] = true,
	["Left Leg"] = true,
	["Right Leg"] = true,
}

-- Penetration resistance in penetration-power units per stud of material thickness.
local MATERIAL_RESISTANCE: { [Enum.Material]: number } = {
	[Enum.Material.Glass] = 0.35,
	[Enum.Material.Foil] = 0.40,
	[Enum.Material.Cardboard] = 0.45,
	[Enum.Material.Fabric] = 0.50,
	[Enum.Material.Carpet] = 0.60,
	[Enum.Material.LeafyGrass] = 0.70,
	[Enum.Material.Leather] = 0.80,
	[Enum.Material.Snow] = 0.80,
	[Enum.Material.Grass] = 0.85,
	[Enum.Material.Plaster] = 0.90,
	[Enum.Material.Plastic] = 1.00,
	[Enum.Material.SmoothPlastic] = 1.10,
	[Enum.Material.WoodPlanks] = 1.15,
	[Enum.Material.Wood] = 1.25,
	[Enum.Material.Rubber] = 1.30,
	[Enum.Material.Ice] = 1.40,
	[Enum.Material.Sand] = 1.50,
	[Enum.Material.Mud] = 1.80,
	[Enum.Material.Ground] = 2.20,
	[Enum.Material.ClayRoofTiles] = 2.80,
	[Enum.Material.RoofShingles] = 2.40,
	[Enum.Material.CeramicTiles] = 3.20,
	[Enum.Material.Brick] = 4.20,
	[Enum.Material.CorrodedMetal] = 4.50,
	[Enum.Material.Asphalt] = 4.80,
	[Enum.Material.Concrete] = 5.00,
	[Enum.Material.Pavement] = 5.00,
	[Enum.Material.Slate] = 5.20,
	[Enum.Material.Cobblestone] = 5.20,
	[Enum.Material.Limestone] = 5.20,
	[Enum.Material.Sandstone] = 4.60,
	[Enum.Material.Rock] = 5.60,
	[Enum.Material.Granite] = 6.00,
	[Enum.Material.Marble] = 5.80,
	[Enum.Material.Basalt] = 6.00,
	[Enum.Material.DiamondPlate] = 7.00,
	[Enum.Material.Metal] = 8.00,
}

local DEFAULT_MATERIAL_RESISTANCE = 3.0

local sharedExitParams = RaycastParams.new()
sharedExitParams.IgnoreWater = true
sharedExitParams.RespectCanCollide = false

function Ballistics.GetMaterialResistance(material: Enum.Material): number
	return MATERIAL_RESISTANCE[material] or DEFAULT_MATERIAL_RESISTANCE
end

function Ballistics.GetHitZone(part: BasePart): HitZone?
	local name = part.Name
	if HEAD_PARTS[name] then
		return "Head"
	elseif TORSO_PARTS[name] then
		return "Torso"
	elseif LIMB_PARTS[name] then
		return "Limb"
	end
	return nil
end

function Ballistics.FindCharacterFromPart(part: BasePart): (Model?, Humanoid?)
	if part:FindFirstAncestorOfClass("Accessory") ~= nil then
		return nil, nil
	end

	local current: Instance? = part.Parent
	while current and current ~= Workspace do
		if current:IsA("Model") then
			local humanoid = current:FindFirstChildOfClass("Humanoid")
			if humanoid then
				return current, humanoid
			end
		end
		current = current.Parent
	end

	return nil, nil
end

function Ballistics.ComputeDistanceMultiplier(
	distance: number,
	dropStart: number,
	dropEnd: number,
	minMultiplier: number
): number
	if distance <= dropStart then
		return 1.0
	end
	if dropEnd <= dropStart or distance >= dropEnd then
		return math.clamp(minMultiplier, 0.05, 1.0)
	end
	local alpha = (distance - dropStart) / (dropEnd - dropStart)
	return 1.0 + (math.clamp(minMultiplier, 0.05, 1.0) - 1.0) * alpha
end

function Ballistics.ComputeHitDamage(
	baseDamage: number,
	hitZone: HitZone,
	distance: number,
	dropStart: number,
	dropEnd: number,
	minDamageMultiplier: number,
	penetrationDamageMultiplier: number
): number
	local zoneMultiplier = WeaponConfig.HITBOX_MULTIPLIERS[hitZone] or 1.0
	local distanceMultiplier = Ballistics.ComputeDistanceMultiplier(distance, dropStart, dropEnd, minDamageMultiplier)
	local rawDamage = baseDamage * zoneMultiplier * distanceMultiplier * math.max(penetrationDamageMultiplier, 0)
	return math.max(0, math.round(rawDamage * 10) / 10)
end

function Ballistics.ApplySpread(direction: Vector3, spreadDeg: number, rng: Random?): Vector3
	local unitDir = direction.Unit
	if spreadDeg <= 0 then
		return unitDir
	end

	local upRef = if math.abs(unitDir.Y) > 0.99 then Vector3.xAxis else Vector3.yAxis
	local right = unitDir:Cross(upRef).Unit
	local up = right:Cross(unitDir).Unit

	local randU = if rng then rng:NextNumber() else math.random()
	local randV = if rng then rng:NextNumber() else math.random()

	local maxAngle = math.rad(spreadDeg)
	local coneAngle = math.sqrt(randU) * maxAngle
	local azimuth = randV * (2 * math.pi)

	local sinAngle = math.sin(coneAngle)
	local spreadOffset = (right * math.cos(azimuth) + up * math.sin(azimuth)) * sinAngle
	return (unitDir * math.cos(coneAngle) + spreadOffset).Unit
end

function Ballistics.ClosestPointOnSegment(segStart: Vector3, segEnd: Vector3, point: Vector3): (Vector3, number)
	local ab = segEnd - segStart
	local lenSq = ab:Dot(ab)
	if lenSq <= 1e-8 then
		return segStart, (point - segStart).Magnitude
	end
	local t = math.clamp((point - segStart):Dot(ab) / lenSq, 0, 1)
	local closest = segStart + ab * t
	return closest, (point - closest).Magnitude
end

function Ballistics.CreateProjectile(params: ProjectileParams): ProjectileState
	local excludes: { Instance } = {}
	if params.ExcludeInstances then
		for _, inst in ipairs(params.ExcludeInstances) do
			table.insert(excludes, inst)
		end
	end

	return {
		WeaponId = params.WeaponId,
		Position = params.Origin,
		Velocity = params.Velocity,
		BaseDamage = params.BaseDamage,
		MinDamageMultiplier = params.MinDamageMultiplier,
		DamageDropStart = params.DamageDropStart,
		DamageDropEnd = params.DamageDropEnd,
		GravityMultiplier = params.GravityMultiplier,
		DragCoefficient = params.DragCoefficient,
		MaxRange = params.MaxRange,
		InitialPenetration = math.max(params.PenetrationPower, 0),
		RemainingPenetration = math.max(params.PenetrationPower, 0),
		DamageMultiplier = 1.0,
		DistanceTraveled = 0,
		Age = 0,
		WallbangCount = 0,
		Alive = true,
		ExcludeInstances = excludes,
		HitHumanoids = {},
	}
end

local function probePartExit(part: BasePart, entryPos: Vector3, dir: Vector3): RaycastResult?
	if part:IsA("Terrain") then
		return nil
	end
	sharedExitParams.IncludeInstances = { part }
	local probeStart = entryPos + dir * Ballistics.MAX_WALLBANG_CHECK_DISTANCE
	local probeVector = -dir * Ballistics.MAX_WALLBANG_CHECK_DISTANCE
	return Workspace:Raycast(probeStart, probeVector, sharedExitParams)
end

local function appendExclude(state: ProjectileState, raycastParams: RaycastParams, instance: Instance): ()
	table.insert(state.ExcludeInstances, instance)
	raycastParams.ExcludeInstances = state.ExcludeInstances
end

function Ballistics.StepProjectile(
	state: ProjectileState,
	dt: number,
	raycastParams: RaycastParams
): StepResult
	local segments: { Segment } = {}
	local impacts: { ImpactEvent } = {}

	if not state.Alive or dt <= 0 then
		return {
			Segments = segments,
			Impacts = impacts,
			Alive = false,
		}
	end

	local stepDt = math.min(dt, 0.1)
	local gravityVec = Vector3.new(0, -Ballistics.GRAVITY * state.GravityMultiplier, 0)
	local dragAccel = -state.Velocity * state.DragCoefficient
	local accel = gravityVec + dragAccel

	local nextVelocity = state.Velocity + accel * stepDt
	local displacement = (state.Velocity + nextVelocity) * 0.5 * stepDt

	state.Velocity = nextVelocity
	state.Age += stepDt

	local totalDist = displacement.Magnitude
	if totalDist < 1e-6 or state.DistanceTraveled >= state.MaxRange then
		state.Alive = false
		return {
			Segments = segments,
			Impacts = impacts,
			Alive = false,
		}
	end

	raycastParams.ExcludeInstances = state.ExcludeInstances

	local currentPos = state.Position
	local remainingDist = totalDist
	local dir = displacement.Unit
	local impactCount = 0
	local skipCount = 0

	while remainingDist > 1e-4 and state.Alive do
		local castVector = dir * remainingDist
		local hitResult = Workspace:Raycast(currentPos, castVector, raycastParams)

		if not hitResult then
			local endPos = currentPos + castVector
			table.insert(segments, { Start = currentPos, End = endPos })
			state.DistanceTraveled += remainingDist
			state.Position = endPos
			if state.DistanceTraveled >= state.MaxRange then
				state.Alive = false
			end
			break
		end

		local hitInst = hitResult.Instance
		local hitPos = hitResult.Position
		local segmentDist = (hitPos - currentPos).Magnitude

		-- Skip hats/accessories and invisible HumanoidRootParts so real visual hitboxes take precedence.
		local accessory = hitInst:FindFirstAncestorOfClass("Accessory")
		if accessory then
			skipCount += 1
			appendExclude(state, raycastParams, accessory)
			if skipCount > Ballistics.MAX_TRANSPARENT_SKIPS then
				table.insert(segments, { Start = currentPos, End = hitPos })
				state.Position = hitPos
				state.Alive = false
				break
			end
			local advance = segmentDist + 0.01
			remainingDist = math.max(0, remainingDist - advance)
			local nextPos = hitPos + dir * 0.01
			table.insert(segments, { Start = currentPos, End = nextPos })
			currentPos = nextPos
			state.Position = currentPos
			state.DistanceTraveled += segmentDist
			continue
		end

		if hitInst:IsA("BasePart") and hitInst.Name == "HumanoidRootPart" and hitInst.Transparency >= 0.99 then
			skipCount += 1
			appendExclude(state, raycastParams, hitInst)
			if skipCount > Ballistics.MAX_TRANSPARENT_SKIPS then
				table.insert(segments, { Start = currentPos, End = hitPos })
				state.Position = hitPos
				state.Alive = false
				break
			end
			local advance = segmentDist + 0.01
			remainingDist = math.max(0, remainingDist - advance)
			local nextPos = hitPos + dir * 0.01
			table.insert(segments, { Start = currentPos, End = nextPos })
			currentPos = nextPos
			state.Position = currentPos
			state.DistanceTraveled += segmentDist
			continue
		end

		table.insert(segments, { Start = currentPos, End = hitPos })
		state.DistanceTraveled += segmentDist

		if state.DistanceTraveled >= state.MaxRange then
			state.Position = hitPos
			state.Alive = false
			break
		end

		if not hitInst:IsA("BasePart") then
			state.Position = hitPos
			state.Alive = false
			break
		end

		local hitPart = hitInst :: BasePart
		local character, humanoid = Ballistics.FindCharacterFromPart(hitPart)

		if character and humanoid then
			-- Pass cleanly through already-dead ragdolls/corpses.
			if humanoid.Health <= 0 or state.HitHumanoids[humanoid] then
				skipCount += 1
				appendExclude(state, raycastParams, character)
				if skipCount > Ballistics.MAX_TRANSPARENT_SKIPS then
					state.Position = hitPos
					state.Alive = false
					break
				end
				remainingDist = math.max(0, remainingDist - (segmentDist + 0.02))
				currentPos = hitPos + dir * 0.02
				state.Position = currentPos
				continue
			end

			state.HitHumanoids[humanoid] = true
			local hitZone: HitZone = Ballistics.GetHitZone(hitPart) or "Torso"
			local damage = Ballistics.ComputeHitDamage(
				state.BaseDamage,
				hitZone,
				state.DistanceTraveled,
				state.DamageDropStart,
				state.DamageDropEnd,
				state.MinDamageMultiplier,
				state.DamageMultiplier
			)

			table.insert(impacts, {
				Kind = "Character",
				Position = hitPos,
				Normal = hitResult.Normal,
				ExitPosition = nil,
				ExitNormal = nil,
				Instance = hitPart,
				Material = hitResult.Material,
				Character = character,
				Humanoid = humanoid,
				HitZone = hitZone,
				Damage = damage,
				IsWallbang = state.WallbangCount > 0,
				Distance = state.DistanceTraveled,
			})

			impactCount += 1
			if
				state.RemainingPenetration >= Ballistics.CHARACTER_PENETRATION_COST
				and impactCount < Ballistics.MAX_IMPACTS_PER_STEP
			then
				state.RemainingPenetration -= Ballistics.CHARACTER_PENETRATION_COST
				state.DamageMultiplier *= 0.60
				state.Velocity *= 0.78
				appendExclude(state, raycastParams, character)
				remainingDist = math.max(0, (remainingDist - segmentDist) * 0.78)
				currentPos = hitPos + dir * 0.05
				state.Position = currentPos
				continue
			else
				state.Position = hitPos
				state.Alive = false
				break
			end
		end

		-- Environment obstacle: check if wallbang penetration succeeds.
		local penetrated = false
		if state.RemainingPenetration > 0 and impactCount < Ballistics.MAX_IMPACTS_PER_STEP then
			local exitResult = probePartExit(hitPart, hitPos, dir)
			if exitResult then
				local exitOffset = (exitResult.Position - hitPos):Dot(dir)
				local thickness = (exitResult.Position - hitPos).Magnitude
				local resistance = Ballistics.GetMaterialResistance(hitResult.Material)
				local penCost = thickness * resistance

				if
					exitOffset >= -0.005
					and thickness <= Ballistics.MAX_PENETRATION_THICKNESS
					and penCost <= state.RemainingPenetration
				then
					penetrated = true
					impactCount += 1
					state.RemainingPenetration -= penCost
					state.WallbangCount += 1

					local costRatio = math.clamp(penCost / math.max(state.InitialPenetration, 0.01), 0, 1)
					local damageRetention = math.clamp(1 - costRatio * 0.65, 0.25, 0.92)
					local speedRetention = math.clamp(math.sqrt(damageRetention), 0.35, 0.95)

					state.DamageMultiplier *= damageRetention
					state.Velocity *= speedRetention

					table.insert(impacts, {
						Kind = "Wallbang",
						Position = hitPos,
						Normal = hitResult.Normal,
						ExitPosition = exitResult.Position,
						ExitNormal = exitResult.Normal,
						Instance = hitPart,
						Material = hitResult.Material,
						Character = nil,
						Humanoid = nil,
						HitZone = nil,
						Damage = 0,
						IsWallbang = true,
						Distance = state.DistanceTraveled,
					})

					local wallSpan = (exitResult.Position - currentPos).Magnitude + Ballistics.WALLBANG_EXIT_OFFSET
					state.DistanceTraveled += thickness
					currentPos = exitResult.Position + dir * Ballistics.WALLBANG_EXIT_OFFSET
					state.Position = currentPos
					remainingDist = math.max(0, (remainingDist - wallSpan) * speedRetention)

					if remainingDist <= 1e-4 then
						break
					end
				end
			end
		end

		if not penetrated then
			table.insert(impacts, {
				Kind = "Surface",
				Position = hitPos,
				Normal = hitResult.Normal,
				ExitPosition = nil,
				ExitNormal = nil,
				Instance = hitPart,
				Material = hitResult.Material,
				Character = nil,
				Humanoid = nil,
				HitZone = nil,
				Damage = 0,
				IsWallbang = false,
				Distance = state.DistanceTraveled,
			})
			state.Position = hitPos
			state.Alive = false
			break
		end
	end

	return {
		Segments = segments,
		Impacts = impacts,
		Alive = state.Alive,
	}
end

return Ballistics
