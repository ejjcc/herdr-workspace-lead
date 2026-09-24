# herdr-workspace-lead

在 [Herdr](https://herdr.dev) 中协调多个 coding agent 的 Agent Skill。调用它的 agent 担任 leader：巡检各 agent 状态、派发任务并验收产物、处理阻塞、清理自己创建的资源。默认只管理 leader 所在的 Herdr workspace。

## 能力

| 流程 | 作用 |
| --- | --- |
| Patrol | 只读巡检：列出范围内每个 agent 的语义状态（`working` / `blocked` / `done` / `idle` / `unknown`）和阻塞原因 |
| Dispatch and collect | 给已有 agent 命名并派活，或新开 tab 启动 helper；用固定模板写 brief，按产物文件验收 |
| Unblock | 读取 `blocked` agent 的确认框或问题，交给用户决定，不代为回答 |
| Cleanup | 核实完成情况后，只关闭本次编排创建的或用户点名的 tab |

## 范围与权限边界

- 调用方所在 workspace 内的 agent 默认可调用，按名字寻址（如 `bt-codex`），不依赖会变化的 pane ID。
- 其他 workspace 的 agent 默认不可调用。只有用户点名该 agent，或授权该 workspace，才进入范围；不从上下文推断授权。
- 不代答确认框、不打断 `working` 的 agent、不关闭非本次编排创建的资源、不停止 Herdr server。
- 同一 checkout 最多一个写入者；并行写入使用独立 worktree。
- 高风险改动由不同底层模型的 worker 交叉评审；多个评审结论不做多数表决，而是列出分歧。

## 前置条件

- Herdr 0.9.0 或更高版本（行为在 0.9.0 上验证）
- `jq`
- leader 必须运行在 Herdr 管理的 pane 内（`HERDR_ENV=1`）
- 交互式 shell 为 zsh 或 bash（用于解析 alias）

## 安装

```bash
npx skills add ejjcc/herdr-workspace-lead
```

也可以直接把仓库克隆到 agent 的 skills 目录，例如 `~/.claude/skills/herdr-workspace-lead`。

## 配置 helper 的启动 profile

helper 通过 launch profile 启动。profile 是交互式 shell 里的一个命令名：可以是携带模型环境变量和权限参数的 alias，也可以是 `claude`、`codex` 这类 agent 可执行文件。

按角色选取 profile，优先级从高到低：

1. 用户在任务中指定的 profile
2. 角色对应的环境变量
3. 自动发现：`scripts/list_profiles.sh` 列出本机 shell 中所有能启动 Herdr 可识别 agent 的 alias 和可执行文件（只输出名称，不输出 alias 定义）

| 角色 | 环境变量 | 适用任务 |
| --- | --- | --- |
| Executor | `HERDR_WORKSPACE_LEAD_EXECUTOR_PROFILE` | 执行命令、检索资料、代码修改、测试、机械性多步操作 |
| Writer | `HERDR_WORKSPACE_LEAD_WRITER_PROFILE` | 撰写文档、总结、把证据整理成文字 |

```bash
# ~/.zshrc
export HERDR_WORKSPACE_LEAD_EXECUTOR_PROFILE=codex
export HERDR_WORKSPACE_LEAD_WRITER_PROFILE=claude
```

权限模式由 profile 本身决定，skill 不添加也不去除权限参数：

- 跳过确认的 profile：helper 不会因 Bash 确认而停住，此时 brief 中的写入边界是唯一约束。
- 需要确认的 profile：helper 每次遇到确认框会进入 `blocked`，由 leader 转交用户处理。

## 目录结构

```
SKILL.md                    角色定义、范围规则、权限边界、状态模型
references/workflows.md     Patrol / Dispatch / Unblock / Cleanup 的具体步骤
references/monitoring.md    派活后的探测、失败分类、重试上限、停止条件
scripts/list_profiles.sh    列出已配置和本机可发现的 launch profile
scripts/start_helper.sh     在指定 pane 中用 profile 启动 helper 并命名
```

## License

[MIT](LICENSE)
