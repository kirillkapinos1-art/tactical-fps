--!strict
-- Modular configuration for tactical grenades (Frag & Flashbang) and deterministic
-- shared trajectory/bounce simulation used identically by Server and Client.

local Workspace = game:GetService("Workspace")

export type GrenadeType = "Frag" | "Flash"

export type GrenadeDefinition = {
	Type: GrenadeType,
	DisplayName: string,
	ShortName: string,
	KeyHint: string,
	StartingCount: number,
	FuseTime: number,
	ThrowSpeed: number,
	UpwardBoost: number,
	GravityMultiplier: number,
	AirDrag: number,
	Restitution: number,
	SurfaceFriction: number,
	Radius: number,
	InnerRadius: number,
	OuterRadius: number,
	MaxDamage: number,
	MinDamage: number,
	SuppressionRadius: number,
	MaxBlindDuration: number,
	BodyColor: Color3,
	AccentColor: Color3,
	PinSoundId: string,
	BounceSoundId: string,
	DetonateSoundId: string,
}

local GrenadeConfig = {}

GrenadeConfig.GRAVITY = 196.2
GrenadeConfig.PREP_MIN_DURATION = 0.20
GrenadeConfig.POST_THROW_COOLDOWN = 0.45

GrenadeConfig.GrenadeOrder = {
	"Frag" :: GrenadeType,
	"Flash" :: GrenadeType,
}

GrenadeConfig.Grenades = {
	Frag = {
		Type = "Frag",
		DisplayName = "Осколочная граната (M67)",
		ShortName = "M67 Оскол.",
		KeyHint = "G",
		StartingCount = 2,
		FuseTime = 3.0,
		ThrowSpeed = 86,
		UpwardBoost = 16,
		GravityMultiplier = 0.85,
		AirDrag = 0.18,
		Restitution = 0.42,
		SurfaceFriction = 0.72,
		Radius = 0.42,
		InnerRadius = 9,
		OuterRadius = 34,
		MaxDamage = 115,
		MinDamage = 12,
		SuppressionRadius = 52,
		MaxBlindDuration = 0,
		BodyColor = Color3.fromRGB(68, 82, 54),
		AccentColor = Color3.fromRGB(196, 168, 72),
		PinSoundId = "rbxassetid://133384716023284",
		BounceSoundId = "rbxassetid://139719503904449",
		DetonateSoundId = "rbxassetid://138668273240081",
	},

	Flash = {
		Type = "Flash",
		DisplayName = "Светошумовая (M84)",
		ShortName = "M84 Флеш",
		KeyHint = "F",
		StartingCount = 2,
		FuseTime = 1.65,
		ThrowSpeed = 90,
		UpwardBoost = 15,
		GravityMultiplier = 0.85,
		AirDrag = 0.18,
		Restitution = 0.48,
		SurfaceFriction = 0.75,
		Radius = 0.40,
		InnerRadius = 18,
		OuterRadius = 78,
		MaxDamage = 0,
		MinDamage = 0,
		SuppressionRadius = 36,
		MaxBlindDuration = 4.6,
		BodyColor = Color3.fromRGB(48, 52, 58),
		AccentColor = Color3.fromRGB(115, 190, 238),
		PinSoundId = "rbxassetid://133384716023284",
		BounceSoundId = "rbxassetid://139719503904449",
		DetonateSoundId = "rbxassetid://114560494672327",
	},
} :: { [GrenadeType]: GrenadeDefinition }

function GrenadeConfig.GetGrenade(grenadeType: string): GrenadeDefinition?
	return (GrenadeConfig.Grenades :: { [string]: GrenadeDefinition })[grenadeType]
end

-- Advances a thrown grenade through up to 2 surface bounces per tick using raycast + radius clearance.
function GrenadeConfig.StepGrenadeMotion(
	position: Vector3,
	velocity: Vector3,
	dt: number,
	def: GrenadeDefinition,
	rayParams: RaycastParams
): (Vector3, Vector3, boolean)
	if dt <= 0 then
		return position, velocity, false
	end

	local clampedDt = math.min(dt, 0.1)
	local vel = velocity + Vector3.new(0, -GrenadeConfig.GRAVITY * def.GravityMultiplier * clampedDt, 0)
	vel *= math.exp(-def.AirDrag * clampedDt)

	local pos = position
	local didBounce = false
	local remainingRatio = 1.0

	for _bouncePass = 1, 2 do
		local stepVec = vel * (clampedDt * remainingRatio)
		local stepDist = stepVec.Magnitude
		if stepDist < 1e-4 then
			break
		end

		local stepDir = stepVec / stepDist
		local hit = Workspace:Raycast(pos, stepDir * (stepDist + def.Radius), rayParams)
		if not hit then
			pos += stepVec
			break
		end

		local n = hit.Normal
		local travelBeforeHit = math.max(0, hit.Distance - def.Radius)
		pos = hit.Position + n * (def.Radius + 0.02)

		local fracUsed = math.clamp(travelBeforeHit / math.max(stepDist, 1e-4), 0, 1)
		remainingRatio *= (1 - fracUsed)

		local vn = vel:Dot(n)
		if vn < 0 then
			local normalComp = n * vn
			local tangentComp = vel - normalComp
			vel = tangentComp * def.SurfaceFriction - normalComp * def.Restitution
			if n.Y > 0.65 and math.abs(vel.Y) < 3.2 and tangentComp.Magnitude < 2.2 then
				vel = Vector3.zero
				break
			end
			if stepDist > 0.04 then
				didBounce = true
			end
		else
			pos += stepDir * 0.03
		end

		if remainingRatio <= 0.02 then
			break
		end
	end

	return pos, vel, didBounce
end

return GrenadeConfig
