--!strict
-- Tactical first-person movement controller: stamina-gated sprint with regen delay,
-- smooth crouching (C), collision-checked leaning (Q/E) with camera roll,
-- jump inertia, and height-scaled landing camera shake.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local Workspace = game:GetService("Workspace")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local NetworkTypes = require(Shared.NetworkTypes)
local Spring = require(Shared.Spring)

export type MovementSnapshot = {
	IsAlive: boolean,
	IsSprinting: boolean,
	IsCrouching: boolean,
	IsGrounded: boolean,
	LeanDirection: number,
	LeanValue: number,
	MoveSpeed: number,
	NormalizedSpeed: number,
	LocalMoveDirection: Vector3,
	Stamina: number,
	MaxStamina: number,
}

local MovementController = {}

local WALK_SPEED = 14.5
local SPRINT_SPEED = 22.5
local CROUCH_SPEED = 8.5
local ADS_SPEED_MULTIPLIER = 0.72
local JUMP_POWER = 44

local MAX_STAMINA = 100
local STAMINA_DRAIN_PER_SEC = 18
local STAMINA_REGEN_PER_SEC = 22
local STAMINA_REGEN_DELAY = 1.35
local STAMINA_MIN_TO_RESUME_SPRINT = 15
local JUMP_STAMINA_COST = 12

local CROUCH_CAMERA_DROP = -1.55
local LEAN_LATERAL_OFFSET = 1.15
local LEAN_ROLL_DEGREES = 10.5

local localPlayer = Players.LocalPlayer
local updatePostureRemote: UnreliableRemoteEvent

local crouchSpring = Spring.scalarFromFrequency(0.95, 5.2, 1, 0)
local leanSpring = Spring.scalarFromFrequency(0.90, 6.2, 1, 0)
local landingPosSpring = Spring.fromFrequency(0.72, 6.8, 1, Vector3.zero)
local landingRotSpring = Spring.fromFrequency(0.68, 7.5, 1, Vector3.zero)

local currentCharacter: Model? = nil
local currentHumanoid: Humanoid? = nil
local currentRoot: BasePart? = nil

local isCrouching = false
local isSprintInputHeld = false
local isSprinting = false
local isAdsActive = false
local isGrounded = true
local stamina = MAX_STAMINA
local staminaExhaustedLock = false
local lastStaminaSpendTime = 0
local fallPeakY = 0

local leftLeanHeld = false
local rightLeanHeld = false
local targetLean = 0

local lastReplicatedCrouch: boolean? = nil
local lastReplicatedLean: number? = nil

local characterConnections: { RBXScriptConnection } = {}
local inputConnections: { RBXScriptConnection } = {}
local leanCheckParams = RaycastParams.new()
leanCheckParams.IgnoreWater = true
leanCheckParams.RespectCanCollide = true

local function disconnectList(conns: { RBXScriptConnection }): ()
	for _, conn in ipairs(conns) do
		conn:Disconnect()
	end
	table.clear(conns)
end

local function updateTargetLean(): ()
	if leftLeanHeld and not rightLeanHeld then
		targetLean = -1
	elseif rightLeanHeld and not leftLeanHeld then
		targetLean = 1
	else
		targetLean = 0
	end
	leanSpring:SetTarget(targetLean)
end

local function replicatePostureIfChanged(): ()
	if isCrouching ~= lastReplicatedCrouch or targetLean ~= lastReplicatedLean then
		lastReplicatedCrouch = isCrouching
		lastReplicatedLean = targetLean
		local payload: NetworkTypes.ClientPosturePayload = {
			IsCrouching = isCrouching,
			LeanDirection = targetLean,
		}
		updatePostureRemote:FireServer(payload)
	end
end

local function computeSafeLeanOffset(cameraCFrame: CFrame, desiredLateralOffset: number): number
	if math.abs(desiredLateralOffset) < 0.02 or not currentCharacter then
		return desiredLateralOffset
	end

	leanCheckParams.ExcludeInstances = { currentCharacter }
	local dir = cameraCFrame.RightVector * math.sign(desiredLateralOffset)
	local castDist = math.abs(desiredLateralOffset) + 0.35
	local hit = Workspace:Raycast(cameraCFrame.Position, dir * castDist, leanCheckParams)
	if hit then
		local clamped = math.max(0, hit.Distance - 0.35)
		return clamped * math.sign(desiredLateralOffset)
	end
	return desiredLateralOffset
end

local function bindCharacter(character: Model): ()
	if currentCharacter == character then
		return
	end
	disconnectList(characterConnections)

	currentCharacter = character
	currentHumanoid = nil
	currentRoot = nil

	local humanoid = character:WaitForChild("Humanoid", 5)
	local root = character:WaitForChild("HumanoidRootPart", 5)

	if currentCharacter ~= character then
		return
	end
	if not humanoid or not humanoid:IsA("Humanoid") or not root or not root:IsA("BasePart") then
		return
	end

	currentHumanoid = humanoid
	currentRoot = root
	humanoid.UseJumpPower = true
	humanoid.JumpPower = JUMP_POWER
	humanoid.WalkSpeed = WALK_SPEED

	isCrouching = false
	isSprinting = false
	isGrounded = true
	stamina = MAX_STAMINA
	staminaExhaustedLock = false
	lastStaminaSpendTime = 0
	targetLean = 0
	fallPeakY = root.Position.Y
	lastReplicatedCrouch = nil
	lastReplicatedLean = nil

	crouchSpring:SnapTo(0)
	leanSpring:SnapTo(0)
	landingPosSpring:Reset()
	landingRotSpring:Reset()

	table.insert(
		characterConnections,
		humanoid.StateChanged:Connect(function(_oldState: Enum.HumanoidStateType, newState: Enum.HumanoidStateType)
			if newState == Enum.HumanoidStateType.Freefall then
				isGrounded = false
				fallPeakY = root.Position.Y
			elseif newState == Enum.HumanoidStateType.Jumping then
				isGrounded = false
				fallPeakY = root.Position.Y
				if stamina >= JUMP_STAMINA_COST then
					stamina = math.max(0, stamina - JUMP_STAMINA_COST)
					lastStaminaSpendTime = os.clock()
				end
				landingPosSpring:Shove(Vector3.new(0, 0.25, 0))
				landingRotSpring:Shove(Vector3.new(math.rad(1.4), 0, 0))
			elseif newState == Enum.HumanoidStateType.Landed then
				isGrounded = true
				local fallDist = math.max(0, fallPeakY - root.Position.Y)
				local impactScale = math.clamp((fallDist - 2.0) / 16.0, 0.15, 1.5)
				landingPosSpring:Shove(Vector3.new(0, -1.8 * impactScale, 0))
				landingRotSpring:Shove(
					Vector3.new(
						math.rad(-8.5 * impactScale),
						math.rad((math.random() - 0.5) * 3.0 * impactScale),
						math.rad((math.random() - 0.5) * 4.5 * impactScale)
					)
				)
				-- Preserve slight landing inertia by briefly damping horizontal velocity.
				local vel = root.AssemblyLinearVelocity
				root.AssemblyLinearVelocity = Vector3.new(vel.X * 0.82, vel.Y, vel.Z * 0.82)
			elseif newState == Enum.HumanoidStateType.Running or newState == Enum.HumanoidStateType.RunningNoPhysics then
				isGrounded = true
			end
		end)
	)

	-- Track apex height while airborne for accurate landing impact force.
	table.insert(
		characterConnections,
		RunService.Heartbeat:Connect(function()
			if not isGrounded and root.Parent then
				if root.Position.Y > fallPeakY then
					fallPeakY = root.Position.Y
				end
			end
		end)
	)
end

function MovementController.BindCharacter(character: Model): ()
	bindCharacter(character)
end

function MovementController.Init(): ()
	updatePostureRemote = NetworkTypes.GetUnreliableRemoteEvent(NetworkTypes.RemoteNames.UpdatePosture)

	disconnectList(inputConnections)

	table.insert(
		inputConnections,
		UserInputService.InputBegan:Connect(function(input: InputObject, gameProcessed: boolean)
			if gameProcessed then
				return
			end
			if input.KeyCode == Enum.KeyCode.LeftShift then
				isSprintInputHeld = true
			elseif input.KeyCode == Enum.KeyCode.C then
				if currentHumanoid and currentHumanoid.Health > 0 then
					isCrouching = not isCrouching
					crouchSpring:SetTarget(if isCrouching then CROUCH_CAMERA_DROP else 0)
					replicatePostureIfChanged()
				end
			elseif input.KeyCode == Enum.KeyCode.Q then
				leftLeanHeld = true
				updateTargetLean()
				replicatePostureIfChanged()
			elseif input.KeyCode == Enum.KeyCode.E then
				rightLeanHeld = true
				updateTargetLean()
				replicatePostureIfChanged()
			end
		end)
	)

	table.insert(
		inputConnections,
		UserInputService.InputEnded:Connect(function(input: InputObject, _gameProcessed: boolean)
			if input.KeyCode == Enum.KeyCode.LeftShift then
				isSprintInputHeld = false
			elseif input.KeyCode == Enum.KeyCode.Q then
				leftLeanHeld = false
				updateTargetLean()
				replicatePostureIfChanged()
			elseif input.KeyCode == Enum.KeyCode.E then
				rightLeanHeld = false
				updateTargetLean()
				replicatePostureIfChanged()
			end
		end)
	)

	if localPlayer.Character then
		bindCharacter(localPlayer.Character)
	end
end

function MovementController.SetAdsActive(active: boolean): ()
	isAdsActive = active
end

function MovementController.Update(dt: number): ()
	local humanoid = currentHumanoid
	local root = currentRoot
	if not humanoid or not root or humanoid.Health <= 0 then
		isSprinting = false
		return
	end

	local now = os.clock()
	local moveDir = humanoid.MoveDirection
	local horizontalVel = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
	local isMoving = moveDir.Magnitude > 0.1 and horizontalVel.Magnitude > 1.5

	-- Check forward alignment so tactical sprint doesn't happen while backpedaling.
	local camera = Workspace.CurrentCamera
	local isMovingForward = true
	if camera and isMoving then
		local camForward = Vector3.new(camera.CFrame.LookVector.X, 0, camera.CFrame.LookVector.Z)
		if camForward.Magnitude > 0.01 then
			isMovingForward = camForward.Unit:Dot(moveDir.Unit) > 0.25
		end
	end

	local canSprint = isSprintInputHeld
		and isMoving
		and isMovingForward
		and isGrounded
		and not isAdsActive
		and not staminaExhaustedLock
		and stamina > 0.5

	if canSprint and isCrouching then
		isCrouching = false
		crouchSpring:SetTarget(0)
		replicatePostureIfChanged()
	end

	isSprinting = canSprint

	if isSprinting then
		stamina = math.max(0, stamina - STAMINA_DRAIN_PER_SEC * dt)
		lastStaminaSpendTime = now
		if stamina <= 0 then
			staminaExhaustedLock = true
			isSprinting = false
		end
	else
		if now - lastStaminaSpendTime >= STAMINA_REGEN_DELAY then
			stamina = math.min(MAX_STAMINA, stamina + STAMINA_REGEN_PER_SEC * dt)
			if staminaExhaustedLock and stamina >= STAMINA_MIN_TO_RESUME_SPRINT then
				staminaExhaustedLock = false
			end
		end
	end

	-- Apply target walk speed & jump gating based on stamina
	local targetSpeed = WALK_SPEED
	if isSprinting then
		targetSpeed = SPRINT_SPEED
	elseif isCrouching then
		targetSpeed = CROUCH_SPEED
	end
	if isAdsActive then
		targetSpeed *= ADS_SPEED_MULTIPLIER
	end
	humanoid.WalkSpeed = targetSpeed
	humanoid.JumpPower = if stamina >= JUMP_STAMINA_COST then JUMP_POWER else 28

	-- Update procedural springs
	local crouchY = crouchSpring:Update(dt)
	leanSpring:Update(dt)
	local landPos = landingPosSpring:Update(dt)
	landingRotSpring:Update(dt)

	humanoid.CameraOffset = Vector3.new(0, crouchY + landPos.Y, 0)
end

function MovementController.GetCameraOffsetCFrame(baseCameraCFrame: CFrame): CFrame
	local leanValue = leanSpring.Position
	local desiredLateral = leanValue * LEAN_LATERAL_OFFSET
	local safeLateral = computeSafeLeanOffset(baseCameraCFrame, desiredLateral)
	local rollRad = -leanValue * math.rad(LEAN_ROLL_DEGREES)

	local landRot = landingRotSpring.Position
	return CFrame.new(safeLateral, 0, 0) * CFrame.Angles(landRot.X, landRot.Y, rollRad + landRot.Z)
end

function MovementController.GetSnapshot(): MovementSnapshot
	local humanoid = currentHumanoid
	local root = currentRoot
	local alive = humanoid ~= nil and root ~= nil and humanoid.Health > 0

	local moveSpeed = 0
	local localMoveDir = Vector3.zero
	if alive and root then
		local horizVel = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
		moveSpeed = horizVel.Magnitude
		local camera = Workspace.CurrentCamera
		if camera and moveSpeed > 0.1 then
			local invCam = camera.CFrame:VectorToObjectSpace(horizVel)
			localMoveDir = Vector3.new(invCam.X, 0, invCam.Z).Unit
		end
	end

	return {
		IsAlive = alive,
		IsSprinting = isSprinting,
		IsCrouching = isCrouching,
		IsGrounded = isGrounded,
		LeanDirection = targetLean,
		LeanValue = leanSpring.Position,
		MoveSpeed = moveSpeed,
		NormalizedSpeed = math.clamp(moveSpeed / SPRINT_SPEED, 0, 1),
		LocalMoveDirection = localMoveDir,
		Stamina = stamina,
		MaxStamina = MAX_STAMINA,
	}
end

return MovementController
