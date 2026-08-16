# 巨天 Codex 插件

这个插件把巨天的本地 Canvas Agent MCP 打包给 Codex app 使用，让 Codex 能打开本地画布、读取当前节点、创建内容并触发生成流程。

## 安装

> 巨天尚未上架 Codex 公共插件目录，直接搜索不会显示。请从本仓库自带的 marketplace 安装。

### AI 自动安装

把下面这段发给 Codex：

```text
请从 https://github.com/zkhyww/open-ai-canvas.git 的 jutian/stable 分支安装巨天 Codex 插件。
请 clone 该分支到 ~/plugins/open-ai-canvas，确认 .agents/plugins/marketplace.json 和
plugins/infinite-canvas/.codex-plugin/plugin.json 都存在。然后运行
codex plugin marketplace add ~/plugins/open-ai-canvas，
再运行 codex plugin add infinite-canvas@infinite-canvas-local。
安装后请校验插件，并告诉我是否需要开启一个新对话来加载新技能和 MCP 工具。
```

### 手动安装

如果本机还没有仓库，先 clone：

```bash
mkdir -p ~/plugins
git clone --branch jutian/stable --single-branch https://github.com/zkhyww/open-ai-canvas.git ~/plugins/open-ai-canvas
```

注册仓库 marketplace 并安装插件；如果使用已有仓库，请把路径替换为仓库的绝对路径：

```bash
codex plugin marketplace add ~/plugins/open-ai-canvas
codex plugin add infinite-canvas@infinite-canvas-local
```

安装后建议开启一个新的 Codex 对话，让新的 skill 和 MCP 工具完整加载。

### 本仓库开发调试

如果你就在巨天仓库中调试插件，可以直接添加当前仓库。建议使用仓库绝对路径，避免 Codex 从其他工作目录解析失败：

```bash
cd /path/to/infinite-canvas
codex plugin marketplace add "$(pwd)"
codex plugin add infinite-canvas@infinite-canvas-local
```

## 使用

1. 新建 Codex 线程后说“打开巨天”。
2. 插件会确认当前仓库的本地画布服务是否已运行；端口被占用时会检查进程归属，不会把其他项目的 `3000` 当作巨天。
3. 确认或启动后，插件会直接打开新建画布 URL，并自动尝试连接本地 Agent。
4. 画布打开后，让 Codex 读取或操作当前画布。

常用提示：

```text
打开巨天
读取当前画布并总结节点结构
根据选中节点创建一组生图提示词
```

## 工作机制

插件会从已注册的 `infinite-canvas-local` marketplace 定位当前巨天源码，并使用其中已构建的 Canvas Agent MCP。它不依赖未发布的公网 npm 包。

“巨天一键启动”负责幂等启动 Web 3000、Backend 8080 和本机 Runtime 17371。浏览器会使用签名会话连接 Runtime，无需也不应把连接令牌放入 URL。

## 手动排查

优先双击桌面的“巨天一键启动”，然后检查：

```bash
http://127.0.0.1:3000
http://127.0.0.1:8080/api/health
http://127.0.0.1:17371/health
```

插件已安装但 Codex 仍没有巨天工具时，先确认状态，再新建一个 Codex 任务：

```bash
codex plugin list
```

遇到“本机运行时请求失败”，重新运行一键启动并刷新页面。不要读取或复制 Runtime 主令牌，不要使用带 `agentToken` 的旧版深链接。
