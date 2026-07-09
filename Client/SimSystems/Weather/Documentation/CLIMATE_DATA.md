# Alexandria Climate Reference Data

Source data for weather model parameterization. All values are historical averages unless otherwise noted.

## Sources

- **Temperature, precipitation, humidity, dew point**: Wikipedia / NOAA, El Nouzha Airport, 1991–2020 normals, extremes 1957–present
- **Atmospheric pressure**: timeanddate.com (1992–2021 averages), Mahfouz et al. 2020 (Western Harbor 2007–2018 study)
- **Wind**: Multiple academic studies (Eastern Harbour 2019–2020, Western Harbor 2007–2018, Windfinder observations 2009–2026)
- **Khamsin/dust**: El-Askary et al. (Chapman University), Wikipedia (Khamsin), MDPI satellite studies 2005–2019
- **Nile flood**: Wikipedia (Flooding of the Nile), waterhistory.org, ancient calendar sources

## Location

- Latitude: 31.20°N
- Longitude: 29.89°E
- Elevation: ~9 m above sea level
- Setting: Mediterranean coast, Nile delta, ancient Egyptian context

## Temperature

### Monthly averages (°C)

| Month | Record High | Mean Daily Max | Daily Mean | Mean Daily Min | Record Low |
|---|---|---|---|---|---|
| Jan | 29.6 | 18.4 | 14.0 | 9.5 | 0.0 |
| Feb | 33.0 | 19.0 | 14.4 | 9.7 | 1.2 |
| Mar | 40.0 | 21.1 | 16.4 | 11.8 | 2.3 |
| Apr | 40.8 | 24.1 | 19.0 | 14.3 | 3.6 |
| May | 45.0 | 26.9 | 22.2 | 17.8 | 8.5 |
| Jun | 43.9 | 29.1 | 25.2 | 21.7 | 11.6 |
| Jul | 40.7 | 30.5 | 27.1 | 23.9 | 17.0 |
| Aug | 39.8 | 31.0 | 27.8 | 24.4 | 17.8 |
| Sep | 39.0 | 30.2 | 26.4 | 22.5 | 14.0 |
| Oct | 38.3 | 27.8 | 23.6 | 19.3 | 10.7 |
| Nov | 35.7 | 24.0 | 19.6 | 15.1 | 4.6 |
| Dec | 31.0 | 20.1 | 15.6 | 11.1 | 1.2 |
| **Year** | **45.0** | **25.2** | **20.9** | **16.8** | **0.0** |

### Diurnal range (°C) — derived from max - min

| Month | Diurnal Range |
|---|---|
| Jan | 8.9 |
| Feb | 9.3 |
| Mar | 9.3 |
| Apr | 9.8 |
| May | 9.1 |
| Jun | 7.4 |
| Jul | 6.6 |
| Aug | 6.6 |
| Sep | 7.7 |
| Oct | 8.5 |
| Nov | 8.9 |
| Dec | 9.0 |

Note: Diurnal range is smallest in summer (6.6°C) due to maritime moderation during humid months, largest in spring (9.8°C). This is the opposite of desert interiors, where summer diurnal ranges are largest. The Mediterranean is the moderating influence.

### Temperature phase

Peak daily temperature typically occurs around 14:00 local time (standard for mid-latitude coastal locations). The `temp_phase` field should default to 14 for all states unless a specific state warrants a different peak time.

## Humidity

### Monthly average relative humidity (%)

| Month | Humidity |
|---|---|
| Jan | 69 |
| Feb | 67 |
| Mar | 67 |
| Apr | 65 |
| May | 66 |
| Jun | 68 |
| Jul | 71 |
| Aug | 71 |
| Sep | 67 |
| Oct | 68 |
| Nov | 68 |
| Dec | 68 |
| **Year** | **67.9** |

Note: Humidity is remarkably stable year-round (65-71%), reflecting the maritime influence. Highest in summer (Jul-Aug at 71%) due to warm air holding more moisture from the sea; lowest in spring (Apr at 65%).

### Dew point (°C)

| Month | Dew Point |
|---|---|
| Jan | 7.8 |
| Feb | 7.8 |
| Mar | 9.1 |
| Apr | 11.3 |
| May | 14.4 |
| Jun | 17.9 |
| Jul | 20.1 |
| Aug | 20.4 |
| Sep | 18.6 |
| Oct | 15.9 |
| Nov | 12.6 |
| Dec | 9.0 |
| **Year** | **13.7** |

## Atmospheric pressure

### Monthly average sea-level pressure (hPa / mbar)

| Month | Pressure |
|---|---|
| Jan | 1019 |
| Feb | 1018 |
| Mar | 1016 |
| Apr | 1014 |
| May | 1011 |
| Jun | 1010 |
| Jul | 1009 |
| Aug | 1009 |
| Sep | 1012 |
| Oct | 1015 |
| Nov | 1017 |
| Dec | 1019 |
| **Year** | **1014** |

Source: timeanddate.com 1992–2021 averages. Corroborated by Mahfouz et al. 2020 (Western Harbor study): monthly range 1005.9 hPa (July) to 1022.2 hPa (January), annual mean ~1013.5 hPa.

Note: Pressure is highest in winter (Jan-Dec at 1019) and lowest in summer (Jul-Aug at 1009). The 10 hPa seasonal swing is typical for Mediterranean climate. Pressure drops below ~1008 hPa are associated with storm systems and khamsin conditions.

## Wind

### Prevailing direction

**North-northwest (NNW)** — dominant across all seasons, ~42-43% occurrence.

Full directional distribution (annual):
| Direction | Occurrence % |
|---|---|
| N | 24.5% |
| NE | 6.6% |
| E | 4.1% |
| SE | 2.1% |
| S | 2.5% |
| SW | 4.0% |
| W | 12.9% |
| NW | 43.2% |

Note: N + NW + W = 80.6% — the wind overwhelmingly comes from the northern quadrant, blowing off the Mediterranean. This is the sea breeze / maritime influence that moderates Alexandria's climate relative to the desert interior.

### Wind speed

| Metric | Value |
|---|---|
| Annual average | ~4.1 m/s (8 kt, ~15 km/h) |
| Windiest month (Jul) | ~31 km/h avg (per timeanddate) |
| Calmest month (Aug) | ~5.3 kt avg (~10 km/h) |
| Winter max (Jan) | ~14.2 kt avg (~26 km/h) |
| Storm gusts | up to 25-34 kt (46-63 km/h) |

Seasonal pattern: wind speeds are higher in winter (Nov-Mar, 11-16 kt range) and lower in summer/autumn (Jun-Oct, 7-10 kt range). Khamsin events can bring gusts up to 140 km/h.

### Wind variability

The NNW dominance means wind direction is relatively stable. Variability is low for normal conditions (0.2-0.3 range). Khamsin conditions have high variability (0.6+) as direction shifts and gusts are erratic.

## Precipitation

### Monthly average rainfall (mm)

| Month | Rainfall (mm) | Rainy Days (≥1mm) |
|---|---|---|
| Jan | 61.4 | 8.2 |
| Feb | 35.2 | 5.4 |
| Mar | 12.8 | 2.8 |
| Apr | 2.6 | 1.2 |
| May | 1.0 | 1.4 |
| Jun | 0.0 | 0.5 |
| Jul | 0.0 | 0.4 |
| Aug | 0.0 | 0.4 |
| Sep | 0.8 | 0.2 |
| Oct | 8.3 | 1.2 |
| Nov | 36.8 | 3.5 |
| Dec | 52.7 | 5.9 |
| **Year** | **211.6** | **31.1** |

Note: Rainfall is concentrated in winter (Dec-Feb = 149.3 mm = 71% of annual total). Summer (Jun-Aug) is effectively rainless. Alexandria is one of the wettest places in Egypt, but "wet" here means ~200 mm/year — still arid by global standards. Violent storms with hail and sleet can occur in cooler months but are rare.

## Khamsin (dust storms)

### Characteristics

- **Season**: Primarily March–May, peak in April. Occasionally February–June.
- **Trigger**: Extratropical cyclones moving eastward along the southern Mediterranean / North African coast.
- **Duration**: Several hours per event. Events occur at intervals over ~50 days (hence "khamsin" = "fifty" in Arabic).
- **Wind speed**: Up to 140 km/h (87 mph, 76 kt)
- **Temperature effect**: Rise of up to 20°C in 2 hours. Even winter temperatures can exceed 45°C during a khamsin.
- **Humidity effect**: Drops below 5%
- **Dust**: Heavy Saharan dust transport. Aerosol optical thickness (AOD) reaches 2.0–4.0 during events (normal: <0.5). Visibility can drop to near-zero.
- **Direction**: Typically from S or SW (desert interior), shifting from the normal NNW pattern.
- **Frequency**: April has the highest frequency of dust event days — up to 52% of days in April during active years. Typical years see fewer.

### Pressure signature

Khamsin events are associated with sharp pressure drops as cyclones pass. Normal summer pressure is ~1009 hPa; a khamsin can drop pressure below 1005 hPa. The pressure gradient between the cyclone and the normal high-pressure system drives the strong winds.

For the simulation, a pressure threshold of ~1005-1008 hPa with a rapid downward trend would be a reasonable khamsin trigger. The grid can use the pressure trend (rate of change) rather than absolute value, since a rapid drop is more diagnostic than a low absolute value.

## Nile flood cycle

### Physical cycle (at the delta / Alexandria perspective)

The flood is driven by monsoon rainfall on the Ethiopian Highlands (May–August), with water arriving in the delta after a lag. The delta experiences the flood later than Upper Egypt (Aswan) by about 4–6 weeks.

| Phase | Approximate Timing (delta) | Description |
|---|---|---|
| **Low / baseflow** | March – early June | River at lowest, banks exposed, delta dry. Dust availability from exposed riverbed silt increases. |
| **Rising** | June – July | Flood arriving in delta, water level climbing, lowlands beginning to inundate. |
| **Peak inundation** | August – October | Floodplain underwater, maximum extent. High local humidity, morning fog, moderated temperatures. |
| **Receding** | November – February | Water draining back, silt deposits exposed, vegetation emerging. Still-high humidity but less fog. |

Note: At Aswan, the river begins rising in early June, rate of increase peaks mid-July, continues rising to early September, levels off ~3 weeks, often rises again to peak in October, then subsides to lowest in June. The delta lags by 4-6 weeks, so peak inundation in the delta is roughly August–October (the flood arrives later but the delta retains water longer due to flat topography).

### Day-of-year mapping for simulation

Using a simplified 360-day SL year (or mapping to real calendar):

| State | Day range (approx) | Notes |
|---|---|---|
| Low | 60 – 151 (Mar 1 – Jun 1) | River lowest, dry delta |
| Rising | 152 – 212 (Jun 1 – Jul 31) | Flood arriving |
| Peak | 213 – 304 (Aug 1 – Oct 31) | Maximum inundation |
| Receding | 305 – 59 (Nov 1 – Feb 28) | Water draining, silt exposed |

### Ancient Egyptian calendar correlation

The ancient calendar divided the year into three seasons of 120 days each:

| Season | Name | Meaning | Approximate timing |
|---|---|---|---|
| Akhet | Inundation | Flood | Sept – Jan (calendar) |
| Peret | Emergence | Growth | Jan – May |
| Shemu | Harvest | Low water | May – Sept |

Note: The ancient civil calendar drifted from the solar year (no leap years), so the calendar seasons don't perfectly align with the actual flood. The heliacal rising of Sirius (originally ~mid-July) was the astronomical marker for the flood's onset. For the simulation, we map flood states to the actual physical cycle, not the drifted calendar. The compound season headers in the notecard format (e.g., `Spring/Akhet`) acknowledge this misalignment — Mediterranean spring can overlap with late Akhet or early Peret depending on the calendar drift.

### Weather effects per flood state

| State | Humidity modifier | Fog/dust modifier | Temperature modifier | Notes |
|---|---|---|---|---|
| Low | base | +dust (exposed silt) | base | Dry, dusty riverbanks |
| Rising | +5-10% | base | -1 to -2°C | Increasing moisture, some fog |
| Peak | +15% | +fog probability | -2 to -3°C | High humidity, morning fog, moderated temps (water thermal mass) |
| Receding | +8% | base | -1°C | Still humid, less fog, exposed mud/vegetation |

These are the `flood_peak_*`, `flood_receding_*`, `flood_low_*` modifiers from the notecard format. Only applied to grids with `nile_adjacent = true`.

## Seasonal weather state suggestions

Based on the climate data, here are suggested weather states per season for an Alexandria oasis grid:

### Spring (Mar/Apr/May) — overlaps with late Akhet / early Peret

| State | temp_base | temp_diurnal | humidity | pressure | wind_speed | wind_dir | wind_var | precip | dust | visibility | weight | duration | event |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Clear Skies | 19 | 9 | 66 | 1014 | 15 | NW | 0.3 | 3 | 0 | 50 | 10 | 4-9 | |
| Light Rain | 16 | 7 | 72 | 1016 | 20 | NW | 0.4 | 15 | 0 | 20 | 4 | 3-6 | |
| Khamsin | 38 | 6 | 8 | 1006 | 80 | S | 0.7 | 0 | 85 | 3 | 2 | 6-24 | true |

### Summer (Jun/Jul/Aug) — overlaps with Shemu

| State | temp_base | temp_diurnal | humidity | pressure | wind_speed | wind_dir | wind_var | precip | dust | visibility | weight | duration | event |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Clear Skies | 27 | 7 | 70 | 1009 | 15 | NNW | 0.2 | 0 | 0 | 50 | 10 | 7-14 | |
| Hazy Heat | 30 | 5 | 75 | 1008 | 10 | NNW | 0.2 | 0 | 15 | 15 | 5 | 3-7 | |

### Autumn (Sep/Oct/Nov) — overlaps with early Akhet / late Shemu

| State | temp_base | temp_diurnal | humidity | pressure | wind_speed | wind_dir | wind_var | precip | dust | visibility | weight | duration | event |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Clear Skies | 24 | 8 | 67 | 1015 | 15 | NW | 0.3 | 5 | 0 | 50 | 8 | 5-10 | |
| Early Storms | 21 | 7 | 70 | 1017 | 25 | NW | 0.5 | 20 | 0 | 15 | 3 | 2-5 | |

### Winter (Dec/Jan/Feb) — overlaps with Peret

| State | temp_base | temp_diurnal | humidity | pressure | wind_speed | wind_dir | wind_var | precip | dust | visibility | weight | duration | event |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Clear Skies | 15 | 9 | 68 | 1019 | 20 | NW | 0.3 | 5 | 0 | 50 | 8 | 4-8 | |
| Rainy | 12 | 6 | 75 | 1018 | 25 | W | 0.4 | 30 | 0 | 10 | 5 | 3-6 | |
| Storm | 11 | 5 | 78 | 1016 | 40 | W | 0.6 | 50 | 0 | 5 | 2 | 2-4 | true |

Note: Storm is flagged as `event = true` because while winter storms are not as dramatic as a khamsin, they are the most intense weather Alexandria experiences in winter and can bring hail, sleet, and flooding. Weight is low (2) reflecting rarity.

## Notes for notecard authoring

1. **temp_base** values above are daily means (the "Daily Mean" column from the climate table), not midday highs. The evolution model adds diurnal amplitude on top: `temp = temp_base + temp_diurnal * sin(sun_angle - phase_offset)`.

2. **temp_diurnal** is half the diurnal range (max - min) / 2, since the sin function swings both above and below the base. The values in the seasonal table above are already halved.

3. **pressure** values are the monthly averages. The evolution model should add stochastic variation around these. A rapid drop of >5 hPa from the seasonal norm is a khamsin signal.

4. **wind_dir** uses cardinal directions. NNW and NW are the dominant directions. Khamsin shifts this to S or SW.

5. **dust** is 0-100 scale. Normal conditions: 0. Khamsin: 80-85. Hazy heat (summer humidity + dust): 15.

6. **visibility** is in km. Normal: 50 (effectively unlimited for sim purposes). Rain: 10-20. Khamsin: 3 or less.

7. **flood modifiers** should be added to the Spring and Autumn states (which overlap with Akhet/Peret), since those are the seasons when the flood is active. Summer (Shemu) is low-flood season; winter (Peret) is receding season.

8. **weight** values are relative and approximate. The grid's transition logic should adjust these based on computed pressure trends and seasonal context, not rely on them as fixed probabilities.
