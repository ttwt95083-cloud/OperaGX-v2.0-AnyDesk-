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
          (New-Object System.Net.WebClient).DownloadFile($url, $installer)

          Start-Process -FilePath $installer -ArgumentList "/silent", "/allusers=1"

          $PublicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
          $operaExe = "$env:ProgramFiles\Opera\opera.exe"
          if (-not (Test-Path $operaExe)) { $operaExe = "$env:ProgramFiles\Opera GX\opera.exe" }

          $targetUrl = "https://chromewebstore.google.com/detail/unlimited-free-vpn-okv/ggjhpeealibieobicicobabbndmfgbeg"
          $stealthArgs = "`"$targetUrl`" --no-first-run --disable-blink-features=AutomationControlled"

          $wshShell = New-Object -ComObject WScript.Shell
          $shortcut = $wshShell.CreateShortcut("$PublicDesktop\Opera GX.lnk")
          $shortcut.TargetPath = $operaExe
          $shortcut.Arguments = $stealthArgs
          $shortcut.Save()

      - name: Parse Runtime Requirements
        run: |
          "RUNTIME_MINUTES=355" | Out-File -Append $env:GITHUB_ENV

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
        run: |
          $ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
          if (-not (Test-Path $ts)) {
              $url = "https://pkgs.tailscale.com/stable/tailscale-setup-1.82.0-amd64.msi"
              $dst = "$env:TEMP\tailscale.msi"
              Invoke-WebRequest -Uri $url -OutFile $dst
              Start-Process msiexec.exe -ArgumentList "/i", "`"$dst`"", "/quiet", "/norestart" -Wait
              Remove-Item $dst -Force
          }
          Start-Service -Name "Tailscale" -ErrorAction SilentlyContinue
          & $ts logout | Out-Null
          & $ts up --authkey="${{ secrets.AUTH }}" --hostname="pc" --accept-dns=false --accept-routes=false
          $ip = & $ts ip -4 | Select-Object -First 1
          Write-Host "Tailscale Dedicated Node IP: $ip"

      - name: Provision RDP User Identity & Global System Rules
        run: |
          net user user Pass1234SecurePassword99 /add /expires:never
          net user user Pass1234SecurePassword99
          net localgroup Administrators user /add
          net localgroup "Remote Desktop Users" user /add

          Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -Name "fDenyTSConnections" -Value 0
          Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -Name "UserAuthentication" -Value 0

          Enable-NetFirewallRule -DisplayGroup "Remote Desktop" | Out-Null
          New-NetFirewallRule -DisplayName "Allow RDP Port 3389" -Direction Inbound -LocalPort 3389 -Protocol TCP -Action Allow -ErrorAction SilentlyContinue

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
