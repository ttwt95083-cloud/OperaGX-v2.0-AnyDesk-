name: Tailscale + Windows App

on:
  workflow_dispatch:
    inputs:
      runtime_minutes:    { description: "Runtime (max 360)", required: false, default: "355" }

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
      RDP_PASS: "Pass1234"

    steps:
      - name: Wipe Unnecessary Pre-Installed GitHub Apps & Shortcuts
        run: |
          $publicDesktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
          $targets = @("Unity Hub.lnk", "R 4.6.0.lnk", "Firefox.lnk", "Google Chrome.lnk", "Claim Rewards Here.lnk")
          foreach ($target in $targets) { Remove-Item "$publicDesktop\$target" -Force -ErrorAction SilentlyContinue }

      - name: Download & Force Consumer Build of Opera GX
        run: |
          Write-Host "Fetching consumer-stable Opera GX Core..."
          $url = "https://net.geo.opera.com/opera_gx/stable/windows?utm_source=inf&utm_medium=gx"
          $installer = "$env:TEMP\OperaGXSetup.exe"
          Invoke-WebRequest -Uri $url -OutFile $installer
          
          Start-Process -FilePath $installer -ArgumentList "--silent=1", "--allusers=1", "--launchbrowser=0", "--desktopshortcut=1" -Wait
          
          $publicDesktop = [Environment]::GetFolderPath("CommonDesktopDirectory")
          $userDesktop = "$env:USERPROFILE\Desktop"
          
          if (Test-Path "$userDesktop\Opera GX.lnk") {
              Move-Item -Path "$userDesktop\Opera GX.lnk" -Destination $publicDesktop -Force -ErrorAction SilentlyContinue
          }

          Write-Host "Configuring explicit launcher shortcut targeting Urban VPN..."
          $operaExe = "$env:ProgramFiles\Opera GX\opera.exe"
          if (-not (Test-Path $operaExe)) { $operaExe = "$env:ProgramFiles (x86)\Opera GX\opera.exe" }
          
          # TARGET MODIFICATION: Swapped out Forsaken collab for Urban VPN Store Page + Automation Flags
          $targetUrl = "https://chromewebstore.google.com/detail/urban-vpn-proxy/eppiocemhmnlbhjplcgkofciiegomcon"
          $stealthArgs = "`"$targetUrl`" --no-first-run --disable-blink-features=AutomationControlled --disable-infobars --password-store=basic"

          $WshShell = New-Object -ComObject WScript.Shell
          $Shortcut = $WshShell.CreateShortcut("$publicDesktop\Opera GX Browser.lnk")
          $Shortcut.TargetPath = $operaExe
          $Shortcut.Arguments = $stealthArgs
          $Shortcut.Save()

          Start-Process -FilePath "$publicDesktop\Opera GX Browser.lnk"

      - name: Parse Runtime Requirements
        run: |
          function IntOr($v,$d){ if("$v" -match '^\d+$'){ [int]$v } else { [int]$d } }
          $runtime = IntOr("${{ inputs.runtime_minutes }}",355)
          if ($runtime -gt 360 -or $runtime -lt 1) { $runtime = 355 }
          "RUNTIME_MINUTES=$runtime" | Out-File -Append $env:GITHUB_ENV

      - name: Purge Legacy Machine Registrations
        run: |
          try {
            $auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${{ secrets.API }}:"))
            $tn = [uri]::EscapeDataString("${{ secrets.EMAIL }}")
            $list = Invoke-RestMethod -Uri "https://api.tailscale.com/api/v2/tailnet/$tn/devices" -Headers @{ Authorization = "Basic $auth" }
            foreach($d in $list.devices){
              if ($d.hostname -match '^(bullet|pc)[0-9]*$'){
                Invoke-RestMethod -Method Delete -Uri "https://api.tailscale.com/api/v2/device/$($d.id)" -Headers @{ Authorization = "Basic $auth" } -ErrorAction SilentlyContinue
              }
            }
          } catch {}

      - name: Install & Authenticate Tailscale Network
        run: |
          $ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
          if (-not (Test-Path $ts)) {
            $url = "https://pkgs.tailscale.com/stable/tailscale-setup-1.82.0-amd64.msi"
            $dst = "$env:TEMP\tailscale.msi"
            Invoke-WebRequest -Uri $url -OutFile $dst
            Start-Process msiexec.exe -ArgumentList "/i","`"$dst`"","/quiet","/norestart" -Wait
            Remove-Item $dst -Force
          }
          & $ts logout | Out-Null
          & $ts up --authkey "${{ secrets.AUTH }}" --hostname "pc" --accept-dns=true --accept-routes=true
          $ip4 = & $ts ip -4 | Select-Object -First 1
          Write-Host "Tailscale Dedicated Node IP: $ip4"

      - name: Provision RDP User Identity & Global System Rules
        run: |
          Rename-Computer -NewName "pc" -Force -ErrorAction SilentlyContinue
          
          $u = $env:RDP_USER
          $sec = ConvertTo-SecureString $env:RDP_PASS -AsPlainText -Force
          if (-not (Get-LocalUser -Name $u -EA SilentlyContinue)) {
            New-LocalUser -Name $u -Password $sec -AccountNeverExpires
            Add-LocalGroupMember -Group "Administrators" -Member $u
            Add-LocalGroupMember -Group "Remote Desktop Users" -Member $u
          } else {
            Set-LocalUser -Name $u -Password $sec -AccountNeverExpires
            Enable-LocalUser -Name $u
          }
          Set-ItemProperty "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name fDenyTSConnections -Value 0
          Enable-NetFirewallRule -DisplayGroup "Remote Desktop" | Out-Null

      - name: Structural Window Minimization
        run: |
          $shell = New-Object -ComObject Shell.Application
          $shell.MinimizeAll()

      - name: Connection Keep-Alive Loop
        run: |
          $mins = [int]$env:RUNTIME_MINUTES
          if (-not $mins) { $mins = 355 }
          
          $end = (Get-Date).AddMinutes($mins)
          while ((Get-Date) -lt $end) {
            Write-Host ("Tailscale/RDP Active Engine | Heartbeat " + (Get-Date).ToString("HH:mm:ss") + " ends at " + $end.ToString("HH:mm:ss"))
            Start-Sleep -Seconds 60
          }

      - name: Disconnect Tailscale Node Safely
        if: always()
        run: |
          $ts = "$env:ProgramFiles\Tailscale\tailscale.exe"
          if (Test-Path $ts) {
              Write-Host "Disconnecting machine and logging out of tailnet..."
              & $ts logout | Out-Null
          }
