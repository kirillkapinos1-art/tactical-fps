--!strict
-- Minimalist tactical HUD, magazine check feedback, suppression & blood vignettes,
-- sniper scope reticle, top-right killfeed, and pre-spawn loadout selection menu.

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapConfig = require(Shared.MapConfig)
local NetworkTypes = require(Shared.NetworkTypes)
local WeaponConfig = require(Shared.WeaponConfig)

export type LoadoutSelection = NetworkTypes.LoadoutSelection
export type DeployCallback = (loadout: LoadoutSelection) -> ()
export type SensitivityCallback = (baseSens: number, adsScale: number) -> ()
export type MenuBlockingCallback = (isBlocking: boolean) -> ()
export type MapVoteCallback = (mapId: string) -> ()
export type RtvRequestCallback = () -> ()

local HUDController = {}

local MAX_KILLFEED_ITEMS = 5
local KILLFEED_LIFETIME = 6.5
local DEFAULT_BASE_SENS = 0.35
local MIN_BASE_SENS = 0.05
local MAX_BASE_SENS = 2.00
local DEFAULT_ADS_SCALE = 0.85
local MIN_ADS_SCALE = 0.20
local MAX_ADS_SCALE = 1.50

local localPlayer = Players.LocalPlayer
local playerGui = localPlayer:WaitForChild("PlayerGui") :: PlayerGui

local screenGui: ScreenGui
local vignetteContainer: Frame
local suppressionEdges: { Frame } = {}
local bloodEdges: { Frame } = {}
local damageDirectionContainer: Frame
local damageArrow: Frame

local scopeOverlay: Frame
local statusToastLabel: TextLabel
local toastHideAt = 0

local staminaTrack: Frame
local staminaFill: Frame
local postureLabel: TextLabel
local grenadeLabel: TextLabel
local flashOverlay: Frame
local flashBlur: BlurEffect
local matchHeaderLabel: TextLabel
local killfeedContainer: Frame

local loadoutRoot: Frame
local deployButton: TextButton
local loadoutStatusLabel: TextLabel
local loadoutMapBadgeLabel: TextLabel
local loadoutRtvButton: TextButton
local settingsRoot: Frame
local settingsModalButton: TextButton
local settingsSummaryLabel: TextLabel
local settingsRtvButton: TextButton
local mapVoteRoot: Frame
local mapVoteStatusLabel: TextLabel
local mapVoteCurrentLabel: TextLabel
local primaryButtons: { [string]: TextButton } = {}
local selectedPrimary: string = WeaponConfig.DEFAULT_PRIMARY
local selectedSecondary: string = WeaponConfig.DEFAULT_SECONDARY
local onDeployCallback: DeployCallback? = nil
local onSensitivityChangedCallback: SensitivityCallback? = nil
local onMenuBlockingChangedCallback: MenuBlockingCallback? = nil
local onMapVoteCallback: MapVoteCallback? = nil
local onRtvRequestCallback: RtvRequestCallback? = nil

type MapCardEntry = {
	Card: TextButton,
	Stroke: UIStroke,
	AccentColor: Color3,
	CountLabel: TextLabel,
	BarFill: Frame,
	SelectedTag: TextLabel,
	CurrentTag: TextLabel,
}
local mapCardEntries: { [string]: MapCardEntry } = {}

local baseSensitivity = DEFAULT_BASE_SENS
local adsSensitivityScale = DEFAULT_ADS_SCALE
local baseSliderSyncs: { (number) -> () } = {}
local adsSliderSyncs: { (number) -> () } = {}
local uiConnections: { RBXScriptConnection } = {}

local suppressionIntensity = 0
local bloodFlashIntensity = 0
local persistentInjuryIntensity = 0
local damageIndicatorAlpha = 0
local lastDamageOrigin: Vector3? = nil
local flashPeakAlpha = 0
local flashHoldUntil = 0
local flashFadeRate = 0.8
local fragCount = 2
local flashCount = 2
local respawnUnlockAt = 0
local currentMatchState: NetworkTypes.MatchState = "Active"
local currentMapId = MapConfig.DEFAULT_MAP_ID
local currentMapName = if MapConfig.GetMap(MapConfig.DEFAULT_MAP_ID) then (MapConfig.GetMap(MapConfig.DEFAULT_MAP_ID) :: MapConfig.MapDefinition).DisplayName else "Полигон ОС-01"
local lastVotePayload: NetworkTypes.MapVoteStatePayload? = nil
local lastWinnerSummary = ""
local lastIntermissionTime = 15
local isMenuOpen = true
local isSettingsOpen = false
local isVoteMenuOpen = false

type KillfeedRow = {
	Frame: Frame,
	CreatedAt: number,
}
local killfeedRows: { KillfeedRow } = {}

local function createEdgeGradientFrame(
	parent: Instance,
	name: string,
	pos: UDim2,
	size: UDim2,
	rotation: number,
	color: Color3
): Frame
	local frame = Instance.new("Frame")
	frame.Name = name
	frame.BackgroundColor3 = color
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Position = pos
	frame.Size = size
	frame.ZIndex = 2
	frame.Parent = parent

	local grad = Instance.new("UIGradient")
	grad.Rotation = rotation
	grad.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.45, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	grad.Parent = frame

	return frame
end

local function createVignetteGroup(parent: Instance, prefix: string, color: Color3): { Frame }
	return {
		createEdgeGradientFrame(parent, prefix .. "Top", UDim2.fromScale(0, 0), UDim2.fromScale(1, 0.24), 90, color),
		createEdgeGradientFrame(parent, prefix .. "Bottom", UDim2.fromScale(0, 0.76), UDim2.fromScale(1, 0.24), -90, color),
		createEdgeGradientFrame(parent, prefix .. "Left", UDim2.fromScale(0, 0), UDim2.fromScale(0.22, 1), 0, color),
		createEdgeGradientFrame(parent, prefix .. "Right", UDim2.fromScale(0.78, 0), UDim2.fromScale(0.22, 1), 180, color),
	}
end

local function setEdgeGroupTransparency(edges: { Frame }, transparency: number): ()
	local clamped = math.clamp(transparency, 0, 1)
	for _, edge in ipairs(edges) do
		edge.BackgroundTransparency = clamped
	end
end

local function formatTime(seconds: number): string
	local s = math.max(0, math.floor(seconds))
	local mins = math.floor(s / 60)
	local secs = s % 60
	return string.format("%02d:%02d", mins, secs)
end

local function refreshPrimaryCardStyles(): ()
	for id, btn in pairs(primaryButtons) do
		local isSelected = (id == selectedPrimary)
		btn.BackgroundColor3 = if isSelected then Color3.fromRGB(38, 49, 44) else Color3.fromRGB(22, 26, 31)
		local stroke = btn:FindFirstChildOfClass("UIStroke")
		if stroke then
			stroke.Color = if isSelected then Color3.fromRGB(145, 196, 118) else Color3.fromRGB(54, 60, 70)
			stroke.Thickness = if isSelected then 2 else 1
		end
	end
end

local function updateDeployButtonState(): ()
	local now = os.clock()
	if currentMatchState == "Intermission" then
		deployButton.Active = false
		deployButton.AutoButtonColor = false
		deployButton.BackgroundColor3 = Color3.fromRGB(52, 56, 62)
		deployButton.Text = "ОЖИДАНИЕ НОВОГО РАУНДА..."
	elseif now < respawnUnlockAt then
		local left = math.ceil(respawnUnlockAt - now)
		deployButton.Active = false
		deployButton.AutoButtonColor = false
		deployButton.BackgroundColor3 = Color3.fromRGB(52, 56, 62)
		deployButton.Text = `ВОЗРОЖДЕНИЕ ЧЕРЕЗ {left}с`
	else
		deployButton.Active = true
		deployButton.AutoButtonColor = true
		deployButton.BackgroundColor3 = Color3.fromRGB(110, 148, 86)
		deployButton.Text = "В БОЙ"
	end
end

local function isAnyMenuOpen(): boolean
	return isMenuOpen or isSettingsOpen or isVoteMenuOpen
end

local function notifyMenuBlocking(): ()
	if onMenuBlockingChangedCallback then
		onMenuBlockingChangedCallback(isAnyMenuOpen())
	end
end

local function applyCursorState(): ()
	if isMenuOpen or isVoteMenuOpen then
		localPlayer.CameraMode = Enum.CameraMode.Classic
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	elseif isSettingsOpen then
		localPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
		UserInputService.MouseBehavior = Enum.MouseBehavior.Default
		UserInputService.MouseIconEnabled = true
	else
		localPlayer.CameraMode = Enum.CameraMode.LockFirstPerson
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	end
end

local function refreshRtvButtons(): ()
	if loadoutMapBadgeLabel then
		loadoutMapBadgeLabel.Text = `КАРТА: {currentMapName}`
	end
	local payload = lastVotePayload
	local votes = if payload then payload.RtvVotes else 0
	local needed = if payload then payload.RtvNeeded else 1
	local voted = if payload then payload.MyRtvVoted else false

	local bgColor = if voted then Color3.fromRGB(68, 96, 56) else Color3.fromRGB(36, 42, 50)
	local textColor = if voted then Color3.fromRGB(240, 248, 236) else Color3.fromRGB(220, 226, 234)

	if loadoutRtvButton then
		loadoutRtvButton.Text = if voted
			then string.format("✓ Сменить (%d/%d)", votes, needed)
			else string.format("Сменить карту (%d/%d)", votes, needed)
		loadoutRtvButton.BackgroundColor3 = bgColor
		loadoutRtvButton.TextColor3 = textColor
	end
	if settingsRtvButton then
		settingsRtvButton.Text = if voted
			then string.format("✓ Голос за смену карты (%d/%d)", votes, needed)
			else string.format("Сменить карту голосованием (%d/%d)", votes, needed)
		settingsRtvButton.BackgroundColor3 = bgColor
		settingsRtvButton.TextColor3 = textColor
	end
end

local function refreshMapVoteUI(): ()
	if mapVoteCurrentLabel then
		mapVoteCurrentLabel.Text = `ТЕКУЩАЯ: {currentMapName}`
	end

	local payload = lastVotePayload
	if not payload then
		return
	end

	local totalVotes = 0
	for _, mapId in ipairs(MapConfig.MapOrder) do
		totalVotes += (payload.VoteCounts[mapId] or 0)
	end

	for mapId, entry in pairs(mapCardEntries) do
		local count = payload.VoteCounts[mapId] or 0
		local ratio = if totalVotes > 0 then math.clamp(count / totalVotes, 0, 1) else 0
		local pct = math.round(ratio * 100)
		local isMine = payload.MyVoteMapId == mapId

		entry.CountLabel.Text = if totalVotes > 0
			then string.format("Голосов: %d (%d%%)", count, pct)
			else "Голосов: 0"
		entry.BarFill.Size = UDim2.fromScale(ratio, 1)
		entry.SelectedTag.Visible = isMine
		entry.CurrentTag.Visible = (payload.CurrentMapId == mapId)

		if isMine then
			entry.Stroke.Color = Color3.fromRGB(130, 198, 102)
			entry.Stroke.Thickness = 2
			entry.Card.BackgroundColor3 = Color3.fromRGB(28, 36, 32)
		else
			entry.Stroke.Color = Color3.fromRGB(54, 60, 70)
			entry.Stroke.Thickness = 1
			entry.Card.BackgroundColor3 = Color3.fromRGB(22, 26, 31)
		end
	end
end

local function updateSensitivitySummary(): ()
	if not settingsSummaryLabel then
		return
	end
	local adsEffective = baseSensitivity * adsSensitivityScale
	settingsSummaryLabel.Text = string.format(
		"Бедро: %.2f  |  База прицела (x%.2f): %.2f",
		baseSensitivity,
		adsSensitivityScale,
		adsEffective
	)
end

local function applySensitivityValues(newBase: number, newAdsScale: number): ()
	baseSensitivity = math.round(math.clamp(newBase, MIN_BASE_SENS, MAX_BASE_SENS) * 100) / 100
	adsSensitivityScale = math.round(math.clamp(newAdsScale, MIN_ADS_SCALE, MAX_ADS_SCALE) * 100) / 100

	for _, syncFn in ipairs(baseSliderSyncs) do
		syncFn(baseSensitivity)
	end
	for _, syncFn in ipairs(adsSliderSyncs) do
		syncFn(adsSensitivityScale)
	end
	updateSensitivitySummary()

	if onSensitivityChangedCallback then
		onSensitivityChangedCallback(baseSensitivity, adsSensitivityScale)
	end
end

local function createSensitivitySliderRow(
	parent: Instance,
	posX: number,
	posY: number,
	width: number,
	labelText: string,
	minValue: number,
	maxValue: number,
	initialValue: number,
	zBase: number,
	onValueChanged: (number) -> ()
): (number) -> ()
	local row = Instance.new("Frame")
	row.Name = "SliderRow"
	row.Position = UDim2.fromOffset(posX, posY)
	row.Size = UDim2.fromOffset(width, 40)
	row.BackgroundTransparency = 1
	row.ZIndex = zBase
	row.Parent = parent

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(0, 0)
	title.Size = UDim2.fromOffset(width - 68, 16)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamMedium
	title.Text = labelText
	title.TextColor3 = Color3.fromRGB(202, 210, 220)
	title.TextSize = 12
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = zBase
	title.Parent = row

	local valueLabel = Instance.new("TextLabel")
	valueLabel.Position = UDim2.fromOffset(width - 64, 0)
	valueLabel.Size = UDim2.fromOffset(64, 16)
	valueLabel.BackgroundTransparency = 1
	valueLabel.Font = Enum.Font.Code
	valueLabel.TextColor3 = Color3.fromRGB(168, 212, 134)
	valueLabel.TextSize = 13
	valueLabel.TextXAlignment = Enum.TextXAlignment.Right
	valueLabel.ZIndex = zBase
	valueLabel.Parent = row

	local decBtn = Instance.new("TextButton")
	decBtn.Position = UDim2.fromOffset(0, 18)
	decBtn.Size = UDim2.fromOffset(22, 20)
	decBtn.BackgroundColor3 = Color3.fromRGB(30, 35, 42)
	decBtn.BorderSizePixel = 0
	decBtn.Font = Enum.Font.Code
	decBtn.Text = "-"
	decBtn.TextColor3 = Color3.fromRGB(215, 222, 232)
	decBtn.TextSize = 14
	decBtn.ZIndex = zBase + 1
	decBtn.Parent = row
	local decCorner = Instance.new("UICorner")
	decCorner.CornerRadius = UDim.new(0, 4)
	decCorner.Parent = decBtn

	local incBtn = Instance.new("TextButton")
	incBtn.Position = UDim2.fromOffset(width - 22, 18)
	incBtn.Size = UDim2.fromOffset(22, 20)
	incBtn.BackgroundColor3 = Color3.fromRGB(30, 35, 42)
	incBtn.BorderSizePixel = 0
	incBtn.Font = Enum.Font.Code
	incBtn.Text = "+"
	incBtn.TextColor3 = Color3.fromRGB(215, 222, 232)
	incBtn.TextSize = 14
	incBtn.ZIndex = zBase + 1
	incBtn.Parent = row
	local incCorner = Instance.new("UICorner")
	incCorner.CornerRadius = UDim.new(0, 4)
	incCorner.Parent = incBtn

	local trackHit = Instance.new("TextButton")
	trackHit.Position = UDim2.fromOffset(28, 18)
	trackHit.Size = UDim2.fromOffset(math.max(40, width - 56), 20)
	trackHit.BackgroundTransparency = 1
	trackHit.Text = ""
	trackHit.AutoButtonColor = false
	trackHit.ZIndex = zBase + 1
	trackHit.Parent = row

	local trackBg = Instance.new("Frame")
	trackBg.AnchorPoint = Vector2.new(0, 0.5)
	trackBg.Position = UDim2.fromScale(0, 0.5)
	trackBg.Size = UDim2.new(1, 0, 0, 6)
	trackBg.BackgroundColor3 = Color3.fromRGB(34, 40, 48)
	trackBg.BorderSizePixel = 0
	trackBg.ZIndex = zBase
	trackBg.Parent = trackHit
	local trackCorner = Instance.new("UICorner")
	trackCorner.CornerRadius = UDim.new(1, 0)
	trackCorner.Parent = trackBg

	local trackFill = Instance.new("Frame")
	trackFill.Size = UDim2.fromScale(0.2, 1)
	trackFill.BackgroundColor3 = Color3.fromRGB(118, 166, 92)
	trackFill.BorderSizePixel = 0
	trackFill.ZIndex = zBase + 1
	trackFill.Parent = trackBg
	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(1, 0)
	fillCorner.Parent = trackFill

	local knob = Instance.new("Frame")
	knob.AnchorPoint = Vector2.new(0.5, 0.5)
	knob.Position = UDim2.fromScale(0.2, 0.5)
	knob.Size = UDim2.fromOffset(12, 12)
	knob.BackgroundColor3 = Color3.fromRGB(235, 240, 245)
	knob.BorderSizePixel = 0
	knob.ZIndex = zBase + 2
	knob.Parent = trackBg
	local knobCorner = Instance.new("UICorner")
	knobCorner.CornerRadius = UDim.new(1, 0)
	knobCorner.Parent = knob

	local currentVal = initialValue
	local isDragging = false

	local function syncDisplay(val: number): ()
		currentVal = math.clamp(val, minValue, maxValue)
		local alpha = math.clamp((currentVal - minValue) / math.max(maxValue - minValue, 0.001), 0, 1)
		trackFill.Size = UDim2.fromScale(alpha, 1)
		knob.Position = UDim2.fromScale(alpha, 0.5)
		valueLabel.Text = string.format("%.2f", currentVal)
	end

	local function setFromScreenX(screenX: number): ()
		local trackWidth = math.max(trackHit.AbsoluteSize.X, 1)
		local alpha = math.clamp((screenX - trackHit.AbsolutePosition.X) / trackWidth, 0, 1)
		local rawVal = minValue + (maxValue - minValue) * alpha
		local snapped = math.round(rawVal * 100) / 100
		onValueChanged(snapped)
	end

	local function getStepAmount(): number
		if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then
			return 0.05
		end
		return 0.01
	end

	decBtn.MouseButton1Click:Connect(function()
		onValueChanged(currentVal - getStepAmount())
	end)

	incBtn.MouseButton1Click:Connect(function()
		onValueChanged(currentVal + getStepAmount())
	end)

	trackHit.InputBegan:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			isDragging = true
			setFromScreenX(input.Position.X)
		end
	end)

	table.insert(uiConnections, UserInputService.InputChanged:Connect(function(input: InputObject)
		if not isDragging then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseMovement or input.UserInputType == Enum.UserInputType.Touch then
			setFromScreenX(input.Position.X)
		end
	end))

	table.insert(uiConnections, UserInputService.InputEnded:Connect(function(input: InputObject)
		if input.UserInputType == Enum.UserInputType.MouseButton1 or input.UserInputType == Enum.UserInputType.Touch then
			isDragging = false
		end
	end))

	syncDisplay(initialValue)
	return syncDisplay
end

local function buildScopeOverlay(parent: Instance): Frame
	local scope = Instance.new("Frame")
	scope.Name = "ScopeOverlay"
	scope.Size = UDim2.fromScale(1, 1)
	scope.BackgroundTransparency = 1
	scope.Visible = false
	scope.ZIndex = 4
	scope.Parent = parent

	-- Peripheral dark matte ring via 4 solid masks + central lens frame
	local lensSize = 520
	local lens = Instance.new("Frame")
	lens.Name = "ScopeLens"
	lens.AnchorPoint = Vector2.new(0.5, 0.5)
	lens.Position = UDim2.fromScale(0.5, 0.5)
	lens.Size = UDim2.fromOffset(lensSize, lensSize)
	lens.BackgroundTransparency = 1
	lens.Parent = scope

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(1, 0)
	corner.Parent = lens

	local stroke = Instance.new("UIStroke")
	stroke.Thickness = 1200
	stroke.Color = Color3.fromRGB(6, 8, 10)
	stroke.Transparency = 0.02
	stroke.Parent = lens

	-- Fine Mil-Dot Crosshair inside scope lens
	local hLine = Instance.new("Frame")
	hLine.AnchorPoint = Vector2.new(0.5, 0.5)
	hLine.Position = UDim2.fromScale(0.5, 0.5)
	hLine.Size = UDim2.new(0, lensSize, 0, 1)
	hLine.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	hLine.BorderSizePixel = 0
	hLine.Parent = lens

	local vLine = Instance.new("Frame")
	vLine.AnchorPoint = Vector2.new(0.5, 0.5)
	vLine.Position = UDim2.fromScale(0.5, 0.5)
	vLine.Size = UDim2.new(0, 1, 0, lensSize)
	vLine.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	vLine.BorderSizePixel = 0
	vLine.Parent = lens

	-- Subtle mil-dot stadia ticks along vertical and horizontal axes
	for _, offsetPx in ipairs({ -120, -80, -40, 40, 80, 120 }) do
		local hTick = Instance.new("Frame")
		hTick.AnchorPoint = Vector2.new(0.5, 0.5)
		hTick.Position = UDim2.new(0.5, offsetPx, 0.5, 0)
		hTick.Size = UDim2.fromOffset(2, 8)
		hTick.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
		hTick.BorderSizePixel = 0
		hTick.Parent = lens

		local vTick = Instance.new("Frame")
		vTick.AnchorPoint = Vector2.new(0.5, 0.5)
		vTick.Position = UDim2.new(0.5, 0, 0.5, offsetPx)
		vTick.Size = UDim2.fromOffset(8, 2)
		vTick.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
		vTick.BorderSizePixel = 0
		vTick.Parent = lens
	end

	-- Subtle center red dot
	local dot = Instance.new("Frame")
	dot.AnchorPoint = Vector2.new(0.5, 0.5)
	dot.Position = UDim2.fromScale(0.5, 0.5)
	dot.Size = UDim2.fromOffset(4, 4)
	dot.BackgroundColor3 = Color3.fromRGB(235, 55, 55)
	dot.BorderSizePixel = 0
	dot.Parent = lens
	local dotCorner = Instance.new("UICorner")
	dotCorner.CornerRadius = UDim.new(1, 0)
	dotCorner.Parent = dot

	return scope
end

local function buildLoadoutMenu(parent: Instance): Frame
	local backdrop = Instance.new("Frame")
	backdrop.Name = "LoadoutMenu"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(10, 12, 15)
	backdrop.BackgroundTransparency = 0.22
	backdrop.BorderSizePixel = 0
	backdrop.ZIndex = 20
	backdrop.Parent = parent

	local modalUnlock = Instance.new("TextButton")
	modalUnlock.Name = "ModalUnlock"
	modalUnlock.Size = UDim2.fromScale(1, 1)
	modalUnlock.BackgroundTransparency = 1
	modalUnlock.Text = ""
	modalUnlock.AutoButtonColor = false
	modalUnlock.Modal = true
	modalUnlock.ZIndex = 20
	modalUnlock.Parent = backdrop

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(820, 520)
	panel.BackgroundColor3 = Color3.fromRGB(18, 21, 26)
	panel.BorderSizePixel = 0
	panel.ZIndex = 21
	panel.Parent = backdrop

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 6)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(58, 66, 76)
	panelStroke.Thickness = 1
	panelStroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(24, 18)
	title.Size = UDim2.fromOffset(390, 28)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = "СНАРЯЖЕНИЕ  //  FFA"
	title.TextColor3 = Color3.fromRGB(228, 232, 238)
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 22
	title.Parent = panel

	loadoutMapBadgeLabel = Instance.new("TextLabel")
	loadoutMapBadgeLabel.Name = "MapBadge"
	loadoutMapBadgeLabel.Position = UDim2.fromOffset(424, 18)
	loadoutMapBadgeLabel.Size = UDim2.fromOffset(200, 28)
	loadoutMapBadgeLabel.BackgroundColor3 = Color3.fromRGB(24, 28, 34)
	loadoutMapBadgeLabel.BorderSizePixel = 0
	loadoutMapBadgeLabel.Font = Enum.Font.Code
	loadoutMapBadgeLabel.Text = `КАРТА: {currentMapName}`
	loadoutMapBadgeLabel.TextColor3 = Color3.fromRGB(168, 206, 142)
	loadoutMapBadgeLabel.TextSize = 11
	loadoutMapBadgeLabel.TextTruncate = Enum.TextTruncate.AtEnd
	loadoutMapBadgeLabel.ZIndex = 22
	loadoutMapBadgeLabel.Parent = panel
	local badgeCorner = Instance.new("UICorner")
	badgeCorner.CornerRadius = UDim.new(0, 4)
	badgeCorner.Parent = loadoutMapBadgeLabel

	loadoutRtvButton = Instance.new("TextButton")
	loadoutRtvButton.Name = "RtvButton"
	loadoutRtvButton.Position = UDim2.fromOffset(632, 18)
	loadoutRtvButton.Size = UDim2.fromOffset(164, 28)
	loadoutRtvButton.BackgroundColor3 = Color3.fromRGB(36, 42, 50)
	loadoutRtvButton.BorderSizePixel = 0
	loadoutRtvButton.Font = Enum.Font.GothamMedium
	loadoutRtvButton.Text = "Сменить карту (0/1)"
	loadoutRtvButton.TextColor3 = Color3.fromRGB(220, 226, 234)
	loadoutRtvButton.TextSize = 12
	loadoutRtvButton.ZIndex = 23
	loadoutRtvButton.Parent = panel
	local rtvCorner = Instance.new("UICorner")
	rtvCorner.CornerRadius = UDim.new(0, 4)
	rtvCorner.Parent = loadoutRtvButton
	loadoutRtvButton.MouseButton1Click:Connect(function()
		if onRtvRequestCallback then
			onRtvRequestCallback()
		end
	end)

	local controlsHint = Instance.new("TextLabel")
	controlsHint.Position = UDim2.fromOffset(24, 48)
	controlsHint.Size = UDim2.fromOffset(772, 20)
	controlsHint.BackgroundTransparency = 1
	controlsHint.Font = Enum.Font.Gotham
	controlsHint.Text = "ЛКМ Огонь | ПКМ Прицел | V Режим | R Перезарядка | G Оскол. | F Флеш | Q/E Наклон | C Присед | M Настройки"
	controlsHint.TextColor3 = Color3.fromRGB(145, 155, 168)
	controlsHint.TextSize = 11
	controlsHint.TextXAlignment = Enum.TextXAlignment.Left
	controlsHint.ZIndex = 22
	controlsHint.Parent = panel

	loadoutStatusLabel = Instance.new("TextLabel")
	loadoutStatusLabel.Position = UDim2.fromOffset(24, 72)
	loadoutStatusLabel.Size = UDim2.fromOffset(772, 22)
	loadoutStatusLabel.BackgroundTransparency = 1
	loadoutStatusLabel.Font = Enum.Font.GothamMedium
	loadoutStatusLabel.Text = "Выберите основное оружие перед высадкой"
	loadoutStatusLabel.TextColor3 = Color3.fromRGB(202, 178, 118)
	loadoutStatusLabel.TextSize = 13
	loadoutStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	loadoutStatusLabel.ZIndex = 22
	loadoutStatusLabel.Parent = panel

	local cardsRow = Instance.new("Frame")
	cardsRow.Position = UDim2.fromOffset(24, 104)
	cardsRow.Size = UDim2.fromOffset(772, 224)
	cardsRow.BackgroundTransparency = 1
	cardsRow.ZIndex = 22
	cardsRow.Parent = panel

	local listLayout = Instance.new("UIListLayout")
	listLayout.FillDirection = Enum.FillDirection.Horizontal
	listLayout.SortOrder = Enum.SortOrder.LayoutOrder
	listLayout.Padding = UDim.new(0, 12)
	listLayout.Parent = cardsRow

	local primaryWeapons = WeaponConfig.GetWeaponsBySlot("Primary")
	for cardIndex, def in ipairs(primaryWeapons) do
		local card = Instance.new("TextButton")
		card.Name = def.Id
		card.LayoutOrder = cardIndex
		card.Size = UDim2.fromOffset(184, 220)
		card.BackgroundColor3 = Color3.fromRGB(22, 26, 31)
		card.Text = ""
		card.AutoButtonColor = false
		card.ZIndex = 23
		card.Parent = cardsRow

		local cCorner = Instance.new("UICorner")
		cCorner.CornerRadius = UDim.new(0, 5)
		cCorner.Parent = card

		local cStroke = Instance.new("UIStroke")
		cStroke.Color = Color3.fromRGB(54, 60, 70)
		cStroke.Thickness = 1
		cStroke.Parent = card

		local nameLbl = Instance.new("TextLabel")
		nameLbl.Position = UDim2.fromOffset(12, 12)
		nameLbl.Size = UDim2.fromOffset(160, 22)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Font = Enum.Font.GothamBold
		nameLbl.Text = def.DisplayName
		nameLbl.TextColor3 = Color3.fromRGB(232, 236, 240)
		nameLbl.TextSize = 14
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left
		nameLbl.ZIndex = 24
		nameLbl.Parent = card

		local calLbl = Instance.new("TextLabel")
		calLbl.Position = UDim2.fromOffset(12, 34)
		calLbl.Size = UDim2.fromOffset(160, 18)
		calLbl.BackgroundTransparency = 1
		calLbl.Font = Enum.Font.GothamMedium
		calLbl.Text = def.Caliber
		calLbl.TextColor3 = Color3.fromRGB(154, 188, 124)
		calLbl.TextSize = 12
		calLbl.TextXAlignment = Enum.TextXAlignment.Left
		calLbl.ZIndex = 24
		calLbl.Parent = card

		local descLbl = Instance.new("TextLabel")
		descLbl.Position = UDim2.fromOffset(12, 58)
		descLbl.Size = UDim2.fromOffset(160, 72)
		descLbl.BackgroundTransparency = 1
		descLbl.Font = Enum.Font.Gotham
		descLbl.Text = def.Description
		descLbl.TextWrapped = true
		descLbl.TextColor3 = Color3.fromRGB(172, 178, 188)
		descLbl.TextSize = 11
		descLbl.TextXAlignment = Enum.TextXAlignment.Left
		descLbl.TextYAlignment = Enum.TextYAlignment.Top
		descLbl.ZIndex = 24
		descLbl.Parent = card

		local statsLbl = Instance.new("TextLabel")
		statsLbl.Position = UDim2.fromOffset(12, 136)
		statsLbl.Size = UDim2.fromOffset(160, 74)
		statsLbl.BackgroundTransparency = 1
		statsLbl.Font = Enum.Font.Code
		statsLbl.Text = string.format(
			"Урон: %d (Гол: %d)\nТемп: %d RPM | Маг: %d\nСкор: %d st/s | Проб: %.1f",
			def.BaseDamage,
			math.round(def.BaseDamage * 2.5),
			def.RPM,
			def.MagazineSize,
			def.MuzzleVelocity,
			def.PenetrationPower
		)
		statsLbl.TextColor3 = Color3.fromRGB(205, 212, 222)
		statsLbl.TextSize = 11
		statsLbl.TextXAlignment = Enum.TextXAlignment.Left
		statsLbl.TextYAlignment = Enum.TextYAlignment.Top
		statsLbl.ZIndex = 24
		statsLbl.Parent = card

		card.MouseButton1Click:Connect(function()
			selectedPrimary = def.Id
			refreshPrimaryCardStyles()
		end)

		primaryButtons[def.Id] = card
	end

	local secondaryDef = WeaponConfig.GetWeapon(selectedSecondary)
	local secondaryLabel = Instance.new("TextLabel")
	secondaryLabel.Position = UDim2.fromOffset(24, 342)
	secondaryLabel.Size = UDim2.fromOffset(772, 26)
	secondaryLabel.BackgroundColor3 = Color3.fromRGB(24, 28, 34)
	secondaryLabel.BorderSizePixel = 0
	secondaryLabel.Font = Enum.Font.GothamMedium
	secondaryLabel.Text = if secondaryDef
		then `  Вторичное [2]: {secondaryDef.DisplayName} ({secondaryDef.Caliber})  |  Гранаты: [G] M67 x2, [F] M84 x2`
		else "  Вторичное [2]: USP .45 Tactical  |  Гранаты: [G] M67 x2, [F] M84 x2"
	secondaryLabel.TextColor3 = Color3.fromRGB(188, 196, 206)
	secondaryLabel.TextSize = 13
	secondaryLabel.TextXAlignment = Enum.TextXAlignment.Left
	secondaryLabel.ZIndex = 22
	secondaryLabel.Parent = panel

	local secCorner = Instance.new("UICorner")
	secCorner.CornerRadius = UDim.new(0, 4)
	secCorner.Parent = secondaryLabel

	local sensBox = Instance.new("Frame")
	sensBox.Name = "SensitivityStrip"
	sensBox.Position = UDim2.fromOffset(24, 378)
	sensBox.Size = UDim2.fromOffset(772, 52)
	sensBox.BackgroundColor3 = Color3.fromRGB(24, 28, 34)
	sensBox.BorderSizePixel = 0
	sensBox.ZIndex = 22
	sensBox.Parent = panel
	local sensCorner = Instance.new("UICorner")
	sensCorner.CornerRadius = UDim.new(0, 4)
	sensCorner.Parent = sensBox

	local syncLoadoutBase = createSensitivitySliderRow(
		sensBox,
		12,
		6,
		596,
		"Чувствительность мыши",
		MIN_BASE_SENS,
		MAX_BASE_SENS,
		baseSensitivity,
		23,
		function(val: number)
			applySensitivityValues(val, adsSensitivityScale)
		end
	)
	table.insert(baseSliderSyncs, syncLoadoutBase)

	local openSettingsBtn = Instance.new("TextButton")
	openSettingsBtn.Name = "OpenSettingsButton"
	openSettingsBtn.Position = UDim2.fromOffset(620, 10)
	openSettingsBtn.Size = UDim2.fromOffset(140, 32)
	openSettingsBtn.BackgroundColor3 = Color3.fromRGB(36, 42, 50)
	openSettingsBtn.BorderSizePixel = 0
	openSettingsBtn.Font = Enum.Font.GothamMedium
	openSettingsBtn.Text = "Настройки [M]"
	openSettingsBtn.TextColor3 = Color3.fromRGB(220, 226, 234)
	openSettingsBtn.TextSize = 12
	openSettingsBtn.ZIndex = 23
	openSettingsBtn.Parent = sensBox
	local openBtnCorner = Instance.new("UICorner")
	openBtnCorner.CornerRadius = UDim.new(0, 4)
	openBtnCorner.Parent = openSettingsBtn
	openSettingsBtn.MouseButton1Click:Connect(function()
		HUDController.SetSettingsMenuVisible(true)
	end)

	deployButton = Instance.new("TextButton")
	deployButton.Name = "DeployButton"
	deployButton.Position = UDim2.fromOffset(24, 442)
	deployButton.Size = UDim2.fromOffset(772, 54)
	deployButton.BackgroundColor3 = Color3.fromRGB(110, 148, 86)
	deployButton.Font = Enum.Font.GothamBold
	deployButton.Text = "В БОЙ"
	deployButton.TextColor3 = Color3.fromRGB(245, 248, 250)
	deployButton.TextSize = 18
	deployButton.ZIndex = 23
	deployButton.Parent = panel

	local dCorner = Instance.new("UICorner")
	dCorner.CornerRadius = UDim.new(0, 5)
	dCorner.Parent = deployButton

	deployButton.MouseButton1Click:Connect(function()
		updateDeployButtonState()
		if not deployButton.Active then
			return
		end
		if onDeployCallback then
			onDeployCallback({
				Primary = selectedPrimary,
				Secondary = selectedSecondary,
			})
		end
	end)

	refreshPrimaryCardStyles()
	return backdrop
end

local function buildSettingsMenu(parent: Instance): Frame
	local backdrop = Instance.new("Frame")
	backdrop.Name = "SettingsMenu"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
	backdrop.BackgroundTransparency = 0.36
	backdrop.BorderSizePixel = 0
	backdrop.Visible = false
	backdrop.ZIndex = 30
	backdrop.Parent = parent

	settingsModalButton = Instance.new("TextButton")
	settingsModalButton.Name = "ModalUnlock"
	settingsModalButton.Size = UDim2.fromScale(1, 1)
	settingsModalButton.BackgroundTransparency = 1
	settingsModalButton.Text = ""
	settingsModalButton.AutoButtonColor = false
	settingsModalButton.Modal = true
	settingsModalButton.ZIndex = 30
	settingsModalButton.Parent = backdrop

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(480, 322)
	panel.BackgroundColor3 = Color3.fromRGB(18, 21, 26)
	panel.BorderSizePixel = 0
	panel.ZIndex = 31
	panel.Parent = backdrop

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 6)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(58, 66, 76)
	panelStroke.Thickness = 1
	panelStroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(22, 18)
	title.Size = UDim2.fromOffset(390, 24)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = "НАСТРОЙКИ ЧУВСТВИТЕЛЬНОСТИ"
	title.TextColor3 = Color3.fromRGB(228, 232, 238)
	title.TextSize = 18
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 32
	title.Parent = panel

	local closeBtn = Instance.new("TextButton")
	closeBtn.Name = "CloseButton"
	closeBtn.Position = UDim2.fromOffset(430, 16)
	closeBtn.Size = UDim2.fromOffset(28, 28)
	closeBtn.BackgroundColor3 = Color3.fromRGB(32, 37, 45)
	closeBtn.BorderSizePixel = 0
	closeBtn.Font = Enum.Font.GothamBold
	closeBtn.Text = "X"
	closeBtn.TextColor3 = Color3.fromRGB(205, 212, 222)
	closeBtn.TextSize = 13
	closeBtn.ZIndex = 33
	closeBtn.Parent = panel
	local closeCorner = Instance.new("UICorner")
	closeCorner.CornerRadius = UDim.new(0, 4)
	closeCorner.Parent = closeBtn
	closeBtn.MouseButton1Click:Connect(function()
		HUDController.SetSettingsMenuVisible(false)
	end)

	local subtitle = Instance.new("TextLabel")
	subtitle.Position = UDim2.fromOffset(22, 46)
	subtitle.Size = UDim2.fromOffset(436, 18)
	subtitle.BackgroundTransparency = 1
	subtitle.Font = Enum.Font.Gotham
	subtitle.Text = "Настройка чувствительности мыши на лету (горячие клавиши: M или F2)"
	subtitle.TextColor3 = Color3.fromRGB(145, 155, 168)
	subtitle.TextSize = 12
	subtitle.TextXAlignment = Enum.TextXAlignment.Left
	subtitle.ZIndex = 32
	subtitle.Parent = panel

	local syncBase = createSensitivitySliderRow(
		panel,
		22,
		80,
		436,
		"Общая чувствительность (от бедра)",
		MIN_BASE_SENS,
		MAX_BASE_SENS,
		baseSensitivity,
		32,
		function(val: number)
			applySensitivityValues(val, adsSensitivityScale)
		end
	)
	table.insert(baseSliderSyncs, syncBase)

	local syncAds = createSensitivitySliderRow(
		panel,
		22,
		134,
		436,
		"Множитель в прицеле (ADS)",
		MIN_ADS_SCALE,
		MAX_ADS_SCALE,
		adsSensitivityScale,
		32,
		function(val: number)
			applySensitivityValues(baseSensitivity, val)
		end
	)
	table.insert(adsSliderSyncs, syncAds)

	settingsSummaryLabel = Instance.new("TextLabel")
	settingsSummaryLabel.Name = "Summary"
	settingsSummaryLabel.Position = UDim2.fromOffset(22, 186)
	settingsSummaryLabel.Size = UDim2.fromOffset(436, 20)
	settingsSummaryLabel.BackgroundTransparency = 1
	settingsSummaryLabel.Font = Enum.Font.Code
	settingsSummaryLabel.TextColor3 = Color3.fromRGB(178, 188, 200)
	settingsSummaryLabel.TextSize = 12
	settingsSummaryLabel.TextXAlignment = Enum.TextXAlignment.Left
	settingsSummaryLabel.ZIndex = 32
	settingsSummaryLabel.Parent = panel

	local resetBtn = Instance.new("TextButton")
	resetBtn.Name = "ResetButton"
	resetBtn.Position = UDim2.fromOffset(22, 220)
	resetBtn.Size = UDim2.fromOffset(208, 38)
	resetBtn.BackgroundColor3 = Color3.fromRGB(36, 42, 50)
	resetBtn.BorderSizePixel = 0
	resetBtn.Font = Enum.Font.GothamMedium
	resetBtn.Text = string.format("Сбросить (%.2f / %.2f)", DEFAULT_BASE_SENS, DEFAULT_ADS_SCALE)
	resetBtn.TextColor3 = Color3.fromRGB(220, 226, 234)
	resetBtn.TextSize = 13
	resetBtn.ZIndex = 33
	resetBtn.Parent = panel
	local resetCorner = Instance.new("UICorner")
	resetCorner.CornerRadius = UDim.new(0, 5)
	resetCorner.Parent = resetBtn
	resetBtn.MouseButton1Click:Connect(function()
		applySensitivityValues(DEFAULT_BASE_SENS, DEFAULT_ADS_SCALE)
	end)

	local doneBtn = Instance.new("TextButton")
	doneBtn.Name = "DoneButton"
	doneBtn.Position = UDim2.fromOffset(246, 220)
	doneBtn.Size = UDim2.fromOffset(212, 38)
	doneBtn.BackgroundColor3 = Color3.fromRGB(110, 148, 86)
	doneBtn.BorderSizePixel = 0
	doneBtn.Font = Enum.Font.GothamBold
	doneBtn.Text = "ГОТОВО [M]"
	doneBtn.TextColor3 = Color3.fromRGB(245, 248, 250)
	doneBtn.TextSize = 14
	doneBtn.ZIndex = 33
	doneBtn.Parent = panel
	local doneCorner = Instance.new("UICorner")
	doneCorner.CornerRadius = UDim.new(0, 5)
	doneCorner.Parent = doneBtn
	doneBtn.MouseButton1Click:Connect(function()
		HUDController.SetSettingsMenuVisible(false)
	end)

	settingsRtvButton = Instance.new("TextButton")
	settingsRtvButton.Name = "RtvButton"
	settingsRtvButton.Position = UDim2.fromOffset(22, 268)
	settingsRtvButton.Size = UDim2.fromOffset(436, 34)
	settingsRtvButton.BackgroundColor3 = Color3.fromRGB(36, 42, 50)
	settingsRtvButton.BorderSizePixel = 0
	settingsRtvButton.Font = Enum.Font.GothamMedium
	settingsRtvButton.Text = "Сменить карту голосованием (0/1)"
	settingsRtvButton.TextColor3 = Color3.fromRGB(220, 226, 234)
	settingsRtvButton.TextSize = 13
	settingsRtvButton.ZIndex = 33
	settingsRtvButton.Parent = panel
	local setRtvCorner = Instance.new("UICorner")
	setRtvCorner.CornerRadius = UDim.new(0, 5)
	setRtvCorner.Parent = settingsRtvButton
	settingsRtvButton.MouseButton1Click:Connect(function()
		if onRtvRequestCallback then
			onRtvRequestCallback()
		end
	end)

	return backdrop
end

local function buildMapVoteMenu(parent: Instance): Frame
	local backdrop = Instance.new("Frame")
	backdrop.Name = "MapVoteMenu"
	backdrop.Size = UDim2.fromScale(1, 1)
	backdrop.BackgroundColor3 = Color3.fromRGB(8, 10, 14)
	backdrop.BackgroundTransparency = 0.25
	backdrop.BorderSizePixel = 0
	backdrop.Visible = false
	backdrop.ZIndex = 25
	backdrop.Parent = parent

	local modalUnlock = Instance.new("TextButton")
	modalUnlock.Name = "ModalUnlock"
	modalUnlock.Size = UDim2.fromScale(1, 1)
	modalUnlock.BackgroundTransparency = 1
	modalUnlock.Text = ""
	modalUnlock.AutoButtonColor = false
	modalUnlock.Modal = true
	modalUnlock.ZIndex = 25
	modalUnlock.Parent = backdrop

	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 0.5)
	panel.Position = UDim2.fromScale(0.5, 0.5)
	panel.Size = UDim2.fromOffset(820, 412)
	panel.BackgroundColor3 = Color3.fromRGB(18, 21, 26)
	panel.BorderSizePixel = 0
	panel.ZIndex = 26
	panel.Parent = backdrop

	local panelCorner = Instance.new("UICorner")
	panelCorner.CornerRadius = UDim.new(0, 6)
	panelCorner.Parent = panel

	local panelStroke = Instance.new("UIStroke")
	panelStroke.Color = Color3.fromRGB(58, 66, 76)
	panelStroke.Thickness = 1
	panelStroke.Parent = panel

	local title = Instance.new("TextLabel")
	title.Position = UDim2.fromOffset(24, 18)
	title.Size = UDim2.fromOffset(500, 26)
	title.BackgroundTransparency = 1
	title.Font = Enum.Font.GothamBold
	title.Text = "ГОЛОСОВАНИЕ ЗА СЛЕДУЮЩУЮ КАРТУ"
	title.TextColor3 = Color3.fromRGB(228, 232, 238)
	title.TextSize = 20
	title.TextXAlignment = Enum.TextXAlignment.Left
	title.ZIndex = 27
	title.Parent = panel

	mapVoteCurrentLabel = Instance.new("TextLabel")
	mapVoteCurrentLabel.Name = "CurrentMapTag"
	mapVoteCurrentLabel.Position = UDim2.fromOffset(546, 18)
	mapVoteCurrentLabel.Size = UDim2.fromOffset(250, 26)
	mapVoteCurrentLabel.BackgroundColor3 = Color3.fromRGB(26, 30, 38)
	mapVoteCurrentLabel.BorderSizePixel = 0
	mapVoteCurrentLabel.Font = Enum.Font.Code
	mapVoteCurrentLabel.Text = `ТЕКУЩАЯ: {currentMapName}`
	mapVoteCurrentLabel.TextColor3 = Color3.fromRGB(178, 192, 210)
	mapVoteCurrentLabel.TextSize = 12
	mapVoteCurrentLabel.ZIndex = 27
	mapVoteCurrentLabel.Parent = panel
	local curCorner = Instance.new("UICorner")
	curCorner.CornerRadius = UDim.new(0, 4)
	curCorner.Parent = mapVoteCurrentLabel

	mapVoteStatusLabel = Instance.new("TextLabel")
	mapVoteStatusLabel.Name = "VoteStatus"
	mapVoteStatusLabel.Position = UDim2.fromOffset(24, 52)
	mapVoteStatusLabel.Size = UDim2.fromOffset(772, 22)
	mapVoteStatusLabel.BackgroundTransparency = 1
	mapVoteStatusLabel.Font = Enum.Font.GothamMedium
	mapVoteStatusLabel.Text = "Выберите карту для следующего раунда"
	mapVoteStatusLabel.TextColor3 = Color3.fromRGB(202, 178, 118)
	mapVoteStatusLabel.TextSize = 13
	mapVoteStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
	mapVoteStatusLabel.ZIndex = 27
	mapVoteStatusLabel.Parent = panel

	local row = Instance.new("Frame")
	row.Name = "CardsRow"
	row.Position = UDim2.fromOffset(24, 88)
	row.Size = UDim2.fromOffset(772, 282)
	row.BackgroundTransparency = 1
	row.ZIndex = 27
	row.Parent = panel

	local layout = Instance.new("UIListLayout")
	layout.FillDirection = Enum.FillDirection.Horizontal
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.Padding = UDim.new(0, 12)
	layout.Parent = row

	for idx, def in ipairs(MapConfig.GetAllMaps()) do
		local card = Instance.new("TextButton")
		card.Name = def.Id
		card.LayoutOrder = idx
		card.Size = UDim2.fromOffset(184, 280)
		card.BackgroundColor3 = Color3.fromRGB(22, 26, 31)
		card.Text = ""
		card.AutoButtonColor = false
		card.ZIndex = 28
		card.Parent = row

		local cCorner = Instance.new("UICorner")
		cCorner.CornerRadius = UDim.new(0, 5)
		cCorner.Parent = card

		local cStroke = Instance.new("UIStroke")
		cStroke.Color = Color3.fromRGB(54, 60, 70)
		cStroke.Thickness = 1
		cStroke.Parent = card

		local accentBar = Instance.new("Frame")
		accentBar.Size = UDim2.new(1, 0, 0, 4)
		accentBar.BackgroundColor3 = def.AccentColor
		accentBar.BorderSizePixel = 0
		accentBar.ZIndex = 29
		accentBar.Parent = card

		local currentTag = Instance.new("TextLabel")
		currentTag.Position = UDim2.fromOffset(12, 12)
		currentTag.Size = UDim2.fromOffset(78, 16)
		currentTag.BackgroundColor3 = Color3.fromRGB(40, 48, 58)
		currentTag.BorderSizePixel = 0
		currentTag.Font = Enum.Font.Code
		currentTag.Text = "ТЕКУЩАЯ"
		currentTag.TextColor3 = Color3.fromRGB(196, 206, 218)
		currentTag.TextSize = 10
		currentTag.Visible = false
		currentTag.ZIndex = 29
		currentTag.Parent = card

		local selectedTag = Instance.new("TextLabel")
		selectedTag.Position = UDim2.fromOffset(96, 12)
		selectedTag.Size = UDim2.fromOffset(76, 16)
		selectedTag.BackgroundColor3 = Color3.fromRGB(72, 114, 58)
		selectedTag.BorderSizePixel = 0
		selectedTag.Font = Enum.Font.Code
		selectedTag.Text = "✓ ГОЛОС"
		selectedTag.TextColor3 = Color3.fromRGB(240, 248, 236)
		selectedTag.TextSize = 10
		selectedTag.Visible = false
		selectedTag.ZIndex = 29
		selectedTag.Parent = card

		local nameLbl = Instance.new("TextLabel")
		nameLbl.Position = UDim2.fromOffset(12, 34)
		nameLbl.Size = UDim2.fromOffset(160, 24)
		nameLbl.BackgroundTransparency = 1
		nameLbl.Font = Enum.Font.GothamBold
		nameLbl.Text = def.DisplayName
		nameLbl.TextColor3 = Color3.fromRGB(232, 236, 240)
		nameLbl.TextSize = 15
		nameLbl.TextXAlignment = Enum.TextXAlignment.Left
		nameLbl.ZIndex = 29
		nameLbl.Parent = card

		local tagLbl = Instance.new("TextLabel")
		tagLbl.Position = UDim2.fromOffset(12, 58)
		tagLbl.Size = UDim2.fromOffset(160, 18)
		tagLbl.BackgroundTransparency = 1
		tagLbl.Font = Enum.Font.GothamMedium
		tagLbl.Text = def.Tagline
		tagLbl.TextColor3 = def.AccentColor
		tagLbl.TextSize = 11
		tagLbl.TextXAlignment = Enum.TextXAlignment.Left
		tagLbl.TextTruncate = Enum.TextTruncate.AtEnd
		tagLbl.ZIndex = 29
		tagLbl.Parent = card

		local metaLbl = Instance.new("TextLabel")
		metaLbl.Position = UDim2.fromOffset(12, 78)
		metaLbl.Size = UDim2.fromOffset(160, 18)
		metaLbl.BackgroundTransparency = 1
		metaLbl.Font = Enum.Font.Code
		metaLbl.Text = `{def.ArenaSize} | {def.RecommendedRange}`
		metaLbl.TextColor3 = Color3.fromRGB(162, 172, 184)
		metaLbl.TextSize = 11
		metaLbl.TextXAlignment = Enum.TextXAlignment.Left
		metaLbl.ZIndex = 29
		metaLbl.Parent = card

		local descLbl = Instance.new("TextLabel")
		descLbl.Position = UDim2.fromOffset(12, 104)
		descLbl.Size = UDim2.fromOffset(160, 112)
		descLbl.BackgroundTransparency = 1
		descLbl.Font = Enum.Font.Gotham
		descLbl.Text = def.Description
		descLbl.TextWrapped = true
		descLbl.TextColor3 = Color3.fromRGB(178, 186, 196)
		descLbl.TextSize = 12
		descLbl.TextXAlignment = Enum.TextXAlignment.Left
		descLbl.TextYAlignment = Enum.TextYAlignment.Top
		descLbl.ZIndex = 29
		descLbl.Parent = card

		local countLbl = Instance.new("TextLabel")
		countLbl.Position = UDim2.fromOffset(12, 232)
		countLbl.Size = UDim2.fromOffset(160, 18)
		countLbl.BackgroundTransparency = 1
		countLbl.Font = Enum.Font.Code
		countLbl.Text = "Голосов: 0"
		countLbl.TextColor3 = Color3.fromRGB(220, 226, 234)
		countLbl.TextSize = 12
		countLbl.TextXAlignment = Enum.TextXAlignment.Left
		countLbl.ZIndex = 29
		countLbl.Parent = card

		local barTrack = Instance.new("Frame")
		barTrack.Position = UDim2.fromOffset(12, 256)
		barTrack.Size = UDim2.fromOffset(160, 8)
		barTrack.BackgroundColor3 = Color3.fromRGB(34, 40, 48)
		barTrack.BorderSizePixel = 0
		barTrack.ZIndex = 29
		barTrack.Parent = card
		local barTrackCorner = Instance.new("UICorner")
		barTrackCorner.CornerRadius = UDim.new(1, 0)
		barTrackCorner.Parent = barTrack

		local barFill = Instance.new("Frame")
		barFill.Size = UDim2.fromScale(0, 1)
		barFill.BackgroundColor3 = def.AccentColor
		barFill.BorderSizePixel = 0
		barFill.ZIndex = 29
		barFill.Parent = barTrack
		local barFillCorner = Instance.new("UICorner")
		barFillCorner.CornerRadius = UDim.new(1, 0)
		barFillCorner.Parent = barFill

		card.MouseButton1Click:Connect(function()
			if onMapVoteCallback then
				onMapVoteCallback(def.Id)
			end
		end)

		mapCardEntries[def.Id] = {
			Card = card,
			Stroke = cStroke,
			AccentColor = def.AccentColor,
			CountLabel = countLbl,
			BarFill = barFill,
			SelectedTag = selectedTag,
			CurrentTag = currentTag,
		}
	end

	return backdrop
end

function HUDController.Init(
	onDeploy: DeployCallback,
	onSensitivityChanged: SensitivityCallback?,
	onMenuBlockingChanged: MenuBlockingCallback?,
	onMapVote: MapVoteCallback?,
	onRtvRequest: RtvRequestCallback?
): ()
	for _, conn in ipairs(uiConnections) do
		conn:Disconnect()
	end
	table.clear(uiConnections)
	table.clear(baseSliderSyncs)
	table.clear(adsSliderSyncs)
	table.clear(primaryButtons)
	table.clear(mapCardEntries)
	table.clear(killfeedRows)

	onDeployCallback = onDeploy
	onSensitivityChangedCallback = onSensitivityChanged
	onMenuBlockingChangedCallback = onMenuBlockingChanged
	onMapVoteCallback = onMapVote
	onRtvRequestCallback = onRtvRequest

	local old = playerGui:FindFirstChild("TacticalHUD")
	if old then
		old:Destroy()
	end

	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "TacticalHUD"
	screenGui.ResetOnSpawn = false
	screenGui.IgnoreGuiInset = true
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = playerGui

	vignetteContainer = Instance.new("Frame")
	vignetteContainer.Name = "Vignettes"
	vignetteContainer.Size = UDim2.fromScale(1, 1)
	vignetteContainer.BackgroundTransparency = 1
	vignetteContainer.ZIndex = 1
	vignetteContainer.Parent = screenGui

	suppressionEdges = createVignetteGroup(vignetteContainer, "Suppression", Color3.fromRGB(8, 10, 12))
	bloodEdges = createVignetteGroup(vignetteContainer, "Blood", Color3.fromRGB(155, 16, 18))

	-- Directional damage indicator container (rotates around screen center)
	damageDirectionContainer = Instance.new("Frame")
	damageDirectionContainer.Name = "DamageDirection"
	damageDirectionContainer.AnchorPoint = Vector2.new(0.5, 0.5)
	damageDirectionContainer.Position = UDim2.fromScale(0.5, 0.5)
	damageDirectionContainer.Size = UDim2.fromOffset(220, 220)
	damageDirectionContainer.BackgroundTransparency = 1
	damageDirectionContainer.ZIndex = 3
	damageDirectionContainer.Parent = screenGui

	damageArrow = Instance.new("Frame")
	damageArrow.AnchorPoint = Vector2.new(0.5, 0)
	damageArrow.Position = UDim2.fromScale(0.5, 0)
	damageArrow.Size = UDim2.fromOffset(48, 8)
	damageArrow.BackgroundColor3 = Color3.fromRGB(220, 38, 42)
	damageArrow.BackgroundTransparency = 1
	damageArrow.BorderSizePixel = 0
	damageArrow.ZIndex = 3
	damageArrow.Parent = damageDirectionContainer

	scopeOverlay = buildScopeOverlay(screenGui)

	-- Top-center minimal match header
	matchHeaderLabel = Instance.new("TextLabel")
	matchHeaderLabel.Name = "MatchHeader"
	matchHeaderLabel.AnchorPoint = Vector2.new(0.5, 0)
	matchHeaderLabel.Position = UDim2.new(0.5, 0, 0, 12)
	matchHeaderLabel.Size = UDim2.fromOffset(440, 26)
	matchHeaderLabel.BackgroundColor3 = Color3.fromRGB(14, 16, 20)
	matchHeaderLabel.BackgroundTransparency = 0.35
	matchHeaderLabel.BorderSizePixel = 0
	matchHeaderLabel.Font = Enum.Font.Code
	matchHeaderLabel.Text = "FFA  |  10:00  |  0 / 30"
	matchHeaderLabel.TextColor3 = Color3.fromRGB(218, 224, 232)
	matchHeaderLabel.TextSize = 13
	matchHeaderLabel.ZIndex = 10
	matchHeaderLabel.Parent = screenGui
	local headerCorner = Instance.new("UICorner")
	headerCorner.CornerRadius = UDim.new(0, 4)
	headerCorner.Parent = matchHeaderLabel

	-- Top-right Killfeed
	killfeedContainer = Instance.new("Frame")
	killfeedContainer.Name = "Killfeed"
	killfeedContainer.AnchorPoint = Vector2.new(1, 0)
	killfeedContainer.Position = UDim2.new(1, -18, 0, 16)
	killfeedContainer.Size = UDim2.fromOffset(360, 220)
	killfeedContainer.BackgroundTransparency = 1
	killfeedContainer.ZIndex = 10
	killfeedContainer.Parent = screenGui

	local kfLayout = Instance.new("UIListLayout")
	kfLayout.VerticalAlignment = Enum.VerticalAlignment.Top
	kfLayout.HorizontalAlignment = Enum.HorizontalAlignment.Right
	kfLayout.Padding = UDim.new(0, 5)
	kfLayout.Parent = killfeedContainer

	-- Transient tactical toast (fire mode / mag check / reload)
	statusToastLabel = Instance.new("TextLabel")
	statusToastLabel.Name = "TacticalToast"
	statusToastLabel.AnchorPoint = Vector2.new(1, 1)
	statusToastLabel.Position = UDim2.new(1, -28, 1, -46)
	statusToastLabel.Size = UDim2.fromOffset(310, 44)
	statusToastLabel.BackgroundColor3 = Color3.fromRGB(16, 19, 24)
	statusToastLabel.BackgroundTransparency = 0.25
	statusToastLabel.BorderSizePixel = 0
	statusToastLabel.Font = Enum.Font.GothamMedium
	statusToastLabel.Text = ""
	statusToastLabel.TextColor3 = Color3.fromRGB(232, 236, 240)
	statusToastLabel.TextSize = 14
	statusToastLabel.TextXAlignment = Enum.TextXAlignment.Right
	statusToastLabel.Visible = false
	statusToastLabel.ZIndex = 10
	statusToastLabel.Parent = screenGui

	local toastPadding = Instance.new("UIPadding")
	toastPadding.PaddingRight = UDim.new(0, 12)
	toastPadding.PaddingLeft = UDim.new(0, 12)
	toastPadding.Parent = statusToastLabel

	local toastCorner = Instance.new("UICorner")
	toastCorner.CornerRadius = UDim.new(0, 4)
	toastCorner.Parent = statusToastLabel

	-- Minimalist bottom stamina bar & posture indicator
	staminaTrack = Instance.new("Frame")
	staminaTrack.Name = "StaminaBar"
	staminaTrack.AnchorPoint = Vector2.new(0.5, 1)
	staminaTrack.Position = UDim2.new(0.5, 0, 1, -20)
	staminaTrack.Size = UDim2.fromOffset(180, 3)
	staminaTrack.BackgroundColor3 = Color3.fromRGB(20, 22, 26)
	staminaTrack.BackgroundTransparency = 0.35
	staminaTrack.BorderSizePixel = 0
	staminaTrack.ZIndex = 10
	staminaTrack.Parent = screenGui

	staminaFill = Instance.new("Frame")
	staminaFill.Size = UDim2.fromScale(1, 1)
	staminaFill.BackgroundColor3 = Color3.fromRGB(215, 222, 230)
	staminaFill.BorderSizePixel = 0
	staminaFill.ZIndex = 11
	staminaFill.Parent = staminaTrack

	postureLabel = Instance.new("TextLabel")
	postureLabel.Name = "Posture"
	postureLabel.AnchorPoint = Vector2.new(0, 1)
	postureLabel.Position = UDim2.new(0, 24, 1, -22)
	postureLabel.Size = UDim2.fromOffset(320, 20)
	postureLabel.BackgroundTransparency = 1
	postureLabel.Font = Enum.Font.Code
	postureLabel.Text = ""
	postureLabel.TextColor3 = Color3.fromRGB(185, 194, 205)
	postureLabel.TextSize = 12
	postureLabel.TextXAlignment = Enum.TextXAlignment.Left
	postureLabel.ZIndex = 10
	postureLabel.Parent = screenGui

	grenadeLabel = Instance.new("TextLabel")
	grenadeLabel.Name = "Grenades"
	grenadeLabel.AnchorPoint = Vector2.new(1, 1)
	grenadeLabel.Position = UDim2.new(1, -24, 1, -22)
	grenadeLabel.Size = UDim2.fromOffset(300, 20)
	grenadeLabel.BackgroundTransparency = 1
	grenadeLabel.Font = Enum.Font.Code
	grenadeLabel.Text = ""
	grenadeLabel.TextColor3 = Color3.fromRGB(196, 206, 218)
	grenadeLabel.TextSize = 12
	grenadeLabel.TextXAlignment = Enum.TextXAlignment.Right
	grenadeLabel.ZIndex = 10
	grenadeLabel.Parent = screenGui

	flashOverlay = Instance.new("Frame")
	flashOverlay.Name = "FlashOverlay"
	flashOverlay.Size = UDim2.fromScale(1, 1)
	flashOverlay.BackgroundColor3 = Color3.fromRGB(246, 249, 255)
	flashOverlay.BackgroundTransparency = 1
	flashOverlay.BorderSizePixel = 0
	flashOverlay.ZIndex = 18
	flashOverlay.Parent = screenGui

	local existingBlur = Lighting:FindFirstChild("FlashBlur")
	if existingBlur and existingBlur:IsA("BlurEffect") then
		flashBlur = existingBlur
	else
		flashBlur = Instance.new("BlurEffect")
		flashBlur.Name = "FlashBlur"
		flashBlur.Parent = Lighting
	end
	flashBlur.Enabled = false
	flashBlur.Size = 0

	loadoutRoot = buildLoadoutMenu(screenGui)
	mapVoteRoot = buildMapVoteMenu(screenGui)
	settingsRoot = buildSettingsMenu(screenGui)
	applySensitivityValues(baseSensitivity, adsSensitivityScale)
	refreshRtvButtons()
	refreshMapVoteUI()
	HUDController.SetLoadoutMenuVisible(true)
end

function HUDController.SetSettingsMenuVisible(visible: boolean): ()
	isSettingsOpen = visible
	if settingsRoot then
		settingsRoot.Visible = visible
	end
	if visible and settingsModalButton then
		settingsModalButton.Modal = true
	end
	applyCursorState()
	notifyMenuBlocking()
end

function HUDController.ToggleSettingsMenu(): boolean
	HUDController.SetSettingsMenuVisible(not isSettingsOpen)
	return isSettingsOpen
end

function HUDController.IsSettingsMenuOpen(): boolean
	return isSettingsOpen
end

function HUDController.IsAnyMenuOpen(): boolean
	return isAnyMenuOpen()
end

function HUDController.GetSensitivity(): (number, number)
	return baseSensitivity, adsSensitivityScale
end

function HUDController.SetSensitivity(baseSens: number, adsScale: number?): ()
	applySensitivityValues(baseSens, if adsScale ~= nil then adsScale else adsSensitivityScale)
end

function HUDController.SetLoadoutMenuVisible(visible: boolean, statusMessage: string?, lockSeconds: number?): ()
	isMenuOpen = visible
	loadoutRoot.Visible = visible
	if visible then
		isSettingsOpen = false
		if settingsRoot then
			settingsRoot.Visible = false
		end
	end
	if statusMessage then
		loadoutStatusLabel.Text = statusMessage
	end
	if lockSeconds and lockSeconds > 0 then
		respawnUnlockAt = os.clock() + lockSeconds
	end
	updateDeployButtonState()
	applyCursorState()
	notifyMenuBlocking()
end

function HUDController.ShowToast(text: string, duration: number?, accentColor: Color3?): ()
	statusToastLabel.Text = text
	statusToastLabel.TextColor3 = accentColor or Color3.fromRGB(232, 236, 240)
	statusToastLabel.Visible = true
	toastHideAt = os.clock() + (duration or 2.2)
end

function HUDController.ShowFireModeToast(weaponName: string, fireMode: NetworkTypes.FireMode): ()
	local modeLabel = if fireMode == "Auto" then "АВТО" else "ОДИНОЧ."
	HUDController.ShowToast(`{weaponName}  |  Режим: {modeLabel}`, 1.8, Color3.fromRGB(220, 226, 235))
end

function HUDController.ShowMagazineCheck(magazine: number, capacity: number, fireMode: NetworkTypes.FireMode): ()
	local estimate: string
	local color: Color3

	if magazine <= 0 then
		estimate = "Магазин пуст"
		color = Color3.fromRGB(235, 95, 95)
	else
		local ratio = magazine / math.max(capacity, 1)
		if ratio >= 0.99 then
			estimate = "Полный магазин"
			color = Color3.fromRGB(164, 214, 142)
		elseif ratio >= 0.72 then
			estimate = "Магазин почти полон"
			color = Color3.fromRGB(185, 220, 155)
		elseif ratio >= 0.45 then
			estimate = "Половина магазина"
			color = Color3.fromRGB(224, 206, 128)
		elseif ratio >= 0.22 then
			estimate = "Меньше половины"
			color = Color3.fromRGB(232, 165, 96)
		else
			estimate = "Почти пуст"
			color = Color3.fromRGB(235, 102, 92)
		end
	end

	local modeLabel = if fireMode == "Auto" then "АВТО" else "ОДИНОЧ."
	HUDController.ShowToast(`{estimate}  [{modeLabel}]`, 2.4, color)
end

function HUDController.AddKillfeedEntry(entry: NetworkTypes.KillfeedEntry): ()
	local row = Instance.new("Frame")
	row.Size = UDim2.fromOffset(350, 26)
	row.BackgroundColor3 = Color3.fromRGB(14, 17, 22)
	row.BackgroundTransparency = 0.28
	row.BorderSizePixel = 0
	row.ZIndex = 11
	row.Parent = killfeedContainer

	local rCorner = Instance.new("UICorner")
	rCorner.CornerRadius = UDim.new(0, 3)
	rCorner.Parent = row

	local tags = ""
	if entry.IsHeadshot then
		tags ..= " [HS]"
	end
	if entry.IsWallbang then
		tags ..= " [WB]"
	end

	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 12
	label.TextXAlignment = Enum.TextXAlignment.Right
	label.ZIndex = 12

	if entry.KillerUserId == entry.VictimUserId or entry.WeaponId == "Environment" then
		label.Text = `{entry.VictimName}  [Погиб]  `
		label.TextColor3 = Color3.fromRGB(205, 160, 160)
	else
		local isLocalInvolved = entry.KillerUserId == localPlayer.UserId or entry.VictimUserId == localPlayer.UserId
		label.Text = `{entry.KillerName}  [{entry.WeaponId}{tags} {entry.Distance}m]  {entry.VictimName}  `
		label.TextColor3 = if isLocalInvolved then Color3.fromRGB(245, 212, 128) else Color3.fromRGB(215, 222, 232)
	end
	label.Parent = row

	table.insert(killfeedRows, {
		Frame = row,
		CreatedAt = os.clock(),
	})

	while #killfeedRows > MAX_KILLFEED_ITEMS do
		local oldest = table.remove(killfeedRows, 1)
		if oldest then
			oldest.Frame:Destroy()
		end
	end
end

function HUDController.TriggerSuppression(intensity: number): ()
	suppressionIntensity = math.min(1.0, math.max(suppressionIntensity, intensity) + intensity * 0.35)
end

function HUDController.TriggerDamageTaken(payload: NetworkTypes.DamageTakenPayload): ()
	bloodFlashIntensity = math.min(1.0, bloodFlashIntensity + math.clamp(payload.Damage / 55, 0.3, 0.9))
	local healthRatio = math.clamp(payload.Health / math.max(payload.MaxHealth, 1), 0, 1)
	persistentInjuryIntensity = math.clamp((0.65 - healthRatio) / 0.65, 0, 0.85)
	lastDamageOrigin = payload.DirectionOrigin
	damageIndicatorAlpha = 1.0
end

function HUDController.UpdateGrenadeCounts(frag: number, flash: number): ()
	fragCount = math.max(0, math.round(frag))
	flashCount = math.max(0, math.round(flash))
end

function HUDController.TriggerFlashbang(intensity: number, duration: number): ()
	local clampedInt = math.clamp(intensity, 0.1, 1.0)
	local clampedDur = math.max(duration, 0.5)
	flashPeakAlpha = math.max(flashPeakAlpha, clampedInt)
	local holdTime = if clampedInt >= 0.45 then clampedDur * 0.30 else 0.08
	flashHoldUntil = math.max(flashHoldUntil, os.clock() + holdTime)
	local fadeTime = math.max(clampedDur - holdTime, 0.45)
	flashFadeRate = flashPeakAlpha / fadeTime
	HUDController.TriggerSuppression(clampedInt)
end

function HUDController.ResetHealthEffects(): ()
	suppressionIntensity = 0
	bloodFlashIntensity = 0
	persistentInjuryIntensity = 0
	damageIndicatorAlpha = 0
	lastDamageOrigin = nil
	flashPeakAlpha = 0
	flashHoldUntil = 0
	if flashOverlay then
		flashOverlay.BackgroundTransparency = 1
	end
	if flashBlur then
		flashBlur.Enabled = false
		flashBlur.Size = 0
	end
	setEdgeGroupTransparency(suppressionEdges, 1)
	setEdgeGroupTransparency(bloodEdges, 1)
	damageArrow.BackgroundTransparency = 1
end

function HUDController.OnMapVoteUpdated(payload: NetworkTypes.MapVoteStatePayload): ()
	lastVotePayload = payload
	if payload.CurrentMapId ~= "" then
		currentMapId = payload.CurrentMapId
	end
	if payload.CurrentMapName ~= "" then
		currentMapName = payload.CurrentMapName
	end
	refreshRtvButtons()
	refreshMapVoteUI()
end

function HUDController.OnMatchStateChanged(payload: NetworkTypes.MatchStatePayload): ()
	local prevMatchState = currentMatchState
	currentMatchState = payload.State

	if payload.CurrentMapId and payload.CurrentMapId ~= "" then
		currentMapId = payload.CurrentMapId
	end
	if payload.CurrentMapName and payload.CurrentMapName ~= "" then
		currentMapName = payload.CurrentMapName
	end
	refreshRtvButtons()
	refreshMapVoteUI()

	local kills = 0
	local stats = localPlayer:FindFirstChild("leaderstats")
	if stats then
		local killsVal = stats:FindFirstChild("Kills")
		if killsVal and killsVal:IsA("IntValue") then
			kills = killsVal.Value
		end
	end

	if payload.State == "Intermission" then
		lastIntermissionTime = payload.TimeRemaining
		local winner = payload.WinnerName or "Ничья"
		local wKills = payload.WinnerKills or 0
		lastWinnerSummary = if payload.WinnerName
			then `Победитель раунда: {winner} ({wKills} фрагов)`
			else "Запущено голосование за карту"
		matchHeaderLabel.Text = `ГОЛОСОВАНИЕ ЗА КАРТУ  |  {formatTime(lastIntermissionTime)}`

		if mapVoteStatusLabel then
			mapVoteStatusLabel.Text = `{lastWinnerSummary}  —  выберите карту ({lastIntermissionTime}с)`
		end

		if not isVoteMenuOpen then
			isVoteMenuOpen = true
			if mapVoteRoot then
				mapVoteRoot.Visible = true
			end
			isMenuOpen = false
			if loadoutRoot then
				loadoutRoot.Visible = false
			end
			applyCursorState()
			notifyMenuBlocking()
		end
	else
		matchHeaderLabel.Text = `{currentMapName}  |  {formatTime(payload.TimeRemaining)}  |  {kills} / {payload.ScoreLimit}`

		local exitedIntermission = prevMatchState == "Intermission" or isVoteMenuOpen
		if exitedIntermission then
			isVoteMenuOpen = false
			if mapVoteRoot then
				mapVoteRoot.Visible = false
			end
			HUDController.SetLoadoutMenuVisible(
				true,
				`Карта загружена: {currentMapName} — выберите оружие перед высадкой`,
				nil
			)
		elseif isMenuOpen and loadoutStatusLabel.Text == "" then
			loadoutStatusLabel.Text = "Выберите основное оружие перед высадкой"
		end
	end
	updateDeployButtonState()
end

function HUDController.Update(
	dt: number,
	staminaRatio: number,
	isCrouching: boolean,
	leanDir: number,
	showScope: boolean
): ()
	local now = os.clock()

	if isMenuOpen then
		updateDeployButtonState()
	end
	if isAnyMenuOpen() and (UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default or not UserInputService.MouseIconEnabled) then
		applyCursorState()
	end

	if statusToastLabel.Visible and now >= toastHideAt then
		statusToastLabel.Visible = false
	end

	-- Decay suppression, blood flash, and directional damage indicator
	suppressionIntensity = math.max(0, suppressionIntensity - dt * 0.95)
	bloodFlashIntensity = math.max(0, bloodFlashIntensity - dt * 1.35)
	damageIndicatorAlpha = math.max(0, damageIndicatorAlpha - dt * 1.15)

	setEdgeGroupTransparency(suppressionEdges, 1 - suppressionIntensity * 0.85)
	local totalBlood = math.max(bloodFlashIntensity, persistentInjuryIntensity)
	setEdgeGroupTransparency(bloodEdges, 1 - totalBlood * 0.78)

	if damageIndicatorAlpha > 0.01 and lastDamageOrigin then
		local camera = Workspace.CurrentCamera
		if camera then
			local flatLook = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
			local flatToAttacker = Vector3.new(
				lastDamageOrigin.X - camera.CFrame.Position.X,
				0,
				lastDamageOrigin.Z - camera.CFrame.Position.Z
			)
			if flatLook.Magnitude > 0.01 and flatToAttacker.Magnitude > 0.01 then
				local f = flatLook.Unit
				local t = flatToAttacker.Unit
				local angle = math.atan2(f:Cross(t).Y, f:Dot(t))
				damageDirectionContainer.Rotation = -math.deg(angle)
				damageArrow.BackgroundTransparency = 1 - damageIndicatorAlpha * 0.9
			end
		end
	else
		damageArrow.BackgroundTransparency = 1
	end

	local menuBlocking = isAnyMenuOpen()
	scopeOverlay.Visible = showScope and not menuBlocking

	-- Flashbang blind fade
	if flashPeakAlpha > 0 and now >= flashHoldUntil then
		flashPeakAlpha = math.max(0, flashPeakAlpha - dt * flashFadeRate)
	end
	if flashOverlay then
		flashOverlay.BackgroundTransparency = if menuBlocking then 1 else math.clamp(1 - flashPeakAlpha, 0, 1)
	end
	if flashBlur then
		flashBlur.Enabled = (not menuBlocking) and (flashPeakAlpha > 0.03)
		flashBlur.Size = 18 * flashPeakAlpha
	end

	-- Stamina visibility & fill
	local clampedStamina = math.clamp(staminaRatio, 0, 1)
	staminaFill.Size = UDim2.fromScale(clampedStamina, 1)
	local staminaVisible = not menuBlocking and clampedStamina < 0.995
	staminaTrack.Visible = staminaVisible
	staminaFill.BackgroundColor3 = if clampedStamina < 0.25
		then Color3.fromRGB(220, 110, 95)
		else Color3.fromRGB(215, 222, 230)

	-- Minimal posture, sensitivity, & tactical grenades readout
	if menuBlocking then
		postureLabel.Text = ""
		if grenadeLabel then
			grenadeLabel.Text = ""
		end
	else
		local pose = if isCrouching then "ПРИСЕД" else "СТОЯ"
		local leanText = if leanDir < 0 then "  |  ◄ НАКЛОН" elseif leanDir > 0 then "  |  НАКЛОН ►" else ""
		postureLabel.Text = string.format("%s%s  |  [M] Сенса: %.2f", pose, leanText, baseSensitivity)
		if grenadeLabel then
			grenadeLabel.Text = string.format("[G] ОСКОЛ: %d   |   [F] ФЛЕШ: %d", fragCount, flashCount)
			grenadeLabel.TextColor3 = if (fragCount + flashCount) > 0
				then Color3.fromRGB(196, 206, 218)
				else Color3.fromRGB(145, 118, 118)
		end
	end

	-- Expire old killfeed entries
	for i = #killfeedRows, 1, -1 do
		local item = killfeedRows[i]
		if now - item.CreatedAt >= KILLFEED_LIFETIME then
			item.Frame:Destroy()
			table.remove(killfeedRows, i)
		end
	end
end

return HUDController
