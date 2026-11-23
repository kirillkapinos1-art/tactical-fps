--!strict
-- Shared network contracts, remote definitions, and payload validation helpers
-- used by both Server and Client layers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

export type FireMode = "Auto" | "Semi"
export type WeaponSlot = "Primary" | "Secondary"
export type WeaponCategory = "AssaultRifle" | "SMG" | "Sniper" | "Pistol"
export type HitZone = "Head" | "Torso" | "Limb"
export type MatchState = "Waiting" | "Active" | "Intermission"
export type RemoteClassName = "RemoteEvent" | "UnreliableRemoteEvent"
export type GrenadeType = "Frag" | "Flash"

export type LoadoutSelection = {
	Primary: string,
	Secondary: string,
}

export type ClientFirePayload = {
	WeaponId: string,
	Origin: Vector3,
	Direction: Vector3,
	ClientTime: number,
	Sequence: number,
}

export type ClientReloadPayload = {
	Action: "Start" | "Cancel",
	WeaponId: string,
}

export type ClientSwitchPayload = {
	Slot: WeaponSlot,
}

export type ClientFireModePayload = {
	WeaponId: string,
	FireMode: FireMode,
}

export type ClientPosturePayload = {
	IsCrouching: boolean,
	LeanDirection: number, -- -1 (left), 0 (center), 1 (right)
}

export type ReplicatedTracerPayload = {
	ShooterUserId: number,
	WeaponId: string,
	Origin: Vector3,
	Velocity: Vector3,
	GravityMultiplier: number,
	DragCoefficient: number,
	MaxRange: number,
	PenetrationPower: number,
}

export type HitConfirmPayload = {
	TargetUserId: number,
	Zone: HitZone,
	Damage: number,
	IsFatal: boolean,
	IsWallbang: boolean,
	Distance: number,
}

export type DamageTakenPayload = {
	DirectionOrigin: Vector3,
	Damage: number,
	Health: number,
	MaxHealth: number,
}

export type SuppressionPayload = {
	Intensity: number,
	ClosestPoint: Vector3,
}

export type AmmoSyncPayload = {
	Slot: WeaponSlot,
	WeaponId: string,
	Magazine: number,
	Reserve: number,
	FireMode: FireMode,
	IsReloading: boolean,
	ReloadDuration: number?,
}

export type KillfeedEntry = {
	KillerName: string,
	KillerUserId: number,
	VictimName: string,
	VictimUserId: number,
	WeaponId: string,
	IsHeadshot: boolean,
	IsWallbang: boolean,
	Distance: number,
	Timestamp: number,
}

export type MatchStatePayload = {
	State: MatchState,
	TimeRemaining: number,
	ScoreLimit: number,
	WinnerName: string?,
	WinnerKills: number?,
	CurrentMapId: string,
	CurrentMapName: string,
}

export type MapVoteStatePayload = {
	IsVotingActive: boolean,
	CurrentMapId: string,
	CurrentMapName: string,
	Candidates: { string },
	VoteCounts: { [string]: number },
	MyVoteMapId: string?,
	RtvVotes: number,
	RtvNeeded: number,
	MyRtvVoted: boolean,
}

export type ClientGrenadeThrowPayload = {
	GrenadeType: GrenadeType,
	Origin: Vector3,
	Direction: Vector3,
}

export type ReplicatedGrenadePayload = {
	GrenadeId: number,
	ThrowerUserId: number,
	GrenadeType: GrenadeType,
	Origin: Vector3,
	Velocity: Vector3,
	FuseTime: number,
}

export type GrenadeDetonatedPayload = {
	GrenadeId: number,
	GrenadeType: GrenadeType,
	Position: Vector3,
}

export type GrenadeSyncPayload = {
	Frag: number,
	Flash: number,
}

export type FlashbangEffectPayload = {
	Origin: Vector3,
	Distance: number,
	DistanceFactor: number,
	MaxDuration: number,
	InnerStunRadius: number,
}

local NetworkTypes = {}

NetworkTypes.REMOTES_FOLDER_NAME = "Remotes"
NetworkTypes.WEAPONS_FOLDER_NAME = "Weapons"

NetworkTypes.RemoteNames = {
	FireWeapon = "FireWeapon",
	ReloadWeapon = "ReloadWeapon",
	SwitchWeapon = "SwitchWeapon",
	SetFireMode = "SetFireMode",
	RequestSpawn = "RequestSpawn",
	UpdatePosture = "UpdatePosture",
	BulletReplicated = "BulletReplicated",
	HitConfirm = "HitConfirm",
	DamageTaken = "DamageTaken",
	Suppression = "Suppression",
	AmmoSync = "AmmoSync",
	KillfeedUpdate = "KillfeedUpdate",
	MatchStateSync = "MatchStateSync",
	CastMapVote = "CastMapVote",
	RequestMapVoteStart = "RequestMapVoteStart",
	MapVoteSync = "MapVoteSync",
	ThrowGrenade = "ThrowGrenade",
	GrenadeReplicated = "GrenadeReplicated",
	GrenadeDetonated = "GrenadeDetonated",
	GrenadeSync = "GrenadeSync",
	FlashbangEffect = "FlashbangEffect",
}

NetworkTypes.RemoteDefinitions = {
	{ Name = "FireWeapon", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "ReloadWeapon", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "SwitchWeapon", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "SetFireMode", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "RequestSpawn", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "UpdatePosture", ClassName = "UnreliableRemoteEvent" :: RemoteClassName },
	{ Name = "BulletReplicated", ClassName = "UnreliableRemoteEvent" :: RemoteClassName },
	{ Name = "HitConfirm", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "DamageTaken", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "Suppression", ClassName = "UnreliableRemoteEvent" :: RemoteClassName },
	{ Name = "AmmoSync", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "KillfeedUpdate", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "MatchStateSync", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "CastMapVote", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "RequestMapVoteStart", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "MapVoteSync", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "ThrowGrenade", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "GrenadeReplicated", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "GrenadeDetonated", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "GrenadeSync", ClassName = "RemoteEvent" :: RemoteClassName },
	{ Name = "FlashbangEffect", ClassName = "RemoteEvent" :: RemoteClassName },
}

function NetworkTypes.IsFiniteNumber(value: unknown): boolean
	return typeof(value) == "number" and value == value and math.abs(value) ~= math.huge
end

function NetworkTypes.IsFiniteVector3(value: unknown): boolean
	if typeof(value) ~= "vector" and typeof(value) ~= "Vector3" then
		return false
	end
	local vec = value :: Vector3
	return NetworkTypes.IsFiniteNumber(vec.X)
		and NetworkTypes.IsFiniteNumber(vec.Y)
		and NetworkTypes.IsFiniteNumber(vec.Z)
end

function NetworkTypes.SanitizeUnitDirection(value: unknown): Vector3?
	if not NetworkTypes.IsFiniteVector3(value) then
		return nil
	end
	local vec = value :: Vector3
	local mag = vec.Magnitude
	if mag < 1e-4 or mag > 1e4 then
		return nil
	end
	return vec / mag
end

function NetworkTypes.GetRemotesFolder(timeoutSeconds: number?): Folder
	local waitTime = timeoutSeconds or 10
	local folder = ReplicatedStorage:WaitForChild(NetworkTypes.REMOTES_FOLDER_NAME, waitTime)
	assert(folder and folder:IsA("Folder"), "ReplicatedStorage.Remotes folder missing or invalid")
	return folder
end

function NetworkTypes.GetRemoteEvent(name: string, timeoutSeconds: number?): RemoteEvent
	local folder = NetworkTypes.GetRemotesFolder(timeoutSeconds)
	local remote = folder:WaitForChild(name, timeoutSeconds or 10)
	assert(remote and remote:IsA("RemoteEvent"), `RemoteEvent "{name}" missing`)
	return remote
end

function NetworkTypes.GetUnreliableRemoteEvent(name: string, timeoutSeconds: number?): UnreliableRemoteEvent
	local folder = NetworkTypes.GetRemotesFolder(timeoutSeconds)
	local remote = folder:WaitForChild(name, timeoutSeconds or 10)
	assert(remote and remote:IsA("UnreliableRemoteEvent"), `UnreliableRemoteEvent "{name}" missing`)
	return remote
end

return NetworkTypes
