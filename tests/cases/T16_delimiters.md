# 公式括号测试

向量里带分式 —— 普通 `[ ]` 不会随内容变高，括号会框不住分式（用户报过）：

$$\varphi_d(k) = [i_d(k), \quad -\omega_e(k)i_q(k), \quad \frac{i_d(k+1)-i_d(k)}{T_s}]^T$$

圆括号里装分式，同样要撑开：

$$g(k) = (\frac{a}{b} + c) \cdot h$$

下面这些**不该**被动（没有"高个子"内容）：

$$\theta_d = [R_s, \quad L_q, \quad L_d]^T$$

行内：下标 $x[i]$、普通括号 $(k+1)$ 都不该动。

已经自己写好的不该被重复标记：$\left[\frac{a}{b}\right]$。

括号内分组不完整（`\left/\right` 不能跨组）也不该动：$\frac{a[}{b]}$。
