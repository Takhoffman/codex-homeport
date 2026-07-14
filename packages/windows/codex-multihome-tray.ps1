param(
  [Parameter(Mandatory = $true)]
  [string]$HomeportScript,
  [string]$WorkingDirectory = $PWD.Path,
  [ValidateSet("live", "dev")]
  [string]$Channel = "live",
  [switch]$ShowOnStart
)

Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "Stop"
$script:homeportScript = (Resolve-Path -LiteralPath $HomeportScript).Path
$script:workingDirectory = $WorkingDirectory
$script:channel = $Channel
$script:window = $null
$script:statusText = $null
$script:allowWindowClose = $false
$script:selectedProduct = "codex"
$script:selectedTab = "favorites"
$script:clonePolicies = @{}

function Reset-ClonePolicies {
  param([string]$Preset = "working-setup")
  $script:clonePolicies = @{
    instructions = "copy"
    config = "copy"
    skills = "copy"
    plugins = "copy"
    prompts = "copy"
    rules = "copy"
    profiles = "copy"
    auth = "copy"
    agents = "copy"
    commands = "copy"
    workflows = "copy"
    outputStyles = "copy"
    browser = "copy"
    memories = "copy"
    sessions = "skip"
  }
  if ($Preset -eq "config-only") {
    foreach ($key in @("auth", "browser", "memories", "sessions")) {
      $script:clonePolicies[$key] = "skip"
    }
  } elseif ($Preset -eq "empty") {
    foreach ($key in @($script:clonePolicies.Keys)) {
      $script:clonePolicies[$key] = "skip"
    }
  }
}

Reset-ClonePolicies

function Invoke-Homeport {
  param(
    [string[]]$Arguments,
    [switch]$Capture,
    [switch]$Wait
  )

  $node = (Get-Command node -ErrorAction Stop).Source
  $allArgs = @($script:homeportScript, "--channel", $script:channel, "--product", $script:selectedProduct) + $Arguments
  $startInfo = New-Object System.Diagnostics.ProcessStartInfo
  $startInfo.FileName = $node
  $startInfo.Arguments = Join-ProcessArguments $allArgs
  $startInfo.WorkingDirectory = $script:workingDirectory
  $startInfo.UseShellExecute = $false
  $startInfo.CreateNoWindow = $true
  if ($Capture) {
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
  }

  $process = [System.Diagnostics.Process]::Start($startInfo)
  if ($Capture -or $Wait) {
    $process.WaitForExit()
  }
  if ($Capture) {
    $output = $process.StandardOutput.ReadToEnd()
    $errorText = $process.StandardError.ReadToEnd()
    if ($process.ExitCode -ne 0) {
      throw ($errorText.Trim(), $output.Trim() | Where-Object { $_ } | Select-Object -First 1)
    }
    return $output.Trim()
  }
}

function Join-ProcessArguments {
  param([string[]]$Arguments)
  return ($Arguments | ForEach-Object { ConvertTo-ProcessArgument $_ }) -join " "
}

function ConvertTo-ProcessArgument {
  param([string]$Argument)
  if ($Argument -notmatch '[\s"]') {
    return $Argument
  }
  return '"' + ($Argument -replace '\\(?=\\*")', '$0$0' -replace '"', '\"') + '"'
}

function Set-Status {
  param([string]$Message)
  if ($script:statusText) {
    $script:statusText.Text = $Message
  }
}

function New-Icon {
  $bitmap = New-Object System.Drawing.Bitmap 16, 16
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
  $graphics.Clear([System.Drawing.Color]::Transparent)
  $brush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(33, 116, 181))
  $graphics.FillEllipse($brush, 1, 1, 14, 14)
  $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::White), 2
  $graphics.DrawLine($pen, 4, 10, 8, 5)
  $graphics.DrawLine($pen, 8, 5, 12, 10)
  $graphics.Dispose()
  return [System.Drawing.Icon]::FromHandle($bitmap.GetHicon())
}

function Read-State {
  $userHome = [Environment]::GetFolderPath("UserProfile")
  $appData = [Environment]::GetFolderPath("ApplicationData")
  if ($script:selectedProduct -eq "claude") {
    $appSupportName = if ($script:channel -eq "dev") { "ClaudeMultihomeDev" } else { "ClaudeMultihome" }
    $managedName = if ($script:channel -eq "dev") { ".claude-homes-dev" } else { ".claude-homes" }
    $mainName = ".claude"
    $profilePath = $null
    $envHome = [Environment]::GetEnvironmentVariable("CLAUDE_CONFIG_DIR", "Process")
    $mainPath = if ($envHome) { $envHome } else { Join-Path $userHome $mainName }
  } else {
    $appSupportName = if ($script:channel -eq "dev") { "CodexMultihomeDev" } else { "CodexMultihome" }
    $managedName = if ($script:channel -eq "dev") { ".codex-homes-dev" } else { ".codex-homes" }
    $mainName = ".codex"
    $profilePath = Join-Path $appData "Codex"
    $mainPath = Join-Path $userHome $mainName
  }
  $stateFile = Join-Path $appData "$appSupportName\homeport.json"
  if (Test-Path -LiteralPath $stateFile) {
    return Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json
  }

  return [pscustomobject]@{
    homes = @([pscustomobject]@{
      id = "00000000-0000-0000-0000-000000000001"
      name = "Main"
      slug = "main"
      kind = "main"
      homePath = $mainPath
      profilePath = $profilePath
      product = $script:selectedProduct
      isTemporary = $false
    })
    instances = @()
    pinnedHomeIDs = @()
    preferences = [pscustomobject]@{
      defaultLaunchTarget = "terminal"
      defaultClonePreset = "working-setup"
      launchTemporaryByDefault = $false
    }
    managedHomes = Join-Path $userHome $managedName
  }
}

function Get-DoctorMap {
  $map = @{}
  try {
    $output = Invoke-Homeport @("doctor") -Capture
    foreach ($line in ($output -split "`r?`n")) {
      $parts = $line -split ":", 2
      if ($parts.Count -eq 2) {
        $map[$parts[0].Trim()] = $parts[1].Trim()
      }
    }
  } catch {
    $map["Status"] = $_.Exception.Message
  }
  return $map
}

function New-Text {
  param(
    [string]$Text,
    [double]$Size = 12,
    [string]$Weight = "Normal",
    [string]$Color = "#1f2937"
  )
  $textBlock = New-Object System.Windows.Controls.TextBlock
  $textBlock.Text = $Text
  $textBlock.FontSize = $Size
  $textBlock.FontWeight = $Weight
  $textBlock.Foreground = $Color
  $textBlock.TextTrimming = "CharacterEllipsis"
  return $textBlock
}

function New-Button {
  param(
    [string]$Text,
    [scriptblock]$Action,
    [string]$Style = "Secondary"
  )
  $button = New-Object System.Windows.Controls.Button
  $button.Content = $Text
  $button.MinHeight = 32
  $button.Padding = "12,5"
  $button.Margin = "0,0,8,0"
  $button.Cursor = "Hand"
  $button.BorderThickness = 0
  $button.FontWeight = "SemiBold"
  $button.FontSize = 12
  if ($Style -eq "Primary") {
    $button.Background = "#2563eb"
    $button.Foreground = "White"
  } elseif ($Style -eq "Danger") {
    $button.Background = "#fee2e2"
    $button.Foreground = "#991b1b"
  } else {
    $button.Background = "#e5e7eb"
    $button.Foreground = "#111827"
  }
  $button.Add_Click($Action)
  return $button
}

function New-Section {
  param([string]$Title)
  $panel = New-Object System.Windows.Controls.StackPanel
  $panel.Margin = "0,14,0,0"
  [void]$panel.Children.Add((New-Text $Title 11 "Bold" "#6b7280"))
  return $panel
}

function New-Card {
  $border = New-Object System.Windows.Controls.Border
  $border.Background = "White"
  $border.BorderBrush = "#e5e7eb"
  $border.BorderThickness = 1
  $border.CornerRadius = 8
  $border.Padding = 10
  $border.Margin = "0,6,0,0"
  return $border
}

function Add-ActionRow {
  param(
    [System.Windows.Controls.Panel]$Parent,
    [string]$Title,
    [string]$Subtitle,
    [scriptblock]$Primary,
    [string]$PrimaryText = "Open",
    [scriptblock]$Secondary = $null,
    [string]$SecondaryText = "Terminal"
  )
  $card = New-Card
  $grid = New-Object System.Windows.Controls.Grid
  [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
  $actionsColumn = New-Object System.Windows.Controls.ColumnDefinition
  $actionsColumn.Width = "Auto"
  [void]$grid.ColumnDefinitions.Add($actionsColumn)

  $textPanel = New-Object System.Windows.Controls.StackPanel
  [void]$textPanel.Children.Add((New-Text $Title 13 "SemiBold" "#111827"))
  [void]$textPanel.Children.Add((New-Text $Subtitle 11 "Normal" "#6b7280"))
  [System.Windows.Controls.Grid]::SetColumn($textPanel, 0)
  [void]$grid.Children.Add($textPanel)

  $buttons = New-Object System.Windows.Controls.StackPanel
  $buttons.Orientation = "Horizontal"
  $buttons.HorizontalAlignment = "Right"
  [void]$buttons.Children.Add((New-Button $PrimaryText $Primary "Primary"))
  if ($Secondary) {
    [void]$buttons.Children.Add((New-Button $SecondaryText $Secondary))
  }
  [System.Windows.Controls.Grid]::SetColumn($buttons, 1)
  [void]$grid.Children.Add($buttons)
  $card.Child = $grid
  [void]$Parent.Children.Add($card)
}

function Add-InfoCard {
  param(
    [System.Windows.Controls.Panel]$Parent,
    [string]$Title,
    [string]$Body
  )
  $card = New-Card
  $panel = New-Object System.Windows.Controls.StackPanel
  [void]$panel.Children.Add((New-Text $Title 13 "SemiBold" "#111827"))
  $bodyText = New-Text $Body 11 "Normal" "#6b7280"
  $bodyText.Margin = "0,4,0,0"
  $bodyText.TextWrapping = "Wrap"
  [void]$panel.Children.Add($bodyText)
  $card.Child = $panel
  [void]$Parent.Children.Add($card)
}

function Get-PolicyDefinitions {
  if ($script:selectedProduct -eq "claude") {
    return @(
      @{ Key = "instructions"; Label = "Instructions"; Detail = "CLAUDE.md and CLAUDE.local.md" },
      @{ Key = "config"; Label = "Config"; Detail = "settings.json, settings.local.json, claude.json, .mcp.json" },
      @{ Key = "skills"; Label = "Skills"; Detail = "skills" },
      @{ Key = "plugins"; Label = "Plugins"; Detail = "plugins" },
      @{ Key = "agents"; Label = "Agents"; Detail = "agents" },
      @{ Key = "commands"; Label = "Commands"; Detail = "commands" },
      @{ Key = "workflows"; Label = "Workflows"; Detail = "workflows" },
      @{ Key = "outputStyles"; Label = "Output Styles"; Detail = "output-styles" },
      @{ Key = "auth"; Label = "Auth"; Detail = ".credentials.json and oauth files" },
      @{ Key = "sessions"; Label = "Sessions"; Detail = "projects, sessions, todos, history, statsig" }
    )
  }
  return @(
    @{ Key = "instructions"; Label = "Instructions"; Detail = "AGENTS.md" },
    @{ Key = "config"; Label = "Config"; Detail = "config.toml, keybindings.json, version.json" },
    @{ Key = "skills"; Label = "Skills"; Detail = "skills and skill backups" },
    @{ Key = "plugins"; Label = "Plugins"; Detail = "plugins and vendor imports" },
    @{ Key = "prompts"; Label = "Prompts"; Detail = "prompts" },
    @{ Key = "rules"; Label = "Rules"; Detail = "rules" },
    @{ Key = "profiles"; Label = "Profiles"; Detail = "profiles" },
    @{ Key = "auth"; Label = "Auth"; Detail = "auth.json" },
    @{ Key = "agents"; Label = "Agents"; Detail = "agents" },
    @{ Key = "browser"; Label = "Browser"; Detail = "browser support and native hosts" },
    @{ Key = "memories"; Label = "Memories"; Detail = "memories and memory sqlite files" },
    @{ Key = "sessions"; Label = "Sessions"; Detail = "sessions, logs, goals, state, attachments" }
  )
}

function New-PolicyButton {
  param(
    [string]$Text,
    [string]$Key,
    [string]$Mode
  )
  $button = New-Object System.Windows.Controls.Button
  $button.Content = $Text
  $button.MinHeight = 28
  $button.MinWidth = 44
  $button.Padding = "8,3"
  $button.Margin = "3,0,0,0"
  $button.Cursor = "Hand"
  $button.BorderThickness = 0
  $button.FontSize = 11
  $button.FontWeight = "SemiBold"
  $button.Tag = "$Key|$Mode"
  if ($script:clonePolicies[$Key] -eq $Mode) {
    $button.Background = "#2563eb"
    $button.Foreground = "White"
  } else {
    $button.Background = "#e5e7eb"
    $button.Foreground = "#374151"
  }
  $button.Add_Click({
    param($sender, $eventArgs)
    $parts = ([string]$sender.Tag) -split "\|", 2
    $script:clonePolicies[$parts[0]] = $parts[1]
    Refresh-Window
  })
  return $button
}

function Add-PolicyEditor {
  param([System.Windows.Controls.Panel]$Parent)
  $section = New-Section "COPY OPTIONS"
  [void]$Parent.Children.Add($section)

  $presetButtons = New-Object System.Windows.Controls.StackPanel
  $presetButtons.Orientation = "Horizontal"
  $presetButtons.Margin = "0,6,0,4"
  [void]$presetButtons.Children.Add((New-Button "Working Setup" { Reset-ClonePolicies "working-setup"; Refresh-Window } "Primary"))
  [void]$presetButtons.Children.Add((New-Button "Config Only" { Reset-ClonePolicies "config-only"; Refresh-Window }))
  [void]$presetButtons.Children.Add((New-Button "Empty" { Reset-ClonePolicies "empty"; Refresh-Window }))
  [void]$section.Children.Add($presetButtons)

  foreach ($definition in (Get-PolicyDefinitions)) {
    $key = [string]$definition.Key
    if (-not $script:clonePolicies.ContainsKey($key)) {
      $script:clonePolicies[$key] = "skip"
    }
    $card = New-Card
    $grid = New-Object System.Windows.Controls.Grid
    [void]$grid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition))
    $actionsColumn = New-Object System.Windows.Controls.ColumnDefinition
    $actionsColumn.Width = "Auto"
    [void]$grid.ColumnDefinitions.Add($actionsColumn)

    $textPanel = New-Object System.Windows.Controls.StackPanel
    [void]$textPanel.Children.Add((New-Text ([string]$definition.Label) 12 "SemiBold" "#111827"))
    $detail = New-Text ([string]$definition.Detail) 10 "Normal" "#6b7280"
    $detail.TextWrapping = "Wrap"
    [void]$textPanel.Children.Add($detail)
    [System.Windows.Controls.Grid]::SetColumn($textPanel, 0)
    [void]$grid.Children.Add($textPanel)

    $buttons = New-Object System.Windows.Controls.StackPanel
    $buttons.Orientation = "Horizontal"
    $buttons.HorizontalAlignment = "Right"
    [void]$buttons.Children.Add((New-PolicyButton "Skip" $key "skip"))
    [void]$buttons.Children.Add((New-PolicyButton "Copy" $key "copy"))
    [void]$buttons.Children.Add((New-PolicyButton "Link" $key "link"))
    [System.Windows.Controls.Grid]::SetColumn($buttons, 1)
    [void]$grid.Children.Add($buttons)
    $card.Child = $grid
    [void]$section.Children.Add($card)
  }
}

function Get-ClonePolicyArgs {
  $copy = @()
  $link = @()
  foreach ($definition in (Get-PolicyDefinitions)) {
    $key = [string]$definition.Key
    $mode = [string]$script:clonePolicies[$key]
    if ($mode -eq "copy") {
      $copy += $key
    } elseif ($mode -eq "link") {
      $link += $key
    }
  }
  $args = @("--preset", "empty")
  if ($copy.Count -gt 0) {
    $args += @("--include", ($copy -join ","))
  }
  if ($link.Count -gt 0) {
    $args += @("--link", ($link -join ","))
  }
  return $args
}

function New-CloneArguments {
  param([string]$Name)
  return @("clone", "--name", $Name) + (Get-ClonePolicyArgs)
}

function Add-HomeRow {
  param(
    [System.Windows.Controls.Panel]$Parent,
    [object]$CodexHome
  )
  $name = [string]$CodexHome.name
  $slug = [string]$CodexHome.slug
  $kind = [string]$CodexHome.kind
  $path = [string]$CodexHome.homePath
  $subtitle = if ($kind) { "$kind  |  $path" } else { $path }
  if ($script:selectedProduct -eq "claude") {
    Add-ActionRow $Parent $name $subtitle { Invoke-And-Refresh @("launch", $slug, "--target", "terminal") "Opened $name terminal" } "Terminal"
  } else {
    Add-ActionRow $Parent $name $subtitle `
      { Invoke-And-Refresh @("launch", $slug, "--target", "desktop") "Opened $name desktop" } "Desktop" `
      { Invoke-And-Refresh @("launch", $slug, "--target", "terminal") "Opened $name terminal" } "Terminal"
  }
}

function Add-ProductButton {
  param(
    [System.Windows.Controls.Panel]$Parent,
    [string]$Text,
    [string]$Product
  )
  $button = New-Object System.Windows.Controls.Button
  $button.Content = $Text
  $button.MinHeight = 34
  $button.Margin = "3,0"
  $button.Padding = "10,5"
  $button.Cursor = "Hand"
  $button.BorderThickness = 0
  $button.FontSize = 12
  $button.FontWeight = "SemiBold"
  $button.Tag = $Product
  if ($script:selectedProduct -eq $Product) {
    $button.Background = "#111827"
    $button.Foreground = "White"
  } else {
    $button.Background = "#e5e7eb"
    $button.Foreground = "#374151"
  }
  $button.Add_Click({
    param($sender, $eventArgs)
    $script:selectedProduct = [string]$sender.Tag
    $script:selectedTab = "favorites"
    Reset-ClonePolicies
    Refresh-Window
  })
  [void]$Parent.Children.Add($button)
}

function Add-TabButton {
  param(
    [System.Windows.Controls.Panel]$Parent,
    [string]$Text,
    [string]$Tab
  )
  $button = New-Object System.Windows.Controls.Button
  $button.Content = $Text
  $button.MinHeight = 52
  $button.Margin = "3,0"
  $button.Padding = "4,5"
  $button.Cursor = "Hand"
  $button.BorderThickness = 0
  $button.FontSize = 11
  $button.FontWeight = "SemiBold"
  $button.HorizontalContentAlignment = "Center"
  $button.VerticalContentAlignment = "Center"
  $button.Tag = $Tab
  if ($script:selectedTab -eq $Tab) {
    $button.Background = "#2563eb"
    $button.Foreground = "White"
  } else {
    $button.Background = "#e5e7eb"
    $button.Foreground = "#374151"
  }
  $button.Add_Click({
    param($sender, $eventArgs)
    $script:selectedTab = [string]$sender.Tag
    Refresh-Window
  })
  [void]$Parent.Children.Add($button)
}

function Invoke-And-Refresh {
  param(
    [string[]]$Arguments,
    [string]$Message
  )
  try {
    Invoke-Homeport $Arguments -Wait | Out-Null
    Refresh-Window
    Set-Status $Message
  } catch {
    Set-Status $_.Exception.Message
  }
}

function Build-Window {
  $window = New-Object System.Windows.Window
  $window.Title = "Codex Multihome"
  $window.Width = 430
  $window.Height = 620
  $window.ResizeMode = "CanResizeWithGrip"
  $window.WindowStartupLocation = "CenterScreen"
  $window.Background = "#f3f4f6"
  $window.Topmost = $true

  $dock = New-Object System.Windows.Controls.DockPanel

  $productRoot = New-Object System.Windows.Controls.Primitives.UniformGrid
  $productRoot.Columns = 2
  $productRoot.Margin = "13,12,13,2"
  [System.Windows.Controls.DockPanel]::SetDock($productRoot, "Top")
  [void]$dock.Children.Add($productRoot)

  $headerRoot = New-Object System.Windows.Controls.StackPanel
  $headerRoot.Margin = "16,10,16,6"
  [System.Windows.Controls.DockPanel]::SetDock($headerRoot, "Top")
  [void]$dock.Children.Add($headerRoot)

  $tabRoot = New-Object System.Windows.Controls.Primitives.UniformGrid
  $tabRoot.Columns = 5
  $tabRoot.Margin = "10,6,10,10"
  [System.Windows.Controls.DockPanel]::SetDock($tabRoot, "Bottom")
  [void]$dock.Children.Add($tabRoot)

  $scroll = New-Object System.Windows.Controls.ScrollViewer
  $scroll.VerticalScrollBarVisibility = "Auto"
  $contentRoot = New-Object System.Windows.Controls.StackPanel
  $contentRoot.Margin = "16,0,16,8"
  $scroll.Content = $contentRoot
  [void]$dock.Children.Add($scroll)

  $window.Content = $dock
  $window.Tag = @{
    ProductTabs = $productRoot
    Header = $headerRoot
    Content = $contentRoot
    Tabs = $tabRoot
  }
  return $window
}

function Refresh-Window {
  if (-not $script:window) {
    return
  }
  try {
    [void](Invoke-Homeport @("reconcile") -Capture)
  } catch {
    Set-Status "Could not refresh running-instance status"
  }
  $regions = $script:window.Tag
  $productRoot = [System.Windows.Controls.Primitives.UniformGrid]$regions.ProductTabs
  $headerRoot = [System.Windows.Controls.StackPanel]$regions.Header
  $root = [System.Windows.Controls.StackPanel]$regions.Content
  $tabRoot = [System.Windows.Controls.Primitives.UniformGrid]$regions.Tabs
  $productRoot.Children.Clear()
  $headerRoot.Children.Clear()
  $root.Children.Clear()
  $tabRoot.Children.Clear()
  Add-ProductButton $productRoot "Codex" "codex"
  Add-ProductButton $productRoot "Claude" "claude"
  $state = Read-State
  $doctor = Get-DoctorMap
  $productName = if ($script:selectedProduct -eq "claude") { "Claude" } else { "Codex" }
  $productCli = if ($script:selectedProduct -eq "claude") { "claude CLI" } else { "codex CLI" }
  $productEnv = if ($script:selectedProduct -eq "claude") { "CLAUDE_CONFIG_DIR" } else { "CODEX_HOME" }
  $productDesktop = if ($script:selectedProduct -eq "claude") { "Claude desktop app" } else { "Codex desktop app" }
  $homes = @($state.homes)
  $instances = @($state.instances)
  $pending = @($instances | Where-Object { $_.cleanupReviewRequired -eq $true })
  $pinnedIds = @($state.pinnedHomeIDs)
  $pinned = @($homes | Where-Object { $pinnedIds -contains $_.id })
  if ($pinned.Count -eq 0) {
    $pinned = @($homes | Where-Object { $_.kind -eq "main" })
  }

  $headerTitle = switch ($script:selectedTab) {
    "favorites" { "Favorites" }
    "recents" { "Recents" }
    "homes" { "Homes" }
    "new" { "New Home" }
    "settings" { "Settings" }
    default { "Favorites" }
  }
  $headerSubtitle = switch ($script:selectedTab) {
    "favorites" { "Fast launch your usual $productName homes" }
    "recents" { "Recent opens and temporary cleanup" }
    "homes" { "Browse, favorite, and launch $productName homes" }
    "new" { "Choose the kind of $productName home first" }
    "settings" { "Defaults, diagnostics, and installer state" }
    default { "Fast launch your usual $productName homes" }
  }
  [void]$headerRoot.Children.Add((New-Text $headerTitle 22 "Bold" "#111827"))
  $badge = New-Text ($(if ($script:channel -eq "dev") { "DEV CHANNEL" } else { "LIVE CHANNEL" })) 10 "Black" "#2563eb"
  $badge.Margin = "0,1,0,0"
  [void]$headerRoot.Children.Add($badge)
  $subtitleText = New-Text $headerSubtitle 11 "Normal" "#6b7280"
  $subtitleText.Margin = "0,3,0,0"
  [void]$headerRoot.Children.Add($subtitleText)

  $mainSessions = if ($doctor["Main sessions"]) { $doctor["Main sessions"] } else { "0" }
  $mainAuth = if ($doctor["Main auth"]) { $doctor["Main auth"] } else { "unknown" }
  $cliStatus = if ($doctor[$productCli] -and $doctor[$productCli] -ne "missing") { "found" } else { "missing" }
  $summary = "Main sessions: {0}  |  Auth: {1}  |  CLI: {2}" -f $mainSessions, $mainAuth, $cliStatus
  $summaryText = New-Text $summary 11 "Normal" "#6b7280"
  $summaryText.Margin = "0,2,0,6"
  [void]$headerRoot.Children.Add($summaryText)

  $visibleHomes = @($pinned) + @($homes | Where-Object { $pinnedIds -notcontains $_.id -and $_.kind -ne "main" })

  switch ($script:selectedTab) {
    "favorites" {
      $quick = New-Section "FAVORITES"
      [void]$root.Children.Add($quick)
      foreach ($codexHome in ($visibleHomes | Select-Object -First 5)) {
        Add-HomeRow $quick $codexHome
      }
      $quickLaunch = New-Section "QUICK LAUNCH"
      [void]$root.Children.Add($quickLaunch)
      if ($script:selectedProduct -eq "claude") {
        Add-ActionRow $quickLaunch "Main" "Use your normal .claude home" { Invoke-And-Refresh @("launch", "main", "--target", "terminal") "Opened Main terminal" } "Terminal"
        Add-ActionRow $quickLaunch "Temporary" "Create a throwaway Claude Code home for cleanup review" { Invoke-And-Refresh @("launch", "temp", "--target", "terminal") "Opened temporary terminal" } "Terminal"
      } else {
        Add-ActionRow $quickLaunch "Main" "Use your normal .codex home" { Invoke-And-Refresh @("launch", "main", "--target", "desktop") "Opened Main desktop" } "Desktop" { Invoke-And-Refresh @("launch", "main", "--target", "terminal") "Opened Main terminal" } "Terminal"
        Add-ActionRow $quickLaunch "Temporary" "Create a throwaway home for cleanup review" { Invoke-And-Refresh @("launch", "temp", "--target", "desktop") "Opened temporary desktop" } "Desktop" { Invoke-And-Refresh @("launch", "temp", "--target", "terminal") "Opened temporary terminal" } "Terminal"
      }
    }
    "recents" {
      $recentSection = New-Section "RECENT OPENS"
      [void]$root.Children.Add($recentSection)
      if ($instances.Count -eq 0) {
        Add-InfoCard $recentSection "No recents" "Launch a home and it will appear here."
      } else {
        foreach ($instance in ($instances | Select-Object -First 6)) {
          $homeName = [string]$instance.homeName
          $target = [string]$instance.target
          $workspacePath = [string]$instance.workspacePath
          Add-ActionRow $recentSection $homeName "$target  |  $workspacePath" { Invoke-And-Refresh @("launch", $homeName, "--target", $target) "Relaunched $homeName" } "Launch"
        }
      }
      if ($pending.Count -gt 0) {
        $cleanup = New-Section "CLEANUP REVIEW"
        [void]$root.Children.Add($cleanup)
        foreach ($instance in ($pending | Select-Object -First 5)) {
          $instanceId = [string]$instance.id
          $homeName = [string]$instance.homeName
          $homePath = [string]$instance.homePath
          Add-ActionRow $cleanup $homeName $homePath { Invoke-And-Refresh @("promote", $instanceId) "Promoted $homeName" } "Promote" { Invoke-And-Refresh @("cleanup", $instanceId) "Cleaned $homeName" } "Delete"
        }
      }
    }
    "homes" {
      $homesSection = New-Section "ALL HOMES"
      [void]$root.Children.Add($homesSection)
      foreach ($codexHome in ($homes | Select-Object -First 12)) {
        Add-HomeRow $homesSection $codexHome
      }
    }
    "new" {
      $new = New-Section "CREATE"
      [void]$root.Children.Add($new)
      Add-ActionRow $new "Clone With Options" "Use the copy options below" { Invoke-And-Refresh (New-CloneArguments "$productName Clone $(Get-Date -Format 'MMM d HHmm')") "Created custom clone" } "Clone"
      Add-ActionRow $new "Clean Room" "Fresh saved $productName home with no inherited files" { Invoke-And-Refresh @("create", "--kind", "clean-room", "--name", "$productName Clean Room $(Get-Date -Format 'MMM d HHmm')") "Created clean room" } "Create"
      Add-ActionRow $new "Temporary" "Disposable $productName home with cleanup review" { Invoke-And-Refresh @("create", "--kind", "temporary", "--name", "$productName Temporary $(Get-Date -Format 'MMM d HHmm')") "Created temporary home" } "Create"
      Add-PolicyEditor $root
      Add-ActionRow $root "Create Clone" "Use the copy options above" { Invoke-And-Refresh (New-CloneArguments "$productName Clone $(Get-Date -Format 'MMM d HHmm')") "Created custom clone" } "Create"
    }
    "settings" {
      $diagnostics = New-Section "DIAGNOSTICS"
      [void]$root.Children.Add($diagnostics)
      $diagText = @(
        "${productEnv}: $(if ($doctor["User $productEnv"]) { $doctor["User $productEnv"] } else { 'not set' })"
        "Desktop app: $(if ($doctor[$productDesktop]) { $doctor[$productDesktop] } else { 'unknown' })"
        "Account: $(if ($doctor['Account']) { $doctor['Account'] } else { 'unknown' })"
      ) -join "`n"
      Add-InfoCard $diagnostics "Launch Health" $diagText
      $defaults = New-Section "DEFAULTS"
      [void]$root.Children.Add($defaults)
      Add-ActionRow $defaults "Open Main" "Default target: $($state.preferences.defaultLaunchTarget)" { Invoke-And-Refresh @("configure", "--launch-target", "desktop") "Default launch target set to desktop" } "Desktop" { Invoke-And-Refresh @("configure", "--launch-target", "terminal") "Default launch target set to terminal" } "Terminal"
      Add-ActionRow $defaults "Temporary Preference" "Prefer temporary: $($state.preferences.launchTemporaryByDefault)" { Invoke-And-Refresh @("configure", "--temporary", "on") "Temporary launches enabled" } "On" { Invoke-And-Refresh @("configure", "--temporary", "off") "Temporary launches disabled" } "Off"
    }
  }

  $footer = New-Object System.Windows.Controls.StackPanel
  $footer.Orientation = "Horizontal"
  $footer.Margin = "0,14,0,0"
  [void]$footer.Children.Add((New-Button "Refresh" { Refresh-Window }))
  [void]$footer.Children.Add((New-Button "Doctor" { Invoke-And-Refresh @("doctor") "Doctor completed" }))
  [void]$footer.Children.Add((New-Button "Exit" {
    $script:allowWindowClose = $true
    $script:notifyIcon.Visible = $false
    $script:notifyIcon.Dispose()
    [System.Windows.Application]::Current.Shutdown()
  } "Danger"))
  [void]$root.Children.Add($footer)

  $script:statusText = New-Text "Ready" 11 "Normal" "#6b7280"
  $script:statusText.Margin = "0,10,0,0"
  [void]$root.Children.Add($script:statusText)

  Add-TabButton $tabRoot "Favorites" "favorites"
  Add-TabButton $tabRoot "Recents" "recents"
  Add-TabButton $tabRoot "Homes" "homes"
  Add-TabButton $tabRoot "New" "new"
  Add-TabButton $tabRoot "Settings" "settings"
}

function New-MultihomeWindow {
  $window = Build-Window
  $window.Add_Closing({
    param($sender, $eventArgs)
    if (-not $script:allowWindowClose) {
      $eventArgs.Cancel = $true
      $sender.Hide()
    }
  })
  $window.Add_Closed({
    $script:window = $null
  })
  $window.Add_Deactivated({
    if ($script:window -and -not $script:window.IsKeyboardFocusWithin) {
      $script:window.Topmost = $false
    }
  })
  return $window
}

function Show-Window {
  try {
    if (-not $script:window) {
      $script:window = New-MultihomeWindow
    }
    Refresh-Window
    $script:window.Show()
    $script:window.Activate()
    $script:window.Topmost = $true
    $script:window.Topmost = $false
  } catch {
    $script:window = New-MultihomeWindow
    Refresh-Window
    $script:window.Show()
    $script:window.Activate()
  }
}

$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:notifyIcon.Icon = New-Icon
$script:notifyIcon.Text = if ($script:channel -eq "dev") { "Codex Multihome Dev" } else { "Codex Multihome" }
$script:notifyIcon.Visible = $true
$script:notifyIcon.add_MouseUp({
  param($sender, $eventArgs)
  if ($eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Left -or $eventArgs.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
    Show-Window
  }
})

$app = [System.Windows.Application]::new()
$app.ShutdownMode = [System.Windows.ShutdownMode]::OnExplicitShutdown
$script:notifyIcon.ShowBalloonTip(900, $script:notifyIcon.Text, "Tray launcher is running. Click the icon to open Multihome.", [System.Windows.Forms.ToolTipIcon]::Info)
if ($ShowOnStart) {
  [void]$app.Dispatcher.BeginInvoke([Action]{ Show-Window })
}
[void]$app.Run()
