--!strict
-- FFA match loop & map voting manager: 30-kill / 10-minute matches, intermission map vote
-- across all 4 tactical maps, early RTV vote-to-switch, leaderstats, and killfeed broadcasting.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local MapConfig = require(Shared.MapConfig)
local NetworkTypes = require(Shared.NetworkTypes)
local WeaponConfig = require(Shared.WeaponConfig)

export type MatchState = NetworkTypes.MatchState
export type LoadoutSelection = NetworkTypes.LoadoutSelection
export type SpawnServiceModule = {
	SpawnPlayerAtSafePoint: (player: Player) -> Model?,
}
export type MapServiceModule = {
	LoadMap: (mapId: string) -> boolean,
	GetCurrentMapId: () -> string,
}
export type OnPlayerSpawnedCallback = (player: Player, character: Model, loadout: LoadoutSelection) -> ()
export type OnPlayerCleanupCallback = (player: Player) -> ()
export type OnClearProjectilesCallback = () -> ()

local GameLoopService = {}

GameLoopService.SCORE_LIMIT = 30
GameLoopService.MATCH_DURATION_SECONDS = 600 -- 10 minutes
GameLoopService.INTERMISSION_SECONDS = 15
GameLoopService.VOTING_FINALIZE_SECONDS = 2.5
GameLoopService.RESPAWN_DELAY_SECONDS = 3.0

local spawnService: SpawnServiceModule
local mapService: MapServiceModule
local onPlayerSpawned: OnPlayerSpawnedCallback?
local onPlayerCleanup: OnPlayerCleanupCallback?
local onClearProjectiles: OnClearProjectilesCallback?

local requestSpawnRemote: RemoteEvent
local killfeedRemote: RemoteEvent
local matchStateRemote: RemoteEvent
local castMapVoteRemote: RemoteEvent
local requestMapVoteStartRemote: RemoteEvent
local mapVoteSyncRemote: RemoteEvent

local currentState: MatchState = "Active"
local timeRemaining: number = GameLoopService.MATCH_DURATION_SECONDS
local syncAccumulator = 0
local lastWinnerName: string? = nil
local lastWinnerKills: number? = nil

local playerLoadouts: { [Player]: LoadoutSelection } = {}
local nextRespawnTime: { [Player]: number } = {}
local spawningPlayers: { [Player]: boolean } = {}
local playerMapVotes: { [Player]: string } = {}
local rtvVotes: { [Player]: boolean } = {}
local heartbeatConnection: RBXScriptConnection? = nil
local voteRng = Random.new()

local function getLeaderstatsValues(player: Player): (IntValue?, IntValue?, IntValue?)
	local stats = player:FindFirstChild("leaderstats")
	if not stats then
		return nil, nil, nil
	end
	local kills = stats:FindFirstChild("Kills")
	local deaths = stats:FindFirstChild("Deaths")
	local streak = stats:FindFirstChild("Streak")
	return if kills and kills:IsA("IntValue") then kills else nil,
		if deaths and deaths:IsA("IntValue") then deaths else nil,
		if streak and streak:IsA("IntValue") then streak else nil
end

local function createLeaderstats(player: Player): ()
	if player:FindFirstChild("leaderstats") then
		return
	end

	local folder = Instance.new("Folder")
	folder.Name = "leaderstats"

	local kills = Instance.new("IntValue")
	kills.Name = "Kills"
	kills.Value = 0
	kills.Parent = folder

	local deaths = Instance.new("IntValue")
	deaths.Name = "Deaths"
	deaths.Value = 0
	deaths.Parent = folder

	local streak = Instance.new("IntValue")
	streak.Name = "Streak"
	streak.Value = 0
	streak.Parent = folder

	folder.Parent = player
end

local function sanitizeLoadout(rawPayload: unknown): LoadoutSelection
	local primaryId = WeaponConfig.DEFAULT_PRIMARY
	local secondaryId = WeaponConfig.DEFAULT_SECONDARY

	if typeof(rawPayload) == "table" then
		local payload = rawPayload :: { [string]: unknown }
		if typeof(payload.Primary) == "string" then
			local def = WeaponConfig.GetWeapon(payload.Primary)
			if def and def.Slot == "Primary" then
				primaryId = def.Id
			end
		end
		if typeof(payload.Secondary) == "string" then
			local def = WeaponConfig.GetWeapon(payload.Secondary)
			if def and def.Slot == "Secondary" then
				secondaryId = def.Id
			end
		end
	end

	return {
		Primary = primaryId,
		Secondary = secondaryId,
	}
end

local function findMatchLeader(): (string?, number?)
	local bestName: string? = nil
	local bestKills = -1

	for _, player in ipairs(Players:GetPlayers()) do
		local kills = getLeaderstatsValues(player)
		if kills and kills.Value > bestKills then
			bestKills = kills.Value
			bestName = player.Name
		end
	end

	if bestKills < 0 then
		return nil, nil
	end
	return bestName, bestKills
end

local function getCurrentMapInfo(): (string, string)
	local mapId = if mapService then mapService.GetCurrentMapId() else MapConfig.DEFAULT_MAP_ID
	local def = MapConfig.GetMap(mapId)
	return mapId, if def then def.DisplayName else mapId
end

local function countRtvVotes(): (number, number)
	local totalPlayers = #Players:GetPlayers()
	local rtvCount = 0
	for voter in pairs(rtvVotes) do
		if voter.Parent == Players then
			rtvCount += 1
		end
	end
	local needed = math.max(1, math.floor(totalPlayers / 2) + 1)
	return rtvCount, needed
end

local function countMapVotes(): ({ [string]: number }, number)
	local counts: { [string]: number } = {}
	for _, mapId in ipairs(MapConfig.MapOrder) do
		counts[mapId] = 0
	end

	local validVoterCount = 0
	for voter, mapId in pairs(playerMapVotes) do
		if voter.Parent == Players and counts[mapId] ~= nil then
			counts[mapId] += 1
			validVoterCount += 1
		end
	end
	return counts, validVoterCount
end

local function buildMatchStatePayload(): NetworkTypes.MatchStatePayload
	local mapId, mapName = getCurrentMapInfo()
	return {
		State = currentState,
		TimeRemaining = math.max(0, math.ceil(timeRemaining)),
		ScoreLimit = GameLoopService.SCORE_LIMIT,
		WinnerName = lastWinnerName,
		WinnerKills = lastWinnerKills,
		CurrentMapId = mapId,
		CurrentMapName = mapName,
	}
end

local function buildMapVotePayload(player: Player): NetworkTypes.MapVoteStatePayload
	local mapId, mapName = getCurrentMapInfo()
	local counts = countMapVotes()
	local rtvCount, rtvNeeded = countRtvVotes()

	return {
		IsVotingActive = currentState == "Intermission",
		CurrentMapId = mapId,
		CurrentMapName = mapName,
		Candidates = table.clone(MapConfig.MapOrder),
		VoteCounts = counts,
		MyVoteMapId = playerMapVotes[player],
		RtvVotes = rtvCount,
		RtvNeeded = rtvNeeded,
		MyRtvVoted = rtvVotes[player] == true,
	}
end

local function broadcastMatchState(): ()
	matchStateRemote:FireAllClients(buildMatchStatePayload())
end

local function broadcastMapVoteState(): ()
	for _, player in ipairs(Players:GetPlayers()) do
		mapVoteSyncRemote:FireClient(player, buildMapVotePayload(player))
	end
end

local function chooseWinningMap(): string
	local currentMapId = getCurrentMapInfo()
	local counts, totalVotes = countMapVotes()

	if totalVotes == 0 then
		-- Rotate deterministically to the next map if nobody voted.
		local idx = table.find(MapConfig.MapOrder, currentMapId) or 1
		local nextIdx = (idx % #MapConfig.MapOrder) + 1
		return MapConfig.MapOrder[nextIdx]
	end

	local maxVotes = -1
	local winners: { string } = {}
	for _, mapId in ipairs(MapConfig.MapOrder) do
		local v = counts[mapId] or 0
		if v > maxVotes then
			maxVotes = v
			winners = { mapId }
		elseif v == maxVotes then
			table.insert(winners, mapId)
		end
	end

	if #winners == 1 then
		return winners[1]
	end

	-- Break ties randomly among top-voted maps.
	return winners[voteRng:NextInteger(1, #winners)]
end

local function beginIntermission(winnerName: string?, winnerKills: number?): ()
	if currentState == "Intermission" then
		return
	end
	currentState = "Intermission"
	timeRemaining = GameLoopService.INTERMISSION_SECONDS
	lastWinnerName = winnerName
	lastWinnerKills = winnerKills
	syncAccumulator = 0
	table.clear(playerMapVotes)
	table.clear(rtvVotes)
	broadcastMatchState()
	broadcastMapVoteState()
end

local function startNewMatch(): ()
	local nextMapId = chooseWinningMap()

	for _, player in ipairs(Players:GetPlayers()) do
		local kills, deaths, streak = getLeaderstatsValues(player)
		if kills then
			kills.Value = 0
		end
		if deaths then
			deaths.Value = 0
		end
		if streak then
			streak.Value = 0
		end
		nextRespawnTime[player] = 0

		if onPlayerCleanup then
			onPlayerCleanup(player)
		end

		local character = player.Character
		if character then
			player.Character = nil
			character:Destroy()
		end
	end

	if onClearProjectiles then
		onClearProjectiles()
	end

	mapService.LoadMap(nextMapId)

	table.clear(playerMapVotes)
	table.clear(rtvVotes)
	currentState = "Active"
	timeRemaining = GameLoopService.MATCH_DURATION_SECONDS
	lastWinnerName = nil
	lastWinnerKills = nil
	syncAccumulator = 0
	broadcastMatchState()
	broadcastMapVoteState()
end

local function isPlayerAlive(player: Player): boolean
	local character = player.Character
	if not character then
		return false
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

local function handleRequestSpawn(player: Player, rawPayload: unknown): ()
	if currentState ~= "Active" then
		return
	end
	if spawningPlayers[player] or isPlayerAlive(player) then
		return
	end

	local now = Workspace:GetServerTimeNow()
	local allowedAt = nextRespawnTime[player] or 0
	if now < allowedAt then
		return
	end

	local loadout = sanitizeLoadout(rawPayload)
	playerLoadouts[player] = loadout
	spawningPlayers[player] = true

	local ok, err = pcall(function()
		local character = spawnService.SpawnPlayerAtSafePoint(player)
		if character and player.Parent == Players and currentState == "Active" then
			if onPlayerSpawned then
				onPlayerSpawned(player, character, loadout)
			end
		end
	end)

	spawningPlayers[player] = nil
	if not ok then
		warn("[GameLoopService] Spawn failed for", player.Name, err)
	end
end

local function handleCastMapVote(player: Player, rawPayload: unknown): ()
	if currentState ~= "Intermission" then
		return
	end
	if typeof(rawPayload) ~= "table" then
		return
	end

	local payload = rawPayload :: { [string]: unknown }
	local mapId = payload.MapId
	if typeof(mapId) ~= "string" or not MapConfig.GetMap(mapId) then
		return
	end

	playerMapVotes[player] = mapId
	broadcastMapVoteState()

	-- Fast-forward intermission countdown once every connected player has cast a vote.
	local activePlayers = Players:GetPlayers()
	if #activePlayers > 0 then
		local everyoneVoted = true
		for _, p in ipairs(activePlayers) do
			if not playerMapVotes[p] then
				everyoneVoted = false
				break
			end
		end
		if everyoneVoted and timeRemaining > GameLoopService.VOTING_FINALIZE_SECONDS then
			timeRemaining = GameLoopService.VOTING_FINALIZE_SECONDS
			syncAccumulator = 0
			broadcastMatchState()
		end
	end
end

local function handleRequestMapVoteStart(player: Player): ()
	if currentState ~= "Active" then
		return
	end

	if rtvVotes[player] then
		rtvVotes[player] = nil
	else
		rtvVotes[player] = true
	end

	local rtvCount, rtvNeeded = countRtvVotes()
	if rtvCount >= rtvNeeded then
		local leaderName, leaderKills = findMatchLeader()
		beginIntermission(leaderName, leaderKills)
	else
		broadcastMapVoteState()
	end
end

function GameLoopService.IsMatchActive(): boolean
	return currentState == "Active"
end

function GameLoopService.SetOnPlayerSpawned(callback: OnPlayerSpawnedCallback): ()
	onPlayerSpawned = callback
end

function GameLoopService.SetOnPlayerCleanup(callback: OnPlayerCleanupCallback): ()
	onPlayerCleanup = callback
end

function GameLoopService.MarkPlayerDied(victim: Player): ()
	nextRespawnTime[victim] = Workspace:GetServerTimeNow() + GameLoopService.RESPAWN_DELAY_SECONDS
end

function GameLoopService.RecordKill(
	killer: Player?,
	victim: Player,
	weaponId: string,
	isHeadshot: boolean,
	isWallbang: boolean,
	distance: number
): ()
	GameLoopService.MarkPlayerDied(victim)

	local _, victimDeaths, victimStreak = getLeaderstatsValues(victim)
	if victimDeaths then
		victimDeaths.Value += 1
	end
	if victimStreak then
		victimStreak.Value = 0
	end

	local killerName = victim.Name
	local killerUserId = victim.UserId
	local killerKillsValue = 0

	if killer and killer ~= victim and killer.Parent == Players then
		killerName = killer.Name
		killerUserId = killer.UserId
		local killerKills, _, killerStreak = getLeaderstatsValues(killer)
		if killerKills then
			killerKills.Value += 1
			killerKillsValue = killerKills.Value
		end
		if killerStreak then
			killerStreak.Value += 1
		end
	end

	local entry: NetworkTypes.KillfeedEntry = {
		KillerName = killerName,
		KillerUserId = killerUserId,
		VictimName = victim.Name,
		VictimUserId = victim.UserId,
		WeaponId = weaponId,
		IsHeadshot = isHeadshot,
		IsWallbang = isWallbang,
		Distance = math.round(distance),
		Timestamp = Workspace:GetServerTimeNow(),
	}
	killfeedRemote:FireAllClients(entry)

	if currentState == "Active" and killer and killer ~= victim and killerKillsValue >= GameLoopService.SCORE_LIMIT then
		beginIntermission(killer.Name, killerKillsValue)
	end
end

function GameLoopService.Init(
	spawnSvc: SpawnServiceModule,
	mapSvc: MapServiceModule,
	clearProjectilesCb: OnClearProjectilesCallback?
): ()
	spawnService = spawnSvc
	mapService = mapSvc
	onClearProjectiles = clearProjectilesCb

	requestSpawnRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.RequestSpawn)
	killfeedRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.KillfeedUpdate)
	matchStateRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.MatchStateSync)
	castMapVoteRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.CastMapVote)
	requestMapVoteStartRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.RequestMapVoteStart)
	mapVoteSyncRemote = NetworkTypes.GetRemoteEvent(NetworkTypes.RemoteNames.MapVoteSync)

	requestSpawnRemote.OnServerEvent:Connect(handleRequestSpawn)
	castMapVoteRemote.OnServerEvent:Connect(handleCastMapVote)
	requestMapVoteStartRemote.OnServerEvent:Connect(handleRequestMapVoteStart)

	local function onPlayerAdded(player: Player): ()
		createLeaderstats(player)
		playerLoadouts[player] = {
			Primary = WeaponConfig.DEFAULT_PRIMARY,
			Secondary = WeaponConfig.DEFAULT_SECONDARY,
		}
		nextRespawnTime[player] = 0
		matchStateRemote:FireClient(player, buildMatchStatePayload())
		mapVoteSyncRemote:FireClient(player, buildMapVotePayload(player))

		player.Chatted:Connect(function(msg: string)
			local trimmed = string.lower((string.gsub(msg, "^%s*(.-)%s*$", "%1")))
			if trimmed == "/rtv" or trimmed == "!rtv" or trimmed == "rtv" then
				handleRequestMapVoteStart(player)
			end
		end)
	end

	Players.PlayerAdded:Connect(onPlayerAdded)
	for _, existingPlayer in ipairs(Players:GetPlayers()) do
		onPlayerAdded(existingPlayer)
	end

	Players.PlayerRemoving:Connect(function(player: Player)
		playerLoadouts[player] = nil
		nextRespawnTime[player] = nil
		spawningPlayers[player] = nil
		playerMapVotes[player] = nil
		rtvVotes[player] = nil
		if onPlayerCleanup then
			onPlayerCleanup(player)
		end
		broadcastMapVoteState()
	end)

	if heartbeatConnection then
		heartbeatConnection:Disconnect()
	end

	heartbeatConnection = RunService.Heartbeat:Connect(function(dt: number)
		timeRemaining -= dt
		syncAccumulator += dt

		if currentState == "Active" then
			if timeRemaining <= 0 then
				local leaderName, leaderKills = findMatchLeader()
				beginIntermission(leaderName, leaderKills)
				return
			end
		elseif currentState == "Intermission" then
			if timeRemaining <= 0 then
				startNewMatch()
				return
			end
		end

		if syncAccumulator >= 1.0 then
			syncAccumulator = 0
			broadcastMatchState()
		end
	end)

	broadcastMatchState()
	broadcastMapVoteState()
end

return GameLoopService
