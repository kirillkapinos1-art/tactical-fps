--!strict
-- Procedural first-person viewmodel controller: spring-driven sway (mouse + strafe),
-- walk/sprint bobbing, AimPart-aligned ADS with FOV/sensitivity/DoF transitions,
-- bolt blowback, visual recoil, and procedural equip/reload/mag-check animations.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NetworkTypes = require(Shared.NetworkTypes)
local Spring = require(Shared.Spring)
local WeaponConfig = require(Shared.WeaponConfig)

local MovementController = require(script.Parent.MovementController)

local ViewmodelController = {}

local BASE_FOV = 75
local SCOPE_OVERLAY_ADS_THRESHOLD = 0.72
local SLEEVE_COLOR = Color3.fromRGB(52, 58, 48)
local GLOVE_COLOR = Color3.fromRGB(30, 32, 34)
local DEFAULT_BASE_SENSITIVITY = 0.35
local DEFAULT_ADS_SENSITIVITY_SCALE = 0.85
local MIN_SENSITIVITY = 0.05
local MAX_SENSITIVITY = 2.00
local MIN_ADS_SENS_SCALE = 0.20
local MAX_ADS_SENS_SCALE = 1.50

local localPlayer = Players.LocalPlayer

local swaySpring = Spring.fromFrequency(0.85, 7.2, 1, Vector3.zero)
local bobSpring = Spring.fromFrequency(0.90, 8.0, 1, Vector3.zero)
local recoilPosSpring = Spring.fromFrequency(0.62, 11.5, 1, Vector3.zero)
local recoilRotSpring = Spring.fromFrequency(0.60, 10.5, 1, Vector3.zero)
local boltSpring = Spring.scalarFromFrequency(0.75, 18.0, 1, 0)
local adsSpring = Spring.scalarFromFrequency(1.0, 4.5, 1, 0)
local sprintSpring = Spring.scalarFromFrequency(0.95, 4.0, 1, 0)
local equipSpring = Spring.scalarFromFrequency(0.88, 4.2, 1, 0)
local inspectSpring = Spring.scalarFromFrequency(0.92, 4.0, 1, 0)
local grenadePrepSpring = Spring.scalarFromFrequency(0.95, 6.2, 1, 0)

local viewmodelContainer: Model? = nil
local weaponClone: Model? = nil
local currentWeaponDef: WeaponConfig.WeaponDefinition? = nil
local handlePart: BasePart? = nil
local muzzlePart: BasePart? = nil
local aimPart: BasePart? = nil
local aimToHandleOffset: CFrame = CFrame.identity

local boltWeld: Weld? = nil
local boltBaseC0: CFrame = CFrame.identity
local magWeld: Weld? = nil
local magBaseC0: CFrame = CFrame.identity

local isAdsRequested = false
local isInspecting = false
local isReloading = false
local isEmptyReload = false
local reloadStartTime = 0
local reloadDuration = 1.0
local bobTimer = 0
local muzzleFlashOffAt = 0
local muzzleLight: PointLight? = nil
local baseSensitivity = DEFAULT_BASE_SENSITIVITY
local adsSensitivityScale = DEFAULT_ADS_SENSITIVITY_SCALE

local function convertPartToAnimatedWeld(part: BasePart, handle: BasePart): (Weld, CFrame)
	for _, child in ipairs(part:GetChildren()) do
		if child:IsA("WeldConstraint") then
			child:Destroy()
		end
	end
	local relCFrame = handle.CFrame:ToObjectSpace(part.CFrame)
	local weld = Instance.new("Weld")
	weld.Part0 = handle
	weld.Part1 = part
	weld.C0 = relCFrame
	weld.C1 = CFrame.identity
	weld.Parent = part
	return weld, relCFrame
end

local function createArmSegment(
	parent: Instance,
	name: string,
	fromPos: Vector3,
	toPos: Vector3,
	thickness: number,
	color: Color3,
	material: Enum.Material,
	handle: BasePart
): ()
	local delta = toPos - fromPos
	local length = math.max(delta.Magnitude, 0.1)
	local mid = (fromPos + toPos) * 0.5
	local seg = Instance.new("Part")
	seg.Name = name
	seg.Size = Vector3.new(thickness, thickness, length)
	seg.CFrame = handle.CFrame * CFrame.lookAt(mid, toPos)
	seg.Color = color
	seg.Material = material
	seg.TopSurface = Enum.SurfaceType.Smooth
	seg.BottomSurface = Enum.SurfaceType.Smooth
	seg.Anchored = false
	seg.CanCollide = false
	seg.CanQuery = false
	seg.CastShadow = false
	seg.Massless = true
	seg.Parent = parent

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = seg
	weld.Parent = seg
end

local function attachProceduralArms(model: Model, def: WeaponConfig.WeaponDefinition, handle: BasePart): ()
	local spec = def.ModelSpec
	local rightGrip = spec.GripOffset + Vector3.new(0, 0.02, 0.04)
	local rightElbow = Vector3.new(0.42, -0.52, 1.32)
	local rightWrist = rightGrip + Vector3.new(0.05, -0.05, 0.18)

	createArmSegment(model, "RightSleeve", rightElbow, rightWrist, 0.22, SLEEVE_COLOR, Enum.Material.Fabric, handle)
	createArmSegment(model, "RightGlove", rightWrist, rightGrip, 0.17, GLOVE_COLOR, Enum.Material.Leather, handle)

	local leftTarget: Vector3
	local leftElbow: Vector3
	if def.Slot == "Secondary" then
		leftTarget = rightGrip + Vector3.new(-0.07, -0.06, -0.04)
		leftElbow = Vector3.new(-0.46, -0.56, 1.18)
	else
		local handguardCenter = spec.HandguardOffset or Vector3.new(0, -0.04, -0.82)
		leftTarget = handguardCenter + Vector3.new(-0.02, -0.09, 0.05)
		leftElbow = Vector3.new(-0.46, -0.52, 1.02)
	end
	local leftWrist = leftTarget + (leftElbow - leftTarget).Unit * 0.22

	createArmSegment(model, "LeftSleeve", leftElbow, leftWrist, 0.22, SLEEVE_COLOR, Enum.Material.Fabric, handle)
	createArmSegment(model, "LeftGlove", leftWrist, leftTarget, 0.17, GLOVE_COLOR, Enum.Material.Leather, handle)
end

local function hideThirdPersonWeaponInFirstPerson(): ()
	local char = localPlayer.Character
	if not char then
		return
	end
	local equipped = char:FindFirstChild("EquippedWeaponModel")
	if equipped then
		for _, desc in ipairs(equipped:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.LocalTransparencyModifier = 1
			end
		end
	end
end

function ViewmodelController.ClearViewmodel(): ()
	if viewmodelContainer then
		viewmodelContainer:Destroy()
		viewmodelContainer = nil
	end
	weaponClone = nil
	handlePart = nil
	muzzlePart = nil
	aimPart = nil
	boltWeld = nil
	magWeld = nil
	muzzleLight = nil
	currentWeaponDef = nil
		isAdsRequested = false
	isReloading = false
	isInspecting = false
	grenadePrepSpring:SnapTo(0)

	UserInputService.MouseDeltaSensitivity = baseSensitivity
	local camera = Workspace.CurrentCamera
	if camera then
		camera.FieldOfView = BASE_FOV
	end
	local dof = Lighting:FindFirstChild("AdsDepthOfField")
	if dof and dof:IsA("DepthOfFieldEffect") then
		dof.Enabled = false
	end
end

function ViewmodelController.EquipWeapon(weaponId: string): ()
	ViewmodelController.ClearViewmodel()

	local def = WeaponConfig.GetWeapon(weaponId)
	if not def then
		return
	end

	local weaponsFolder = ReplicatedStorage:FindFirstChild(NetworkTypes.WEAPONS_FOLDER_NAME)
	if not weaponsFolder then
		return
	end
	local template = weaponsFolder:FindFirstChild(weaponId)
	if not template or not template:IsA("Model") then
		return
	end

	local camera = Workspace.CurrentCamera
	if not camera then
		return
	end

	local container = Instance.new("Model")
	container.Name = "FPSViewmodel"

	local clone = template:Clone()
	local handle = clone.PrimaryPart or clone:FindFirstChild("Handle")
	if not handle or not handle:IsA("BasePart") then
		clone:Destroy()
		container:Destroy()
		return
	end
	clone.PrimaryPart = handle

	for _, desc in ipairs(clone:GetDescendants()) do
		if desc:IsA("BasePart") then
			desc.Anchored = false
			desc.CanCollide = false
			desc.CanQuery = false
			desc.CastShadow = false
			desc.Massless = true
		end
	end

	local aimInst = clone:FindFirstChild("AimPart")
	if aimInst and aimInst:IsA("BasePart") then
		aimPart = aimInst
		aimToHandleOffset = aimInst.CFrame:ToObjectSpace(handle.CFrame)
	else
		aimToHandleOffset = CFrame.identity
	end

	-- Move entire model via PivotTo so all welded descendants stay aligned before creating Welds/Arms.
	clone:PivotTo(camera.CFrame * def.ViewmodelOffset)
	handle.Anchored = true

	local muzzleInst = clone:FindFirstChild("Muzzle")
	if muzzleInst and muzzleInst:IsA("BasePart") then
		muzzlePart = muzzleInst
		local light = muzzleInst:FindFirstChild("MuzzleLight")
		if light and light:IsA("PointLight") then
			muzzleLight = light
		end
	end

	local boltInst = clone:FindFirstChild("Bolt")
	if boltInst and boltInst:IsA("BasePart") then
		boltWeld, boltBaseC0 = convertPartToAnimatedWeld(boltInst, handle)
	end

	local magInst = clone:FindFirstChild("Magazine")
	if magInst and magInst:IsA("BasePart") then
		magWeld, magBaseC0 = convertPartToAnimatedWeld(magInst, handle)
	end

	attachProceduralArms(clone, def, handle)

	clone.Parent = container
	container.Parent = camera

	viewmodelContainer = container
	weaponClone = clone
	currentWeaponDef = def
	handlePart = handle

	-- Configure ADS spring tuning from weapon speed
	adsSpring.Force = def.AdsSpeed * def.AdsSpeed
	adsSpring.Damping = 2 * 0.95 * def.AdsSpeed

	swaySpring:Reset()
	bobSpring:Reset()
	recoilPosSpring:Reset()
	recoilRotSpring:Reset()
	boltSpring:Reset()
	adsSpring:SnapTo(0)
	sprintSpring:SnapTo(0)
	inspectSpring:SnapTo(0)
	equipSpring:SnapTo(1)
	equipSpring:SetTarget(0)
end

function ViewmodelController.SetAds(active: boolean): ()
	isAdsRequested = active
end

function ViewmodelController.SetSensitivity(baseSens: number, adsScale: number?): ()
	baseSensitivity = math.clamp(baseSens, MIN_SENSITIVITY, MAX_SENSITIVITY)
	if adsScale ~= nil then
		adsSensitivityScale = math.clamp(adsScale, MIN_ADS_SENS_SCALE, MAX_ADS_SENS_SCALE)
	end
	if not currentWeaponDef then
		UserInputService.MouseDeltaSensitivity = baseSensitivity
	end
end

function ViewmodelController.GetSensitivity(): (number, number)
	return baseSensitivity, adsSensitivityScale
end

function ViewmodelController.GetAdsAlpha(): number
	return math.clamp(adsSpring.Position, 0, 1)
end

function ViewmodelController.IsScopeOverlayActive(): boolean
	local def = currentWeaponDef
	if not def or def.ModelSpec.OpticType ~= "Scope" then
		return false
	end
	return ViewmodelController.GetAdsAlpha() >= SCOPE_OVERLAY_ADS_THRESHOLD
end

function ViewmodelController.SetInspecting(inspecting: boolean): ()
	isInspecting = inspecting
	inspectSpring:SetTarget(if inspecting then 1 else 0)
end

function ViewmodelController.SetGrenadePrep(prepping: boolean): ()
	grenadePrepSpring:SetTarget(if prepping then 1 else 0)
end

function ViewmodelController.TriggerGrenadeThrowImpulse(): ()
	grenadePrepSpring:SetTarget(0)
	recoilPosSpring:Shove(Vector3.new(-0.35, -0.35, -1.8))
	recoilRotSpring:Shove(Vector3.new(math.rad(-14), math.rad(10), math.rad(-12)))
end

function ViewmodelController.StartReloadAnimation(duration: number, emptyReload: boolean): ()
	isReloading = true
	isEmptyReload = emptyReload
	reloadStartTime = os.clock()
	reloadDuration = math.max(duration, 0.2)
end

function ViewmodelController.StopReloadAnimation(): ()
	isReloading = false
	if magWeld then
		magWeld.C0 = magBaseC0
	end
	if boltWeld then
		boltWeld.C0 = boltBaseC0
	end
end

function ViewmodelController.TriggerShotRecoil(def: WeaponConfig.WeaponDefinition): ()
	local adsAlpha = ViewmodelController.GetAdsAlpha()
	local adsScale = 1 - adsAlpha * 0.45

	local kick = def.ViewmodelRecoilKick * adsScale
	local rot = def.ViewmodelRecoilRot * adsScale
	local jitterX = (math.random() - 0.5) * 0.015 * adsScale
	local jitterYaw = (math.random() - 0.5) * 0.025 * adsScale

	recoilPosSpring:Shove(Vector3.new(kick.X + jitterX, kick.Y, kick.Z) * 24)
	recoilRotSpring:Shove(Vector3.new(rot.X, rot.Y + jitterYaw, (math.random() - 0.5) * rot.Z) * 26)
	boltSpring:Shove(def.BoltKickDistance * 48)

	if muzzleLight then
		muzzleLight.Enabled = true
		muzzleFlashOffAt = os.clock() + 0.045
	end
end

function ViewmodelController.GetMuzzleWorldPosition(): Vector3?
	if muzzlePart and muzzlePart.Parent then
		return muzzlePart.Position
	end
	return nil
end

function ViewmodelController.Update(dt: number): ()
	local camera = Workspace.CurrentCamera
	local def = currentWeaponDef
	local handle = handlePart

	if not camera or not def or not handle or not handle.Parent then
		UserInputService.MouseDeltaSensitivity = baseSensitivity
		return
	end

	hideThirdPersonWeaponInFirstPerson()

	if muzzleLight and muzzleLight.Enabled and os.clock() >= muzzleFlashOffAt then
		muzzleLight.Enabled = false
	end

	local char = localPlayer.Character
	local hum = if char then char:FindFirstChildOfClass("Humanoid") else nil
	if not char or not hum or hum.Health <= 0 then
		ViewmodelController.ClearViewmodel()
		return
	end

	local moveSnap = MovementController.GetSnapshot()

	-- Compute ADS vs Sprint priority (cannot ADS while actively sprinting)
	local effectiveAds = isAdsRequested and not moveSnap.IsSprinting and not isReloading
	adsSpring:SetTarget(if effectiveAds then 1 else 0)
	local adsAlpha = math.clamp(adsSpring:Update(dt), 0, 1)

	local effectiveSprint = moveSnap.IsSprinting and not isReloading
	sprintSpring:SetTarget(if effectiveSprint then 1 else 0)
	local sprintAlpha = math.clamp(sprintSpring:Update(dt), 0, 1)

	local equipAlpha = equipSpring:Update(dt)
	local inspectAlpha = inspectSpring:Update(dt)
	local grenadeAlpha = grenadePrepSpring:Update(dt)

	-- Dynamic FOV, Mouse Sensitivity, and subtle ADS DepthOfField
	camera.FieldOfView = BASE_FOV + (def.AdsFov - BASE_FOV) * adsAlpha
	local adsSens = baseSensitivity * def.AdsSensitivityMultiplier * adsSensitivityScale
	local effectiveSens = baseSensitivity + (adsSens - baseSensitivity) * adsAlpha
	UserInputService.MouseDeltaSensitivity = effectiveSens

	local dof = Lighting:FindFirstChild("AdsDepthOfField")
	if dof and dof:IsA("DepthOfFieldEffect") then
		dof.Enabled = adsAlpha > 0.12
		dof.FarIntensity = 0.28 * adsAlpha
	end

	-- Sway from mouse movement and lateral strafe (normalized so sway stays responsive at low sensitivity)
	local mouseDelta = UserInputService:GetMouseDelta()
	local swaySensComp = math.clamp(1 / math.max(effectiveSens, MIN_SENSITIVITY), 0.5, 6.0)
	local swayMouseX = mouseDelta.X * swaySensComp
	local swayMouseY = mouseDelta.Y * swaySensComp
	local swayDampen = (1 - adsAlpha * 0.80) * def.SwayAmount
	local strafeSwayX = -moveSnap.LocalMoveDirection.X * moveSnap.NormalizedSpeed * 0.045
	local targetSway = Vector3.new(
		math.clamp(-swayMouseX * 0.0028, -0.09, 0.09) + strafeSwayX,
		math.clamp(swayMouseY * 0.0028, -0.09, 0.09),
		math.clamp(-swayMouseX * 0.004, -0.14, 0.14) - moveSnap.LocalMoveDirection.X * 0.06
	) * swayDampen
	swaySpring:SetTarget(targetSway)
	local sway = swaySpring:Update(dt)

	-- Procedural figure-8 walk & sprint bobbing
	local bobTarget = Vector3.zero
	if moveSnap.IsGrounded and moveSnap.NormalizedSpeed > 0.08 then
		local bobFreq = if effectiveSprint then 12.5 else 8.2
		bobTimer += dt * bobFreq * (0.4 + moveSnap.NormalizedSpeed * 0.6)
		local bobScale = (1 - adsAlpha * 0.88) * moveSnap.NormalizedSpeed * def.BobAmount
		local sprintMult = if effectiveSprint then 1.45 else 1.0
		bobTarget = Vector3.new(
			math.cos(bobTimer) * 0.028 * bobScale * sprintMult,
			math.abs(math.sin(bobTimer)) * -0.024 * bobScale * sprintMult,
			math.sin(bobTimer * 2) * 0.012 * bobScale
		)
	else
		-- Subtle idle breathing sway
		bobTimer += dt * 1.6
		local breathScale = 1 - adsAlpha * 0.55
		bobTarget = Vector3.new(
			math.cos(bobTimer * 0.7) * 0.003 * breathScale,
			math.sin(bobTimer) * 0.004 * breathScale,
			0
		)
	end
	bobSpring:SetTarget(bobTarget)
	local bob = bobSpring:Update(dt)

	-- Visual recoil & bolt blowback
	local recoilPos = recoilPosSpring:Update(dt)
	local recoilRot = recoilRotSpring:Update(dt)
	local boltOffset = math.clamp(boltSpring:Update(dt), 0, def.BoltKickDistance * 1.25)

	-- Procedural reload & mag-check offsets
	local reloadCFrame = CFrame.identity
	local magAnimOffset = Vector3.zero
	local boltExtraOffset = 0

	if isReloading then
		local progress = math.clamp((os.clock() - reloadStartTime) / reloadDuration, 0, 1)
		local tiltAlpha = math.sin(math.clamp(progress * 1.15, 0, 1) * math.pi)
		reloadCFrame = CFrame.new(-0.14 * tiltAlpha, -0.22 * tiltAlpha, 0.08 * tiltAlpha)
			* CFrame.Angles(math.rad(-18 * tiltAlpha), math.rad(28 * tiltAlpha), math.rad(16 * tiltAlpha))

		if progress > 0.18 and progress < 0.78 then
			local magWave = math.sin(((progress - 0.18) / 0.60) * math.pi)
			magAnimOffset = Vector3.new(0, -0.58 * magWave, 0.12 * magWave)
		end

		if isEmptyReload and progress > 0.76 and progress < 0.96 then
			local boltWave = math.sin(((progress - 0.76) / 0.20) * math.pi)
			boltExtraOffset = def.BoltKickDistance * boltWave
		end

		if progress >= 1 then
			ViewmodelController.StopReloadAnimation()
		end
	end

	if boltWeld then
		boltWeld.C0 = boltBaseC0 * CFrame.new(0, 0, boltOffset + boltExtraOffset)
	end
	if magWeld then
		magWeld.C0 = magBaseC0 * CFrame.new(magAnimOffset)
	end

	-- Pose blending: Hipfire -> Sprint -> ADS -> Equip/Inspect/Reload
	local basePose = def.ViewmodelOffset:Lerp(def.SprintOffset, sprintAlpha)
	local adsPose = CFrame.new(0, 0, -def.AdsEyeDistance) * aimToHandleOffset
	local aimedPose = basePose:Lerp(adsPose, adsAlpha)

	local inspectCFrame = CFrame.new(-0.18 * inspectAlpha, -0.05 * inspectAlpha, 0.14 * inspectAlpha)
		* CFrame.Angles(math.rad(6 * inspectAlpha), math.rad(32 * inspectAlpha), math.rad(-18 * inspectAlpha))
	local equipCFrame = CFrame.new(0, -0.65 * equipAlpha, 0.25 * equipAlpha)
		* CFrame.Angles(math.rad(-26 * equipAlpha), 0, 0)
	local grenadeCFrame = CFrame.new(-0.22 * grenadeAlpha, -0.32 * grenadeAlpha, 0.16 * grenadeAlpha)
		* CFrame.Angles(math.rad(-22 * grenadeAlpha), math.rad(16 * grenadeAlpha), math.rad(12 * grenadeAlpha))

	local swayCFrame = CFrame.new(sway.X + bob.X, sway.Y + bob.Y, bob.Z)
		* CFrame.Angles(sway.Y * 0.85, -sway.X * 0.85, sway.Z)
	local recoilCFrame = CFrame.new(recoilPos.X, recoilPos.Y, recoilPos.Z)
		* CFrame.Angles(recoilRot.X, recoilRot.Y, recoilRot.Z)

	local finalLocalCFrame = aimedPose * swayCFrame * recoilCFrame * reloadCFrame * inspectCFrame * equipCFrame * grenadeCFrame
	handle.CFrame = camera.CFrame * finalLocalCFrame

	-- Hide 3D sniper viewmodel once zoomed into the 2D scope overlay so the scope mesh does not block view.
	local hideForScope = def.ModelSpec.OpticType == "Scope" and adsAlpha >= SCOPE_OVERLAY_ADS_THRESHOLD
	local targetLocalTrans = if hideForScope then 1 else 0
	if weaponClone then
		for _, desc in ipairs(weaponClone:GetDescendants()) do
			if desc:IsA("BasePart") then
				desc.LocalTransparencyModifier = targetLocalTrans
			end
		end
	end
end

return ViewmodelController
