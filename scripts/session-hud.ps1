# =============================================================================
# Claude Session HUD — 懸浮顯示所有正在跑的 Claude Code session（跨所有專案）
#
# 資料源：claude agents --json（不分專案，全域）
# 必須用 Windows PowerShell 5.1 且 -STA 執行（WPF 需求）
#   powershell.exe -NoProfile -STA -File session-hud.ps1
# 建議用同目錄的 start-hud.vbs 啟動，才不會閃出主控台視窗。
# =============================================================================

# 刻意不開 StrictMode：WPF 事件處理器裡的嚴格模式錯誤是靜默的，極難除錯
$ErrorActionPreference = 'Stop'

# 必須在載入 WPF／建立任何視窗「之前」宣告 DPI 感知。
# 否則在 125% 縮放的螢幕上，WPF 以邏輯單位排版（每列 39.96）但視窗實際像素沒跟著放大，
# 內容會比視窗高 1.25 倍，最後一列永遠被切掉。
Add-Type @"
using System; using System.Runtime.InteropServices;
public class Dpi {
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
  public static string Apply() {
    try { if (SetProcessDpiAwarenessContext(new IntPtr(-4))) return "PerMonitorV2"; } catch { }
    try { if (SetProcessDPIAware()) return "System"; } catch { }
    return "none";
  }
}
"@
$script:DpiMode = [Dpi]::Apply()

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

$script:Root = Split-Path -Parent $MyInvocation.MyCommand.Path

# 執行期狀態一律寫到使用者家目錄，不寫回腳本所在資料夾。
# 當成 Claude Code 外掛安裝時腳本住在外掛快取目錄，更新外掛會整個換掉那個目錄，
# 寫在那裡的視窗位置與 log 都會不見。
$script:StateDir = Join-Path $env:USERPROFILE '.claude\session-hud'
New-Item -ItemType Directory -Force -Path $StateDir -ErrorAction SilentlyContinue | Out-Null
$script:PosFile = Join-Path $StateDir 'hud-pos.json'

# 介面字型：必須含 CJK 字符集，否則中文標籤在這個宿主底下會整片空白（不是豆腐字）。
# 列成後備鏈，讓非繁中系統（簡中／日文／純英文）也有字可用。
$script:UI_FONT = 'Microsoft JhengHei UI, Microsoft YaHei UI, Meiryo UI, Segoe UI'

$script:ClaudeExe = (Get-Command claude -ErrorAction SilentlyContinue).Source
if (-not $ClaudeExe) {
    foreach ($c in @("$env:USERPROFILE\.local\bin\claude.exe",
                     "$env:LOCALAPPDATA\Programs\claude\claude.exe",
                     "$env:APPDATA\npm\claude.cmd")) {
        if (Test-Path $c) { $script:ClaudeExe = $c; break }
    }
}
if (-not $ClaudeExe) {
    [System.Windows.MessageBox]::Show(
        "找不到 claude 執行檔。請確認 Claude Code CLI 已安裝且在 PATH 上。",
        'Claude Session HUD') | Out-Null
    exit 1
}

# --- Win32：找出並聚焦目標視窗 ------------------------------------------------
Add-Type @"
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class HudWin {
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern int  GetWindowTextLength(IntPtr h);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  delegate bool EnumProc(IntPtr h, IntPtr p);

  public class Win { public IntPtr Handle; public string Title; }

  public static List<Win> Visible() {
    var r = new List<Win>();
    EnumWindows((h, p) => {
      if (!IsWindowVisible(h)) return true;
      int len = GetWindowTextLength(h); if (len == 0) return true;
      var sb = new StringBuilder(len + 1); GetWindowText(h, sb, sb.Capacity);
      r.Add(new Win { Handle = h, Title = sb.ToString() });
      return true;
    }, IntPtr.Zero);
    return r;
  }

  public static void Focus(IntPtr h) {
    if (IsIconic(h)) ShowWindow(h, 9); // SW_RESTORE
    SetForegroundWindow(h);
  }

  [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
}
"@

# 依專案資料夾名找出最合適的編輯器視窗。
# 用分數而不是單純 contains：資料夾名可能互為子字串（例如 "api" 與 "api-worker"），
# 單純比對包含關係會挑到錯的視窗。
function Find-WindowForProject([string]$baseName) {
    $best = $null; $bestScore = 0
    foreach ($w in [HudWin]::Visible()) {
        $t = $w.Title
        $score = 0
        if ($t -like "* - $baseName - *")  { $score = 3 }   # 一般資料夾
        elseif ($t -like "* - $baseName (*") { $score = 2 } # 工作區
        elseif ($t -like "*$baseName*")      { $score = 1 } # 寬鬆
        if ($score -gt $bestScore) { $bestScore = $score; $best = $w }
    }
    return $best
}

# --- 背景輪詢：claude agents --json 要 ~640ms，絕不能跑在 UI 執行緒上 ----------
$script:Sync = [hashtable]::Synchronized(@{
    Sessions = @()
    Error    = $null
    Stamp    = 0
})

$poller = [powershell]::Create()
$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'MTA'
$rs.ThreadOptions  = 'ReuseThread'
$rs.Open()
$rs.SessionStateProxy.SetVariable('Sync', $Sync)
$rs.SessionStateProxy.SetVariable('ClaudeExe', $ClaudeExe)
$poller.Runspace = $rs
[void]$poller.AddScript({
    # 對話標題來自轉錄檔 ~/.claude/projects/<正規化cwd>/<sessionId>.jsonl 裡的
    # {"type":"ai-title","sessionId":...,"aiTitle":...} 記錄，每輪都會追加一筆，取最後一筆。
    # 目錄名的正規化規則：cwd 裡所有非英數字元一律換成 "-"。
    $titleCache = @{}

    function Resolve-TranscriptPath([string]$cwd, [string]$sessionId) {
        $safe = ($cwd -replace '[^A-Za-z0-9]', '-')
        $p = Join-Path $env:USERPROFILE ".claude\projects\$safe\$sessionId.jsonl"
        if (Test-Path $p) { return $p }
        # 推導失敗就退回搜尋（例如 cwd 大小寫或路徑形式不同）
        $root = Join-Path $env:USERPROFILE '.claude\projects'
        $hit = Get-ChildItem -Path $root -Filter "$sessionId.jsonl" -Recurse -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($hit) { return $hit.FullName }
        return $null
    }

    function Get-AiTitle([string]$path) {
        try {
            $fi = New-Object System.IO.FileInfo $path
            if (-not $fi.Exists) { return '' }
            # 轉錄檔會長到很大，只讀尾端；標題每輪都寫一次，尾端一定找得到。
            $take = [Math]::Min($fi.Length, 262144)
            # 必須用 FileShare.ReadWrite——Claude Code 正開著這個檔在寫入。
            $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                    [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
            try {
                [void]$fs.Seek($fi.Length - $take, [System.IO.SeekOrigin]::Begin)
                $buf = New-Object byte[] $take
                [void]$fs.Read($buf, 0, $take)
            } finally { $fs.Dispose() }

            $lines = ([System.Text.Encoding]::UTF8.GetString($buf)) -split "`n"
            for ($i = $lines.Count - 1; $i -ge 0; $i--) {
                if ($lines[$i] -notlike '*"ai-title"*') { continue }
                try { $o = $lines[$i] | ConvertFrom-Json } catch { continue }
                if ($o.aiTitle) { return [string]$o.aiTitle }
            }
        } catch { }
        return ''
    }

    while ($true) {
        try {
            $raw = & $ClaudeExe agents --json 2>$null | Out-String
            $list = if ($raw.Trim()) { @($raw | ConvertFrom-Json) } else { @() }

            # 所有檔案 I/O 都在這個背景 runspace 做，UI 執行緒不碰磁碟。
            $out = New-Object System.Collections.Generic.List[object]
            foreach ($s in $list) {
                $title = ''
                $tp = Resolve-TranscriptPath $s.cwd $s.sessionId
                if ($tp) {
                    $fi = New-Object System.IO.FileInfo $tp
                    $stamp = "$($fi.Length):$($fi.LastWriteTimeUtc.Ticks)"
                    $c = $titleCache[$s.sessionId]
                    if ($c -and $c.Stamp -eq $stamp) {
                        $title = $c.Title
                    } else {
                        $title = Get-AiTitle $tp
                        $titleCache[$s.sessionId] = @{ Stamp = $stamp; Title = $title }
                    }
                }
                $out.Add([PSCustomObject]@{
                    Proj    = (Split-Path $s.cwd -Leaf)
                    SName   = $s.name
                    Started = [double]$s.startedAt
                    SessId  = [string]$s.sessionId
                    Title   = $title
                })
            }
            $Sync.Sessions = $out.ToArray()
            $Sync.Error = $null
        } catch {
            $Sync.Error = $_.Exception.Message
        }
        $Sync.Stamp = [DateTime]::UtcNow.Ticks
        Start-Sleep -Seconds 3
    }
})
[void]$poller.BeginInvoke()

# --- 視窗外殼 ----------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Claude Session HUD"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent"
        Topmost="True" ShowInTaskbar="False" Height="200"
        Width="320" ResizeMode="NoResize">
  <Border x:Name="RootBorder" HorizontalAlignment="Left" CornerRadius="10" Background="#F21B1B1F" BorderBrush="#33FFFFFF" BorderThickness="1">
    <Grid Margin="0,0,0,8">
      <Grid.RowDefinitions>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="Auto"/>
        <RowDefinition Height="*"/>
        <RowDefinition Height="Auto"/>
      </Grid.RowDefinitions>
      <Grid x:Name="HeaderBar" Grid.Row="0" Background="#00000000" Margin="12,9,8,7">
        <TextBlock x:Name="HeaderText" Text="Claude Sessions" Foreground="#FFE8E8EC"
                   FontFamily="Segoe UI" FontSize="12" FontWeight="SemiBold" VerticalAlignment="Center"/>
        <TextBlock x:Name="CloseBtn" Text="&#x2715;" Foreground="#FF8A8A93" FontFamily="Segoe UI" FontSize="12"
                   HorizontalAlignment="Right" VerticalAlignment="Center" Cursor="Hand" Padding="6,2"/>
      </Grid>
      <Border Grid.Row="1" Height="1" Background="#22FFFFFF" Margin="10,0,10,4"/>
      <ScrollViewer x:Name="RowScroll" Grid.Row="2" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled">
        <StackPanel x:Name="Rows" Margin="6,2,6,0"/>
      </ScrollViewer>
      <TextBlock x:Name="StatusText" Grid.Row="3" Text="" Foreground="#FF6E6E77" FontFamily="Microsoft JhengHei UI, Microsoft YaHei UI, Meiryo UI, Segoe UI" FontSize="10"
                 Margin="12,6,12,0" TextWrapping="Wrap"/>
    </Grid>
  </Border>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$win    = [Windows.Markup.XamlReader]::Load($reader)

$HeaderBar  = $win.FindName('HeaderBar')
$HeaderText = $win.FindName('HeaderText')
$CloseBtn   = $win.FindName('CloseBtn')
$Rows       = $win.FindName('Rows')
$RowScroll  = $win.FindName('RowScroll')
$RootBorder = $win.FindName('RootBorder')
$StatusText = $win.FindName('StatusText')

# 排版診斷：把每次調整高度用到的數字寫出來，方便驗證真的抓對了。
$script:DiagFile = Join-Path $StateDir 'layout-diag.log'
Remove-Item $DiagFile -ErrorAction SilentlyContinue   # 每次啟動重來，不要無限累積
function Write-Diag([string]$line) {
    try { Add-Content -Path $DiagFile -Value $line -Encoding UTF8 } catch { }
}

# 還原上次位置，預設右下角
$wa = [System.Windows.SystemParameters]::WorkArea
if (Test-Path $PosFile) {
    try {
        $p = Get-Content $PosFile -Raw | ConvertFrom-Json
        $win.Left = [double]$p.Left; $win.Top = [double]$p.Top
    } catch { $win.Left = $wa.Right - 340; $win.Top = $wa.Bottom - 320 }
} else {
    $win.Left = $wa.Right - 340; $win.Top = $wa.Bottom - 320
}

$HeaderBar.Add_MouseLeftButtonDown({ $win.DragMove() })
$CloseBtn.Add_MouseLeftButtonUp({ $win.Close() })

# SizeToContent="Height" 讓實際高度要等排版完才知道；而且 session 一多高度還會再變，
# 所以夾回工作區的動作要在「首次渲染」和「每次尺寸變動」都做一次，
# 否則列變多時視窗底部會滑到工作列底下。
function Clamp-ToWorkArea {
    $a = [System.Windows.SystemParameters]::WorkArea
    if ($win.Left + $win.Width        -gt $a.Right)  { $win.Left = $a.Right  - $win.Width - 8 }
    if ($win.Top  + $win.ActualHeight -gt $a.Bottom) { $win.Top  = $a.Bottom - $win.ActualHeight - 8 }
    if ($win.Left -lt $a.Left) { $win.Left = $a.Left + 8 }
    if ($win.Top  -lt $a.Top)  { $win.Top  = $a.Top  + 8 }
}
$script:HudHwnd    = [IntPtr]::Zero
$script:RowProjects = @()     # 每一列對應的專案名，順序同畫面
$script:RowsTopPx   = 0       # 列區頂端（視窗內實體像素）
$script:RowPitchPx  = 0       # 每列高度（實體像素）

$win.Add_ContentRendered({
    Clamp-ToWorkArea
    $script:HudHwnd = (New-Object System.Windows.Interop.WindowInteropHelper $win).Handle
})

# 用實體螢幕座標自己判斷點到第幾列。
# 為什麼不用 WPF 的命中測試：這個宿主的滑鼠座標是實體像素、但版面座標是 DIP，
# 兩者差一個 scale，結果就是「點第 5 列會觸發第 6 列」，最後一列則完全點不到。
$win.Add_MouseLeftButtonUp({
    try {
        if ($RowPitchPx -le 0 -or $RowProjects.Count -eq 0) { return }
        if ($HudHwnd -eq [IntPtr]::Zero) { return }
        $pt = New-Object HudWin+POINT
        if (-not [HudWin]::GetCursorPos([ref]$pt)) { return }
        $rc = New-Object HudWin+RECT
        if (-not [HudWin]::GetWindowRect($HudHwnd, [ref]$rc)) { return }

        $localY = $pt.Y - $rc.T
        $idx = [int][Math]::Floor(($localY - $RowsTopPx) / $RowPitchPx)
        if ($idx -lt 0 -or $idx -ge $RowProjects.Count) { return }   # 點在標題列或狀態列，忽略

        $proj = $RowProjects[$idx]
        $target = Find-WindowForProject $proj
        if ($target) {
            [HudWin]::Focus($target.Handle)
            Write-Diag ("CLICK idx={0} proj={1} -> `"{2}`"" -f $idx, $proj, $target.Title)
        } else {
            Write-Diag ("CLICK idx={0} proj={1} -> 找不到對應視窗" -f $idx, $proj)
        }
    } catch {
        Write-Diag ("CLICK 例外: {0}" -f $_.Exception.Message)
    }
})

# 依「量到的實際內容高度」設定視窗高度。
# 不用 SizeToContent="Height"：實測在 AllowsTransparency + NoResize 這個組合下，
# 首次排版後就不再跟著內容變高，第 6 筆之後的 session 會看不到。
$MAX_H    = 620
$CHROME   = 62    # 標題列＋分隔線＋狀態列＋邊距
$ROW_H    = 50    # 只在量測失敗時當備援
$DESIGN_W = 430   # 設計寬度；Window.Width 與根 Border 的 MaxWidth 都取這個數（標題較長，需要空間）

$script:NeedResize = $false

# 兩段式定高：這一輪把列加進去，下一輪（700ms 後）才依「已排版完成的真實高度」調整視窗。
# 不在同一輪算高度的原因：不管是 DesiredSize 還是 ActualHeight，在剛加完子元素的當下
# 拿到的都還是上一輪的排版結果，永遠少一列；對容器手動 Measure 也會吃到 WPF 的排版快取。
# 慢一個 tick 對使用者是看不出來的，但數字保證正確。
# 每輪都跑，只在高度真的不對時才調整——自我校正，就算某輪排版值還沒穩定，下一輪也會收斂。
function Apply-PendingResize {
    # ExtentHeight = ScrollViewer 的「內容總高」，是唯一不受目前 viewport 影響的權威值。
    # Rows.ActualHeight 會被 viewport 夾住（等於可視區高度），拿它算會永遠少一列。
    if ($LastStamp -eq -1) { return }   # 還沒收到第一筆資料，別先縮成最小高度閃一下
    $ext = $RowScroll.ExtentHeight      # 內容總高，單位是 DIP（邏輯單位）
    if ($ext -le 0) { return }

    # 單位陷阱：在這個宿主底下 Window.Height 設多少就是多少「實體像素」，
    # 但 WPF 的排版量測值（ExtentHeight／ViewportHeight）是 DIP。
    # 125% 縮放時兩者差 1.25 倍，直接相加會永遠少算最後一列。
    $scale = 1.0
    try { $scale = [System.Windows.PresentationSource]::FromVisual($win).CompositionTarget.TransformToDevice.M11 } catch { }
    if ($scale -le 0) { $scale = 1.0 }

    # 寬度也要換算，理由跟高度一樣：Width 給的是實體像素，WPF 卻用 Width/scale 當 DIP 排版。
    # 不修的話 320 只會換到 256 DIP 的排版寬度，最右邊的狀態文字整個被切到視窗外。
    # 寬度：Window.Width 是實體像素，但內容以 DIP 排版、渲染時會乘上 scale。
    # 所以可用的版面寬度只有 Width/scale DIP，超出就被裁掉（狀態文字消失就是這樣來的）。
    # 用「固定 Width」而不是 MaxWidth：MaxWidth 只設上限，內容會縮到比視窗窄，右邊留一條空白。
    if ([Math]::Abs($DESIGN_W - $win.Width) -gt 1) { $win.Width = $DESIGN_W }
    $rootDip = $DESIGN_W / $scale
    if ([double]::IsNaN($RootBorder.Width) -or [Math]::Abs($rootDip - $RootBorder.Width) -gt 1) {
        $RootBorder.Width = $rootDip
    }

    # 順便更新點擊要用的列區幾何（實體像素），每輪都算，不受下面的提前 return 影響。
    $n = $Rows.Children.Count
    if ($n -gt 0) {
        $script:RowPitchPx = ($ext * $scale) / $n
        try {
            $origin = [System.Windows.Point]::new([double]0, [double]0)
            $script:RowsTopPx = ($RowScroll.TranslatePoint($origin, $win)).Y * $scale
        } catch { }
    }

    # chrome 全部在 DIP 世界裡算，最後才換算成實體像素。
    # 絕對不能用 (win.Height - viewport) 反推：viewport 是由 win.Height 決定的，
    # 會形成回饋迴圈——實測 chrome 會一路崩塌成 37.8 → 3.2 → 12.0 → 9.8，視窗越縮越小。
    # 這裡改用「不參照 win.Height」的量法：上緣偏移＋下方剩餘，兩者都只跟版面有關。
    $topDip = 0.0
    try {
        $origin2 = [System.Windows.Point]::new([double]0, [double]0)
        $topDip = ($RowScroll.TranslatePoint($origin2, $win)).Y
    } catch { }
    $botDip = $win.ActualHeight - $topDip - $RowScroll.ActualHeight
    if ($botDip -lt 0) { $botDip = 0 }
    $chromeDip = $topDip + $botDip
    if ($chromeDip -le 0 -or $chromeDip -gt 200) { $chromeDip = $CHROME }

    $target = [Math]::Max(96, [Math]::Min($MAX_H, ($ext + $chromeDip) * $scale))
    if ([Math]::Abs($target - $win.Height) -le 1) { return }
    Write-Diag ("scale={0} rows={1} ext={2} topDip={3} botDip={4} winAH={5} svAH={6} winH={7} -> {8}" -f `
        $scale, $Rows.Children.Count, $ext, $topDip, $botDip, $win.ActualHeight, $RowScroll.ActualHeight, $win.Height, $target)
    $win.Height = $target
    Clamp-ToWorkArea
}

# --- 狀態 --------------------------------------------------------------------
# 狀態由 ~/.claude/settings.json 的全域 hooks 寫進 ~/.claude/session-status/<sessionId>.json
# （見同目錄的 status-hook.cjs）。因為掛在全域設定，任何專案的 session 都會自動有狀態。
# 沒有檔案 = unknown：多半是這個 session 在 hooks 裝好之前就已經開著了。
$script:StatusDir = Join-Path $env:USERPROFILE '.claude\session-status'

$STATUS_STYLE = @{
    working = @{ Color = '#FF9ECE6A'; Label = '執行中' }
    waiting = @{ Color = '#FFE0AF68'; Label = '等你'   }
    idle    = @{ Color = '#FF6E7681'; Label = '閒置'   }
    unknown = @{ Color = '#FF3F3F48'; Label = '未知'   }
}

function Get-SessionStatus([string]$sessionId) {
    if ([string]::IsNullOrWhiteSpace($sessionId)) { return 'unknown' }
    try {
        $f = Join-Path $StatusDir ($sessionId + '.json')
        if (-not (Test-Path $f)) { return 'unknown' }
        $j = Get-Content $f -Raw -ErrorAction Stop | ConvertFrom-Json
        $s = [string]$j.status
        if ($STATUS_STYLE.ContainsKey($s)) { return $s }
    } catch { }
    return 'unknown'
}

# --- 列的建構 ----------------------------------------------------------------

function New-SessionRow($projectName, $sessionName, $title, $uptime, $status) {
    $style    = $STATUS_STYLE[$status]
    if (-not $style) { $style = $STATUS_STYLE['unknown'] }
    $colorHex = $style.Color
    $border = New-Object Windows.Controls.Border
    $border.CornerRadius = New-Object Windows.CornerRadius 6
    $border.Padding      = New-Object Windows.Thickness 8, 5, 8, 5
    $border.Margin       = New-Object Windows.Thickness 0, 1, 0, 1
    $border.Background   = [Windows.Media.Brushes]::Transparent
    $border.Cursor       = [Windows.Input.Cursors]::Hand
    $border.Tag          = $projectName

    # 用 DockPanel 而不是 Grid(Auto,*,Auto)：Grid 的星號欄會被 StackPanel 的期望寬度撐大
    # （TextTrimming 不會縮小期望寬度），把右邊的 Auto 欄整個擠出可視範圍，狀態文字就消失了。
    # DockPanel 先配置 Dock 過的子元素，靠右的一定拿得到空間。
    $dock = New-Object Windows.Controls.DockPanel
    $dock.LastChildFill = $true

    $dot = New-Object Windows.Shapes.Ellipse
    $dot.Width = 7; $dot.Height = 7
    $dot.Margin = New-Object Windows.Thickness 0, 0, 8, 0
    $dot.VerticalAlignment = 'Center'
    $dot.Fill = (New-Object Windows.Media.BrushConverter).ConvertFrom($colorHex)
    [Windows.Controls.DockPanel]::SetDock($dot, 'Left')

    $stack = New-Object Windows.Controls.StackPanel

    # 第一行放對話標題——那才是能認出「這個 session 在做什麼」的資訊。
    # 還沒產生標題（剛開的 session）就退回顯示 session 代號。
    $t1 = New-Object Windows.Controls.TextBlock
    $t1.Text = if ([string]::IsNullOrWhiteSpace($title)) { $sessionName } else { $title }
    $t1.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFrom('#FFE8E8EC')
    $t1.FontFamily = $UI_FONT; $t1.FontSize = 12
    $t1.TextTrimming = 'CharacterEllipsis'

    $t2 = New-Object Windows.Controls.TextBlock
    $t2.Text = "$projectName · $sessionName · $uptime"
    $t2.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFrom('#FF7A7A85')
    $t2.FontFamily = 'Consolas'; $t2.FontSize = 10
    $t2.TextTrimming = 'CharacterEllipsis'

    [void]$stack.Children.Add($t1); [void]$stack.Children.Add($t2)

    # 右欄放狀態文字，顏色跟圓點一致——只靠顏色分辨對色覺障礙不友善，也記不住。
    $t3 = New-Object Windows.Controls.TextBlock
    $t3.Text = $style.Label
    $t3.Foreground = (New-Object Windows.Media.BrushConverter).ConvertFrom($colorHex)
    # 必須指定含中文字符集的字型：Segoe UI 沒有中文，而這個宿主不會做字型後備，
    # 結果是中文字「完全不渲染」（不是豆腐字，是整片空白），非常難察覺。
    $t3.FontFamily = $UI_FONT; $t3.FontSize = 10
    $t3.VerticalAlignment = 'Center'
    $t3.Margin = New-Object Windows.Thickness 8, 0, 0, 0
    [Windows.Controls.DockPanel]::SetDock($t3, 'Right')

    # 加入順序就是配置順序：先左邊圓點、再右邊狀態，最後才是會填滿剩餘空間的 stack
    [void]$dock.Children.Add($dot); [void]$dock.Children.Add($t3); [void]$dock.Children.Add($stack)
    $border.Child = $dock

    $hoverBrush = (New-Object Windows.Media.BrushConverter).ConvertFrom('#18FFFFFF')
    $border.Add_MouseEnter({ $this.Background = $hoverBrush }.GetNewClosure())
    $border.Add_MouseLeave({ $this.Background = [Windows.Media.Brushes]::Transparent })
    # 點擊「不」綁在列上——WPF 在這個宿主的命中測試偏了一個 DPI 倍率（點 A 列會觸發 B 列）。
    # 改由視窗層的 Invoke-RowHit 用實體螢幕座標自己算是第幾列。

    return $border
}

# 跨 runspace 傳回來的陣列會被包成「單一元素、內容是整個陣列」的形狀：
#   $v.Count            -> 1        （所以標題數字曾經恆為 1）
#   foreach ($x in $v)  -> 只跑 1 圈，$x 是整個陣列（所以 [double]$x.startedAt 會爆）
#   $v | cmdlet         -> 卻會被展開成 N 筆（所以列數看起來又是對的）
# 這裡一次攤平，後面就能當成正常陣列用。
function Expand-Sessions($value) {
    $out = New-Object System.Collections.Generic.List[object]
    foreach ($item in $value) {
        if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) {
            foreach ($inner in $item) { $out.Add($inner) }
        } else {
            $out.Add($item)
        }
    }
    return $out.ToArray()
}

function Format-Uptime([double]$startedAtMs) {
    $span = [DateTime]::UtcNow - [DateTimeOffset]::FromUnixTimeMilliseconds([long]$startedAtMs).UtcDateTime
    if ($span.TotalMinutes -lt 1)  { return '<1m' }
    if ($span.TotalHours   -lt 1)  { return '{0}m' -f [int]$span.TotalMinutes }
    if ($span.TotalDays    -lt 1)  { return '{0}h{1:d2}' -f [int]$span.TotalHours, $span.Minutes }
    return '{0}d' -f [int]$span.TotalDays
}

# --- UI 更新迴圈（輕量，只讀共享表） ------------------------------------------
$script:LastStamp = -1

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(700)
$timer.Add_Tick({
    Apply-PendingResize
    if ($Sync.Stamp -eq $LastStamp) { return }
    $script:LastStamp = $Sync.Stamp

    $Rows.Children.Clear()
    $sessions = @(Expand-Sessions $Sync.Sessions | Where-Object { $null -ne $_ })

    if ($Sync.Error) {
        $HeaderText.Text = 'Claude Sessions — 錯誤'
        $StatusText.Text = $Sync.Error
        return
    }

    $shown = 0
    # 先投影成具名屬性再排序。
    # 不用 Sort-Object 的 script-block 運算式（@{Expression={...}}）：在這條資料路徑上它
    # 會靜默失效、原封不動回傳輸入順序，同專案的 session 就不會排在一起。
    # Proj/SName/Started/SessId/Title 已由背景 poller 準備好，這裡只補上狀態（讀小檔，很快）。
    $projected = foreach ($s in $sessions) {
        [PSCustomObject]@{
            Proj    = $s.Proj
            SName   = $s.SName
            Started = $s.Started
            Title   = $s.Title
            Status  = (Get-SessionStatus $s.SessId)
        }
    }
    $ordered = @($projected | Sort-Object -Property Proj, Started)
    $projList = New-Object System.Collections.Generic.List[string]

    foreach ($s in $ordered) {
        $proj = $s.Proj
        $row = New-SessionRow $proj $s.SName $s.Title (Format-Uptime $s.Started) $s.Status
        [void]$Rows.Children.Add($row)
        $projList.Add($proj)
        $shown++
    }

    # 數字取自「實際畫出來的列數」，而不是集合的 .Count。
    # 跨 runspace 傳來的陣列在 5.1 底下 .Count 會回 1（PSObject 包裝），但列舉是正常的。
    $HeaderText.Text = "Claude Sessions ({0})" -f $shown
    $StatusText.Text = if ($shown -eq 0) { '目前沒有執行中的 session' } else { '' }
    $script:RowProjects = $projList.ToArray()
    $script:NeedResize = $true
})
$timer.Start()

# --- 收尾 --------------------------------------------------------------------
$win.Add_Closed({
    $timer.Stop()
    try { @{ Left = $win.Left; Top = $win.Top } | ConvertTo-Json | Set-Content -Path $PosFile -Encoding UTF8 } catch { }
    try { $poller.Stop(); $poller.Dispose(); $rs.Close(); $rs.Dispose() } catch { }
})

[void]$win.ShowDialog()
