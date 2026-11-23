--!strict
-- Server bootstrapper: ensures ReplicatedStorage contracts, procedural 3D weapon models,
-- initial map/Lighting setup via MapService, and deterministic service startup.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapConfig = require(Shared.MapConfig)
local NetworkTypes = require(Shared.NetworkTypes)
local WeaponConfig = require(Shared.WeaponConfig)

local ServerFolder = script.Parent
local CombatService = require(ServerFolder.CombatService)
local GameLoopService = require(ServerFolder.GameLoopService)
local MapService = require(ServerFolder.MapService)
local SpawnService = require(ServerFolder.SpawnService)

Players.CharacterAutoLoads = false

local function ensureFolder(parent: Instance, name: string): Folder
	local existing = parent:FindFirstChild(name)
	if existing and existing:IsA("Folder") then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = name
	folder.Parent = parent
	return folder
end

local function ensureRemotes(): ()
	local remotesFolder = ensureFolder(ReplicatedStorage, NetworkTypes.REMOTES_FOLDER_NAME)
	for _, def in ipairs(NetworkTypes.RemoteDefinitions) do
		if not remotesFolder:FindFirstChild(def.Name) then
			local remote = Instance.new(def.ClassName)
			remote.Name = def.Name
			remote.Parent = remotesFolder
		end
	end
end

local function createWeaponPart(
	parent: Instance,
	name: string,
	size: Vector3,
	localCFrame: CFrame,
	color: Color3,
	material: Enum.Material,
	handle: BasePart,
	transparency: number?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = handle.CFrame * localCFrame
	part.Color = color
	part.Material = material
	part.Transparency = transparency or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Anchored = false
	part.CanCollide = false
	part.CanQuery = false
	part.CastShadow = (transparency or 0) < 0.9
	part.Massless = true
	part.Parent = parent

	local weld = Instance.new("WeldConstraint")
	weld.Part0 = handle
	weld.Part1 = part
	weld.Parent = part

	return part
end

local function buildProceduralWeaponModel(def: WeaponConfig.WeaponDefinition): Model
	local spec = def.ModelSpec
	local model = Instance.new("Model")
	model.Name = def.Id

	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.18, 0.18, 0.18)
	handle.CFrame = CFrame.new(0, 0, 0)
	handle.Transparency = 1
	handle.Anchored = false
	handle.CanCollide = false
	handle.CanQuery = false
	handle.CastShadow = false
	handle.Massless = true
	handle.Parent = model
	model.PrimaryPart = handle

	-- Receiver
	createWeaponPart(model, "Receiver", spec.ReceiverSize, CFrame.new(0, 0, 0), spec.BodyColor, Enum.Material.Metal, handle)

	-- Barrel
	createWeaponPart(
		model,
		"Barrel",
		spec.BarrelSize,
		CFrame.new(spec.BarrelOffset),
		spec.MetalColor,
		Enum.Material.Metal,
		handle
	)

	if spec.HasSuppressor then
		local suppSize = Vector3.new(spec.BarrelSize.X * 1.45, spec.BarrelSize.Y * 1.45, 0.56)
		createWeaponPart(
			model,
			"Suppressor",
			suppSize,
			CFrame.new(spec.MuzzleOffset + Vector3.new(0, 0, 0.24)),
			spec.MetalColor,
			Enum.Material.SmoothPlastic,
			handle
		)
	end

	-- Optional Handguard & Stock
	if spec.HandguardSize and spec.HandguardOffset then
		createWeaponPart(
			model,
			"Handguard",
			spec.HandguardSize,
			CFrame.new(spec.HandguardOffset),
			spec.AccentColor,
			Enum.Material.Plastic,
			handle
		)
	end

	if spec.StockSize and spec.StockOffset then
		createWeaponPart(
			model,
			"Stock",
			spec.StockSize,
			CFrame.new(spec.StockOffset),
			spec.BodyColor,
			Enum.Material.Plastic,
			handle
		)
	end

	-- Grip & Magazine
	createWeaponPart(
		model,
		"Grip",
		spec.GripSize,
		CFrame.new(spec.GripOffset) * CFrame.Angles(math.rad(-14), 0, 0),
		spec.AccentColor,
		Enum.Material.Plastic,
		handle
	)
	createWeaponPart(
		model,
		"Magazine",
		spec.MagazineSize,
		CFrame.new(spec.MagazineOffset) * CFrame.Angles(math.rad(6), 0, 0),
		spec.MetalColor,
		Enum.Material.Metal,
		handle
	)

	-- Animated Bolt (welded to Handle; ViewmodelController offsets Weld/Part during recoil)
	createWeaponPart(
		model,
		"Bolt",
		spec.BoltSize,
		CFrame.new(spec.BoltOffset),
		Color3.fromRGB(165, 168, 175),
		Enum.Material.Metal,
		handle
	)

	-- Optics & Sights aligned with AimPart
	if spec.OpticType == "Holo" then
		local baseOffset = spec.OpticOffset
		createWeaponPart(
			model,
			"OpticBase",
			Vector3.new(0.16, 0.05, 0.28),
			CFrame.new(baseOffset + Vector3.new(0, -0.05, 0)),
			spec.MetalColor,
			Enum.Material.Metal,
			handle
		)
		createWeaponPart(
			model,
			"OpticLeftPost",
			Vector3.new(0.025, 0.14, 0.24),
			CFrame.new(baseOffset + Vector3.new(-0.07, 0.04, 0)),
			spec.MetalColor,
			Enum.Material.Metal,
			handle
		)
		createWeaponPart(
			model,
			"OpticRightPost",
			Vector3.new(0.025, 0.14, 0.24),
			CFrame.new(baseOffset + Vector3.new(0.07, 0.04, 0)),
			spec.MetalColor,
			Enum.Material.Metal,
			handle
		)
		createWeaponPart(
			model,
			"OpticTopHood",
			Vector3.new(0.165, 0.025, 0.24),
			CFrame.new(baseOffset + Vector3.new(0, 0.11, 0)),
			spec.MetalColor,
			Enum.Material.Metal,
			handle
		)
		createWeaponPart(
			model,
			"OpticLens",
			Vector3.new(0.12, 0.11, 0.02),
			CFrame.new(baseOffset + Vector3.new(0, 0.03, 0)),
			Color3.fromRGB(150, 210, 255),
			Enum.Material.Glass,
			handle,
			0.78
		)
		local reticle = createWeaponPart(
			model,
			"ReticleDot",
			Vector3.new(0.012, 0.012, 0.012),
			CFrame.new(spec.AimOffset.X, spec.AimOffset.Y, baseOffset.Z),
			Color3.fromRGB(255, 50, 50),
			Enum.Material.Neon,
			handle
		)
		reticle.CastShadow = false
	elseif spec.OpticType == "Scope" then
		local baseOffset = spec.OpticOffset
		local tube = createWeaponPart(
			model,
			"ScopeTube",
			Vector3.new(0.14, 0.14, 0.72),
			CFrame.new(baseOffset),
			spec.MetalColor,
			Enum.Material.Metal,
			handle
		)
		tube.Shape = Enum.PartType.Block
		createWeaponPart(
			model,
			"ScopeFrontBell",
			Vector3.new(0.18, 0.18, 0.20),
			CFrame.new(baseOffset + Vector3.new(0, 0, -0.34)),
			spec.MetalColor,
			Enum.Material.Metal,
			handle
		)
		createWeaponPart(
			model,
			"ScopeLensFront",
			Vector3.new(0.14, 0.14, 0.02),
			CFrame.new(baseOffset + Vector3.new(0, 0, -0.44)),
			Color3.fromRGB(90, 175, 220),
			Enum.Material.Glass,
			handle,
			0.55
		)
		createWeaponPart(
			model,
			"ScopeLensRear",
			Vector3.new(0.11, 0.11, 0.02),
			CFrame.new(baseOffset + Vector3.new(0, 0, 0.36)),
			Color3.fromRGB(110, 185, 230),
			Enum.Material.Glass,
			handle,
			0.65
		)
	else
		-- Iron sights: rear notch + front post aligned with AimOffset
		local rearOffset = spec.OpticOffset
		createWeaponPart(
			model,
			"RearSightLeft",
			Vector3.new(0.024, 0.055, 0.04),
			CFrame.new(rearOffset + Vector3.new(-0.028, 0.01, 0)),
			spec.MetalColor,
			Enum.Material.Metal,
			handle
		)
		createWeaponPart(
			model,
			"RearSightRight",
			Vector3.new(0.024, 0.055, 0.04),
			CFrame.new(rearOffset + Vector3.new(0.028, 0.01, 0)),
			spec.MetalColor,
			Enum.Material.Metal,
			handle
		)
		local frontZ = spec.MuzzleOffset.Z + 0.16
		createWeaponPart(
			model,
			"FrontSightPost",
			Vector3.new(0.018, 0.05, 0.03),
			CFrame.new(0, spec.AimOffset.Y - 0.01, frontZ),
			Color3.fromRGB(120, 255, 140),
			Enum.Material.Neon,
			handle
		)
	end

	-- Mandatory AimPart & Muzzle markers
	createWeaponPart(
		model,
		"AimPart",
		Vector3.new(0.06, 0.06, 0.06),
		CFrame.new(spec.AimOffset),
		Color3.fromRGB(0, 255, 0),
		Enum.Material.SmoothPlastic,
		handle,
		1
	)

	local muzzle = createWeaponPart(
		model,
		"Muzzle",
		Vector3.new(0.08, 0.08, 0.08),
		CFrame.new(spec.MuzzleOffset),
		Color3.fromRGB(255, 180, 0),
		Enum.Material.SmoothPlastic,
		handle,
		1
	)

	local muzzleAttachment = Instance.new("Attachment")
	muzzleAttachment.Name = "MuzzleAttachment"
	muzzleAttachment.Parent = muzzle

	local muzzleLight = Instance.new("PointLight")
	muzzleLight.Name = "MuzzleLight"
	muzzleLight.Color = Color3.fromRGB(255, 195, 110)
	muzzleLight.Brightness = 3.5
	muzzleLight.Range = 14
	muzzleLight.Enabled = false
	muzzleLight.Parent = muzzle

	return model
end

local function ensureWeapons(): ()
	local weaponsFolder = ensureFolder(ReplicatedStorage, NetworkTypes.WEAPONS_FOLDER_NAME)
	for _, weaponId in ipairs(WeaponConfig.WeaponOrder) do
		if not weaponsFolder:FindFirstChild(weaponId) then
			local def = WeaponConfig.GetWeapon(weaponId)
			if def then
				local model = buildProceduralWeaponModel(def)
				model.Parent = weaponsFolder
			end
		end
	end
end

--// Startup Sequence
ensureRemotes()
ensureWeapons()
MapService.LoadMap(MapConfig.DEFAULT_MAP_ID)

SpawnService.Init()
GameLoopService.Init(SpawnService, MapService, CombatService.ClearAllProjectiles)
CombatService.Init(GameLoopService, SpawnService)

GameLoopService.SetOnPlayerSpawned(CombatService.OnPlayerSpawned)
GameLoopService.SetOnPlayerCleanup(CombatService.CleanupPlayerCharacter)

assert(ServerScriptService ~= nil, "Bootstrap running in unexpected context")
