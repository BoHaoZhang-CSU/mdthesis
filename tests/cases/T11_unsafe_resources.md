# 文档

## 第一节

下面这几张图都应该被拦截，不能把服务器上的文件读出来：

![外部地址](http://example.com/x.png)

![本地文件](/etc/hostname)

![相对穿越](../../../etc/passwd)

正常的相对路径图片不受影响（见 T9_with_image.md）。

## 第二节

链接也要扫：file:// 和 UNC 会被转嫁给打开文档的人。

[本地链接](file:///etc/passwd)

正常外链不受影响：[示例站](https://example.com)

正文结束。
