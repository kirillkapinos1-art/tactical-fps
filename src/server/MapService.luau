--!strict
-- Procedural tactical map builder & per-map Lighting configurator.
-- Builds 4 distinct arenas (ProvingGround, WarehouseCQB, DesertOutpost, CargoDocks)
-- cleanly in Workspace.TacticalArena and Workspace.SpawnLocations.

local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapConfig = require(Shared.MapConfig)

local MapService = {}

local currentMapId = MapConfig.DEFAULT_MAP_ID

local function createBlock(
	parent: Instance,
	name: string,
	size: Vector3,
	cframe: CFrame,
	color: Color3,
	material: Enum.Material,
	transparency: number?,
	canCollide: boolean?
): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Anchored = true
	part.CanCollide = if canCollide ~= nil then canCollide else true
	part.CanQuery = true
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Transparency = transparency or 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

-- Creates a walk-friendly ramp whose top surface connects fromPos to toPos flush.
local function createRamp(
	parent: Instance,
	name: string,
	width: number,
	thickness: number,
	fromPos: Vector3,
	toPos: Vector3,
	color: Color3,
	material: Enum.Material
): Part
	local delta = toPos - fromPos
	local length = delta.Magnitude
	local mid = (fromPos + toPos) * 0.5
	local oriented = CFrame.lookAt(mid, toPos)
	local flushCenter = oriented - oriented.UpVector * (thickness * 0.5)
	return createBlock(parent, name, Vector3.new(width, thickness, length), flushCenter, color, material)
end

local function createSpawnPad(parent: Instance, name: string, position: Vector3): SpawnLocation
	local pad = Instance.new("SpawnLocation")
	pad.Name = name
	pad.Anchored = true
	pad.CanCollide = true
	pad.CanQuery = false
	pad.Duration = 0
	pad.Neutral = true
	pad.Enabled = true
	pad.Size = Vector3.new(6, 0.5, 6)
	pad.Position = position
	pad.Color = Color3.fromRGB(62, 68, 76)
	pad.Material = Enum.Material.Concrete
	pad.Transparency = 0.4
	pad.TopSurface = Enum.SurfaceType.Smooth
	pad.BottomSurface = Enum.SurfaceType.Smooth
	pad.Parent = parent
	return pad
end

local function createOpenContainer(
	parent: Instance,
	name: string,
	cframe: CFrame,
	outerSize: Vector3,
	color: Color3,
	material: Enum.Material
): ()
	local wallT = 0.45
	local floorT = 0.28
	local roofT = 0.45
	local w = outerSize.X
	local h = outerSize.Y
	local l = outerSize.Z

	createBlock(parent, `{name}_Floor`, Vector3.new(w, floorT, l), cframe * CFrame.new(0, -h * 0.5 + floorT * 0.5, 0), color, material)
	createBlock(parent, `{name}_Roof`, Vector3.new(w, roofT, l), cframe * CFrame.new(0, h * 0.5 - roofT * 0.5, 0), color, material)
	createBlock(parent, `{name}_WallL`, Vector3.new(wallT, h, l), cframe * CFrame.new(-w * 0.5 + wallT * 0.5, 0, 0), color, material)
	createBlock(parent, `{name}_WallR`, Vector3.new(wallT, h, l), cframe * CFrame.new(w * 0.5 - wallT * 0.5, 0, 0), color, material)
end

local function createLightFixture(
	parent: Instance,
	name: string,
	position: Vector3,
	lightColor: Color3,
	brightness: number,
	range: number
): ()
	local lamp = createBlock(
		parent,
		name,
		Vector3.new(5.5, 0.4, 1.4),
		CFrame.new(position),
		lightColor,
		Enum.Material.Neon
	)
	lamp.CastShadow = false

	local pt = Instance.new("PointLight")
	pt.Color = lightColor
	pt.Brightness = brightness
	pt.Range = range
	pt.Shadows = false
	pt.Parent = lamp
end

local function addSpawnList(spawnsFolder: Folder, points: { Vector3 }): ()
	for i, pos in ipairs(points) do
		createSpawnPad(spawnsFolder, `SpawnPad_{i}`, pos)
	end
end

local function applyLightingPreset(preset: MapConfig.MapLightingPreset): ()
	pcall(function()
		(Lighting :: any).Technology = Enum.Technology.Future
	end)

	Lighting.ClockTime = preset.ClockTime
	Lighting.Brightness = preset.Brightness
	Lighting.GlobalShadows = true
	Lighting.ShadowSoftness = preset.ShadowSoftness
	Lighting.Ambient = preset.Ambient
	Lighting.OutdoorAmbient = preset.OutdoorAmbient
	Lighting.EnvironmentDiffuseScale = 0.85
	Lighting.EnvironmentSpecularScale = 1.0
	Lighting.ExposureCompensation = preset.ExposureCompensation

	local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
	if not atmosphere then
		atmosphere = Instance.new("Atmosphere")
		atmosphere.Parent = Lighting
	end
	atmosphere.Density = preset.AtmosphereDensity
	atmosphere.Offset = preset.AtmosphereOffset
	atmosphere.Color = preset.AtmosphereColor
	atmosphere.Decay = preset.AtmosphereDecay
	atmosphere.Glare = preset.AtmosphereGlare
	atmosphere.Haze = preset.AtmosphereHaze

	local cc = Lighting:FindFirstChild("TacticalColorCorrection")
	if not cc or not cc:IsA("ColorCorrectionEffect") then
		cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "TacticalColorCorrection"
		cc.Parent = Lighting
	end
	local colorCorrection = cc :: ColorCorrectionEffect
	colorCorrection.Enabled = true
	colorCorrection.Brightness = preset.ColorCorrectionBrightness
	colorCorrection.Contrast = preset.ColorCorrectionContrast
	colorCorrection.Saturation = preset.ColorCorrectionSaturation
	colorCorrection.TintColor = preset.ColorCorrectionTint

	local dof = Lighting:FindFirstChild("AdsDepthOfField")
	if not dof or not dof:IsA("DepthOfFieldEffect") then
		dof = Instance.new("DepthOfFieldEffect")
		dof.Name = "AdsDepthOfField"
		dof.Parent = Lighting
	end
	local depthOfField = dof :: DepthOfFieldEffect
	depthOfField.Enabled = false
	depthOfField.FarIntensity = 0.28
	depthOfField.NearIntensity = 0.12
	depthOfField.FocusDistance = 65
	depthOfField.InFocusRadius = 38
end

-- Map 1: ProvingGround (Classic mixed industrial proving ground, 220x220)
local function buildProvingGround(arenaFolder: Folder, spawnsFolder: Folder): ()
	local concreteColor = Color3.fromRGB(115, 118, 122)
	local darkConcrete = Color3.fromRGB(78, 82, 88)
	local woodColor = Color3.fromRGB(142, 104, 68)
	local plasterColor = Color3.fromRGB(205, 200, 188)
	local metalColor = Color3.fromRGB(74, 86, 94)

	createBlock(arenaFolder, "ArenaFloor", Vector3.new(220, 1, 220), CFrame.new(0, -0.4, 0), darkConcrete, Enum.Material.Asphalt)

	createBlock(arenaFolder, "PerimeterNorth", Vector3.new(224, 18, 4), CFrame.new(0, 9, -110), concreteColor, Enum.Material.Concrete)
	createBlock(arenaFolder, "PerimeterSouth", Vector3.new(224, 18, 4), CFrame.new(0, 9, 110), concreteColor, Enum.Material.Concrete)
	createBlock(arenaFolder, "PerimeterEast", Vector3.new(4, 18, 220), CFrame.new(110, 9, 0), concreteColor, Enum.Material.Concrete)
	createBlock(arenaFolder, "PerimeterWest", Vector3.new(4, 18, 220), CFrame.new(-110, 9, 0), concreteColor, Enum.Material.Concrete)

	createBlock(arenaFolder, "CenterBridge", Vector3.new(24, 1.5, 56), CFrame.new(0, 10, 0), darkConcrete, Enum.Material.Concrete)
	createBlock(arenaFolder, "BridgeCoverEast", Vector3.new(1.2, 3.6, 44), CFrame.new(11.4, 12.5, 0), woodColor, Enum.Material.WoodPlanks)
	createBlock(arenaFolder, "BridgeCoverWest", Vector3.new(1.2, 3.6, 44), CFrame.new(-11.4, 12.5, 0), woodColor, Enum.Material.WoodPlanks)

	createBlock(
		arenaFolder,
		"BridgeRampNorth",
		Vector3.new(14, 1.2, 30),
		CFrame.new(0, 5.2, -41.5) * CFrame.Angles(math.rad(-20.5), 0, 0),
		concreteColor,
		Enum.Material.Concrete
	)
	createBlock(
		arenaFolder,
		"BridgeRampSouth",
		Vector3.new(14, 1.2, 30),
		CFrame.new(0, 5.2, 41.5) * CFrame.Angles(math.rad(20.5), 0, 0),
		concreteColor,
		Enum.Material.Concrete
	)

	for _, zPos in ipairs({ -22, 22 }) do
		for _, xPos in ipairs({ -10, 10 }) do
			createBlock(arenaFolder, "BridgePillar", Vector3.new(3.5, 10, 3.5), CFrame.new(xPos, 5, zPos), concreteColor, Enum.Material.Concrete)
		end
	end

	local woodCovers = {
		{ pos = Vector3.new(-32, 3, -18), size = Vector3.new(1.4, 6, 16) },
		{ pos = Vector3.new(32, 3, 18), size = Vector3.new(1.4, 6, 16) },
		{ pos = Vector3.new(-46, 2.5, 28), size = Vector3.new(12, 5, 1.5) },
		{ pos = Vector3.new(46, 2.5, -28), size = Vector3.new(12, 5, 1.5) },
		{ pos = Vector3.new(-22, 2.5, 48), size = Vector3.new(5, 5, 5) },
		{ pos = Vector3.new(22, 2.5, -48), size = Vector3.new(5, 5, 5) },
	}
	for idx, item in ipairs(woodCovers) do
		createBlock(arenaFolder, `WoodCover_{idx}`, item.size, CFrame.new(item.pos), woodColor, Enum.Material.Wood)
	end

	for _, side in ipairs({ -1, 1 }) do
		local cx = side * 66
		local tag = if side < 0 then "West" else "East"
		createBlock(arenaFolder, `{tag}HousePlasterFront`, Vector3.new(0.8, 10, 26), CFrame.new(cx - side * 12, 5, 0), plasterColor, Enum.Material.Plaster)
		createBlock(arenaFolder, `{tag}HousePlasterSideNW`, Vector3.new(9, 10, 0.8), CFrame.new(cx - 7.5, 5, -13), plasterColor, Enum.Material.Plaster)
		createBlock(arenaFolder, `{tag}HousePlasterSideNE`, Vector3.new(9, 10, 0.8), CFrame.new(cx + 7.5, 5, -13), plasterColor, Enum.Material.Plaster)
		createBlock(arenaFolder, `{tag}HousePlasterSideSW`, Vector3.new(9, 10, 0.8), CFrame.new(cx - 7.5, 5, 13), plasterColor, Enum.Material.Plaster)
		createBlock(arenaFolder, `{tag}HousePlasterSideSE`, Vector3.new(9, 10, 0.8), CFrame.new(cx + 7.5, 5, 13), plasterColor, Enum.Material.Plaster)
		createBlock(arenaFolder, `{tag}HouseWindowSill`, Vector3.new(0.8, 3.8, 26), CFrame.new(cx + side * 12, 1.9, 0), plasterColor, Enum.Material.Plaster)
		createBlock(arenaFolder, `{tag}HouseWindowHeader`, Vector3.new(0.8, 2.5, 26), CFrame.new(cx + side * 12, 8.75, 0), plasterColor, Enum.Material.Plaster)
		createBlock(
			arenaFolder,
			`{tag}HouseGlassPane`,
			Vector3.new(0.25, 3.7, 24),
			CFrame.new(cx + side * 12, 5.65, 0),
			Color3.fromRGB(165, 210, 230),
			Enum.Material.Glass,
			0.55
		)
		createBlock(arenaFolder, `{tag}FlankShield`, Vector3.new(3.5, 9, 14), CFrame.new(cx + side * 20, 4.5, 0), concreteColor, Enum.Material.Concrete)
	end

	local bunkerPositions = {
		{ x = -82, z = -82, sx = 1, sz = 1 },
		{ x = 82, z = -82, sx = -1, sz = 1 },
		{ x = -82, z = 82, sx = 1, sz = -1 },
		{ x = 82, z = 82, sx = -1, sz = -1 },
	}
	for i, b in ipairs(bunkerPositions) do
		createBlock(arenaFolder, `CornerBunkerA_{i}`, Vector3.new(22, 10, 3.5), CFrame.new(b.x + b.sx * 10, 5, b.z + b.sz * 14), concreteColor, Enum.Material.Concrete)
		createBlock(arenaFolder, `CornerBunkerB_{i}`, Vector3.new(3.5, 10, 22), CFrame.new(b.x + b.sx * 14, 5, b.z + b.sz * 4), concreteColor, Enum.Material.Concrete)
	end

	createBlock(arenaFolder, "ContainerNW", Vector3.new(10, 8, 20), CFrame.new(-42, 4, -56), metalColor, Enum.Material.CorrodedMetal)
	createBlock(arenaFolder, "ContainerSE", Vector3.new(10, 8, 20), CFrame.new(42, 4, 56), metalColor, Enum.Material.CorrodedMetal)

	addSpawnList(spawnsFolder, {
		Vector3.new(-92, 0.35, -92),
		Vector3.new(92, 0.35, -92),
		Vector3.new(-92, 0.35, 92),
		Vector3.new(92, 0.35, 92),
		Vector3.new(0, 0.35, -88),
		Vector3.new(0, 0.35, 88),
		Vector3.new(-88, 0.35, 0),
		Vector3.new(88, 0.35, 0),
	})
end

-- Map 2: WarehouseCQB ("Склад «Север»", 180x180 close-quarters night warehouse)
local function buildWarehouseCQB(arenaFolder: Folder, spawnsFolder: Folder): ()
	local floorColor = Color3.fromRGB(58, 62, 68)
	local wallColor = Color3.fromRGB(72, 78, 86)
	local steelColor = Color3.fromRGB(48, 56, 66)
	local safetyYellow = Color3.fromRGB(205, 162, 54)
	local woodColor = Color3.fromRGB(148, 112, 74)
	local cardboardColor = Color3.fromRGB(168, 134, 94)
	local plasterColor = Color3.fromRGB(196, 194, 186)
	local warmLamp = Color3.fromRGB(255, 218, 168)

	createBlock(arenaFolder, "WarehouseFloor", Vector3.new(180, 1, 180), CFrame.new(0, -0.4, 0), floorColor, Enum.Material.Slate)

	-- Outer hangar walls & structural rafters
	createBlock(arenaFolder, "WallNorth", Vector3.new(184, 26, 4), CFrame.new(0, 13, -90), wallColor, Enum.Material.Concrete)
	createBlock(arenaFolder, "WallSouth", Vector3.new(184, 26, 4), CFrame.new(0, 13, 90), wallColor, Enum.Material.Concrete)
	createBlock(arenaFolder, "WallEast", Vector3.new(4, 26, 180), CFrame.new(90, 13, 0), wallColor, Enum.Material.Concrete)
	createBlock(arenaFolder, "WallWest", Vector3.new(4, 26, 180), CFrame.new(-90, 13, 0), wallColor, Enum.Material.Concrete)

	-- Side roof eaves + open skylight trusses + warm floodlights
	createBlock(arenaFolder, "RoofEaveWest", Vector3.new(46, 1.2, 180), CFrame.new(-66, 25.4, 0), steelColor, Enum.Material.Metal)
	createBlock(arenaFolder, "RoofEaveEast", Vector3.new(46, 1.2, 180), CFrame.new(66, 25.4, 0), steelColor, Enum.Material.Metal)
	for _, zBeam in ipairs({ -60, -20, 20, 60 }) do
		createBlock(arenaFolder, "RoofTruss", Vector3.new(90, 1.4, 2.2), CFrame.new(0, 25.0, zBeam), steelColor, Enum.Material.Metal)
		createLightFixture(arenaFolder, `BayLampL_{zBeam}`, Vector3.new(-28, 22.8, zBeam), warmLamp, 2.0, 58)
		createLightFixture(arenaFolder, `BayLampR_{zBeam}`, Vector3.new(28, 22.8, zBeam), warmLamp, 2.0, 58)
	end
	createLightFixture(arenaFolder, "CenterLamp", Vector3.new(0, 23.2, 0), warmLamp, 2.3, 64)

	-- West 2-story Dispatch Office (X = -72..-46, Z = -34..34, second floor Y = 9.5..10.0)
	createBlock(arenaFolder, "OfficeDeck", Vector3.new(26, 1, 68), CFrame.new(-59, 9.5, 0), steelColor, Enum.Material.DiamondPlate)
	for _, zPil in ipairs({ -30, 0, 30 }) do
		createBlock(arenaFolder, `OfficePillar_{zPil}`, Vector3.new(2.5, 9.2, 2.5), CFrame.new(-47.5, 4.6, zPil), safetyYellow, Enum.Material.Metal)
	end
	createRamp(arenaFolder, "OfficeRampNorth", 10, 0.9, Vector3.new(-58, 0.1, -66), Vector3.new(-58, 10.0, -34), steelColor, Enum.Material.DiamondPlate)
	createRamp(arenaFolder, "OfficeRampSouth", 10, 0.9, Vector3.new(-58, 0.1, 66), Vector3.new(-58, 10.0, 34), steelColor, Enum.Material.DiamondPlate)

	-- Second-floor wallbang parapet & glass observation windows
	createBlock(arenaFolder, "OfficeWindowSill", Vector3.new(0.8, 3.6, 56), CFrame.new(-46.4, 11.8, 0), plasterColor, Enum.Material.Plaster)
	createBlock(arenaFolder, "OfficeWindowHeader", Vector3.new(0.8, 2.2, 68), CFrame.new(-46.4, 18.6, 0), plasterColor, Enum.Material.Plaster)
	createBlock(arenaFolder, "OfficeGlass", Vector3.new(0.25, 4.0, 54), CFrame.new(-46.4, 15.6, 0), Color3.fromRGB(168, 212, 228), Enum.Material.Glass, 0.55)
	-- Interior plaster office divider on 2nd floor
	createBlock(arenaFolder, "OfficeDividerN", Vector3.new(10, 7.5, 0.8), CFrame.new(-64, 13.7, -8), plasterColor, Enum.Material.Plaster)
	createBlock(arenaFolder, "OfficeDividerS", Vector3.new(10, 7.5, 0.8), CFrame.new(-52, 13.7, 10), plasterColor, Enum.Material.Plaster)
	-- Ground floor storage room wall under office with doorways
	createBlock(arenaFolder, "UnderOfficeWallN", Vector3.new(0.8, 9.0, 22), CFrame.new(-47.5, 4.5, -20), plasterColor, Enum.Material.Plaster)
	createBlock(arenaFolder, "UnderOfficeWallS", Vector3.new(0.8, 9.0, 22), CFrame.new(-47.5, 4.5, 20), plasterColor, Enum.Material.Plaster)

	-- Central elevated loading catwalk & ramps
	createBlock(arenaFolder, "CenterCatwalk", Vector3.new(16, 1.0, 36), CFrame.new(0, 7.0, 0), steelColor, Enum.Material.DiamondPlate)
	createRamp(arenaFolder, "CatwalkRampN", 10, 0.8, Vector3.new(0, 0.1, -42), Vector3.new(0, 7.5, -18), steelColor, Enum.Material.DiamondPlate)
	createRamp(arenaFolder, "CatwalkRampS", 10, 0.8, Vector3.new(0, 0.1, 42), Vector3.new(0, 7.5, 18), steelColor, Enum.Material.DiamondPlate)
	createBlock(arenaFolder, "CatwalkCoverW", Vector3.new(1.0, 3.4, 28), CFrame.new(-7.5, 9.2, 0), woodColor, Enum.Material.WoodPlanks)
	createBlock(arenaFolder, "CatwalkCoverE", Vector3.new(1.0, 3.4, 28), CFrame.new(7.5, 9.2, 0), woodColor, Enum.Material.WoodPlanks)

	-- 4 industrial rack rows with wallbang wooden/cardboard crates
	local rackX = { -22, 22 }
	local rackZ = { -32, 32 }
	for _, rx in ipairs(rackX) do
		for _, rz in ipairs(rackZ) do
			createBlock(arenaFolder, `RackShelfA_{rx}_{rz}`, Vector3.new(7, 0.6, 22), CFrame.new(rx, 5.5, rz), woodColor, Enum.Material.WoodPlanks)
			createBlock(arenaFolder, `RackPost1_{rx}_{rz}`, Vector3.new(0.9, 10, 0.9), CFrame.new(rx - 3, 5, rz - 10), safetyYellow, Enum.Material.Metal)
			createBlock(arenaFolder, `RackPost2_{rx}_{rz}`, Vector3.new(0.9, 10, 0.9), CFrame.new(rx + 3, 5, rz - 10), safetyYellow, Enum.Material.Metal)
			createBlock(arenaFolder, `RackPost3_{rx}_{rz}`, Vector3.new(0.9, 10, 0.9), CFrame.new(rx - 3, 5, rz + 10), safetyYellow, Enum.Material.Metal)
			createBlock(arenaFolder, `RackPost4_{rx}_{rz}`, Vector3.new(0.9, 10, 0.9), CFrame.new(rx + 3, 5, rz + 10), safetyYellow, Enum.Material.Metal)
			-- Floor-level wallbangable cargo crates inside racks
			createBlock(arenaFolder, `CrateWood_{rx}_{rz}`, Vector3.new(5.2, 4.8, 7), CFrame.new(rx, 2.4, rz - 5), woodColor, Enum.Material.Wood)
			createBlock(arenaFolder, `CrateBox_{rx}_{rz}`, Vector3.new(4.8, 4.0, 6), CFrame.new(rx, 2.0, rz + 5), cardboardColor, Enum.Material.Cardboard)
			createBlock(arenaFolder, `UpperCrate_{rx}_{rz}`, Vector3.new(4.5, 3.5, 6), CFrame.new(rx, 7.55, rz), cardboardColor, Enum.Material.Cardboard)
		end
	end

	-- East loading bay platform & hollow cargo trailers
	createBlock(arenaFolder, "LoadingBayDeck", Vector3.new(18, 4.0, 96), CFrame.new(79, 2.0, 0), wallColor, Enum.Material.Concrete)
	createRamp(arenaFolder, "BayRampN", 12, 0.8, Vector3.new(78, 0.1, -64), Vector3.new(78, 4.0, -48), wallColor, Enum.Material.Concrete)
	createRamp(arenaFolder, "BayRampS", 12, 0.8, Vector3.new(78, 0.1, 64), Vector3.new(78, 4.0, 48), wallColor, Enum.Material.Concrete)

	createOpenContainer(arenaFolder, "TrailerNorth", CFrame.new(52, 4.25, -34), Vector3.new(9, 8.3, 24), Color3.fromRGB(58, 76, 94), Enum.Material.CorrodedMetal)
	createOpenContainer(arenaFolder, "TrailerSouth", CFrame.new(52, 4.25, 34), Vector3.new(9, 8.3, 24), Color3.fromRGB(118, 62, 52), Enum.Material.CorrodedMetal)

	-- Spawn protection baffles near N/S gates & corners
	createBlock(arenaFolder, "GateShieldN", Vector3.new(18, 7, 2.8), CFrame.new(0, 3.5, -66), wallColor, Enum.Material.Concrete)
	createBlock(arenaFolder, "GateShieldS", Vector3.new(18, 7, 2.8), CFrame.new(0, 3.5, 66), wallColor, Enum.Material.Concrete)
	createBlock(arenaFolder, "CornerShieldNW", Vector3.new(14, 7, 2.5), CFrame.new(-74, 3.5, -70), wallColor, Enum.Material.Concrete)
	createBlock(arenaFolder, "CornerShieldSW", Vector3.new(14, 7, 2.5), CFrame.new(-74, 3.5, 70), wallColor, Enum.Material.Concrete)
	createBlock(arenaFolder, "CornerShieldNE", Vector3.new(2.5, 7, 16), CFrame.new(68, 3.5, -74), wallColor, Enum.Material.Concrete)
	createBlock(arenaFolder, "CornerShieldSE", Vector3.new(2.5, 7, 16), CFrame.new(68, 3.5, 74), wallColor, Enum.Material.Concrete)

	addSpawnList(spawnsFolder, {
		Vector3.new(-80, 0.35, -80),
		Vector3.new(80, 0.35, -80),
		Vector3.new(-80, 0.35, 80),
		Vector3.new(80, 0.35, 80),
		Vector3.new(0, 0.35, -78),
		Vector3.new(0, 0.35, 78),
		Vector3.new(-74, 0.35, 0),
		Vector3.new(40, 0.35, 0),
	})
end

-- Map 3: DesertOutpost ("Блокпост «Каньон»", 260x260 long-range desert canyon & watchtowers)
local function buildDesertOutpost(arenaFolder: Folder, spawnsFolder: Folder): ()
	local sandColor = Color3.fromRGB(204, 174, 128)
	local roadColor = Color3.fromRGB(132, 122, 108)
	local sandstoneColor = Color3.fromRGB(184, 146, 102)
	local rockColor = Color3.fromRGB(142, 108, 78)
	local hescoColor = Color3.fromRGB(168, 152, 122)
	local woodColor = Color3.fromRGB(132, 92, 56)
	local plasterColor = Color3.fromRGB(214, 198, 170)

	createBlock(arenaFolder, "DesertFloor", Vector3.new(260, 1, 260), CFrame.new(0, -0.4, 0), sandColor, Enum.Material.Sand)
	createBlock(arenaFolder, "ConvoyRoadEW", Vector3.new(258, 0.25, 24), CFrame.new(0, 0.02, 0), roadColor, Enum.Material.Pavement)
	createBlock(arenaFolder, "ConvoyRoadNS", Vector3.new(24, 0.25, 258), CFrame.new(0, 0.02, 0), roadColor, Enum.Material.Pavement)

	-- Stepped canyon cliff perimeter
	createBlock(arenaFolder, "CanyonNorth", Vector3.new(266, 24, 6), CFrame.new(0, 12, -130), rockColor, Enum.Material.Rock)
	createBlock(arenaFolder, "CanyonSouth", Vector3.new(266, 24, 6), CFrame.new(0, 12, 130), rockColor, Enum.Material.Rock)
	createBlock(arenaFolder, "CanyonEast", Vector3.new(6, 24, 260), CFrame.new(130, 12, 0), rockColor, Enum.Material.Rock)
	createBlock(arenaFolder, "CanyonWest", Vector3.new(6, 24, 260), CFrame.new(-130, 12, 0), rockColor, Enum.Material.Rock)

	-- Two sniper watchtowers (NW & SE) with two-stage ramps
	for _, towerCfg in ipairs({
		{ tag = "NW", cx = -86, cz = -86, sx = -1, sz = -1 },
		{ tag = "SE", cx = 86, cz = 86, sx = 1, sz = 1 },
	}) do
		local cx, cz, sx, sz = towerCfg.cx, towerCfg.cz, towerCfg.sx, towerCfg.sz
		createBlock(arenaFolder, `TowerDeck_{towerCfg.tag}`, Vector3.new(18, 1.0, 18), CFrame.new(cx, 12.0, cz), woodColor, Enum.Material.WoodPlanks)
		for _, dx in ipairs({ -7.5, 7.5 }) do
			for _, dz in ipairs({ -7.5, 7.5 }) do
				createBlock(arenaFolder, `TowerLeg_{towerCfg.tag}`, Vector3.new(2.2, 12.0, 2.2), CFrame.new(cx + dx, 6.0, cz + dz), sandstoneColor, Enum.Material.Sandstone)
			end
		end
		-- Parapet facing arena center (wood slats = wallbangable, leaving 7-stud ramp entry gap at back/side)
		createBlock(arenaFolder, `TowerRailInX_{towerCfg.tag}`, Vector3.new(11, 3.6, 1.0), CFrame.new(cx - sx * 3.5, 14.3, cz - sz * 8.5), woodColor, Enum.Material.WoodPlanks)
		createBlock(arenaFolder, `TowerRailInZ_{towerCfg.tag}`, Vector3.new(1.0, 3.6, 18), CFrame.new(cx - sx * 8.5, 14.3, cz), woodColor, Enum.Material.WoodPlanks)
		-- Overhead sun canopy
		createBlock(arenaFolder, `TowerRoof_{towerCfg.tag}`, Vector3.new(19, 0.7, 19), CFrame.new(cx, 20.5, cz), hescoColor, Enum.Material.Fabric)
		for _, dx in ipairs({ -8.2, 8.2 }) do
			for _, dz in ipairs({ -8.2, 8.2 }) do
				createBlock(arenaFolder, `TowerRoofPost_{towerCfg.tag}`, Vector3.new(0.8, 8.0, 0.8), CFrame.new(cx + dx, 16.5, cz + dz), woodColor, Enum.Material.Wood)
			end
		end
		-- Approach ramp from back corner up to deck
		createRamp(
			arenaFolder,
			`TowerRamp_{towerCfg.tag}`,
			6.5,
			0.8,
			Vector3.new(cx + sx * 6, 0.1, cz - sz * 28),
			Vector3.new(cx + sx * 6, 12.5, cz - sz * 9),
			woodColor,
			Enum.Material.WoodPlanks
		)
	end

	-- Central HESCO checkpoint compound
	createBlock(arenaFolder, "HescoNW", Vector3.new(22, 6.5, 3.5), CFrame.new(-16, 3.25, -22), hescoColor, Enum.Material.Sandstone)
	createBlock(arenaFolder, "HescoNE", Vector3.new(22, 6.5, 3.5), CFrame.new(16, 3.25, -22), hescoColor, Enum.Material.Sandstone)
	createBlock(arenaFolder, "HescoSW", Vector3.new(22, 6.5, 3.5), CFrame.new(-16, 3.25, 22), hescoColor, Enum.Material.Sandstone)
	createBlock(arenaFolder, "HescoSE", Vector3.new(22, 6.5, 3.5), CFrame.new(16, 3.25, 22), hescoColor, Enum.Material.Sandstone)
	createBlock(arenaFolder, "CenterAmmoCrate1", Vector3.new(6, 4.2, 6), CFrame.new(-7, 2.1, -6), woodColor, Enum.Material.Wood)
	createBlock(arenaFolder, "CenterAmmoCrate2", Vector3.new(6, 4.2, 6), CFrame.new(7, 2.1, 6), woodColor, Enum.Material.Wood)
	createBlock(arenaFolder, "CenterCanopy", Vector3.new(24, 0.6, 24), CFrame.new(0, 10.5, 0), woodColor, Enum.Material.WoodPlanks)
	for _, px in ipairs({ -10, 10 }) do
		for _, pz in ipairs({ -10, 10 }) do
			createBlock(arenaFolder, "CenterCanopyPost", Vector3.new(1.2, 10.5, 1.2), CFrame.new(px, 5.25, pz), woodColor, Enum.Material.Wood)
		end
	end

	-- Two sandstone compound houses (SW & NE quadrants)
	for _, house in ipairs({ { tag = "SW", x = -56, z = 56 }, { tag = "NE", x = 56, z = -56 } }) do
		local x, z = house.x, house.z
		createBlock(arenaFolder, `{house.tag}_WallN`, Vector3.new(26, 9, 2.4), CFrame.new(x, 4.5, z - 12), sandstoneColor, Enum.Material.Sandstone)
		createBlock(arenaFolder, `{house.tag}_WallS`, Vector3.new(26, 9, 2.4), CFrame.new(x, 4.5, z + 12), sandstoneColor, Enum.Material.Sandstone)
		createBlock(arenaFolder, `{house.tag}_WallWA`, Vector3.new(2.4, 9, 8), CFrame.new(x - 12, 4.5, z - 8), sandstoneColor, Enum.Material.Sandstone)
		createBlock(arenaFolder, `{house.tag}_WallWB`, Vector3.new(2.4, 9, 8), CFrame.new(x - 12, 4.5, z + 8), sandstoneColor, Enum.Material.Sandstone)
		createBlock(arenaFolder, `{house.tag}_WallEA`, Vector3.new(2.4, 9, 8), CFrame.new(x + 12, 4.5, z - 8), sandstoneColor, Enum.Material.Sandstone)
		createBlock(arenaFolder, `{house.tag}_WallEB`, Vector3.new(2.4, 9, 8), CFrame.new(x + 12, 4.5, z + 8), sandstoneColor, Enum.Material.Sandstone)
		createBlock(arenaFolder, `{house.tag}_InnerPlaster`, Vector3.new(0.8, 8, 12), CFrame.new(x, 4, z), plasterColor, Enum.Material.Plaster)
		createBlock(arenaFolder, `{house.tag}_Roof`, Vector3.new(28, 1.0, 26), CFrame.new(x, 9.5, z), woodColor, Enum.Material.WoodPlanks)
	end

	-- Desert rock ridges & roadside concrete barriers
	local rocks = {
		{ x = -38, z = -42, sx = 18, sy = 7, sz = 10, ry = 22 },
		{ x = 38, z = 42, sx = 18, sy = 7, sz = 10, ry = 22 },
		{ x = -96, z = 24, sx = 14, sy = 8, sz = 18, ry = -15 },
		{ x = 96, z = -24, sx = 14, sy = 8, sz = 18, ry = -15 },
		{ x = -22, z = -92, sx = 24, sy = 6, sz = 6, ry = 8 },
		{ x = 22, z = 92, sx = 24, sy = 6, sz = 6, ry = 8 },
	}
	for i, r in ipairs(rocks) do
		createBlock(arenaFolder, `DesertRock_{i}`, Vector3.new(r.sx, r.sy, r.sz), CFrame.new(r.x, r.sy * 0.5, r.z) * CFrame.Angles(0, math.rad(r.ry), 0), rockColor, Enum.Material.Rock)
	end

	-- Outer spawn screens
	createBlock(arenaFolder, "SpawnScreenN", Vector3.new(18, 8, 3), CFrame.new(0, 4, -98), hescoColor, Enum.Material.Sandstone)
	createBlock(arenaFolder, "SpawnScreenS", Vector3.new(18, 8, 3), CFrame.new(0, 4, 98), hescoColor, Enum.Material.Sandstone)
	createBlock(arenaFolder, "SpawnScreenW", Vector3.new(3, 8, 18), CFrame.new(-98, 4, 0), hescoColor, Enum.Material.Sandstone)
	createBlock(arenaFolder, "SpawnScreenE", Vector3.new(3, 8, 18), CFrame.new(98, 4, 0), hescoColor, Enum.Material.Sandstone)

	addSpawnList(spawnsFolder, {
		Vector3.new(-116, 0.35, -116),
		Vector3.new(116, 0.35, 116),
		Vector3.new(-112, 0.35, 112),
		Vector3.new(112, 0.35, -112),
		Vector3.new(0, 0.35, -114),
		Vector3.new(0, 0.35, 114),
		Vector3.new(-114, 0.35, 0),
		Vector3.new(114, 0.35, 0),
		Vector3.new(-56, 0.35, 76),
		Vector3.new(56, 0.35, -76),
	})
end

-- Map 4: CargoDocks ("Доки «Атлантик»", 240x240 foggy dawn port container terminal)
local function buildCargoDocks(arenaFolder: Folder, spawnsFolder: Folder): ()
	local tarmacColor = Color3.fromRGB(72, 76, 84)
	local pierWall = Color3.fromRGB(116, 120, 126)
	local craneOrange = Color3.fromRGB(192, 92, 46)
	local redContainer = Color3.fromRGB(138, 48, 44)
	local blueContainer = Color3.fromRGB(44, 78, 116)
	local greenContainer = Color3.fromRGB(64, 94, 62)
	local ochreContainer = Color3.fromRGB(156, 114, 52)
	local steelColor = Color3.fromRGB(66, 74, 84)
	local woodColor = Color3.fromRGB(144, 106, 68)
	local plasterColor = Color3.fromRGB(204, 206, 210)

	createBlock(arenaFolder, "PierAsphalt", Vector3.new(240, 1, 240), CFrame.new(0, -0.4, 0), tarmacColor, Enum.Material.Asphalt)
	-- Pier hazard lane stripes
	createBlock(arenaFolder, "LaneStripeW", Vector3.new(2, 0.12, 220), CFrame.new(-26, 0.12, 0), Color3.fromRGB(186, 160, 74), Enum.Material.SmoothPlastic)
	createBlock(arenaFolder, "LaneStripeE", Vector3.new(2, 0.12, 220), CFrame.new(26, 0.12, 0), Color3.fromRGB(186, 160, 74), Enum.Material.SmoothPlastic)

	-- Perimeter concrete terminal walls
	createBlock(arenaFolder, "DockNorth", Vector3.new(244, 18, 4), CFrame.new(0, 9, -120), pierWall, Enum.Material.Concrete)
	createBlock(arenaFolder, "DockSouth", Vector3.new(244, 18, 4), CFrame.new(0, 9, 120), pierWall, Enum.Material.Concrete)
	createBlock(arenaFolder, "DockEast", Vector3.new(4, 18, 240), CFrame.new(120, 9, 0), pierWall, Enum.Material.Concrete)
	createBlock(arenaFolder, "DockWest", Vector3.new(4, 18, 240), CFrame.new(-120, 9, 0), pierWall, Enum.Material.Concrete)

	-- Overhead port gantry crane silhouettes (non-obstructive overhead landmark)
	for _, gx in ipairs({ -74, 74 }) do
		createBlock(arenaFolder, `CraneSpan_{gx}`, Vector3.new(6, 4, 210), CFrame.new(gx, 32, 0), craneOrange, Enum.Material.Metal)
		createBlock(arenaFolder, `CraneLegN_{gx}`, Vector3.new(4, 32, 4), CFrame.new(gx, 16, -104), craneOrange, Enum.Material.Metal)
		createBlock(arenaFolder, `CraneLegS_{gx}`, Vector3.new(4, 32, 4), CFrame.new(gx, 16, 104), craneOrange, Enum.Material.Metal)
	end

	-- Central inspection gantry platform + wooden cargo crates
	createBlock(arenaFolder, "CenterGantry", Vector3.new(20, 1.0, 28), CFrame.new(0, 6.5, 0), steelColor, Enum.Material.DiamondPlate)
	createRamp(arenaFolder, "GantryRampW", 10, 0.8, Vector3.new(-30, 0.1, 0), Vector3.new(-10, 7.0, 0), steelColor, Enum.Material.DiamondPlate)
	createRamp(arenaFolder, "GantryRampE", 10, 0.8, Vector3.new(30, 0.1, 0), Vector3.new(10, 7.0, 0), steelColor, Enum.Material.DiamondPlate)
	createBlock(arenaFolder, "GantryCoverN", Vector3.new(16, 3.2, 1.2), CFrame.new(0, 8.6, -13.4), woodColor, Enum.Material.WoodPlanks)
	createBlock(arenaFolder, "GantryCoverS", Vector3.new(16, 3.2, 1.2), CFrame.new(0, 8.6, 13.4), woodColor, Enum.Material.WoodPlanks)

	-- Walk-through hollow cargo containers (wallbangable 0.45-stud steel walls)
	createOpenContainer(arenaFolder, "PassThroughNW", CFrame.new(-42, 4.35, -36), Vector3.new(9, 8.5, 24), redContainer, Enum.Material.CorrodedMetal)
	createOpenContainer(arenaFolder, "PassThroughSE", CFrame.new(42, 4.35, 36), Vector3.new(9, 8.5, 24), blueContainer, Enum.Material.CorrodedMetal)
	createOpenContainer(arenaFolder, "PassThroughNE", CFrame.new(42, 4.35, -36) * CFrame.Angles(0, math.rad(90), 0), Vector3.new(9, 8.5, 24), greenContainer, Enum.Material.CorrodedMetal)
	createOpenContainer(arenaFolder, "PassThroughSW", CFrame.new(-42, 4.35, 36) * CFrame.Angles(0, math.rad(90), 0), Vector3.new(9, 8.5, 24), ochreContainer, Enum.Material.CorrodedMetal)

	-- Climbable 2-tier container stacks on East & West flanks
	for _, side in ipairs({ -1, 1 }) do
		local xBase = side * 72
		local tag = if side < 0 then "West" else "East"
		createBlock(arenaFolder, `{tag}StackBase`, Vector3.new(10, 8.5, 28), CFrame.new(xBase, 4.25, 0), blueContainer, Enum.Material.CorrodedMetal)
		createBlock(arenaFolder, `{tag}StackTop`, Vector3.new(10, 8.5, 16), CFrame.new(xBase, 12.75, 0), redContainer, Enum.Material.CorrodedMetal)
		createRamp(arenaFolder, `{tag}StackRampN`, 8, 0.8, Vector3.new(xBase, 0.1, -38), Vector3.new(xBase, 8.5, -14), steelColor, Enum.Material.DiamondPlate)
		createRamp(arenaFolder, `{tag}StackRampS`, 8, 0.8, Vector3.new(xBase, 0.1, 38), Vector3.new(xBase, 8.5, 14), steelColor, Enum.Material.DiamondPlate)
	end

	-- Additional staggered containers & wooden pallet stacks
	local solidContainers = {
		{ x = -84, z = -56, color = greenContainer, ry = 0 },
		{ x = 84, z = 56, color = ochreContainer, ry = 0 },
		{ x = -84, z = 56, color = redContainer, ry = 90 },
		{ x = 84, z = -56, color = blueContainer, ry = 90 },
		{ x = -22, z = -56, color = ochreContainer, ry = 90 },
		{ x = 22, z = 56, color = greenContainer, ry = 90 },
	}
	for i, c in ipairs(solidContainers) do
		createBlock(arenaFolder, `CargoBox_{i}`, Vector3.new(9, 8.5, 22), CFrame.new(c.x, 4.25, c.z) * CFrame.Angles(0, math.rad(c.ry), 0), c.color, Enum.Material.CorrodedMetal)
	end

	-- North & South Customs Guardhouses (glass + plaster wallbang)
	for _, side in ipairs({ -1, 1 }) do
		local cz = side * 86
		local tag = if side < 0 then "North" else "South"
		createBlock(arenaFolder, `{tag}CheckSill`, Vector3.new(30, 3.6, 0.8), CFrame.new(0, 1.8, cz - side * 7), plasterColor, Enum.Material.Plaster)
		createBlock(arenaFolder, `{tag}CheckHeader`, Vector3.new(30, 2.4, 0.8), CFrame.new(0, 8.8, cz - side * 7), plasterColor, Enum.Material.Plaster)
		createBlock(arenaFolder, `{tag}CheckGlass`, Vector3.new(28, 4.0, 0.25), CFrame.new(0, 5.6, cz - side * 7), Color3.fromRGB(165, 210, 226), Enum.Material.Glass, 0.55)
		createBlock(arenaFolder, `{tag}CheckBack`, Vector3.new(30, 10, 1.2), CFrame.new(0, 5, cz + side * 7), pierWall, Enum.Material.Concrete)
		createBlock(arenaFolder, `{tag}CheckSideW`, Vector3.new(1.0, 10, 8), CFrame.new(-15, 5, cz), plasterColor, Enum.Material.Plaster)
		createBlock(arenaFolder, `{tag}CheckSideE`, Vector3.new(1.0, 10, 8), CFrame.new(15, 5, cz), plasterColor, Enum.Material.Plaster)
		createBlock(arenaFolder, `{tag}CheckRoof`, Vector3.new(32, 0.8, 16), CFrame.new(0, 10.4, cz), steelColor, Enum.Material.Metal)
	end

	-- Wooden pallet covers in center lanes
	for _, zOff in ipairs({ -30, 30 }) do
		createBlock(arenaFolder, `PalletCoverL_{zOff}`, Vector3.new(8, 4.5, 1.4), CFrame.new(-16, 2.25, zOff), woodColor, Enum.Material.Wood)
		createBlock(arenaFolder, `PalletCoverR_{zOff}`, Vector3.new(8, 4.5, 1.4), CFrame.new(16, 2.25, zOff), woodColor, Enum.Material.Wood)
	end

	addSpawnList(spawnsFolder, {
		Vector3.new(-106, 0.35, -106),
		Vector3.new(106, 0.35, -106),
		Vector3.new(-106, 0.35, 106),
		Vector3.new(106, 0.35, 106),
		Vector3.new(0, 0.35, -106),
		Vector3.new(0, 0.35, 106),
		Vector3.new(-106, 0.35, 0),
		Vector3.new(106, 0.35, 0),
		Vector3.new(-56, 0.35, -84),
		Vector3.new(56, 0.35, 84),
	})
end

local MAP_BUILDERS: { [string]: (Folder, Folder) -> () } = {
	ProvingGround = buildProvingGround,
	WarehouseCQB = buildWarehouseCQB,
	DesertOutpost = buildDesertOutpost,
	CargoDocks = buildCargoDocks,
}

function MapService.GetCurrentMapId(): string
	return currentMapId
end

function MapService.LoadMap(mapId: string): boolean
	local def = MapConfig.GetMap(mapId)
	local builder = MAP_BUILDERS[mapId]
	if not def or not builder then
		def = MapConfig.GetMap(MapConfig.DEFAULT_MAP_ID)
		builder = MAP_BUILDERS[MapConfig.DEFAULT_MAP_ID]
		if not def or not builder then
			return false
		end
		mapId = MapConfig.DEFAULT_MAP_ID
	end

	-- Remove starter Baseplate and default SpawnLocation so map surfaces & smart spawns stay clean.
	local defaultSpawn = Workspace:FindFirstChild("SpawnLocation")
	if defaultSpawn and defaultSpawn:IsA("SpawnLocation") then
		defaultSpawn:Destroy()
	end
	local baseplate = Workspace:FindFirstChild("Baseplate")
	if baseplate and baseplate:IsA("BasePart") then
		baseplate:Destroy()
	end

	local oldArena = Workspace:FindFirstChild("TacticalArena")
	if oldArena then
		oldArena:Destroy()
	end
	local oldSpawns = Workspace:FindFirstChild("SpawnLocations")
	if oldSpawns then
		oldSpawns:Destroy()
	end

	local arenaFolder = Instance.new("Folder")
	arenaFolder.Name = "TacticalArena"

	local spawnsFolder = Instance.new("Folder")
	spawnsFolder.Name = "SpawnLocations"

	builder(arenaFolder, spawnsFolder)
	arenaFolder.Parent = Workspace
	spawnsFolder.Parent = Workspace

	applyLightingPreset(def.Lighting)
	currentMapId = mapId
	return true
end

return MapService
