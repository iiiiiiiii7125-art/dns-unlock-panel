# 证据归档说明（修复轮）

- 本目录归档修复轮各线的关键红/绿证据日志（审计硬性要求：红/绿跑日志必须进仓库）。
- go-lane/：Go 线 9 项的红/绿日志 + final-go-test.log（`go test ./... -count=1` 全绿，lane worktree）。
- plan3-lane/：V016-03/04/05 的红证、check3.log（基线/复测接线）、panel-test3.log（PreferFastest API 接线）、rig.log（受 Shell 线并行台架污染的 115+12，见该线汇报）。
- shell-lane/rig-clean-126-1.log：Shell 线干净单跑 rig 126 PASS + 1 FAIL（唯一失败 S9b 清理，定性为 rig 测试设计问题——旧版 rig 的断言；新版 rig 在台架线干净跑 143/0）。
- ui-lane/v016-ui-harness.js：UI 线行为 harness 脚本（30/30）；真浏览器点按 6 项未做，待合并后由父代理点按。
- 另：审计轮的 /tmp 证据（lane-e、p1live、v016-audit）因 /tmp tmpfs 满，已原样搬到宿主 ~/tmp-archive/（未删除），路径变更记录于此；审计结论本身在已提交的 AUDIT-V016-LANE-*.md 里。
- nspawn 第一遍 smoke 失败日志：nspawn-smoke-FAIL-20261121-1244Z.log（同目录，台架线已提交）。
