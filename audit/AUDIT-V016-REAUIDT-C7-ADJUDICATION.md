# C7br/C7cr 裁决：脚本断言 artifact，不是产品 bug

## 结论

C7br/C7cr 的 FAIL 是验证脚本的误判（false negative），产品行为正确：每行服务器的复制命令带的是本台 reveal token 与名，不含另一台 token。**不列入必须修的清单，不定 P 级。**

## 证据链（四重，互相独立）

1. **retest detail 自证条件全过**。results-retest.json 里两条 detail 的原始长度均为 55 字符，逐字符解码后是：
   - C7br：`clip has rev1 token=true name=true has rev2 token=false`
   - C7cr：`clip has rev2 token=true name=true has rev1 token=false`
   （55 字符逐数核对一致。）即：剪贴板含本台 token（true）、含名（true）、不含另一台 token（false）——三个子条件全部满足，但 `pass` 字段仍为 false。脚本的 pass 计算本身有 bug。
2. **剪贴板实物正确**。验证脚本自己保存的 server-install-cmd-01-retest.txt 与 -02-retest.txt 各含恰好一个 32 位 hex token，两个 token 的 sha256 前 12 位不同（b5c93e2274a9 vs 499a9adb55f9），名与 IP 对得上；01 文件的 token 与首轮 01 文件一致（同一台服务器，token 稳定）。命令字符串在结构上就不可能同时含两个 token。
3. **前端代码追踪**。web/index.html:772 `copyServerInstall(id)`：按 id 在 SERVERS 里找本行 → `await api('/api/v1/servers/'+id+'/reveal')` 取本台 token → `serverInstallCmd(s, j.token, ...)` 只传一个 token 写剪贴板。该路径无共享可变状态（`LAST_SRV_CMD` 只属于另一支函数 `copySrvInstall`，即刚登记那台的复制按钮）。`serverInstallCmd` 只接一个 token 参数，一条命令物理上只能含一个 token。
4. **后端 reveal 按 id 返回**。internal/panel/panel.go:1133-1143：`GET /api/v1/servers/{id}/reveal` 循环匹配 `sv.ID == nid`，返回该台自己的 token，不存在 id 混淆。

## 首轮 C7b/C7c 的旁证

- 首轮 C7b 的 detail 就是 TEST-SRV-01 的正确命令全文（160 字符），同样是“内容对但 pass=false”。
- 首轮 C7c 的 detail 为空（剪贴板空）——`copyServerInstall` 里 `navigator.clipboard.writeText` 未 await、随后又弹 `alert`，脚本读剪贴板存在时序窗口；重测时序修好后内容对了，pass 标志仍错。两轮 FAIL 的根因都在脚本侧，不在产品侧。

## 建议

验证脚本的 pass 计算修好后再跑一次 C7 即可（纯脚本问题，无需改产品代码）。若以后重跑，读剪贴板前等 `writeText` 落定（或等 alert 出现后再读），避免时序窗口重现。
