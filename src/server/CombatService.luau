--!strict
-- Server-authoritative combat handler: anti-exploit shot validation, RPM & ammo enforcement,
-- Heartbeat projectile simulation, wallbang damage, suppression detection, and reload state machine.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared.Ballistics)
local GrenadeConfig = require(Shared.GrenadeConfig)
local NetworkTypes = require(Shared.NetworkTypes)
local WeaponConfig = require(Shared.WeaponConfig)

export type FireMode = NetworkTypes.FireMode
export type WeaponSlot = NetworkTypes.WeaponSlot
export type LoadoutSelection = NetworkTypes.LoadoutSelection

export type GameLoopServiceModule = {
	IsMatchActive: () -> boolean,
	RecordKill: (
		killer: Player?,
		victim: Player,
		weaponId: string,
		isHeadshot: boolean,
		isWallbang: boolean,
		distance: number
	) -> (),
}

type SlotWeaponState = {
	WeaponId: string,
	Magazine: number,
	Reserve: number,
	FireMode: FireMode,
}

type PlayerCombatState = {
	Character: Model?,
	Primary: SlotWeaponState,
	Secondary: SlotWeaponState,
	ActiveSlot: WeaponSlot,
	IsReloading: boolean,
	ReloadToken: number,
	LastFireTime: number,
	LastThrowTime: number,
	FragCount: number,
	FlashCount: number,
	SpawnProtectedUntil: number,
	EquippedModel: Model?,
}

type ActiveServerProjectile = {
	Shooter: Player,
	InitialOrigin: Vector3,
	SuppressionRadius: number,
	State: Ballistics.ProjectileState,
	RayParams: RaycastParams,
	SuppressedPlayers: { [Player]: boolean },
}

type ActiveServerGrenade = {
	Id: number,
	Thrower: Player,
	Def: GrenadeConfig.GrenadeDefinition,
	Position: Vector3,
	Velocity: Vector3,
	DetonateAt: number,
	RayParams: RaycastParams,
}

local CombatService = {}

local MAX_ORIGIN_OFFSET_FROM_HEAD = 10.0
local SPAWN_PROTECTION_SECONDS = 1.25
local FIRE_RATE_TOLERANCE = 0.88

local gameLoopService: GameLoopServiceModule

local fireWeaponRemote: RemoteEvent
local reloadWeaponRemote: RemoteEvent
local switchWeaponRemote: RemoteEvent
local setFireModeRemote: RemoteEvent
local updatePostureRemote: UnreliableRemoteEvent
local bulletReplicatedRemote: UnreliableRemoteEvent
local hitConfirmRemote: RemoteEvent
local damageTakenRemote: RemoteEvent
local suppressionRemote: UnreliableRemoteEvent
local ammoSyncRemote: RemoteEvent
local throwGrenadeRemote: RemoteEvent
local grenadeReplicatedRemote: RemoteEvent
local grenadeDetonatedRemote: RemoteEvent
local grenadeSyncRemote: RemoteEvent
local flashbangEffectRemote: RemoteEvent

local playerStates: { [Player]: PlayerCombatState } = {}
local activeProjectiles: { ActiveServerProjectile } = {}
local activeGrenades: { ActiveServerGrenade } = {}
local nextGrenadeId = 1
local heartbeatConnection: RBXScriptConnection? = nil

local function createSlotState(weaponId: string): SlotWeaponState
	local def = WeaponConfig.GetWeapon(weaponId) or WeaponConfig.GetWeapon(WeaponConfig.DEFAULT_PRIMARY) :: WeaponConfig.WeaponDefinition
	return {
		WeaponId = def.Id,
		Magazine = def.MagazineSize,
		Reserve = def.MagazineSize * def.ReserveMagazines,
		FireMode = def.DefaultFireMode,
	}
end

local function getActiveSlotState(state: PlayerCombatState): SlotWeaponState
	if state.ActiveSlot == "Secondary" then
		return state.Secondary
	end
	return state.Primary
end

local function syncAmmo(player: Player, state: PlayerCombatState, reloadDuration: number?): ()
	local slotState = getActiveSlotState(state)
	local payload: NetworkTypes.AmmoSyncPayload = {
		Slot = state.ActiveSlot,
		WeaponId = slotState.WeaponId,
		Magazine = slotState.Magazine,
		Reserve = slotState.Reserve,
		FireMode = slotState.FireMode,
		IsReloading = state.IsReloading,
		ReloadDuration = reloadDuration,
	}
	ammoSyncRemote:FireClient(player, payload)
end

local function syncGrenades(player: Player, state: PlayerCombatState): ()
	local payload: NetworkTypes.GrenadeSyncPayload = {
		Frag = state.FragCount,
		Flash = state.FlashCount,
	}
	grenadeSyncRemote:FireClient(player, payload)
end

local function destroyEquippedModel(state: PlayerCombatState): ()
	if state.EquippedModel then
		state.EquippedModel:Destroy()
		state.EquippedModel = nil
	end
end

local function equipThirdPersonWeapon(character: Model, state: PlayerCombatState, weaponId: string): ()
	destroyEquippedModel(state)

	local weaponsFolder = ReplicatedStorage:FindFirstChild(NetworkTypes.WEAPONS_FOLDER_NAME)
	if not weaponsFolder then
		return
	end
	local template = weaponsFolder:FindFirstChild(weaponId)
	if not template or not template:IsA("Model") then
		return
	end

	local hand = character:FindFirstChild("RightHand") or character:FindFirstChild("Right Arm")
	if not hand or not hand:IsA("BasePart") then
		return
	end

	local clone = template:Clone()
	clone.Name = "EquippedWeaponModel"
	local handle = clone.PrimaryPart or clone:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		clone:Destroy()
		return
	end
	clone.PrimaryPart = handle

	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = false
			desc.CanCollide = false
			desc.CanQuery = false
			desc.Massless = true
		end
	end

	local gripOffset = if hand.Name == "RightHand"
		then CFrame.new(0, -0.08, -0.28) * CFrame.Angles(math.rad(-90), 0, 0)
		else CFrame.new(0, -1.0, -0.35) * CFrame.Angles(math.rad(-90), 0, 0)

	clone:PivotTo(hand.CFrame * gripOffset)

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = hand
	weld.Part1 = handle
	weld.Parent = handle

	clone.Parent = character
	state.EquippedModel = clone
end

local function cancelReload(player: Player, state: PlayerCombatState): ()
	if not state.IsReloading then
		return
	end
	state.IsReloading = false
	state.ReloadToken += 1
	syncAmmo(player, state, nil)
end

local function resolveSafeOrigin(character: Model, headPos: Vector3, claimedOrigin: Vector3): Vector3?
	if (claimedOrigin - headPos).Magnitude > MAX_ORIGIN_OFFSET_FROM_HEAD then
		return nil
	end

	local delta = claimedOrigin - headPos
	if delta.Magnitude < 0.05 then
		return claimedOrigin
	end

	local losParams = RaycastParams.new()
	losParams.IgnoreWater = true
	losParams.RespectCanCollide = false

	local excludes: { Instance } = { character }
	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer.Character and otherPlayer.Character ~= character then
			table.insert(excludes, otherPlayer.Character)
		end
	end
	losParams.ExcludeInstances = excludes

	local obstruction = Workspace:Raycast(headPos, delta, losParams)
	if obstruction then
		-- Prevent firing from behind walls by clamping origin back to server head position.
		return headPos
	end

	return claimedOrigin
end

local function handleFireWeapon(player: Player, rawPayload: unknown): ()
	if not gameLoopService.IsMatchActive() then
		return
	end
	if typeof(rawPayload) ~= "table" then
		return
	end

	local state = playerStates[player]
	if not state or state.IsReloading then
		return
	end

	local character = player.Character
	if not character or character ~= state.Character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local head = character:FindFirstChild("Head")
	if not humanoid or humanoid.Health <= 0 or not head or not head:IsA("BasePart") then
		return
	end

	local payload = rawPayload :: { [string]: unknown }
	local slotState = getActiveSlotState(state)
	if typeof(payload.WeaponId) ~= "string" or payload.WeaponId ~= slotState.WeaponId then
		return
	end

	local weaponDef = WeaponConfig.GetWeapon(slotState.WeaponId)
	if not weaponDef then
		return
	end

	if not NetworkTypes.IsFiniteVector3(payload.Origin) then
		return
	end
	local dir = NetworkTypes.SanitizeUnitDirection(payload.Direction)
	if not dir then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local minInterval = (60 / weaponDef.RPM) * FIRE_RATE_TOLERANCE
	if now - state.LastFireTime < minInterval then
		return
	end

	if slotState.Magazine <= 0 then
		syncAmmo(player, state, nil)
		return
	end

	local safeOrigin = resolveSafeOrigin(character, head.Position, payload.Origin :: Vector3)
	if not safeOrigin then
		return
	end

	slotState.Magazine -= 1
	state.LastFireTime = now
	state.SpawnProtectedUntil = 0
	syncAmmo(player, state, nil)

	local initialVelocity = dir * weaponDef.MuzzleVelocity
	local rayParams = RaycastParams.new()
	rayParams.IgnoreWater = true
	rayParams.RespectCanCollide = false

	local projState = Ballistics.CreateProjectile({
		WeaponId = weaponDef.Id,
		Origin = safeOrigin,
		Velocity = initialVelocity,
		BaseDamage = weaponDef.BaseDamage,
		MinDamageMultiplier = weaponDef.MinDamageMultiplier,
		DamageDropStart = weaponDef.DamageDropStart,
		DamageDropEnd = weaponDef.DamageDropEnd,
		GravityMultiplier = weaponDef.GravityMultiplier,
		DragCoefficient = weaponDef.DragCoefficient,
		MaxRange = weaponDef.MaxRange,
		PenetrationPower = weaponDef.PenetrationPower,
		ExcludeInstances = { character },
	})

	table.insert(activeProjectiles, {
		Shooter = player,
		InitialOrigin = safeOrigin,
		SuppressionRadius = weaponDef.SuppressionRadius,
		State = projState,
		RayParams = rayParams,
		SuppressedPlayers = {},
	})

	local tracerPayload: NetworkTypes.ReplicatedTracerPayload = {
		ShooterUserId = player.UserId,
		WeaponId = weaponDef.Id,
		Origin = safeOrigin,
		Velocity = initialVelocity,
		GravityMultiplier = weaponDef.GravityMultiplier,
		DragCoefficient = weaponDef.DragCoefficient,
		MaxRange = weaponDef.MaxRange,
		PenetrationPower = weaponDef.PenetrationPower,
	}

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= player then
			bulletReplicatedRemote:FireClient(otherPlayer, tracerPayload)
		end
	end
end

local function handleReloadWeapon(player: Player, rawPayload: unknown): ()
	if typeof(rawPayload) ~= "table" then
		return
	end
	local state = playerStates[player]
	if not state then
		return
	end
	local character = player.Character
	if not character or character ~= state.Character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local payload = rawPayload :: { [string]: unknown }
	local slotState = getActiveSlotState(state)
	if payload.Action == "Cancel" then
		cancelReload(player, state)
		return
	end
	if payload.Action ~= "Start" or state.IsReloading then
		return
	end

	local weaponDef = WeaponConfig.GetWeapon(slotState.WeaponId)
	if not weaponDef or slotState.Reserve <= 0 then
		return
	end

	local isEmpty = slotState.Magazine <= 0
	local targetCapacity = weaponDef.MagazineSize
	if weaponDef.ChamberSupported and not isEmpty then
		targetCapacity += 1
	end

	if slotState.Magazine >= targetCapacity then
		return
	end

	local reloadTime = if isEmpty then weaponDef.EmptyReloadTime else weaponDef.TacticalReloadTime
	state.IsReloading = true
	state.ReloadToken += 1
	local expectedToken = state.ReloadToken

	syncAmmo(player, state, reloadTime)

	task.delay(reloadTime, function()
		local currentState = playerStates[player]
		if not currentState or currentState ~= state then
			return
		end
		if not currentState.IsReloading or currentState.ReloadToken ~= expectedToken then
			return
		end
		if player.Character ~= character or humanoid.Health <= 0 then
			return
		end

		local activeSlot = getActiveSlotState(currentState)
		if activeSlot ~= slotState then
			return
		end

		local stillEmpty = activeSlot.Magazine <= 0
		local maxAllowed = weaponDef.MagazineSize
		if weaponDef.ChamberSupported and not stillEmpty then
			maxAllowed += 1
		end

		local needed = math.max(0, maxAllowed - activeSlot.Magazine)
		local transferred = math.min(needed, activeSlot.Reserve)
		activeSlot.Magazine += transferred
		activeSlot.Reserve -= transferred
		currentState.IsReloading = false
		syncAmmo(player, currentState, nil)
	end)
end

local function handleSwitchWeapon(player: Player, rawPayload: unknown): ()
	if typeof(rawPayload) ~= "table" then
		return
	end
	local state = playerStates[player]
	if not state then
		return
	end
	local character = player.Character
	if not character or character ~= state.Character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local payload = rawPayload :: { [string]: unknown }
	local requestedSlot = payload.Slot
	if requestedSlot ~= "Primary" and requestedSlot ~= "Secondary" then
		return
	end
	if state.ActiveSlot == requestedSlot then
		return
	end

	cancelReload(player, state)
	state.ActiveSlot = requestedSlot :: WeaponSlot
	local slotState = getActiveSlotState(state)
	equipThirdPersonWeapon(character, state, slotState.WeaponId)
	syncAmmo(player, state, nil)
end

local function handleSetFireMode(player: Player, rawPayload: unknown): ()
	if typeof(rawPayload) ~= "table" then
		return
	end
	local state = playerStates[player]
	if not state then
		return
	end

	local payload = rawPayload :: { [string]: unknown }
	local slotState = getActiveSlotState(state)
	if payload.WeaponId ~= slotState.WeaponId then
		return
	end

	local weaponDef = WeaponConfig.GetWeapon(slotState.WeaponId)
	if not weaponDef then
		return
	end

	local requestedMode = payload.FireMode
	if requestedMode ~= "Auto" and requestedMode ~= "Semi" then
		return
	end
	if table.find(weaponDef.FireModes, requestedMode :: FireMode) == nil then
		return
	end

	slotState.FireMode = requestedMode :: FireMode
	syncAmmo(player, state, nil)
end

local function handleUpdatePosture(player: Player, rawPayload: unknown): ()
	if typeof(rawPayload) ~= "table" then
		return
	end
	local character = player.Character
	if not character then
		return
	end
	local payload = rawPayload :: { [string]: unknown }
	if typeof(payload.IsCrouching) == "boolean" then
		character:SetAttribute("IsCrouching", payload.IsCrouching)
	end
	if NetworkTypes.IsFiniteNumber(payload.LeanDirection) then
		local lean = math.clamp(math.round(payload.LeanDirection :: number), -1, 1)
		character:SetAttribute("LeanDirection", lean)
	end
end

local function checkSuppressionForSegments(proj: ActiveServerProjectile, segments: { Ballistics.Segment }): ()
	if #segments == 0 or proj.SuppressionRadius <= 0 then
		return
	end

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		if otherPlayer ~= proj.Shooter and not proj.SuppressedPlayers[otherPlayer] then
			local character = otherPlayer.Character
			if character then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				local head = character:FindFirstChild("Head")
				if humanoid and humanoid.Health > 0 and head and head:IsA("BasePart") then
					for _, seg in ipairs(segments) do
						local closest, dist = Ballistics.ClosestPointOnSegment(seg.Start, seg.End, head.Position)
						if dist <= proj.SuppressionRadius then
							proj.SuppressedPlayers[otherPlayer] = true
							local intensity = math.clamp(1 - (dist / proj.SuppressionRadius), 0.18, 1.0)
							local supPayload: NetworkTypes.SuppressionPayload = {
								Intensity = intensity,
								ClosestPoint = closest,
							}
							suppressionRemote:FireClient(otherPlayer, supPayload)
							break
						end
					end
				end
			end
		end
	end
end

local function processImpact(proj: ActiveServerProjectile, impact: Ballistics.ImpactEvent): ()
	if impact.Kind ~= "Character" or not impact.Character or not impact.Humanoid then
		return
	end

	local victimChar = impact.Character
	local victimHumanoid = impact.Humanoid
	if victimHumanoid.Health <= 0 then
		return
	end

	local victimPlayer = Players:GetPlayerFromCharacter(victimChar)
	local now = Workspace:GetServerTimeNow()
	if victimPlayer then
		local victimState = playerStates[victimPlayer]
		if victimState and now < victimState.SpawnProtectedUntil then
			return
		end
	end

	victimHumanoid:TakeDamage(impact.Damage)
	local isFatal = victimHumanoid.Health <= 0

	if proj.Shooter.Parent == Players then
		local confirmPayload: NetworkTypes.HitConfirmPayload = {
			TargetUserId = if victimPlayer then victimPlayer.UserId else 0,
			Zone = impact.HitZone or "Torso",
			Damage = impact.Damage,
			IsFatal = isFatal,
			IsWallbang = impact.IsWallbang,
			Distance = math.round(impact.Distance),
		}
		hitConfirmRemote:FireClient(proj.Shooter, confirmPayload)
	end

	if victimPlayer and victimPlayer.Parent == Players then
		local damagePayload: NetworkTypes.DamageTakenPayload = {
			DirectionOrigin = proj.InitialOrigin,
			Damage = impact.Damage,
			Health = math.max(0, victimHumanoid.Health),
			MaxHealth = victimHumanoid.MaxHealth,
		}
		damageTakenRemote:FireClient(victimPlayer, damagePayload)

		if isFatal and not victimChar:GetAttribute("KillRecorded") then
			victimChar:SetAttribute("KillRecorded", true)
			gameLoopService.RecordKill(
				proj.Shooter,
				victimPlayer,
				proj.State.WeaponId,
				impact.HitZone == "Head",
				impact.IsWallbang,
				impact.Distance
			)
		end
	end
end

local function buildEnvironmentRayParams(): RaycastParams
	local params = RaycastParams.new()
	params.IgnoreWater = true
	params.RespectCanCollide = true
	local excludes: { Instance } = {}
	for _, player in ipairs(Players:GetPlayers()) do
		if player.Character then
			table.insert(excludes, player.Character)
		end
	end
	params.ExcludeInstances = excludes
	return params
end

local function traceShrapnelFactor(origin: Vector3, targetPoint: Vector3, baseParams: RaycastParams): (number, boolean)
	local delta = targetPoint - origin
	local dist = delta.Magnitude
	if dist < 0.2 then
		return 1.0, false
	end

	local dir = delta / dist
	local hit = Workspace:Raycast(origin, delta, baseParams)
	if not hit then
		return 1.0, false
	end

	local resistance = Ballistics.GetMaterialResistance(hit.Material)
	if hit.Material == Enum.Material.Glass then
		return 0.85, true
	end
	if resistance > 1.65 then
		return 0, false
	end

	-- Probe exit thickness for thin soft cover (wood, plaster, cardboard)
	local maxThickness = 1.8
	local exitParams = RaycastParams.new()
	exitParams.FilterType = Enum.RaycastFilterType.Include
	exitParams.FilterDescendantsInstances = { hit.Instance }
	local probeEnd = hit.Position + dir * maxThickness
	if (hit.Position - origin).Magnitude + maxThickness >= dist then
		return 0.5, true
	end

	local exitHit = Workspace:Raycast(probeEnd, -dir * maxThickness, exitParams)
	if not exitHit then
		return 0, false
	end
	local thickness = (exitHit.Position - hit.Position).Magnitude
	if thickness <= maxThickness then
		return 0.5, true
	end
	return 0, false
end

local function hasFlashLineOfSight(origin: Vector3, headPos: Vector3, baseParams: RaycastParams): boolean
	local cursor = origin
	for _skip = 1, 4 do
		local delta = headPos - cursor
		if delta.Magnitude < 0.15 then
			return true
		end
		local hit = Workspace:Raycast(cursor, delta, baseParams)
		if not hit then
			return true
		end
		if hit.Material ~= Enum.Material.Glass then
			return false
		end
		cursor = hit.Position + delta.Unit * 0.15
	end
	return false
end

local function detonateFrag(g: ActiveServerGrenade): ()
	local def = g.Def
	local blastOrigin = g.Position + Vector3.new(0, 0.35, 0)
	local envParams = buildEnvironmentRayParams()
	local now = Workspace:GetServerTimeNow()

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		local character = otherPlayer.Character
		if not character then
			continue
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local root = character:FindFirstChild("HumanoidRootPart")
		local head = character:FindFirstChild("Head")
		if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
			continue
		end

		local dist = (root.Position - g.Position).Magnitude
		if dist <= def.SuppressionRadius then
			local supIntensity = math.clamp(1 - (dist / def.SuppressionRadius), 0.25, 1.0)
			suppressionRemote:FireClient(otherPlayer, {
				Intensity = supIntensity,
				ClosestPoint = g.Position,
			} :: NetworkTypes.SuppressionPayload)
		end

		if dist > def.OuterRadius then
			continue
		end

		local victimState = playerStates[otherPlayer]
		if victimState and now < victimState.SpawnProtectedUntil then
			continue
		end

		local factor1, wb1 = traceShrapnelFactor(blastOrigin, root.Position, envParams)
		local factor2, wb2 = 0, false
		if head and head:IsA("BasePart") then
			factor2, wb2 = traceShrapnelFactor(blastOrigin, head.Position, envParams)
		end

		local bestFactor = math.max(factor1, factor2)
		if bestFactor <= 0 then
			continue
		end
		local isWallbang = if factor2 > factor1 then wb2 else wb1

		local distFactor = if dist <= def.InnerRadius
			then 1.0
			else math.pow(1 - (dist - def.InnerRadius) / math.max(def.OuterRadius - def.InnerRadius, 1), 1.35)
		local damage = math.round((def.MinDamage + (def.MaxDamage - def.MinDamage) * distFactor) * bestFactor)
		if damage < 1 then
			continue
		end

		humanoid:TakeDamage(damage)
		local isFatal = humanoid.Health <= 0

		if g.Thrower.Parent == Players and g.Thrower ~= otherPlayer then
			local confirmPayload: NetworkTypes.HitConfirmPayload = {
				TargetUserId = otherPlayer.UserId,
				Zone = "Torso",
				Damage = damage,
				IsFatal = isFatal,
				IsWallbang = isWallbang,
				Distance = math.round(dist),
			}
			hitConfirmRemote:FireClient(g.Thrower, confirmPayload)
		end

		local damagePayload: NetworkTypes.DamageTakenPayload = {
			DirectionOrigin = g.Position,
			Damage = damage,
			Health = math.max(0, humanoid.Health),
			MaxHealth = humanoid.MaxHealth,
		}
		damageTakenRemote:FireClient(otherPlayer, damagePayload)

		if isFatal and not character:GetAttribute("KillRecorded") then
			character:SetAttribute("KillRecorded", true)
			local killerArg = if g.Thrower.Parent == Players then g.Thrower else nil
			gameLoopService.RecordKill(killerArg, otherPlayer, def.ShortName, false, isWallbang, dist)
		end
	end
end

local function detonateFlash(g: ActiveServerGrenade): ()
	local def = g.Def
	local flashOrigin = g.Position + Vector3.new(0, 0.35, 0)
	local envParams = buildEnvironmentRayParams()

	for _, otherPlayer in ipairs(Players:GetPlayers()) do
		local character = otherPlayer.Character
		if not character then
			continue
		end
		local humanoid = character:FindFirstChildOfClass("Humanoid")
		local head = character:FindFirstChild("Head")
		if not humanoid or humanoid.Health <= 0 or not head or not head:IsA("BasePart") then
			continue
		end

		local dist = (head.Position - g.Position).Magnitude
		if dist > def.OuterRadius then
			continue
		end

		if hasFlashLineOfSight(flashOrigin, head.Position, envParams) then
			local distFactor = math.clamp(1 - (dist / def.OuterRadius) * 0.72, 0.25, 1.0)
			local payload: NetworkTypes.FlashbangEffectPayload = {
				Origin = g.Position,
				Distance = dist,
				DistanceFactor = distFactor,
				MaxDuration = def.MaxBlindDuration,
				InnerStunRadius = def.InnerRadius,
			}
			flashbangEffectRemote:FireClient(otherPlayer, payload)
		elseif dist <= def.InnerRadius then
			suppressionRemote:FireClient(otherPlayer, {
				Intensity = 0.45,
				ClosestPoint = g.Position,
			} :: NetworkTypes.SuppressionPayload)
		end
	end
end

local function stepAllGrenades(dt: number): ()
	local now = Workspace:GetServerTimeNow()
	local i = #activeGrenades
	while i >= 1 do
		local g = activeGrenades[i]
		local newPos, newVel = GrenadeConfig.StepGrenadeMotion(g.Position, g.Velocity, dt, g.Def, g.RayParams)
		g.Position = newPos
		g.Velocity = newVel

		if now >= g.DetonateAt then
			local last = #activeGrenades
			activeGrenades[i] = activeGrenades[last]
			activeGrenades[last] = nil

			grenadeDetonatedRemote:FireAllClients({
				GrenadeId = g.Id,
				GrenadeType = g.Def.Type,
				Position = g.Position,
			} :: NetworkTypes.GrenadeDetonatedPayload)

			if g.Def.Type == "Frag" then
				detonateFrag(g)
			else
				detonateFlash(g)
			end
		end

		i -= 1
	end
end

local function handleThrowGrenade(player: Player, rawPayload: unknown): ()
	if not gameLoopService.IsMatchActive() then
		return
	end
	if typeof(rawPayload) ~= "table" then
		return
	end

	local state = playerStates[player]
	if not state then
		return
	end
	local character = player.Character
	if not character or character ~= state.Character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local head = character:FindFirstChild("Head")
	if not humanoid or humanoid.Health <= 0 or not head or not head:IsA("BasePart") then
		return
	end

	local now = Workspace:GetServerTimeNow()
	if now - state.LastThrowTime < GrenadeConfig.POST_THROW_COOLDOWN * 0.85 then
		return
	end

	local payload = rawPayload :: { [string]: unknown }
	local rawType = payload.GrenadeType
	if rawType ~= "Frag" and rawType ~= "Flash" then
		return
	end
	local gType = rawType :: NetworkTypes.GrenadeType
	local def = GrenadeConfig.GetGrenade(gType)
	if not def then
		return
	end

	if gType == "Frag" then
		if state.FragCount <= 0 then
			syncGrenades(player, state)
			return
		end
		state.FragCount -= 1
	else
		if state.FlashCount <= 0 then
			syncGrenades(player, state)
			return
		end
		state.FlashCount -= 1
	end

	if not NetworkTypes.IsFiniteVector3(payload.Origin) then
		return
	end
	local dir = NetworkTypes.SanitizeUnitDirection(payload.Direction)
	if not dir then
		return
	end

	local safeOrigin = resolveSafeOrigin(character, head.Position, payload.Origin :: Vector3)
	if not safeOrigin then
		safeOrigin = head.Position + dir * 0.8
	end

	cancelReload(player, state)
	state.LastThrowTime = now
	syncGrenades(player, state)

	local initialVelocity = dir * def.ThrowSpeed + Vector3.new(0, def.UpwardBoost, 0)
	local grenadeId = nextGrenadeId
	nextGrenadeId += 1

	table.insert(activeGrenades, {
		Id = grenadeId,
		Thrower = player,
		Def = def,
		Position = safeOrigin,
		Velocity = initialVelocity,
		DetonateAt = now + def.FuseTime,
		RayParams = buildEnvironmentRayParams(),
	})

	local repPayload: NetworkTypes.ReplicatedGrenadePayload = {
		GrenadeId = grenadeId,
		ThrowerUserId = player.UserId,
		GrenadeType = gType,
		Origin = safeOrigin,
		Velocity = initialVelocity,
		FuseTime = def.FuseTime,
	}
	grenadeReplicatedRemote:FireAllClients(repPayload)
end

local function stepAllProjectiles(dt: number): ()
	local index = #activeProjectiles
	while index >= 1 do
		local proj = activeProjectiles[index]
		local stepResult = Ballistics.StepProjectile(proj.State, dt, proj.RayParams)

		checkSuppressionForSegments(proj, stepResult.Segments)

		for _, impact in ipairs(stepResult.Impacts) do
			processImpact(proj, impact)
		end

		if not stepResult.Alive then
			local last = #activeProjectiles
			activeProjectiles[index] = activeProjectiles[last]
			activeProjectiles[last] = nil
		end

		index -= 1
	end

	stepAllGrenades(dt)
end

function CombatService.ClearAllProjectiles(): ()
	table.clear(activeProjectiles)
	table.clear(activeGrenades)
end

function CombatService.OnPlayerSpawned(player: Player, character: Model, loadout: LoadoutSelection): ()
	local state: PlayerCombatState = {
		Character = character,
		Primary = createSlotState(loadout.Primary),
		Secondary = createSlotState(loadout.Secondary),
		ActiveSlot = "Primary",
		IsReloading = false,
		ReloadToken = 0,
		LastFireTime = 0,
		LastThrowTime = 0,
		FragCount = GrenadeConfig.Grenades.Frag.StartingCount,
		FlashCount = GrenadeConfig.Grenades.Flash.StartingCount,
		SpawnProtectedUntil = Workspace:GetServerTimeNow() + SPAWN_PROTECTION_SECONDS,
		EquippedModel = nil,
	}
	playerStates[player] = state

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.MaxHealth = WeaponConfig.DEFAULT_MAX_HEALTH
		humanoid.Health = WeaponConfig.DEFAULT_MAX_HEALTH

		humanoid.Died:Connect(function()
			state.IsReloading = false
			state.ReloadToken += 1
			if not character:GetAttribute("KillRecorded") then
				character:SetAttribute("KillRecorded", true)
				gameLoopService.RecordKill(nil, player, "Environment", false, false, 0)
			end
		end)
	end

	equipThirdPersonWeapon(character, state, state.Primary.WeaponId)
	syncAmmo(player, state, nil)
	syncGrenades(player, state)
end

function CombatService.CleanupPlayerCharacter(player: Player): ()
	local state = playerStates[player]
	if state then
		state.IsReloading = false
		state.ReloadToken += 1
		destroyEquippedModel(state)
		playerStates[player] = nil
	end
end

function CombatService.Init(gameLoopSvc: GameLoopServiceModule, _spawnSvc: unknown): ()
	gameLoopService = gameLoopSvc

	fireWeaponRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.FireWeapon)
	reloadWeaponRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.ReloadWeapon)
	switchWeaponRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.SwitchWeapon)
	setFireModeRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.SetFireMode)
	updatePostureRemote = NetworkTypes.GetUnreliableRemoteEvent(NetworkTypes.RemoteNames.UpdatePosture)
	bulletReplicatedRemote = NetworkTypes.GetUnreliableRemoteEvent(NetworkTypes.RemoteNames.BulletReplicated)
	hitConfirmRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.HitConfirm)
	damageTakenRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.DamageTaken)
	suppressionRemote = NetworkTypes.GetUnreliableRemoteEvent(NetworkTypes.RemoteNames.Suppression)
	ammoSyncRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.AmmoSync)
	throwGrenadeRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.ThrowGrenade)
	grenadeReplicatedRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.GrenadeReplicated)
	grenadeDetonatedRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.GrenadeDetonated)
	grenadeSyncRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.GrenadeSync)
	flashbangEffectRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.FlashbangEffect)

	fireWeaponRemote.OnServerEvent:Connect(handleFireWeapon)
	reloadWeaponRemote.OnServerEvent:Connect(handleReloadWeapon)
	switchWeaponRemote.OnServerEvent:Connect(handleSwitchWeapon)
	setFireModeRemote.OnServerEvent:Connect(handleSetFireMode)
	updatePostureRemote.OnServerEvent:Connect(handleUpdatePosture)
	throwGrenadeRemote.OnServerEvent:Connect(handleThrowGrenade)

	if heartbeatConnection then
		heartbeatConnection:Disconnect()
	end
	heartbeatConnection = RunService.Heartbeat:Connect(stepAllProjectiles)
end

return CombatService
