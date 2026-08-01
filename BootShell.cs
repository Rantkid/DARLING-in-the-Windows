using System;
using System.Diagnostics;
using System.IO;

internal static class BootShell
{
    [STAThread]
    private static int Main(string[] args)
    {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string logPath = Path.Combine(baseDir, "boot-shell.log");

        try
        {
            Log(logPath, "BootShell started.");
            int exitCode = RunBootIntro(baseDir, args, logPath);
            EnsureExplorer(logPath);
            Log(logPath, "BootShell finished. PowerShell exit code: " + exitCode);
            return exitCode;
        }
        catch (Exception ex)
        {
            Log(logPath, "BootShell failed: " + ex);
            EnsureExplorer(logPath);
            return 1;
        }
    }

    private static int RunBootIntro(string baseDir, string[] args, string logPath)
    {
        string scriptPath = Path.Combine(baseDir, "Start-BootIntro.ps1");
        if (!File.Exists(scriptPath))
        {
            throw new FileNotFoundException("Start-BootIntro.ps1 was not found.", scriptPath);
        }

        string powershellExe = Path.Combine(
            Environment.SystemDirectory,
            @"WindowsPowerShell\v1.0\powershell.exe");

        if (!File.Exists(powershellExe))
        {
            throw new FileNotFoundException("powershell.exe was not found.", powershellExe);
        }

        bool force = HasArgument(args, "--force") || HasArgument(args, "-Force");
        string arguments =
            "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File " +
            Quote(scriptPath) +
            " -ShellMode";

        if (force)
        {
            arguments += " -Force";
        }

        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = powershellExe;
        startInfo.Arguments = arguments;
        startInfo.WorkingDirectory = baseDir;
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;

        Log(logPath, "Starting intro script: " + powershellExe + " " + arguments);

        using (Process process = Process.Start(startInfo))
        {
            if (process == null)
            {
                throw new InvalidOperationException("Failed to start PowerShell.");
            }

            process.WaitForExit();
            return process.ExitCode;
        }
    }

    private static void EnsureExplorer(string logPath)
    {
        try
        {
            if (Process.GetProcessesByName("explorer").Length > 0)
            {
                return;
            }

            string explorerExe = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "explorer.exe");

            if (!File.Exists(explorerExe))
            {
                Log(logPath, "explorer.exe was not found: " + explorerExe);
                return;
            }

            ProcessStartInfo startInfo = new ProcessStartInfo();
            startInfo.FileName = explorerExe;
            startInfo.WorkingDirectory = Path.GetDirectoryName(explorerExe);
            startInfo.UseShellExecute = true;

            Process.Start(startInfo);
            Log(logPath, "Started explorer fallback.");
        }
        catch (Exception ex)
        {
            Log(logPath, "Explorer fallback failed: " + ex);
        }
    }

    private static bool HasArgument(string[] args, string expected)
    {
        foreach (string arg in args)
        {
            if (string.Equals(arg, expected, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }

        return false;
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static void Log(string logPath, string message)
    {
        try
        {
            File.AppendAllText(
                logPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff") + " " + message + Environment.NewLine);
        }
        catch
        {
            // Logging must never block login.
        }
    }
}
