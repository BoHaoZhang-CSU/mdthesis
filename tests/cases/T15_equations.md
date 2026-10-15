# 公式编号测试

## 摘要

本文用来测试公式编号。**摘要不算一章** —— 模板不给它编号，编号器也不能把它算进去
（踩过：第 4 章的表编成了 5-1）。

## 引言

行内公式 $a = b$ 不该被编号。

第一个独立公式：

$$y(k) = \varphi^T(k)\theta$$

第二个：

$$\hat{\theta}(k) = \hat{\theta}(k-1) + K(k)\varepsilon(k)$$

推导中间步骤不编号：

::: {.unnumbered}
$$K(k) = P(k-1)\varphi(k)[\lambda + \varphi^T(k)P(k-1)\varphi(k)]^{-1}$$
:::

## 仿真验证

本章第一个公式：

$$J = \sum_{k=1}^{N} \varepsilon^2(k)$$
