--!strict
-- Modular catalog of tactical FFA maps and their per-map Lighting/Atmosphere presets.

export type MapLightingPreset = {
	ClockTime: number,
	Brightness: number,
	ShadowSoftness: number,
	Ambient: Color3,
	OutdoorAmbient: Color3,
	ExposureCompensation: number,
	AtmosphereDensity: number,
	AtmosphereOffset: number,
	AtmosphereColor: Color3,
	AtmosphereDecay: Color3,
	AtmosphereGlare: number,
	AtmosphereHaze: number,
	ColorCorrectionBrightness: number,
	ColorCorrectionContrast: number,
	ColorCorrectionSaturation: number,
	ColorCorrectionTint: Color3,
}

export type MapDefinition = {
	Id: string,
	DisplayName: string,
	Tagline: string,
	Description: string,
	RecommendedRange: string,
	ArenaSize: string,
	AccentColor: Color3,
	Lighting: MapLightingPreset,
}

local MapConfig = {}

MapConfig.DEFAULT_MAP_ID = "ProvingGround"

MapConfig.MapOrder = {
	"ProvingGround",
	"WarehouseCQB",
	"DesertOutpost",
	"CargoDocks",
}

MapConfig.Maps = {
	ProvingGround = {
		Id = "ProvingGround",
		DisplayName = "Полигон ОС-01",
		Tagline = "БАЛАНС  //  ПРОМЗОНА",
		Description = "Классический учебный полигон: центральный мост, домики из гипсокартона под прострел (wallbang) и бетонные бункеры.",
		RecommendedRange = "25–130 м",
		ArenaSize = "220 x 220",
		AccentColor = Color3.fromRGB(118, 166, 92),
		Lighting = {
			ClockTime = 16.4,
			Brightness = 2.4,
			ShadowSoftness = 0.25,
			Ambient = Color3.fromRGB(48, 52, 60),
			OutdoorAmbient = Color3.fromRGB(92, 98, 110),
			ExposureCompensation = 0.1,
			AtmosphereDensity = 0.34,
			AtmosphereOffset = 0.2,
			AtmosphereColor = Color3.fromRGB(198, 206, 218),
			AtmosphereDecay = Color3.fromRGB(96, 108, 128),
			AtmosphereGlare = 0.25,
			AtmosphereHaze = 1.6,
			ColorCorrectionBrightness = -0.02,
			ColorCorrectionContrast = 0.14,
			ColorCorrectionSaturation = -0.18,
			ColorCorrectionTint = Color3.fromRGB(246, 248, 255),
		},
	},

	WarehouseCQB = {
		Id = "WarehouseCQB",
		DisplayName = "Склад «Север»",
		Tagline = "НОЧНОЙ CQB  //  АНГАР",
		Description = "Тесный логистический комплекс с прожекторами, 2-этажной диспетчерской, стеллажами из простреливаемой фанеры и погрузочной рампой.",
		RecommendedRange = "5–45 м",
		ArenaSize = "180 x 180",
		AccentColor = Color3.fromRGB(214, 154, 72),
		Lighting = {
			ClockTime = 20.6,
			Brightness = 1.6,
			ShadowSoftness = 0.32,
			Ambient = Color3.fromRGB(42, 46, 56),
			OutdoorAmbient = Color3.fromRGB(64, 74, 92),
			ExposureCompensation = 0.18,
			AtmosphereDensity = 0.38,
			AtmosphereOffset = 0.15,
			AtmosphereColor = Color3.fromRGB(115, 132, 162),
			AtmosphereDecay = Color3.fromRGB(46, 56, 78),
			AtmosphereGlare = 0.08,
			AtmosphereHaze = 2.1,
			ColorCorrectionBrightness = -0.01,
			ColorCorrectionContrast = 0.16,
			ColorCorrectionSaturation = -0.15,
			ColorCorrectionTint = Color3.fromRGB(238, 242, 255),
		},
	},

	DesertOutpost = {
		Id = "DesertOutpost",
		DisplayName = "Блокпост «Каньон»",
		Tagline = "ДАЛЬНИЙ БОЙ  //  ПУСТЫНЯ",
		Description = "Укреплённый пустынный аванпост среди скал: две высокие снайперские вышки, центральный блокпост и глинобитные укрытия.",
		RecommendedRange = "50–210 м",
		ArenaSize = "260 x 260",
		AccentColor = Color3.fromRGB(210, 134, 74),
		Lighting = {
			ClockTime = 17.5,
			Brightness = 3.0,
			ShadowSoftness = 0.18,
			Ambient = Color3.fromRGB(72, 60, 48),
			OutdoorAmbient = Color3.fromRGB(132, 110, 86),
			ExposureCompensation = 0.05,
			AtmosphereDensity = 0.30,
			AtmosphereOffset = 0.25,
			AtmosphereColor = Color3.fromRGB(235, 198, 152),
			AtmosphereDecay = Color3.fromRGB(168, 118, 76),
			AtmosphereGlare = 0.45,
			AtmosphereHaze = 2.2,
			ColorCorrectionBrightness = -0.02,
			ColorCorrectionContrast = 0.16,
			ColorCorrectionSaturation = -0.10,
			ColorCorrectionTint = Color3.fromRGB(255, 246, 234),
		},
	},

	CargoDocks = {
		Id = "CargoDocks",
		DisplayName = "Доки «Атлантик»",
		Tagline = "РАССВЕТ  //  ПОРТ",
		Description = "Туманный грузовой терминал: двухъярусные морские контейнеры, сквозные проходы, таможенные КПП со стеклом и портовая эстакада.",
		RecommendedRange = "15–95 м",
		ArenaSize = "240 x 240",
		AccentColor = Color3.fromRGB(92, 168, 206),
		Lighting = {
			ClockTime = 6.3,
			Brightness = 2.1,
			ShadowSoftness = 0.28,
			Ambient = Color3.fromRGB(52, 60, 72),
			OutdoorAmbient = Color3.fromRGB(96, 112, 132),
			ExposureCompensation = 0.12,
			AtmosphereDensity = 0.42,
			AtmosphereOffset = 0.18,
			AtmosphereColor = Color3.fromRGB(182, 204, 224),
			AtmosphereDecay = Color3.fromRGB(88, 108, 136),
			AtmosphereGlare = 0.32,
			AtmosphereHaze = 2.5,
			ColorCorrectionBrightness = -0.02,
			ColorCorrectionContrast = 0.14,
			ColorCorrectionSaturation = -0.16,
			ColorCorrectionTint = Color3.fromRGB(240, 248, 255),
		},
	},
} :: { [string]: MapDefinition }

function MapConfig.GetMap(mapId: string): MapDefinition?
	return MapConfig.Maps[mapId]
end

function MapConfig.GetAllMaps(): { MapDefinition }
	local list: { MapDefinition } = {}
	for _, mapId in ipairs(MapConfig.MapOrder) do
		local def = MapConfig.Maps[mapId]
		if def then
			table.insert(list, def)
		end
	end
	return list
end

return MapConfig
