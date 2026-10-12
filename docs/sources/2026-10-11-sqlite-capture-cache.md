---
title: SQLite 临时捕获缓存与 spill 阈值
author: SQLite project
source_url: https://www.sqlite.org/pragma.html#pragma_cache_spill
captured: 2026-10-11
kind: external-spec
---

## 来源摘要

SQLite 官方 [cache_spill](https://www.sqlite.org/pragma.html#pragma_cache_spill) 规定脏页溢出需要同时超过 spill 阈值与 cache_size 限额；数字阈值和布尔开关语义不同。[cache_size](https://www.sqlite.org/pragma.html#pragma_cache_size) 的负值是近似 KiB 预算，连接级设置不跨会话持久化。

## 本项目采用的部分

仅对应用自建、可丢弃的内部捕获副本同时设置 4 MiB cache 和明确的数字 spill 阈值，按实际 page_size 验证有效 spill 在预算内；源库 DELETE/EXTRA 不变。实现见 [SQLiteLogicalCaptureDatabase](../../Sources/KinloguePlatform/Backup/SQLiteLogicalCaptureDatabase.swift)，本机规模观测见 [实测](../storage-refactor-measurement-2026-10-11.md#sqlite-逻辑捕获)。

## 未采用或仍待验证的部分

本机 macOS 27.0.1 system SQLite 在只降低 cache_size 后仍回读 20,000 pages，是本机观测，不是上游所有构建的默认保证。代码不依赖该常数或本机有效阈值 991；macOS 26 engine 尚待独立验证。内部副本不作为备份文件格式，不改变逻辑恢复点的版本契约。
