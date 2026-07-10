# atlas

**File:** `src/worker/locs/atlas.zig`  
**Module:** `worker/locs`  
**Description:** Geospatial location service: reverse geocoding, coordinate lookup, region detection, and location-based context enrichment for worker tasks.

---

## Purpose Summary

Geospatial location service: reverse geocoding, coordinate lookup, region detection, and location-based context enrichment for worker tasks.

## Key Exports

- `Atlas` struct — location service
- `reverse_geocode(lat, lng)` — address lookup
- `lookup_region(ip)` — IP geolocation
- `AtlasConfig` — provider and cache settings

## Dependencies

- `config/key_vault` — geolocation API keys
- `worker/commons` — shared types
- Standard library: http client, json

## Usage Context

Used by workers that need location context — crawling geo-targeted pages, location-aware tasks.

## Notable Implementation Details

Uses a local GeoIP database (MaxMind GeoLite2) for IP lookups with an external provider fallback for reverse geocoding. Results are cached.

---

*Documentation generated for nl-veil — atlas.zig source analysis.*
