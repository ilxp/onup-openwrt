# ONUP - Online UPgrade System for OpenWrt

OpenWrt 系统自动在线更新工具。命令行 + LuCI 双界面，支持定时升级、一键更新、镜像加速、断点续传。

## 特性

- **命令行 + LuCI 双入口**：SSH 里 `onup -T` 一键测试，LuCI 页面点按钮升级
- **多下载器支持**：aria2c / wget-ssl / curl / wget / uclient-fetch，可配置或命令行指定
- **镜像加速**：支持多个 GitHub 镜像，随机打乱 + 逐镜像重试，直连垫底，避开限流
- **自定义升级源**：从服务器拉取 JSON 清单
- **定时升级**：weekly / monthly 两种计划，4 个独立高级开关
- **x86 引导方式**：自动探测 UEFI/BIOS，可手动指定
- **SHA256 校验**：下载后校验，防止损坏
- **固件格式**：.img / .img.gz / .gz / .zip 全支持，自动解压
- **日志持久化**：设备重启后保留最近一次升级记录

## 命令行用法

### 快速上手

```bash
onup -T              # 测试模式：下载 + 校验，不刷写
onup                 # 手动升级（保留配置）
onup -n              # 升级（不保留配置）
onup --list          # 打印系统信息
onup --help          # 完整帮助
```

### 全部参数

```
更新固件:
  -n                     不保留配置更新固件
  -u                     适用于定时更新（跳过交互）
  -f                     跳过版本校验 + 强制刷写（危险）
  -F, --force-flash      强制刷写（危险）
  -D <Downloader>        指定下载器
                         可选: aria2c | wget-ssl | wget | curl | uclient-fetch
  -P, --proxy <URL>      临时指定镜像（覆盖 Mirror_List，逗号分隔多个）
  --decompress           解压 .img.gz / .zip 后再刷写
  --skip-verify          跳过 SHA256 校验（危险）
  --path <PATH>          固件下载到指定路径

更新脚本:
  -x                     自动更新 onup 程序
  -x -path <PATH>        更新到指定路径
  -x -url <URL>          从指定 URL 更新

其他:
  --help                 打印帮助
  -T                     测试模式（下载+校验，不刷写）
  -B, --boot-mode <TYPE>  x86 引导方式（UEFI / BIOS / auto）
  -C, --api-url <URL>     更改 API 地址
  --api                  打印当前 API 内容
  --backup [PATH]        备份系统配置
  --chk                  检查运行环境
  --clean                清理缓存
  --flag <FLAG>          更改固件标签
      --flag -reset      恢复默认固件标签
  --fw-log < | *>        打印云端更新日志
  --env <ENV> [ENV]...   打印环境变量
  --log                  打印运行日志
      -clean             清空运行日志
      -del / -rm         同 -clean
      -path <PATH>       更改日志保存路径（需配合 --log）
  --list                 打印系统信息
  --reset                重置运行环境
  --verbose              打印详细下载信息
  -v < | [Cc]loud>       打印当前 / 云端脚本版本
  -V < | [Cc]loud>       打印当前 / 云端固件版本
```

### 常用示例

```bash
# 换镜像加速（临时，当次有效）
onup -T -P https://aa.com

# 多个镜像
onup -T -P "https://aa.com,https://bb.com"

# 用 curl 下载（弱网/代理环境）
onup -T -D curl

# 强制刷写固件
onup -F

# 更新 onup 程序自身
onup -x

# 打印云端更新日志
onup --fw-log
```

## 配置文件

### 优先级

```
custom (用户覆盖) > default (出厂默认) > 内置默认值
```

**custom 里只存"与 default 不同的值"**。改回默认值时，custom 里对应行会被自动删除。

### 常用字段

```sh
# 核心
Github=https://github.com/user/repo
TARGET_FLAG=oR
Log_Path=/tmp

# 镜像
Mirror_List=https://aa.com,https://bb.com
Mirror_Random=1          # 1=随机打乱 0=固定顺序
Mirror_Retry=1           # 每个镜像重试次数

# 下载器（auto = 走默认优先级列表）
Downloader=auto

# x86 引导（auto = 自动探测）
x86_Boot_Method=auto
```

## 下载器优先级

**不指定下载器时**，按以下顺序尝试（第一个可用即用）：

```
aria2c > wget-ssl > curl > wget > uclient-fetch
```

**指定下载器时**（LuCI 下拉框 或 `-D`），全链路统一使用：

| 场景 | auto | 指定 `curl` |
|---|---|---|
| 拉 API 清单 | wget-ssl | curl |
| 拉云端日志 | wget-ssl | curl |
| 下载固件 | aria2c | curl |
| `-v cloud` 拉脚本 | aria2c | curl |
| `-x` 更新脚本 | aria2c | curl |

**为什么 auto 时拉 API 用 wget-ssl 而非 aria2c？**

API / 云端日志是小文件（几 KB），aria2c 的启动开销（~100ms）不划算。轻量的 wget-ssl/curl 更合适。**固件（~200MB）才值得用 aria2c 多线程。**

## 定时任务

### 启用

LuCI 页面勾选 `Enable Scheduled Upgrade` → 设置计划 → 保存。

### 命令行

```bash
# 每周一 3:30，带 --decompress
uci set onup.@onup[0].enable=1
uci set onup.@onup[0].schedule_type=weekly
uci set onup.@onup[0].week=1
uci set onup.@onup[0].hour=3
uci set onup.@onup[0].minute=30
uci set onup.@onup[0].decompress=1
uci commit onup
/etc/init.d/onup restart
```

生成的 cron 任务：

```
30 3 * * 1 /usr/bin/onup -u --decompress		## onup crontab
```

### 关闭

```bash
uci set onup.@onup[0].enable=0
uci commit onup
/etc/init.d/onup restart
```

## 镜像配置

### 格式

- 分隔符：`逗号` / `分号` / `空格`
- 空值 = 直连 GitHub

### 建议

- **单用户**：关掉随机，把最快的镜像放第一位
  ```sh
  Mirror_List=https://aa.com,https://bb.com,https://cc.com
  Mirror_Random=0
  ```
- **多用户**：保持随机，分散负载
  ```sh
  Mirror_Random=1
  ```

## 故障排查

### 检查环境

```bash
onup --chk
```

检查项：`jq` / `sysupgrade` / 各下载器 / HiCloud / GitHub / 必填环境变量。

### 常见问题

| 症状 | 原因 | 处理 |
|---|---|---|
| `API 请求错误` | 网络不通 / 镜像挂 | 换镜像 或 `-P` 指定 |
| `云端未找到适配本机的固件` | 标签/设备/格式不匹配 | 检查 `TARGET_FLAG` / `TARGET_PROFILE` |
| `固件下载失败` | 镜像不稳 | 换镜像 / 加 `-D wget-ssl` |
| `SHA256 校验失败` | 文件损坏 / 缓存残留 | 清 `/tmp/onup/` 重下 |
| LuCI 页面打不开 | controller 语法错 / 缓存 | `rm -rf /tmp/luci-*` + 重启 uhttpd |
| `-v cloud` 失败 | `Script_Url` 路径 404 | 检查 GitHub 仓库 |

### 查看日志

```bash
# 实时日志
tail -f /tmp/onup.log

# 最近一次升级（重启后保留）
cat /etc/onup/last.log

# 命令行
onup --log
```
## 致谢

本项目部分代码参考了 [Hyy2001X/AutoBuild-Actions-BETA](https://github.com/Hyy2001X/AutoBuild-Actions-BETA)，
在此特别感谢原作者 Hyy2001X。

原始项目的模块化设计、镜像加速、固件挑选逻辑为 `onup` 提供了重要基础。

## 许可

MIT

## 反馈

- GitHub Issues: https://github.com/ilxp/onup-openwrt/issues
- 运行日志 + 系统信息：`onup --log` + `onup --list`