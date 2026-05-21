# Build web-staff delta handoff (changes since handoff/web-staff-full).
# Run from repo root:
#   powershell -ExecutionPolicy Bypass -File handoff/build-web-staff-delta.ps1

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

$deltaDir = Join-Path $repoRoot "handoff\web-staff-delta-since-full"
$zipPath = Join-Path $repoRoot "handoff\web-staff-delta-since-full-handoff.zip"
$docsDir = Join-Path $PSScriptRoot "web-staff-delta-docs"
$readmeSrc = Join-Path $docsDir "README.md"
$changelogSrc = Join-Path $docsDir "CHANGELOG.md"

if (Test-Path $deltaDir) { Remove-Item -Recurse -Force $deltaDir }
New-Item -ItemType Directory -Force -Path "$deltaDir\backend\src" | Out-Null
New-Item -ItemType Directory -Force -Path "$deltaDir\backend\sql\migrations" | Out-Null
New-Item -ItemType Directory -Force -Path "$deltaDir\frontend\lib" | Out-Null

# --- Staff-variant index.ts (production minus theme/seating module routes) ---
$prodIndex = Join-Path $repoRoot "packages\backend\src\index.ts"
$indexText = Get-Content -Path $prodIndex -Raw -Encoding UTF8
$indexText = $indexText -replace 'import \{ normalizeSeatingPlan, registerEventDesignSeatingRoutes \} from "\./eventDesignSeating\.js";', 'import { normalizeSeatingPlan } from "./seatingPlanNormalize.js";'
$indexText = [regex]::Replace(
  $indexText,
  '(?s)app\.post\("/api/public/events/theme-design/theme-search".*?\}\);\r?\n\r?\napp\.get\("/api/mobile/inquiries"',
  'app.get("/api/mobile/inquiries"'
)
$indexText = [regex]::Replace(
  $indexText,
  '(?s)\r?\nregisterEventDesignSeatingRoutes\(app, \{.*?\}\);\r?\n\r?\nasync function main',
  "`nasync function main"
)
$staffIndexOut = Join-Path $deltaDir "backend\src\index.ts"
[System.IO.File]::WriteAllText($staffIndexOut, $indexText, [System.Text.UTF8Encoding]::new($false))

Copy-Item (Join-Path $repoRoot "packages\backend\src\db.ts") "$deltaDir\backend\src\db.ts"
Copy-Item (Join-Path $repoRoot "packages\frontend\lib\main.dart") "$deltaDir\frontend\lib\main.dart"
$mig = Join-Path $repoRoot "packages\backend\sql\migrations\20260520_catering_pipeline_status_check.sql"
if (Test-Path $mig) {
  Copy-Item $mig "$deltaDir\backend\sql\migrations\20260520_catering_pipeline_status_check.sql"
}

# Reference unchanged since full handoff
$exclSrc = Join-Path $repoRoot "packages\backend\src\eventDesignSeating.ts"
if (Test-Path $exclSrc) {
  New-Item -ItemType Directory -Force -Path "$deltaDir\backend\EXCLUDED" | Out-Null
  Copy-Item $exclSrc "$deltaDir\backend\EXCLUDED\eventDesignSeating.ts.reference"
}

if (Test-Path $readmeSrc) { Copy-Item $readmeSrc $deltaDir }
if (Test-Path $changelogSrc) { Copy-Item $changelogSrc $deltaDir }

Write-Host "Wrote delta package to $deltaDir"

if (Test-Path $zipPath) { Remove-Item -Force $zipPath }
Compress-Archive -Path (Join-Path $deltaDir "*") -DestinationPath $zipPath -Force
Write-Host "Created $zipPath"
