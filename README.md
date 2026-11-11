# dsh-vm-lab

在 Windows 上用 VirtualBox 搭一个隔离虚拟机,安全地试用 dsh(DeepSeek 命令行智能体)这类会自己执行命令的 AI。

- 真实 API Key 不进虚拟机(虚拟机里只有假 Key,真 Key 只在电脑内存里的转发器中)
- 虚拟机碰不到局域网和本机服务(只能经电脑上的网页代理上网,拦截回环/内网/云元数据地址)
- 一个开关启动/关闭整套环境,随时一键断网
- 出问题时生成已打码的诊断文件,交给你自己的 AI 帮你排查

这是一个 Claude Code 技能(Skill)。用法:

1. 把整个仓库放进 `~/.claude/skills/dsh-vm-lab/`(Windows: `C:\Users\<你>\.claude\skills\dsh-vm-lab\`)
2. 对 Claude Code 说"帮我搭 dsh 隔离虚拟机",或直接双击 `portable\setup.cmd` 做环境检测并按 `SKILL.md` 往下走

详细步骤、常见问题、安全规则见 [SKILL.md](SKILL.md)。

## 验证环境

Windows 11,VirtualBox 7.2.22,Python 3.12;VPN 模式和真实 IP 模式的代理都测过。其他环境遇到问题,欢迎提 Issue,并附上 `diagnose.cmd` 生成的 `diagnose.txt`(已打码,不含 Key 和密码)。

## 免责

只用一次性、余额很小的 API Key。本项目按 MIT 协议原样提供,不保证安全性,使用风险自负。