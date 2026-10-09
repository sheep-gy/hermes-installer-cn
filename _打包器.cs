// 打包器源码 —— 把 hermes-vpn.ps1 嵌进 Hermes安装加速器.exe
// 重新打包命令（git-bash，先 export MSYS_NO_PATHCONV=1）：
//   csc.exe -nologo -codepage:65001 -target:exe -out:"Hermes安装加速器.exe" \
//     -resource:"hermes-vpn.ps1",hermes_tool.ps1 _打包器.cs
// csc 位置：C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

class HermesTool
{
    static int Main(string[] args)
    {
        try { Console.OutputEncoding = Encoding.GetEncoding(936); } catch { }

        // 把"exe 所在目录"告诉脚本（脚本据此找安装包、写日志）
        string exeDir = "";
        try { exeDir = Path.GetDirectoryName(Assembly.GetExecutingAssembly().Location); } catch { }
        if (!string.IsNullOrEmpty(exeDir))
            Environment.SetEnvironmentVariable("HERMES_TOOL_DIR", exeDir);

        // 把内嵌的 PowerShell 脚本释放到临时目录
        string tmp = Path.Combine(Path.GetTempPath(), "hermes_tool.ps1");
        try
        {
            using (Stream s = Assembly.GetExecutingAssembly().GetManifestResourceStream("hermes_tool.ps1"))
            using (FileStream f = File.Create(tmp))
            {
                if (s == null) { Console.WriteLine("内嵌脚本缺失（打包有误）。"); return 1; }
                s.CopyTo(f);
            }
        }
        catch (Exception e)
        {
            Console.WriteLine("释放脚本失败：" + e.Message);
            return 1;
        }

        StringBuilder a = new StringBuilder();
        a.Append("-NoProfile -ExecutionPolicy Bypass -File \"").Append(tmp).Append("\"");
        foreach (string x in args) a.Append(" ").Append(Quote(x));

        ProcessStartInfo psi = new ProcessStartInfo("powershell.exe", a.ToString());
        psi.UseShellExecute = false;

        int code = 1;
        try
        {
            Process p = Process.Start(psi);
            p.WaitForExit();
            code = p.ExitCode;
        }
        catch (Exception e)
        {
            Console.WriteLine("启动失败：" + e.Message);
            code = 1;
        }
        finally
        {
            try { File.Delete(tmp); } catch { }
        }
        return code;
    }

    static string Quote(string s)
    {
        if (s.IndexOf(' ') < 0 && s.IndexOf('"') < 0) return s;
        return "\"" + s.Replace("\"", "\\\"") + "\"";
    }
}
