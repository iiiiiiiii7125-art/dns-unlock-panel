# REFERENCES.md — 参考来源

本项目是**自己实现**的 Go 单二进制；以下项目只作为设计参考，没有拉取或运行其中任何脚本/代码。

| 项目 | 说明 | 本项目用到它的哪一点 |
|---|---|---|
| [ab77/netflix-proxy](https://github.com/ab77/netflix-proxy)（3738 stars） | dnsmasq + sniproxy + Docker，管理站 :8080 做客户端 IP 授权 | 经典栈对照：DNS 复写 + SNI 代理分离；客户端 IP 授权 → 我们的 allowlist |
| [myxuchangbin/dnsmasq_sniproxy_install](https://github.com/myxuchangbin/dnsmasq_sniproxy_install) | 一键脚本，proxy-domains.txt 是单一域名总表 | 域名库参考源之一；我们改为每平台最小化域名 + 自定义域名入口 |
| [lthero-big/Smartdns_sniproxy_installer](https://github.com/lthero-big/Smartdns_sniproxy_installer) | SmartDNS + sniproxy，解锁机/被解锁机分离 | 两种解锁模式（address / nameserver）的思路来源；解锁机与被解锁机分离的部署模型 |
| [suuhm/unblock-proxy.sh](https://github.com/suuhm/unblock-proxy.sh) | 一键解锁代理脚本 | 安装脚本的交互流程参考（提示输入、写配置、起服务） |
| [liulilittle/sniproxy](https://github.com/liulilittle/sniproxy) | SNI 代理实现 | SNI 解析与透传的协议参考 |
| [v2fly/domain-list-community](https://github.com/v2fly/domain-list-community)（geosite） | 域名分类清单 | 平台域名核对的交叉参考 |
| [yt1988/unlock-check](https://github.com/yt1988/unlock-check)（154 项流媒体/AI 解锁检测） | 解锁检测脚本 | “解锁自测”清单的设计参考（按服务逐项核对，不做假检测）；热度分级的参考之一 |
| RegionRestrictionCheck | 流媒体地区限制检测思路 | 同上：检测方法按平台给，不伪造结果 |
| [SukkaW/Surge](https://github.com/SukkaW/Surge)（规则集方法论） | Surge 规则的最小化原则 | 域名库最小化：只收真正做地域判定的域名，不拉通用 CDN |

另：AKDNS（dns.akile.ai）作为分类法与选择项全面性的参考（六类：流媒体、AI 服务、日本专区、台湾专区、香港专区、社交与娱乐；约 18 个地区；六步流程），同样没有拉取或运行其任何脚本/代码。
