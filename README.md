# jenshow 部署脚本

一套用于 Linux 服务器的**环境搭建**与**前后端发布**脚本，支持 `curl` 一键安装。

- 代码仓库：[github.com/showx/jenshow](https://github.com/showx/jenshow)
- 脚本源：`https://raw.githubusercontent.com/showx/jenshow/master`

---

## 目录结构

```
jenshow/
├── project.conf.example      # 配置模板（提交到仓库）
├── project.conf              # 各项目实际配置（本地/业务仓库，勿提交 jenshow）
├── project_lib.sh            # 配置加载与 Supervisor 模板生成
├── install.sh                # curl 安装入口
├── setup_server.sh           # 完整服务器环境搭建
├── setup_server_common.sh    # 仅基础软件安装
├── setup_lib.sh              # setup 幂等工具库
├── backend/
│   ├── publish.sh              # 后端发布主脚本
│   ├── build_and_upload.sh     # → publish.sh --upload-only
│   ├── build_upload_deploy.sh  # → publish.sh
│   └── deploy.sh               # 服务器端切换版本
└── frontend/
    └── build_and_upload.sh   # 构建 + 打包 + 上传 + 解压部署
```

---

## 两个层次，别混用

| 层次 | 是什么 | 要不要推送到 jenshow |
|------|--------|----------------------|
| **工具仓库** | [showx/jenshow](https://github.com/showx/jenshow) — 脚本、模板 | 直接推送，`project.conf.example` 即可 |
| **项目配置** | 每个业务项目一份 `project.conf` | **不要**推进工具仓库 |

工具仓库里只有 `project.conf.example`（占位符）。每个项目在使用时复制并修改：

```bash
cp project.conf.example project.conf
# 编辑 PROJECT_NAME、SERVER_HOST、API_DOMAIN …
```

`project.conf` 已加入 `.gitignore`，避免误提交某个项目的 IP/域名。

---

## 核心概念：配置驱动

所有路径由 **`project.conf`** 统一管理，分为三类：

1. **项目标识** — `PROJECT_NAME` 决定服务名、服务器 `WEB_ROOT`
2. **本地目录** — 脚本位置、源码位置、构建产物（相对 `project.conf` 所在目录）
3. **服务器目录** — 上传到服务器的目标路径（相对 `/webwww/www/${PROJECT_NAME}`）

### 服务器侧（由 PROJECT_NAME 推导）

以 `PROJECT_NAME="myapp"` 为例：

| 项目 | 默认值 |
|------|--------|
| 部署根目录 | `/webwww/www/myapp/` |
| 后端部署目录 | `/webwww/www/myapp/backend/` |
| 前端静态目录 | `/webwww/www/myapp/frontend/dist/` |
| Supervisor 程序名 | `myapp-server` |
| Nginx 站点配置 | `/etc/nginx/sites-enabled/myapp.conf` |

### 本地目录配置

```bash
# 发布脚本放哪
BACKEND_SCRIPTS_DIR="backend"
FRONTEND_SCRIPTS_DIR="frontend"

# 源码在哪
BACKEND_SRC_DIR="backend"         # Go 工程（含 go.mod）
GO_BUILD_TARGET="."               # go build 目标
FRONTEND_SRC_DIR="frontend"       # 前端工程（含 package.json）
FRONTEND_BUILD_DIR="dist"         # 构建产物子目录
FRONTEND_BUILD_CMD="npm run build"

# 服务器子目录（相对 WEB_ROOT）
SERVER_BACKEND_SUBDIR="backend"
SERVER_FRONTEND_SUBDIR="frontend"
SERVER_FRONTEND_DIST="dist"
```

### 目录布局示例

**默认结构**（脚本与源码同在 `backend/`、`frontend/`）：

```
myrepo/
├── project.conf
├── backend/          ← 脚本 + Go 代码
└── frontend/         ← 脚本 + 前端代码
```

**Monorepo 常见结构**（脚本、源码分离）：

```
myrepo/
├── project.conf
├── deploy/
│   ├── backend/      ← BACKEND_SCRIPTS_DIR="deploy/backend"
│   └── frontend/       ← FRONTEND_SCRIPTS_DIR="deploy/frontend"
├── apps/
│   ├── api/            ← BACKEND_SRC_DIR="apps/api"
│   └── web/            ← FRONTEND_SRC_DIR="apps/web"
```

对应配置：

```bash
BACKEND_SCRIPTS_DIR="deploy/backend"
FRONTEND_SCRIPTS_DIR="deploy/frontend"
BACKEND_SRC_DIR="apps/api"
GO_BUILD_TARGET="./cmd/server"
FRONTEND_SRC_DIR="apps/web"
FRONTEND_BUILD_DIR="dist"
```

发布脚本会从自身位置**向上查找** `project.conf`，因此脚本目录可以任意嵌套。

### 基础配置

```bash
PROJECT_NAME="myapp"
SERVER_USER="root"
SERVER_HOST="1.2.3.4"             # 发布时必填
API_DOMAIN="api.example.com"
FRONTEND_ROUTE="/adminxend"
BACKEND_PORT="8080"
```

---

## 快速开始

### 0. 推送工具仓库（无需填任何项目信息）

[jenshow](https://github.com/showx/jenshow) 是**通用脚本库**，可以直接推送：

```bash
git add .
git commit -m "init deploy toolkit"
git push origin master
```

### 1. 交互式配置（推荐，curl 一步步来）

**本机：交互配置 + 下载发布脚本**

```bash
curl -fsSL https://raw.githubusercontent.com/showx/jenshow/master/install.sh | bash -s -- init ./myproject
```

会依次询问（回车即用默认值）：

1. **项目标识** — 项目名、API 域名、服务器 IP、SSH 用户  
2. **运行参数** — 前端路由、后端端口  
3. **目录布局**（可选高级）— Go/前端源码路径  

确认后生成 `project.conf` 并下载全部脚本。

**仅交互生成配置（不下载脚本）：**

```bash
curl -fsSL https://raw.githubusercontent.com/showx/jenshow/master/install.sh | bash -s -- configure
```

**服务器：交互配置 + 环境搭建（需 root）：**

```bash
curl -fsSL https://raw.githubusercontent.com/showx/jenshow/master/install.sh | sudo bash -s -- setup-init
```

> 说明：curl 管道执行时仍可在终端输入，脚本从 `/dev/tty` 读取。若无 TTY，请先下载再执行：  
> `curl -fsSL ... -o install.sh && bash install.sh init`

### 2. 非交互方式（已有配置或环境变量）

```bash
PROJECT_NAME=qsdk API_DOMAIN=qsdk.example.com \
curl -fsSL https://raw.githubusercontent.com/showx/jenshow/master/install.sh | sudo bash -s -- setup
```

本地已有 `project.conf` 时：`sudo ./setup_server.sh`

### 3. 本机仅下载脚本（无交互，使用模板）

```bash
curl -fsSL https://raw.githubusercontent.com/showx/jenshow/master/install.sh | bash -s -- deploy-scripts ./my-project
```

### 4. 发布后端

在 `BACKEND_SCRIPTS_DIR` 对应目录下（默认 `backend/`）：

```bash
# 编译 + 上传 + 远程部署（推荐）
./publish.sh
./publish.sh 20260109_1530

# 等价快捷方式
./build_upload_deploy.sh

# 仅编译 + 上传
./publish.sh --upload-only
./build_and_upload.sh
```

### 5. 发布前端

在 `FRONTEND_SCRIPTS_DIR` 对应目录下（默认 `frontend/`）：

```bash
./build_and_upload.sh

# 指定版本号
./build_and_upload.sh 20260109_1530
```

---

## 部署流程说明

### 后端

```
本机 build_upload_deploy.sh
  ├─ go build（按 BACKEND_SRC_DIR / GO_BUILD_TARGET 编译）
  ├─ 输出 myapp-server<版本号> 到 backend/ 脚本目录
  ├─ scp 上传到服务器 backend/
  └─ ssh 远程执行 deploy.sh <版本号>
       ├─ chmod 744
       ├─ ln -snf 更新软链 myapp-server
       └─ supervisorctl restart myapp-server
```

### 前端

```
本机 build_and_upload.sh
  ├─ npm run build
  ├─ tar 打包 dist
  ├─ scp 上传到服务器 frontend/
  └─ ssh 远程解压
       ├─ dist → dist_old（备份）
       └─ 解压新版本到 dist/
```

### 服务器 setup 做了什么

`setup_server.sh` 会依次完成：

1. 更新 apt 软件源（已安装时可跳过 upgrade）
2. 安装 Nginx、Supervisor、Redis
3. 配置 SSH（关闭密码登录、支持 ssh-rsa 密钥）
4. 创建项目目录并设置权限
5. 写入 Nginx 站点配置
6. 写入 Supervisor 配置（按 `PROJECT_NAME` 命名）
7. 同步 `project.conf` 和 `deploy.sh` 到服务器 `backend/` 目录

---

## 幂等设计（可重复执行）

所有 setup 脚本支持**重复运行**，已完成的步骤会自动跳过，输出 `⏭ 跳过:` 提示：

| 检测项 | 行为 |
|--------|------|
| apt 软件包 | 已安装则跳过 |
| apt upgrade | 核心软件均已安装则跳过 |
| systemd 服务 | 已在运行则跳过 |
| SSH 配置 | 已是目标配置则跳过，不重复覆盖 `.bak` |
| 目录 | 已存在则跳过创建 |
| Nginx / Supervisor 配置 | 内容无变化则跳过重载 |
| deploy.sh | 已存在则跳过下载 |

### 强制覆盖选项

```bash
# 强制系统升级
sudo FORCE_UPGRADE=1 ./setup_server.sh

# 强制重新下载 deploy.sh
sudo FORCE=1 ./setup_server.sh
```

---

## 环境变量

setup 时可通过环境变量覆盖 `project.conf`（适合 curl 一行命令）：

```bash
PROJECT_NAME=myapp \
API_DOMAIN=api.example.com \
curl -fsSL https://raw.githubusercontent.com/showx/jenshow/master/install.sh | sudo bash -s -- setup
```

| 变量 | 说明 |
|------|------|
| `JENSHOW_BASE_URL` | 脚本下载源（GitHub raw 地址） |
| `PROJECT_NAME` | 项目名 |
| `API_DOMAIN` | Nginx server_name |
| `FRONTEND_ROUTE` | 前端 SPA 路由前缀 |
| `BACKEND_PORT` | 后端监听端口 |
| `FORCE_UPGRADE` | `1` = 强制 apt upgrade |
| `FORCE` | `1` = 强制覆盖 deploy.sh |

---

## 服务器目录布局

以 `PROJECT_NAME=myapp` 为例，setup 完成后服务器上的目录：

```
/webwww/www/myapp/
├── backend/
│   ├── project.conf              # setup 自动同步
│   ├── deploy.sh                 # setup 自动下载
│   ├── myapp-server              # 软链 → 当前版本二进制
│   └── myapp-server20260109_1530 # 实际上线的二进制
└── frontend/
    ├── dist/                     # 当前前端静态文件
    ├── dist_old/                 # 上一次部署备份
    └── dist_20260109_1530.tar.gz # 上传的压缩包
```

---

## 前置要求

### 服务器

- Ubuntu / Debian 系 Linux
- root 权限
- 可访问 apt 源

### 本机（发布时）

- **后端**：Go 工具链、SSH 免密登录到服务器
- **前端**：Node.js、npm、SSH 免密登录到服务器

---

## 常见问题

**Q: 之前用的是 `qsdk2` 目录，怎么兼容？**

在 `project.conf` 中设置 `PROJECT_NAME="qsdk2"`，路径会变为 `/webwww/www/qsdk2/`，服务名为 `qsdk2-server`。

**Q: curl setup 时找不到 project.conf？**

正常。setup 不会从工具仓库拉某个项目的配置。请传 `PROJECT_NAME` 等环境变量，或在执行目录放好该项目的 `project.conf`。

**Q: Supervisor 启动失败？**

首次 setup 时后端二进制尚未上传，`myapp-server` 不存在导致启动失败是正常现象。执行 `build_upload_deploy.sh` 发布后端后即可。

**Q: 如何查看服务状态？**

```bash
supervisorctl status myapp-server    # 替换为你的 PROJECT_NAME-server
tail -f /var/log/myapp-server.out.log
```

---

## 脚本速查

| 脚本 | 运行位置 | 作用 |
|------|----------|------|
| `install.sh configure` | 本机/服务器 | 交互式生成 project.conf |
| `install.sh init` | 本机 | 交互配置 + 下载脚本 |
| `install.sh setup-init` | 服务器 | 交互配置 + 环境搭建 |
| `install.sh setup` | 服务器 | curl 完整环境搭建 |
| `install.sh setup-common` | 服务器 | curl 基础软件安装 |
| `install.sh deploy-scripts` | 本机 | curl 下载全部发布脚本 |
| `setup_server.sh` | 服务器 | 完整环境搭建 |
| `setup_server_common.sh` | 服务器 | 基础软件安装 |
| `backend/publish.sh` | 本机 | 后端发布主脚本 |
| `backend/build_upload_deploy.sh` | 本机 | 后端一键发布（调用 publish.sh） |
| `backend/build_and_upload.sh` | 本机 | 仅编译上传 |
| `backend/deploy.sh` | 服务器 | 切换后端版本 |
| `frontend/build_and_upload.sh` | 本机 | 前端一键发布 |
