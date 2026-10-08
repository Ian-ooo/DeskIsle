# 🏝️ DeskIsle · macOS 原生版本目录

> 本目录**不再单独维护说明文档**。
> 全项目统一说明文档请查阅 **[根目录 README.md](../README.md)** —— 功能变更请直接更新该文件。

## 目录内开发文档

- [`PLAN.md`](./PLAN.md)：macOS 原生版里程碑、开发计划与 Electron → 原生 API 映射
- [`FEATURE_GAP.md`](./FEATURE_GAP.md)：Electron 版与原生版功能对照及缺口清单

## 快速构建

```bash
swift build --disable-sandbox   # 编译 Debug
swift test --disable-sandbox    # 回归断言（排版基准 / 拖出发起 / 搜索匹配）
.build/debug/DeskIsle           # 运行调试
bash build-app.sh               # 打包 release 到 dist/DeskIsle.app（内含测试步骤）
```

> ⚠️ 若 `swift build` 秒回「Build complete」却没真的编译，先 `touch Sources/**/*.swift` ——
> 某些编辑器写文件不更新 mtime，SwiftPM 会据此判定无需重编。
