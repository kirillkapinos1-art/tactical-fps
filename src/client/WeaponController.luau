--!strict
-- Client weapon controller: Auto/Semi firing, tactical/empty reload & hold-R mag check,
-- camera recoil springs + spray pattern, spread, spatial audio, and projectile tracer/impact VFX.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local SoundService = game:GetService("SoundService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Ballistics = require(Shared.Ballistics)
local GrenadeConfig = require(Shared.GrenadeConfig)
local NetworkTypes = require(Shared.NetworkTypes)
local Spring = require(Shared.Spring)
local WeaponConfig = require(Shared.WeaponConfig)

local HUDController = require(script.Parent.HUDController)
local MovementController = require(script.Parent.MovementController)
local ViewmodelController = require(script.Parent.ViewmodelController)

type WeaponSlot = NetworkTypes.WeaponSlot
type FireMode = NetworkTypes.FireMode
type GrenadeType = NetworkTypes.GrenadeType

type LocalSlotState = {
	WeaponId: string,
	Magazine: number,
	Reserve: number,
	FireMode: FireMode,
}

type VisualProjectile = {
	State: Ballistics.ProjectileState,
	RayParams: RaycastParams,
	MuzzleOrigin: Vector3?,
	IsFirstSegment: boolean,
}

type EphemeralVisual = {
	Part: BasePart,
	CreatedAt: number,
	Lifetime: number,
	InitialTransparency: number,
}

type ClientGrenadeVisual = {
	Id: number,
	Def: GrenadeConfig.GrenadeDefinition,
	Model: Model,
	Position: Vector3,
	Velocity: Vector3,
	SpinAngle: Vector3,
	SpinRate: Vector3,
	ExpiresAt: number,
	LastBounceSoundAt: number,
	RayParams: RaycastParams,
}

type ExplosionDebris = {
	Part: BasePart,
	Position: Vector3,
	Velocity: Vector3,
	CreatedAt: number,
	Lifetime: number,
	InitialTransparency: number,
	GrowRate: number,
}

local WeaponController = {}

local MAG_CHECK_HOLD_SECONDS = 0.24
local TRACER_LIFETIME = 0.085
local IMPACT_HOLE_LIFETIME = 10.0

local localPlayer = Players.LocalPlayer

local fireWeaponRemote: RemoteEvent
local reloadWeaponRemote: RemoteEvent
local switchWeaponRemote: RemoteEvent
local setFireModeRemote: RemoteEvent
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

local cameraRecoilSpring = Spring.new(1, 185, 21, 1, Vector3.zero)
local suppressionShakeSpring = Spring.fromFrequency(0.6, 14, 1, Vector3.zero)
local persistentRecoil = Vector2.zero -- X = yaw rad, Y = pitch rad

local activeSlot: WeaponSlot = "Primary"
local slots: { [WeaponSlot]: LocalSlotState } = {
	Primary = { WeaponId = WeaponConfig.DEFAULT_PRIMARY, Magazine = 30, Reserve = 120, FireMode = "Auto" },
	Secondary = { WeaponId = WeaponConfig.DEFAULT_SECONDARY, Magazine = 12, Reserve = 60, FireMode = "Semi" },
}
local grenadeCounts: { [GrenadeType]: number } = {
	Frag = GrenadeConfig.Grenades.Frag.StartingCount,
	Flash = GrenadeConfig.Grenades.Flash.StartingCount,
}

local isEquippedAndAlive = false
local isMenuBlocking = true
local isReloading = false
local isTriggerHeld = false
local semiShotConsumed = false
local lastShotTime = 0
local sprayIndex = 0
local fireSequence = 0

local rKeyDown = false
local rPressStartedAt = 0
local rCheckTriggered = false

local pendingGrenadeType: GrenadeType? = nil
local prepStartedAt = 0
local prepKeyDown = false
local lastThrowEndAt = 0

local visualFolder: Folder
local activeTracers: { VisualProjectile } = {}
local ephemeralVisuals: { EphemeralVisual } = {}
local activeClientGrenades: { [number]: ClientGrenadeVisual } = {}
local explosionDebris: { ExplosionDebris } = {}
local spreadRng = Random.new()

local function getActiveSlotState(): LocalSlotState
	return slots[activeSlot]
end

local function ensureVisualFolder(): Folder
	local existing = Workspace:FindFirstChild("__ClientBallisticsVFX")
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = "__ClientBallisticsVFX"
	folder.Parent = Workspace
	return folder
end

local function playSound2D(soundId: string, volume: number, pitch: number): ()
	if soundId == "" then
		return
	end
	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.PlaybackSpeed = pitch * spreadRng:NextNumber(0.96, 1.04)
	sound.Parent = SoundService
	sound:Play()
	sound.Ended:Connect(function()
		sound:Destroy()
	end)
	task.delay(3.5, function()
		if sound.Parent then
			sound:Destroy()
		end
	end)
end

local function playSound3D(soundId: string, position: Vector3, volume: number, pitch: number, maxDist: number): ()
	if soundId == "" then
		return
	end
	local anchor = Instance.new("Part")
	anchor.Name = "SoundEmitter"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.2, 0.2, 0.2)
	anchor.Position = position
	anchor.Parent = visualFolder

	local sound = Instance.new("Sound")
	sound.SoundId = soundId
	sound.Volume = volume
	sound.PlaybackSpeed = pitch * spreadRng:NextNumber(0.95, 1.05)
	sound.RollOffMode = Enum.RollOffMode.InverseTapered
	sound.RollOffMinDistance = 16
	sound.RollOffMaxDistance = maxDist
	sound.Parent = anchor
	sound:Play()

	task.delay(3.5, function()
		if anchor.Parent then
			anchor:Destroy()
		end
	end)
end

local function spawnTracerBeam(startPos: Vector3, endPos: Vector3): ()
	local delta = endPos - startPos
	local dist = delta.Magnitude
	if dist < 0.25 then
		return
	end

	local beam = Instance.new("Part")
	beam.Name = "Tracer"
	beam.Anchored = true
	beam.CanCollide = false
	beam.CanQuery = false
	beam.CastShadow = false
	beam.Material = Enum.Material.Neon
	beam.Color = Color3.fromRGB(255, 224, 150)
	beam.Transparency = 0.22
	beam.Size = Vector3.new(0.055, 0.055, dist)
	beam.CFrame = CFrame.lookAt((startPos + endPos) * 0.5, endPos)
	beam.Parent = visualFolder

	table.insert(ephemeralVisuals, {
		Part = beam,
		CreatedAt = os.clock(),
		Lifetime = TRACER_LIFETIME,
		InitialTransparency = 0.22,
	})
end

local function spawnSurfaceImpact(pos: Vector3, normal: Vector3, material: Enum.Material, isWallbangExit: boolean): ()
	local hole = Instance.new("Part")
	hole.Name = if isWallbangExit then "ExitHole" else "ImpactHole"
	hole.Anchored = true
	hole.CanCollide = false
	hole.CanQuery = false
	hole.CastShadow = false
	hole.Material = Enum.Material.SmoothPlastic
	hole.Color = Color3.fromRGB(24, 24, 24)
	hole.Transparency = 0.15
	hole.Size = Vector3.new(0.24, 0.24, 0.04)
	hole.CFrame = CFrame.lookAt(pos + normal * 0.02, pos + normal * 1.02)
	hole.Parent = visualFolder

	local emitter = Instance.new("ParticleEmitter")
	emitter.Lifetime = NumberRange.new(0.18, 0.35)
	emitter.Speed = NumberRange.new(8, 22)
	emitter.SpreadAngle = Vector2.new(55, 55)
	emitter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.22),
		NumberSequenceKeypoint.new(1, 0.02),
	})
	emitter.Rate = 0
	if material == Enum.Material.Metal or material == Enum.Material.CorrodedMetal or material == Enum.Material.DiamondPlate then
		emitter.Color = ColorSequence.new(Color3.fromRGB(255, 215, 110))
		emitter.LightEmission = 1
	elseif material == Enum.Material.Glass then
		emitter.Color = ColorSequence.new(Color3.fromRGB(210, 238, 255))
	elseif material == Enum.Material.Wood or material == Enum.Material.WoodPlanks then
		emitter.Color = ColorSequence.new(Color3.fromRGB(168, 130, 88))
	else
		emitter.Color = ColorSequence.new(Color3.fromRGB(185, 185, 185))
	end
	emitter.Parent = hole
	emitter:Emit(if isWallbangExit then 6 else 10)

	table.insert(ephemeralVisuals, {
		Part = hole,
		CreatedAt = os.clock(),
		Lifetime = IMPACT_HOLE_LIFETIME,
		InitialTransparency = 0.15,
	})
end

local function spawnVisualProjectile(
	weaponDef: WeaponConfig.WeaponDefinition,
	origin: Vector3,
	velocity: Vector3,
	muzzleOrigin: Vector3?,
	excludeInstances: { Instance }
): ()
	local rayParams = RaycastParams.new()
	rayParams.IgnoreWater = true
	rayParams.RespectCanCollide = false

	local state = Ballistics.CreateProjectile({
		WeaponId = weaponDef.Id,
		Origin = origin,
		Velocity = velocity,
		BaseDamage = weaponDef.BaseDamage,
		MinDamageMultiplier = weaponDef.MinDamageMultiplier,
		DamageDropStart = weaponDef.DamageDropStart,
		DamageDropEnd = weaponDef.DamageDropEnd,
		GravityMultiplier = weaponDef.GravityMultiplier,
		DragCoefficient = weaponDef.DragCoefficient,
		MaxRange = weaponDef.MaxRange,
		PenetrationPower = weaponDef.PenetrationPower,
		ExcludeInstances = excludeInstances,
	})

	table.insert(activeTracers, {
		State = state,
		RayParams = rayParams,
		MuzzleOrigin = muzzleOrigin,
		IsFirstSegment = true,
	})
end

local function applyWeaponRecoil(def: WeaponConfig.WeaponDefinition, adsAlpha: number, isCrouching: boolean): ()
	local now = os.clock()
	if now - lastShotTime <= 0.35 then
		sprayIndex += 1
	else
		sprayIndex = 1
	end

	local scale = (1 + (def.AdsRecoilMultiplier - 1) * adsAlpha)
		* (if isCrouching then def.CrouchRecoilMultiplier else 1.0)

	local patternIdx = math.min(sprayIndex, math.max(#def.RecoilPattern, 1))
	local patternVec = if #def.RecoilPattern > 0 then def.RecoilPattern[patternIdx] else Vector2.zero

	local randPitch = spreadRng:NextNumber(def.RecoilPitchMin, def.RecoilPitchMax)
	local randYaw = spreadRng:NextNumber(def.RecoilYawMin, def.RecoilYawMax)
	local randRoll = spreadRng:NextNumber(-def.RecoilRollMax, def.RecoilRollMax)

	local totalPitchDeg = (patternVec.Y * 0.55 + randPitch * 0.45) * scale
	local totalYawDeg = (patternVec.X * 0.60 + randYaw * 0.40) * scale

	-- Split recoil between snappy Spring recovery and persistent vertical/horizontal climb.
	local pitchRad = math.rad(totalPitchDeg)
	local yawRad = math.rad(totalYawDeg)
	local rollRad = math.rad(randRoll * scale)

	cameraRecoilSpring.Force = def.RecoilSpringForce
	cameraRecoilSpring.Damping = def.RecoilSpringDamping
	cameraRecoilSpring:Shove(Vector3.new(pitchRad * 16.0, -yawRad * 16.0, rollRad * 12.0))

	persistentRecoil = Vector2.new(
		math.clamp(persistentRecoil.X - yawRad * 0.48, math.rad(-10), math.rad(10)),
		math.clamp(persistentRecoil.Y + pitchRad * 0.62, 0, math.rad(20))
	)
end

local function tryFireShot(): ()
	if not isEquippedAndAlive or isMenuBlocking or isReloading or pendingGrenadeType ~= nil then
		return
	end

	local camera = Workspace.CurrentCamera
	local character = localPlayer.Character
	if not camera or not character then
		return
	end

	local slotState = getActiveSlotState()
	local def = WeaponConfig.GetWeapon(slotState.WeaponId)
	if not def then
		return
	end

	local now = os.clock()
	local fireInterval = 60 / def.RPM
	if now - lastShotTime < fireInterval then
		return
	end

	if slotState.FireMode == "Semi" and semiShotConsumed then
		return
	end

	if slotState.Magazine <= 0 then
		semiShotConsumed = true
		lastShotTime = now
		playSound2D(def.DryFireSoundId, 0.5, 1.0)
		return
	end

	-- Compute tactical spread based on ADS, crouch, movement speed, and airborne state
	local moveSnap = MovementController.GetSnapshot()
	local adsAlpha = ViewmodelController.GetAdsAlpha()
	local baseSpread = def.HipfireSpreadDeg + (def.AdsSpreadDeg - def.HipfireSpreadDeg) * adsAlpha
	local moveFactor = 1 + (def.MoveSpreadMultiplier - 1) * moveSnap.NormalizedSpeed
	local crouchFactor = if moveSnap.IsCrouching then def.CrouchSpreadMultiplier else 1.0
	local airFactor = if moveSnap.IsGrounded then 1.0 else 1.75
	local finalSpreadDeg = baseSpread * moveFactor * crouchFactor * airFactor

	local aimOrigin = camera.CFrame.Position
	local shotDir = Ballistics.ApplySpread(camera.CFrame.LookVector, finalSpreadDeg, spreadRng)

	-- Optimistic local feedback (server remains authoritative)
	slotState.Magazine -= 1
	lastShotTime = now
	if slotState.FireMode == "Semi" then
		semiShotConsumed = true
	end
	fireSequence += 1

	ViewmodelController.TriggerShotRecoil(def)
	applyWeaponRecoil(def, adsAlpha, moveSnap.IsCrouching)
	playSound2D(def.ShotSoundId, def.ShotVolume, def.ShotPitch)

	local muzzleWorld = ViewmodelController.GetMuzzleWorldPosition()
	spawnVisualProjectile(def, aimOrigin, shotDir * def.MuzzleVelocity, muzzleWorld, { character })

	local firePayload: NetworkTypes.ClientFirePayload = {
		WeaponId = def.Id,
		Origin = aimOrigin,
		Direction = shotDir,
		ClientTime = Workspace:GetServerTimeNow(),
		Sequence = fireSequence,
	}
	fireWeaponRemote:FireServer(firePayload)
end

local function toggleFireMode(): ()
	if not isEquippedAndAlive or isMenuBlocking then
		return
	end
	local slotState = getActiveSlotState()
	local def = WeaponConfig.GetWeapon(slotState.WeaponId)
	if not def or #def.FireModes <= 1 then
		return
	end

	local currentIdx = table.find(def.FireModes, slotState.FireMode) or 1
	local nextIdx = (currentIdx % #def.FireModes) + 1
	local nextMode = def.FireModes[nextIdx]
	slotState.FireMode = nextMode

	playSound2D("rbxassetid://139719503904449", 0.35, 1.15)
	HUDController.ShowFireModeToast(def.DisplayName, nextMode)

	local payload: NetworkTypes.ClientFireModePayload = {
		WeaponId = def.Id,
		FireMode = nextMode,
	}
	setFireModeRemote:FireServer(payload)
end

local function requestSlotSwitch(targetSlot: WeaponSlot): ()
	if not isEquippedAndAlive or isMenuBlocking or pendingGrenadeType ~= nil or activeSlot == targetSlot then
		return
	end
	isReloading = false
	ViewmodelController.StopReloadAnimation()
	ViewmodelController.SetAds(false)
	MovementController.SetAdsActive(false)
	persistentRecoil = Vector2.zero

	activeSlot = targetSlot
	local slotState = getActiveSlotState()
	ViewmodelController.EquipWeapon(slotState.WeaponId)

	local def = WeaponConfig.GetWeapon(slotState.WeaponId)
	if def then
		HUDController.ShowFireModeToast(def.DisplayName, slotState.FireMode)
	end

	local payload: NetworkTypes.ClientSwitchPayload = { Slot = targetSlot }
	switchWeaponRemote:FireServer(payload)
end

local function triggerReload(): ()
	if not isEquippedAndAlive or isMenuBlocking or isReloading or pendingGrenadeType ~= nil then
		return
	end
	local slotState = getActiveSlotState()
	local def = WeaponConfig.GetWeapon(slotState.WeaponId)
	if not def or slotState.Reserve <= 0 then
		return
	end

	local maxCap = def.MagazineSize + (if def.ChamberSupported and slotState.Magazine > 0 then 1 else 0)
	if slotState.Magazine >= maxCap then
		HUDController.ShowMagazineCheck(slotState.Magazine, def.MagazineSize, slotState.FireMode)
		return
	end

	local payload: NetworkTypes.ClientReloadPayload = {
		Action = "Start",
		WeaponId = def.Id,
	}
	reloadWeaponRemote:FireServer(payload)
end

local function createClientGrenadeModel(def: GrenadeConfig.GrenadeDefinition, origin: Vector3): Model
	local model = Instance.new("Model")
	model.Name = `Grenade_{def.Type}`

	local body = Instance.new("Part")
	body.Name = "Body"
	body.Shape = if def.Type == "Frag" then Enum.PartType.Ball else Enum.PartType.Cylinder
	body.Size = if def.Type == "Frag" then Vector3.new(0.62, 0.72, 0.62) else Vector3.new(0.95, 0.42, 0.42)
	body.Color = def.BodyColor
	body.Material = Enum.Material.Metal
	body.Anchored = true
	body.CanCollide = false
	body.CanQuery = false
	body.CastShadow = true
	body.CFrame = CFrame.new(origin)
	body.Parent = model

	local band = Instance.new("Part")
	band.Name = "AccentBand"
	band.Shape = if def.Type == "Frag" then Enum.PartType.Cylinder else Enum.PartType.Cylinder
	band.Size = if def.Type == "Frag" then Vector3.new(0.24, 0.46, 0.46) else Vector3.new(0.18, 0.44, 0.44)
	band.Color = def.AccentColor
	band.Material = Enum.Material.SmoothPlastic
	band.Anchored = true
	band.CanCollide = false
	band.CanQuery = false
	band.CastShadow = false
	band.CFrame = CFrame.new(origin) * CFrame.new(0, 0.25, 0) * CFrame.Angles(0, 0, math.rad(90))
	band.Parent = model

	model.PrimaryPart = body
	model.Parent = visualFolder
	return model
end

local function buildClientGrenadeRayParams(): RaycastParams
	local params = RaycastParams.new()
	params.IgnoreWater = true
	params.RespectCanCollide = true
	local excludes: { Instance } = { visualFolder }
	for _, p in ipairs(Players:GetPlayers()) do
		if p.Character then
			table.insert(excludes, p.Character)
		end
	end
	params.ExcludeInstances = excludes
	return params
end

local function addDebrisPart(pos: Vector3, vel: Vector3, size: Vector3, color: Color3, material: Enum.Material, lifetime: number, initTrans: number, growRate: number): ()
	local p = Instance.new("Part")
	p.Name = "GrenadeDebris"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CastShadow = false
	p.Size = size
	p.Color = color
	p.Material = material
	p.Transparency = initTrans
	p.CFrame = CFrame.new(pos)
	p.Parent = visualFolder

	table.insert(explosionDebris, {
		Part = p,
		Position = pos,
		Velocity = vel,
		CreatedAt = os.clock(),
		Lifetime = lifetime,
		InitialTransparency = initTrans,
		GrowRate = growRate,
	})
end

local function spawnFragExplosionVFX(pos: Vector3): ()
	local def = GrenadeConfig.Grenades.Frag
	playSound3D(def.DetonateSoundId, pos, 1.0, 1.0, 420)

	-- Bright fireball core + PointLight
	local flashSphere = Instance.new("Part")
	flashSphere.Name = "FragFlashCore"
	flashSphere.Shape = Enum.PartType.Ball
	flashSphere.Anchored = true
	flashSphere.CanCollide = false
	flashSphere.CanQuery = false
	flashSphere.CastShadow = false
	flashSphere.Material = Enum.Material.Neon
	flashSphere.Color = Color3.fromRGB(255, 172, 74)
	flashSphere.Size = Vector3.new(7, 7, 7)
	flashSphere.Position = pos + Vector3.new(0, 0.8, 0)
	flashSphere.Parent = visualFolder

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 165, 70)
	light.Brightness = 6
	light.Range = 36
	light.Parent = flashSphere

	table.insert(ephemeralVisuals, {
		Part = flashSphere,
		CreatedAt = os.clock(),
		Lifetime = 0.16,
		InitialTransparency = 0.05,
	})

	-- Expanding dark smoke puffs + shrapnel sparks
	for _s = 1, 5 do
		local puffVel = Vector3.new(spreadRng:NextNumber(-7, 7), spreadRng:NextNumber(6, 15), spreadRng:NextNumber(-7, 7))
		addDebrisPart(pos + Vector3.new(0, 0.8, 0), puffVel, Vector3.new(3.5, 3.5, 3.5), Color3.fromRGB(58, 56, 54), Enum.Material.SmoothPlastic, 1.15, 0.35, 9.0)
	end
	for _k = 1, 10 do
		local sparkVel = Vector3.new(spreadRng:NextNumber(-46, 46), spreadRng:NextNumber(14, 48), spreadRng:NextNumber(-46, 46))
		addDebrisPart(pos + Vector3.new(0, 0.6, 0), sparkVel, Vector3.new(0.26, 0.26, 0.55), Color3.fromRGB(255, 195, 92), Enum.Material.Neon, 0.42, 0.05, 0)
	end

	-- Local camera concussive shake based on distance
	local camera = Workspace.CurrentCamera
	if camera then
		local dist = (camera.CFrame.Position - pos).Magnitude
		if dist < 60 then
			local shakeScale = math.clamp(1 - dist / 60, 0.15, 1.0)
			cameraRecoilSpring:Shove(
				Vector3.new(
					math.rad(spreadRng:NextNumber(-5.5, 5.5) * shakeScale),
					math.rad(spreadRng:NextNumber(-6.0, 6.0) * shakeScale),
					math.rad(spreadRng:NextNumber(-7.0, 7.0) * shakeScale)
				) * 14
			)
		end
	end
end

local function spawnFlashExplosionVFX(pos: Vector3): ()
	local def = GrenadeConfig.Grenades.Flash
	playSound3D(def.DetonateSoundId, pos, 0.95, 1.0, 340)

	local flashBall = Instance.new("Part")
	flashBall.Name = "FlashbangCore"
	flashBall.Shape = Enum.PartType.Ball
	flashBall.Anchored = true
	flashBall.CanCollide = false
	flashBall.CanQuery = false
	flashBall.CastShadow = false
	flashBall.Material = Enum.Material.Neon
	flashBall.Color = Color3.fromRGB(250, 252, 255)
	flashBall.Size = Vector3.new(6, 6, 6)
	flashBall.Position = pos + Vector3.new(0, 0.6, 0)
	flashBall.Parent = visualFolder

	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(245, 250, 255)
	light.Brightness = 10
	light.Range = 46
	light.Parent = flashBall

	table.insert(ephemeralVisuals, {
		Part = flashBall,
		CreatedAt = os.clock(),
		Lifetime = 0.14,
		InitialTransparency = 0,
	})
end

local function cancelGrenadePrep(): ()
	if pendingGrenadeType ~= nil then
		pendingGrenadeType = nil
		prepKeyDown = false
		ViewmodelController.SetGrenadePrep(false)
	end
end

local function beginGrenadePrep(gType: GrenadeType): ()
	if not isEquippedAndAlive or isMenuBlocking or isReloading or pendingGrenadeType ~= nil then
		return
	end
	if os.clock() < lastThrowEndAt then
		return
	end

	local def = GrenadeConfig.GetGrenade(gType)
	if not def then
		return
	end

	if (grenadeCounts[gType] or 0) <= 0 then
		playSound2D("rbxassetid://139719503904449", 0.30, 0.82)
		HUDController.ShowToast(`{def.ShortName}: закончились`, 1.4, Color3.fromRGB(220, 120, 108))
		return
	end

	isTriggerHeld = false
	ViewmodelController.SetAds(false)
	MovementController.SetAdsActive(false)
	pendingGrenadeType = gType
	prepStartedAt = os.clock()
	prepKeyDown = true
	ViewmodelController.SetGrenadePrep(true)
	playSound2D(def.PinSoundId, 0.45, 1.0)
end

local function executeGrenadeThrow(): ()
	local gType = pendingGrenadeType
	if not gType then
		return
	end
	pendingGrenadeType = nil
	prepKeyDown = false

	local camera = Workspace.CurrentCamera
	if not camera or not isEquippedAndAlive or isMenuBlocking then
		ViewmodelController.SetGrenadePrep(false)
		return
	end

	if (grenadeCounts[gType] or 0) <= 0 then
		ViewmodelController.SetGrenadePrep(false)
		return
	end

	local look = camera.CFrame.LookVector
	local origin = camera.CFrame.Position + look * 1.4 - camera.CFrame.UpVector * 0.20
	local aimDir = (look + Vector3.new(0, 0.12, 0)).Unit

	grenadeCounts[gType] = math.max(0, (grenadeCounts[gType] or 0) - 1)
	HUDController.UpdateGrenadeCounts(grenadeCounts.Frag, grenadeCounts.Flash)

	ViewmodelController.TriggerGrenadeThrowImpulse()
	lastThrowEndAt = os.clock() + GrenadeConfig.POST_THROW_COOLDOWN

	local def = GrenadeConfig.GetGrenade(gType)
	if def then
		HUDController.ShowToast(`Бросок: {def.ShortName}`, 1.2, def.AccentColor)
	end

	throwGrenadeRemote:FireServer({
		GrenadeType = gType,
		Origin = origin,
		Direction = aimDir,
	} :: NetworkTypes.ClientGrenadeThrowPayload)
end

local function stepVisualsHeartbeat(dt: number): ()
	local now = os.clock()

	if pendingGrenadeType ~= nil and not prepKeyDown and (now - prepStartedAt) >= GrenadeConfig.PREP_MIN_DURATION then
		executeGrenadeThrow()
	end

	-- Step thrown grenade models with synchronized bounce physics
	for gId, g in pairs(activeClientGrenades) do
		local newPos, newVel, bounced = GrenadeConfig.StepGrenadeMotion(g.Position, g.Velocity, dt, g.Def, g.RayParams)
		g.Position = newPos
		g.Velocity = newVel

		if newVel.Magnitude > 1.5 then
			g.SpinAngle += g.SpinRate * dt
		end

		if bounced and now - g.LastBounceSoundAt >= 0.08 and newVel.Magnitude > 5 then
			g.LastBounceSoundAt = now
			playSound3D(g.Def.BounceSoundId, newPos, 0.35, 1.35, 95)
		end

		local bodyCF = CFrame.new(newPos) * CFrame.Angles(g.SpinAngle.X, g.SpinAngle.Y, g.SpinAngle.Z)
		if g.Def.Type == "Flash" then
			bodyCF *= CFrame.Angles(0, 0, math.rad(90))
		end
		if g.Model.PrimaryPart then
			g.Model.PrimaryPart.CFrame = bodyCF
			local band = g.Model:FindFirstChild("AccentBand")
			if band and band:IsA("BasePart") then
				band.CFrame = bodyCF * CFrame.new(0, 0.22, 0) * CFrame.Angles(0, 0, math.rad(90))
			end
		end

		if now >= g.ExpiresAt then
			g.Model:Destroy()
			activeClientGrenades[gId] = nil
		end
	end

	-- Step explosion debris / smoke puffs
	local dIdx = #explosionDebris
	while dIdx >= 1 do
		local d = explosionDebris[dIdx]
		local age = now - d.CreatedAt
		if age >= d.Lifetime or not d.Part.Parent then
			if d.Part.Parent then
				d.Part:Destroy()
			end
			local last = #explosionDebris
			explosionDebris[dIdx] = explosionDebris[last]
			explosionDebris[last] = nil
		else
			d.Velocity += Vector3.new(0, if d.GrowRate > 0 then -12 else -140, 0) * dt
			d.Position += d.Velocity * dt
			d.Part.Position = d.Position
			if d.GrowRate > 0 then
				d.Part.Size += Vector3.new(d.GrowRate, d.GrowRate, d.GrowRate) * dt
			end
			local alpha = age / d.Lifetime
			d.Part.Transparency = d.InitialTransparency + (1 - d.InitialTransparency) * alpha
		end
		dIdx -= 1
	end

	-- Step local & replicated projectile tracers
	local i = #activeTracers
	while i >= 1 do
		local tracer = activeTracers[i]
		local result = Ballistics.StepProjectile(tracer.State, dt, tracer.RayParams)

		for segIdx, seg in ipairs(result.Segments) do
			local drawStart = seg.Start
			if tracer.IsFirstSegment and segIdx == 1 and tracer.MuzzleOrigin then
				drawStart = tracer.MuzzleOrigin
			end
			spawnTracerBeam(drawStart, seg.End)
		end
		tracer.IsFirstSegment = false

		for _, impact in ipairs(result.Impacts) do
			if impact.Kind == "Surface" then
				spawnSurfaceImpact(impact.Position, impact.Normal, impact.Material, false)
			elseif impact.Kind == "Wallbang" then
				spawnSurfaceImpact(impact.Position, impact.Normal, impact.Material, false)
				if impact.ExitPosition and impact.ExitNormal then
					spawnSurfaceImpact(impact.ExitPosition, impact.ExitNormal, impact.Material, true)
				end
			end
		end

		if not result.Alive then
			local last = #activeTracers
			activeTracers[i] = activeTracers[last]
			activeTracers[last] = nil
		end

		i -= 1
	end

	-- Fade and expire ephemeral tracer beams & impact holes
	local vIdx = #ephemeralVisuals
	while vIdx >= 1 do
		local vis = ephemeralVisuals[vIdx]
		local age = now - vis.CreatedAt
		if age >= vis.Lifetime or not vis.Part.Parent then
			if vis.Part.Parent then
				vis.Part:Destroy()
			end
			local last = #ephemeralVisuals
			ephemeralVisuals[vIdx] = ephemeralVisuals[last]
			ephemeralVisuals[last] = nil
		else
			local alpha = age / vis.Lifetime
			vis.Part.Transparency = vis.InitialTransparency + (1 - vis.InitialTransparency) * alpha
		end
		vIdx -= 1
	end
end

function WeaponController.Init(): ()
	visualFolder = ensureVisualFolder()

	fireWeaponRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.FireWeapon)
	reloadWeaponRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.ReloadWeapon)
	switchWeaponRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.SwitchWeapon)
	setFireModeRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.SetFireMode)
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

	grenadeSyncRemote.OnClientEvent:Connect(function(payload: NetworkTypes.GrenadeSyncPayload)
		if typeof(payload) ~= "table" then
			return
		end
		grenadeCounts.Frag = payload.Frag or 0
		grenadeCounts.Flash = payload.Flash or 0
		HUDController.UpdateGrenadeCounts(grenadeCounts.Frag, grenadeCounts.Flash)
	end)

	grenadeReplicatedRemote.OnClientEvent:Connect(function(payload: NetworkTypes.ReplicatedGrenadePayload)
		if typeof(payload) ~= "table" then
			return
		end
		local def = GrenadeConfig.GetGrenade(payload.GrenadeType)
		if not def then
			return
		end
		local existing = activeClientGrenades[payload.GrenadeId]
		if existing then
			existing.Model:Destroy()
		end
		local model = createClientGrenadeModel(def, payload.Origin)
		activeClientGrenades[payload.GrenadeId] = {
			Id = payload.GrenadeId,
			Def = def,
			Model = model,
			Position = payload.Origin,
			Velocity = payload.Velocity,
			SpinAngle = Vector3.zero,
			SpinRate = Vector3.new(spreadRng:NextNumber(-9, 9), spreadRng:NextNumber(-7, 7), spreadRng:NextNumber(-9, 9)),
			ExpiresAt = os.clock() + def.FuseTime + 1.5,
			LastBounceSoundAt = 0,
			RayParams = buildClientGrenadeRayParams(),
		}
	end)

	grenadeDetonatedRemote.OnClientEvent:Connect(function(payload: NetworkTypes.GrenadeDetonatedPayload)
		if typeof(payload) ~= "table" then
			return
		end
		local vis = activeClientGrenades[payload.GrenadeId]
		if vis then
			vis.Model:Destroy()
			activeClientGrenades[payload.GrenadeId] = nil
		end
		if payload.GrenadeType == "Frag" then
			spawnFragExplosionVFX(payload.Position)
		else
			spawnFlashExplosionVFX(payload.Position)
		end
	end)

	flashbangEffectRemote.OnClientEvent:Connect(function(payload: NetworkTypes.FlashbangEffectPayload)
		if typeof(payload) ~= "table" or not isEquippedAndAlive then
			return
		end
		local camera = Workspace.CurrentCamera
		if not camera then
			return
		end
		local delta = payload.Origin - camera.CFrame.Position
		local dirToFlash = if delta.Magnitude > 0.05 then delta.Unit else camera.CFrame.LookVector
		local lookDot = camera.CFrame.LookVector:Dot(dirToFlash)

		local angleFactor: number
		if lookDot >= 0.35 then
			angleFactor = 1.0
		elseif lookDot >= -0.25 then
			angleFactor = 0.55 + ((lookDot + 0.25) / 0.60) * 0.45
		else
			angleFactor = if payload.Distance <= payload.InnerStunRadius then 0.38 else 0.14
		end

		local intensity = math.clamp(payload.DistanceFactor * angleFactor, 0.12, 1.0)
		local duration = math.max(0.6, payload.MaxDuration * payload.DistanceFactor * angleFactor)
		HUDController.TriggerFlashbang(intensity, duration)
		playSound2D(GrenadeConfig.Grenades.Flash.DetonateSoundId, 0.45 * intensity, 1.0)
		cameraRecoilSpring:Shove(
			Vector3.new(
				math.rad(spreadRng:NextNumber(-4, 4) * intensity),
				math.rad(spreadRng:NextNumber(-5, 5) * intensity),
				math.rad(spreadRng:NextNumber(-6, 6) * intensity)
			) * 14
		)
	end)

	ammoSyncRemote.OnClientEvent:Connect(function(payload: NetworkTypes.AmmoSyncPayload)
		if typeof(payload) ~= "table" then
			return
		end
		local slot = payload.Slot
		if slot ~= "Primary" and slot ~= "Secondary" then
			return
		end

		local previousReloading = isReloading
		slots[slot] = {
			WeaponId = payload.WeaponId,
			Magazine = payload.Magazine,
			Reserve = payload.Reserve,
			FireMode = payload.FireMode,
		}

		local slotChanged = (activeSlot ~= slot)
		activeSlot = slot
		isReloading = payload.IsReloading

		if slotChanged then
			ViewmodelController.EquipWeapon(payload.WeaponId)
		end

		if isReloading and not previousReloading then
			local def = WeaponConfig.GetWeapon(payload.WeaponId)
			local duration = payload.ReloadDuration or (if def then def.TacticalReloadTime else 1.8)
			ViewmodelController.StartReloadAnimation(duration, payload.Magazine <= 0)
			if def then
				playSound2D(def.ReloadSoundId, 0.55, 1.0)
			end
		elseif not isReloading and previousReloading then
			ViewmodelController.StopReloadAnimation()
		end
	end)

	bulletReplicatedRemote.OnClientEvent:Connect(function(payload: NetworkTypes.ReplicatedTracerPayload)
		if typeof(payload) ~= "table" then
			return
		end
		local def = WeaponConfig.GetWeapon(payload.WeaponId)
		if not def then
			return
		end
		playSound3D(def.ShotSoundId, payload.Origin, def.ShotVolume * 0.9, def.ShotPitch, 380)

		local excludes: { Instance } = {}
		local shooter = Players:GetPlayerByUserId(payload.ShooterUserId)
		if shooter and shooter.Character then
			table.insert(excludes, shooter.Character)
		end
		spawnVisualProjectile(def, payload.Origin, payload.Velocity, nil, excludes)
	end)

	hitConfirmRemote.OnClientEvent:Connect(function(_payload: NetworkTypes.HitConfirmPayload)
		-- Subtle crisp audio feedback on confirmed hit without arcade floating numbers
		playSound2D("rbxassetid://139719503904449", 0.22, 1.6)
	end)

	damageTakenRemote.OnClientEvent:Connect(function(payload: NetworkTypes.DamageTakenPayload)
		if typeof(payload) ~= "table" then
			return
		end
		HUDController.TriggerDamageTaken(payload)
		cameraRecoilSpring:Shove(
			Vector3.new(
				math.rad(spreadRng:NextNumber(2.0, 4.5)),
				math.rad(spreadRng:NextNumber(-3.5, 3.5)),
				math.rad(spreadRng:NextNumber(-4.0, 4.0))
			) * 8
		)
	end)

	suppressionRemote.OnClientEvent:Connect(function(payload: NetworkTypes.SuppressionPayload)
		if typeof(payload) ~= "table" then
			return
		end
		HUDController.TriggerSuppression(payload.Intensity)
		suppressionShakeSpring:Shove(
			Vector3.new(
				math.rad(spreadRng:NextNumber(-1.4, 1.4) * payload.Intensity),
				math.rad(spreadRng:NextNumber(-1.6, 1.6) * payload.Intensity),
				math.rad(spreadRng:NextNumber(-2.2, 2.2) * payload.Intensity)
			) * 18
		)
	end)

	UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or not isEquippedAndAlive or isMenuBlocking then
			return
		end

		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			isTriggerHeld = true
			semiShotConsumed = false
			tryFireShot()
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			ViewmodelController.SetAds(true)
			MovementController.SetAdsActive(true)
		elseif input.KeyCode == Enum.KeyCode.V then
			toggleFireMode()
		elseif input.KeyCode == Enum.KeyCode.R then
			rKeyDown = true
			rPressStartedAt = os.clock()
			rCheckTriggered = false
		elseif input.KeyCode == Enum.KeyCode.One then
			requestSlotSwitch("Primary")
		elseif input.KeyCode == Enum.KeyCode.Two then
			requestSlotSwitch("Secondary")
		elseif input.KeyCode == Enum.KeyCode.G then
			beginGrenadePrep("Frag")
		elseif input.KeyCode == Enum.KeyCode.F then
			beginGrenadePrep("Flash")
		end
	end)

	UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			isTriggerHeld = false
			semiShotConsumed = false
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			ViewmodelController.SetAds(false)
			MovementController.SetAdsActive(false)
		elseif input.KeyCode == Enum.KeyCode.R then
			if rKeyDown then
				rKeyDown = false
				ViewmodelController.SetInspecting(false)
				if not rCheckTriggered then
					triggerReload()
				end
			end
		elseif input.KeyCode == Enum.KeyCode.G and pendingGrenadeType == "Frag" then
			prepKeyDown = false
		elseif input.KeyCode == Enum.KeyCode.F and pendingGrenadeType == "Flash" then
			prepKeyDown = false
		end
	end)

	UserInputService.InputChanged:Connect(function(input: InputObject, gameProcessed: boolean)
		if gameProcessed or not isEquippedAndAlive or isMenuBlocking then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseWheel then
			local targetSlot: WeaponSlot = if activeSlot == "Primary" then "Secondary" else "Primary"
			requestSlotSwitch(targetSlot)
		end
	end)

	RunService.Heartbeat:Connect(stepVisualsHeartbeat)
end

function WeaponController.OnCharacterSpawned(loadout: NetworkTypes.LoadoutSelection): ()
	local pDef = WeaponConfig.GetWeapon(loadout.Primary)
	local sDef = WeaponConfig.GetWeapon(loadout.Secondary)

	if pDef then
		slots.Primary = {
			WeaponId = pDef.Id,
			Magazine = pDef.MagazineSize,
			Reserve = pDef.MagazineSize * pDef.ReserveMagazines,
			FireMode = pDef.DefaultFireMode,
		}
	end
	if sDef then
		slots.Secondary = {
			WeaponId = sDef.Id,
			Magazine = sDef.MagazineSize,
			Reserve = sDef.MagazineSize * sDef.ReserveMagazines,
			FireMode = sDef.DefaultFireMode,
		}
	end

	activeSlot = "Primary"
	isEquippedAndAlive = true
	isMenuBlocking = false
	isReloading = false
	isTriggerHeld = false
	semiShotConsumed = false
	pendingGrenadeType = nil
	prepKeyDown = false
	lastThrowEndAt = 0
	grenadeCounts.Frag = GrenadeConfig.Grenades.Frag.StartingCount
	grenadeCounts.Flash = GrenadeConfig.Grenades.Flash.StartingCount
	HUDController.UpdateGrenadeCounts(grenadeCounts.Frag, grenadeCounts.Flash)
	sprayIndex = 0
	persistentRecoil = Vector2.zero
	cameraRecoilSpring:Reset()
	suppressionShakeSpring:Reset()

	ViewmodelController.EquipWeapon(slots.Primary.WeaponId)
	if pDef then
		HUDController.ShowFireModeToast(pDef.DisplayName, slots.Primary.FireMode)
	end
end

function WeaponController.ClearVisualEffects(): ()
	table.clear(activeTracers)
	for _, vis in ipairs(ephemeralVisuals) do
		if vis.Part and vis.Part.Parent then
			vis.Part:Destroy()
		end
	end
	table.clear(ephemeralVisuals)

	for _, d in ipairs(explosionDebris) do
		if d.Part and d.Part.Parent then
			d.Part:Destroy()
		end
	end
	table.clear(explosionDebris)

	for _, g in pairs(activeClientGrenades) do
		if g.Model and g.Model.Parent then
			g.Model:Destroy()
		end
	end
	table.clear(activeClientGrenades)
end

function WeaponController.OnCharacterDied(): ()
	isEquippedAndAlive = false
	isTriggerHeld = false
	isReloading = false
	rKeyDown = false
	cancelGrenadePrep()
	ViewmodelController.SetAds(false)
	MovementController.SetAdsActive(false)
	ViewmodelController.ClearViewmodel()
end

function WeaponController.SetMenuBlocking(blocking: boolean): ()
	isMenuBlocking = blocking
	if blocking then
		isTriggerHeld = false
		cancelGrenadePrep()
		ViewmodelController.SetAds(false)
		MovementController.SetAdsActive(false)
	end
end

function WeaponController.Update(dt: number): ()
	if isEquippedAndAlive and not isMenuBlocking then
		-- Hold-R detection for magazine check without reloading
		if rKeyDown and not rCheckTriggered and os.clock() - rPressStartedAt >= MAG_CHECK_HOLD_SECONDS then
			rCheckTriggered = true
			local slotState = getActiveSlotState()
			local def = WeaponConfig.GetWeapon(slotState.WeaponId)
			if def then
				ViewmodelController.SetInspecting(true)
				HUDController.ShowMagazineCheck(slotState.Magazine, def.MagazineSize, slotState.FireMode)
			end
		end

		if isTriggerHeld then
			local slotState = getActiveSlotState()
			if slotState.FireMode == "Auto" then
				tryFireShot()
			end
		end
	end

	-- Decay persistent recoil gently when not actively spraying
	if not isTriggerHeld or isReloading then
		local decay = math.exp(-dt * 5.0)
		persistentRecoil *= decay
	end

	-- Allow mouse pull-down to compensate persistent recoil climb smoothly
	if persistentRecoil.Y > 0 then
		local mouseDelta = UserInputService:GetMouseDelta()
		if mouseDelta.Y > 0 then
			local comp = math.rad(mouseDelta.Y * 0.08)
			persistentRecoil = Vector2.new(persistentRecoil.X, math.max(0, persistentRecoil.Y - comp))
		end
	end

	cameraRecoilSpring:Update(dt)
	suppressionShakeSpring:Update(dt)
end

function WeaponController.GetCameraRecoilCFrame(): CFrame
	local springVec = cameraRecoilSpring.Position
	local supVec = suppressionShakeSpring.Position
	return CFrame.Angles(
		springVec.X + persistentRecoil.Y + supVec.X,
		springVec.Y + persistentRecoil.X + supVec.Y,
		springVec.Z + supVec.Z
	)
end

function WeaponController.ShouldShowScopeOverlay(): boolean
	if not isEquippedAndAlive or isMenuBlocking then
		return false
	end
	return ViewmodelController.IsScopeOverlayActive()
end

return WeaponController
