name: Tailscale + Windows App

on:
  workflow_dispatch:
    inputs:
      runtime_minutes:
        description: 'Runtime (max 360)'
        required: false
        default: '360'

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

permissions:
  contents: read
  actions: write

defaults:
  run:
    shell: pwsh

jobs:
  rdp:
    runs-on: windows-latest
    timeout-minutes: 370
    env:
      RDP_USER: "user"
      RDP_PASS: "Pass1234SecurePassword99"

    steps:
      - name: Wipe Unnecessary Pre-Installed GitHub Apps & Shortcuts
        run: |
          $PublicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
          $targets = @("Unity Hub.lnk", "R 4.6.0.lnk", "Firefox.lnk", "Google Chrome.lnk")
          foreach ($target in $targets) { Remove-Item "$PublicDesktop\$target" -ErrorAction SilentlyContinue }

      - name: Download & Force Consumer Build of Opera GX
        run: |
          Write-Host "Fetching consumer-stable Opera GX Core..."
          $url = "https://net.geo.opera.com/opera_gx/stable/windows"
          $installer = "$env:TEMP\OperaSetup.exe"
          Invoke-WebRequest -Uri $url -OutFile $installer

          Start-Process -FilePath $installer -ArgumentList "/silent", "/allusers=1" -Wait

          $userDesktop = "$env:USERPROFILE\Desktop"
          if (Test-Path "$userDesktop\Opera GX.lnk") {
              Move-Item -Path "$userDesktop\Opera GX.lnk" -Destination "$PublicDesktop\Opera GX.lnk" -Force
          }

          Write-Host "Configuring explicit launcher shortcut target..."
          $operaExe = "$env:ProgramFiles\Opera\opera.exe"
          if (-not (Test-Path $operaExe)) { $operaExe = "$env:ProgramFiles\Opera GX\opera.exe" }

          $targetUrl = "https://chromewebstore.google.com/detail/unlimited-free-vpn-okv/ggjhpeealibieobicicobabbndmfgbeg"
          $stealthArgs = "`"$targetUrl`" --no-first-run --disable-blink-features=AutomationControlled"

          $wshShell = New-Object -ComObject WScript.Shell
          $shortcut = $wshShell.CreateShortcut("$PublicDesktop\Opera GX.lnk")
          $shortcut.TargetPath = $operaExe
          $shortcut.Arguments = $stealthArgs
          $shortcut.Save()

          if (Test-Path $operaExe) {
              Start-Process -FilePath $operaExe -ArgumentList $stealthArgs
          }

      - name: Parse Runtime Requirements
        run: |
          function IntOrDefault($v,$d){ if($v -match '^\d+$'){ [int]$v }else{ $d } }
          $runtime = IntOrDefault("${{ inputs.runtime_minutes }}", 355)
          if ($runtime -gt 360 -or $runtime -lt 1) { $runtime = 355 }
          "RUNTIME_MINUTES=$runtime" | Out-File -Append $env:GITHUB_ENV

      - name: Purge Legacy Machine Registrations
        run: |
          try {
              $email = "${{ secrets.EMAILS }}"
              if ([string]::IsNullOrWhiteSpace($email)) { return }

              $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($secrets.EMAILS)"))
              $un = [Uri]::EscapeDataString($email)
              $list = Invoke-RestMethod -Uri "https://api.tailscale.com/api/v2/tailnet/-/devices" -Headers @{ Authorization = "Basic $auth" }
              foreach ($d in $list.devices){ if ($d.hostname -match "build(-[0-9]+)?$") { Invoke-RestMethod -Method Delete -Uri "https://api.tailscale.com/api/v2/device/$($d.id)" -Headers @{ Authorization = "Basic $auth" } } }
          } catch {}

      - name: Install & Authenticate Tailscale Network
        uses: tailscale/github-action@v2
        with:
          authkey: ${{ secrets.AUTH }}
          args: --hostname=pc

      - name: Provision RDP User Identity & Global System Rules
        run: |
          $u = $env:RDP_USER
          $p = $env:RDP_PASS
          $pSec = $p | ConvertTo-SecureString -AsPlainText -Force
          if (-not (Get-LocalUser -Name $u -ErrorAction SilentlyContinue)) {
              New-LocalUser -Name $u -Password $pSec -PasswordNeverExpires -AccountNeverExpires
              Add-LocalGroupMember -Group "Administrators" -Member $u
              Add-LocalGroupMember -Group "Remote Desktop Users" -Member $u
          } else {
              Enable-LocalUser -Name $u
              Set-LocalUser -Name $u -Password $pSec -PasswordNeverExpires
          }

          Set-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
          Enable-NetFirewallRule -DisplayGroup "Remote Desktop" | Out-Null

      - name: Structural Window Minimization
        run: |
          $shell = New-Object -ComObject Shell.Application
          $shell.MinimizeAll()

      - name: Connection Keep-Alive Loop
        run: |
          $mins = [int]$env:RUNTIME_MINUTES
          if (-not $mins) { $mins = 355 }

          $send = (Get-Date).AddMinutes($mins)
          while ((Get-Date) -lt $send) {
              Write-Host "Tailscale/RDP Active Engine | Heartbeat = $((Get-Date).ToString('HH:mm:ss'))"
              Start-Sleep -Seconds 60
          }

      - name: Disconnect Tailscale Node Safely
        if: always()
        run: |
          $ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
          if (Test-Path $ts) {
              Write-Host "Disconnecting machine and logging out of Tailscale..."
              & $ts logout | Out-Null
          }
