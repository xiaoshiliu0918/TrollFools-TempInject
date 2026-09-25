# TrollFools 魔改版 —— 临时注入（TempInject）tipa

## 效果

- 打开本 tipa → 选目标 App → 点 **临时注入并启动**（或选好插件后一键注入）
- 自动注入 dylib 并**跳转到目标 App**，插件立即生效
- **退出目标 App 后，看门狗自动还原 App（弹出注入）**
- 之后直接打开目标 App = 干净原版；想再带插件，必须回本 tipa 再点一次注入

## 原理

```
[tipa UI] 临时注入并启动
   1. InjectorV3 原位注入 (shouldPersist: false)
      - 拷贝插件到目标 App/Frameworks/
      - insert_dylib 写 LC_LOAD_DYLIB (@rpath/xxx.dylib → @executable_path/Frameworks)
      - ldid 伪签 + ct_bypass CoreTrust 绕过
   2. 写会话状态 /var/mobile/Library/TrollFools/TempInject/<bid>/state.json
   3. posix_spawn 脱离式看门狗：trollfoolscli watch <bid>
      - 与 UI 进程分离，tipa 被杀/挂起均不影响
      - Phase1: sysctl(KERN_PROC_ALL) 轮询等目标进程出现（默认最长 600s）
      - Phase2: 轮询等目标进程退出
      - Phase3: optool 移除 load command + 删插件文件 + ct_bypass 重签还原
   4. LSApplicationWorkspace.openApplication 自动跳转目标 App
```

孤儿自愈：tipa 启动时扫描 TempInject 目录，看门狗已死但注入残留的会话会被自动还原，
保证临时注入永远不会"漏"成持久注入。

## 改动清单

| 文件 | 改动 |
|---|---|
| `TrollFools/CLI/CmdEject.swift` | 新增 `CmdWatch` 看门狗子命令（进程轮询 + 定向/全量还原） |
| `TrollFools/CLI/Entry.swift` | 注册 `watch` 子命令 |
| `TrollFools/Constants.swift` | 新增 `tempInjectRootURL` 会话状态根目录 |
| `TrollFools/InjectView.swift` | 注入分支支持 `tempMode`（不持久化 + 起看门狗 + 跳转）；新增 `TempInjectManager` |
| `TrollFools/OptionView.swift` | 目标 App 页新增"临时注入并启动"（记住上次插件，一键注入）与"选择插件 · 临时注入并启动" |
| `TrollFools/TrollFoolsApp.swift` | 启动时执行孤儿会话自愈 |
| `devkit/tipa.sh` | 把 `trollfoolscli` 打进 `Payload/TrollFools.app/`（原版 tipa 不带 CLI） |
| `zh-Hans/en Localizable.strings` | 新增文案 |
| `.github/workflows/build-tipa.yml` | macOS 云端打包 tipa（无需本地 Mac） |

原有的持久注入功能（注入 / 推出 / 管理插件）完全保留未动。

## 打包

**方式 A（推荐，无 Mac）：** 推到 GitHub，Actions 自动构建，Artifacts 下载 `*.tipa`。

**方式 B（有 Mac）：**
```bash
make package FINALPACKAGE=1
# 产物: packages/TrollFools_<ver>-<build>.tipa
```

## 使用

1. TrollStore 安装 tipa
2. 选择目标 App → 首次点 **选择插件 · 临时注入并启动** 选中你的 dylib（如 S45smoba 编译产物）
3. 之后该 App 页面会出现 **临时注入并启动（xxx.dylib）** 一键按钮
4. 退出目标 App 数秒后自动还原（可在本 tipa 日志页查看还原记录）

## 注意

- 临时注入期间不要再用原版"注入"往同一 App 塞别的持久插件，还原时会把整个注入状态清干净
- 看门狗等待目标启动最长 600 秒，超时会直接还原（视为放弃本次注入）
- 若设备重启导致看门狗丢失，下次打开本 tipa 会自动还原残留注入
