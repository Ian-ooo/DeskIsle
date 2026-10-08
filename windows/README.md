# 🏝️ DeskIsle · Windows 原生版本目录

> 本目录**不再单独维护说明文档**。
> 全项目统一说明文档请查阅 **[根目录 README.md](../README.md)** —— 功能变更请直接更新该文件。

## 工程入口

- `DeskIsle.sln`：Visual Studio 解决方案（Win64）
- `build.bat`：一键打包脚本，产物 `dist\DeskIsle\DeskIsle.exe`
- `DeskIsle/`：.NET 8 WPF 工程（Models / Services / Views / Controls / Native）

## 快速构建

```cmd
build.bat
dotnet publish -c Release -r win-x64 --self-contained false -o "..\dist\DeskIsle"
```
