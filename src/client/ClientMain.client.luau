--!strict
-- Client entry point: disables arcade Health CoreGui, wires controller initialization,
-- binds deterministic Camera -> Viewmodel -> HUD RenderStepped pipeline, and handles spawn lifecycle.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NetworkTypes = require(Shared.NetworkTypes)
local WeaponConfig = require(Shared.WeaponConfig)

local ClientFolder = script.Parent
local MovementController = require(ClientFolder.MovementController)
local ViewmodelController = require(ClientFolder.ViewmodelController)
local WeaponController = require(ClientFolder.WeaponController)
local HUDController = require(ClientFolder.HUDController)

local localPlayer = Players.LocalPlayer

pcall(function()
	StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Health, false)
end)

local requestSpawnRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.RequestSpawn)
local killfeedRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.KillfeedUpdate)
local matchStateRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.MatchStateSync)
local castMapVoteRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.CastMapVote)
local requestMapVoteStartRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.RequestMapVoteStart)
local mapVoteSyncRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.MapVoteSync)

local currentLoadout: NetworkTypes.LoadoutSelection = {
	Primary = WeaponConfig.DEFAULT_PRIMARY,
	Secondary = WeaponConfig.DEFAULT_SECONDARY,
}
local currentMatchState: NetworkTypes.MatchState = "Active"
local isWaitingForSpawn = false
local lastAppliedCameraOffset = CFrame.identity

local function isLocalCharacterAlive(): boolean
	local char = localPlayer.Character
	if not char then
		return false
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and hum.Health > 0
end

local function onDeployRequested(loadout: NetworkTypes.LoadoutSelection): ()
	if currentMatchState ~= "Active" or isWaitingForSpawn or isLocalCharacterAlive() then
		return
	end

	currentLoadout = loadout
	isWaitingForSpawn = true
	HUDController.SetSettingsMenuVisible(false)
	HUDController.SetLoadoutMenuVisible(false)
	WeaponController.SetMenuBlocking(false)
	requestSpawnRemote:FireServer(loadout)

	-- Safeguard: re-open menu if spawn did not complete within 2.5s (e.g. respawn timer jitter)
	task.delay(2.5, function()
		if isWaitingForSpawn and not isLocalCharacterAlive() and currentMatchState == "Active" then
			isWaitingForSpawn = false
			WeaponController.SetMenuBlocking(true)
			HUDController.SetLoadoutMenuVisible(true, "Ожидание подтверждения спавна...", 0.5)
		end
	end)
end

HUDController.Init(
	onDeployRequested,
	function(baseSens: number, adsScale: number)
		ViewmodelController.SetSensitivity(baseSens, adsScale)
	end,
	function(isBlocking: boolean)
		WeaponController.SetMenuBlocking(isBlocking)
	end,
	function(mapId: string)
		castMapVoteRemote:FireServer({ MapId = mapId })
	end,
	function()
		requestMapVoteStartRemote:FireServer()
	end
)
MovementController.Init()
WeaponController.Init()
do
	local initBaseSens, initAdsScale = HUDController.GetSensitivity()
	ViewmodelController.SetSensitivity(initBaseSens, initAdsScale)
end

UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
	if gameProcessed then
		return
	end
	if input.KeyCode == Enum.KeyCode.M or input.KeyCode == Enum.KeyCode.F2 then
		HUDController.ToggleSettingsMenu()
	end
end)

killfeedRemote.OnClientEvent:Connect(function(entry: NetworkTypes.KillfeedEntry)
	if typeof(entry) == "table" then
		HUDController.AddKillfeedEntry(entry)
	end
end)

mapVoteSyncRemote.OnClientEvent:Connect(function(payload: NetworkTypes.MapVoteStatePayload)
	if typeof(payload) == "table" then
		HUDController.OnMapVoteUpdated(payload)
	end
end)

matchStateRemote.OnClientEvent:Connect(function(payload: NetworkTypes.MatchStatePayload)
	if typeof(payload) ~= "table" then
		return
	end
	local prevState = currentMatchState
	currentMatchState = payload.State
	HUDController.OnMatchStateChanged(payload)
	if payload.State == "Intermission" then
		isWaitingForSpawn = false
		WeaponController.OnCharacterDied()
		WeaponController.ClearVisualEffects()
		WeaponController.SetMenuBlocking(true)
		HUDController.SetSettingsMenuVisible(false)
	elseif prevState == "Intermission" and payload.State == "Active" then
		WeaponController.ClearVisualEffects()
	end
end)

local function onCharacterAdded(character: Model): ()
	isWaitingForSpawn = false
	lastAppliedCameraOffset = CFrame.identity
	local humanoid = character:WaitForChild("Humanoid", 5)
	local root = character:WaitForChild("HumanoidRootPart", 5)
	if not humanoid or not humanoid:IsA("Humanoid") or not root then
		return
	end

	MovementController.BindCharacter(character)
	HUDController.ResetHealthEffects()
	HUDController.SetLoadoutMenuVisible(false)
	WeaponController.OnCharacterSpawned(currentLoadout)
	WeaponController.SetMenuBlocking(HUDController.IsAnyMenuOpen())

	humanoid.Died:Connect(function()
		lastAppliedCameraOffset = CFrame.identity
		WeaponController.OnCharacterDied()
		WeaponController.SetMenuBlocking(true)
		HUDController.SetSettingsMenuVisible(false)
		HUDController.SetLoadoutMenuVisible(true, "Вы выбыли из строя  —  подготовьте снаряжение", 3.0)
	end)
end

if localPlayer.Character then
	onCharacterAdded(localPlayer.Character)
end
localPlayer.CharacterAdded:Connect(onCharacterAdded)

RunService:BindToRenderStep("TacticalPreCameraStep", Enum.RenderPriority.Camera.Value - 1, function(_dt: number)
	if lastAppliedCameraOffset ~= CFrame.identity then
		local camera = Workspace.CurrentCamera
		if camera then
			camera.CFrame = camera.CFrame * lastAppliedCameraOffset:Inverse()
		end
		lastAppliedCameraOffset = CFrame.identity
	end
end)

RunService:BindToRenderStep("TacticalCameraStep", Enum.RenderPriority.Camera.Value + 1, function(dt: number)
	MovementController.Update(dt)
	WeaponController.Update(dt)

	local camera = Workspace.CurrentCamera
	if camera and isLocalCharacterAlive() then
		local moveOffset = MovementController.GetCameraOffsetCFrame(camera.CFrame)
		local recoilOffset = WeaponController.GetCameraRecoilCFrame()
		local combinedOffset = moveOffset * recoilOffset
		camera.CFrame = camera.CFrame * combinedOffset
		lastAppliedCameraOffset = combinedOffset
	else
		lastAppliedCameraOffset = CFrame.identity
	end
end)

RunService:BindToRenderStep("TacticalViewmodelStep", Enum.RenderPriority.Camera.Value + 2, function(dt: number)
	ViewmodelController.Update(dt)

	local snap = MovementController.GetSnapshot()
	local staminaRatio = snap.Stamina / math.max(snap.MaxStamina, 1)
	HUDController.Update(
		dt,
		staminaRatio,
		snap.IsCrouching,
		snap.LeanDirection,
		WeaponController.ShouldShowScopeOverlay()
	)
end)
