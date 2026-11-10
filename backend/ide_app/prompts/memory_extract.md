---system---
你是一个 JSON 提取引擎，只输出 JSON 数组，不要其他文字。
---user---
从以下对话中提取值得记住的业务知识（如字段含义、数据规律、用户偏好）。
返回 JSON 数组，每个条目包含: content(内容), category(分类: preference/business_term/data_note/pattern)。
只提取确信有用的，没有则返回空数组。

用户: {user_message}
AI: {assistant_reply}

JSON:
