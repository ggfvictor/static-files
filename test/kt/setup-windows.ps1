# Scan Setup v0.1 | Windows 10/11 | Windows PowerShell 5.1 (64-bit)
[CmdletBinding()]
param([string]$DesktopPath, [string]$Employee, [switch]$Elevated)
$ErrorActionPreference = 'Stop'
$share = 'scan'
$account = 'scan'
$ruleName = 'ScanSetup-SMB-In-v01'
$tag = 'ScanSetup v0.1 - dedicated scanner account'
function Quote-PS([string]$s) { "'" + $s.Replace("'", "''") + "'" }
function Wait-Exit { [void](Read-Host '按 Enter 退出') }
function New-ScanPassword {
    $bytes = New-Object byte[] 8
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ('Sc9!' + ([BitConverter]::ToString($bytes).Replace('-', '').ToLowerInvariant()))
}
function Is-IPv4([string]$s) {
    if ($s -notmatch '^\d{1,3}(\.\d{1,3}){3}$') { return $false }
    foreach ($part in ($s -split '\.')) { if ([int]$part -gt 255) { return $false } }
    return $true
}
function Select-IP {
    $ips = @(Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.AddressState -eq 'Preferred' -and $_.IPAddress -notmatch '^(127\.|169\.254\.|0\.)'
    } | Where-Object {
        $a = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
        $a -and $a.Status -eq 'Up'
    } | Sort-Object InterfaceAlias,IPAddress)
    if ($ips.Count -eq 0) { throw '未发现有效的活动 IPv4 地址，请先连接办公网。' }
    Write-Host '请选择打印机可访问的办公网络（不要选择 VPN、虚拟网卡）：' -ForegroundColor Cyan
    for ($i=0; $i -lt $ips.Count; $i++) { Write-Host ('  {0}. {1}  {2}/{3}' -f ($i+1),$ips[$i].InterfaceAlias,$ips[$i].IPAddress,$ips[$i].PrefixLength) }
    do { $sel = Read-Host '输入序号（只有一项时可直接回车）'; if (!$sel -and $ips.Count -eq 1) { $sel='1' } } until ($sel -match '^\d{1,4}$' -and [int]$sel -ge 1 -and [int]$sel -le $ips.Count)
    return $ips[([int]$sel-1)]
}
$madeUser = $false; $madeShare = $false; $madeRule = $false; $addedAcl = $false; $configured = $false; $folder = $null; $ace = $null
try {
    if (!$DesktopPath) { $DesktopPath = [Environment]::GetFolderPath('DesktopDirectory') }
    if (!$Employee) { $Employee = $env:USERNAME }
    if (!$DesktopPath -or !(Test-Path -LiteralPath $DesktopPath -PathType Container)) { throw '找不到当前用户桌面目录。请从员工自己的桌面会话运行。' }
    $admin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (!$admin) {
        if ($Elevated) { throw '未取得管理员权限。' }
        Write-Host '配置 SMB 需要管理员权限。请确认 UAC 提示，或由 IT 输入管理员凭据。'
        # Preserve the original employee Desktop even when another account supplies UAC credentials.
        $cmd = '& ' + (Quote-PS $PSCommandPath) + ' -DesktopPath ' + (Quote-PS $DesktopPath) + ' -Employee ' + (Quote-PS $Employee) + ' -Elevated'
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
        $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $exe -Verb RunAs -ArgumentList @('-NoProfile','-STA','-EncodedCommand',$enc) -Wait
        return
    }
    Write-Host "`n=== Scan Setup v0.1 / Windows ===" -ForegroundColor Cyan
    foreach ($cmd in @('Get-LocalUser','New-LocalUser','Get-SmbShare','New-SmbShare','Get-NetIPAddress','New-NetFirewallRule')) { if (!(Get-Command $cmd -ErrorAction SilentlyContinue)) { throw "缺少命令 $cmd。请使用 64 位 Windows PowerShell 5.1。" } }
    if (Get-LocalUser -Name $account -ErrorAction SilentlyContinue) { throw '本机已有 scan 账户。为避免修改已有凭据，本版停止；请联系 IT 核查后再运行。' }
    if (Get-SmbShare -Name $share -ErrorAction SilentlyContinue) { throw '本机已有 scan 共享。本版不会覆盖现有共享，请联系 IT。' }
    if (Get-NetFirewallRule -Name $ruleName -ErrorAction SilentlyContinue) { throw '已有本工具防火墙规则，可能是之前的配置。请联系 IT。' }
    $desktopItem = Get-Item -LiteralPath $DesktopPath -Force
    if ($desktopItem.FullName -notmatch '^[A-Za-z]:\\' -or $desktopItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw '桌面为网络路径或重解析点，请由 IT 检查重定向/云盘配置。' }
    $folder = Join-Path $desktopItem.FullName 'scan'
    if (Test-Path -LiteralPath $folder) {
        $item = Get-Item -LiteralPath $folder -Force
        if (!$item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'scan 路径不是普通文件夹，停止。' }
        if (@(Get-ChildItem -LiteralPath $folder -Force | Select-Object -First 1).Count) { throw '桌面 scan 已有文件，为避免共享旧资料，请由 IT 检查。' }
    }
    $nic = Select-IP
    $ip = $nic.IPAddress
    $profile = Get-NetConnectionProfile -InterfaceIndex $nic.InterfaceIndex -ErrorAction SilentlyContinue | Select-Object -First 1
    if (!$profile -or $profile.NetworkCategory -eq 'Public') { Write-Warning '当前网络不是专用/域网络。工具不会改变网络类型，也不会开放公用网络；可能需要 IT 处理。' }
    $scopeInput = Read-Host '打印机 IPv4（多个用英文逗号分隔；回车=仅本地子网，IT 后续应收紧）'
    $remote = @('LocalSubnet')
    if ($scopeInput.Trim()) {
        $remote = @($scopeInput -split ',' | ForEach-Object { $_.Trim() })
        foreach ($addr in $remote) { if (!(Is-IPv4 $addr)) { throw "无效的打印机 IPv4：$addr" } }
    }
    $label = Read-Host "打印机通讯录显示名（员工姓名，回车=$Employee）"
    if ($label.Trim()) { $Employee = $label.Trim() }
    $svc = Get-CimInstance Win32_Service -Filter "Name='LanmanServer'"
    if (!$svc -or $svc.StartMode -eq 'Disabled') { throw 'Windows Server (LanmanServer) 服务不可用或已被禁用，请 IT 检查策略。' }
    Write-Host "`n将创建：$folder；共享 scan；非管理员本地账户 scan；TCP 445 入站范围：$($remote -join ', ')"
    if ((Read-Host '确认配置？输入 Y 继续') -notmatch '^[Yy]$') { throw '用户取消，未执行配置。' }
    if (!(Test-Path -LiteralPath $folder)) { New-Item -ItemType Directory -Path $folder | Out-Null }
    if ($svc.StartMode -ne 'Auto') { Set-Service -Name LanmanServer -StartupType Automatic }
    Start-Service -Name LanmanServer
    $password = New-ScanPassword
    $secure = ConvertTo-SecureString $password -AsPlainText -Force
    $user = New-LocalUser -Name $account -Password $secure -Description $tag -PasswordNeverExpires -UserMayNotChangePassword -AccountNeverExpires
    $madeUser = $true
    $sid = $user.SID
    $principal = "$env:COMPUTERNAME\$account"
    $admins = ([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')).Translate([Security.Principal.NTAccount]).Value
    $acl = Get-Acl -LiteralPath $folder
    $ace = [System.Security.AccessControl.FileSystemAccessRule]::new($sid, [System.Security.AccessControl.FileSystemRights]::Modify, ([System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [System.Security.AccessControl.InheritanceFlags]::ObjectInherit), [System.Security.AccessControl.PropagationFlags]::None, [System.Security.AccessControl.AccessControlType]::Allow)
    $acl.AddAccessRule($ace)
    Set-Acl -LiteralPath $folder -AclObject $acl
    $addedAcl = $true
    New-SmbShare -Name $share -Path $folder -ChangeAccess $principal -FullAccess $admins -Description 'ScanSetup v0.1' | Out-Null
    $madeShare = $true
    # Fail closed if the returned share grants access to any unexpected identity.
    $allowedSids = @($sid.Value,'S-1-5-32-544')
    $shareAccess = @(Get-SmbShareAccess -Name $share)
    foreach ($entry in $shareAccess) {
        if ($entry.AccessControlType -eq 'Allow') {
            $entrySid = ([Security.Principal.NTAccount]::new($entry.AccountName)).Translate([Security.Principal.SecurityIdentifier]).Value
            if ($entrySid -notin $allowedSids) { throw "发现意外的共享权限：$($entry.AccountName)" }
        }
    }
    New-NetFirewallRule -Name $ruleName -DisplayName 'ScanSetup SMB scanner (TCP 445)' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -Profile Domain,Private -InterfaceAlias $nic.InterfaceAlias -RemoteAddress $remote | Out-Null
    $madeRule = $true
    $configured = $true
    $listening = @(Get-NetTCPConnection -LocalPort 445 -State Listen -ErrorAction SilentlyContinue).Count -gt 0
    $status = if ($listening -and $profile -and $profile.NetworkCategory -ne 'Public') { '本机共享已配置，445 监听正常；等待打印机实测' } else { '本机共享已配置；网络配置/445 监听待 IT 检查' }
    try { if ((Get-SmbServerConfiguration).EnableSMB1Protocol) { Write-Warning '系统已启用 SMB1（非本脚本开启），建议 IT 核查并优先使用 SMB2/3。' } } catch { Write-Warning '无法读取现有 SMB 协议状态。' }
    $report = @"
【扫描到个人电脑 - 配置信息】
员工姓名：$Employee
操作系统：Windows
计算机名：$env:COMPUTERNAME
服务器 IP：$ip
端口：445 (TCP)
共享名称：scan
子目录：无（共享根目录）
UNC 路径：\\$ip\scan
SMB 用户名：$account
完整用户名：$principal
SMB 密码：$password
状态：$status
"@
    Write-Host "`n$report`n" -ForegroundColor Cyan
    try { Set-Clipboard -Value $report -ErrorAction Stop; Write-Host '已复制全部配置信息。请通过单位批准的安全渠道发送给 IT，发送后清除剪贴板。' -ForegroundColor Green }
    catch { Write-Warning '自动复制失败，请手动选择上方信息并复制。' }
} catch {
    Write-Host "`n配置未完成：$($_.Exception.Message)" -ForegroundColor Red
    if (!$configured) {
        if ($madeRule) { try { Remove-NetFirewallRule -Name $ruleName } catch { Write-Warning '防火墙规则清理失败，需 IT 处理。' } }
        if ($madeShare) { try { Remove-SmbShare -Name $share -Force } catch { Write-Warning '共享清理失败，需 IT 处理。' } }
        if ($addedAcl -and $folder -and $ace) { try { $a=Get-Acl -LiteralPath $folder; $a.RemoveAccessRuleSpecific($ace); Set-Acl -LiteralPath $folder -AclObject $a } catch { Write-Warning 'NTFS 权限清理失败，需 IT 处理。' } }
        if ($madeUser) { try { Remove-LocalUser -Name $account } catch { Write-Warning '新账户清理失败，需 IT 处理。' } }
        Write-Warning '若已创建空 scan 文件夹或启动 SMB 服务，将保留；不会删除员工文件。'
    }
} finally {
    if ($Elevated -or $admin) { Wait-Exit }
}
