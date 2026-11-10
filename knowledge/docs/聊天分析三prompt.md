> 来源：JoyTools 88 Agent（assets/45_NLP数据写入测试/聊天分片分析.md、群组分片聚合分析.md、话题聚合分析.md、SQL合集.sql、chunk_flow.py、nlp_utils.py）

# 聊天分析三 Prompt 口径

## 取数口径（SQL合集.sql，先于任何分析）
- chattype 映射：0-世界、2-公会、3-私聊、4-好友；取数限定 chattype IN (0,2)。
- chatgroup_id 构造：0→gamesvrid；2→unionid；3→LEAST(vroleid,rroleid)-GREATEST(vroleid,rroleid)；4→gamesvrid-rroleid。
- [z数字] 表情清洗：regexp_replace 去掉 [z数字] 后，再把去重后的表情串补一次（array_join(array_distinct(...))），同时去 [li]。
- 时区切日：dteventtime 减 5 小时后取前 10 位作为自然日 date（这是既定切日口径，别改用其他偏移）。
- 噪声过滤：content 非空、不含 "-数字" 口令、不含 lfp/lfm/-fs/welcome、不在 public_analyst.dim_stopwords_info 停用词表。

## 三 Prompt 分工（分片 → 跨分片 → 全量，不要跳级）
1. **聊天分片分析**：单群单日分片内的话题级分析；每话题 ≥5 句/UUID 才成立；忽略招募、水帖、纯表情、无意义口头禅与刷屏；情感分布整数百分比总和 100；语言 18 枚举、话题分类 11 类、情感标签 6 类。
2. **群组分片聚合分析**：跨分片去重合并；reference_uuid_list 去重；重叠窗口视为同一候选。
3. **话题聚合分析**：热度最高 5 话题；topic_summary 为含 facts/positive/negative 的 JSON 字符串；reference_topicid_list 去重。

## 注意事项
- topic_id 用 game_code|date|chat_type|chatgroup_id|salt|序号 哈希构造（nlp_utils 口径），跨批次稳定。
- 分片顺序敏感：先 sort（date, chat_type, chatgroup_id, dteventtime, uuid）再切分，聚合才有确定性。
