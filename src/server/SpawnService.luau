--!strict
-- Smart FFA spawn selector: picks SpawnLocations maximally distant from alive opponents
-- and outside their direct line-of-sight.

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local SpawnService = {}

local SPAWN_HEIGHT_OFFSET = 3.2
local EYE_HEIGHT_OFFSET = 5.0
local MIN_SAFE_ENEMY_DISTANCE = 24
local MAX_SCORED_DISTANCE = 320
local LINE_OF_SIGHT_PENALTY = 12000
local CLOSE_RANGE_PENALTY = 3000

local rng = Random.new()

local function getSpawnCandidates(): { BasePart }
	local candidates: { BasePart } = {}

	local spawnFolder = Workspace:FindFirstChild("SpawnLocations")
	if spawnFolder then
		for _, child in ipairs(spawnFolder:GetDescendants()) do
			if child:IsA("BasePart") then
				table.insert(candidates, child)
			end
		end
	end

	if #candidates == 0 then
		for _, child in ipairs(Workspace:GetDescendants()) do
			if child:IsA("SpawnLocation") then
				table.insert(candidates, child)
			end
		end
	end

	return candidates
end

local function collectAliveEnemies(targetPlayer: Player): ({ Model }, { Vector3 })
	local enemyCharacters: { Model } = {}
	local enemyEyes: { Vector3 } = {}

	for _, player in ipairs(Players:GetPlayers()) do
		if player ~= targetPlayer then
			local character = player.Character
			if character then
				local humanoid = character:FindFirstChildOfClass("Humanoid")
				local head = character:FindFirstChild("Head")
				local root = character:FindFirstChild("HumanoidRootPart")
				if humanoid and humanoid.Health > 0 then
					local eyePart = if head and head:IsA("BasePart")
						then head
						elseif root and root:IsA("BasePart") then root
						else nil
					if eyePart then
						table.insert(enemyCharacters, character)
						table.insert(enemyEyes, eyePart.Position)
					end
				end
			end
		end
	end

	return enemyCharacters, enemyEyes
end

local function hasLineOfSight(fromPos: Vector3, toPos: Vector3, rayParams: RaycastParams): boolean
	local delta = toPos - fromPos
	local dist = delta.Magnitude
	if dist < 1 then
		return true
	end
	local hit = Workspace:Raycast(fromPos, delta, rayParams)
	return hit == nil
end

function SpawnService.Init(): ()
	-- Kept explicit for deterministic bootstrap orchestration.
end

function SpawnService.SelectBestSpawnCFrame(targetPlayer: Player): CFrame
	local candidates = getSpawnCandidates()
	if #candidates == 0 then
		return CFrame.new(0, 8, 0)
	end

	local enemyCharacters, enemyEyes = collectAliveEnemies(targetPlayer)
	if #enemyEyes == 0 then
		local chosen = candidates[rng:NextInteger(1, #candidates)]
		local spawnPos = chosen.Position + Vector3.new(0, chosen.Size.Y * 0.5 + SPAWN_HEIGHT_OFFSET, 0)
		local lookTarget = Vector3.new(0, spawnPos.Y, 0)
		if (lookTarget - spawnPos).Magnitude > 2 then
			return CFrame.lookAt(spawnPos, lookTarget)
		end
		return CFrame.new(spawnPos) * chosen.CFrame.Rotation
	end

	local losParams = RaycastParams.new()
	losParams.IgnoreWater = true
	losParams.RespectCanCollide = false
	local excludes: { Instance } = {}
	for _, char in ipairs(enemyCharacters) do
		table.insert(excludes, char)
	end
	if targetPlayer.Character then
		table.insert(excludes, targetPlayer.Character)
	end
	losParams.ExcludeInstances = excludes

	local bestCandidate = candidates[1]
	local bestScore = -math.huge

	for _, candidate in ipairs(candidates) do
		local spawnPos = candidate.Position + Vector3.new(0, candidate.Size.Y * 0.5 + SPAWN_HEIGHT_OFFSET, 0)
		local eyePos = candidate.Position + Vector3.new(0, candidate.Size.Y * 0.5 + EYE_HEIGHT_OFFSET, 0)

		local minDistance = math.huge
		local totalDistance = 0
		local visibleCount = 0

		for _, enemyEye in ipairs(enemyEyes) do
			local dist = (eyePos - enemyEye).Magnitude
			if dist < minDistance then
				minDistance = dist
			end
			totalDistance += math.min(dist, MAX_SCORED_DISTANCE)

			if hasLineOfSight(enemyEye, eyePos, losParams) then
				visibleCount += 1
			end
		end

		local avgDistance = totalDistance / #enemyEyes
		local clampedMin = math.min(minDistance, MAX_SCORED_DISTANCE)
		local score = clampedMin * 1.5 + avgDistance * 0.35 - visibleCount * LINE_OF_SIGHT_PENALTY

		if minDistance < MIN_SAFE_ENEMY_DISTANCE then
			score -= CLOSE_RANGE_PENALTY * (1 - minDistance / MIN_SAFE_ENEMY_DISTANCE)
		end

		score += rng:NextNumber(0, 6)

		if score > bestScore then
			bestScore = score
			bestCandidate = candidate
		end
	end

	local finalPos = bestCandidate.Position + Vector3.new(0, bestCandidate.Size.Y * 0.5 + SPAWN_HEIGHT_OFFSET, 0)
	local arenaCenter = Vector3.new(0, finalPos.Y, 0)
	if (arenaCenter - finalPos).Magnitude > 2 then
		return CFrame.lookAt(finalPos, arenaCenter)
	end
	return CFrame.new(finalPos) * bestCandidate.CFrame.Rotation
end

function SpawnService.SpawnPlayerAtSafePoint(player: Player): Model?
	if not player.Parent then
		return nil
	end

	local targetCFrame = SpawnService.SelectBestSpawnCFrame(player)
	player:LoadCharacter()

	local character = player.Character or player.CharacterAdded:Wait()
	if not character or not player.Parent then
		return nil
	end

	local root = character:WaitForChild("HumanoidRootPart", 5)
	if root and root:IsA("BasePart") then
		root.CanQuery = false
	end

	-- Remove default Roblox Health regen script for tactical realism.
	local defaultHealth = character:FindFirstChild("Health")
	if defaultHealth then
		defaultHealth:Destroy()
	end

	character:PivotTo(targetCFrame)
	return character
end

return SpawnService
