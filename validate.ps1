param([string]$UpstreamPath)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repoPath = $PSScriptRoot
$checkCount = 0
function Assert-Template([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
    $script:checkCount++
}
function Read-Json([string]$Name) {
    return (Get-Content -LiteralPath (Join-Path $repoPath $Name) -Raw | ConvertFrom-Json)
}
$expectedFiles = @('manifest.json', 'call-of-duty2.kvp', 'call-of-duty2config.json',
    'call-of-duty2metaconfig.json', 'call-of-duty2ports.json', 'call-of-duty2updates.json',
    'README.md', 'validate.ps1')
$files = @(Get-ChildItem -LiteralPath $repoPath -File -Force)
Assert-Template ($files.Count -eq $expectedFiles.Count) 'Unexpected or missing repository files.'
foreach ($name in $expectedFiles) {
    Assert-Template (Test-Path -LiteralPath (Join-Path $repoPath $name) -PathType Leaf) "Missing file: $name"
}
$extraDirectories = @(Get-ChildItem -LiteralPath $repoPath -Directory -Force | Where-Object Name -ne '.git')
Assert-Template ($extraDirectories.Count -eq 0) 'AMP template files must be in the repository root.'
foreach ($file in $files | Where-Object Extension -eq '.json') {
    $null = Read-Json $file.Name
    Assert-Template $true "JSON parse: $($file.Name)"
}
$kvp = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $repoPath 'call-of-duty2.kvp')) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    Assert-Template ($line -match '^(Meta|App|Console|Limits)\.[A-Za-z0-9]+=(.*)$') "Invalid KVP line: $line"
    $parts = $line -split '=', 2
    Assert-Template (-not $kvp.ContainsKey($parts[0])) "Duplicate KVP key: $($parts[0])"
    $kvp[$parts[0]] = $parts[1]
}
$required = @('Meta.DisplayName', 'Meta.Description', 'Meta.OS', 'Meta.Arch', 'Meta.Author',
    'Meta.URL', 'Meta.ConfigRoot', 'Meta.ConfigManifest', 'Meta.MetaConfigManifest',
    'Meta.MinAMPVersion', 'Meta.AppConfigId', 'App.RootDir', 'App.BaseDirectory',
    'App.ExecutableWin', 'App.WorkingDir', 'App.CommandLineArgs', 'App.Ports', 'App.UpdateSources')
foreach ($key in $required) {
    Assert-Template ($kvp.ContainsKey($key) -and $kvp[$key] -ne '') "Missing metadata/configuration: $key"
}
$manifest = Read-Json 'manifest.json'
Assert-Template ($manifest.repotype -ceq 'AppTemplates') 'Wrong repository type.'
Assert-Template ($manifest.origin -ceq 'https://github.com/goashu/lancon-amp-templates.git') 'Wrong origin.'
Assert-Template ($manifest.url -ceq 'https://github.com/goashu/lancon-amp-templates') 'Wrong repository URL.'
Assert-Template ($manifest.prefix -ceq 'LANCON') 'Wrong display prefix.'
Assert-Template (@($manifest.authors).Count -gt 0) 'Missing authors.'
$null = [guid]::Parse($manifest.id)
$null = [guid]::Parse($kvp['Meta.AppConfigId'])
Assert-Template ($manifest.id -ne $kvp['Meta.AppConfigId']) 'Repository ID and application ID must differ.'
Assert-Template ($kvp['Meta.ConfigRoot'] -ceq 'call-of-duty2.kvp') 'Wrong ConfigRoot.'
foreach ($key in @('Meta.ConfigRoot', 'Meta.ConfigManifest', 'Meta.MetaConfigManifest')) {
    Assert-Template ($files.Name -ccontains $kvp[$key]) "Missing/case-mismatched reference: $key"
}
foreach ($value in $kvp.Values) {
    if ($value -match '^@IncludeJson\[(.+)\]$') {
        Assert-Template ($files.Name -ccontains $Matches[1]) "Missing include: $($Matches[1])"
    }
}
foreach ($key in @('App.AppSettings', 'App.EnvironmentVariables', 'App.PreStartStages',
    'Meta.Prerequisites', 'Meta.ExtraContainerPackages', 'Console.UserActions')) {
    $null = $kvp[$key] | ConvertFrom-Json
    Assert-Template $true "Embedded JSON: $key"
}
Assert-Template ($kvp['Meta.OS'] -ceq 'Windows') 'Only Windows is supported.'
Assert-Template ($kvp['Meta.Arch'] -ceq 'x86_64') 'Target a Windows x64 host.'
Assert-Template ([version]$kvp['Meta.MinAMPVersion'] -le [version]'2.8.0.8') 'Target AMP version excluded.'
Assert-Template ($kvp['App.ExecutableWin'] -ceq 'CoD2MP_s.exe') 'Wrong Windows executable.'
Assert-Template ($kvp['App.ExecutableLinux'] -eq '') 'Unexpected Linux executable.'
Assert-Template ($kvp['App.RootDir'] -ceq './call-of-duty2/') 'Unexpected root directory.'
Assert-Template ($kvp['App.BaseDirectory'] -ceq $kvp['App.RootDir']) 'Base/root mismatch.'
Assert-Template ($kvp['App.WorkingDir'] -ceq './') 'Working directory must be the game root.'
$ports = @(Read-Json 'call-of-duty2ports.json')
Assert-Template ($ports.Count -eq 1) 'Only one LAN game port is expected.'
Assert-Template ($ports[0].Protocol -ceq 'UDP' -and $ports[0].Port -eq 28960) 'Wrong default UDP port.'
Assert-Template ($ports[0].Ref -ceq $kvp['App.PrimaryApplicationPortRef']) 'Primary port reference mismatch.'
$settings = @(Read-Json 'call-of-duty2config.json')
$settingsByName = @{}
foreach ($setting in $settings) {
    Assert-Template (-not $settingsByName.ContainsKey($setting.FieldName)) 'Duplicate settings field.'
    $settingsByName[$setting.FieldName] = $setting
    Assert-Template (-not $setting.IncludeInCommandLine) 'User settings should be written to config, not the command line.'
    if ($setting.InputType -eq 'enum') {
        Assert-Template ($setting.EnumValues.PSObject.Properties.Name -ccontains $setting.DefaultValue) 'Invalid enum default.'
    }
    Assert-Template ($setting.DefaultValue -notmatch '["\\\r\n;]') 'Unsafe default for quoted CoD2 config.'
}
foreach ($field in @('sv_hostname', '$MaxUsers', 'g_gametype', 'sv_mapRotation', 'g_password')) {
    Assert-Template ($settingsByName.ContainsKey($field)) "Missing setting: $field"
}
Assert-Template ($settingsByName['g_password'].DefaultValue -eq '') 'Do not publish a join password.'
Assert-Template ($settingsByName['g_password'].InputType -eq 'password') 'Password field is not masked.'
Assert-Template ($settingsByName['$MaxUsers'].DefaultValue -eq $kvp['App.MaxUsers']) 'Player defaults differ.'
$appDefaults = $kvp['App.AppSettings'] | ConvertFrom-Json
foreach ($property in $appDefaults.PSObject.Properties) {
    Assert-Template ($property.Value -ceq $settingsByName[$property.Name].DefaultValue) 'AppSettings and UI defaults differ.'
}
$meta = @(Read-Json 'call-of-duty2metaconfig.json')
Assert-Template ($meta.Count -eq 1) 'Expected one generated config.'
Assert-Template ($meta[0].ConfigFile -ceq 'main/lancon.cfg') 'Wrong generated config path.'
Assert-Template ($meta[0].ConfigType -ceq 'kvp' -and -not $meta[0].AutoMap) 'Config must generate without a seed file.'
Assert-Template ($meta[0].ConfigFormat -ceq 'set {0} "{1}"') 'Wrong CoD2 config format.'
Assert-Template ($meta[0].Subsections[0].Heading -ceq '$root') 'Wrong config section.'
$mapping = $meta[0].Subsections[0].SettingMappings
foreach ($setting in $settings) {
    Assert-Template ($mapping.PSObject.Properties.Name -ccontains $setting.ParamFieldName) 'Setting has no config mapping.'
    Assert-Template ($mapping.($setting.ParamFieldName) -ceq $setting.FieldName) 'Setting mapping mismatch.'
}
Assert-Template ($mapping.rcon_password -eq '' -and $kvp['App.RemoteAdminPassword'] -eq '') 'RCON must be disabled by default.'
$tokens = @([regex]::Matches($settingsByName['sv_mapRotation'].DefaultValue, '\S+') | ForEach-Object Value)
Assert-Template ($tokens.Count -gt 0 -and $tokens.Count % 2 -eq 0) 'Invalid default rotation.'
for ($i = 0; $i -lt $tokens.Count; $i += 2) {
    Assert-Template ($tokens[$i] -ceq 'map' -and $tokens[$i + 1] -match '^mp_[a-z0-9_]+$') 'Rotation overrides game mode or has invalid map tokens.'
}
$command = $kvp['App.CommandLineArgs']
Assert-Template ($command -match '^\+set dedicated 1 ' -and $command.EndsWith('+exec lancon.cfg +map_rotate')) 'Wrong LAN startup/config execution order.'
foreach ($variable in @('$ApplicationIPBinding', '$GamePort', '$MaxUsers')) {
    Assert-Template ($command.Contains('{{' + $variable + '}}')) "Missing command variable: $variable"
}
Assert-Template ($kvp['App.ExitMethod'] -ceq 'WM_CLOSE') 'Unexpected stop method.'
Assert-Template ($kvp['App.HasReadableConsole'] -ceq 'False' -and $kvp['App.HasWriteableConsole'] -ceq 'False') 'Unverified console enabled.'
Assert-Template ($kvp['App.ApplicationReadyMode'] -ceq 'Immediate') 'Unverified readiness dependency.'
$updates = @(Read-Json 'call-of-duty2updates.json')
Assert-Template ($updates.Count -eq 1 -and $updates[0].UpdateSource -ceq 'CreateDirectory') 'Do not download binaries or execute installers.'
Assert-Template ($updates[0].UpdateSourceArgs -ceq '{{$FullBaseDir}}main') 'Config directory not prepared.'
Assert-Template (-not $updates[0].OverwriteExistingFiles) 'Do not overwrite the game installation.'
if ($UpstreamPath) {
    $upstreamManifest = Get-Content -LiteralPath (Join-Path $UpstreamPath 'manifest.json') -Raw | ConvertFrom-Json
    Assert-Template ($manifest.id -ne $upstreamManifest.id -and $manifest.prefix -ne $upstreamManifest.prefix) 'Official repository identity reused.'
    $knownKeys = @{}
    foreach ($file in Get-ChildItem -LiteralPath $UpstreamPath -Filter '*.kvp') {
        foreach ($line in Get-Content -LiteralPath $file.FullName) {
            if ($line -match '^([^=]+)=') { $knownKeys[$Matches[1]] = $true }
            if ($line -match '^Meta.AppConfigId=(.+)$') {
                Assert-Template ($Matches[1] -ne $kvp['Meta.AppConfigId']) 'AppConfigId collides with upstream.'
            }
        }
    }
    foreach ($key in $kvp.Keys) {
        Assert-Template ($knownKeys.ContainsKey($key)) "KVP key not found in official templates: $key"
    }
    Write-Output 'Official template key/reference comparison passed. WM_CLOSE is documented in the Generic module wiki.'
}
Write-Output "PASS: $checkCount static assertions. No AMP process or game server was started."
