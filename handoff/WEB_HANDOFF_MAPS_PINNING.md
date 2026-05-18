# Maps, pinning & venue autocomplete — Web repository handoff

**Important:** The mobile app does **not** use `google_maps_flutter` or a Google Maps API key for in-app maps.

| Concern | Technology |
|---------|------------|
| In-app map tiles | **OpenStreetMap** via `flutter_map` (mobile) / **Leaflet** (web, below) |
| Search, geocode, reverse geocode | **Nominatim** (HTTPS, requires `User-Agent`) |
| “Open in Google Maps” | **External URL** only (`url_launcher` / `window.open`) — no SDK |
| Saved coordinates | **Profile API** (`delivery_lat`, `delivery_lng`) for registered customers |
| Event venue | **Address text only** on server (`event_city` / `address`); pin is client-side for inquiry/manager forms |

Source of truth: **`packages/frontend/lib/main.dart`** lines **672–820**, **1541–1608**, **10466–10889**, venue autocomplete **11169–11216** (and manager variants ~14300+, ~16743+).

---

## 1. Web `package.json` dependencies

```json
{
  "dependencies": {
    "leaflet": "^1.9.4",
    "react": "^18.0.0",
    "react-dom": "^18.0.0",
    "react-leaflet": "^4.2.1"
  },
  "devDependencies": {
    "@types/leaflet": "^1.9.12"
  }
}
```

**Flutter mobile (reference):** `flutter_map`, `latlong2`, `geolocator`, `http`, `url_launcher` — see `packages/frontend/pubspec.yaml`.

**No Google Maps JavaScript API key** is required unless you choose to replace Nominatim/Leaflet with Google Maps Platform (Places + Maps JS).

### CSS (Next.js / Vite)

```css
@import "leaflet/dist/leaflet.css";
```

### Nominatim policy

- Set a real **`User-Agent`** (app name + contact email).
- Max ~1 request/second; debounce autocomplete (300ms).
- Docs: https://operations.osmfoundation.org/policies/nominatim/

---

## 2. Constants (from mobile)

```typescript
// packages/frontend/lib/main.dart ~672-757
export const NOMINATIM_USER_AGENT = "CurateringWeb/1.0 (support@macrina.local)";

/** Restaurant anchor — Taguig (delivery radius). */
export const RESTAURANT_LAT = 14.513436;
export const RESTAURANT_LNG = 121.059198;
export const DELIVERY_MAX_DISTANCE_KM = 5;

export const CATERING_ALLOWED_REGIONS = [
  "ncr",
  "national capital region",
  "metro manila",
  "bulacan",
  "cavite",
  "rizal",
  "laguna",
];

export const DEFAULT_MAP_CENTER = { lat: 14.5995, lng: 120.9842 }; // Manila fallback
```

---

## 3. Core geospatial module (save as `src/lib/geo.ts`)

```typescript
export const NOMINATIM_USER_AGENT = "CurateringWeb/1.0 (support@macrina.local)";
export const RESTAURANT_LAT = 14.513436;
export const RESTAURANT_LNG = 121.059198;
export const DELIVERY_MAX_DISTANCE_KM = 5;

export type LatLng = { lat: number; lng: number };

export function haversineKm(a: LatLng, b: LatLng): number {
  const R = 6371;
  const dLat = ((b.lat - a.lat) * Math.PI) / 180;
  const dLng = ((b.lng - a.lng) * Math.PI) / 180;
  const lat1 = (a.lat * Math.PI) / 180;
  const lat2 = (b.lat * Math.PI) / 180;
  const x =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2;
  return R * 2 * Math.atan2(Math.sqrt(x), Math.sqrt(1 - x));
}

export function isWithinDeliveryRadius(pin: LatLng): boolean {
  return (
    haversineKm({ lat: RESTAURANT_LAT, lng: RESTAURANT_LNG }, pin) <=
    DELIVERY_MAX_DISTANCE_KM
  );
}

export function isAllowedCateringAddress(address: string): boolean {
  const t = address.trim().toLowerCase();
  if (!t) return false;
  const hasRegion = [
    "ncr",
    "national capital region",
    "metro manila",
    "bulacan",
    "cavite",
    "rizal",
    "laguna",
  ].some((p) => t.includes(p));
  return hasRegion;
}

export const cateringCoverageError =
  "Service area is limited to NCR, Bulacan, Cavite, Rizal, and Laguna (Philippines).";

async function nominatimGet(url: string): Promise<unknown> {
  const res = await fetch(url, {
    headers: { "User-Agent": NOMINATIM_USER_AGENT },
  });
  if (!res.ok) throw new Error(`Nominatim HTTP ${res.status}`);
  return res.json();
}

/** Forward geocode — first result. */
export async function geocodeAddress(query: string): Promise<LatLng | null> {
  const q = query.trim();
  if (!q) return null;
  const url = `https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(q)}&format=json&limit=1`;
  const list = (await nominatimGet(url)) as Array<{ lat?: string; lon?: string }>;
  if (!list?.length) return null;
  const lat = parseFloat(list[0].lat ?? "");
  const lng = parseFloat(list[0].lon ?? "");
  if (!Number.isFinite(lat) || !Number.isFinite(lng)) return null;
  return { lat, lng };
}

/** Autocomplete — up to 5 display names. */
export async function searchAddresses(query: string, limit = 5): Promise<string[]> {
  const q = query.trim();
  if (q.length < 3) return [];
  const url = `https://nominatim.openstreetmap.org/search?q=${encodeURIComponent(q)}&format=json&limit=${limit}`;
  const list = (await nominatimGet(url)) as Array<{ display_name?: string }>;
  return list
    .map((e) => (e.display_name ?? "").trim())
    .filter(Boolean)
    .slice(0, limit);
}

/** Reverse geocode — display address for pin. */
export async function reverseGeocode(pin: LatLng): Promise<string> {
  const url = `https://nominatim.openstreetmap.org/reverse?lat=${pin.lat}&lon=${pin.lng}&format=json`;
  try {
    const body = (await nominatimGet(url)) as { display_name?: string };
    const name = (body.display_name ?? "").trim();
    if (name) return name;
  } catch {
    /* fall through */
  }
  return `${pin.lat.toFixed(6)}, ${pin.lng.toFixed(6)}`;
}

export async function geocodeDistanceKmFromRestaurant(address: string): Promise<number | null> {
  const pin = await geocodeAddress(address);
  if (!pin) return null;
  return haversineKm({ lat: RESTAURANT_LAT, lng: RESTAURANT_LNG }, pin);
}

/** Open external Google Maps (no API key). */
export function openGoogleMaps(address: string, pin?: LatLng): boolean {
  const q = address.trim();
  if (!q) return false;
  const encoded = encodeURIComponent(q);
  const urls = [
    pin ? `https://www.google.com/maps/search/?api=1&query=${pin.lat},${pin.lng}` : null,
    `https://www.google.com/maps/search/?api=1&query=${encoded}`,
    `https://maps.google.com/maps?q=${encoded}`,
  ].filter(Boolean) as string[];
  for (const href of urls) {
    const w = window.open(href, "_blank", "noopener,noreferrer");
    if (w) return true;
  }
  return false;
}
```

---

## 4. Profile API (persist delivery pin)

| Method | Path | Fields |
|--------|------|--------|
| GET | `/api/mobile/profile?user_email=` | `delivery_address`, `delivery_map_confirmed`, `delivery_lat`, `delivery_lng`, `delivery_addresses[]` |
| PUT | `/api/mobile/profile` | Same in JSON body |

```typescript
// src/lib/profileApi.ts
const API_BASE = process.env.NEXT_PUBLIC_API_BASE!.replace(/\/+$/, "");

export type Profile = {
  user_email: string;
  full_name: string;
  contact_number: string;
  delivery_address: string;
  delivery_map_confirmed: boolean;
  delivery_lat: number | null;
  delivery_lng: number | null;
  delivery_addresses: string[];
};

export async function loadProfile(userEmail: string): Promise<Profile> {
  const res = await fetch(
    `${API_BASE}/api/mobile/profile?user_email=${encodeURIComponent(userEmail)}`,
  );
  if (!res.ok) throw new Error("Could not load profile");
  return res.json();
}

export async function saveProfile(
  userEmail: string,
  data: Pick<
    Profile,
    | "full_name"
    | "contact_number"
    | "delivery_address"
    | "delivery_map_confirmed"
    | "delivery_lat"
    | "delivery_lng"
    | "delivery_addresses"
  >,
): Promise<void> {
  const res = await fetch(`${API_BASE}/api/mobile/profile`, {
    method: "PUT",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ user_email: userEmail, ...data }),
  });
  if (!res.ok) throw new Error("Could not save profile");
}
```

**Guest checkout:** mobile keeps lat/lng in memory and validates 5 km before submit; restaurant `POST /api/mobile/orders` sends **address text only** (no lat/lng on server).

**Catering inquiry / manager event:** venue is `event_city` / `address` string; coordinates are **not** stored server-side.

---

## 5. React map pin picker (save as `src/components/MapPinPicker.tsx`)

Uses **react-leaflet** + OSM tiles (same as mobile `FlutterMap` + `tile.openstreetmap.org`).

```tsx
"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { MapContainer, Marker, TileLayer, useMapEvents } from "react-leaflet";
import L from "leaflet";
import "leaflet/dist/leaflet.css";
import {
  DEFAULT_MAP_CENTER,
  geocodeAddress,
  DELIVERY_MAX_DISTANCE_KM,
  isWithinDeliveryRadius,
  reverseGeocode,
  searchAddresses,
  type LatLng,
} from "@/lib/geo";

// Fix default marker icon paths in bundlers
import iconUrl from "leaflet/dist/images/marker-icon.png";
import iconRetinaUrl from "leaflet/dist/images/marker-icon-2x.png";
import shadowUrl from "leaflet/dist/images/marker-shadow.png";

const defaultIcon = L.icon({
  iconUrl: iconUrl.src ?? iconUrl,
  iconRetinaUrl: iconRetinaUrl.src ?? iconRetinaUrl,
  shadowUrl: shadowUrl.src ?? shadowUrl,
  iconSize: [25, 41],
  iconAnchor: [12, 41],
});
L.Marker.prototype.options.icon = defaultIcon;

export type MapPinResult = { address: string; lat: number; lng: number };

type Props = {
  initialQuery?: string;
  initialPin?: LatLng;
  /** If true, block confirm when outside 5 km (delivery profile / checkout). */
  enforceDeliveryRadius?: boolean;
  onConfirm: (result: MapPinResult) => void;
  onCancel: () => void;
};

function MapClickHandler({ onPick }: { onPick: (p: LatLng) => void }) {
  useMapEvents({
    click(e) {
      onPick({ lat: e.latlng.lat, lng: e.latlng.lng });
    },
  });
  return null;
}

export function MapPinPicker({
  initialQuery = "",
  initialPin,
  enforceDeliveryRadius = false,
  onConfirm,
  onCancel,
}: Props) {
  const [query, setQuery] = useState(initialQuery);
  const [pin, setPin] = useState<LatLng>(initialPin ?? DEFAULT_MAP_CENTER);
  const [address, setAddress] = useState("");
  const [suggestions, setSuggestions] = useState<string[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const refreshAddress = useCallback(async (p: LatLng) => {
    setBusy(true);
    try {
      setAddress(await reverseGeocode(p));
    } finally {
      setBusy(false);
    }
  }, []);

  useEffect(() => {
    void (async () => {
      if (initialQuery.trim()) {
        const g = await geocodeAddress(initialQuery);
        if (g) {
          setPin(g);
          await refreshAddress(g);
          return;
        }
      }
      if (initialPin) await refreshAddress(initialPin);
    })();
  }, [initialQuery, initialPin, refreshAddress]);

  useEffect(() => {
    const t = setTimeout(async () => {
      if (query.trim().length < 3) {
        setSuggestions([]);
        return;
      }
      setSuggestions(await searchAddresses(query));
    }, 300);
    return () => clearTimeout(t);
  }, [query]);

  const onPick = async (p: LatLng) => {
    setPin(p);
    setError(null);
    await refreshAddress(p);
  };

  const useGps = () => {
    if (!navigator.geolocation) {
      setError("GPS not available in this browser.");
      return;
    }
    navigator.geolocation.getCurrentPosition(
      async (pos) => {
        await onPick({ lat: pos.coords.latitude, lng: pos.coords.longitude });
      },
      () => setError("Location permission denied."),
      { enableHighAccuracy: true },
    );
  };

  const confirm = () => {
    if (enforceDeliveryRadius && !isWithinDeliveryRadius(pin)) {
      setError(`Delivery must be within ${DELIVERY_MAX_DISTANCE_KM} km of our restaurant.`);
      return;
    }
    onConfirm({
      address: address || `${pin.lat.toFixed(6)}, ${pin.lng.toFixed(6)}`,
      lat: pin.lat,
      lng: pin.lng,
    });
  };

  const center = useMemo(() => [pin.lat, pin.lng] as [number, number], [pin.lat, pin.lng]);

  return (
    <div className="map-pin-picker">
      <p>Tap the map to set the pin. Address updates via OpenStreetMap.</p>
      <input
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder="Search place or address"
        list="venue-suggestions"
      />
      <datalist id="venue-suggestions">
        {suggestions.map((s) => (
          <option key={s} value={s} />
        ))}
      </datalist>
      <button type="button" onClick={useGps}>
        Use my location (GPS)
      </button>
      <MapContainer center={center} zoom={16} style={{ height: 280, width: "100%" }}>
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          url="https://tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        <MapClickHandler onPick={onPick} />
        <Marker position={center} />
      </MapContainer>
      <p>
        <strong>{busy ? "Resolving…" : address || "—"}</strong>
      </p>
      <p>
        {pin.lat.toFixed(6)}, {pin.lng.toFixed(6)}
      </p>
      {error && <p className="error">{error}</p>}
      <button type="button" onClick={onCancel}>
        Cancel
      </button>
      <button type="button" onClick={confirm} disabled={busy}>
        Use this location
      </button>
    </div>
  );
}
```

Root element is a plain `<div>` wrapper.

---

## 6. Venue autocomplete hook (event inquiry / manager)

Port of `InquiryScreen._onVenueChanged` (`main.dart` ~11169–11203):

```typescript
import { useEffect, useState } from "react";
import { searchAddresses } from "@/lib/geo";

export function useVenueSuggestions(
  query: string,
  savedAddresses: string[] = [],
  debounceMs = 300,
) {
  const [suggestions, setSuggestions] = useState<string[]>([]);

  useEffect(() => {
    const q = query.trim();
    if (q.length < 3) {
      setSuggestions([]);
      return;
    }
    const t = setTimeout(async () => {
      const local = savedAddresses
        .filter((a) => a.toLowerCase().includes(q.toLowerCase()))
        .slice(0, 5);
      const remote = await searchAddresses(q, 5);
      const merged = [...new Set([...local, ...remote])].slice(0, 8);
      setSuggestions(merged);
    }, debounceMs);
    return () => clearTimeout(t);
  }, [query, savedAddresses, debounceMs]);

  return suggestions;
}
```

Event venue pin (address only on submit):

```typescript
// After MapPinPicker confirms:
setEventCity(result.address);
// Submit inquiry with event_city / address — no lat/lng field on API
```

---

## 7. Read-only venue preview + “Open in Google Maps”

Mobile: `_EventVenueMapPreviewDialog` (`main.dart` ~10473–10598) + `openGoogleMapsForAddress` (~1541–1565).

```tsx
"use client";

import { useEffect, useState } from "react";
import { MapContainer, Marker, TileLayer } from "react-leaflet";
import { DEFAULT_MAP_CENTER, geocodeAddress, openGoogleMaps, type LatLng } from "@/lib/geo";

export function EventVenueMapPreview({ address }: { address: string }) {
  const [pin, setPin] = useState<LatLng>(DEFAULT_MAP_CENTER);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    void (async () => {
      const g = await geocodeAddress(address);
      if (g) setPin(g);
      else setError("Could not find this address on the map.");
    })();
  }, [address]);

  return (
    <div>
      <p>{address}</p>
      {error ? (
        <p>{error}</p>
      ) : (
        <MapContainer center={[pin.lat, pin.lng]} zoom={16} style={{ height: 260, width: "100%" }}>
          <TileLayer url="https://tile.openstreetmap.org/{z}/{x}/{y}.png" />
          <Marker position={[pin.lat, pin.lng]} />
        </MapContainer>
      )}
      <button type="button" onClick={() => openGoogleMaps(address, pin)}>
        Open in Google Maps
      </button>
    </div>
  );
}
```

---

## 8. Flutter source reference (mobile — copy from repo)

### Imports (`main.dart` top)

```dart
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:url_launcher/url_launcher.dart';
```

### Key symbols & line ranges

| Lines | Symbol |
|-------|--------|
| 672–673 | `kNominatimUserAgent` |
| 755–820 | Restaurant lat/lng, `haversineKm`, `geocodeAddressDistanceKmFromRestaurant`, catering region check |
| 1541–1565 | `openGoogleMapsForAddress` |
| 1569–1608 | `buildEventVenueAddressLink`, `showEventVenueMapPreview` |
| 10466–10471 | `MapPinResult` |
| 10473–10598 | `_EventVenueMapPreviewDialog` |
| 10600–10889 | `_MapPinPickerDialog` (delivery + event venue pin) |
| 11169–11216 | `InquiryScreen` venue autocomplete + `_pickVenueOnMap` |
| 3218–3321 | `loadProfile` / `saveProfile` (delivery lat/lng) |
| 9940+ | `MyProfileScreen` — profile map pin |
| 7633+ | `CheckoutScreen` — guest delivery pin + 5 km check |

### Android / iOS (mobile only)

- `android/app/src/main/AndroidManifest.xml` — location permissions; intent queries for `geo`, Google Maps.
- `ios/Runner/Info.plist` — `NSLocationWhenInUseUsageDescription`.

---

## 9. Optional: Google Maps Platform (web-only upgrade)

If the **web** repo must use Google Maps instead of Leaflet:

1. Enable **Maps JavaScript API** + **Places API** in Google Cloud Console.
2. `NEXT_PUBLIC_GOOGLE_MAPS_API_KEY=...`
3. Replace Nominatim autocomplete with Places Autocomplete; replace Leaflet with `@react-google-maps/api`.
4. Keep the same **profile PUT** fields (`delivery_lat`, `delivery_lng`).

Mobile can stay on OSM/Nominatim unless you align both clients.

---

## 10. Backend (no map proxy)

The backend does **not** geocode. Relevant endpoints:

- `GET/PUT /api/mobile/profile` — delivery pin persistence (`packages/backend/src/index.ts` ~2503+)
- `POST /api/mobile/inquiries` — `event_city` string
- Manager catering draft APIs — `address` field

DB columns (via `schemaNormalize.ts`): `customer_accounts.delivery_lat`, `delivery_lng`, `delivery_map_confirmed`.

---

## 11. Usage checklist for web

1. Add `geo.ts` + `profileApi.ts` + `MapPinPicker.tsx`.
2. Import Leaflet CSS globally.
3. Debounce Nominatim; set `User-Agent`.
4. Profile page: save pin via `PUT /api/mobile/profile`.
5. Checkout: enforce `isWithinDeliveryRadius` before order submit.
6. Catering inquiry / manager venue: autocomplete + optional pin → save **address text only**.
7. “Open in Google Maps” for read-only venue links in admin/manager views.
